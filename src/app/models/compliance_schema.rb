class ComplianceSchema < ApplicationRecord
  scope :active, -> { where(active: true) }
  scope :obsolete, -> { where(active: false) }

  scope :for_project_type, ->(tag) {
    return none if tag.blank?

    where(
      "? = ANY (string_to_array(regexp_replace(COALESCE(project_type_tags, ''), '\\s+', '', 'g'), ','))",
      tag.to_s
    )
  }

  validates :name, presence: true
  validates :project_type_tags, presence: true

  def self.parse_tags(raw)
    raw.to_s.split(',').map { |t| t.strip }.reject(&:blank?)
  end

  # scFAIR applies to every sc-like project type (sc, spat, atac, multi).
  # Schemas that already list `sc` get the rest of SC_LIKE_TAGS.
  def self.ensure_sc_like_project_types!
    updated = 0
    find_each do |cs|
      current = parse_tags(cs.project_type_tags)
      next unless current.include?('sc')

      merged = current | ProjectType::SC_LIKE_TAGS
      next if merged == current

      cs.update!(project_type_tags: merged.join(','))
      updated += 1
    end
    updated
  end

  def tags
    self.class.parse_tags(project_type_tags)
  end

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
