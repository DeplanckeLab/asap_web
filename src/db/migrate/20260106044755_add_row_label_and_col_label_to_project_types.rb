class AddRowLabelAndColLabelToProjectTypes < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:project_types)
    
    add_column :project_types, :row_label, :text, null: true unless column_exists?(:project_types, :row_label)
    add_column :project_types, :col_label, :text, null: true unless column_exists?(:project_types, :col_label)
  end

  def down
    return unless table_exists?(:project_types)
    
    remove_column :project_types, :row_label if column_exists?(:project_types, :row_label)
    remove_column :project_types, :col_label if column_exists?(:project_types, :col_label)
  end
end

