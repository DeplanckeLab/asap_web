# frozen_string_literal: true

require 'httparty'
require 'cgi'

module ExternalCatalog
  # Public HuBMAP RNAseq datasets with downloadable AnnData matrices.
  # Matrices live on assets.hubmapconsortium.org (requires a User-Agent on GET).
  class HubmapCatalog
    SEARCH_URL = 'https://search.api.hubmapconsortium.org/v3/search'.freeze
    ASSETS_BASE = 'https://assets.hubmapconsortium.org'.freeze
    PORTAL_DATASET = ->(uuid) { "https://portal.hubmapconsortium.org/browse/dataset/#{uuid}" }
    HTTP_HEADERS = {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
      'User-Agent' => 'ASAP-external-catalog (https://asap.epfl.ch)'
    }.freeze

    # sc/sn RNA only — skip bulk Salmon, Slide-seq (spatial), ATAC, multiome.
    SC_RNA_DATA_TYPES = %w[
      salmon_sn_rnaseq_10x
      salmon_rnaseq_10x
      salmon_rnaseq_snareseq
      salmon_rnaseq_sciseq
      sc_rna_seq_snare_lab
    ].freeze

    # Prefer raw count AnnData over secondary analysis / marker outputs.
    H5AD_PRIORITY = %w[out.h5ad raw_expr.h5ad expr.h5ad].freeze

    PAGE_SIZE = 100

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      yielded = 0
      from = 0
      loop do
        break if limit.present? && yielded >= limit.to_i

        payload = search_page(from: from, size: PAGE_SIZE)
        hits = Array(payload.dig('hits', 'hits'))
        break if hits.empty?

        hits.each do |hit|
          break if limit.present? && yielded >= limit.to_i

          entry = entry_from_hit(hit)
          next unless entry

          yield entry
          yielded += 1
        end

        from += hits.size
        total = payload.dig('hits', 'total', 'value') || payload.dig('hits', 'total')
        break if total.present? && from >= total.to_i
        break if hits.size < PAGE_SIZE
      end
      yielded
    end

    def first_entry(limit: 1)
      each(limit: limit).first
    end

    def self.asset_url?(url)
      uri = URI.parse(url.to_s.strip)
      return false unless uri.is_a?(URI::HTTP)

      uri.host.to_s.casecmp('assets.hubmapconsortium.org').zero?
    rescue URI::InvalidURIError
      false
    end

    private

    def search_page(from:, size:)
      body = {
        version: true,
        from: from,
        size: size,
        query: {
          bool: {
            filter: [
              { term: { 'entity_type.keyword' => 'Dataset' } },
              { term: { 'status.keyword' => 'Published' } },
              { term: { 'data_access_level.keyword' => 'public' } },
              { terms: { 'data_types.keyword' => SC_RNA_DATA_TYPES } }
            ]
          }
        },
        _source: %w[
          hubmap_id uuid title dataset_type data_types files
          origin_samples_unique_mapped_organs anatomy_1 donor
        ]
      }
      response = HTTParty.post(
        SEARCH_URL,
        headers: HTTP_HEADERS,
        body: body.to_json,
        timeout: 120
      )
      raise "HuBMAP search failed: HTTP #{response.code}" unless response.success?

      JSON.parse(response.body)
    end

    def entry_from_hit(hit)
      source = hit.is_a?(Hash) ? (hit['_source'] || hit) : nil
      return nil unless source.is_a?(Hash)

      uuid = source['uuid'].to_s.strip
      hubmap_id = source['hubmap_id'].to_s.strip
      return nil if uuid.blank? || hubmap_id.blank?

      matrix = pick_h5ad(source['files'])
      return nil unless matrix

      organs = Array(source['origin_samples_unique_mapped_organs']).map(&:to_s).reject(&:blank?)
      organs = Array(source['anatomy_1']).map(&:to_s).reject(&:blank?) if organs.empty?
      title = source['title'].to_s.strip.presence || hubmap_id
      if organs.any? && !title.downcase.include?(organs.first.downcase)
        title = "#{title} (#{organs.map(&:capitalize).join(', ')})"
      end

      Entry.new(
        source: 'hubmap',
        external_id: hubmap_id,
        title: title,
        url: "#{ASSETS_BASE}/#{uuid}/#{matrix[:rel_path]}",
        tax_id: 9606,
        organism_label: 'Homo sapiens',
        filesize: matrix[:size].to_i,
        n_obs: nil,
        project_type_tag: 'sc',
        format_kind: :h5ad,
        filename: File.basename(matrix[:rel_path]),
        dois: [],
        pmids: [],
        identifiers: [],
        source_page_url: PORTAL_DATASET.call(uuid)
      )
    rescue StandardError => e
      @logger.error(
        "[ExternalCatalog::HubmapCatalog] #{hubmap_id.presence || uuid}: #{e.class} #{e.message}"
      )
      nil
    end

    def pick_h5ad(files)
      rows = Array(files).select do |f|
        f.is_a?(Hash) && f['rel_path'].to_s.downcase.end_with?('.h5ad')
      end
      return nil if rows.empty?

      H5AD_PRIORITY.each do |name|
        found = rows.find { |f| f['rel_path'].to_s == name }
        return { rel_path: found['rel_path'], size: found['size'].to_i } if found
      end

      # Do not fall back to secondary_analysis / marker / scvelo products.
      nil
    end
  end
end
