class OttProject < ApplicationRecord
  belongs_to :project
  belongs_to :ontology_term_type
end
