class Rating < ApplicationRecord
  belongs_to :user

  validates :stars, presence: true, inclusion: { in: 1..5 }
  validates :review, length: { maximum: 5000 }
end
