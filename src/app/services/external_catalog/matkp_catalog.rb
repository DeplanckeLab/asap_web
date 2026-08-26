# frozen_string_literal: true

require 'httparty'
require 'cgi'
require 'zlib'
require 'stringio'

module ExternalCatalog
  # Enumerates MATKP single-cell datasets that publish a public processed matrix
  # (download_public → api.kpndataregistry.org ZIP containing norm_counts.tsv.gz).
  # https://matkp.org/datasets.html
  class MatkpCatalog
    METADATA_URL =
      'https://matkp.hugeampkpnbi.org/api/raw/file/single_cell_all_metadata/dataset_metadata.json.gz'.freeze
    SOURCE_PAGE = ->(dataset_id) { "https://matkp.org/datasets.html?dataset=#{CGI.escape(dataset_id)}" }
    HTTP_HEADERS = {
      'Accept' => 'application/json, application/gzip, */*',
      'User-Agent' => 'ASAP-external-catalog (https://asap.epfl.ch)'
    }.freeze

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      yielded = 0
      fetch_rows.each do |row|
        break if limit.present? && yielded >= limit.to_i

        entry = entry_from_row(row)
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

    def fetch_rows
      response = HTTParty.get(METADATA_URL, headers: HTTP_HEADERS, timeout: 120)
      raise "MATKP metadata request failed: HTTP #{response.code}" unless response.success?

      body = response.body.to_s
      text =
        if gzip_magic?(body)
          Zlib::GzipReader.new(StringIO.new(body)).read
        else
          body
        end

      rows = []
      text.each_line do |line|
        line = line.strip
        next if line.blank?

        parsed = JSON.parse(line)
        rows << parsed if parsed.is_a?(Hash)
      end
      rows
    end

    def gzip_magic?(bytes)
      bytes.bytesize >= 2 && bytes.getbyte(0) == 0x1f && bytes.getbyte(1) == 0x8b
    end

    def entry_from_row(row)
      return nil unless row['data_type'].to_s == 'single_cell'

      dataset_id = row['datasetId'].to_s.strip
      download_url = row['download_public'].to_s.strip
      return nil if dataset_id.blank? || download_url.blank?
      return nil unless download_url.start_with?('http')

      species = row['species'].to_s.strip.presence
      tax_id = species.present? ? HcaCatalog::SPECIES_TAX[species.downcase] : nil
      raise "MATKP #{dataset_id}: unknown species #{species.inspect}" if tax_id.blank?

      title = row['datasetName'].to_s.strip.presence || dataset_id
      depot = [row['depot'], row['depot2']].map { |v| v.to_s.strip.presence }.compact
      if depot.any? && !title.downcase.include?(depot.first.downcase)
        title = "#{title} (#{depot.join(', ')})"
      end

      n_obs = row['totalSamples'].to_i
      n_obs = nil if n_obs <= 0
      filesize = probe_filesize(download_url)
      dois = [ReferenceIds.normalize_doi(row['doi'])].compact
      pmids = [ReferenceIds.normalize_pmid(row['pmid'])].compact
      identifiers = geo_identifiers_from_source(row['sourceDataset'])

      Entry.new(
        source: 'matkp',
        external_id: dataset_id,
        title: title,
        url: download_url,
        tax_id: tax_id,
        organism_label: species,
        filesize: filesize,
        n_obs: n_obs,
        project_type_tag: 'sc',
        format_kind: :zip,
        filename: "#{dataset_id}.zip",
        dois: dois,
        pmids: pmids,
        identifiers: identifiers,
        source_page_url: SOURCE_PAGE.call(dataset_id)
      )
    rescue StandardError => e
      @logger.error(
        "[ExternalCatalog::MatkpCatalog] #{row['datasetId']}: #{e.class} #{e.message}"
      )
      nil
    end

    def geo_identifiers_from_source(source_dataset)
      text = source_dataset.to_s
      ids = []
      text.scan(/\bGSE\d+\b/i).each do |gse|
        ids << ReferenceIds.identifier_hash(kind: 'geo_series', value: gse.upcase)
      end
      ids.compact.uniq { |h| [h[:kind], h[:value].to_s.upcase] }
    end

    # Prefer Content-Range / Content-Length without downloading the full ZIP.
    def probe_filesize(url)
      response = HTTParty.get(
        url,
        headers: HTTP_HEADERS.merge('Range' => 'bytes=0-0'),
        timeout: 60,
        follow_redirects: true
      )
      cr = response.headers['content-range'].to_s
      if (m = cr.match(%r{/(\d+)\z}))
        return m[1].to_i
      end

      cl = response.headers['content-length'].to_s
      return cl.to_i if cl.match?(/\A\d+\z/) && response.code.to_i != 206

      0
    rescue StandardError => e
      @logger.warn("[ExternalCatalog::MatkpCatalog] filesize probe: #{e.class} #{e.message}")
      0
    end
  end
end
