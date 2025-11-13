class Version < ApplicationRecord
  scope :activated, -> { where(activated: true) }
end

