class AddOntologyTermTypeIdToComplianceMappings < ActiveRecord::Migration[7.0]
  def change
    add_column :compliance_mappings, :ontology_term_type_id, :integer
    add_index :compliance_mappings, :ontology_term_type_id
    add_foreign_key :compliance_mappings, :ontology_term_types,
                    name: 'compliance_mappings_ontology_term_type_id_fkey'
  end
end
