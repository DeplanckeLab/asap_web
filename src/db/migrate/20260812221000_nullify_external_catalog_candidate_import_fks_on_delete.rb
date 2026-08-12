# frozen_string_literal: true

class NullifyExternalCatalogCandidateImportFksOnDelete < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :external_catalog_candidates, column: :import_project_id
    add_foreign_key :external_catalog_candidates, :projects,
                    column: :import_project_id, on_delete: :nullify

    remove_foreign_key :external_catalog_candidates, column: :import_user_id
    add_foreign_key :external_catalog_candidates, :users,
                    column: :import_user_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :external_catalog_candidates, column: :import_project_id
    add_foreign_key :external_catalog_candidates, :projects, column: :import_project_id

    remove_foreign_key :external_catalog_candidates, column: :import_user_id
    add_foreign_key :external_catalog_candidates, :users, column: :import_user_id
  end
end
