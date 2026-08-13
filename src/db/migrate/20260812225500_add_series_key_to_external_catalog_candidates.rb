# frozen_string_literal: true

class AddSeriesKeyToExternalCatalogCandidates < ActiveRecord::Migration[8.1]
  def up
    add_column :external_catalog_candidates, :collection_id, :string
    add_column :external_catalog_candidates, :series_key, :string
    add_index :external_catalog_candidates, :series_key
    add_index :external_catalog_candidates, :collection_id

    say_with_time 'backfill collection_id and series_key' do
      ExternalCatalogCandidate.reset_column_information
      ExternalCatalogCandidate.find_each do |candidate|
        collection_id = candidate.collection_id.presence ||
                        ExternalCatalogCandidate.collection_id_from_source_page_url(candidate.source_page_url)
        series_key = ExternalCatalogCandidate.build_series_key(
          source: candidate.source,
          external_id: candidate.external_id,
          dois: candidate.dois,
          identifiers: candidate.identifiers,
          collection_id: collection_id
        )
        candidate.update_columns(
          collection_id: collection_id,
          series_key: series_key,
          updated_at: Time.current
        )
      end
    end
  end

  def down
    remove_index :external_catalog_candidates, :collection_id
    remove_index :external_catalog_candidates, :series_key
    remove_column :external_catalog_candidates, :series_key
    remove_column :external_catalog_candidates, :collection_id
  end
end
