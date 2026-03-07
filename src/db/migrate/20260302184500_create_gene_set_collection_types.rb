class CreateGeneSetCollectionTypes < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  class MigrationGeneSetCollection < ApplicationRecord
    self.table_name = 'gene_set_collections'
  end

  TYPE_ROWS = [
    { key: 'manual', label: 'Manual' },
    { key: 'imported', label: 'Imported' },
    { key: 'from_de', label: 'From DE' },
    { key: 'from_find_markers', label: 'From FindMarkers' }
  ].freeze

  def up
    create_table :gene_set_collection_types do |t|
      t.string :key, null: false
      t.string :label, null: false

      t.timestamps
    end

    add_index :gene_set_collection_types, :key, unique: true
    add_reference :gene_set_collections, :gene_set_collection_type, foreign_key: true

    now = Time.current
    TYPE_ROWS.each do |row|
      MigrationGeneSetCollectionType.create!(
        key: row[:key],
        label: row[:label],
        created_at: now,
        updated_at: now
      )
    end

    manual_type_id = MigrationGeneSetCollectionType.find_by!(key: 'manual').id
    imported_type_id = MigrationGeneSetCollectionType.find_by!(key: 'imported').id

    MigrationGeneSetCollection.reset_column_information
    MigrationGeneSetCollection.find_each do |collection|
      normalized_kind = collection.source_kind.to_s.strip.downcase
      mapped_type_id = normalized_kind == 'manual' ? manual_type_id : imported_type_id
      collection.update_columns(gene_set_collection_type_id: mapped_type_id)
    end

    change_column_null :gene_set_collections, :gene_set_collection_type_id, false
    add_index :gene_set_collections, [:project_id, :gene_set_collection_type_id], name: 'index_gene_set_collections_on_project_and_type'
  end

  def down
    remove_index :gene_set_collections, name: 'index_gene_set_collections_on_project_and_type'
    remove_reference :gene_set_collections, :gene_set_collection_type, foreign_key: true
    drop_table :gene_set_collection_types
  end
end
