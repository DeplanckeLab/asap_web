# frozen_string_literal: true

class CreateExternalCatalogCandidateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :external_catalog_candidate_projects do |t|
      t.references :external_catalog_candidate,
                   null: false,
                   foreign_key: { on_delete: :cascade },
                   index: { name: 'index_ext_catalog_cand_projects_on_candidate_id' }
      t.references :project,
                   null: false,
                   foreign_key: { on_delete: :cascade },
                   index: { name: 'index_ext_catalog_cand_projects_on_project_id' }
      # import = official auto-import; content_match = same file+preparsing;
      # provider_match = already linked via ProviderProject; manual = curated later.
      t.string :link_kind, null: false, default: 'content_match'
      t.timestamps
    end

    add_index :external_catalog_candidate_projects,
              [:external_catalog_candidate_id, :project_id],
              unique: true,
              name: 'index_ext_catalog_cand_projects_on_candidate_and_project'
    add_index :external_catalog_candidate_projects, :link_kind
  end
end
