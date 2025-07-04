# Copyright 2020 Google LLC
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.

require "google/cloud/spanner"
require "spanner_client_ext"
require "activerecord_spanner_adapter/information_schema"
require_relative "../active_record/connection_adapters/spanner/errors/transaction_mutation_limit_exceeded_error"

module ActiveRecordSpannerAdapter
  TransactionMutationLimitExceededError = Google::Cloud::Spanner::Errors::TransactionMutationLimitExceededError

  class Connection
    attr_reader :instance_id
    attr_reader :database_id
    attr_reader :spanner
    attr_accessor :current_transaction
    attr_accessor :isolation_level

    def initialize config
      @instance_id = config[:instance]
      @database_id = config[:database]
      @isolation_level = config[:isolation_level]
      @spanner = self.class.spanners config
    end

    def self.spanners config
      config = config.symbolize_keys
      @spanners ||= {}
      @mutex ||= Mutex.new
      @mutex.synchronize do
        @spanners[database_path(config)] ||= Google::Cloud::Spanner.new(
          project_id: config[:project],
          credentials: config[:credentials],
          emulator_host: config[:emulator_host],
          scope: config[:scope],
          timeout: config[:timeout],
          lib_name: "spanner-activerecord-adapter",
          lib_version: ActiveRecordSpannerAdapter::VERSION
        )
      end
    end

    # Clears the cached information about the underlying information schemas.
    # Call this method if you drop and recreate a database with the same name
    # to prevent the cached information to be used for the new database.
    def self.reset_information_schemas!
      return unless @database

      @information_schemas.each_value do |info_schema|
        info_schema.connection.disconnect!
      end
      @information_schemas = {}
    end

    def self.information_schema config
      @information_schemas ||= {}
      @information_schemas[database_path(config)] ||=
        ActiveRecordSpannerAdapter::InformationSchema.new new(config)
    end

    def session
      @last_used = Time.current
      @session ||= spanner.create_session instance_id, database_id
    end
    alias connect! session

    def active?
      # This method should not initialize a session.
      unless @session
        return false
      end
      # Assume that it is still active if it has been used in the past 50 minutes.
      if ((Time.current - @last_used) / 60).round < 50
        return true
      end
      session.execute_query "SELECT 1"
      true
    rescue StandardError
      false
    end

    def disconnect!
      session.release!
      true
    ensure
      @session = nil
    end

    def reset!
      disconnect!
      session
      true
    end

    # Database Operations

    def create_database
      job = spanner.create_database instance_id, database_id
      job.wait_until_done!
      raise Google::Cloud::Error.from_error job.error if job.error?
      job.database
    end

    def database
      @database ||= begin
        database = spanner.database instance_id, database_id
        unless database
          raise ActiveRecord::NoDatabaseError, "#{spanner.project}/#{instance_id}/#{database_id}"
        end
        database
      end
    end

    # DDL Statements

    # @params [Array<String>, String] sql Single or list of statements
    def execute_ddl statements, operation_id: nil, wait_until_done: true
      raise "DDL cannot be executed during a transaction" if current_transaction&.active?
      self.current_transaction = nil

      statements = Array statements
      return unless statements.any?

      # If a DDL batch is active we only buffer the statements on the connection until the batch is run.
      if @ddl_batch
        @ddl_batch.push(*statements)
        return true
      end

      execute_ddl_statements statements, operation_id, wait_until_done
    end

    # DDL Batching

    ##
    # Executes a set of DDL statements as one batch. This method raises an error if no block is given.
    #
    # @example
    #   connection.ddl_batch do
    #     connection.execute_ddl "CREATE TABLE `Users` (Id INT64, Name STRING(MAX)) PRIMARY KEY (Id)"
    #     connection.execute_ddl "CREATE INDEX Idx_Users_Name ON `Users` (Name)"
    #   end
    def ddl_batch
      raise Google::Cloud::FailedPreconditionError, "No block given for the DDL batch" unless block_given?
      begin
        start_batch_ddl
        yield
        run_batch
      rescue StandardError
        abort_batch
        raise
      ensure
        @ddl_batch = nil
      end
    end

    ##
    # Returns true if this connection is currently executing a DDL batch, and otherwise false.
    def ddl_batch?
      return true if @ddl_batch
      false
    end

    # Returns true if this connection is currently executing a DML batch, and otherwise false.
    def dml_batch?
      return true if @dml_batch
      false
    end

    ##
    # Starts a manual DDL batch. The batch must be ended by calling either run_batch or abort_batch.
    #
    # @example
    #   begin
    #     connection.start_batch_ddl
    #     connection.execute_ddl "CREATE TABLE `Users` (Id INT64, Name STRING(MAX)) PRIMARY KEY (Id)"
    #     connection.execute_ddl "CREATE INDEX Idx_Users_Name ON `Users` (Name)"
    #     connection.run_batch
    #   rescue StandardError
    #     connection.abort_batch
    #     raise
    #   end
    def start_batch_ddl
      if @ddl_batch && @dml_batch
        raise Google::Cloud::FailedPreconditionError, "Batch is already active on this connection"
      end
      @ddl_batch = []
    end

    ##
    # Starts a manual DML batch. The batch must be ended by calling either run_batch or abort_batch.
    #
    # @example
    #   begin
    #     connection.start_batch_dml
    #     connection.execute_query "insert into `Users` (Id, Name) VALUES (1, 'Test 1')"
    #     connection.execute_query "insert into `Users` (Id, Name) VALUES (2, 'Test 2')"
    #     connection.run_batch
    #   rescue StandardError
    #     connection.abort_batch
    #     raise
    #   end
    def start_batch_dml
      if @ddl_batch || @dml_batch
        raise Google::Cloud::FailedPreconditionError, "A batch is already active on this connection"
      end
      @dml_batch = []
    end

    ##
    # Aborts the current batch on this connection. This is a no-op if there is no batch on this connection.
    #
    # @see start_batch_ddl
    def abort_batch
      @ddl_batch = nil
      @dml_batch = nil
    end

    ##
    # Runs the current batch on this connection. This will raise a FailedPreconditionError if there is no
    # active batch on this connection.
    #
    # @see start_batch_ddl
    def run_batch
      unless @ddl_batch || @dml_batch
        raise Google::Cloud::FailedPreconditionError, "There is no batch active on this connection"
      end
      # Just return if the batch is empty.
      return true if @ddl_batch&.empty? || @dml_batch&.empty?
      begin
        if @ddl_batch
          run_ddl_batch
        else
          run_dml_batch
        end
      end
    end

    def run_ddl_batch
      return true if @ddl_batch.empty?
      begin
        execute_ddl_statements @ddl_batch, nil, true
      ensure
        @ddl_batch = nil
      end
    end

    def run_dml_batch
      return true if @dml_batch.empty?
      begin
        # Execute the DML statements in the batch.
        execute_dml_statements_in_batch @dml_batch
      ensure
        @dml_batch = nil
      end
    end

    ##
    # Executes a set of DML statements as one batch. This method raises an error if no block is given.
    def dml_batch
      raise Google::Cloud::FailedPreconditionError, "No block given for the DML batch" unless block_given?
      begin
        start_batch_dml
        yield
        run_batch
      rescue StandardError
        abort_batch
        raise
      ensure
        @dml_batch = nil
      end
    end

    # DQL, DML Statements

    def execute_query sql, params: nil, types: nil, single_use_selector: nil, request_options: nil, statement_type: nil
      # Clear the transaction from the previous statement.
      unless current_transaction&.active?
        self.current_transaction = nil
      end
      if statement_type == :dml && dml_batch?
        @dml_batch.push({ sql: sql, params: params, types: types })
        return
      end
      if params
        converted_params, types =
          Google::Cloud::Spanner::Convert.to_input_params_and_types(
            params, types
          )
      end

      selector = transaction_selector || single_use_selector
      execute_sql_request sql, converted_params, types, selector, request_options
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def execute_sql_request sql, converted_params, types, selector, request_options = nil
      res = session.execute_query \
        sql,
        params: converted_params,
        types: types,
        transaction: selector,
        request_options: request_options,
        seqno: current_transaction&.next_sequence_number
      current_transaction.grpc_transaction = res.metadata.transaction \
          if current_transaction && res&.metadata&.transaction
      res
    rescue Google::Cloud::AbortedError
      # Mark the current transaction as aborted to prevent any unnecessary further requests on the transaction.
      current_transaction&.mark_aborted
      raise
    rescue Google::Cloud::NotFoundError => e
      if session_not_found?(e) || transaction_not_found?(e)
        reset!
        # Force a retry of the entire transaction if this statement was executed as part of a transaction.
        # Otherwise, just retry the statement itself.
        raise_aborted_err if current_transaction&.active?
        retry
      end
      raise
    rescue Google::Cloud::Error => e
      if TransactionMutationLimitExceededError.is_mutation_limit_error? e
        raise
      end
      # Check if it was the first statement in a transaction that included a BeginTransaction
      # option in the request. If so, execute an explicit BeginTransaction and then retry the
      # request without the BeginTransaction option.
      if current_transaction && selector&.begin&.read_write
        selector = create_transaction_after_failed_first_statement e
        retry
      end
      # It was not the first statement, so propagate the error.
      raise
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # Creates a transaction using a BeginTransaction RPC. This is used if the first statement of a
    # transaction fails, as that also means that no transaction id was returned.
    def create_transaction_after_failed_first_statement original_error
      transaction = current_transaction.force_begin_read_write
      Google::Cloud::Spanner::V1::TransactionSelector.new id: transaction.transaction_id
    rescue Google::Cloud::Error
      # Raise the original error if the BeginTransaction RPC also fails.
      raise original_error
    end

    # Transactions

    def begin_transaction isolation = nil, **options
      raise "Nested transactions are not allowed" if current_transaction&.active?
      exclude_from_streams = options.fetch :exclude_txn_from_change_streams, false
      self.current_transaction = Transaction.new self, isolation || @isolation_level,
                                                 exclude_txn_from_change_streams: exclude_from_streams
      current_transaction.begin
      current_transaction
    end

    def commit_transaction
      raise "This connection does not have a transaction" unless current_transaction
      current_transaction.commit
    end

    def rollback_transaction
      raise "This connection does not have a transaction" unless current_transaction
      current_transaction.rollback
    end

    def transaction_selector
      current_transaction&.transaction_selector if current_transaction&.active?
    end

    def truncate table_name
      session.delete table_name
    end

    def self.database_path config
      "#{config[:emulator_host]}/#{config[:project]}/#{config[:instance]}/#{config[:database]}"
    end

    def session_not_found? err
      if err.respond_to?(:metadata) && err.metadata["google.rpc.resourceinfo-bin"]
        resource_info = Google::Rpc::ResourceInfo.decode err.metadata["google.rpc.resourceinfo-bin"]
        type = resource_info["resource_type"]
        return "type.googleapis.com/google.spanner.v1.Session".eql? type
      end
      false
    end

    def transaction_not_found? err
      if err.respond_to?(:metadata) && err.metadata["google.rpc.resourceinfo-bin"]
        resource_info = Google::Rpc::ResourceInfo.decode err.metadata["google.rpc.resourceinfo-bin"]
        type = resource_info["resource_type"]
        return "type.googleapis.com/google.spanner.v1.Transaction".eql? type
      end
      false
    end

    def raise_aborted_err
      retry_info = Google::Rpc::RetryInfo.new retry_delay: Google::Protobuf::Duration.new(seconds: 0, nanos: 1)
      begin
        raise GRPC::BadStatus.new(
          GRPC::Core::StatusCodes::ABORTED,
          "Transaction aborted",
          "google.rpc.retryinfo-bin": Google::Rpc::RetryInfo.encode(retry_info)
        )
      rescue GRPC::BadStatus
        raise Google::Cloud::AbortedError
      end
    end

    private

    def execute_ddl_statements statements, operation_id, wait_until_done
      job = database.update statements: statements, operation_id: operation_id
      job.wait_until_done! if wait_until_done
      raise Google::Cloud::Error.from_error job.error if job.error?
      job.done?
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def execute_dml_statements_in_batch statements
      selector = transaction_selector
      response = session.batch_update selector, current_transaction&.next_sequence_number do |batch|
        statements.each do |statement|
          batch.batch_update statement[:sql], params: statement[:params], types: statement[:types]
        end
      end
      batch_update_results = Google::Cloud::Spanner::BatchUpdateResults.new response
      first_res = response.result_sets.first
      current_transaction.grpc_transaction = first_res.metadata.transaction \
        if current_transaction && first_res&.metadata&.transaction
      batch_update_results.row_counts
    rescue Google::Cloud::AbortedError
      # Mark the current transaction as aborted to prevent any unnecessary further requests on the transaction.
      current_transaction&.mark_aborted
      raise
    rescue Google::Cloud::Spanner::BatchUpdateError => e
      # Check if the status is ABORTED, and if it is, just propagate an AbortedError.
      if e.cause&.code == GRPC::Core::StatusCodes::ABORTED
        current_transaction&.mark_aborted
        raise e.cause
      end

      # Check if the request returned a transaction or not.
      # BatchDML is capable of returning BOTH an error and a transaction.
      if current_transaction && !current_transaction.grpc_transaction? && selector&.begin&.read_write
        selector = create_transaction_after_failed_first_statement e
        retry
      end
      # It was not the first statement, or it returned a transaction, so propagate the error.
      raise
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity


    ##
    # Retrieves the delay value from Google::Cloud::AbortedError or
    # GRPC::Aborted
    def delay_from_aborted err
      return nil if err.nil?
      if err.respond_to?(:metadata) && err.metadata["google.rpc.retryinfo-bin"]
        retry_info = Google::Rpc::RetryInfo.decode err.metadata["google.rpc.retryinfo-bin"]
        seconds = retry_info["retry_delay"].seconds
        nanos = retry_info["retry_delay"].nanos
        return seconds if nanos.zero?
        return seconds + (nanos / 1_000_000_000.0)
      end
      # No metadata? Try the inner error
      delay_from_aborted err.cause
    rescue StandardError
      # Any error indicates the backoff should be handled elsewhere
      nil
    end
  end
end
