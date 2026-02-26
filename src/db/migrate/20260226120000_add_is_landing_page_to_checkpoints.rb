class AddIsLandingPageToCheckpoints < ActiveRecord::Migration[7.2]
  def change
    add_column :checkpoints, :is_landing_page, :boolean, null: false, default: false
    add_index :checkpoints,
              :project_id,
              unique: true,
              where: "is_landing_page = true",
              name: "index_checkpoints_one_landing_page_per_project"
  end
end
