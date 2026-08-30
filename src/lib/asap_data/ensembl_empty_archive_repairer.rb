# frozen_string_literal: true

require "open3"
require "pathname"
require "set"
require "fileutils"

module AsapData
  # Finds Ensembl organism dumps where required tables are empty (loose files or
  # inside .tgz), re-downloads them from Ensembl FTP, repacks archives, then
  # optionally reloads assemblies / genes / gene_set_items for affected organisms.
  module EnsemblEmptyArchiveRepairer
    module_function

    # Tables that must be non-empty when a gene dump exists. external_synonym.txt
    # can legitimately be empty for some species, so it is not required.
    REQUIRED_TABLES = %w[gene.txt xref.txt object_xref.txt].freeze

    Finding = Struct.new(
      :db_type,
      :release_num,
      :db_name,
      :release_dir,
      :archive_path,
      :organism_dir,
      :empty_tables,
      :sources,
      keyword_init: true
    )

    def find_empty_archives!(base_dirs: EnsemblAssembliesLoader.all_ensembl_base_dirs)
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      findings = []
      archive_members_cache = {}

      EnsemblAssembliesLoader.parse_db_types.each do |db_type|
        EnsemblAssembliesLoader.available_release_numbers(base_dirs, db_type).each do |release_num|
          release_dir = EnsemblAssembliesLoader.resolve_release_dir(base_dirs, db_type, release_num)
          next unless release_dir

          EnsemblAssembliesLoader.organisms_in_release_dir(release_dir).each do |db_name|
            next if db_name_filter && !db_name_filter.include?(db_name)

            finding = inspect_organism(
              db_type: db_type,
              release_num: release_num,
              db_name: db_name,
              release_dir: release_dir,
              archive_members_cache: archive_members_cache
            )
            findings << finding if finding
          end
        end
      end

      findings
    end

    def repair!(
      remote_db: default_remote_db,
      dry_run: default_dry_run?,
      reload_db: default_reload_db?,
      reload_gene_sets: default_reload_gene_sets?
    )
      base_dirs = EnsemblAssembliesLoader.all_ensembl_base_dirs
      findings = find_empty_archives!(base_dirs: base_dirs)

      stats = {
        findings: findings.size,
        repaired: 0,
        failed: 0,
        skipped_no_core: 0,
        tables_redownloaded: 0,
        archives_updated: 0,
        organisms_reloaded: 0,
        gene_sets_reloaded: 0
      }

      return stats.merge(findings_detail: findings) if findings.empty?

      core_folders_cache = {}
      repaired_db_names = Set.new
      organism_ids_by_db_name = organisms_by_db_name(remote_db)

      findings.each do |finding|
        puts "  empty: #{finding.db_type}/#{finding.release_num}/#{finding.db_name} " \
             "tables=#{finding.empty_tables.join(',')} sources=#{finding.sources.join(',')}"

        if dry_run
          stats[:repaired] += 1
          repaired_db_names << finding.db_name
          next
        end

        ok = repair_finding!(
          finding: finding,
          base_dirs: base_dirs,
          core_folders_cache: core_folders_cache,
          stats: stats
        )
        if ok
          stats[:repaired] += 1
          repaired_db_names << finding.db_name
        else
          stats[:failed] += 1
        end
      end

      if reload_db && !dry_run && repaired_db_names.any?
        reload_affected_organisms!(
          remote_db: remote_db,
          db_names: repaired_db_names.to_a.sort,
          organism_ids_by_db_name: organism_ids_by_db_name,
          reload_gene_sets: reload_gene_sets,
          stats: stats
        )
      end

      stats.merge(findings_detail: findings, repaired_db_names: repaired_db_names.to_a.sort)
    end

    def inspect_organism(db_type:, release_num:, db_name:, release_dir:, archive_members_cache:)
      organism_dir = release_dir + db_name
      archive_path = release_dir + "#{db_name}.tgz"
      archive_path = nil unless archive_path.file?

      sizes = table_sizes(
        organism_dir: organism_dir,
        archive_path: archive_path,
        db_name: db_name,
        archive_members_cache: archive_members_cache
      )

      gene_size = sizes.dig("gene.txt", :size).to_i
      return nil if gene_size <= 0 && REQUIRED_TABLES.none? { |t| sizes.dig(t, :size).to_i.positive? }

      empty_tables = []
      sources = Set.new
      REQUIRED_TABLES.each do |table_name|
        entry = sizes[table_name]
        next unless entry
        next if entry[:size].positive?

        empty_tables << table_name
        sources.merge(entry[:sources])
      end
      return nil if empty_tables.empty?

      # Only treat as broken when gene.txt exists and is non-empty (partial dump),
      # or when gene itself is the empty required table.
      return nil if gene_size <= 0 && !empty_tables.include?("gene.txt")

      Finding.new(
        db_type: db_type,
        release_num: release_num,
        db_name: db_name,
        release_dir: release_dir,
        archive_path: archive_path,
        organism_dir: organism_dir.directory? ? organism_dir : nil,
        empty_tables: empty_tables,
        sources: sources.to_a.sort
      )
    end

    def table_sizes(organism_dir:, archive_path:, db_name:, archive_members_cache:)
      sizes = {}

      if organism_dir.directory?
        REQUIRED_TABLES.each do |table_name|
          path = organism_dir + table_name
          next unless path.file?

          sizes[table_name] = { size: path.size, sources: ["dir"] }
        end

        # Loose files already decide: healthy dump -> skip expensive tar listing.
        # Empty required loose file -> report from dir without opening the archive.
        return sizes if dir_tables_complete?(sizes)
        return sizes if sizes.any? { |_name, entry| entry[:size] <= 0 }
      end

      return sizes unless archive_path

      # Overall .tgz size is not enough: broken dumps still have a large gene.txt.
      # Inspect member sizes for required tables only.
      members = archive_member_sizes(archive_members_cache, archive_path, db_name)
      REQUIRED_TABLES.each do |table_name|
        next unless members.key?(table_name)

        size = members[table_name]
        if sizes[table_name]
          if size > sizes[table_name][:size]
            sizes[table_name] = { size: size, sources: ["archive"] }
          elsif size <= 0
            sizes[table_name][:sources] |= ["archive"]
          end
        else
          sizes[table_name] = { size: size, sources: ["archive"] }
        end
      end

      sizes
    end

    def dir_tables_complete?(sizes)
      REQUIRED_TABLES.all? { |table_name| sizes.dig(table_name, :size).to_i.positive? }
    end

    # List only required member sizes via tar -tvzf (metadata). Cached per archive.
    def archive_member_sizes(cache, archive_path, db_name)
      key = archive_path.to_s
      return cache[key] if cache.key?(key)

      wanted = REQUIRED_TABLES.map { |table_name| "#{db_name}/#{table_name}" }.to_set
      stdout, _stderr, status = Open3.capture3("tar", "-tvzf", key)
      members = {}
      if status.success?
        stdout.each_line do |line|
          match = line.chomp.match(/\A\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+(.+)\z/)
          next unless match

          member = match[2]
          next unless wanted.include?(member)

          members[File.basename(member)] = match[1].to_i
          break if members.size == REQUIRED_TABLES.size
        end
      end
      cache[key] = members
    end

    def repair_finding!(finding:, base_dirs:, core_folders_cache:, stats:)
      core_folders = EnsemblAssembliesLoader.core_folders_for_release(
        core_folders_cache,
        finding.db_type,
        finding.release_num,
        only_db_names: [finding.db_name]
      )
      core_folder = EnsemblAssembliesLoader.resolve_core_folder(finding.db_name, core_folders)
      if core_folder.blank?
        Rails.logger.warn(
          "[EnsemblEmptyArchiveRepairer] no core folder for " \
          "#{finding.db_type}/#{finding.release_num}/#{finding.db_name}"
        )
        stats[:skipped_no_core] += 1
        return false
      end

      organism_dir = EnsemblAssembliesLoader.writable_organism_dir(
        base_dirs,
        finding.db_type,
        finding.release_num,
        finding.db_name
      )
      unless organism_dir
        Rails.logger.warn(
          "[EnsemblEmptyArchiveRepairer] no writable organism dir for " \
          "#{finding.db_type}/#{finding.release_num}/#{finding.db_name}"
        )
        return false
      end

      finding.empty_tables.each do |table_name|
        remove_empty_table_stubs!(organism_dir, table_name)
        table_base = table_name.delete_suffix(".txt")
        downloaded = EnsemblAssembliesLoader.download_ensembl_table(
          db_type: finding.db_type,
          release_num: finding.release_num,
          core_folder: core_folder,
          table_name: table_base,
          destination_dir: organism_dir
        )
        path = organism_dir + table_name
        unless downloaded && path.file? && path.size.positive?
          Rails.logger.warn(
            "[EnsemblEmptyArchiveRepairer] download failed for " \
            "#{finding.db_type}/#{finding.release_num}/#{finding.db_name}/#{table_name}"
          )
          return false
        end
        stats[:tables_redownloaded] += 1
        puts "    downloaded #{table_name} (#{path.size} bytes)"
      end

      archive_path = finding.archive_path || (finding.release_dir + "#{finding.db_name}.tgz")
      loose_files = EnsemblArchiveIntegrator.loose_files_for_dirs([organism_dir])
      # Only pack the tables we care about refreshing plus any other local tables.
      unless EnsemblArchiveIntegrator.integrate_into_archive!(archive_path, finding.db_name, loose_files)
        Rails.logger.warn(
          "[EnsemblEmptyArchiveRepairer] archive update failed for #{archive_path}"
        )
        return false
      end
      stats[:archives_updated] += 1

      # Verify required tables are non-empty in the new archive.
      members = archive_member_sizes({}, archive_path, finding.db_name)
      finding.empty_tables.each do |table_name|
        size = members[table_name].to_i
        if size <= 0
          Rails.logger.warn(
            "[EnsemblEmptyArchiveRepairer] #{table_name} still empty in #{archive_path} after repair"
          )
          return false
        end
      end

      true
    end

    def remove_empty_table_stubs!(organism_dir, table_name)
      path = organism_dir + table_name
      FileUtils.rm_f(path) if path.file? && !path.size.positive?

      # Stale compressed stubs can shadow a fresh download.
      %W[#{table_name}.gz #{table_name}.table #{table_name}.table.gz].each do |name|
        FileUtils.rm_f(organism_dir + name)
      end
    end

    def reload_affected_organisms!(remote_db:, db_names:, organism_ids_by_db_name:, reload_gene_sets:, stats:)
      db_names.each do |db_name|
        organism = organism_ids_by_db_name[db_name]
        unless organism
          puts "  skip DB reload for #{db_name}: not found in #{remote_db}"
          next
        end

        puts "  reload DB for organism_id=#{organism[:id]} #{db_name}"
        with_env(
          "ASAP2_REMOTE_DB" => remote_db,
          "ORGANISM_ID" => organism[:id].to_s,
          "ENSEMBL_DB_NAME" => db_name,
          "FORCE" => "true",
          "DOWNLOAD_MISSING_META" => "false",
          "DOWNLOAD_MISSING_GENE_TABLE" => "false",
          "DOWNLOAD_MISSING_TABLES" => "false"
        ) do
          EnsemblAssembliesLoader.populate!(
            remote_db: remote_db,
            download_missing_meta: false
          )
          GeneFirstEnsemblReleasePopulator.populate!(
            remote_db: remote_db,
            download_missing_gene_table: false,
            force: true
          )
          GeneNcbiAltNamesPopulator.populate!(
            remote_db: remote_db,
            download_missing_tables: false
          )
        end
        stats[:organisms_reloaded] += 1
      end

      return unless reload_gene_sets

      puts "  reload gene_set_items for: #{db_names.join(', ')}"
      with_env(
        "ASAP2_REMOTE_DB" => remote_db,
        "ORGANISM" => db_names.join(","),
        "RESET_ITEMS" => default_reset_gene_set_items? ? "1" : (ENV["RESET_ITEMS"].presence || "0"),
        "DOWNLOAD_MISSING" => "0"
      ) do
        task = Rake::Task["update_xrefs_versioned"]
        task.reenable
        task.invoke
      end
      stats[:gene_sets_reloaded] = db_names.size
    end

    def organisms_by_db_name(remote_db)
      EnsemblAssembliesLoader.load_organisms(remote_db).each_with_object({}) do |organism, hash|
        hash[organism[:ensembl_db_name]] = organism
      end
    end

    def db_name_filter
      organism_id = ENV["ORGANISM_ID"].to_s.strip
      if organism_id.present?
        remote_db = default_remote_db
        organism = EnsemblAssembliesLoader.load_organisms(remote_db).find { |row| row[:id] == organism_id.to_i }
        return [organism[:ensembl_db_name]] if organism
      end

      ensembl_db_name = ENV["ENSEMBL_DB_NAME"].to_s.strip
      return ensembl_db_name.split(",").map(&:strip).reject(&:blank?) if ensembl_db_name.present?

      organism_names = ENV["ORGANISM"].to_s.strip
      return organism_names.split(",").map(&:strip).reject(&:blank?) if organism_names.present?

      nil
    end

    def with_env(overrides)
      previous = overrides.keys.index_with { |key| ENV[key] }
      overrides.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end

    def default_remote_db
      ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    end

    def default_dry_run?
      ENV.fetch("DRY_RUN", "false").to_s.strip.downcase == "true"
    end

    def default_reload_db?
      ENV.fetch("RELOAD_DB", "true").to_s.strip.downcase != "false"
    end

    def default_reload_gene_sets?
      ENV.fetch("RELOAD_GENE_SETS", "true").to_s.strip.downcase != "false"
    end

    def default_reset_gene_set_items?
      ENV.fetch("RESET_ITEMS", "true").to_s.strip.downcase != "false"
    end
  end
end
