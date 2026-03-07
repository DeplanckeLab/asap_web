class AddIconToGeneSetCollectionTypes < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  ICON_BY_KEY = {
    'manual' => 'fas fa-pen',
    'imported' => 'fas fa-file-import',
    'from_de' => 'fas fa-chart-line',
    'from_find_markers' => 'fas fa-magnifying-glass'
  }.freeze

  def up
    add_column :gene_set_collection_types, :icon, :string

    MigrationGeneSetCollectionType.reset_column_information
    ICON_BY_KEY.each do |type_key, icon_value|
      MigrationGeneSetCollectionType.where(key: type_key).update_all(icon: icon_value)
    end

    MigrationGeneSetCollectionType.where(icon: [nil, '']).update_all(icon: 'fas fa-layer-group')
    change_column_null :gene_set_collection_types, :icon, false
  end

  def down
    remove_column :gene_set_collection_types, :icon
  end
end
