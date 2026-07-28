# frozen_string_literal: true

class RemoteGeneSet < Asap2RemoteRecord
  self.table_name = "gene_sets"

  belongs_to :remote_organism, foreign_key: :organism_id, class_name: "RemoteOrganism", optional: true
  has_many :remote_gene_set_items, foreign_key: :gene_set_id, class_name: "RemoteGeneSetItem"
end
