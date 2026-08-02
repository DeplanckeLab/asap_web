class AddHeatmapGeneSetCollectionType < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  def up
    now = Time.current
    row = MigrationGeneSetCollectionType.find_or_initialize_by(key: 'from_heatmap')
    row.label = 'Heatmap selection'
    row.icon = 'fas fa-th'
    row.icon_color = '#ea580c'
    row.created_at ||= now
    row.updated_at = now
    row.save!
  end

  def down
    MigrationGeneSetCollectionType.find_by(key: 'from_heatmap')&.destroy
  end
end
