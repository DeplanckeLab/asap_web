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

  # URL of this project on the provider's website (attrs source_page_url, else url_mask + key).
  def source_page_url
    url = parsed_attrs['source_page_url'].to_s.presence
    return url if url.present?
    return nil unless provider&.url_mask.present? && key.present?

    provider.url_mask.gsub('#{id}', key.to_s)
  end
end


