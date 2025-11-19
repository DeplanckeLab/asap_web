class CellOntologyTerm < ApplicationRecord
  belongs_to :cell_ontology

  scope :original, -> { where(original: true) }
end


