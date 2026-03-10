class OrcidUser < ApplicationRecord
  has_many :users

  validates :key, presence: true
end
