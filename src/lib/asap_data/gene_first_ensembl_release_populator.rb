# frozen_string_literal: true

require "open3"
require "set"
require "shellwords"

module AsapData
  module GeneFirstEnsemblReleasePopulator
    module_function

    BATCH_SIZE = 50_000
    # Allow ':' for older metazoa IDs such as TCOGS2:TC000001
    ENSEMBL_ID_PATTERN = /\A[A-Za-z]+[0-9A-Za-z._:-]+\z/

    def populate!(remote_db: default_remote_db, download_missing_gene_table: default_download_missing_gene_table?, force: default_force?)
      base_dirs = EnsemblAssembliesLoader.all_ensembl_base_dirs
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      stats = {
        organisms_total: 0,
        organisms_processed: 0,
        organisms_skipped: 0,
        genes_updated: 0,
        latest_genes_updated: 0,
        genes_unchanged: 0,
        genes_without_match: 0,
        gene_table_reads: 0,
        gene_table_downloads: 0,
        corrupt_gene_table_reads: 0
      }

      core_folders_cache = {}
      stable_id_map_cache = {}
      archive_members_cache = {}
      subdomain_latest_releases = EnsemblAssembliesLoader.load_subdomain_latest_releases(remote_db)
      organisms = filter_organisms(EnsemblAssembliesLoader.load_organisms(remote_db))
      stats[:organisms_total] = organisms.size

      organisms.each do |organism|
        organism_start = Time.now
        reads_before = stats[:gene_table_reads]
        updated_before = stats[:genes_updated]
        genes_to_update = count_genes_to_update(organism: organism, remote_db: remote_db, force: force)
        if genes_to_update.zero?
          stats[:organisms_skipped] += 1
          next
        end

        puts "  scanning #{organism[:ensembl_db_name]} (#{organism[:subdomain]}): #{genes_to_update} genes to update..."
        $stdout.flush
        updated = populate_for_organism!(
          organism: organism,
          base_dirs: base_dirs,
          subdomain_latest_releases: subdomain_latest_releases,
          core_folders_cache: core_folders_cache,
          stable_id_map_cache: stable_id_map_cache,
          archive_members_cache: archive_members_cache,
          remote_db: remote_db,
          download_missing_gene_table: download_missing_gene_table,
          force: force,
          stats: stats
        )
        if updated
          stats[:organisms_processed] += 1
          puts(
            "  organism #{organism[:ensembl_db_name]} (#{organism[:subdomain]}): " \
            "updated=#{stats[:genes_updated] - updated_before} reads=#{stats[:gene_table_reads] - reads_before} " \
            "(#{(Time.now - organism_start).round(1)}s)"
          )
          $stdout.flush
        else
          stats[:organisms_skipped] += 1
          puts(
            "  skipped #{organism[:ensembl_db_name]} (#{organism[:subdomain]}): " \
            "no ensembl matches in #{stats[:gene_table_reads] - reads_before} release reads " \
            "(#{(Time.now - organism_start).round(1)}s)"
          )
          $stdout.flush
        end
      end

      stats
    end

    def populate_for_organism!(organism:, base_dirs:, subdomain_latest_releases:, core_folders_cache:, stable_id_map_cache:, archive_members_cache:, remote_db:, download_missing_gene_table:, force:, stats:)
      db_type = organism[:subdomain].to_sym
      return false unless EnsemblAssembliesLoader::DB_TYPES.include?(db_type)

      release_numbers = EnsemblAssembliesLoader.release_numbers_for_scan(
        organism,
        base_dirs,
        subdomain_latest_releases[organism[:subdomain]],
        download_missing: download_missing_gene_table
      )
      return false if release_numbers.empty?

      gene_rows = load_gene_rows_for_update!(organism: organism, remote_db: remote_db, force: force)
      return false if gene_rows.nil?

      target_ensembl_ids = gene_rows.map { |row| row[:ensembl_key] }.to_set
      first_release_by_ensembl = {}
      latest_release_by_ensembl = {}

      release_numbers.each do |release_num|
        read = accumulate_ensembl_releases!(
          release_dir: resolve_release_dir_for_scan(base_dirs, db_type, release_num, download_missing_gene_table),
          db_name: organism[:ensembl_db_name],
          db_type: db_type,
          release_num: release_num,
          core_folders_cache: core_folders_cache,
          stable_id_map_cache: stable_id_map_cache,
          archive_members_cache: archive_members_cache,
          download_missing_gene_table: download_missing_gene_table,
          target_ensembl_ids: target_ensembl_ids,
          first_release_by_ensembl: first_release_by_ensembl,
          latest_release_by_ensembl: latest_release_by_ensembl,
          stats: stats
        )
        stats[:gene_table_reads] += 1 if read
      end
      return false if first_release_by_ensembl.empty?

      RemoteGene.with_remote(remote_db) do
        conn = RemoteGene.connection
        updates = build_gene_updates(gene_rows, first_release_by_ensembl, latest_release_by_ensembl, force: force, stats: stats)
        apply_combined_updates!(conn, organism[:id], updates, stats: stats)
      end

      true
    end

    def count_genes_to_update(organism:, remote_db:, force:)
      RemoteGene.with_remote(remote_db) do
        scope = RemoteGene.where(organism_id: organism[:id])
        unless force
          scope = scope.where("first_ensembl_release IS NULL OR latest_ensembl_release IS NULL")
        end
        scope.count
      end
    end

    def load_gene_rows_for_update!(organism:, remote_db:, force:)
      rows = nil
      RemoteGene.with_remote(remote_db) do
        scope = RemoteGene.where(organism_id: organism[:id])
        unless force
          scope = scope.where("first_ensembl_release IS NULL OR latest_ensembl_release IS NULL")
        end
        rows = scope.pluck(:id, :ensembl_id, :first_ensembl_release, :latest_ensembl_release).map do |gene_id, ensembl_id, current_first, current_latest|
          {
            gene_id: gene_id,
            ensembl_key: ensembl_id.to_s.downcase,
            current_first: current_first,
            current_latest: current_latest
          }
        end
      end
      rows.empty? ? nil : rows
    end

    def build_gene_updates(gene_rows, first_release_by_ensembl, latest_release_by_ensembl, force:, stats:)
      updates = []
      gene_rows.each do |row|
        target_first = first_release_by_ensembl[row[:ensembl_key]]
        target_latest = latest_release_by_ensembl[row[:ensembl_key]]
        if target_first.nil?
          stats[:genes_without_match] += 1
          next
        end

        target_latest ||= target_first
        current_first = row[:current_first]
        current_latest = row[:current_latest]
        first_needs_update = force || current_first.nil? || current_first != target_first
        latest_needs_update = force || current_latest.nil? || current_latest != target_latest ||
                              (current_first.present? && current_latest.present? && current_first > current_latest)

        if !first_needs_update && !latest_needs_update
          stats[:genes_unchanged] += 1
          next
        end

        updates << [
          row[:gene_id],
          first_needs_update ? target_first : current_first,
          latest_needs_update ? target_latest : current_latest
        ]
      end
      updates
    end

    def resolve_release_dir_for_scan(base_dirs, db_type, release_num, download_missing_gene_table)
      release_dir = EnsemblAssembliesLoader.resolve_release_dir(base_dirs, db_type, release_num)
      return release_dir if release_dir || !download_missing_gene_table

      EnsemblAssembliesLoader.ensure_release_dir(
        EnsemblAssembliesLoader.writable_ensembl_base_dir(base_dirs),
        db_type,
        release_num
      )
    end

    def apply_combined_updates!(conn, organism_id, updates, stats:)
      updates.each_slice(BATCH_SIZE) do |slice|
        ids = slice.map { |row| row[0].to_i }
        firsts = slice.map { |row| row[1].to_i }
        latests = slice.map { |row| row[2].to_i }
        sql = <<~SQL
          UPDATE genes AS g
          SET first_ensembl_release = v.first_release,
              latest_ensembl_release = v.latest_release
          FROM (
            SELECT *
            FROM unnest(
              ARRAY[#{ids.join(',')}]::bigint[],
              ARRAY[#{firsts.join(',')}]::int[],
              ARRAY[#{latests.join(',')}]::int[]
            ) AS t(gene_id, first_release, latest_release)
          ) AS v
          WHERE g.id = v.gene_id
            AND g.organism_id = #{organism_id.to_i}
        SQL
        updated = conn.update(sql)
        stats[:genes_updated] += updated.to_i
        stats[:latest_genes_updated] += updated.to_i
      end
    end

    def accumulate_ensembl_releases!(release_dir:, db_name:, db_type:, release_num:, core_folders_cache:, stable_id_map_cache:, archive_members_cache:, download_missing_gene_table:, target_ensembl_ids:, first_release_by_ensembl:, latest_release_by_ensembl:, stats:)
      return false if release_dir.nil?

      stream = lambda do |ensembl_id|
        record_ensembl_release!(
          first_release_by_ensembl,
          latest_release_by_ensembl,
          ensembl_id,
          release_num,
          target_ensembl_ids: target_ensembl_ids
        )
      end

      # Early Ensembl schemas keep stable IDs in gene_stable_id.txt (gene.txt has \\N).
      # Prefer that table when present or downloadable — also avoids parsing full gene.txt.
      stable_id_source = if download_missing_gene_table
        resolve_gene_stable_id_source(
          release_dir: release_dir,
          db_name: db_name,
          db_type: db_type,
          release_num: release_num,
          core_folders_cache: core_folders_cache,
          archive_members_cache: archive_members_cache,
          download_missing_gene_table: download_missing_gene_table,
          stats: stats
        )
      else
        find_gene_stable_id_source(
          release_dir: release_dir,
          db_name: db_name,
          archive_members_cache: archive_members_cache
        )
      end

      if stable_id_source
        stream_ensembl_ids_from_stable_id_table(stable_id_source, stats: stats, &stream)
        return true
      end

      source = resolve_gene_table_source(
        release_dir: release_dir,
        db_name: db_name,
        db_type: db_type,
        release_num: release_num,
        core_folders_cache: core_folders_cache,
        archive_members_cache: archive_members_cache,
        download_missing_gene_table: download_missing_gene_table,
        stats: stats
      )
      return false unless source

      column = ensembl_id_column(db_type, release_num)
      unless column
        puts "  WARN skipping release #{release_num} for #{db_name}: no gene table column mapping"
        return false
      end

      stream_ensembl_ids(source, column: column, stats: stats, &stream)
      true
    end

    def stream_ensembl_ids_from_stable_id_table(source, stats: nil)
      each_gene_table_line(source, stats: stats) do |line|
        parts = line.chomp.split("\t", 3)
        next if parts.size < 2

        ensembl_id = parts[1].to_s.strip
        next if ensembl_id.blank? || ensembl_id == "\\N"
        next unless valid_ensembl_id?(ensembl_id)

        yield ensembl_id
      end
    end

    def record_ensembl_release!(first_release_by_ensembl, latest_release_by_ensembl, ensembl_id, release_num, target_ensembl_ids:)
      key = ensembl_id.downcase
      return unless target_ensembl_ids.include?(key)

      first_release_by_ensembl[key] ||= release_num
      latest_release_by_ensembl[key] = release_num
    end

    def cached_gene_stable_id_map(cache:, source:, release_dir:, db_name:, stats:)
      cache_key = "#{release_dir}/#{db_name}/gene_stable_id"
      return cache[cache_key] if cache.key?(cache_key)

      cache[cache_key] = load_gene_stable_id_map(source: source, stats: stats)
    end

    def resolve_gene_table_source(release_dir:, db_name:, db_type:, release_num:, core_folders_cache:, archive_members_cache:, download_missing_gene_table:, stats:)
      organism_dir = release_dir + db_name
      txt_path = organism_dir + "gene.txt"
      return { type: :file, path: txt_path } if text_file_present?(txt_path)

      gz_path = organism_dir + "gene.txt.gz"
      return { type: :gzip, path: gz_path } if gzip_file_present?(gz_path)

      archive_path = release_dir + "#{db_name}.tgz"
      if archive_path.file?
        return { type: :archive, path: archive_path, member: "#{db_name}/gene.txt" } if archive_member?(archive_members_cache, archive_path, "#{db_name}/gene.txt")
        return { type: :archive, path: archive_path, member: "#{db_name}/gene.txt.gz", gzip: true } if archive_member?(archive_members_cache, archive_path, "#{db_name}/gene.txt.gz")
      end

      return nil unless download_missing_gene_table

      ensure_gene_txt(
        release_dir: release_dir,
        db_name: db_name,
        db_type: db_type,
        release_num: release_num,
        core_folders_cache: core_folders_cache,
        download_missing_gene_table: download_missing_gene_table,
        stats: stats
      )
      resolve_gene_table_source(
        release_dir: release_dir,
        db_name: db_name,
        db_type: db_type,
        release_num: release_num,
        core_folders_cache: core_folders_cache,
        archive_members_cache: archive_members_cache,
        download_missing_gene_table: false,
        stats: stats
      )
    end

    def archive_member?(cache, archive_path, member)
      archive_member_size(cache, archive_path, member).positive?
    end

    def archive_member_size(cache, archive_path, member)
      archive_members(cache, archive_path).fetch(member, 0)
    end

    def archive_members(cache, archive_path)
      key = archive_path.to_s
      return cache[key] if cache.key?(key)

      stdout, _stderr, status = Open3.capture3("tar", "-tvzf", key)
      members = {}
      if status.success?
        stdout.each_line do |line|
          match = line.chomp.match(/\A\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+(.+)\z/)
          next unless match

          members[match[2]] = match[1].to_i
        end
      end
      cache[key] = members
    end

    def stream_ensembl_ids(source, db_type: nil, release_num: nil, stable_id_map: nil, column: nil, stats: nil)
      if column
        stream_ensembl_ids_from_column(source, column, stats: stats) { |id| yield id if valid_ensembl_id?(id) }
      else
        stream_ensembl_ids_with_map(source, db_type: db_type, release_num: release_num, stable_id_map: stable_id_map, stats: stats) do |id|
          yield id if valid_ensembl_id?(id)
        end
      end
    end

    def stream_ensembl_ids_from_column(source, column, stats: nil)
      col = column + 1
      pipeline = "set -o pipefail; #{gene_table_pipeline(source)} | awk -F'\\t' -v col=#{col} '{{ if (NF >= col) print $col }}'"
      each_pipeline_line(source, pipeline, stats: stats) do |line|
        id = line.strip
        yield id if id.present?
      end
    end

    def normalize_gene_table_line(line)
      line.force_encoding("iso-8859-1").encode("utf-8", invalid: :replace, undef: :replace)
    end

    def stream_ensembl_ids_with_map(source, db_type:, release_num:, stable_id_map:, stats: nil)
      each_gene_table_line(source, stats: stats) do |line|
        parts = line.chomp.split("\t")
        ensembl_id = resolve_ensembl_id_from_gene_row(
          parts,
          db_type: db_type,
          release_num: release_num,
          stable_id_map: stable_id_map
        )
        yield ensembl_id if ensembl_id.present?
      end
    end

    def each_gene_table_line(source, stats: nil)
      each_pipeline_line(source, gene_table_pipeline(source), stats: stats) do |line|
        yield normalize_gene_table_line(line)
      end
    end

    def each_pipeline_line(source, pipeline, stats: nil)
      Open3.popen3("bash", "-c", pipeline) do |_stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| yield line }
        report_corrupt_gene_table_source(source, wait_thr.value, stderr.read, stats: stats)
      end
    end

    def report_corrupt_gene_table_source(source, status, stderr, stats:)
      return if status.success?

      stats[:corrupt_gene_table_reads] += 1 if stats
      label = gene_table_source_label(source)
      detail = stderr.to_s.each_line.map(&:strip).reject(&:empty?).first
      detail = "exit status #{status.exitstatus}" if detail.blank?
      puts "  WARN unreadable gene table #{label}: #{detail}"
    end

    def gene_table_source_label(source)
      case source[:type]
      when :archive
        "#{source[:path]}:#{source[:member]}"
      else
        source[:path].to_s
      end
    end

    def gene_table_pipeline(source)
      case source[:type]
      when :file
        "cat #{Shellwords.escape(source[:path].to_s)}"
      when :gzip
        "zcat #{Shellwords.escape(source[:path].to_s)}"
      when :archive
        base = "tar -xOzf #{Shellwords.escape(source[:path].to_s)} #{Shellwords.escape(source[:member])}"
        source[:gzip] ? "#{base} | gzip -dc" : base
      else
        raise ArgumentError, "unknown gene table source #{source[:type]}"
      end
    end

    def ensembl_id_column(db_type, release_num)
      case db_type
      when :vertebrates
        if release_num >= 90
          12
        elsif release_num >= 74
          13
        else
          14
        end
      else
        if release_num >= 37
          12
        elsif release_num >= 21
          13
        else
          14
        end
      end
    end

    def load_gene_stable_id_map(source:, stats:)
      map = {}
      each_gene_table_line(source, stats: stats) do |line|
        parts = line.chomp.split("\t", 3)
        next if parts.size < 2

        gene_id = parts[0].to_s.strip
        ensembl_id = parts[1].to_s.strip
        next if gene_id.blank? || ensembl_id.blank? || ensembl_id == "\\N"
        next unless valid_ensembl_id?(ensembl_id)

        map[gene_id] = ensembl_id
      end
      map
    end

    def resolve_gene_stable_id_source(release_dir:, db_name:, db_type:, release_num:, core_folders_cache:, archive_members_cache:, download_missing_gene_table:, stats:)
      source = find_gene_stable_id_source(
        release_dir: release_dir,
        db_name: db_name,
        archive_members_cache: archive_members_cache
      )
      return source if source
      return nil unless download_missing_gene_table

      ensure_gene_stable_id_txt(
        release_dir: release_dir,
        db_name: db_name,
        db_type: db_type,
        release_num: release_num,
        core_folders_cache: core_folders_cache,
        download_missing_gene_table: download_missing_gene_table,
        stats: stats
      )
      find_gene_stable_id_source(
        release_dir: release_dir,
        db_name: db_name,
        archive_members_cache: archive_members_cache
      )
    end

    def find_gene_stable_id_source(release_dir:, db_name:, archive_members_cache:)
      organism_dir = release_dir + db_name
      txt_path = organism_dir + "gene_stable_id.txt"
      return { type: :file, path: txt_path } if text_file_present?(txt_path)

      gz_path = organism_dir + "gene_stable_id.txt.gz"
      return { type: :gzip, path: gz_path } if gzip_file_present?(gz_path)

      archive_path = release_dir + "#{db_name}.tgz"
      return nil unless archive_path.file?

      if archive_member?(archive_members_cache, archive_path, "#{db_name}/gene_stable_id.txt")
        return { type: :archive, path: archive_path, member: "#{db_name}/gene_stable_id.txt" }
      end
      if archive_member?(archive_members_cache, archive_path, "#{db_name}/gene_stable_id.txt.gz")
        return { type: :archive, path: archive_path, member: "#{db_name}/gene_stable_id.txt.gz", gzip: true }
      end

      nil
    end

    def ensure_gene_stable_id_txt(release_dir:, db_name:, db_type:, release_num:, core_folders_cache:, download_missing_gene_table:, stats:)
      organism_dir = release_dir + db_name
      stable_id_path = organism_dir + "gene_stable_id.txt"
      return stable_id_path if text_file_present?(stable_id_path)

      stable_id_gz_path = organism_dir + "gene_stable_id.txt.gz"
      if gzip_file_present?(stable_id_gz_path) && gunzip_file(stable_id_gz_path)
        return stable_id_path if text_file_present?(stable_id_path)
      end
      remove_invalid_gene_table_files(stable_id_path, stable_id_gz_path)

      return nil unless download_missing_gene_table

      core_folders = EnsemblAssembliesLoader.core_folders_for_release(core_folders_cache, db_type, release_num)
      core_folder = EnsemblAssembliesLoader.resolve_core_folder(db_name, core_folders)
      return nil if core_folder.blank?

      FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
      downloaded = download_gene_table(
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        table_name: "gene_stable_id",
        destination_dir: organism_dir
      )
      stats[:gene_table_downloads] += 1 if downloaded
      text_file_present?(stable_id_path) ? stable_id_path : nil
    end

    def ensure_gene_txt(release_dir:, db_name:, db_type:, release_num:, core_folders_cache:, download_missing_gene_table:, stats:)
      organism_dir = release_dir + db_name
      gene_path = organism_dir + "gene.txt"
      return gene_path if text_file_present?(gene_path)

      gene_gz_path = organism_dir + "gene.txt.gz"
      if gzip_file_present?(gene_gz_path) && gunzip_file(gene_gz_path)
        return gene_path if text_file_present?(gene_path)
      end
      remove_invalid_gene_table_files(gene_path, gene_gz_path)

      return nil unless download_missing_gene_table

      core_folders = EnsemblAssembliesLoader.core_folders_for_release(core_folders_cache, db_type, release_num)
      core_folder = EnsemblAssembliesLoader.resolve_core_folder(db_name, core_folders)
      return nil if core_folder.blank?

      FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
      downloaded = download_gene_table(
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        table_name: "gene",
        destination_dir: organism_dir
      )
      stats[:gene_table_downloads] += 1 if downloaded
      text_file_present?(gene_path) ? gene_path : nil
    end

    def download_gene_table(db_type:, release_num:, core_folder:, table_name:, destination_dir:)
      EnsemblAssembliesLoader.send(
        :download_ensembl_table,
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        table_name: table_name,
        destination_dir: destination_dir
      )
    end

    def resolve_ensembl_id_from_gene_row(parts, db_type:, release_num:, stable_id_map:)
      if stable_id_map
        gene_id = parts[0].to_s.strip
        ensembl_id = stable_id_map[gene_id]
        return ensembl_id if valid_ensembl_id?(ensembl_id)

        return nil
      end

      column = ensembl_id_column(db_type, release_num)
      return nil if column.nil? || parts.size <= column

      ensembl_id = parts[column].to_s.strip
      valid_ensembl_id?(ensembl_id) ? ensembl_id : nil
    end

    def valid_ensembl_id?(ensembl_id)
      ensembl_id.present? && ensembl_id != "\\N" && ensembl_id.match?(ENSEMBL_ID_PATTERN) &&
        !ensembl_id.match?(/\A\d+\z/)
    end

    def gzip_file_present?(path)
      path&.file? && path.size.positive?
    end

    def text_file_present?(path)
      path&.file? && path.size.positive?
    end

    def remove_invalid_gene_table_files(txt_path, gz_path)
      FileUtils.rm_f(gz_path) if gz_path&.file? && !gzip_file_present?(gz_path)
      FileUtils.rm_f(txt_path) if txt_path&.file? && !text_file_present?(txt_path)
    end

    def gunzip_file(path)
      return false unless gzip_file_present?(path)

      _stdout, stderr, status = Open3.capture3("gunzip", "-f", path.to_s)
      return true if status.success?

      Rails.logger.warn("[GeneFirstEnsemblReleasePopulator] gunzip failed for #{path}: #{stderr.strip}")
      FileUtils.rm_f(path)
      false
    end

    def filter_organisms(organisms)
      organism_id = ENV["ORGANISM_ID"].to_s.strip
      return organisms if organism_id.blank?

      id = organism_id.to_i
      organisms.select { |organism| organism[:id] == id }
    end

    def default_remote_db
      ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    end

    def default_download_missing_gene_table?
      ENV.fetch("DOWNLOAD_MISSING_GENE_TABLE", "false").to_s.strip.downcase == "true"
    end

    def default_force?
      ENV.fetch("FORCE", "false").to_s.strip.downcase == "true"
    end
  end
end
