class AddPreparsingVersionIdToFus < ActiveRecord::Migration[8.1]
  def change
    add_column :fus, :preparsing_version_id, :integer
    add_index :fus, :preparsing_version_id
  end
end
