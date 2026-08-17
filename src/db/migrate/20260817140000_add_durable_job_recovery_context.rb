# frozen_string_literal: true

class AddDurableJobRecoveryContext < ActiveRecord::Migration[8.0]
  def change
    add_column :fus, :compliance_schema_id, :string
    add_column :fus, :compliance_task_id, :string
    add_index :fus, :compliance_task_id

    add_column :projects, :being_cloned, :boolean, default: false, null: false
    add_column :projects, :being_validated, :boolean, default: false, null: false

    add_column :gene_set_collections, :import_id, :string
    add_index :gene_set_collections, :import_id

    create_table :module_score_requests do |t|
      t.string :request_id, null: false
      t.integer :project_id, null: false
      t.integer :user_id
      t.string :item_id, null: false
      t.string :loom_file, null: false
      t.string :dataset, null: false
      t.string :status, null: false
      t.string :result_path
      t.text :error_message
      t.integer :pid
      t.timestamps
    end
    add_index :module_score_requests, :request_id, unique: true
    add_index :module_score_requests, :project_id
    add_index :module_score_requests, :status
  end
end
