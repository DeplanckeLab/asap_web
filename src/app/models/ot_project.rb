class OtProject < ApplicationRecord
  belongs_to :project
  belongs_to :cell_ontology_term, optional: true
  belongs_to :ontology_term_type
  belongs_to :annot, optional: true
end
