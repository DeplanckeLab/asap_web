class AddLabelTemplateToDataClasses < ActiveRecord::Migration[7.0]
  def up
    # Only run on primary database (data_classes table doesn't exist in remote databases)
    return unless connection.table_exists?(:data_classes)
    
    # Check if column already exists (in case migration was partially run)
    unless connection.column_exists?(:data_classes, :label_template)
      add_column :data_classes, :label_template, :string
    end

    # Populate label templates
    # Templates can use {row_label} and {col_label} placeholders that get replaced with project type values
    # nil means the data class should not be displayed in messages
    templates = {
      'dataset' => nil,  # Don't display "dataset" as it's redundant
      'int_matrix' => 'integer matrix',
      'num_matrix' => 'numeric matrix',
      'matrix' => 'matrix',
      'mdata' => 'metadata',
      'col_mdata' => '{col_label} metadata',
      'row_mdata' => '{row_label} metadata',
      'numeric_mdata' => 'numeric metadata',
      'discrete_mdata' => 'discrete metadata',
      'string_mdata' => 'string metadata',
      'global_mdata' => 'global metadata',
      'not_handled_mdata' => 'unhandled metadata'
    }

    templates.each do |name, template|
      DataClass.where(name: name).update_all(label_template: template)
    end
  end

  def down
    return unless connection.table_exists?(:data_classes)
    return unless connection.column_exists?(:data_classes, :label_template)
    
    remove_column :data_classes, :label_template
  end
end
