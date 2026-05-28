class AddDataTransformationIdToAnnots < ActiveRecord::Migration[8.0]
  def change
    add_column :annots, :data_transformation_id, :integer, null: true
    add_foreign_key :annots, :data_transformations
    add_index :annots, :data_transformation_id
  end
end
