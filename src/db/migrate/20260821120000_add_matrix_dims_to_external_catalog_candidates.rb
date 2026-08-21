# frozen_string_literal: true

class AddMatrixDimsToExternalCatalogCandidates < ActiveRecord::Migration[8.1]
  def change
    add_column :external_catalog_candidates, :n_obs, :bigint
    add_column :external_catalog_candidates, :n_vars, :bigint
    add_index :external_catalog_candidates, :n_obs
  end
end
