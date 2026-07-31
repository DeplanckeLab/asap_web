class AddKindAndRunToCheckpoints < ActiveRecord::Migration[7.2]
  def change
    add_column :checkpoints, :kind, :string, null: false, default: "visualization"
    add_column :checkpoints, :run_id, :integer

    add_index :checkpoints, :kind
    add_index :checkpoints, [:project_id, :kind, :run_id], name: "index_checkpoints_on_project_kind_run"
    add_index :checkpoints, :run_id

    add_foreign_key :checkpoints, :runs
  end
end
