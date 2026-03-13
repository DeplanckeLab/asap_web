class GuidedTourStep < ApplicationRecord
  belongs_to :guided_tour, inverse_of: :guided_tour_steps

  validates :page_url, presence: true
  validates :title, presence: true
  validates :focus_element, presence: true
  validates :rank, presence: true, numericality: { only_integer: true, greater_than: 0 }

  before_validation :assign_rank, on: :create

  scope :ordered, -> { order(:rank, :id) }

  private

  def assign_rank
    return if rank.present? || guided_tour.nil?

    self.rank = (guided_tour.guided_tour_steps.maximum(:rank) || 0) + 1
  end
end
