# frozen_string_literal: true

require 'httparty'

module ExternalCatalog
  # Refresh collection title/description from upstream structured APIs
  # (CELLxGENE curation JSON; HCA via candidate sync metadata already on entries).
  class CollectionMetadataRefresh
    CELLXGENE_COLLECTIONS_URL = 'https://api.cellxgene.cziscience.com/curation/v1/collections/'.freeze

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # SOURCE=cellxgene|hca|all
    def call(source: 'cellxgene')
      source = source.to_s.strip.downcase
      totals = { cellxgene: 0, hca: 0, project_collections: 0 }

      if source == 'all' || source == 'cellxgene'
        totals[:cellxgene] = refresh_cellxgene!
      end
      if source == 'all' || source == 'hca'
        totals[:hca] = refresh_hca_from_candidates!
      end
      totals[:project_collections] = sync_project_collections_from_catalog!(source: source)
      totals
    end

    private

    def refresh_cellxgene!
      response = HTTParty.get(CELLXGENE_COLLECTIONS_URL, timeout: 120)
      raise "CELLxGENE collections request failed: HTTP #{response.code}" unless response.success?

      rows = JSON.parse(response.body, symbolize_names: true)
      updated = 0
      rows.each do |row|
        collection_id = (row[:collection_id] || row['collection_id']).to_s.strip
        next if collection_id.blank?

        title = (row[:name] || row['name'] || row[:title] || row['title']).to_s.strip.presence
        description = (row[:description] || row['description']).to_s.strip.presence
        collection_url = "https://cellxgene.cziscience.com/collections/#{collection_id}"

        ExternalCatalogCollection.upsert_from_catalog!(
          source: 'cellxgene',
          external_key: collection_id,
          title: title,
          description: description,
          source_page_url: collection_url
        )
        updated += 1
      end
      @logger.info("[ExternalCatalog] refreshed CELLxGENE collection metadata count=#{updated}")
      updated
    end

    # HCA project title/description are already carried on candidates when synced;
    # rebuild external_catalog_collections from the best candidate row per collection_id.
    def refresh_hca_from_candidates!
      updated = 0
      ExternalCatalogCandidate.current
                              .for_source('hca')
                              .where.not(collection_id: [nil, ''])
                              .includes(:external_catalog_collection)
                              .find_each do |candidate|
        collection_id = candidate.collection_id.to_s.strip
        next if collection_id.blank?

        ecc = candidate.external_catalog_collection
        # Prefer existing non-placeholder title; otherwise use a stable HCA placeholder
        # until a full HCA sync rewrites via upsert_from_entry!.
        title = nil
        description = nil
        if ecc && !ecc.placeholder_title?
          title = ecc.title
          description = ecc.description
        end

        collection_url = "https://data.humancellatlas.org/explore/projects/#{collection_id}"
        catalog_collection = ExternalCatalogCollection.upsert_from_catalog!(
          source: 'hca',
          external_key: collection_id,
          title: title,
          description: description,
          source_page_url: collection_url
        )
        if candidate.external_catalog_collection_id != catalog_collection.id
          candidate.update_column(:external_catalog_collection_id, catalog_collection.id)
        end
        updated += 1
      end
      @logger.info("[ExternalCatalog] ensured HCA external_catalog_collections count=#{updated}")
      updated
    end

    def sync_project_collections_from_catalog!(source:)
      scope = ExternalCatalogCollection.all
      if source.present? && source != 'all'
        scope = scope.for_source(source)
      end

      updated = 0
      scope.find_each do |ecc|
        pc = ProjectCollection.find_by(source: ecc.source, external_key: ecc.external_key)
        next unless pc
        next if !pc.placeholder_title? && pc.description.present?

        ProjectCollection.upsert_from_catalog!(
          source: ecc.source,
          external_key: ecc.external_key,
          title: ecc.placeholder_title? ? nil : ecc.title,
          description: ecc.description,
          source_page_url: ecc.source_page_url
        )
        updated += 1
      end
      updated
    end
  end
end
