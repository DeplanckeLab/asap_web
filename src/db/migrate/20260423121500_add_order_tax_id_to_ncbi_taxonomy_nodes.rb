# frozen_string_literal: true

class AddOrderTaxIdToNcbiTaxonomyNodes < ActiveRecord::Migration[7.0]
  def change
    return unless table_exists?(:ncbi_taxonomy_nodes)

    unless column_exists?(:ncbi_taxonomy_nodes, :order_tax_id)
      add_column :ncbi_taxonomy_nodes, :order_tax_id, :integer
      add_index :ncbi_taxonomy_nodes, :order_tax_id
    end
  end
end
