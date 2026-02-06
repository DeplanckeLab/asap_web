class AddCategoryToDataClasses < ActiveRecord::Migration[7.0]
  def up
    # Only run on primary database
    return unless connection.table_exists?(:data_classes)
    
    unless connection.column_exists?(:data_classes, :category)
      add_column :data_classes, :category, :string
    end

    # Categories:
    # - 'skip' = don't display (dataset)
    # - 'base' = base dimension type (row_mdata, col_mdata)
    # - 'value_type' = value type modifier (numeric_mdata, discrete_mdata, string_mdata)
    # - 'matrix' = matrix types (num_matrix, int_matrix)
    # - 'other' = other types
    
    # Update templates to be more structured:
    # - Base types use {row_label_singular} or {col_label_singular}
    # - Value types just have the value name (will be combined with "values")
    # - Matrix types have full label
    
    updates = {
      'dataset' => { category: 'skip', label_template: nil },
      'mdata' => { category: 'other', label_template: 'metadata' },
      'row_mdata' => { category: 'base', label_template: '{row_label_singular} metadata' },
      'col_mdata' => { category: 'base', label_template: '{col_label_singular} metadata' },
      'numeric_mdata' => { category: 'value_type', label_template: 'float' },
      'discrete_mdata' => { category: 'value_type', label_template: 'discrete' },
      'string_mdata' => { category: 'value_type', label_template: 'string' },
      'global_mdata' => { category: 'other', label_template: 'global metadata' },
      'not_handled_mdata' => { category: 'skip', label_template: nil },
      'num_matrix' => { category: 'matrix', label_template: 'numeric matrix' },
      'int_matrix' => { category: 'matrix', label_template: 'integer matrix' },
      'matrix' => { category: 'matrix', label_template: 'matrix' }
    }

    updates.each do |name, attrs|
      DataClass.where(name: name).update_all(attrs)
    end
  end

  def down
    return unless connection.table_exists?(:data_classes)
    return unless connection.column_exists?(:data_classes, :category)
    
    remove_column :data_classes, :category
  end
end
