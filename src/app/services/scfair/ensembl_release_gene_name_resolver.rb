# frozen_string_literal: true

require 'set'
require 'open3'

module Scfair
  # Resolves Ensembl display gene names for a specific release from local Ensembl dumps.
  # Mirrors update_genes.rake: gene_name when display_xref is assigned, otherwise stable_id.
  class EnsemblReleaseGeneNameResolver
    GENE_STABLE_ID_COLUMN = 12
    DISPLAY_XREF_COLUMN = 7

    def initialize
      @names_by_cache_key = {}
      @loaded_keys = Set.new
    end

    def available?
      AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs.any?
    rescue StandardError
      false
    end

    def preload!(db_type:, ensembl_db_name:, release:, ensembl_ids:)
      release = release.to_i
      return if release <= 0

      ids = Array(ensembl_ids).map { |id| normalize_id(id) }.compact.uniq
      return if ids.empty?

      key = cache_key(db_type, ensembl_db_name, release)
      return if @loaded_keys.include?(key)

      target_ids = ids.to_set
      if db_type.to_s == AsapData::EnsemblCovidLoader::SUBDOMAIN
        gtf_path = AsapData::EnsemblCovidLoader.cached_gtf_path(release: release)
        if gtf_path
          @names_by_cache_key[key] = AsapData::EnsemblCovidLoader.gene_names_from_gtf(gtf_path, target_ids)
          @loaded_keys << key
        end
        return
      end

      gene_path, xref_path = table_paths(db_type:, ensembl_db_name:, release:)
      return unless gene_path && xref_path

      xref_names = load_xref_names(xref_path)
      names = {}
      File.foreach(gene_path) do |line|
        line = line.force_encoding('iso-8859-1').encode('utf-8')
        parts = line.chomp.split("\t")
        next if parts.size <= GENE_STABLE_ID_COLUMN

        stable_id = normalize_id(parts[GENE_STABLE_ID_COLUMN])
        next if stable_id.blank? || !target_ids.include?(stable_id)

        display_xref_id = parts[DISPLAY_XREF_COLUMN].to_s
        names[stable_id] = gene_name_from_display_xref(display_xref_id, xref_names, stable_id)
      end

      @names_by_cache_key[key] = names
      @loaded_keys << key
    rescue StandardError => e
      Rails.logger.warn("[EnsemblReleaseGeneNameResolver] preload failed: #{e.class}: #{e.message}")
      nil
    end

    def gene_name_for(ensembl_id, db_type:, ensembl_db_name:, release:)
      stable_id = normalize_id(ensembl_id)
      return nil if stable_id.blank?

      key = cache_key(db_type, ensembl_db_name, release)
      @names_by_cache_key.dig(key, stable_id)
    end

    private

    def cache_key(db_type, ensembl_db_name, release)
      [db_type.to_s, ensembl_db_name.to_s, release.to_i].join(':')
    end

    def normalize_id(value)
      id = value.to_s.strip
      return nil if id.blank? || id == '\\N'

      id.sub(/\.\d+\z/, '')
    end

    def gene_name_from_display_xref(display_xref_id, xref_names, stable_id)
      name = xref_names[display_xref_id].to_s.strip
      return stable_id if name.blank? || name == '\\N'

      name.gsub(/\s+\(\s*\d+\s+of\s+\w+\s*\)/, '').strip.presence || stable_id
    end

    def load_xref_names(xref_path)
      names = {}
      File.foreach(xref_path) do |line|
        line = line.force_encoding('iso-8859-1').encode('utf-8')
        parts = line.chomp.split("\t")
        next if parts.size < 4

        names[parts[0]] = parts[3]
      end
      names
    end

    def table_paths(db_type:, ensembl_db_name:, release:)
      release_dir = resolve_release_dir(db_type, release)
      return [nil, nil] unless release_dir

      organism_dir = release_dir + ensembl_db_name.to_s
      gene_path = ensure_table_file(organism_dir, release_dir, ensembl_db_name, 'gene.txt')
      xref_path = ensure_table_file(organism_dir, release_dir, ensembl_db_name, 'xref.txt')
      return [nil, nil] unless gene_path&.file? && xref_path&.file?

      [gene_path, xref_path]
    end

    def resolve_release_dir(db_type, release)
      AsapData::EnsemblAssembliesLoader.resolve_release_dir(
        AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs,
        db_type.to_sym,
        release.to_i
      )
    end

    def ensure_table_file(organism_dir, release_dir, ensembl_db_name, table_name)
      path = organism_dir + table_name
      return path if path.file? && path.size?.positive?

      gz_path = organism_dir + "#{table_name}.gz"
      if gz_path.file?
        gunzip_file(gz_path)
        return path if path.file? && path.size?.positive?
      end

      archive_path = release_dir + "#{ensembl_db_name}.tgz"
      return nil unless archive_path.file?

      extracted = extract_table_from_archive(archive_path, organism_dir, table_name)
      return extracted if extracted&.file?

      extracted_gz = extract_table_from_archive(archive_path, organism_dir, "#{table_name}.gz")
      return nil unless extracted_gz&.file?

      gunzip_file(extracted_gz)
      path.file? ? path : nil
    end

    def extract_table_from_archive(archive_path, organism_dir, table_name)
      require 'tmpdir'
      Dir.mktmpdir('scfair_ensembl_') do |tmpdir|
        _stdout, stderr, status = Open3.capture3(
          'tar', '-xzf', archive_path.to_s, '-C', tmpdir, '--wildcards', "*/#{table_name}"
        )
        unless status.success?
          Rails.logger.debug(
            "[EnsemblReleaseGeneNameResolver] #{table_name} not in archive #{archive_path}: #{stderr.strip}"
          )
          return nil
        end

        extracted = Dir.glob(File.join(tmpdir, '**', table_name)).first
        return nil unless extracted

        FileUtils.mkdir_p(organism_dir) unless organism_dir.directory?
        destination = organism_dir + table_name
        FileUtils.cp(extracted, destination)
        destination
      end
    end

    def gunzip_file(gz_path)
      destination = gz_path.sub_ext('')
      return destination if destination.file? && destination.size?.positive?

      system('gunzip', '-f', gz_path.to_s)
      destination.file? ? destination : nil
    end
  end
end
