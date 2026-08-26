# frozen_string_literal: true

require 'httparty'
require 'cgi'

module ExternalCatalog
  # Enumerates Single Cell Expression Atlas project H5AD files from the EBI FTP
  # mirror, enriched with the public experiments JSON (title, species, assay count).
  class EbiScCatalog
    FTP_BASE =
      'https://ftp.ebi.ac.uk/pub/databases/microarray/data/atlas/sc_experiments'.freeze
    EXPERIMENTS_JSON = 'https://www.ebi.ac.uk/gxa/sc/json/experiments'.freeze
    SOURCE_PAGE = ->(accession) { "https://www.ebi.ac.uk/gxa/sc/experiments/#{accession}" }

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def each(limit: nil)
      return enum_for(:each, limit: limit) unless block_given?

      meta_by_accession = fetch_experiment_metadata
      yielded = 0
      list_experiment_accessions.each do |accession|
        break if limit.present? && yielded >= limit.to_i

        entry = entry_for_accession(accession, meta_by_accession[accession])
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

    def fetch_experiment_metadata
      response = HTTParty.get(EXPERIMENTS_JSON, timeout: 120)
      raise "EBI SC Atlas experiments request failed: HTTP #{response.code}" unless response.success?

      payload = JSON.parse(response.body)
      experiments = payload.is_a?(Hash) ? (payload['experiments'] || []) : Array(payload)
      experiments.each_with_object({}) do |row, acc|
        next unless row.is_a?(Hash)

        accession = row['experimentAccession'].to_s.strip
        next if accession.blank?

        acc[accession] = row
      end
    end

    def list_experiment_accessions
      response = HTTParty.get("#{FTP_BASE}/", timeout: 120)
      raise "EBI SC Atlas FTP listing failed: HTTP #{response.code}" unless response.success?

      response.body.to_s.scan(%r{href="(E-[A-Za-z0-9]+-\d+)/"}i).flatten.uniq
    end

    def entry_for_accession(accession, meta)
      h5ad = pick_h5ad_file(accession)
      return nil unless h5ad

      title = meta && meta['experimentDescription'].to_s.strip.presence
      species = meta && meta['species'].to_s.strip.presence
      n_obs = meta && meta['numberOfAssays'].to_i
      n_obs = nil if n_obs.to_i <= 0
      tax_id = species.present? ? HcaCatalog::SPECIES_TAX[species.downcase] : nil
      dois, pmids = fetch_publication_ids(accession)
      identifiers = [ReferenceIds.identifier_hash(kind: 'array_express', value: accession)]
      if (m = accession.match(/\AE-GEOD-(\d+)\z/i))
        identifiers << ReferenceIds.identifier_hash(kind: 'geo_series', value: "GSE#{m[1]}")
      end

      Entry.new(
        source: 'ebi_sc',
        external_id: accession,
        title: title.presence || accession,
        url: h5ad[:url],
        tax_id: tax_id,
        organism_label: species,
        filesize: h5ad[:filesize].to_i,
        n_obs: n_obs,
        project_type_tag: 'sc',
        format_kind: :h5ad,
        filename: h5ad[:name],
        dois: dois,
        pmids: pmids,
        identifiers: identifiers.compact,
        source_page_url: SOURCE_PAGE.call(accession)
      )
    rescue StandardError => e
      @logger.error("[ExternalCatalog::EbiScCatalog] #{accession}: #{e.class} #{e.message}")
      nil
    end

    # Prefer `{accession}.project.h5ad`; otherwise the sole `.h5ad` in the directory.
    def pick_h5ad_file(accession)
      files = list_directory_files("#{FTP_BASE}/#{accession}/")
      h5ads = files.select { |f| f[:name].to_s.downcase.end_with?('.h5ad') }
      return nil if h5ads.empty?

      project = h5ads.find { |f| f[:name].to_s.match?(/\.project\.h5ad\z/i) }
      project || (h5ads.size == 1 ? h5ads.first : nil)
    end

    def list_directory_files(url)
      response = HTTParty.get(url, timeout: 60)
      return [] unless response.success?

      body = response.body.to_s
      files = []
      body.scan(
        %r{href="([^"?]+)"[^>]*>.*?</td>\s*<td[^>]*>[^<]*</td>\s*<td[^>]*align="right">\s*([^<]+)\s*</td>}im
      ) do |href, size_label|
        name = CGI.unescape(href.to_s)
        next if name.end_with?('/')
        next if name == '../' || name == './'

        base = url.end_with?('/') ? url : "#{url}/"
        files << {
          name: File.basename(name),
          url: "#{base}#{File.basename(name)}",
          filesize: parse_apache_size(size_label)
        }
      end

      if files.empty?
        body.scan(/href="([^"?]+)"/i).flatten.each do |href|
          name = CGI.unescape(href.to_s)
          next if name.end_with?('/')
          next if name == '../' || name == './'

          base = url.end_with?('/') ? url : "#{url}/"
          files << { name: File.basename(name), url: "#{base}#{File.basename(name)}", filesize: 0 }
        end
      end
      files
    end

    def fetch_publication_ids(accession)
      url = "#{FTP_BASE}/#{accession}/#{accession}.idf.txt"
      response = HTTParty.get(url, timeout: 60)
      return [[], []] unless response.success?

      dois = []
      pmids = []
      response.body.to_s.each_line do |line|
        key, value = line.split("\t", 2)
        next if key.blank? || value.blank?

        case key.strip
        when /\APublication DOI\z/i
          dois << ReferenceIds.normalize_doi(value.strip)
        when /\APubMed ID\z/i
          value.split(/[;,|\s]+/).each do |part|
            pmids << ReferenceIds.normalize_pmid(part)
          end
        end
      end
      [dois.compact.uniq, pmids.compact.uniq]
    rescue StandardError => e
      @logger.warn("[ExternalCatalog::EbiScCatalog] IDF #{accession}: #{e.class} #{e.message}")
      [[], []]
    end

    def parse_apache_size(label)
      s = label.to_s.strip
      return 0 if s.blank? || s == '-'

      if (m = s.match(/\A([\d.]+)\s*([KMGTP])?\z/i))
        n = m[1].to_f
        unit = (m[2] || '').upcase
        factor =
          case unit
          when 'K' then 1024
          when 'M' then 1024**2
          when 'G' then 1024**3
          when 'T' then 1024**4
          when 'P' then 1024**5
          else 1
          end
        return (n * factor).round
      end

      s.delete(',').to_i
    end
  end
end
