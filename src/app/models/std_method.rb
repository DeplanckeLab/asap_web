class StdMethod < ApplicationRecord
  belongs_to :step
  belongs_to :docker_image, optional: true
end

