class CreateComplianceSchemas < ActiveRecord::Migration[7.2]
  def change
    create_table :compliance_schemas do |t|
      t.string :name, null: false
      t.string :version
      t.string :source_schema_name
      t.text :description
      t.string :source_url
      t.string :url
      t.string :compliant_icon
      t.string :not_compliant_icon
      t.string :project_type_tags, null: false
      t.string :if_compliant
      t.boolean :active, null: false, default: true
      t.datetime :started_at
      t.datetime :ended_at

      t.timestamps
    end

    add_index :compliance_schemas, :active
  end
end
