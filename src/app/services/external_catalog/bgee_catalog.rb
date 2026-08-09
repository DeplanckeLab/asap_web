# frozen_string_literal: true

require 'httparty'
require 'erb'

module ExternalCatalog
  # Enumerates H5AD download URLs from the Bgee experiment API
  # (same source as scfair BgeeParser).
  class BgeeCatalog
    LIST_URL =
      'https://www.bgee.org/api/?page=data&action=experiments&data_type=SC_RNA_SEQ&get_results=1&offset=0&limit=1000'.freeze
    DETAIL_URL = ->(experiment_id) { "https://www.bgee.org/api/?page=data&exp_id=#{experiment_id}" }

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      yielded = 0
      fetch_experiment_ids.each do |experiment_id|
        break if limit.present? && yielded >= limit.to_i

        entries_for_experiment(experiment_id).each do |entry|
          break if limit.present? && yielded >= limit.to_i

          yield entry
          yielded += 1
        end
      end
      yielded
    end

    def first_entry(limit: 1)
      each(limit: limit).first
    end

    private

    def fetch_experiment_ids
      response = HTTParty.get(LIST_URL, timeout: 120)
      raise "Bgee experiments request failed: HTTP #{response.code}" unless response.success?

      data = JSON.parse(response.body, symbolize_names: true)
      results = data.dig(:data, :results, :SC_RNA_SEQ) || []
      results.filter_map { |row| row.dig(:xRef, :xRefId) }
    end

    def entries_for_experiment(experiment_id)
      response = HTTParty.get(DETAIL_URL.call(experiment_id), timeout: 120)
      unless response.success?
        @logger.warn("[ExternalCatalog::BgeeCatalog] HTTP #{response.code} for #{experiment_id}")
        return []
      end

      payload = JSON.parse(response.body, symbolize_names: true)
      unless payload[:status].to_s.upcase == 'SUCCESS' && payload[:data].present?
        @logger.warn("[ExternalCatalog::BgeeCatalog] No data for #{experiment_id}")
        return []
      end

      experiment = payload.dig(:data, :experiment)
      return [] unless experiment

      title = experiment[:name].presence || experiment_id.to_s
      download_files = experiment[:downloadFiles] || []
      tax_id, organism_label = extract_organism_from_files(download_files)
      dois, pmids, identifiers = bgee_reference_fields(experiment, experiment_id)

      download_files.filter_map do |asset|
        next if asset.nil?

        file_name = asset[:fileName].to_s
        next unless file_name.downcase.end_with?('.h5ad')

        url = build_file_url(asset[:path], file_name)
        next if url.blank?

        file_tax_id, file_label = organism_from_asset(asset)
        Entry.new(
          source: 'bgee',
          external_id: experiment_id.to_s,
          title: title,
          url: url,
          tax_id: file_tax_id || tax_id,
          organism_label: file_label || organism_label,
          filesize: (asset[:size] || asset['size']).to_i,
          project_type_tag: 'sc',
          format_kind: :h5ad,
          filename: file_name,
        dois: dois,
        pmids: pmids,
        identifiers: identifiers,
        source_page_url: "https://www.bgee.org/experiment/#{experiment_id}"
      )
      end
    rescue StandardError => e
      @logger.error("[ExternalCatalog::BgeeCatalog] #{experiment_id}: #{e.class} #{e.message}")
      []
    end

    def bgee_reference_fields(experiment, experiment_id)
      dois = []
      pmids = []
      identifiers = []

      dois << ReferenceIds.normalize_doi(experiment[:dOI] || experiment['dOI'] || experiment[:doi] || experiment['doi'])

      xref = experiment[:xRef] || experiment['xRef'] || {}
      xref_id = (xref[:xRefId] || xref['xRefId'] || experiment_id).to_s
      identifiers << ReferenceIds.identifier_hash(kind: nil, value: xref_id)

      [dois.compact.uniq, pmids.compact.uniq, identifiers.compact]
    end

    def extract_organism_from_files(download_files)
      download_files.each do |asset|
        tax_id, label = organism_from_asset(asset)
        return [tax_id, label] if tax_id.present?
      end
      [nil, nil]
    end

    def organism_from_asset(asset)
      species = asset.is_a?(Hash) ? (asset[:species] || asset['species']) : nil
      return [nil, nil] unless species.is_a?(Hash)

      tax_id = (species[:id] || species['id']).to_i
      tax_id = nil if tax_id <= 0
      genus = species[:genus] || species['genus']
      species_name = species[:speciesName] || species['speciesName']
      label = [genus, species_name].compact.join(' ').presence || species[:name] || species['name']
      [tax_id, label.to_s.presence]
    end

    def build_file_url(path, file_name)
      base_path = path.to_s
      return nil if base_path.blank? || file_name.blank?

      safe_base = base_path.end_with?('/') ? base_path : "#{base_path}/"
      encoded = ERB::Util.url_encode(file_name.to_s).gsub('%2F', '/')
      "#{safe_base}#{encoded}"
    end
  end
end
