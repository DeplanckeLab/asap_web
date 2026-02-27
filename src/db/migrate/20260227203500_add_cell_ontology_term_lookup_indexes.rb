class AddCellOntologyTermLookupIndexes < ActiveRecord::Migration[7.2]
  def up
    unless index_exists?(:cell_ontology_terms, [:original, :identifier], name: "idx_cot_original_identifier")
      add_index :cell_ontology_terms, [:original, :identifier], name: "idx_cot_original_identifier"
    end

    unless index_exists?(:cell_ontology_terms, [:original, :name], name: "idx_cot_original_name")
      add_index :cell_ontology_terms, [:original, :name], name: "idx_cot_original_name"
    end
  end

  def down
    remove_index :cell_ontology_terms, name: "idx_cot_original_name" if index_exists?(:cell_ontology_terms, [:original, :name], name: "idx_cot_original_name")
    remove_index :cell_ontology_terms, name: "idx_cot_original_identifier" if index_exists?(:cell_ontology_terms, [:original, :identifier], name: "idx_cot_original_identifier")
  end
end
