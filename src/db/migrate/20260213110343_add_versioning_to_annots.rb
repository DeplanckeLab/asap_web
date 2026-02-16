class AddVersioningToAnnots < ActiveRecord::Migration[7.0]
  def change
    add_column :annots, :version_nber, :integer, default: 1
    add_column :annots, :latest_version, :boolean, default: true
  end
end
