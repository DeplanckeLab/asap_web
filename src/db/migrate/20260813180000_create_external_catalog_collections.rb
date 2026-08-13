# frozen_string_literal: true

class CreateExternalCatalogCollections < ActiveRecord::Migration[8.1]
  def change
    create_table :external_catalog_collections do |t|
      t.string :source, null: false
      t.string :external_key, null: false
      t.text :title, null: false
      t.text :description
      t.text :source_page_url
      t.timestamps
    end

    add_index :external_catalog_collections, [:source, :external_key],
              unique: true,
              name: 'index_ext_catalog_collections_on_source_and_external_key'

    add_reference :external_catalog_candidates, :external_catalog_collection,
                  foreign_key: { on_delete: :nullify },
                  index: { name: 'index_ext_catalog_candidates_on_collection_id' }

    add_column :projects, :input_preparsing_fingerprint, :string, limit: 64
    add_index :projects, [:input_content_sha256, :input_preparsing_fingerprint],
              name: 'index_projects_on_input_sha_and_preparsing_fp'

    add_column :project_collections, :created_by_user_id, :integer
    add_index :project_collections, :created_by_user_id
    add_foreign_key :project_collections, :users, column: :created_by_user_id, on_delete: :nullify
  end
end
