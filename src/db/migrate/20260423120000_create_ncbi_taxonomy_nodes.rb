# frozen_string_literal: true

class CreateNcbiTaxonomyNodes < ActiveRecord::Migration[7.0]
  def change
    create_table :ncbi_taxonomy_nodes, id: false do |t|
      t.integer :tax_id, null: false, primary_key: true
      t.integer :parent_tax_id
      t.integer :order_tax_id
      t.string :rank, null: false, default: ""
      t.string :scientific_name, null: false, default: ""
      t.timestamps
    end

    add_index :ncbi_taxonomy_nodes, :parent_tax_id
    add_index :ncbi_taxonomy_nodes, :order_tax_id
    add_index :ncbi_taxonomy_nodes, :rank
  end
end
