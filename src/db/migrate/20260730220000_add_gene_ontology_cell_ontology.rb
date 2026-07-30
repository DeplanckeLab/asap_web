# frozen_string_literal: true

class AddGeneOntologyCellOntology < ActiveRecord::Migration[7.2]
  GO_TAG = "GO"

  def up
    go = CellOntology.find_or_initialize_by(tag: GO_TAG)
    go.assign_attributes(
      name: "Gene Ontology",
      format: "obo",
      tax_ids: "",
      url: "https://geneontology.org",
      file_url: "http://purl.obolibrary.org/obo/go.obo",
      url_mask: 'https://amigo.geneontology.org/amigo/term/#{id}',
      obsolete: false
    )
    go.save!
  end

  def down
    go = CellOntology.find_by(tag: GO_TAG)
    return unless go

    # Only remove if this migration created a GO row without terms.
    return if CellOntologyTerm.where(cell_ontology_id: go.id).exists?

    go.destroy!
  end
end
