class AddProjectIdIndexesForSummary < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :clas, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :runs, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :shares, :project_id, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :clas, :project_id, algorithm: :concurrently, if_exists: true
    remove_index :runs, :project_id, algorithm: :concurrently, if_exists: true
    remove_index :shares, :project_id, algorithm: :concurrently, if_exists: true
  end
end
