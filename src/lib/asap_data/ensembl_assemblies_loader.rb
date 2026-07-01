# frozen_string_literal: true

require "open3"
require "pathname"
require "set"

module AsapData
  module EnsemblAssembliesLoader
    module_function

    DB_TYPES = %i[vertebrates bacteria fungi metazoa plants protists].freeze
    DEFAULT_ENSEMBL_DATA_DIR = "/mnt/asap_data/ensembl"
    META_KEYS = %w[assembly.name assembly.default].freeze
    DEFAULT_RELEASE_FROM = {
      vertebrates: 54,
      bacteria: 5,
      fungi: 5,
      metazoa: 5,
      plants: 5,
      protists: 5
    }.freeze
    DEFAULT_RELEASE_TO = {
      vertebrates: 115,
      bacteria: 62,
      fungi: 62,
      metazoa: 62,
      plants: 62,
      protists: 62
    }.freeze

    def truncate_assemblies!(remote_db: default_remote_db)
      RemoteAssembly.with_remote(remote_db) do
        RemoteAssembly.connection.execute("TRUNCATE TABLE assemblies RESTART IDENTITY")
      end
    end

    def populate!(remote_db: default_remote_db, download_missing_meta: default_download_missing_meta?)
      base_dirs = all_ensembl_base_dirs
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      stats = {
        organisms_total: 0,
        organisms_with_assembly: 0,
        organisms_without_assembly: 0,
        assembly_names_found: 0,
        meta_downloads: 0,
        assemblies_created: 0,
        assemblies_updated: 0,
        skipped_no_meta: 0,
        skipped_unknown_subdomain: 0
      }

      assemblies_by_key = {}
      RemoteAssembly.with_remote(remote_db) do
        RemoteAssembly.find_each { |row| assemblies_by_key[assembly_cache_key(row.organism_id, row.name)] = row }
      end

      core_folders_cache = {}
      subdomain_latest_releases = load_subdomain_latest_releases(remote_db)
      organisms = load_organisms(remote_db)
      stats[:organisms_total] = organisms.size

      organisms.each do |organism|
        db_type = organism[:subdomain].to_sym
        unless DB_TYPES.include?(db_type)
          stats[:skipped_unknown_subdomain] += 1
          stats[:organisms_without_assembly] += 1
          next
        end

        release_numbers = release_numbers_for_scan(
          organism,
          base_dirs,
          subdomain_latest_releases[organism[:subdomain]],
          download_missing: download_missing_meta
        )
        if release_numbers.empty?
          stats[:organisms_without_assembly] += 1
          next
        end

        got_assembly = false
        release_numbers.each do |release_num|
          release_dir = resolve_release_dir(base_dirs, db_type, release_num) ||
                        ensure_release_dir(writable_ensembl_base_dir(base_dirs), db_type, release_num)
          core_folder = nil
          if download_missing_meta
            core_folders = core_folders_for_release(core_folders_cache, db_type, release_num)
            core_folder = resolve_core_folder(organism[:ensembl_db_name], core_folders)
          end

          assembly_name = assembly_name_for_organism(
            release_dir: release_dir,
            db_name: organism[:ensembl_db_name],
            db_type: db_type,
            release_num: release_num,
            core_folder: core_folder,
            download_missing_meta: download_missing_meta,
            stats: stats
          )
          next if assembly_name.blank?

          stats[:assembly_names_found] += 1
          created, updated = upsert_assembly!(
            assemblies_by_key,
            organism[:id],
            assembly_name,
            release_num,
            remote_db: remote_db
          )
          stats[:assemblies_created] += 1 if created
          stats[:assemblies_updated] += 1 if updated
          got_assembly = true
        end

        if got_assembly
          stats[:organisms_with_assembly] += 1
        else
          stats[:organisms_without_assembly] += 1
          Rails.logger.warn(
            "[EnsemblAssembliesLoader] no assembly for organism_id=#{organism[:id]} " \
            "#{organism[:ensembl_db_name]} (#{organism[:subdomain]})"
          )
        end
      end

      stats
    end

    def complete_local_meta_files!(remote_db: default_remote_db)
      base_dirs = all_ensembl_base_dirs
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      db_name_filter = meta_files_db_name_filter(remote_db)
      scan_started = Time.now
      scan = scan_missing_meta_coord_entries(base_dirs, db_name_filter: db_name_filter)
      scan_elapsed = Time.now - scan_started
      missing = scan[:missing]

      stats = {
        scan_elapsed: scan_elapsed,
        organisms_checked: scan[:organisms_checked],
        already_complete: scan[:already_complete],
        missing_entries: missing.size,
        need_meta: missing.count(&:need_meta),
        need_coord: missing.count(&:need_coord),
        meta_downloaded: 0,
        coord_system_downloaded: 0,
        meta_failed: 0,
        coord_system_failed: 0,
        skipped_no_core: 0
      }

      puts(
        "  scan: #{stats[:organisms_checked]} organisms in #{stats[:scan_elapsed].round(1)}s, " \
        "#{stats[:already_complete]} complete, #{stats[:missing_entries]} to fetch " \
        "(meta: #{stats[:need_meta]}, coord: #{stats[:need_coord]})"
      )
      return stats if missing.empty?

      core_folders_cache = {}
      progress_interval = ENV.fetch("META_COMPLETION_PROGRESS_INTERVAL", "50").to_i
      total = missing.size

      missing.each_with_index do |entry, index|
        organism_dir = writable_organism_dir(base_dirs, entry.db_type, entry.release_num, entry.db_name)
        unless organism_dir
          stats[:skipped_no_core] += 1
          next
        end

        meta_path = organism_dir + "meta.txt"
        coord_path = organism_dir + "coord_system.txt"
        need_meta = entry.need_meta && !local_meta_txt_present?(meta_path)
        need_coord = entry.need_coord && !local_coord_system_txt_present?(coord_path)
        next unless need_meta || need_coord

        core_folder = resolve_core_folder(
          entry.db_name,
          core_folders_for_release(core_folders_cache, entry.db_type, entry.release_num)
        )
        if core_folder.blank?
          stats[:skipped_no_core] += 1
          report_meta_download_progress(stats, index + 1, total, entry, progress_interval)
          next
        end

        if need_meta
          if download_meta_txt(
            db_type: entry.db_type,
            release_num: entry.release_num,
            core_folder: core_folder,
            destination_dir: organism_dir
          ) && valid_meta_file?(meta_path)
            stats[:meta_downloaded] += 1
          else
            stats[:meta_failed] += 1
          end
        end

            if need_coord
              if download_ensembl_table(
                db_type: entry.db_type,
                release_num: entry.release_num,
                core_folder: core_folder,
                table_name: "coord_system",
                destination_dir: organism_dir
              ) && local_coord_system_txt_present?(coord_path)
                stats[:coord_system_downloaded] += 1
              else
                stats[:coord_system_failed] += 1
              end
            end

        report_meta_download_progress(stats, index + 1, total, entry, progress_interval)
      end

      stats
    end

    MissingMetaCoordEntry = Struct.new(:db_type, :release_num, :db_name, :release_dir, :need_meta, :need_coord, keyword_init: true)

    def scan_missing_meta_coord_entries(base_dirs, db_name_filter: nil)
      missing = []
      organisms_checked = 0
      already_complete = 0

      parse_db_types.each do |db_type|
        base_dirs.each do |base_dir|
          type_dir = base_dir + db_type.to_s
          next unless type_dir.directory?

          Dir.each_child(type_dir.to_s) do |release_name|
            next unless release_name.match?(/\A\d+\z/)

            release_num = release_name.to_i
            next if release_num < release_from_bound(db_type)

            release_to = parse_release_bound("ENSEMBL_RELEASE_TO")
            next if release_to && release_num > release_to

            release_dir = type_dir + release_name
            next unless release_dir.directory?

            organisms_in_release_dir(release_dir, sorted: false).each do |db_name|
              next if db_name_filter && !db_name_filter.include?(db_name)

              organisms_checked += 1
              meta_path, coord_path = local_meta_coord_paths(release_dir, db_name)
              need_meta = !local_meta_txt_present?(meta_path)
              need_coord = !local_coord_system_txt_present?(coord_path)

              if need_meta || need_coord
                missing << MissingMetaCoordEntry.new(
                  db_type: db_type,
                  release_num: release_num,
                  db_name: db_name,
                  release_dir: release_dir,
                  need_meta: need_meta,
                  need_coord: need_coord
                )
              else
                already_complete += 1
              end
            end
          end
        end
      end

      { missing: missing, organisms_checked: organisms_checked, already_complete: already_complete }
    end

    def report_meta_download_progress(stats, index, total, entry, interval)
      return if interval <= 0
      return unless (index % interval).zero? || index == total

      puts(
        "  progress: #{index}/#{total} meta_dl=#{stats[:meta_downloaded]} " \
        "coord_dl=#{stats[:coord_system_downloaded]} meta_fail=#{stats[:meta_failed]} " \
        "coord_fail=#{stats[:coord_system_failed]} skipped_no_core=#{stats[:skipped_no_core]} " \
        "last=#{entry.db_type}/#{entry.release_num}/#{entry.db_name}"
      )
    end

    def organisms_in_release_dir(release_dir, sorted: true)
      names = Set.new
      Dir.each_child(release_dir.to_s) do |basename|
        if basename.end_with?(".tgz")
          names.add(basename.delete_suffix(".tgz"))
        elsif File.directory?(release_dir + basename)
          names.add(basename)
        end
      end
      sorted ? names.sort : names
    end

    def local_meta_coord_paths(release_dir, db_name)
      organism_dir = release_dir + db_name
      [organism_dir + "meta.txt", organism_dir + "coord_system.txt"]
    end

    def local_meta_txt_present?(path)
      path.file? && path.size.positive?
    end

    def local_coord_system_txt_present?(path)
      path.file? && path.size.positive?
    end

    def writable_organism_dir(base_dirs, db_type, release_num, db_name)
      release_dir = resolve_release_dir(base_dirs, db_type, release_num)
      return nil unless release_dir
      return nil unless organism_present_in_release?(release_dir, db_name)

      preferred_dir = release_dir + db_name
      if writable_path?(release_dir)
        FileUtils.mkdir_p(preferred_dir) unless preferred_dir.directory?
        return preferred_dir
      end

      organism_dir = ensure_release_dir(writable_ensembl_base_dir(base_dirs), db_type, release_num) + db_name
      FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
      organism_dir
    end

    def writable_path?(path)
      target = path.directory? ? path : path.dirname
      File.writable?(target)
    rescue StandardError
      false
    end

    def meta_files_db_name_filter(remote_db)
      organism_id = ENV["ORGANISM_ID"].to_s.strip
      if organism_id.present?
        organism = load_organisms(remote_db).find { |row| row[:id] == organism_id.to_i }
        return [organism[:ensembl_db_name]] if organism
      end

      ensembl_db_name = ENV["ENSEMBL_DB_NAME"].to_s.strip
      return [ensembl_db_name] if ensembl_db_name.present?

      nil
    end

    def all_ensembl_base_dirs
      candidates = ensembl_base_dir_candidates.map { |path| Pathname.new(path) }.select(&:directory?).uniq
      return candidates if merge_ensembl_data_dirs?

      primary = candidates.first
      primary ? [primary] : []
    end

    def merge_ensembl_data_dirs?
      ENV.fetch("ENSEMBL_MERGE_DATA_DIRS", "false").to_s.strip.downcase == "true"
    end

    def resolve_ensembl_base_dir
      all_ensembl_base_dirs.first
    end

    def ensembl_base_dir_candidates
      [
        ENV["ENSEMBL_DATA_DIR"],
        DEFAULT_ENSEMBL_DATA_DIR,
        defined?(APP_CONFIG) && APP_CONFIG.respond_to?(:[]) ? File.join(APP_CONFIG[:data_dir].to_s, "ensembl") : nil,
        ENV["PROD_DATA_DIR"].present? ? File.join(ENV["PROD_DATA_DIR"], "ensembl") : nil,
        ENV["DATA_DIR"].present? ? File.join(ENV["DATA_DIR"], "ensembl") : nil,
        "/data/asap/ensembl"
      ].compact.uniq
    end

    def writable_ensembl_base_dir(base_dirs)
      base_dirs.find { |path| path.to_s == DEFAULT_ENSEMBL_DATA_DIR } ||
        base_dirs.find { |path| path.to_s.start_with?("/mnt/asap_data") } ||
        base_dirs.first
    end

    def resolve_release_dir(base_dirs, db_type, release_num)
      base_dirs.each do |base_dir|
        release_dir = base_dir + db_type.to_s + release_num.to_s
        return release_dir if release_dir.directory?
      end
      nil
    end

    def ensure_release_dir(base_dir, db_type, release_num)
      release_dir = base_dir + db_type.to_s + release_num.to_s
      FileUtils.mkdir_p(release_dir) unless release_dir.directory?
      release_dir
    end

    def available_release_numbers(base_dirs, db_type)
      release_from = parse_release_bound("ENSEMBL_RELEASE_FROM")
      release_to = parse_release_bound("ENSEMBL_RELEASE_TO")
      numbers = Set.new

      base_dirs.each do |base_dir|
        type_dir = base_dir + db_type.to_s
        next unless type_dir.directory?

        type_dir.children.each do |entry|
          next unless entry.directory?
          next unless entry.basename.to_s.match?(/\A\d+\z/)

          release_num = entry.basename.to_s.to_i
          next if release_from && release_num < release_from
          next if release_to && release_num > release_to

          numbers.add(release_num)
        end
      end

      numbers.sort
    end

    def local_release_numbers_for_organism(organism, base_dirs)
      db_type = organism[:subdomain].to_sym
      db_name = organism[:ensembl_db_name]
      numbers = Set.new

      available_release_numbers(base_dirs, db_type).each do |release_num|
        release_dir = resolve_release_dir(base_dirs, db_type, release_num)
        next unless release_dir
        next unless organism_present_in_release?(release_dir, db_name)

        numbers.add(release_num)
      end

      numbers.sort
    end

    def release_numbers_for_scan(organism, base_dirs, subdomain_latest_release, download_missing: false)
      db_type = organism[:subdomain].to_sym
      db_name = organism[:ensembl_db_name]
      release_from = release_from_bound(db_type)
      release_to = release_to_bound(organism, subdomain_latest_release)
      return [] if release_from > release_to

      numbers = Set.new
      (release_from..release_to).each do |release_num|
        release_dir = resolve_release_dir(base_dirs, db_type, release_num)
        if release_dir && organism_present_in_release?(release_dir, db_name)
          numbers.add(release_num)
        elsif download_missing
          numbers.add(release_num)
        end
      end

      numbers.sort
    end

    def default_release_from(db_type)
      DEFAULT_RELEASE_FROM.fetch(db_type, 1)
    end

    def release_from_bound(db_type)
      parse_release_bound("ENSEMBL_RELEASE_FROM") || default_release_from(db_type)
    end

    def release_to_bound(organism, subdomain_latest_release)
      explicit = parse_release_bound("ENSEMBL_RELEASE_TO")
      return explicit if explicit

      db_type = organism[:subdomain].to_sym
      default_to = DEFAULT_RELEASE_TO.fetch(db_type, 115)
      organism_latest = organism[:latest_ensembl_release].to_i
      subdomain_latest = subdomain_latest_release.to_i
      candidate = [organism_latest, subdomain_latest].select(&:positive?).max
      return default_to unless candidate

      [candidate, default_to].min
    end

    def organism_present_in_release?(release_dir, db_name)
      return true if (release_dir + db_name).directory?
      return true if (release_dir + "#{db_name}.tgz").file?

      false
    end

    def core_folders_for_release(cache, db_type, release_num)
      cache_key = "#{db_type}:#{release_num}"
      cache[cache_key] ||= fetch_core_folder_names(db_type, release_num)
    end

    def assembly_name_for_organism(release_dir:, db_name:, db_type:, release_num:, core_folder:, download_missing_meta:, stats:)
      meta_path = ensure_meta_txt(
        release_dir: release_dir,
        db_name: db_name,
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        download_missing_meta: download_missing_meta,
        stats: stats
      )
      assembly_name = parse_assembly_name(meta_path) if valid_meta_file?(meta_path)
      return assembly_name if assembly_name.present?

      coord_path = ensure_coord_system_txt(
        release_dir: release_dir,
        db_name: db_name,
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        download_missing_meta: download_missing_meta,
        stats: stats
      )
      parse_assembly_name_from_coord_system(coord_path)
    end

    def ensure_meta_txt(release_dir:, db_name:, db_type:, release_num:, core_folder:, download_missing_meta:, stats:)
      organism_dir = release_dir + db_name
      meta_path = organism_dir + "meta.txt"
      return meta_path if valid_meta_file?(meta_path)

      meta_gz_path = organism_dir + "meta.txt.gz"
      if meta_gz_path.file?
        gunzip_file(meta_gz_path)
        return meta_path if valid_meta_file?(meta_path)
      end

      archive_path = release_dir + "#{db_name}.tgz"
      if archive_path.file?
        extracted = extract_meta_from_archive(archive_path, organism_dir)
        return extracted if valid_meta_file?(extracted)
      end

      FileUtils.rm_f(meta_path) if meta_path.file? && !valid_meta_file?(meta_path)

      if download_missing_meta
        resolved_core_folder = core_folder.presence || resolve_core_folder(db_name, core_folders_for_release({}, db_type, release_num))
        if resolved_core_folder.present?
          FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
          downloaded = download_meta_txt(
            db_type: db_type,
            release_num: release_num,
            core_folder: resolved_core_folder,
            destination_dir: organism_dir
          )
          stats[:meta_downloads] += 1 if downloaded
          return meta_path if valid_meta_file?(meta_path)
        end
      end

      stats[:skipped_no_meta] += 1
      nil
    end

    def valid_meta_file?(meta_path)
      meta_path&.file? && meta_path.size?(&:positive?) && parse_assembly_name(meta_path).present?
    end

    def ensure_coord_system_txt(release_dir:, db_name:, db_type:, release_num:, core_folder:, download_missing_meta:, stats:)
      organism_dir = release_dir + db_name
      coord_path = organism_dir + "coord_system.txt"
      return coord_path if valid_coord_system_file?(coord_path)

      archive_path = release_dir + "#{db_name}.tgz"
      if archive_path.file?
        extracted = extract_table_from_archive(archive_path, organism_dir, "coord_system.txt")
        return extracted if valid_coord_system_file?(extracted)
      end

      return nil unless download_missing_meta

      resolved_core_folder = core_folder.presence || resolve_core_folder(db_name, core_folders_for_release({}, db_type, release_num))
      return nil if resolved_core_folder.blank?

      FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
      downloaded = download_ensembl_table(
        db_type: db_type,
        release_num: release_num,
        core_folder: resolved_core_folder,
        table_name: "coord_system",
        destination_dir: organism_dir
      )
      stats[:meta_downloads] += 1 if downloaded
      return coord_path if valid_coord_system_file?(coord_path)

      nil
    end

    def valid_coord_system_file?(coord_path)
      coord_path&.file? && coord_path.size?(&:positive?) && parse_assembly_name_from_coord_system(coord_path).present?
    end

    def parse_assembly_name_from_coord_system(coord_path)
      return nil unless coord_path&.file?

      preferred = nil
      fallback = nil
      File.foreach(coord_path) do |line|
        line = normalize_ensembl_line(line)
        parts = line.chomp.split("\t")
        next if parts.size < 4

        coord_name = parts[2].to_s.strip
        version = parts[3].to_s.strip
        attribs = parts[5].to_s
        next if version.blank? || version == "\\N"
        next unless %w[primary_assembly chromosome].include?(coord_name)

        if attribs.include?("default_version")
          preferred = version
          break
        end
        fallback ||= version
      end

      preferred.presence || fallback
    end

    def extract_table_from_archive(archive_path, organism_dir, table_name)
      Dir.mktmpdir("asap_ensembl_") do |tmpdir|
        txt = extract_archive_member(archive_path, tmpdir, "*/#{table_name}.txt")
        if txt
          FileUtils.mkdir_p(organism_dir)
          destination = organism_dir + "#{table_name}.txt"
          FileUtils.cp(txt, destination)
          return destination
        end

        gz = extract_archive_member(archive_path, tmpdir, "*/#{table_name}.txt.gz")
        if gz
          FileUtils.mkdir_p(organism_dir)
          destination = organism_dir + "#{table_name}.txt.gz"
          FileUtils.cp(gz, destination)
          gunzip_file(destination)
          return organism_dir + "#{table_name}.txt" if (organism_dir + "#{table_name}.txt").file?
        end
      end
      nil
    end

    def extract_archive_member(archive_path, tmpdir, pattern)
      _stdout, stderr, status = Open3.capture3(
        "tar", "-xzf", archive_path.to_s, "-C", tmpdir, "--wildcards", pattern
      )
      unless status.success?
        Rails.logger.debug("[EnsemblAssembliesLoader] #{pattern} not in archive #{archive_path}: #{stderr.strip}")
        return nil
      end

      basename = File.basename(pattern)
      Dir.glob(File.join(tmpdir, "**", basename)).first
    end

    TABLE_DOWNLOAD_SUFFIXES = [".txt.gz", ".txt.gz.bz2", ".txt"].freeze

    def download_ensembl_table(db_type:, release_num:, core_folder:, table_name:, destination_dir:)
      destination_txt = destination_dir + "#{table_name}.txt"
      base_url = "#{mysql_base_url(db_type, release_num)}#{core_folder}/#{table_name}"

      TABLE_DOWNLOAD_SUFFIXES.each do |suffix|
        archive_path = destination_dir + "#{table_name}#{suffix}"
        next unless fetch_ftp_file("#{base_url}#{suffix}", archive_path)

        begin
          decompress_ensembl_table_archive(archive_path, suffix, destination_dir, table_name)
        rescue StandardError => e
          Rails.logger.warn(
            "[EnsemblAssembliesLoader] decompress failed for #{base_url}#{suffix}: #{e.message}"
          )
          cleanup_partial_table_download(destination_dir, table_name)
          next
        end

        return true if destination_txt.file? && destination_txt.size.positive?
      end

      false
    end

    def fetch_ftp_file(url, destination_path)
      _stdout, stderr, status = Open3.capture3("curl", "-s", "-f", "-o", destination_path.to_s, url)
      unless status.success? && destination_path.file? && destination_path.size.positive?
        FileUtils.rm_f(destination_path)
        Rails.logger.debug("[EnsemblAssembliesLoader] curl failed for #{url}: #{stderr.strip}")
        return false
      end

      true
    end

    def decompress_ensembl_table_archive(archive_path, suffix, destination_dir, table_name)
      case suffix
      when ".txt.gz"
        gunzip_file(archive_path)
      when ".txt.gz.bz2"
        bunzip2_file(archive_path)
        gunzip_file(destination_dir + "#{table_name}.txt.gz")
      when ".txt"
        destination_txt = destination_dir + "#{table_name}.txt"
        FileUtils.cp(archive_path, destination_txt) unless archive_path == destination_txt
      else
        raise ArgumentError, "unknown table suffix #{suffix}"
      end
    end

    def cleanup_partial_table_download(destination_dir, table_name)
      %W[#{table_name}.txt #{table_name}.txt.gz #{table_name}.txt.gz.bz2].each do |name|
        FileUtils.rm_f(destination_dir + name)
      end
    end

    def download_meta_txt(db_type:, release_num:, core_folder:, destination_dir:)
      download_ensembl_table(
        db_type: db_type,
        release_num: release_num,
        core_folder: core_folder,
        table_name: "meta",
        destination_dir: destination_dir
      )
    end

    def resolve_core_folder(db_name, core_folders)
      return core_folders[db_name] if core_folders[db_name].present?

      prefix_matches = core_folders.select do |core_name, _folder|
        db_name.start_with?("#{core_name}_") || core_name.start_with?("#{db_name}_") || db_name == core_name
      end
      return prefix_matches.values.first if prefix_matches.size == 1

      nil
    end

    def extract_meta_from_archive(archive_path, organism_dir)
      extract_table_from_archive(archive_path, organism_dir, "meta")
    end

    def gunzip_file(path)
      _stdout, stderr, status = Open3.capture3("gunzip", "-f", path.to_s)
      return if status.success?

      raise "gunzip failed for #{path}: #{stderr.strip}"
    end

    def bunzip2_file(path)
      _stdout, stderr, status = Open3.capture3("bunzip2", "-f", path.to_s)
      return if status.success?

      raise "bunzip2 failed for #{path}: #{stderr.strip}"
    end

    def parse_assembly_name(meta_path)
      values = {}
      File.foreach(meta_path) do |line|
        line = normalize_ensembl_line(line)
        parts = line.chomp.split("\t", 4)
        next if parts.size < 4

        key = parts[2].to_s.strip
        next unless META_KEYS.include?(key)

        value = parts[3].to_s.strip
        next if value.blank? || value == "\\N"

        values[key] = value
      end

      values["assembly.name"].presence || values["assembly.default"].presence
    end

    def normalize_ensembl_line(line)
      line.to_s.dup.force_encoding("iso-8859-1").encode("utf-8")
    end

    def fetch_core_folder_names(db_type, release_num)
      url = mysql_base_url(db_type, release_num)
      stdout, stderr, status = Open3.capture3("curl", "-s", "--list-only", url)
      unless status.success?
        Rails.logger.warn("[EnsemblAssembliesLoader] cannot list #{url}: #{stderr.strip}")
        return {}
      end

      names = {}
      stdout.each_line do |line|
        folder = line.strip
        next if folder.blank?
        next if folder.end_with?(".gz")
        next unless (core_match = folder.match(/\A(.+?)_core_/))

        names[core_match[1]] = folder
      end
      names
    end

    def mysql_base_url(db_type, release_num)
      if db_type == :vertebrates
        "ftp://ftp.ensembl.org/pub/release-#{release_num}/mysql/"
      else
        "ftp://ftp.ensemblgenomes.org/pub/release-#{release_num}/#{db_type}/mysql/"
      end
    end

    def load_subdomain_latest_releases(remote_db)
      RemoteOrganism.with_remote(remote_db) do
        conn = RemoteOrganism.connection
        conn.select_all(<<~SQL).each_with_object({}) do |row, hash|
          SELECT name, MAX(latest_ensembl_release) AS latest_ensembl_release
          FROM ensembl_subdomains
          GROUP BY name
        SQL
          hash[row["name"]] = row["latest_ensembl_release"].to_i
        end
      end
    end

    def load_organisms(remote_db)
      db_types = parse_db_types.map(&:to_s)
      RemoteOrganism.with_remote(remote_db) do
        conn = RemoteOrganism.connection
        subdomain_names = conn.select_all(<<~SQL).each_with_object({}) do |row, hash|
          SELECT DISTINCT ON (id) id, name
          FROM ensembl_subdomains
          ORDER BY id
        SQL
          hash[row["id"].to_i] = row["name"]
        end

        scope = RemoteOrganism.where.not(ensembl_db_name: [nil, ""])
        if ENV["ENSEMBL_DB_TYPES"].present?
          subdomain_ids = subdomain_names.select { |_id, name| db_types.include?(name) }.keys
          scope = scope.where(ensembl_subdomain_id: subdomain_ids)
        end

        scope.pluck(:id, :ensembl_db_name, :ensembl_subdomain_id, :latest_ensembl_release).filter_map do |id, db_name, subdomain_id, latest_release|
          subdomain = subdomain_names[subdomain_id.to_i]
          next if subdomain.blank?

          {
            id: id,
            ensembl_db_name: db_name,
            subdomain: subdomain,
            latest_ensembl_release: latest_release
          }
        end
      end
    end

    def assembly_cache_key(organism_id, name)
      "#{organism_id}:#{name}"
    end

    def upsert_assembly!(assemblies_by_key, organism_id, name, release_num, remote_db:)
      RemoteAssembly.with_remote(remote_db) do
        key = assembly_cache_key(organism_id, name)
        existing = assemblies_by_key[key]
        if existing
          new_first = [existing.first_ensembl_release, release_num].compact.min
          new_latest = [existing.latest_ensembl_release, release_num].compact.max
          if new_first != existing.first_ensembl_release || new_latest != existing.latest_ensembl_release
            existing.update!(
              first_ensembl_release: new_first,
              latest_ensembl_release: new_latest
            )
            return [false, true]
          end
          [false, false]
        else
          record = RemoteAssembly.create!(
            organism_id: organism_id,
            name: name,
            first_ensembl_release: release_num,
            latest_ensembl_release: release_num
          )
          assemblies_by_key[key] = record
          [true, false]
        end
      end
    end

    def default_remote_db
      ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    end

    def default_download_missing_meta?
      ENV.fetch("DOWNLOAD_MISSING_META", "true").to_s.strip.downcase != "false"
    end

    def parse_db_types
      raw = ENV["ENSEMBL_DB_TYPES"].to_s.strip
      return DB_TYPES if raw.blank?

      requested = raw.split(",").map { |value| value.strip.downcase.to_sym }.reject(&:blank?)
      invalid = requested - DB_TYPES
      raise ArgumentError, "Unknown ENSEMBL_DB_TYPES: #{invalid.join(', ')}" if invalid.any?

      requested
    end

    def parse_release_bound(env_name)
      raw = ENV[env_name].to_s.strip
      return nil if raw.blank?

      Integer(raw)
    end
  end
end
