class CreateDataTransformations < ActiveRecord::Migration[8.0]
  def up
    create_table :data_transformations do |t|
      t.string :name, null: false
      t.string :label, null: false
      t.text :description
      t.timestamps
    end

    execute <<~SQL
      INSERT INTO data_transformations (id, name, label, description, created_at, updated_at) VALUES
        (1, 'none', 'No log transformation',
         'The expression matrix is not in log-transformed space. Values are raw counts or linearly normalized only (e.g. relative counts without log1p). Maps from output.json is_log_transformed: false.',
         NOW(), NOW()),
        (2, 'log10', 'log10',
         'Log-transformed with base 10 (e.g. log10(x+1)). Maps from output.json is_log_transformed: true with log_base 10.0 or log_type containing "log10".',
         NOW(), NOW()),
        (3, 'log2', 'log2',
         'Log-transformed with base 2 (e.g. log2(x+1)). Maps from output.json is_log_transformed: true with log_base 2.0 or log_type containing "log2".',
         NOW(), NOW()),
        (4, 'ln', 'ln (natural log)',
         'Log-transformed with natural log (ln / log1p). Maps from output.json is_log_transformed: true with log_base null or log_type describing natural log (typical for Seurat LogNormalize, CLR, Scanpy --log without --log_base).',
         NOW(), NOW());
    SQL

    execute "SELECT setval('data_transformations_id_seq', 4)"
  end

  def down
    drop_table :data_transformations
  end
end
