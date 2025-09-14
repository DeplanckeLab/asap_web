class Provider < ApplicationRecord
  has_many :provider_projects, dependent: :destroy
  
  # Scopes
  scope :by_name, ->(name) { where("name ILIKE ?", "%#{name}%") if name.present? }
  scope :by_tag, ->(tag) { where("tag ILIKE ?", "%#{tag}%") if tag.present? }
  
  # Instance methods
  def display_name
    name.presence || "Unknown Provider"
  end
  
  def display_url_mask
    url_mask.presence || ""
  end
  
  def parsed_attrs
    return {} unless attrs_json.present?
    JSON.parse(attrs_json) rescue {}
  end
end


