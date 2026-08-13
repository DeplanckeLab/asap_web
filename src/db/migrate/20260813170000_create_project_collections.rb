# frozen_string_literal: true

class CreateProjectCollections < ActiveRecord::Migration[8.1]
  def change
    create_table :project_collections do |t|
      t.text :title, null: false
      t.text :description
      t.string :source, null: false
      t.string :external_key
      t.text :source_page_url
      t.timestamps
    end

    add_index :project_collections, [:source, :external_key],
              unique: true,
              where: 'external_key IS NOT NULL',
              name: 'index_project_collections_on_source_and_external_key'

    add_reference :projects, :project_collection, foreign_key: { on_delete: :nullify }, index: true
  end
end
