class AddExportedProjectIdToProjects < ActiveRecord::Migration[7.1]
  def change
    add_column :projects, :exported_project_id, :integer
    add_index :projects, :exported_project_id
    add_foreign_key :projects, :projects, column: :exported_project_id
  end
end
