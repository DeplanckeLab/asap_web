class AddOntologyTermTypeIdToClas < ActiveRecord::Migration[7.0]
  def change
    add_column :clas, :ontology_term_type_id, :integer
    add_index :clas, :ontology_term_type_id
    add_foreign_key :clas, :ontology_term_types, name: 'clas_ontology_term_type_id_fkey'
  end
end
