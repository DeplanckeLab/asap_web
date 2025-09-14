class Journal < ApplicationRecord
  has_many :articles, dependent: :destroy
  
  # Scopes
  scope :by_name, ->(name) { where("name ILIKE ?", "%#{name}%") if name.present? }
  
  # Instance methods
  def display_name
    name.presence || "Unknown Journal"
  end
end

