class ComplianceSchema < ApplicationRecord
  scope :active, -> { where(active: true) }
  scope :obsolete, -> { where(active: false) }

  scope :for_project_type, ->(tag) {
    return none if tag.blank?
    where("project_type_tags LIKE ?", "%#{tag}%")
  }

  validates :name, presence: true
  validates :project_type_tags, presence: true

  def requires_public?
    if_compliant.to_s.split(',').map(&:strip).include?('allow_public')
  end

  # Return a hash matching the shape previously stored in env_json,
  # so that existing view code can consume it without changes.
  def to_config_hash
    {
      'name' => name,
      'version' => version,
      'source_schema_name' => source_schema_name,
      'description' => description,
      'source_url' => source_url,
      'url' => url,
      'compliant_icon' => compliant_icon,
      'not_compliant_icon' => not_compliant_icon,
      'if_compliant' => if_compliant.to_s.split(',').map(&:strip)
    }
  end
end
