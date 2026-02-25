class CreateCheckpoints < ActiveRecord::Migration[7.2]
  def change
    create_table :checkpoints do |t|
      t.integer :project_id, null: false
      t.integer :user_id
      t.string :title, null: false
      t.text :state_json, null: false, default: "{}"
      t.text :comments_json, null: false, default: "[]"

      t.timestamps
    end

    add_index :checkpoints, :project_id
    add_index :checkpoints, :user_id
    add_foreign_key :checkpoints, :projects
    add_foreign_key :checkpoints, :users
  end
end
