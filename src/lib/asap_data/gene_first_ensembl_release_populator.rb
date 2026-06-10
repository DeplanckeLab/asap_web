# frozen_string_literal: true

require "open3"
require "set"

module AsapData
  module GeneFirstEnsemblReleasePopulator
    module_function

    GENE_STABLE_ID_COLUMN = 12
    BATCH_SIZE = 50_000

    def populate!(remote_db: default_remote_db, download_missing_gene_table: default_download_missing_gene_table?, force: default_force?)
      base_dirs = EnsemblAssembliesLoader.all_ensembl_base_dirs
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      stats = {
        organisms_total: 0,
        organisms_processed: 0,
        organisms_skipped: 0,
        genes_updated: 0,
        genes_unchanged: 0,
        genes_without_match: 0,
        gene_table_reads: 0,
        gene_table_downloads: 0
      }

      core_folders_cache = {}
      subdomain_latest_releases = EnsemblAssembliesLoader.load_subdomain_latest_releases(remote_db)
      organisms = filter_organisms(EnsemblAssembliesLoader.load_organisms(remote_db))
      stats[:organisms_total] = organisms.size

      organisms.each do |organism|
        updated = populate_for_organism!(
          organism: organism,
          base_dirs: base_dirs,
          subdomain_latest_releases: subdomain_latest_releases,
          core_folders_cache: core_folders_cache,
          remote_db: remote_db,
          download_missing_gene_table: download_missing_gene_table,
          force: force,
          stats: stats
        )
        if updated
          stats[:organisms_processed] += 1
        else
          stats[:organisms_skipped] += 1
        end
      end

      stats
    end

    def populate_for_organism!(organism:, base_dirs:, subdomain_latest_releases:, core_folders_cache:, remote_db:, download_missing_gene_table:, force:, stats:)
      db_type = organism[:subdomain].to_sym
      return false unless EnsemblAssembliesLoader::DB_TYPES.include?(db_type)

      release_numbers = EnsemblAssembliesLoader.release_numbers_for_scan(
        organism,
        base_dirs,
        subdomain_latest_releases[organism[:subdomain]]
      )
      return false if release_numbers.empty?

      first_release_by_ensembl = {}
      release_numbers.each do |release_num|
        release_dir = EnsemblAssembliesLoader.resolve_release_dir(base_dirs, db_type, release_num)
        next unless release_dir

        ensembl_ids = ensembl_ids_for_organism_release(
          release_dir: release_dir,
          db_name: organism[:ensembl_db_name],
          db_type: db_type,
          release_num: release_num,
          core_folders_cache: core_folders_cache,
          download_missing_gene_table: download_missing_gene_table,
          stats: stats
        )
        next if ensembl_ids.empty?

        ensembl_ids.each do |ensembl_id|
          key = ensembl_id.downcase
          first_release_by_ensembl[key] ||= release_num
        end
      end
      return false if first_release_by_ensembl.empty?

      RemoteGene.with_remote(remote_db) do
        conn = RemoteGene.connection
        scope = RemoteGene.where(organism_id: organism[:id])
        scope = scope.where(first_ensembl_release: nil) unless force

        updates_by_release = Hash.new { |hash, key| hash[key] = [] }
        scope.pluck(:id, :ensembl_id, :first_ensembl_release).each do |gene_id, ensembl_id, current_first|
          target_release = first_release_by_ensembl[ensembl_id.to_s.downcase]
          if target_release.nil?
            stats[:genes_without_match] += 1
            next
          end
          if !force && current_first.present?
            stats[:genes_unchanged] += 1
            next
          end
          if current_first == target_release
            stats[:genes_unchanged] += 1
            next
          end

          updates_by_release[target_release] << gene_id
        end

        apply_updates!(conn, organism[:id], updates_by_release, force: force, stats: stats)
      end

      true
    end

    def apply_updates!(conn, organism_id, updates_by_release, force:, stats:)
      updates_by_release.sort.each do |release_num, gene_ids|
        gene_ids.each_slice(BATCH_SIZE) do |slice|
          ids_sql = slice.map(&:to_i).join(",")
          null_clause = force ? "" : "AND first_ensembl_release IS NULL"
          sql = <<~SQL
            UPDATE genes
            SET first_ensembl_release = #{conn.quote(release_num)}
            WHERE organism_id = #{organism_id.to_i}
              AND id IN (#{ids_sql})
              #{null_clause}
          SQL
          updated = conn.update(sql)
          stats[:genes_updated] += updated.to_i
        end
      end
    end

    def ensembl_ids_for_organism_release(release_dir:, db_name:, db_type:, release_num:, core_folders_cache:, download_missing_gene_table:, stats:)
      gene_path = ensure_gene_txt(
        release_dir: release_dir,
        db_name: db_name,
        db_type: db_type,
        release_num: release_num,
        core_folders_cache: core_folders_cache,
        download_missing_gene_table: download_missing_gene_table,
        stats: stats
      )
      return [] unless gene_path&.file? && gene_path.size?(&:positive?)

      stats[:gene_table_reads] += 1
      parse_ensembl_ids_from_gene_txt(gene_path)
    end

    def ensure_gene_txt(release_dir:, db_name:, db_type:, release_num:, core_folders_cache:, download_missing_gene_table:, stats:)
      organism_dir = release_dir + db_name
      gene_path = organism_dir + "gene.txt"
      return gene_path if gene_path.file? && gene_path.size?(&:positive?)

      gene_gz_path = organism_dir + "gene.txt.gz"
      if gene_gz_path.file?
        gunzip_file(gene_gz_path)
        return gene_path if gene_path.file? && gene_path.size?(&:positive?)
      end

      archive_path = release_dir + "#{db_name}.tgz"
      if archive_path.file?
        extracted = extract_gene_txt_from_archive(archive_path, organism_dir)
        return extracted if extracted&.file? && extracted.size?(&:positive?)
      end

      return nil unless download_missing_gene_table

      core_folders = EnsemblAssembliesLoader.core_folders_for_release(core_folders_cache, db_type, release_num)
      core_folder = EnsemblAssembliesLoader.resolve_core_folder(db_name, core_folders)
      return nil if core_folder.blank?

      FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
      downloaded = download_gene_txt(
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        destination_dir: organism_dir
      )
      stats[:gene_table_downloads] += 1 if downloaded
      return gene_path if gene_path.file? && gene_path.size?(&:positive?)

      nil
    end

    def parse_ensembl_ids_from_gene_txt(gene_path)
      ids = []
      File.foreach(gene_path) do |line|
        line = line.force_encoding("iso-8859-1").encode("utf-8")
        parts = line.chomp.split("\t")
        next if parts.size <= GENE_STABLE_ID_COLUMN

        ensembl_id = parts[GENE_STABLE_ID_COLUMN].to_s.strip
        next if ensembl_id.blank? || ensembl_id == "\\N"

        ids << ensembl_id
      end
      ids
    end

    def extract_gene_txt_from_archive(archive_path, organism_dir)
      copied = extract_table_from_archive(archive_path, organism_dir, "gene.txt")
      return copied if copied&.file?

      copied = extract_table_from_archive(archive_path, organism_dir, "gene.txt.gz")
      return nil unless copied&.file?

      gunzip_file(copied)
      destination = organism_dir + "gene.txt"
      destination.file? ? destination : nil
    end

    def extract_table_from_archive(archive_path, organism_dir, table_name)
      Dir.mktmpdir("asap_gene_") do |tmpdir|
        _stdout, stderr, status = Open3.capture3(
          "tar", "-xzf", archive_path.to_s, "-C", tmpdir, "--wildcards", "*/#{table_name}"
        )
        unless status.success?
          Rails.logger.debug(
            "[GeneFirstEnsemblReleasePopulator] #{table_name} not in archive #{archive_path}: #{stderr.strip}"
          )
          return nil
        end

        extracted = Dir.glob(File.join(tmpdir, "**", table_name)).first
        return nil unless extracted

        FileUtils.mkdir_p(organism_dir)
        destination = organism_dir + table_name
        FileUtils.cp(extracted, destination)
        destination
      end
    end

    def download_gene_txt(db_type:, release_num:, core_folder:, destination_dir:)
      url = "#{mysql_base_url(db_type, release_num)}#{core_folder}/gene.txt.gz"
      destination_gz = destination_dir + "gene.txt.gz"
      _stdout, stderr, status = Open3.capture3("wget", "-qO", destination_gz.to_s, url)
      unless status.success? && destination_gz.file? && destination_gz.size?(&:positive?)
        FileUtils.rm_f(destination_gz)
        Rails.logger.warn("[GeneFirstEnsemblReleasePopulator] wget failed for #{url}: #{stderr.strip}")
        return false
      end

      gunzip_file(destination_gz)
      (destination_dir + "gene.txt").file?
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
