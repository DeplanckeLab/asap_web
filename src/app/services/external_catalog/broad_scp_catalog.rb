# frozen_string_literal: true

require 'httparty'
require 'cgi'
require 'uri'

module ExternalCatalog
  # Enumerates public Broad Institute Single Cell Portal studies with a single
  # importable matrix (AnnData, Seurat RDS, or one Expression Matrix file).
  # File bytes require SCP_ACCESS_TOKEN (Google OAuth) at download time.
  class BroadScpCatalog
    API_BASE = 'https://singlecell.broadinstitute.org/single_cell/api/v1'.freeze
    PORTAL_HOST = 'singlecell.broadinstitute.org'.freeze
    SOURCE_PAGE = lambda { |accession, study_url = nil|
      if study_url.to_s.start_with?('/')
        "https://#{PORTAL_HOST}#{study_url}"
      elsif study_url.to_s.start_with?('http')
        study_url.to_s
      else
        "https://#{PORTAL_HOST}/single_cell/study/#{accession}"
      end
    }
    # Curated branding groups from https://singlecell.broadinstitute.org/single_cell/collections
    COLLECTIONS = [
      {
        id: '18th-broad-retreat-2022',
        title: '18th Broad Retreat 2022',
        query: { scpbr: '18th-broad-retreat-2022' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=18th-broad-retreat-2022'
      },
      {
        id: 'biccn-anatomy-and-morphology-project',
        title: 'BICCN Anatomy and Morphology Project',
        query: { scpbr: 'biccn-anatomy-and-morphology-project' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=biccn-anatomy-and-morphology-project'
      },
      {
        id: 'brain-multi-modal',
        title: 'BRAIN multi-modal',
        query: { scpbr: 'brain-multi-modal' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=brain-multi-modal'
      },
      {
        id: 'hca-covid-19-integrated-analysis',
        title: 'HCA COVID-19 Integrated Analysis',
        query: { scpbr: 'hca-covid-19-integrated-analysis' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=hca-covid-19-integrated-analysis'
      },
      {
        id: 'human-cell-atlas-main-collection',
        title: 'Human Cell Atlas - Main Collection',
        query: { scpbr: 'human-cell-atlas-main-collection' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=human-cell-atlas-main-collection'
      },
      {
        id: 'immune-cell-atlas',
        title: 'Immune Cell Atlas',
        query: { scpbr: 'immune-cell-atlas' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=immune-cell-atlas'
      },
      {
        id: 'immunological-genome-project',
        title: 'Immunological Genome Project',
        query: { scpbr: 'immunological-genome-project' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=immunological-genome-project'
      },
      {
        id: 'the-alexandria-project',
        title: 'The Alexandria Project',
        query: { scpbr: 'the-alexandria-project' },
        url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=the-alexandria-project'
      },
      {
        id: 'covid19',
        title: 'COVID-19 Studies',
        query: { preset_search: 'covid19' },
        url: 'https://singlecell.broadinstitute.org/single_cell/covid19'
      }
    ].freeze

    class MissingAccessToken < StandardError; end

    def self.collection_page_url(collection_id)
      row = COLLECTIONS.find { |c| c[:id] == collection_id.to_s }
      return row[:url] if row

      "https://#{PORTAL_HOST}/single_cell?scpbr=#{CGI.escape(collection_id.to_s)}"
    end

    def self.scp_download_url?(url)
      uri = URI.parse(url.to_s.strip)
      return false unless uri.is_a?(URI::HTTP)
      return false unless uri.host.to_s.casecmp(PORTAL_HOST).zero?

      uri.path.to_s.include?('/download') || uri.path.to_s.include?('/stream')
    rescue URI::InvalidURIError
      false
    end

    # Bearer token for SCP matrix downloads (Google OAuth / Terra ToS account).
    def self.access_token
      ENV['SCP_ACCESS_TOKEN'].to_s.strip.presence
    end

    def self.authorization_header_for!(url)
      return nil unless scp_download_url?(url)

      token = access_token
      if token.blank?
        raise MissingAccessToken,
              'SCP_ACCESS_TOKEN is required to download from the Broad Single Cell Portal'
      end

      "Bearer #{token}"
    end

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      collection_by_accession = fetch_collection_memberships
      yielded = 0
      each_search_study do |accession, search_row|
        break if limit.present? && yielded >= limit.to_i

        entry = entry_for_accession(
          accession,
          search_row,
          collection_by_accession[accession]
        )
        next unless entry

        yield entry
        yielded += 1
      end
      yielded
    end

    def first_entry(limit: 1)
      each(limit: limit).first
    end

    private

    def each_search_study
      page = 1
      total_pages = 1
      while page <= total_pages
        payload = fetch_json(
          "#{API_BASE}/search",
          query: { type: 'study', page: page }
        )
        total_pages = payload['total_pages'].to_i
        total_pages = 1 if total_pages < 1
        Array(payload['studies']).each do |row|
          next unless row.is_a?(Hash)

          accession = row['accession'].to_s.strip
          next if accession.blank?

          yield accession, row
        end
        page += 1
      end
    end

    def fetch_collection_memberships
      membership = {}
      COLLECTIONS.each do |collection|
        each_collection_accession(collection) do |accession|
          membership[accession] ||= {
            id: collection[:id],
            title: collection[:title],
            url: collection[:url]
          }
        end
      end
      membership
    end

    def each_collection_accession(collection)
      page = 1
      total_pages = 1
      while page <= total_pages
        payload = fetch_json(
          "#{API_BASE}/search",
          query: { type: 'study', page: page }.merge(collection[:query])
        )
        total_pages = payload['total_pages'].to_i
        total_pages = 1 if total_pages < 1
        Array(payload['matching_accessions']).each do |accession|
          acc = accession.to_s.strip
          yield acc if acc.present?
        end
        page += 1
      end
    end

    def entry_for_accession(accession, search_row, collection)
      detail = fetch_json("#{API_BASE}/site/studies/#{CGI.escape(accession)}")
      picked = pick_matrix_file(detail['study_files'], accession: accession)
      return nil unless picked

      species = Array(search_row && search_row.dig('metadata', 'species')).map(&:to_s).map(&:strip).reject(&:blank?)
      organism_label = species.first
      tax_id = organism_label.present? ? HcaCatalog::SPECIES_TAX[organism_label.downcase] : nil
      n_obs = detail['cell_count'].to_i
      n_obs = (search_row && search_row['cell_count']).to_i if n_obs <= 0
      n_obs = nil if n_obs.to_i <= 0
      n_vars = detail['gene_count'].to_i
      n_vars = (search_row && search_row['gene_count']).to_i if n_vars <= 0
      n_vars = nil if n_vars.to_i <= 0

      title = detail['name'].to_s.strip.presence ||
              (search_row && search_row['name']).to_s.strip.presence ||
              accession
      study_url = search_row && search_row['study_url']
      dois, pmids = publication_ids(detail['publications'])
      identifiers = identifiers_from_external_resources(detail['external_resources'])

      Entry.new(
        source: 'broad_scp',
        external_id: accession,
        title: title,
        url: picked[:url],
        tax_id: tax_id,
        organism_label: organism_label,
        filesize: picked[:filesize].to_i,
        n_obs: n_obs,
        n_vars: n_vars,
        project_type_tag: 'sc',
        format_kind: picked[:format_kind],
        filename: picked[:filename],
        dois: dois,
        pmids: pmids,
        identifiers: identifiers,
        source_page_url: SOURCE_PAGE.call(accession, study_url),
        collection_id: collection && collection[:id],
        collection_title: collection && collection[:title],
        collection_description: nil
      )
    rescue StandardError => e
      @logger.error("[ExternalCatalog::BroadScpCatalog] #{accession}: #{e.class} #{e.message}")
      nil
    end

    # Prefer AnnData, then Seurat, then a single Expression Matrix file.
    # Skip multi-file MTX / split CSV expression sets (ASAP imports one URL).
    def pick_matrix_file(study_files, accession:)
      files = Array(study_files).select { |f| f.is_a?(Hash) }

      anndata = files.select { |f| anndata_file?(f) }
      picked = prefer_raw_or_smallest(anndata)
      return file_pick(picked, :h5ad, accession: accession) if picked

      seurat = files.select { |f| seurat_file?(f) }
      picked = prefer_raw_or_smallest(seurat)
      return file_pick(picked, :rds, accession: accession) if picked

      expr = files.select { |f| f['file_type'].to_s == 'Expression Matrix' }
      return nil unless expr.size == 1

      file_pick(expr.first, :counts_table, accession: accession)
    end

    def anndata_file?(file)
      return true if file['file_type'].to_s == 'AnnData'

      file['name'].to_s.downcase.end_with?('.h5ad')
    end

    def seurat_file?(file)
      return true if file['file_type'].to_s == 'Seurat'

      name = file['name'].to_s.downcase
      name.end_with?('.rds', '.rdata')
    end

    def prefer_raw_or_smallest(files)
      return nil if files.empty?
      return files.first if files.size == 1

      raw = files.select { |f| f['name'].to_s.match?(/raw|count/i) }
      pool = raw.presence || files
      pool.min_by { |f| f['upload_file_size'].to_i.positive? ? f['upload_file_size'].to_i : Float::INFINITY }
    end

    def file_pick(file, format_kind, accession:)
      name = file['name'].to_s.presence || file['bucket_location'].to_s
      url = file['download_url'].to_s.presence
      if url.blank?
        loc = file['bucket_location'].to_s.presence || name
        if loc.present?
          url = "#{API_BASE}/site/studies/#{CGI.escape(accession)}/download?filename=#{CGI.escape(loc)}"
        end
      end
      return nil if name.blank? || url.blank?

      {
        filename: name,
        url: url,
        filesize: file['upload_file_size'].to_i,
        format_kind: format_kind
      }
    end

    def publication_ids(publications)
      dois = []
      pmids = []
      Array(publications).each do |pub|
        next unless pub.is_a?(Hash)

        url = pub['url'].to_s
        dois << ReferenceIds.extract_doi_from_text(url)
        dois << ReferenceIds.extract_doi_from_text(pub['citation'].to_s)
        pmids << ReferenceIds.normalize_pmid(url)
        pmids << ReferenceIds.normalize_pmid(pub['pmid'] || pub['pubmed_id'])
      end
      [dois.compact.uniq, pmids.compact.uniq]
    end

    def identifiers_from_external_resources(resources)
      out = []
      Array(resources).each do |res|
        next unless res.is_a?(Hash)

        url = (res['url'] || res['link_url']).to_s
        next if url.blank? || !url.start_with?('http')

        ReferenceIds.extract_accession_from_text(url).each do |acc|
          ident = ReferenceIds.identifier_hash(kind: nil, value: acc)
          out << ident if ident
        end
      end
      out.uniq { |h| [h[:kind], h[:value].to_s.upcase] }
    end

    def fetch_json(url, query: nil)
      response = HTTParty.get(
        url,
        query: query,
        headers: { 'Accept' => 'application/json' },
        timeout: 120
      )
      raise "Broad SCP request failed: HTTP #{response.code} for #{url}" unless response.success?

      JSON.parse(response.body)
    end
  end
end
