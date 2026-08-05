class AddObsoleteToOrganisms < ActiveRecord::Migration[8.1]
  def change
    add_column :organisms, :obsolete, :boolean, default: false, null: false
    add_index :organisms, :obsolete
  end
end
