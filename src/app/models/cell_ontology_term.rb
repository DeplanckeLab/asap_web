class CellOntologyTerm < ApplicationRecord
  belongs_to :cell_ontology

  scope :original, -> { where(original: true) }

  # Metadata label resolution (e.g. ASAP auto CLAs) must ignore obsolete terms and
  # terms whose parent ontology is obsolete (cell_ontologies.obsolete), so disabled
  # ontologies such as CARO do not compete with UBERON and similar.
  scope :with_active_cell_ontology, -> {
    where(obsolete: false)
      .joins(:cell_ontology)
      .where(cell_ontologies: { obsolete: false })
  }
end


