class UpdateGeneSetCollectionTypeIconsForDeAndMarkers < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  def up
    MigrationGeneSetCollectionType.where(key: 'from_de').update_all(icon: 'DE')
    MigrationGeneSetCollectionType.where(key: 'from_find_markers').update_all(icon: 'fas fa-bookmark')
  end

  def down
    MigrationGeneSetCollectionType.where(key: 'from_de').update_all(icon: 'fas fa-chart-line')
    MigrationGeneSetCollectionType.where(key: 'from_find_markers').update_all(icon: 'fas fa-magnifying-glass')
  end
end
