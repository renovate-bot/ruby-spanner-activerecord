# Copyright 2021 Google LLC
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.

module TestMigrationsWithMockServer
  class Track < ActiveRecord::Base
    belongs_to :album
  end
end
