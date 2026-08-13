# frozen_string_literal: true

class AddExcludedToExternalCatalogCandidates < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:external_catalog_candidates, :excluded)
      rename_column :external_catalog_candidates, :excluded, :obsolete
      if index_name_exists?(:external_catalog_candidates, 'index_external_catalog_candidates_on_excluded')
        rename_index :external_catalog_candidates,
                     'index_external_catalog_candidates_on_excluded',
                     'index_external_catalog_candidates_on_obsolete'
      elsif !index_exists?(:external_catalog_candidates, :obsolete)
        add_index :external_catalog_candidates, :obsolete
      end
    elsif !column_exists?(:external_catalog_candidates, :obsolete)
      add_column :external_catalog_candidates, :obsolete, :boolean, default: false, null: false
      add_index :external_catalog_candidates, :obsolete
    end
  end

  def down
    if column_exists?(:external_catalog_candidates, :obsolete)
      rename_column :external_catalog_candidates, :obsolete, :excluded
      if index_name_exists?(:external_catalog_candidates, 'index_external_catalog_candidates_on_obsolete')
        rename_index :external_catalog_candidates,
                     'index_external_catalog_candidates_on_obsolete',
                     'index_external_catalog_candidates_on_excluded'
      end
    end
  end
end
