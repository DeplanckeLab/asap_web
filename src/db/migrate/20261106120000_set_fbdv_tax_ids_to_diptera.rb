# frozen_string_literal: true

# cell_ontologies.tax_ids now lists clade nodes (organism = node or descendant, see CellOntology#applies_to_tax_id?).
# FBdv is used for Diptera (e.g. Aedes), matching rules.yaml cross_field.organism_dev_stage_mapping.
class SetFbdvTaxIdsToDiptera < ActiveRecord::Migration[7.2]
  DIPTERA = "7147"
  D_MELANOGASTER = "7227"

  def up
    execute("UPDATE cell_ontologies SET tax_ids = '#{DIPTERA}' WHERE tag = 'FBdv'")
  end

  def down
    execute("UPDATE cell_ontologies SET tax_ids = '#{D_MELANOGASTER}' WHERE tag = 'FBdv'")
  end
end
