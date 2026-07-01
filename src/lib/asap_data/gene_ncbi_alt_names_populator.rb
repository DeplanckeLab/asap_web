# frozen_string_literal: true

require "open3"
require "set"

module AsapData
  module GeneNcbiAltNamesPopulator
    module_function

    GENE_INTERNAL_ID_COLUMN = 0
    GENE_DISPLAY_XREF_COLUMN = 7
    NCBI_XREF_TYPE = "1300"
    BATCH_SIZE = 10_000
    RELEASE_TABLES = %w[gene.txt xref.txt object_xref.txt external_synonym.txt].freeze
    UPDATE_FIELDS = %i[name alt_names obsolete_alt_names ncbi_gene_id].freeze

    def populate!(remote_db: default_remote_db, download_missing_tables: default_download_missing_tables?)
      base_dirs = EnsemblAssembliesLoader.all_ensembl_base_dirs
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      stats = {
        organisms_total: 0,
        organisms_processed: 0,
        organisms_skipped: 0,
        releases_applied: 0,
        releases_skipped: 0,
        genes_updated: 0,
        genes_unchanged: 0,
        table_reads: 0,
        table_downloads: 0
      }

      core_folders_cache = {}
      subdomain_latest_releases = EnsemblAssembliesLoader.load_subdomain_latest_releases(remote_db)
      organisms = filter_organisms(EnsemblAssembliesLoader.load_organisms(remote_db))
      stats[:organisms_total] = organisms.size

      organisms.each do |organism|
        processed = populate_for_organism!(
          organism: organism,
          base_dirs: base_dirs,
          subdomain_latest_releases: subdomain_latest_releases,
          core_folders_cache: core_folders_cache,
          remote_db: remote_db,
          download_missing_tables: download_missing_tables,
          stats: stats
        )
        if processed
          stats[:organisms_processed] += 1
        else
          stats[:organisms_skipped] += 1
        end
      end

      stats
    end

    def populate_for_organism!(organism:, base_dirs:, subdomain_latest_releases:, core_folders_cache:, remote_db:, download_missing_tables:, stats:)
      db_type = organism[:subdomain].to_sym
      return false unless EnsemblAssembliesLoader::DB_TYPES.include?(db_type)

      db_genes = load_db_genes(organism[:id], remote_db: remote_db)
      return false if db_genes.empty?

      db_ensembl_ids = db_genes.keys.to_set
      release_numbers = release_numbers_for_organism(
        organism,
        base_dirs,
        subdomain_latest_releases[organism[:subdomain]],
        organism_id: organism[:id],
        remote_db: remote_db
      )
      return false if release_numbers.empty?

      puts "  #{organism[:ensembl_db_name]}: #{release_numbers.size} releases, #{db_genes.size} genes in db"

      release_numbers.each do |release_num|
        release_started = Time.now
        release_dir = EnsemblAssembliesLoader.resolve_release_dir(base_dirs, db_type, release_num)
        unless release_dir
          stats[:releases_skipped] += 1
          next
        end

        release_data = load_release_data(
          release_dir: release_dir,
          db_name: organism[:ensembl_db_name],
          db_type: db_type,
          release_num: release_num,
          db_ensembl_ids: db_ensembl_ids,
          core_folders_cache: core_folders_cache,
          download_missing_tables: download_missing_tables,
          stats: stats
        )
        if release_data.nil?
          stats[:releases_skipped] += 1
          next
        end

        changed = apply_release!(db_genes, release_data)
        stats[:releases_applied] += 1
        puts "    release #{release_num}: #{release_data[:genes].size} genes, " \
             "#{release_data[:xrefs].size} xrefs, #{changed} changed (#{(Time.now - release_started).round(1)}s)"
      end

      RemoteGene.with_remote(remote_db) do
        conn = RemoteGene.connection
        conn.transaction do
          apply_updates!(conn, organism[:id], db_genes, stats: stats)
        end
      end

      true
    end

    def load_db_genes(organism_id, remote_db:)
      genes = {}
      RemoteGene.with_remote(remote_db) do
        RemoteGene.where(organism_id: organism_id).pluck(
          :id, :ensembl_id, :name, :alt_names, :obsolete_alt_names, :ncbi_gene_id
        ).each do |gene_id, ensembl_id, name, alt_names, obsolete_alt_names, ncbi_gene_id|
          genes[ensembl_id.to_s.downcase] = {
            id: gene_id,
            ensembl_id: ensembl_id,
            name: name,
            alt_names: alt_names.to_s,
            obsolete_alt_names: obsolete_alt_names.to_s,
            ncbi_gene_id: ncbi_gene_id,
            original: {
              name: name,
              alt_names: alt_names.to_s,
              obsolete_alt_names: obsolete_alt_names.to_s,
              ncbi_gene_id: ncbi_gene_id
            },
            dirty: false
          }
        end
      end
      genes
    end

    def apply_release!(db_genes, release_data)
      changed = 0
      release_data[:genes].each do |stable_id, gene_info|
        state = db_genes[stable_id.to_s.downcase]
        next unless state

        attrs = build_gene_attributes(
          stable_id,
          gene_info[:internal_id],
          gene_info[:display_xref_id],
          release_data[:object_xrefs][gene_info[:internal_id]],
          release_data[:xrefs],
          release_data[:external_synonyms]
        )
        next if attrs.nil?

        changed += 1 if apply_attributes_to_state!(state, attrs)
      end
      changed
    end

    def build_gene_attributes(stable_id, internal_id, display_xref_id, object_xref_ids, xrefs, external_synonyms)
      return nil if object_xref_ids.nil?

      alt_names = []
      ncbi_gene_id = nil

      object_xref_ids.each do |xref_id|
        xref = xrefs[xref_id]
        next unless xref

        if xref[:type] == NCBI_XREF_TYPE
          ncbi_gene_id = xref[:acc].to_i
          ncbi_name = normalize_name(xref[:name])
          alt_names.push(ncbi_name) if ncbi_name.present? && ncbi_name != "\\N"
        end

        external_synonyms[xref_id]&.each do |syn|
          alt_names.push(syn)
        end
      end

      display_xref = xrefs[display_xref_id]
      name = if display_xref && display_xref[:name].present?
               normalize_name(display_xref[:name])
             else
               stable_id
             end

      alt_names.reject! { |n| n.blank? || n == name }
      alt_names.uniq!

      {
        name: name,
        alt_names: alt_names,
        ncbi_gene_id: ncbi_gene_id
      }
    end

    def apply_attributes_to_state!(state, attrs)
      existing_alt_names = split_csv_names(state[:alt_names])
      existing_obsolete_alt_names = split_csv_names(state[:obsolete_alt_names])
      new_alt_names = attrs[:alt_names]
      new_name = attrs[:name]
      new_alt_names_str = new_alt_names.map { |n| normalize_name(n) }.join(",")
      new_obsolete_alt_names_str = obsolete_alt_names_for_update(
        existing_obsolete_alt_names,
        existing_alt_names,
        state[:name],
        new_alt_names,
        new_name
      )

      changed = new_alt_names_str != state[:alt_names] ||
                new_obsolete_alt_names_str != state[:obsolete_alt_names] ||
                new_name != state[:name] ||
                (attrs[:ncbi_gene_id] && attrs[:ncbi_gene_id] != state[:ncbi_gene_id])

      return false unless changed

      state[:alt_names] = new_alt_names_str
      state[:obsolete_alt_names] = new_obsolete_alt_names_str
      state[:name] = new_name
      state[:ncbi_gene_id] = attrs[:ncbi_gene_id] if attrs[:ncbi_gene_id]
      state[:dirty] = true
      true
    end

    def obsolete_alt_names_for_update(existing_obsolete_alt_names, existing_alt_names, existing_name, new_alt_names, new_name)
      (
        (existing_obsolete_alt_names.map(&:strip) | existing_alt_names | [existing_name]) -
        new_alt_names -
        [new_name] -
        ["null"]
      ).compact.join(",")
    end

    def load_release_data(release_dir:, db_name:, db_type:, release_num:, db_ensembl_ids:, core_folders_cache:, download_missing_tables:, stats:)
      table_paths = RELEASE_TABLES.index_with do |table_name|
        ensure_table_txt(
          release_dir: release_dir,
          db_name: db_name,
          db_type: db_type,
          release_num: release_num,
          table_name: table_name,
          core_folders_cache: core_folders_cache,
          download_missing_tables: download_missing_tables,
          stats: stats
        )
      end

      gene_path = table_paths["gene.txt"]
      xref_path = table_paths["xref.txt"]
      object_xref_path = table_paths["object_xref.txt"]
      return nil unless gene_path&.file? && xref_path&.file? && object_xref_path&.file?

      stats[:table_reads] += 3
      stats[:table_reads] += 1 if table_paths["external_synonym.txt"]&.file?

      genes = parse_genes_filtered(gene_path, db_ensembl_ids, db_type, release_num)
      return nil if genes.empty?

      internal_ids = genes.values.map { |gene| gene[:internal_id] }.to_set
      object_xrefs = parse_gene_object_xrefs_filtered(object_xref_path, internal_ids)

      needed_xref_ids = Set.new
      genes.each_value do |gene|
        needed_xref_ids << gene[:display_xref_id] if gene[:display_xref_id].present?
      end
      object_xrefs.each_value { |xref_ids| needed_xref_ids.merge(xref_ids) }

      xrefs = parse_xrefs_filtered(xref_path, needed_xref_ids)
      object_xrefs.transform_values! { |xref_ids| xref_ids.select { |xref_id| xrefs.key?(xref_id) } }
      object_xrefs.delete_if { |_internal_id, xref_ids| xref_ids.empty? }

      {
        genes: genes,
        xrefs: xrefs,
        object_xrefs: object_xrefs,
        external_synonyms: parse_external_synonyms_filtered(table_paths["external_synonym.txt"], needed_xref_ids, xrefs)
      }
    end

    def parse_genes_filtered(gene_path, db_ensembl_ids, db_type, release_num)
      stable_id_column = GeneFirstEnsemblReleasePopulator.ensembl_id_column(db_type, release_num)
      return {} unless stable_id_column

      genes = {}
      File.foreach(gene_path) do |line|
        line = line.force_encoding("iso-8859-1").encode("utf-8")
        parts = line.chomp.split("\t")
        next if parts.size <= stable_id_column || parts.size <= GENE_DISPLAY_XREF_COLUMN

        internal_id = parts[GENE_INTERNAL_ID_COLUMN].to_s.strip
        stable_id = parts[stable_id_column].to_s.strip
        display_xref_id = parts[GENE_DISPLAY_XREF_COLUMN].to_s.strip
        next if internal_id.blank? || stable_id.blank? || stable_id == "\\N"
        next unless db_ensembl_ids.include?(stable_id.downcase)

        genes[stable_id] = {
          internal_id: internal_id,
          display_xref_id: display_xref_id
        }
      end
      genes
    end

    def parse_xrefs_filtered(xref_path, needed_xref_ids)
      return {} if needed_xref_ids.empty?

      xrefs = {}
      File.foreach(xref_path) do |line|
        line = line.force_encoding("iso-8859-1").encode("utf-8")
        parts = line.chomp.split("\t")
        next if parts.size < 6

        xref_id = parts[0].to_s.strip
        next if xref_id.blank? || !needed_xref_ids.include?(xref_id)

        xrefs[xref_id] = {
          acc: parts[2],
          name: parts[3],
          type: parts[1].to_s,
          description: parts[5]
        }
      end
      xrefs
    end

    def parse_gene_object_xrefs_filtered(object_xref_path, internal_ids)
      return {} if internal_ids.empty?

      mapping = {}
      File.foreach(object_xref_path) do |line|
        parts = line.chomp.split("\t")
        next unless parts.size >= 4
        next unless parts[2].to_s == "Gene"

        internal_id = parts[1].to_s.strip
        xref_id = parts[3].to_s.strip
        next if internal_id.blank? || xref_id.blank?
        next unless internal_ids.include?(internal_id)

        mapping[internal_id] ||= []
        mapping[internal_id] << xref_id
      end
      mapping
    end

    def parse_external_synonyms_filtered(external_synonym_path, needed_xref_ids, xrefs)
      return {} unless external_synonym_path&.file?
      return {} if needed_xref_ids.empty?

      synonyms = {}
      File.foreach(external_synonym_path) do |line|
        line = line.force_encoding("iso-8859-1").encode("utf-8")
        parts = line.chomp.split("\t")
        next if parts.size < 2

        xref_id = parts[0].to_s.strip
        next unless needed_xref_ids.include?(xref_id)
        next unless xrefs[xref_id]

        synonyms[xref_id] ||= []
        synonyms[xref_id] << unquote_synonym(parts[1])
      end
      synonyms
    end

    def parse_xrefs(xref_path)
      xrefs = {}
      File.foreach(xref_path) do |line|
        line = line.force_encoding("iso-8859-1").encode("utf-8")
        parts = line.chomp.split("\t")
        next if parts.size < 6

        xref_id = parts[0].to_s.strip
        next if xref_id.blank?

        xrefs[xref_id] = {
          acc: parts[2],
          name: parts[3],
          type: parts[1].to_s,
          description: parts[5]
        }
      end
      xrefs
    end

    def parse_ncbi_xref_names(xref_path)
      names = {}
      parse_xrefs(xref_path).each do |xref_id, xref|
        next unless xref[:type] == NCBI_XREF_TYPE

        name = normalize_name(xref[:name])
        next if name.blank? || name == "\\N"

        names[xref_id] = name
      end
      names
    end

    def normalize_name(value)
      value.to_s.gsub(/\s+\(\s*\d+\s+of\s+\w+\s*\)/, "").strip
    end

    def unquote_synonym(txt)
      value = txt.to_s.strip
      if value.start_with?("'") && value.end_with?("'")
        value = value[1..-2]
      end
      value
    end

    def split_csv_names(value)
      value.to_s.split(",").reject(&:blank?)
    end

    def release_numbers_for_organism(organism, base_dirs, subdomain_latest_release, organism_id:, remote_db:)
      releases = EnsemblAssembliesLoader.release_numbers_for_scan(
        organism,
        base_dirs,
        subdomain_latest_release,
        download_missing: false
      )
      min_release = min_first_ensembl_release(organism_id, remote_db)
      releases.select! { |release_num| release_num >= min_release } if min_release
      release_from = ENV["ENSEMBL_RELEASE_FROM"].to_s.strip
      releases.select! { |release_num| release_num >= release_from.to_i } if release_from.present?
      releases
    end

    def min_first_ensembl_release(organism_id, remote_db)
      RemoteGene.with_remote(remote_db) do
        RemoteGene.where(organism_id: organism_id).where.not(first_ensembl_release: nil).minimum(:first_ensembl_release)
      end
    end

    def field_changed?(gene, field)
      case field
      when :name
        gene[:name] != gene[:original][:name]
      when :alt_names
        gene[:alt_names] != gene[:original][:alt_names]
      when :obsolete_alt_names
        gene[:obsolete_alt_names] != gene[:original][:obsolete_alt_names]
      when :ncbi_gene_id
        gene[:ncbi_gene_id] != gene[:original][:ncbi_gene_id]
      else
        false
      end
    end

    def apply_updates!(conn, organism_id, db_genes, stats:)
      updates = db_genes.values.select { |gene| gene[:dirty] }
      if updates.empty?
        stats[:genes_unchanged] += db_genes.size
        return
      end

      stats[:genes_unchanged] += db_genes.size - updates.size
      updated_gene_ids = Set.new

      UPDATE_FIELDS.each do |field|
        batch = updates.select { |gene| field_changed?(gene, field) }
        next if batch.empty?

        batch.each_slice(BATCH_SIZE) do |slice|
          updated_gene_ids.merge(apply_field_updates!(conn, organism_id, slice, field))
        end
      end

      stats[:genes_updated] += updated_gene_ids.size
    end

    def apply_field_updates!(conn, organism_id, slice, field)
      column = field.to_s
      values = slice.map do |gene|
        value = gene[field]
        quoted = if field == :ncbi_gene_id
                   value.nil? ? "NULL" : value.to_i
                 else
                   conn.quote(value.to_s)
                 end
        "(#{gene[:id].to_i}, #{quoted})"
      end.join(",")
      sql = <<~SQL
        UPDATE genes AS g
        SET #{column} = v.value
        FROM (VALUES #{values}) AS v(id, value)
        WHERE g.id = v.id
          AND g.organism_id = #{organism_id.to_i}
          AND g.#{column} IS DISTINCT FROM v.value
      SQL
      conn.update(sql)
      slice.map { |gene| gene[:id] }
    end

    def ensure_table_txt(release_dir:, db_name:, db_type:, release_num:, table_name:, core_folders_cache:, download_missing_tables:, stats:)
      organism_dir = release_dir + db_name
      table_path = organism_dir + table_name
      return table_path if table_path.file? && table_path.size?(&:positive?)

      table_gz_path = organism_dir + "#{table_name}.gz"
      if table_gz_path.file? && table_gz_path.size?(&:positive?)
        gunzip_file(table_gz_path)
        return table_path if table_path.file? && table_path.size?(&:positive?)
      end

      archive_path = release_dir + "#{db_name}.tgz"
      if archive_path.file? && archive_path.size?(&:positive?)
        table_base = table_name.delete_suffix(".txt")
        extracted = EnsemblAssembliesLoader.extract_table_from_archive(archive_path, organism_dir, table_base)
        table_path = organism_dir + table_name
        return table_path if extracted&.file? && extracted.size?(&:positive?)
      end

      return nil if table_name == "external_synonym.txt"
      return nil unless download_missing_tables

      core_folders = EnsemblAssembliesLoader.core_folders_for_release(core_folders_cache, db_type, release_num)
      core_folder = EnsemblAssembliesLoader.resolve_core_folder(db_name, core_folders)
      return nil if core_folder.blank?

      FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
      table_base = table_name.delete_suffix(".txt")
      downloaded = download_table_txt(
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        table_name: table_base,
        destination_dir: organism_dir
      )
      stats[:table_downloads] += 1 if downloaded
      return table_path if table_path.file? && table_path.size?(&:positive?)

      nil
    end

    def download_table_txt(db_type:, release_num:, core_folder:, table_name:, destination_dir:)
      url = "#{mysql_base_url(db_type, release_num)}#{core_folder}/#{table_name}.txt.gz"
      destination_gz = destination_dir + "#{table_name}.txt.gz"
      _stdout, stderr, status = Open3.capture3("wget", "-qO", destination_gz.to_s, url)
      unless status.success? && destination_gz.file? && destination_gz.size?(&:positive?)
        FileUtils.rm_f(destination_gz)
        Rails.logger.warn("[GeneNcbiAltNamesPopulator] wget failed for #{url}: #{stderr.strip}")
        return false
      end

      gunzip_file(destination_gz)
      (destination_dir + "#{table_name}.txt").file?
    end

    def gunzip_file(path)
      _stdout, stderr, status = Open3.capture3("gunzip", "-f", path.to_s)
      return if status.success?

      raise "gunzip failed for #{path}: #{stderr.strip}"
    end

    def mysql_base_url(db_type, release_num)
      if db_type == :vertebrates
        "ftp://ftp.ensembl.org/pub/release-#{release_num}/mysql/"
      else
        "ftp://ftp.ensemblgenomes.org/pub/release-#{release_num}/#{db_type}/mysql/"
      end
    end

    def filter_organisms(organisms)
      organism_id = ENV["ORGANISM_ID"].to_s.strip
      if organism_id.present?
        id = organism_id.to_i
        organisms = organisms.select { |organism| organism[:id] == id }
      end

      exclude_ids = parse_organism_id_list(ENV["EXCLUDE_ORGANISM_ID"])
      organisms.reject { |organism| exclude_ids.include?(organism[:id]) }
    end

    def parse_organism_id_list(value)
      value.to_s.split(/[,\s]+/).map(&:strip).reject(&:blank?).map(&:to_i)
    end

    def default_remote_db
      ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    end

    def default_download_missing_tables?
      ENV.fetch("DOWNLOAD_MISSING_TABLES", "false").to_s.strip.downcase == "true"
    end
  end
end
