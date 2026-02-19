class AddComplianceSchemaIdToComplianceMappings < ActiveRecord::Migration[7.2]
  def change
    add_column :compliance_mappings, :compliance_schema_id, :integer
    add_index :compliance_mappings, :compliance_schema_id
  end
end
