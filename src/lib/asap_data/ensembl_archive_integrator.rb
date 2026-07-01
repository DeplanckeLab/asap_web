# frozen_string_literal: true

require "open3"
require "pathname"
require "set"
require "fileutils"

module AsapData
  module EnsemblArchiveIntegrator
    module_function

  INTEGRATION_TABLES = %w[
    meta.txt
    coord_system.txt
    gene.txt
    xref.txt
    object_xref.txt
    external_synonym.txt
    external_db.txt
    seq_region.txt
    transcript.txt
    exon_transcript.txt
    exon.txt
    gene_stable_id.txt
  ].freeze

    def integrate!(dry_run: default_dry_run?, create_missing_archives: default_create_missing_archives?)
      base_dirs = EnsemblAssembliesLoader.all_ensembl_base_dirs
      raise ArgumentError, "Ensembl data directory not found (set ENSEMBL_DATA_DIR)" if base_dirs.empty?

      stats = {
        organisms_checked: 0,
        archives_updated: 0,
        archives_created: 0,
        dirs_removed: 0,
        skipped_no_dir: 0,
        skipped_no_files: 0,
        skipped_no_archive: 0,
        failed: 0
      }

      EnsemblAssembliesLoader.parse_db_types.each do |db_type|
        EnsemblAssembliesLoader.available_release_numbers(base_dirs, db_type).each do |release_num|
          organism_names = organism_names_for_release(base_dirs, db_type, release_num)
          organism_names.each do |db_name|
            next if db_name_filter && !db_name_filter.include?(db_name)

            organism_dirs = organism_dirs_for_release(base_dirs, db_type, release_num, db_name)
            if organism_dirs.empty?
              stats[:skipped_no_dir] += 1
              next
            end

            loose_files = loose_files_for_dirs(organism_dirs)
            if loose_files.empty?
              stats[:skipped_no_files] += 1
              next
            end

            stats[:organisms_checked] += 1
            archive_path = resolve_archive_path(base_dirs, db_type, release_num, db_name)

            if archive_path.nil?
              unless create_missing_archives
                stats[:skipped_no_archive] += 1
                next
              end

              archive_path = default_archive_path(base_dirs, db_type, release_num, db_name)
              if dry_run
                stats[:archives_created] += 1
                stats[:dirs_removed] += organism_dirs.size
                next
              end

              if create_archive!(archive_path, db_name, loose_files)
                stats[:archives_created] += 1
                stats[:dirs_removed] += remove_organism_dirs!(organism_dirs)
              else
                stats[:failed] += 1
              end
              next
            end

            if dry_run
              stats[:archives_updated] += 1
              stats[:dirs_removed] += organism_dirs.size
              next
            end

            if integrate_into_archive!(archive_path, db_name, loose_files)
              stats[:archives_updated] += 1
              stats[:dirs_removed] += remove_organism_dirs!(organism_dirs)
            else
              stats[:failed] += 1
            end
          end
        end
      end

      stats
    end

    def integrate_into_archive!(archive_path, db_name, loose_files)
      Dir.mktmpdir("asap_ensembl_integrate_") do |tmpdir|
        tmpdir_path = Pathname.new(tmpdir)
        extract_root = tmpdir_path + "extract"
        FileUtils.mkdir_p(extract_root)

        if archive_path.file?
          _stdout, stderr, status = Open3.capture3("tar", "-xzf", archive_path.to_s, "-C", extract_root.to_s)
          unless status.success?
            Rails.logger.warn("[EnsemblArchiveIntegrator] extract failed for #{archive_path}: #{stderr.strip}")
            return false
          end
        else
          FileUtils.mkdir_p(extract_root + db_name)
        end

        organism_root = extract_root + db_name
        FileUtils.mkdir_p(organism_root) unless organism_root.directory?

        loose_files.each do |filename, source_path|
          FileUtils.cp(source_path, organism_root + filename, preserve: true)
        end

        new_archive = archive_path.sub_ext(".tgz.new")
        FileUtils.rm_f(new_archive)
        _stdout, stderr, status = Open3.capture3(
          "tar", "-czf", new_archive.to_s, "-C", extract_root.to_s, db_name
        )
        unless status.success? && new_archive.file? && new_archive.size?(&:positive?)
          FileUtils.rm_f(new_archive)
          Rails.logger.warn("[EnsemblArchiveIntegrator] repack failed for #{archive_path}: #{stderr.strip}")
          return false
        end

        FileUtils.mv(new_archive, archive_path)
      end
      true
    end

    def create_archive!(archive_path, db_name, loose_files)
      Dir.mktmpdir("asap_ensembl_create_") do |tmpdir|
        organism_root = Pathname.new(tmpdir) + db_name
        FileUtils.mkdir_p(organism_root)
        loose_files.each do |filename, source_path|
          FileUtils.cp(source_path, organism_root + filename, preserve: true)
        end

        FileUtils.mkdir_p(archive_path.dirname)
        _stdout, stderr, status = Open3.capture3(
          "tar", "-czf", archive_path.to_s, "-C", tmpdir, db_name
        )
        unless status.success? && archive_path.file? && archive_path.size?(&:positive?)
          FileUtils.rm_f(archive_path)
          Rails.logger.warn("[EnsemblArchiveIntegrator] create failed for #{archive_path}: #{stderr.strip}")
          return false
        end
      end
      true
    end

    def loose_files_for_dirs(organism_dirs)
      files = {}
      organism_dirs.each do |organism_dir|
        organism_dir.children.each do |entry|
          next unless entry.file?

          basename = entry.basename.to_s
          next unless integration_file?(basename)

          files[basename] = entry
        end
      end
      files
    end

    def integration_file?(basename)
      return true if INTEGRATION_TABLES.include?(basename)
      return true if basename.end_with?(".txt") && !basename.end_with?(".txt.gz")

      false
    end

    def organism_names_for_release(base_dirs, db_type, release_num)
      names = Set.new
      base_dirs.each do |base_dir|
        release_dir = base_dir + db_type.to_s + release_num.to_s
        next unless release_dir.directory?

        EnsemblAssembliesLoader.organisms_in_release_dir(release_dir).each { |name| names.add(name) }
      end
      names.sort
    end

    def organism_dirs_for_release(base_dirs, db_type, release_num, db_name)
      base_dirs.filter_map do |base_dir|
        dir = base_dir + db_type.to_s + release_num.to_s + db_name
        dir if dir.directory? && dir.children.any? { |entry| entry.file? }
      end.uniq
    end

    def resolve_archive_path(base_dirs, db_type, release_num, db_name)
      base_dirs.each do |base_dir|
        archive_path = base_dir + db_type.to_s + release_num.to_s + "#{db_name}.tgz"
        return archive_path if archive_path.file?
      end
      nil
    end

    def default_archive_path(base_dirs, db_type, release_num, db_name)
      release_dir = EnsemblAssembliesLoader.resolve_release_dir(base_dirs, db_type, release_num) ||
                    EnsemblAssembliesLoader.ensure_release_dir(
                      EnsemblAssembliesLoader.writable_ensembl_base_dir(base_dirs),
                      db_type,
                      release_num
                    )
      release_dir + "#{db_name}.tgz"
    end

    def remove_organism_dirs!(organism_dirs)
      removed = 0
      organism_dirs.each do |organism_dir|
        next unless organism_dir.directory?

        FileUtils.rm_rf(organism_dir)
        removed += 1 if !organism_dir.directory?
      end
      removed
    end

    def db_name_filter
      organism_id = ENV["ORGANISM_ID"].to_s.strip
      if organism_id.present?
        remote_db = ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
        organism = EnsemblAssembliesLoader.load_organisms(remote_db).find { |row| row[:id] == organism_id.to_i }
        return [organism[:ensembl_db_name]] if organism
      end

      ensembl_db_name = ENV["ENSEMBL_DB_NAME"].to_s.strip
      return [ensembl_db_name] if ensembl_db_name.present?

      nil
    end

    def default_dry_run?
      ENV.fetch("DRY_RUN", "false").to_s.strip.downcase == "true"
    end

    def default_create_missing_archives?
      ENV.fetch("CREATE_MISSING_ARCHIVES", "false").to_s.strip.downcase == "true"
    end
  end
end
