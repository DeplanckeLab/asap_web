class AddDescriptionToDataTransformations < ActiveRecord::Migration[8.0]
  DESCRIPTIONS = {
    'none' => {
      label: 'No log transformation',
      description: 'The expression matrix is not in log-transformed space. Values are raw counts or linearly normalized only (e.g. relative counts without log1p). Maps from output.json is_log_transformed: false.'
    },
    'log10' => {
      label: 'log10',
      description: 'Log-transformed with base 10 (e.g. log10(x+1)). Maps from output.json is_log_transformed: true with log_base 10.0 or log_type containing "log10".'
    },
    'log2' => {
      label: 'log2',
      description: 'Log-transformed with base 2 (e.g. log2(x+1)). Maps from output.json is_log_transformed: true with log_base 2.0 or log_type containing "log2".'
    },
    'ln' => {
      label: 'ln (natural log)',
      description: 'Log-transformed with natural log (ln / log1p). Maps from output.json is_log_transformed: true with log_base null or log_type describing natural log (typical for Seurat LogNormalize, CLR, Scanpy --log without --log_base).'
    }
  }.freeze

  def up
    # CreateDataTransformations may already include description + seed rows
    # (schema folded into the create migration after this one was written).
    add_column :data_transformations, :description, :text unless column_exists?(:data_transformations, :description)

    DESCRIPTIONS.each do |name, attrs|
      execute <<~SQL.squish
        UPDATE data_transformations
        SET label = #{connection.quote(attrs[:label])},
            description = #{connection.quote(attrs[:description])},
            updated_at = NOW()
        WHERE name = #{connection.quote(name)}
      SQL
    end
  end

  def down
    remove_column :data_transformations, :description if column_exists?(:data_transformations, :description)
  end
end
