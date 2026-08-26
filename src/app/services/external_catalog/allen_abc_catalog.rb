# frozen_string_literal: true

require 'httparty'
require 'rexml/document'

module ExternalCatalog
  # Enumerates raw AnnData (h5ad) expression matrices from the Allen Brain Cell
  # Atlas AWS public dataset (latest releases/*/manifest.json).
  # Spatial / multiome / section packages are skipped; ASAP catalog imports are sc.
  class AllenAbcCatalog
    S3_BASE = 'https://allen-brain-cell-atlas.s3.us-west-2.amazonaws.com'.freeze
    RELEASES_LIST =
      "#{S3_BASE}/?list-type=2&prefix=releases/&delimiter=/".freeze
    SOURCE_PAGE = 'https://knowledge.brain-map.org/abcatlas'.freeze
    HTTP_HEADERS = {
      'Accept' => 'application/json, application/xml, text/xml, */*',
      'User-Agent' => 'ASAP-external-catalog (https://asap.epfl.ch)'
    }.freeze

    # Directory names that publish sc/snRNA 10x (or compatible) raw h5ads.
    INCLUDE_DIRECTORY = /\A(
      WMB-10Xv2|WMB-10Xv3|
      WHB-10Xv3|
      SEA-AD-CaH-10X|SEA-AD-Multiregion-10X|
      Consensus-WMB-AIBS-10X|Consensus-WMB-Macosko-10X|
      Zeng-Aging-Mouse-10Xv3|
      Developing-Mouse-Vis-Cortex-10X|
      ASAP-PMDBS-10X
    )\z/x.freeze

    DIRECTORY_TAX = {
      'WMB-10Xv2' => [10090, 'Mus musculus'],
      'WMB-10Xv3' => [10090, 'Mus musculus'],
      'Consensus-WMB-AIBS-10X' => [10090, 'Mus musculus'],
      'Consensus-WMB-Macosko-10X' => [10090, 'Mus musculus'],
      'Zeng-Aging-Mouse-10Xv3' => [10090, 'Mus musculus'],
      'Developing-Mouse-Vis-Cortex-10X' => [10090, 'Mus musculus'],
      'WHB-10Xv3' => [9606, 'Homo sapiens'],
      'SEA-AD-CaH-10X' => [9606, 'Homo sapiens'],
      'SEA-AD-Multiregion-10X' => [9606, 'Homo sapiens'],
      'ASAP-PMDBS-10X' => [9606, 'Homo sapiens']
    }.freeze

    def initialize(logger: Rails.logger, manifest_url: nil)
      @logger = logger
      @manifest_url = manifest_url
    end

    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      manifest = fetch_manifest
      version = manifest['version'].to_s
      yielded = 0
      each_raw_h5ad(manifest) do |row|
        break if limit.present? && yielded >= limit.to_i

        entry = entry_from_row(row, release_version: version)
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

    def fetch_manifest
      url = @manifest_url.presence || latest_manifest_url
      response = HTTParty.get(url, headers: HTTP_HEADERS, timeout: 120)
      raise "Allen ABC manifest failed: HTTP #{response.code} url=#{url}" unless response.success?

      JSON.parse(response.body)
    end

    def latest_manifest_url
      response = HTTParty.get(RELEASES_LIST, headers: HTTP_HEADERS, timeout: 60)
      raise "Allen ABC releases list failed: HTTP #{response.code}" unless response.success?

      doc = REXML::Document.new(response.body)
      prefixes = []
      doc.elements.each('//CommonPrefixes/Prefix') do |el|
        prefixes << el.text.to_s
      end
      versions = prefixes.filter_map do |prefix|
        m = prefix.to_s.match(%r{\Areleases/(\d{8})/\z})
        m && m[1]
      end
      raise 'Allen ABC releases list returned no dated manifests' if versions.empty?

      latest = versions.max
      "#{S3_BASE}/releases/#{latest}/manifest.json"
    end

    def each_raw_h5ad(manifest)
      file_listing = manifest['file_listing'] || {}
      file_listing.each do |directory, kinds|
        next unless directory.to_s.match?(INCLUDE_DIRECTORY)

        matrices = (kinds.is_a?(Hash) ? kinds['expression_matrices'] : nil) || {}
        matrices.each do |matrix_name, variants|
          next unless variants.is_a?(Hash)

          raw = variants['raw']
          next unless raw.is_a?(Hash)

          h5ad = ((raw['files'] || {})['h5ad'])
          next unless h5ad.is_a?(Hash) && h5ad['url'].to_s.strip.present?

          yield(
            directory: directory.to_s,
            matrix_name: matrix_name.to_s,
            url: h5ad['url'].to_s.strip,
            filesize: h5ad['size'].to_i,
            relative_path: h5ad['relative_path'].to_s
          )
        end
      end
    end

    def entry_from_row(row, release_version:)
      directory = row[:directory]
      matrix_name = row[:matrix_name]
      return nil if directory.blank? || matrix_name.blank?

      tax_id, organism_label = DIRECTORY_TAX[directory]
      raise "Missing tax mapping for Allen ABC directory=#{directory}" if tax_id.blank?

      title = "#{directory} / #{matrix_name} (Allen Brain Cell Atlas #{release_version})"
      filename = File.basename(row[:relative_path].presence || "#{matrix_name}-raw.h5ad")

      Entry.new(
        source: 'allen_abc',
        external_id: matrix_name,
        title: title,
        url: row[:url],
        tax_id: tax_id,
        organism_label: organism_label,
        filesize: row[:filesize].to_i,
        n_obs: nil,
        project_type_tag: 'sc',
        format_kind: :h5ad,
        filename: filename,
        dois: [],
        pmids: [],
        identifiers: [],
        source_page_url: SOURCE_PAGE,
        collection_id: directory,
        collection_title: directory,
        collection_description:
          "Allen Brain Cell Atlas release #{release_version} package #{directory}"
      )
    rescue StandardError => e
      @logger.error(
        "[ExternalCatalog::AllenAbcCatalog] #{row[:matrix_name]}: #{e.class} #{e.message}"
      )
      nil
    end
  end
end
