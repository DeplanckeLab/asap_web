class ExpEntry < ApplicationRecord
  belongs_to :identifier_type, optional: true
  has_many :exp_entries_projects, dependent: :destroy
  has_many :projects, through: :exp_entries_projects
  has_many :exp_entries_sample_identifiers, dependent: :destroy
  has_many :sample_identifiers, through: :exp_entries_sample_identifiers
  
  # Scopes
  scope :by_identifier, ->(identifier) { where("identifier ILIKE ?", "%#{identifier}%") if identifier.present? }
  scope :by_doi, ->(doi) { where("doi ILIKE ?", "%#{doi}%") if doi.present? }
  
  # Instance methods
  def display_identifier
    identifier.presence || "Unknown identifier"
  end
  
  def display_title
    title.presence || "Untitled"
  end
  
  def display_contributors
    contributors.presence || "Unknown contributors"
  end
  
  def parsed_identifiers
    return {} unless identifiers_json.present?
    JSON.parse(identifiers_json) rescue {}
  end
end

