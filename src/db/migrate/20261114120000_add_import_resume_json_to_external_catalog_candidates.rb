# frozen_string_literal: true

# State of a catalog import paused for an H5AD matrix choice (import_status = awaiting_matrix):
# the downloaded Fu, version, archive flag and a digest of the guest sandbox key.
class AddImportResumeJsonToExternalCatalogCandidates < ActiveRecord::Migration[7.2]
  def change
    add_column :external_catalog_candidates, :import_resume_json, :text
  end
end
