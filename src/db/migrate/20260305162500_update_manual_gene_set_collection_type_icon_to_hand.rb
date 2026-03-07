class UpdateManualGeneSetCollectionTypeIconToHand < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  def up
    MigrationGeneSetCollectionType.where(key: 'manual').update_all(icon: 'fas fa-hand')
  end

  def down
    MigrationGeneSetCollectionType.where(key: 'manual').update_all(icon: 'fas fa-pen')
  end
end
