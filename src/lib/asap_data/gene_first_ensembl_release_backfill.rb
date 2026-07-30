# frozen_string_literal: true

require "set"

module AsapData
  # Fast backfill of genes.first_ensembl_release for rows where it is still NULL.
  #
  # Strategy (fastest path given the local mirror):
  # 1) Scan local Ensembl gene tables oldest -> newest for organisms that still
  #    have NULL first values; stop as soon as every target id for that organism
  #    is found. Never rewrites latest_ensembl_release.
  # 2) Optional approximate phase: for genes still NULL after the scan — typically
  #    obsolete genes whose latest release predates the local mirror (vertebrates
  #    dumps start at 54) — set first = latest.
  #
  # ENV:
  #   ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ORGANISM_ID, ORGANISM
  #   DOWNLOAD_MISSING_GENE_TABLE, MODE
  #   MODE=scan|approximate|scan_then_approximate (default scan)
  module GeneFirstEnsemblReleaseBackfill
    module_function

    BATCH_SIZE = 50_000

    def backfill!(
      remote_db: default_remote_db,
      download_missing_gene_table: default_download_missing_gene_table?,
      mode: default_mode
    )
      stats = blank_stats
      approximate = mode != "scan"
      do_scan = mode != "approximate"

      if do_scan
        scan_missing!(
          remote_db: remote_db,
          download_missing_gene_table: download_missing_gene_table,
          stats: stats
        )
      end

      if approximate
        n = approximate_remaining_with_latest!(remote_db: remote_db)
        stats[:genes_updated_from_approximate] = n
        puts "Approximate first=latest for remaining NULL rows: #{n}"
      end

      RemoteGene.with_remote(remote_db) do
        stats[:genes_still_missing] = RemoteGene.where(first_ensembl_release: nil).count
      end
      stats
    end

    def blank_stats
      {
        organisms_total: 0,
        organisms_processed: 0,
        organisms_skipped: 0,
        genes_updated_from_scan: 0,
        genes_updated_from_approximate: 0,
        genes_still_missing: 0,
        gene_table_reads: 0,
        gene_table_downloads: 0,
        corrupt_gene_table_reads: 0,
        releases_scanned: 0,
        releases_skipped_early_exit: 0
      }
    end

    def scan_missing!(remote_db:, download_missing_gene_table:, stats:)
      pop = GeneFirstEnsemblReleasePopulator
      base_dirs = EnsemblAssembliesLoader.all_ensembl_base_dirs
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      core_folders_cache = {}
      stable_id_map_cache = {}
      archive_members_cache = {}

      organisms = missing_organisms(remote_db)
      stats[:organisms_total] = organisms.size
      puts "Scan phase: #{organisms.size} organisms with missing first_ensembl_release"

      organisms.each do |organism|
        organism_start = Time.now
        reads_before = stats[:gene_table_reads]

        gene_rows = load_missing_gene_rows(organism_id: organism[:id], remote_db: remote_db)
        if gene_rows.empty?
          stats[:organisms_skipped] += 1
          next
        end

        target_ensembl_ids = gene_rows.map { |row| row[:ensembl_key] }.to_set
        max_latest = gene_rows.map { |row| row[:latest].to_i }.max
        puts "  #{organism[:ensembl_db_name]} (#{organism[:subdomain]}): #{gene_rows.size} genes, scan <= #{max_latest}..."
        $stdout.flush

        first_by_ensembl = scan_first_releases!(
          organism: organism,
          base_dirs: base_dirs,
          max_latest: max_latest,
          target_ensembl_ids: target_ensembl_ids,
          core_folders_cache: core_folders_cache,
          stable_id_map_cache: stable_id_map_cache,
          archive_members_cache: archive_members_cache,
          download_missing_gene_table: download_missing_gene_table,
          stats: stats,
          pop: pop
        )

        updates = gene_rows.filter_map do |row|
          first = first_by_ensembl[row[:ensembl_key]]
          first ? [row[:gene_id], first.to_i] : nil
        end
        updated = write_first_updates!(remote_db, organism[:id], updates)
        stats[:genes_updated_from_scan] += updated

        if updated.positive?
          stats[:organisms_processed] += 1
        else
          stats[:organisms_skipped] += 1
        end

        puts(
          "    updated=#{updated} reads=#{stats[:gene_table_reads] - reads_before} " \
          "(#{(Time.now - organism_start).round(1)}s)"
        )
        $stdout.flush
      end
    end

    def approximate_remaining_with_latest!(remote_db:)
      RemoteGene.with_remote(remote_db) do
        sql = <<~SQL
          UPDATE genes
          SET first_ensembl_release = latest_ensembl_release
          WHERE first_ensembl_release IS NULL
            AND latest_ensembl_release IS NOT NULL
        SQL
        RemoteGene.connection.update(sql).to_i
      end
    end

    def missing_organisms(remote_db)
      rows = []
      RemoteGene.with_remote(remote_db) do
        sql = <<~SQL
          SELECT o.id, o.ensembl_db_name, es.name AS subdomain, COUNT(*) AS missing_count
          FROM genes g
          JOIN organisms o ON o.id = g.organism_id
          JOIN ensembl_subdomains es ON es.id = o.ensembl_subdomain_id
          WHERE g.first_ensembl_release IS NULL
            AND g.ensembl_id IS NOT NULL
            AND g.ensembl_id <> ''
          GROUP BY o.id, o.ensembl_db_name, es.name
          ORDER BY COUNT(*) DESC, o.ensembl_db_name
        SQL
        RemoteGene.connection.select_all(sql).each do |row|
          rows << {
            id: row["id"].to_i,
            ensembl_db_name: row["ensembl_db_name"],
            subdomain: row["subdomain"],
            missing_count: row["missing_count"].to_i
          }
        end
      end

      organism_id = ENV["ORGANISM_ID"].to_s.strip
      if organism_id.present?
        id = organism_id.to_i
        rows.select! { |organism| organism[:id] == id }
      end

      ensembl_db = ENV["ORGANISM"].to_s.strip
      if ensembl_db.present?
        wanted = ensembl_db.split(",").map(&:strip)
        rows.select! { |organism| wanted.include?(organism[:ensembl_db_name]) }
      end

      rows
    end

    def load_missing_gene_rows(organism_id:, remote_db:)
      RemoteGene.with_remote(remote_db) do
        RemoteGene.where(organism_id: organism_id, first_ensembl_release: nil)
          .where.not(ensembl_id: [nil, ""])
          .pluck(:id, :ensembl_id, :latest_ensembl_release)
          .map do |gene_id, ensembl_id, latest|
            {
              gene_id: gene_id,
              ensembl_key: ensembl_id.to_s.downcase,
              latest: latest
            }
          end
      end
    end

    def scan_first_releases!(
      organism:,
      base_dirs:,
      max_latest:,
      target_ensembl_ids:,
      core_folders_cache:,
      stable_id_map_cache:,
      archive_members_cache:,
      download_missing_gene_table:,
      stats:,
      pop:
    )
      db_type = organism[:subdomain].to_sym
      return {} unless EnsemblAssembliesLoader::DB_TYPES.include?(db_type)

      release_numbers = local_release_numbers(
        base_dirs: base_dirs,
        db_type: db_type,
        db_name: organism[:ensembl_db_name],
        max_latest: max_latest,
        download_missing: download_missing_gene_table,
        core_folders_cache: core_folders_cache
      )
      return {} if release_numbers.empty?

      puts "    releases to scan: #{release_numbers.size} (#{release_numbers.first}..#{release_numbers.last})"
      $stdout.flush

      first_by_ensembl = {}
      remaining = target_ensembl_ids.dup

      release_numbers.each_with_index do |release_num, idx|
        if remaining.empty?
          stats[:releases_skipped_early_exit] += (release_numbers.size - idx)
          break
        end

        release_dir = pop.resolve_release_dir_for_scan(base_dirs, db_type, release_num, download_missing_gene_table)
        latest_unused = {}
        before = first_by_ensembl.size
        read = pop.accumulate_ensembl_releases!(
          release_dir: release_dir,
          db_name: organism[:ensembl_db_name],
          db_type: db_type,
          release_num: release_num,
          core_folders_cache: core_folders_cache,
          stable_id_map_cache: stable_id_map_cache,
          archive_members_cache: archive_members_cache,
          download_missing_gene_table: download_missing_gene_table,
          target_ensembl_ids: remaining,
          first_release_by_ensembl: first_by_ensembl,
          latest_release_by_ensembl: latest_unused,
          stats: stats
        )
        stats[:gene_table_reads] += 1 if read
        stats[:releases_scanned] += 1 if read
        remaining.subtract(first_by_ensembl.keys)
        newly = first_by_ensembl.size - before
        puts "    r#{release_num}: read=#{read} newly_found=#{newly} remaining=#{remaining.size}"
        $stdout.flush
      end

      first_by_ensembl
    end

    # Local dumps plus FTP releases where the species core exists (when downloading).
    def local_release_numbers(base_dirs:, db_type:, db_name:, max_latest:, download_missing:, core_folders_cache: {})
      numbers = []
      upper = max_latest.to_i
      return numbers unless upper.positive?

      (1..upper).each do |release_num|
        release_dir = EnsemblAssembliesLoader.resolve_release_dir(base_dirs, db_type, release_num)
        if release_dir && EnsemblAssembliesLoader.organism_present_in_release?(release_dir, db_name)
          numbers << release_num
          next
        end
        next unless download_missing

        folders = EnsemblAssembliesLoader.core_folders_for_release(
          core_folders_cache, db_type, release_num, only_db_names: [db_name]
        )
        next if folders.blank?
        next if EnsemblAssembliesLoader.resolve_core_folder(db_name, folders).blank?

        numbers << release_num
      end
      numbers
    end

    def write_first_updates!(remote_db, organism_id, updates)
      return 0 if updates.empty?

      updated_total = 0
      RemoteGene.with_remote(remote_db) do
        conn = RemoteGene.connection
        updates.each_slice(BATCH_SIZE) do |slice|
          ids = slice.map { |row| row[0].to_i }
          firsts = slice.map { |row| row[1].to_i }
          sql = <<~SQL
            UPDATE genes AS g
            SET first_ensembl_release = v.first_release
            FROM (
              SELECT *
              FROM unnest(
                ARRAY[#{ids.join(',')}]::bigint[],
                ARRAY[#{firsts.join(',')}]::int[]
              ) AS t(gene_id, first_release)
            ) AS v
            WHERE g.id = v.gene_id
              AND g.organism_id = #{organism_id.to_i}
              AND g.first_ensembl_release IS NULL
          SQL
          updated_total += conn.update(sql).to_i
        end
      end
      updated_total
    end

    def default_remote_db
      ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    end

    def default_download_missing_gene_table?
      ENV.fetch("DOWNLOAD_MISSING_GENE_TABLE", "true").to_s.strip.downcase == "true"
    end

    def default_mode
      mode = ENV.fetch("MODE", "scan").to_s.strip.downcase
      return mode if %w[scan approximate scan_then_approximate].include?(mode)

      "scan"
    end
  end
end
