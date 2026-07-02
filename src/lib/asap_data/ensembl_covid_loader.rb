# frozen_string_literal: true

require "open3"
require "pathname"
require "set"
require "zlib"

module AsapData
  # One-shot loader for Ensembl COVID-19 (SARS-CoV-2): static GTF/TSV dumps, release 101.
  module EnsemblCovidLoader
    module_function

    SUBDOMAIN = "viruses"
    ENSEMBL_DB_NAME = "sars_cov_2"
    ORGANISM_NAME = "SARS-CoV-2"
    TAX_ID = 2697049
    ASSEMBLY_NAME = "ASM985889v3"
    RELEASE = 101
    FTP_BASE = "http://ftp.ensemblgenomes.org/pub/viruses"
    GTF_ARCHIVE = "Sars_cov_2.ASM985889v3.101.gtf.gz"
    REFSEQ_ARCHIVE = "Sars_cov_2.ASM985889v3.101.refseq.tsv.gz"
    ENTREZ_ARCHIVE = "Sars_cov_2.ASM985889v3.101.entrez.tsv.gz"
    CACHED_GTF_NAME = "genes.gtf"

    def populate!(remote_db: default_remote_db, download: default_download?)
      base_dir = writable_base_dir
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" unless base_dir

      stats = {
        download: download,
        files_cached: 0,
        genes_parsed: 0,
        subdomain_created: false,
        organism_created: false,
        assembly_created: false,
        genes_created: 0,
        genes_updated: 0,
        genes_unchanged: 0
      }

      cache_dir = cache_organism_dir(base_dir)
      if download
        stats[:files_cached] = download_files!(cache_dir)
      else
        ensure_cached_files!(cache_dir)
      end

      gtf_path = cache_dir + CACHED_GTF_NAME
      entrez_path = cache_dir + REFSEQ_ARCHIVE.sub(/\.gz\z/, "").sub("refseq", "entrez")
      refseq_path = cache_dir + REFSEQ_ARCHIVE.sub(/\.gz\z/, "")

      genes = parse_genes_from_gtf(gtf_path)
      entrez_xrefs = parse_entrez_xrefs(entrez_path)
      refseq_xrefs = parse_refseq_xrefs(refseq_path)
      gene_records = build_gene_records(genes, entrez_xrefs, refseq_xrefs)
      stats[:genes_parsed] = gene_records.size

      write_meta_file!(cache_dir)

      upsert_stats = upsert_reference_data!(remote_db:, gene_records:)
      stats.merge!(upsert_stats)

      stats
    end

    def parse_genes_from_gtf(path)
      genes = {}
      File.foreach(path) do |line|
        line = line.to_s.strip
        next if line.empty? || line.start_with?("#")

        parts = line.split("\t")
        next unless parts[2] == "gene"

        attrs = parse_gtf_attributes(parts[8])
        ensembl_id = attrs["gene_id"]
        next if ensembl_id.blank?

        start_pos = parts[3].to_i
        end_pos = parts[4].to_i
        genes[ensembl_id] = {
          ensembl_id: ensembl_id,
          name: attrs["gene_name"].presence || ensembl_id,
          biotype: attrs["gene_biotype"],
          chr: parts[0],
          gene_length: (end_pos - start_pos).abs + 1
        }
      end
      genes
    end

    def parse_gtf_attributes(field)
      field.to_s.scan(/([A-Za-z0-9_]+)\s+"([^"]*)"/).to_h
    end

    def parse_entrez_xrefs(path)
      xrefs = Hash.new { |hash, key| hash[key] = { ncbi_gene_id: nil, alt_names: [] } }
      return xrefs unless path.file?

      File.foreach(path).with_index do |line, index|
        next if index.zero?

        parts = line.chomp.split("\t")
        next if parts.size < 5

        gene_id = parts[0].to_s.strip
        xref = parts[3].to_s.strip
        db_name = parts[4].to_s.strip
        next if gene_id.blank?

        if db_name == "EntrezGene" && xref.match?(/\A\d+\z/)
          xrefs[gene_id][:ncbi_gene_id] ||= xref.to_i
        elsif db_name == "EntrezGene_trans_name" && xref.present?
          xrefs[gene_id][:alt_names] << xref
        end
      end
      xrefs
    end

    def parse_refseq_xrefs(path)
      xrefs = Hash.new { |hash, key| hash[key] = [] }
      return xrefs unless path.file?

      File.foreach(path).with_index do |line, index|
        next if index.zero?

        parts = line.chomp.split("\t")
        next if parts.size < 5

        gene_id = parts[0].to_s.strip
        xref = parts[3].to_s.strip
        db_name = parts[4].to_s.strip
        next if gene_id.blank? || xref.blank?
        next unless db_name.start_with?("RefSeq")

        xrefs[gene_id] << xref
      end
      xrefs
    end

    def build_gene_records(genes, entrez_xrefs, refseq_xrefs)
      genes.values.map do |gene|
        xref = entrez_xrefs[gene[:ensembl_id]]
        alt_names = []
        alt_names.concat(refseq_xrefs[gene[:ensembl_id]])
        alt_names.concat(xref[:alt_names]) if xref
        alt_names = alt_names.map(&:strip).reject(&:blank?).uniq - [gene[:name]]

        {
          ensembl_id: gene[:ensembl_id],
          name: gene[:name],
          biotype: gene[:biotype],
          chr: gene[:chr],
          gene_length: gene[:gene_length],
          ncbi_gene_id: xref&.dig(:ncbi_gene_id),
          alt_names: alt_names.join(","),
          first_ensembl_release: RELEASE,
          latest_ensembl_release: RELEASE
        }
      end
    end

    def gene_names_from_gtf(path, ensembl_ids)
      target_ids = Array(ensembl_ids).map { |id| normalize_ensembl_id(id) }.compact.to_set
      return {} if target_ids.empty?

      names = {}
      parse_genes_from_gtf(path).each do |ensembl_id, gene|
        next unless target_ids.include?(normalize_ensembl_id(ensembl_id))

        names[normalize_ensembl_id(ensembl_id)] = gene[:name]
      end
      names
    end

    def cached_gtf_path(base_dirs: nil, release: RELEASE)
      base_dirs ||= EnsemblAssembliesLoader.all_ensembl_base_dirs
      base_dirs.each do |base_dir|
        path = cache_organism_dir(base_dir, release:) + CACHED_GTF_NAME
        return path if path.file? && path.size.positive?
      end
      nil
    end

    def normalize_ensembl_id(value)
      id = value.to_s.strip
      return nil if id.blank?

      id.sub(/\.\d+\z/, "")
    end

    def download_files!(cache_dir)
      FileUtils.mkdir_p(cache_dir)
      count = 0
      [
        [gtf_source_url, cache_dir + GTF_ARCHIVE],
        [refseq_source_url, cache_dir + REFSEQ_ARCHIVE],
        [entrez_source_url, cache_dir + ENTREZ_ARCHIVE]
      ].each do |url, destination|
        next if destination.file? && destination.size.positive?

        fetch_file(url, destination)
        count += 1
      end

      decompress_gtf!(cache_dir)
      decompress_tsv!(cache_dir, REFSEQ_ARCHIVE)
      decompress_tsv!(cache_dir, ENTREZ_ARCHIVE)
      count
    end

    def ensure_cached_files!(cache_dir)
      gtf_path = cache_dir + CACHED_GTF_NAME
      raise ArgumentError, "Missing cached COVID GTF at #{gtf_path} (run with DOWNLOAD_COVID_FILES=true)" unless gtf_path.file?
    end

    def write_meta_file!(cache_dir)
      meta_path = cache_dir + "meta.txt"
      return if meta_path.file? && meta_path.size.positive?

      meta_path.write("1\tassembly\tassembly.name\t#{ASSEMBLY_NAME}\n")
    end

    def upsert_reference_data!(remote_db:, gene_records:)
      stats = {
        subdomain_created: false,
        organism_created: false,
        assembly_created: false,
        genes_created: 0,
        genes_updated: 0,
        genes_unchanged: 0
      }

      RemoteOrganism.with_remote(remote_db) do
        ActiveRecord::Base.transaction do
          subdomain = find_or_create_subdomain!(stats)
          organism = find_or_create_organism!(subdomain, stats)
          find_or_create_assembly!(organism, stats)
          upsert_genes!(organism, gene_records, stats)
        end
      end

      stats
    end

    def find_or_create_subdomain!(stats)
      conn = RemoteOrganism.connection
      row = conn.select_one(<<~SQL.squish)
        SELECT id, latest_ensembl_release
        FROM ensembl_subdomains
        WHERE name = #{conn.quote(SUBDOMAIN)}
        ORDER BY id
        LIMIT 1
      SQL

      if row
        subdomain_id = row["id"].to_i
        if row["latest_ensembl_release"].to_i != RELEASE
          conn.execute(<<~SQL.squish)
            UPDATE ensembl_subdomains
            SET latest_ensembl_release = #{RELEASE}
            WHERE id = #{subdomain_id}
          SQL
        end
        return subdomain_id
      end

      inserted = conn.exec_query(<<~SQL.squish)
        INSERT INTO ensembl_subdomains (name, latest_ensembl_release)
        VALUES (#{conn.quote(SUBDOMAIN)}, #{RELEASE})
        RETURNING id
      SQL
      stats[:subdomain_created] = true
      inserted.first["id"].to_i
    end

    def find_or_create_organism!(subdomain_id, stats)
      organism = RemoteOrganism.find_by(ensembl_db_name: ENSEMBL_DB_NAME) ||
                 RemoteOrganism.find_by(tax_id: TAX_ID)

      attrs = {
        ensembl_db_name: ENSEMBL_DB_NAME,
        ensembl_subdomain_id: subdomain_id,
        latest_ensembl_release: RELEASE,
        tax_id: TAX_ID,
        name: ORGANISM_NAME,
        short_name: ORGANISM_NAME
      }

      if organism
        organism.update!(attrs)
        return organism
      end

      stats[:organism_created] = true
      RemoteOrganism.create!(attrs)
    end

    def find_or_create_assembly!(organism, stats)
      assembly = RemoteAssembly.find_by(organism_id: organism.id, name: ASSEMBLY_NAME)
      attrs = {
        organism_id: organism.id,
        name: ASSEMBLY_NAME,
        first_ensembl_release: RELEASE,
        latest_ensembl_release: RELEASE
      }

      if assembly
        assembly.update!(attrs)
        return assembly
      end

      stats[:assembly_created] = true
      RemoteAssembly.create!(attrs)
    end

    def upsert_genes!(organism, gene_records, stats)
      existing = RemoteGene.where(organism_id: organism.id).index_by { |gene| gene.ensembl_id.to_s.downcase }

      gene_records.each do |attrs|
        key = attrs[:ensembl_id].to_s.downcase
        gene = existing[key]
        if gene
          if gene_changed?(gene, attrs)
            gene.update!(attrs)
            stats[:genes_updated] += 1
          else
            stats[:genes_unchanged] += 1
          end
        else
          RemoteGene.create!(attrs.merge(organism_id: organism.id))
          stats[:genes_created] += 1
        end
      end
    end

    def gene_changed?(gene, attrs)
      attrs.any? do |field, value|
        gene.public_send(field) != value
      end
    end

    def cache_organism_dir(base_dir, release: RELEASE)
      Pathname.new(base_dir) + SUBDOMAIN + release.to_s + ENSEMBL_DB_NAME
    end

    def writable_base_dir
      base_dirs = EnsemblAssembliesLoader.all_ensembl_base_dirs
      if base_dirs.empty?
        candidate = Pathname.new(
          ENV["ENSEMBL_DATA_DIR"].presence || EnsemblAssembliesLoader::DEFAULT_ENSEMBL_DATA_DIR
        )
        FileUtils.mkdir_p(candidate) unless candidate.directory?
        return candidate if candidate.directory?
      end

      EnsemblAssembliesLoader.writable_ensembl_base_dir(base_dirs)
    end

    def gtf_source_url
      "#{FTP_BASE}/gtf/sars_cov_2/#{GTF_ARCHIVE}"
    end

    def refseq_source_url
      "#{FTP_BASE}/tsv/sars_cov_2/#{REFSEQ_ARCHIVE}"
    end

    def entrez_source_url
      "#{FTP_BASE}/tsv/sars_cov_2/#{ENTREZ_ARCHIVE}"
    end

    def fetch_file(url, destination_path)
      _stdout, stderr, status = Open3.capture3("curl", "-s", "-f", "-L", "-o", destination_path.to_s, url)
      return if status.success? && destination_path.file? && destination_path.size.positive?

      FileUtils.rm_f(destination_path)
      raise "Failed to download #{url}: #{stderr.strip}"
    end

    def decompress_gtf!(cache_dir)
      archive = cache_dir + GTF_ARCHIVE
      destination = cache_dir + CACHED_GTF_NAME
      return if destination.file? && destination.size.positive?

      Zlib::GzipReader.open(archive.to_s) do |gz|
        destination.write(gz.read)
      end
    end

    def decompress_tsv!(cache_dir, archive_name)
      archive = cache_dir + archive_name
      destination = cache_dir + archive_name.sub(/\.gz\z/, "")
      return if destination.file? && destination.size.positive?

      Zlib::GzipReader.open(archive.to_s) do |gz|
        destination.write(gz.read)
      end
    end

    def default_remote_db
      ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    end

    def default_download?
      ENV.fetch("DOWNLOAD_COVID_FILES", "true").to_s.strip.downcase != "false"
    end
  end
end
