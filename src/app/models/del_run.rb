class DelRun < ApplicationRecord
  belongs_to :project
  belongs_to :docker_build, optional: true
end




