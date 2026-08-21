# frozen_string_literal: true

require 'httparty'
require 'cgi'

module ExternalCatalog
  # Full HCA Azul catalog (default dcp60). Prefers public S3 mirror URLs when present.
  class HcaCatalog
    BASE = 'https://service.azul.data.humancellatlas.org'.freeze
    DEFAULT_CATALOG = 'dcp60'.freeze
    # Prefer loom, then h5ad, then h5 (10x), then mtx — skip raw reads.
    FORMAT_PRIORITY = %w[loom h5ad h5 mtx].freeze
    SPECIES_TAX = {
      'homo sapiens' => 9606,
      'mus musculus' => 10090,
      'rattus norvegicus' => 10116,
      'danio rerio' => 7955,
      'drosophila melanogaster' => 7227,
      'caenorhabditis elegans' => 6239,
      'macaca mulatta' => 9544,
      'macaca fascicularis' => 9541,
      'sus scrofa' => 9823,
      'gallus gallus' => 9031,
      'arabidopsis thaliana' => 3702,
      'saccharomyces cerevisiae' => 4932,
      'zea mays' => 4577,
      'oryza sativa' => 4530,
      'bos taurus' => 9913,
      'canis lupus familiaris' => 9615,
      'canis familiaris' => 9615,
      'pan troglodytes' => 9598,
      'xenopus tropicalis' => 8364,
      'xenopus laevis' => 8355,
      'schizosaccharomyces pombe' => 4896,
      'neurospora crassa' => 5141,
      'plasmodium falciparum' => 5833,
      'glycine max' => 3847,
      'solanum lycopersicum' => 4081,
      'triticum aestivum' => 4565,
      'hordeum vulgare' => 4513
    }.freeze

    def initialize(catalog: DEFAULT_CATALOG, logger: Rails.logger)
      @catalog = catalog
      @logger = logger
      @project_meta_cache = {}
    end

    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      yielded = 0
      FORMAT_PRIORITY.each do |fmt|
        break if limit.present? && yielded >= limit.to_i

        each_format(fmt) do |entry|
          break if limit.present? && yielded >= limit.to_i

          yield entry
          yielded += 1
        end
      end
      yielded
    end

    private

    def each_format(fmt)
      page_size = 100
      url = nil
      loop do
        payload =
          if url
            fetch_url(url)
          else
            fetch_files_page(fmt, size: page_size)
          end
        hits = payload['hits'] || []
        break if hits.empty?

        hits.each do |hit|
          entry = entry_from_hit(hit, fmt)
          yield entry if entry
        end

        url = payload.dig('pagination', 'next')
        break if url.blank?
      end
    end

    def fetch_url(url)
      response = HTTParty.get(url, timeout: 120)
      raise "HCA request failed: HTTP #{response.code}" unless response.success?

      JSON.parse(response.body)
    end

    def fetch_files_page(fmt, size:)
      filters = { 'fileFormat' => { 'is' => [fmt] } }
      params = {
        catalog: @catalog,
        size: size,
        filters: filters.to_json,
        sort: 'fileName',
        order: 'asc'
      }

      response = HTTParty.get("#{BASE}/index/files", query: params, timeout: 120)
      raise "HCA files request failed: HTTP #{response.code}" unless response.success?

      JSON.parse(response.body)
    end

    def entry_from_hit(hit, fmt)
      files = hit['files'] || []
      file = files.first
      return nil unless file.is_a?(Hash)

      # Prefer non-intermediate matrices when the flag is present.
      if file['isIntermediate'] == true && files.size > 1
        preferred = files.find { |f| f['isIntermediate'] != true }
        file = preferred if preferred
      end

      url = mirror_https_url(file['azul_mirror_uri']) || file['azul_url']
      return nil if url.blank?
      return nil if file['accessible'] == false

      project = (hit['projects'] || []).first || {}
      project_id = Array(project['projectId']).first
      project_title = Array(project['projectTitle']).first.presence
      title = project_title.presence || file['name'].to_s
      filename = file['name'].to_s
      file_uuid = file['uuid'].presence || hit['entryId']
      external_id = "#{project_id}::#{file_uuid}"

      tax_id, organism_label = extract_species(hit)
      dois, pmids, identifiers = hca_reference_fields(project_id)
      meta = project_id.present? ? fetch_project_meta(project_id) : nil
      collection_description =
        if meta.is_a?(Hash)
          Array(meta['projectDescription']).first.presence || meta['projectDescription'].to_s.presence
        end

      n_obs = file['matrixCellCount'].to_i
      n_obs = nil unless n_obs.positive?

      Entry.new(
        source: 'hca',
        external_id: external_id,
        title: title,
        url: url,
        tax_id: tax_id,
        organism_label: organism_label,
        filesize: file['size'].to_i,
        n_obs: n_obs,
        n_vars: nil,
        project_type_tag: 'sc',
        format_kind: fmt.to_sym,
        filename: filename,
        dois: dois,
        pmids: pmids,
        identifiers: identifiers,
        source_page_url: (
          project_id.present? ? "https://data.humancellatlas.org/explore/projects/#{project_id}" : nil
        ),
        collection_id: project_id.to_s.presence,
        collection_title: project_title,
        collection_description: collection_description
      )
    end

    def hca_reference_fields(project_id)
      return [[], [], []] if project_id.blank?

      meta = fetch_project_meta(project_id)
      return [[], [], []] if meta.blank?

      dois = []
      pmids = []
      identifiers = []

      Array(meta['publications']).each do |pub|
        next unless pub.is_a?(Hash)

        dois << ReferenceIds.normalize_doi(pub['doi'])
        dois << ReferenceIds.extract_doi_from_text(pub['publicationUrl'])
        pmids << ReferenceIds.normalize_pmid(pub['pmid'])
        pmids << ReferenceIds.normalize_pmid(pub['publicationUrl'])
      end

      Array(meta['accessions']).each do |acc|
        next unless acc.is_a?(Hash)

        identifiers << ReferenceIds.from_hca_accession(
          namespace: acc['namespace'],
          accession: acc['accession']
        )
      end

      [dois.compact.uniq, pmids.compact.uniq, identifiers.compact]
    end

    def fetch_project_meta(project_id)
      return @project_meta_cache[project_id] if @project_meta_cache.key?(project_id)

      filters = { 'projectId' => { 'is' => [project_id] } }
      params = {
        catalog: @catalog,
        size: 1,
        filters: filters.to_json
      }
      response = HTTParty.get("#{BASE}/index/projects", query: params, timeout: 120)
      unless response.success?
        @logger.warn("[ExternalCatalog::HcaCatalog] project meta HTTP #{response.code} for #{project_id}")
        @project_meta_cache[project_id] = nil
        return nil
      end

      body = JSON.parse(response.body)
      hit = (body['hits'] || []).first
      project = hit && (hit['projects'] || []).first
      @project_meta_cache[project_id] = project
      project
    rescue StandardError => e
      @logger.warn("[ExternalCatalog::HcaCatalog] project meta #{project_id}: #{e.class} #{e.message}")
      @project_meta_cache[project_id] = nil
      nil
    end

    def mirror_https_url(azul_mirror_uri)
      uri = azul_mirror_uri.to_s
      return nil if uri.blank?
      # s3://humancellatlas/file/<sha256>.sha256
      m = uri.match(%r{\As3://([^/]+)/(.+)\z})
      return nil unless m

      bucket = m[1]
      key = m[2]
      "https://s3.amazonaws.com/#{bucket}/#{key}"
    end

    def extract_species(hit)
      donors = hit['donorOrganisms'] || []
      species = donors.flat_map { |d| Array(d['genusSpecies']) }.compact
      label = species.first.to_s
      tax_id = SPECIES_TAX[label.downcase]
      [tax_id, label.presence]
    end
  end
end
