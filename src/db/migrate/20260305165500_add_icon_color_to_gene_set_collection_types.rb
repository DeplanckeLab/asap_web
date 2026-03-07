class AddIconColorToGeneSetCollectionTypes < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  COLOR_BY_KEY = {
    'manual' => '#2563eb',
    'imported' => '#6b7280',
    'from_de' => '#7c3aed',
    'from_find_markers' => '#d97706'
  }.freeze

  def up
    add_column :gene_set_collection_types, :icon_color, :string

    MigrationGeneSetCollectionType.reset_column_information
    COLOR_BY_KEY.each do |type_key, color_value|
      MigrationGeneSetCollectionType.where(key: type_key).update_all(icon_color: color_value)
    end

    MigrationGeneSetCollectionType.where(icon_color: [nil, '']).update_all(icon_color: '#6b7280')
    change_column_null :gene_set_collection_types, :icon_color, false
  end

  def down
    remove_column :gene_set_collection_types, :icon_color
  end
end
