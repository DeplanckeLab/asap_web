class CreateComplianceValidations < ActiveRecord::Migration[7.2]
  def change
    create_table :compliance_validations do |t|
      t.integer :project_id, null: false
      t.integer :compliance_schema_id
      t.boolean :passed, null: false, default: false
      t.integer :errors_count, null: false, default: 0
      t.integer :warnings_count, null: false, default: 0
      t.integer :valid_checks_count, null: false, default: 0
      t.string :result_digest, limit: 32
      t.datetime :validated_at, null: false

      t.timestamps
    end

    add_index :compliance_validations, :project_id
    add_index :compliance_validations, :compliance_schema_id
    add_index :compliance_validations, [:project_id, :validated_at]
  end
end
