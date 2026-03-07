class AddGlobalGeneSetCollectionType < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  class MigrationGeneSetCollection < ApplicationRecord
    self.table_name = 'gene_set_collections'
  end

  def up
    now = Time.current
    row = MigrationGeneSetCollectionType.find_or_initialize_by(key: 'global')
    row.label = 'Global'
    row.icon = 'fas fa-globe'
    row.icon_color = '#0ea5e9'
    row.created_at ||= now
    row.updated_at = now
    row.save!
  end

  def down
    global_type = MigrationGeneSetCollectionType.find_by(key: 'global')
    imported_type = MigrationGeneSetCollectionType.find_by(key: 'imported')
    if global_type && imported_type
      MigrationGeneSetCollection.where(gene_set_collection_type_id: global_type.id).update_all(gene_set_collection_type_id: imported_type.id)
    end
    global_type&.destroy
  end
end
class AddGlobalGeneSetCollectionType < ActiveRecord::Migration[7.2]
  class MigrationGeneSetCollectionType < ApplicationRecord
    self.table_name = 'gene_set_collection_types'
  end

  class MigrationGeneSetCollection < ApplicationRecord
    self.table_name = 'gene_set_collections'
  end

  def up
    now = Time.current
    row = MigrationGeneSetCollectionType.find_or_initialize_by(key: 'global')
    row.label = 'Global'
    row.icon = 'fas fa-globe'
    row.icon_color = '#0ea5e9'
    row.created_at ||= now
    row.updated_at = now
    row.save!
  end

  def down
    global_type = MigrationGeneSetCollectionType.find_by(key: 'global')
    imported_type = MigrationGeneSetCollectionType.find_by(key: 'imported')
    if global_type && imported_type
      MigrationGeneSetCollection.where(gene_set_collection_type_id: global_type.id).update_all(gene_set_collection_type_id: imported_type.id)
    end
    global_type&.destroy
  end
end
