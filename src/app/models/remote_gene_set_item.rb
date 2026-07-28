# frozen_string_literal: true

class RemoteGeneSetItem < Asap2RemoteRecord
  self.table_name = "gene_set_items"

  belongs_to :remote_gene_set, foreign_key: :gene_set_id, class_name: "RemoteGeneSet", optional: true
end
