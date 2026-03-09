class CreateProjectViewLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :project_view_logs do |t|
      t.references :project, null: false, foreign_key: true
      t.string :viewer_token, null: false, limit: 128
      t.date :viewed_on, null: false

      t.timestamps
    end

    add_index :project_view_logs,
              [:project_id, :viewer_token, :viewed_on],
              unique: true,
              name: 'idx_pvl_on_project_viewer_day'
    add_index :project_view_logs, [:project_id, :viewed_on]
  end
end
