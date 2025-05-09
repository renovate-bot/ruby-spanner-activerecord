# Copyright 2025 Google LLC
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.

module MockServerTests
  class TableWithIdentity < ActiveRecord::Base
    self.table_name = :table_with_identity
  end
end
