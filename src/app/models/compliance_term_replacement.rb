class ComplianceTermReplacement < ApplicationRecord
  belongs_to :compliance_mapping
  belongs_to :cell_ontology_term, optional: true

  validates :original_value, presence: true
end
