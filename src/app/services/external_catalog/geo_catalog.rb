# frozen_string_literal: true

require 'httparty'
require 'cgi'
require 'json'

module ExternalCatalog
  # GEO Series (GSE) catalog. Picks one matrix file per series:
  # SC: loom > h5ad > RDS > MTX; bulk: counts table > archive
  # (HT-seq series_matrix is metadata-only and is not cataloged).
  class GeoCatalog
    EUTILS = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils'.freeze
    FTP_HTTPS = 'https://ftp.ncbi.nlm.nih.gov'.freeze

    SC_HINT = /
      single[- ]?cell|scRNA|snRNA|single[- ]?nucleus|10x\s*genomics|
      drop-?seq|smart-?seq|sci-RNA|CITE-seq|scATAC
    /xi.freeze

    def initialize(logger: Rails.logger, email: ENV['NCBI_EMAIL'])
      @logger = logger
      @email = email
    end

    # Yields ExternalCatalog::Entry. +mode+: 'all' | 'sc' | 'bulk'
    def each(limit: nil, mode: 'all')
      return enum_for(:each, limit: limit, mode: mode) unless block_given?

      yielded = 0
      retstart = 0
      page = 100
      loop do
        break if limit.present? && yielded >= limit.to_i

        ids = esearch_ids(retstart: retstart, retmax: page, mode: mode)
        break if ids.empty?

        summaries = esummary(ids)
        summaries.each do |summary|
          break if limit.present? && yielded >= limit.to_i

          entry = entry_from_summary(summary, mode: mode)
          next unless entry

          yield entry
          yielded += 1
        end

        retstart += ids.size
        break if ids.size < page
        sleep 0.34
      end
      yielded
    end

    # Sample FTP listings and return format / classification statistics.
    def explore(sample_size: 40)
      stats = {
        sampled: 0,
        sc_candidates: 0,
        bulk_candidates: 0,
        skipped_no_matrix: 0,
        sc_kinds: Hash.new(0),
        bulk_kinds: Hash.new(0),
        extensions: Hash.new(0),
        examples: { sc: [], bulk: [], skipped: [] }
      }

      each(limit: sample_size, mode: 'all') do |entry|
        stats[:sampled] += 1
        if entry.project_type_tag.to_s == 'sc'
          stats[:sc_candidates] += 1
          stats[:sc_kinds][entry.format_kind] += 1
          stats[:examples][:sc] << { gse: entry.external_id, kind: entry.format_kind, file: entry.filename } if stats[:examples][:sc].size < 5
        else
          stats[:bulk_candidates] += 1
          stats[:bulk_kinds][entry.format_kind] += 1
          stats[:examples][:bulk] << { gse: entry.external_id, kind: entry.format_kind, file: entry.filename } if stats[:examples][:bulk].size < 5
        end
        stats[:extensions][File.extname(entry.filename.to_s).downcase] += 1
      end

      # Also count series scanned that yielded nothing: approximate via esearch page with no entry
      stats
    end

    private

    def esearch_ids(retstart:, retmax:, mode: 'all')
      term =
        case mode.to_s
        when 'sc'
          'gse[Entry Type] AND "Expression profiling by high throughput sequencing"[DataSet Type] AND (single-cell OR scRNA-seq OR "single cell" OR snRNA-seq OR "single nucleus")'
        when 'bulk'
          'gse[Entry Type] AND "Expression profiling by high throughput sequencing"[DataSet Type] NOT (single-cell OR scRNA-seq OR "single cell")'
        else
          'gse[Entry Type] AND "Expression profiling by high throughput sequencing"[DataSet Type]'
        end
      params = {
        db: 'gds',
        term: term,
        retstart: retstart,
        retmax: retmax,
        retmode: 'json',
        sort: 'relevance'
      }
      params[:email] = @email if @email.present?
      response = HTTParty.get("#{EUTILS}/esearch.fcgi", query: params, timeout: 60)
      raise "GEO esearch failed: HTTP #{response.code}" unless response.success?

      body = JSON.parse(response.body)
      Array(body.dig('esearchresult', 'idlist'))
    end

    def esummary(ids)
      params = { db: 'gds', id: ids.join(','), retmode: 'json' }
      params[:email] = @email if @email.present?
      response = HTTParty.get("#{EUTILS}/esummary.fcgi", query: params, timeout: 60)
      raise "GEO esummary failed: HTTP #{response.code}" unless response.success?

      body = JSON.parse(response.body)
      result = body['result'] || {}
      Array(result['uids']).filter_map { |uid| result[uid] }
    end

    def entry_from_summary(summary, mode:)
      accession = summary['accession'].to_s
      return nil unless accession.start_with?('GSE')

      title = summary['title'].to_s
      ftp = summary['ftplink'].to_s
      return nil if ftp.blank?

      gdstype = summary['gdstype'].to_s
      sc = single_cell_series?(title, gdstype)
      return nil if mode.to_s == 'sc' && !sc
      return nil if mode.to_s == 'bulk' && sc

      files = list_geo_files(ftp, accession)
      if sc
        picked = FormatPriority.pick_geo_sc_file(files.map { |f| f[:name] })
        return nil unless picked

        name, kind = picked
        meta = files.find { |f| f[:name] == name }
        project_type = 'sc'
        n_obs = nil
      else
        picked = FormatPriority.pick_geo_bulk_file(files.map { |f| f[:name] })
        return nil unless picked

        name, kind = picked
        meta = files.find { |f| f[:name] == name }
        project_type = 'bulk'
        # GEO esummary n_samples is the series sample count (bulk matrix columns).
        n_obs = positive_int(summary['n_samples'])
      end

      tax_id = extract_tax_id(summary)
      dois, pmids, identifiers = geo_reference_fields(summary, accession)
      filesize = meta[:filesize].to_i
      filesize = remote_filesize(meta[:url]) if filesize <= 0
      Entry.new(
        source: 'geo',
        external_id: accession,
        title: title,
        url: meta[:url],
        tax_id: tax_id,
        organism_label: summary['taxon'].to_s.presence,
        filesize: filesize,
        n_obs: n_obs,
        project_type_tag: project_type,
        format_kind: kind,
        filename: name,
        dois: dois,
        pmids: pmids,
        identifiers: identifiers,
        source_page_url: "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=#{accession}"
      )
    rescue StandardError => e
      @logger.warn("[ExternalCatalog::GeoCatalog] #{accession}: #{e.class} #{e.message}")
      nil
    end

    def geo_reference_fields(summary, accession)
      identifiers = []
      identifiers << ReferenceIds.identifier_hash(kind: 'geo_series', value: accession)

      bioproject = summary['bioproject'].to_s.strip
      identifiers << ReferenceIds.identifier_hash(kind: 'bioproject', value: bioproject) if bioproject.present?

      Array(summary['extrelations']).each do |rel|
        next unless rel.is_a?(Hash)

        target = (rel['targetobject'] || rel['target'] || rel['value']).to_s
        identifiers << ReferenceIds.identifier_hash(kind: nil, value: target)
      end

      pmids = Array(summary['pubmedids']).filter_map { |p| ReferenceIds.normalize_pmid(p) }
      [[], pmids, identifiers.compact]
    end

    def single_cell_series?(title, gdstype)
      text = "#{title} #{gdstype}"
      text.match?(SC_HINT)
    end

    def extract_tax_id(summary)
      tid = summary['taxid'] || summary['taxonid']
      return tid.to_i if tid.to_i > 0

      taxon = summary['taxon'].to_s.split(';').map(&:strip).reject(&:blank?).first.to_s
      return nil if taxon.blank?

      HcaCatalog::SPECIES_TAX[taxon.downcase]
    end

    def list_geo_files(ftp_link, accession)
      https_base = ftp_link.sub(%r{\Aftp://ftp\.ncbi\.nlm\.nih\.gov}, FTP_HTTPS)
      https_base = https_base.sub(%r{\Aftp://}, 'https://')
      https_base += '/' unless https_base.end_with?('/')

      # Suppl only: HT-seq matrix/ holds series_matrix SOFT stubs, not usable counts.
      list_directory("#{https_base}suppl/")
    rescue StandardError => e
      @logger.debug("[ExternalCatalog::GeoCatalog] list #{accession} suppl/: #{e.message}")
      []
    end

    def list_directory(url)
      response = HTTParty.get(url, timeout: 60)
      return [] unless response.success?

      hrefs = response.body.to_s.scan(/href="([^"?]+)"/i).flatten
      hrefs.filter_map do |href|
        name = CGI.unescape(href)
        next if name.end_with?('/')
        next if name == '../' || name == './'

        base = url.end_with?('/') ? url : "#{url}/"
        { name: File.basename(name), url: "#{base}#{name}", filesize: 0 }
      end
    end

    def remote_filesize(url)
      return 0 if url.blank?

      response = HTTParty.head(url, timeout: 30)
      return 0 unless response.success?

      response.headers['content-length'].to_i
    rescue StandardError
      0
    end

    def positive_int(value)
      n = value.to_i
      n.positive? ? n : nil
    end
  end
end
