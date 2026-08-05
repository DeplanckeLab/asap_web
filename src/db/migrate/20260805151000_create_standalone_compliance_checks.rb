# frozen_string_literal: true

class CreateStandaloneComplianceChecks < ActiveRecord::Migration[7.2]
  def change
    create_table :standalone_compliance_checks do |t|
      t.integer :user_id
      t.string :filename
      t.text :source_url
      t.string :format
      t.string :schema_id
      t.boolean :passed, null: false, default: false
      t.string :status, null: false, default: 'completed'
      t.jsonb :result_json, null: false, default: {}
      t.string :task_id
      t.integer :fu_id
      t.datetime :checked_at, null: false

      t.timestamps
    end

    add_index :standalone_compliance_checks, :user_id
    add_index :standalone_compliance_checks, :checked_at
    add_index :standalone_compliance_checks, :passed
    add_index :standalone_compliance_checks, :status
    add_index :standalone_compliance_checks, :task_id
    add_index :standalone_compliance_checks, :fu_id
  end
end
