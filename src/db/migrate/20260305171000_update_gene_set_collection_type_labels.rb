class UpdateGeneSetCollectionTypeLabels < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  LABEL_BY_KEY = {
    'manual' => 'Manual',
    'imported' => 'Imported',
    'from_de' => 'From DE results',
    'from_find_markers' => 'From Find markers'
  }.freeze

  def up
    LABEL_BY_KEY.each do |type_key, type_label|
      MigrationGeneSetCollectionType.where(key: type_key).update_all(label: type_label)
    end
  end

  def down
    MigrationGeneSetCollectionType.where(key: 'manual').update_all(label: 'Manual')
    MigrationGeneSetCollectionType.where(key: 'imported').update_all(label: 'Imported')
    MigrationGeneSetCollectionType.where(key: 'from_de').update_all(label: 'From DE')
    MigrationGeneSetCollectionType.where(key: 'from_find_markers').update_all(label: 'From FindMarkers')
  end
end
