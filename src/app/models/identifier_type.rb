class IdentifierType < ApplicationRecord
  has_many :exp_entries, dependent: :destroy
  
  # Scopes
  scope :by_name, ->(name) { where("name ILIKE ?", "%#{name}%") if name.present? }
  
  # Instance methods
  def display_name
    name.presence || "Unknown Type"
  end
end


