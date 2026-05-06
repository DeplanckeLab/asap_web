class GuidedTour < ApplicationRecord
  has_many :guided_tour_steps, -> { order(:rank, :id) }, dependent: :destroy, inverse_of: :guided_tour

  validates :name, presence: true
  validates :rank, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :duration_time, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  before_validation :assign_rank, on: :create

  scope :ordered, -> { order(:rank, :id) }
  scope :visible, -> { where(hidden: false) }

  private

  def assign_rank
    return if rank.present?

    self.rank = (GuidedTour.maximum(:rank) || 0) + 1
  end
end
