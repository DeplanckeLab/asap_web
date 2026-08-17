# frozen_string_literal: true

class AddImportContextToGeneSetCollections < ActiveRecord::Migration[8.0]
  def change
    add_column :gene_set_collections, :staged_upload_path, :string
    add_column :gene_set_collections, :import_loom_file, :string
  end
end
