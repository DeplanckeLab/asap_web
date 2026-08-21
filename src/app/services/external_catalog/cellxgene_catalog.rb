# frozen_string_literal: true

require 'httparty'
require 'net/http'
require 'uri'

module ExternalCatalog
  # Enumerates H5AD download URLs from the CELLxGENE curation API
  # (same source as scfair CellxgeneParser).
  class CellxgeneCatalog
    BASE_URL = 'https://api.cellxgene.cziscience.com/curation/v1/collections/'.freeze
    HTTP_OPEN_TIMEOUT_SEC = 20
    HTTP_READ_TIMEOUT_SEC = 180
    HTTP_ATTEMPTS = 4
    RETRYABLE_ERRORS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::ETIMEDOUT,
      SocketError
    ].freeze
    RETRYABLE_STATUS = [429, 500, 502, 503, 504].freeze
    HTTP_HEADERS = { 'User-Agent' => 'ASAP-external-catalog (https://asap.epfl.ch)' }.freeze

    class FetchError < StandardError; end

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Yields ExternalCatalog::Entry for each H5AD asset.
    # Stops early when +limit+ entries have been yielded (if limit present).
    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      yielded = 0
      failed_collection_ids = []
      fetch_collections.each do |collection_summary|
        break if limit.present? && yielded >= limit.to_i

        collection_id = collection_summary[:collection_id] || collection_summary['collection_id']
        next if collection_id.blank?

        begin
          detail = fetch_collection(collection_id)
        rescue FetchError => e
          @logger.error("[ExternalCatalog::CellxgeneCatalog] collection=#{collection_id} #{e.message}")
          failed_collection_ids << collection_id
          next
        end
        datasets = detail[:datasets] || detail['datasets'] || []
        collection_refs = collection_reference_fields(detail, collection_id)
        collection_title = (detail[:name] || detail['name'] || detail[:title] || detail['title']).to_s.presence
        collection_description = (detail[:description] || detail['description']).to_s.presence
        datasets.each do |dataset|
          break if limit.present? && yielded >= limit.to_i

          entries_for_dataset(
            dataset,
            collection_refs,
            collection_id: collection_id,
            collection_title: collection_title,
            collection_description: collection_description
          ).each do |entry|
            break if limit.present? && yielded >= limit.to_i

            yield entry
            yielded += 1
          end
        end
      end
      if failed_collection_ids.any?
        sample = failed_collection_ids.first(10).join(', ')
        raise FetchError,
              "CELLxGENE #{failed_collection_ids.size} collection(s) failed after retries: #{sample}"
      end
      yielded
    end

    def first_entry(limit: 1)
      each(limit: limit).first
    end

    private

    def fetch_collections
      http_get_json(BASE_URL, label: 'collections list')
    end

    def fetch_collection(collection_id)
      http_get_json("#{BASE_URL}#{collection_id}", label: "collection #{collection_id}")
    end

    def http_get_json(url, label:)
      last_error = nil
      HTTP_ATTEMPTS.times do |attempt|
        begin
          response = perform_get(url)
          if response.success?
            return JSON.parse(response.body, symbolize_names: true)
          end

          last_error = "HTTP #{response.code}"
          unless RETRYABLE_STATUS.include?(response.code.to_i)
            raise FetchError, "CELLxGENE #{label} failed: #{last_error}"
          end
        rescue *RETRYABLE_ERRORS => e
          last_error = "#{e.class}: #{e.message}"
        end

        next_attempt = attempt + 2
        next unless next_attempt <= HTTP_ATTEMPTS

        sleep_sec = 2**attempt
        @logger.warn(
          "[ExternalCatalog::CellxgeneCatalog] retry #{next_attempt}/#{HTTP_ATTEMPTS} " \
          "for #{label} after #{last_error} sleep=#{sleep_sec}s"
        )
        backoff_sleep(sleep_sec)
      end

      raise FetchError, "CELLxGENE #{label} failed after #{HTTP_ATTEMPTS} attempts: #{last_error}"
    end

    def perform_get(url)
      HTTParty.get(
        url,
        open_timeout: HTTP_OPEN_TIMEOUT_SEC,
        timeout: HTTP_READ_TIMEOUT_SEC,
        headers: HTTP_HEADERS
      )
    end

    def backoff_sleep(seconds)
      sleep(seconds)
    end

    def entries_for_dataset(dataset, collection_refs = {}, collection_id: nil, collection_title: nil, collection_description: nil)
      dataset_id = dataset[:dataset_id] || dataset['dataset_id']
      title = dataset[:title] || dataset['name'] || dataset_id.to_s
      if atac_or_multiome_only_dataset?(dataset)
        @logger.info(
          "[ExternalCatalog::CellxgeneCatalog] skip atac/multiome-only " \
          "dataset=#{dataset_id} title=#{title.inspect}"
        )
        return []
      end

      tax_id, organism_label = extract_organism(dataset)
      assets = dataset[:assets] || dataset['assets'] || []
      refs = merge_dataset_refs(dataset, collection_refs)

      assets.filter_map do |asset|
        filetype = (asset[:filetype] || asset['filetype']).to_s.downcase
        next unless filetype == 'h5ad'

        url = asset[:url] || asset['url']
        next if url.blank?

        Entry.new(
          source: 'cellxgene',
          external_id: dataset_id.to_s,
          title: title.to_s,
          url: url.to_s,
          tax_id: tax_id,
          organism_label: organism_label,
          filesize: (asset[:filesize] || asset['filesize']).to_i,
          n_obs: positive_int(dataset[:cell_count] || dataset['cell_count']),
          n_vars: positive_int(dataset[:feature_count] || dataset['feature_count']),
          project_type_tag: 'sc',
          format_kind: :h5ad,
          filename: File.basename(URI.parse(url.to_s).path.to_s),
          dois: refs[:dois],
          pmids: refs[:pmids],
          identifiers: refs[:identifiers],
          source_page_url: refs[:source_page_url],
          collection_id: collection_id.to_s.presence,
          collection_title: collection_title.to_s.presence,
          collection_description: collection_description.to_s.presence
        )
      end
    end

    def collection_reference_fields(detail, collection_id)
      dois = []
      pmids = []
      identifiers = []

      dois << ReferenceIds.normalize_doi(detail[:doi] || detail['doi'])
      pm = detail[:publisher_metadata] || detail['publisher_metadata'] || {}
      if pm.is_a?(Hash)
        dois << ReferenceIds.normalize_doi(pm[:doi] || pm['doi'])
        pmids << ReferenceIds.normalize_pmid(pm[:pmid] || pm['pmid'])
      end

      links = detail[:links] || detail['links'] || []
      links.each do |link|
        next unless link.is_a?(Hash)

        name = (link[:link_name] || link['link_name']).to_s
        url = (link[:link_url] || link['link_url']).to_s
        ReferenceIds.extract_accession_from_text("#{name} #{url}").each do |acc|
          identifiers << ReferenceIds.identifier_hash(kind: nil, value: acc)
        end
        dois << ReferenceIds.extract_doi_from_text(url)
      end

      collection_url =
        if collection_id.present?
          "https://cellxgene.cziscience.com/collections/#{collection_id}"
        end

      {
        dois: dois.compact.uniq,
        pmids: pmids.compact.uniq,
        identifiers: identifiers.compact,
        source_page_url: collection_url
      }
    end

    def merge_dataset_refs(dataset, collection_refs)
      dois = Array(collection_refs[:dois]).dup
      pmids = Array(collection_refs[:pmids]).dup
      identifiers = Array(collection_refs[:identifiers]).dup

      citation = dataset[:citation] || dataset['citation']
      dois << ReferenceIds.extract_doi_from_text(citation)

      explorer = dataset[:explorer_url] || dataset['explorer_url']
      dataset_id = dataset[:dataset_id] || dataset['dataset_id']
      source_page_url =
        explorer.to_s.presence ||
        (
          if dataset_id.present?
            "https://cellxgene.cziscience.com/e/#{dataset_id}.cxg/"
          end
        ) ||
        collection_refs[:source_page_url].presence

      {
        dois: dois.compact.uniq,
        pmids: pmids.compact.uniq,
        identifiers: identifiers.compact,
        source_page_url: source_page_url
      }
    end

    def atac_or_multiome_only_dataset?(dataset)
      assays = dataset[:assay] || dataset['assay']
      Scfair::AssayProjectTypeHelper.catalog_assays_atac_or_multiome_only?(assays)
    end

    def extract_organism(dataset)
      organisms = dataset[:organism] || dataset['organism'] || []
      organisms = [organisms] unless organisms.is_a?(Array)
      first = organisms.compact.first
      return [nil, nil] unless first

      label = first[:label] || first['label']
      ontology_id = first[:ontology_term_id] || first['ontology_term_id']
      tax_id = nil
      if ontology_id.to_s =~ /\ANCBITaxon:(\d+)\z/i
        tax_id = Regexp.last_match(1).to_i
      end
      [tax_id, label.to_s.presence]
    end

    def positive_int(value)
      n = value.to_i
      n.positive? ? n : nil
    end
  end
end
