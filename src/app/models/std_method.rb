class StdMethod < ApplicationRecord
  belongs_to :step
  belongs_to :docker_image, optional: true
  has_many :reqs, dependent: :nullify
  has_many :runs, dependent: :nullify
end
