class ProviderProject < ApplicationRecord
  belongs_to :provider, optional: true
  has_many :projects_provider_projects, dependent: :destroy
  has_many :projects, through: :projects_provider_projects
  
  # Scopes
  scope :by_key, ->(key) { where("key ILIKE ?", "%#{key}%") if key.present? }
  scope :by_title, ->(title) { where("title ILIKE ?", "%#{title}%") if title.present? }
  
  # Instance methods
  def display_key
    key.presence || "Unknown key"
  end
  
  def display_title
    title.presence || "Untitled"
  end
  
  def parsed_attrs
    return {} unless attrs_json.present?
    JSON.parse(attrs_json) rescue {}
  end
end
