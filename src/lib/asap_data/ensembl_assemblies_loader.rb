# frozen_string_literal: true

require "open3"
require "pathname"
require "set"

module AsapData
  module EnsemblAssembliesLoader
    module_function

    DB_TYPES = %i[vertebrates bacteria fungi metazoa plants protists].freeze
    META_KEYS = %w[assembly.name assembly.default].freeze

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
          subdomain_latest_releases[organism[:subdomain]]
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

    def all_ensembl_base_dirs
      ensembl_base_dir_candidates.map { |path| Pathname.new(path) }.select(&:directory?).uniq
    end

    def resolve_ensembl_base_dir
      all_ensembl_base_dirs.first
    end

    def ensembl_base_dir_candidates
      [
        ENV["ENSEMBL_DATA_DIR"],
        defined?(APP_CONFIG) && APP_CONFIG.respond_to?(:[]) ? File.join(APP_CONFIG[:data_dir].to_s, "ensembl") : nil,
        ENV["PROD_DATA_DIR"].present? ? File.join(ENV["PROD_DATA_DIR"], "ensembl") : nil,
        ENV["DATA_DIR"].present? ? File.join(ENV["DATA_DIR"], "ensembl") : nil,
        "/mnt/asap_data/ensembl",
        "/data/asap/ensembl"
      ].compact.uniq
    end

    def writable_ensembl_base_dir(base_dirs)
      base_dirs.find { |path| path.to_s.start_with?("/data/asap") } || base_dirs.first
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

    def release_numbers_for_scan(organism, base_dirs, subdomain_latest_release)
      local_releases = local_release_numbers_for_organism(organism, base_dirs)
      latest_release = organism[:latest_ensembl_release].to_i
      numbers = Set.new(local_releases)

      if latest_release.positive? && release_in_bounds?(latest_release)
        numbers.add(latest_release)
      elsif numbers.empty?
        subdomain_latest = subdomain_latest_release.to_i
        numbers.add(subdomain_latest) if subdomain_latest.positive? && release_in_bounds?(subdomain_latest)
      end

      numbers.sort
    end

    def release_in_bounds?(release_num)
      release_from = parse_release_bound("ENSEMBL_RELEASE_FROM")
      release_to = parse_release_bound("ENSEMBL_RELEASE_TO")
      return false if release_from && release_num < release_from
      return false if release_to && release_num > release_to

      true
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
        _stdout, stderr, status = Open3.capture3(
          "tar", "-xzf", archive_path.to_s, "-C", tmpdir, "--wildcards", "*/#{table_name}.txt", "*/#{table_name}.txt.gz"
        )
        unless status.success?
          Rails.logger.debug("[EnsemblAssembliesLoader] #{table_name} not in archive #{archive_path}: #{stderr.strip}")
          return nil
        end

        txt = Dir.glob(File.join(tmpdir, "**", "#{table_name}.txt")).first
        gz = Dir.glob(File.join(tmpdir, "**", "#{table_name}.txt.gz")).first
        if txt
          FileUtils.mkdir_p(organism_dir)
          destination = organism_dir + "#{table_name}.txt"
          FileUtils.cp(txt, destination)
          return destination
        end
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

    def download_ensembl_table(db_type:, release_num:, core_folder:, table_name:, destination_dir:)
      url = "#{mysql_base_url(db_type, release_num)}#{core_folder}/#{table_name}.txt.gz"
      destination_gz = destination_dir + "#{table_name}.txt.gz"
      _stdout, stderr, status = Open3.capture3("wget", "-qO", destination_gz.to_s, url)
      unless status.success? && destination_gz.file? && destination_gz.size?(&:positive?)
        FileUtils.rm_f(destination_gz)
        Rails.logger.warn("[EnsemblAssembliesLoader] wget failed for #{url}: #{stderr.strip}")
        return false
      end

      gunzip_file(destination_gz)
      (destination_dir + "#{table_name}.txt").file?
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

    def parse_assembly_name(meta_path)
      values = {}
      File.foreach(meta_path) do |line|
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

    def fetch_core_folder_names(db_type, release_num)
      url = mysql_base_url(db_type, release_num)
      stdout, stderr, status = Open3.capture3("wget", "-O", "-", url)
      unless status.success?
        Rails.logger.warn("[EnsemblAssembliesLoader] cannot list #{url}: #{stderr.strip}")
        return {}
      end

      names = {}
      stdout.each_line do |line|
        next unless (match = line.match(/>(\w+)\/</))
        next unless (core_match = match[1].match(/(.+?)_core_/))

        names[core_match[1]] = match[1].strip
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
