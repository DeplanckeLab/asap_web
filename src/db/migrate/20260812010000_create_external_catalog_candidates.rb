# frozen_string_literal: true

class CreateExternalCatalogCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :external_catalog_candidates do |t|
      t.string :source, null: false
      t.string :external_id, null: false
      t.string :provider_tag, null: false
      t.text :title
      t.string :organism_label
      t.integer :tax_id
      t.string :project_type_tag, default: 'sc', null: false
      t.string :format_kind
      t.string :filename
      t.bigint :filesize, default: 0, null: false
      t.text :url
      t.text :source_page_url
      t.text :dois_json
      t.text :pmids_json
      t.text :identifiers_json
      t.text :attrs_json
      t.string :import_status, default: 'idle', null: false
      t.text :import_error
      t.integer :import_project_id
      t.integer :import_user_id
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :external_catalog_candidates, %i[source external_id], unique: true, name: 'index_ext_catalog_candidates_on_source_and_external_id'
    add_index :external_catalog_candidates, :source
    add_index :external_catalog_candidates, :provider_tag
    add_index :external_catalog_candidates, :import_status
    add_index :external_catalog_candidates, :project_type_tag
    add_index :external_catalog_candidates, :last_seen_at
    add_foreign_key :external_catalog_candidates, :projects, column: :import_project_id, on_delete: :nullify
    add_foreign_key :external_catalog_candidates, :users, column: :import_user_id, on_delete: :nullify
  end
end
