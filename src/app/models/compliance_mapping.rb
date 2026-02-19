class ComplianceMapping < ApplicationRecord
  belongs_to :project
  belongs_to :compliance_schema, optional: true
  belongs_to :source_annot, class_name: 'Annot', optional: true
  belongs_to :ontology_term_type, optional: true

  has_many :compliance_term_replacements, dependent: :destroy

  validates :field_group_id, presence: true
  validates :target_path, presence: true
  validates :action_type, presence: true, inclusion: { in: %w[map_from resolve_paired set_value] }

  # Parse the resolve map from JSON
  def resolve_map
    return {} if resolve_map_json.blank?
    JSON.parse(resolve_map_json) rescue {}
  end

  # Set the resolve map as JSON
  def resolve_map=(hash)
    self.resolve_map_json = hash.to_json
  end
end
