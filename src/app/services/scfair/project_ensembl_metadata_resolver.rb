# frozen_string_literal: true

module Scfair
  # Resolves Ensembl release, database, and assembly for a project.
  # Preference order: Annot `/attrs/ensembl_*` (list_cat_json), parsing/output.json,
  # then Version tool_versions + ASAP assembly lookup.
  class ProjectEnsemblMetadataResolver
    COVID_TAX_ID = 2697049
    VERTEBRATES_SUBDOMAIN = 'vertebrates'
    PARSING_ESTIMATE_RE =
      /Estimated Ensembl release (\d+).*assembly '([^']+)'/i.freeze

    def self.call(project, lookup: nil)
      new(project, lookup: lookup).call
    end

    def initialize(project, lookup: nil)
      @project = project
      @lookup_override = lookup
    end

    def call
      organism = @project.organism
      version = @project.version_for_catalog
      return nil unless organism&.tax_id.present? && version

      env = version.env_data
      tool_versions = env['tool_versions'] || {}
      remote_db = asap_data_db_name(env)
      annots = resolve_from_annots
      parsing = resolve_from_parsing
      release = annots[:ensembl_release].presence ||
                parsing[:ensembl_release].presence ||
                resolve_release(organism, tool_versions)
      database = annots[:ensembl_database].presence || resolve_database(organism)
      assembly = annots[:ensembl_assembly].presence ||
                 parsing[:ensembl_assembly].presence ||
                 resolve_assembly(organism, release, remote_db)

      result = {}
      result[:ensembl_release] = release.to_s if release.present?
      result[:ensembl_database] = database if database.present?
      result[:ensembl_assembly] = assembly if assembly.present?
      if annots[:ensembl_assembly].present? || annots[:ensembl_release].present?
        result[:source] = :annot
      elsif parsing[:ensembl_release].present? || parsing[:ensembl_assembly].present?
        result[:source] = :parsing
      elsif release.present?
        result[:source] = :version
      end
      result.presence
    end

    private

    ENSEMBL_ATTR_NAMES = {
      ensembl_assembly: '/attrs/ensembl_assembly',
      ensembl_release: '/attrs/ensembl_release',
      ensembl_database: '/attrs/ensembl_database'
    }.freeze

    def asap_data_db_name(env)
      env['asap_data_db_name'].presence ||
        (env['asap_data_db_version'].present? && "asap_data_v#{env['asap_data_db_version']}")
    end

    # Prefer Annot rows written at parse time (list_cat_json / categories_json).
    def resolve_from_annots
      return {} unless @project.respond_to?(:annots)

      relation = @project.annots
      return {} if relation.nil?

      names = ENSEMBL_ATTR_NAMES.values
      rows =
        if relation.respond_to?(:where)
          scope = relation
          scope = scope.where(latest_version: true) if annot_has_latest_version_column?
          scope.where(name: names).to_a
        else
          Array(relation).select { |annot| names.include?(annot.name.to_s) }
        end
      return {} if rows.empty?

      # Prefer parsing/output.loom when several looms carry the same global attr.
      by_name = rows.group_by(&:name).transform_values do |group|
        group.min_by do |annot|
          path = annot.filepath.to_s
          [
            path == 'parsing/output.loom' ? 0 : 1,
            path.start_with?('parsing/') ? 0 : 1,
            annot.id.to_i
          ]
        end
      end

      result = {}
      ENSEMBL_ATTR_NAMES.each do |key, attr_name|
        value = scalar_from_annot(by_name[attr_name])
        result[key] = value if value.present?
      end
      result
    rescue StandardError
      {}
    end

    def annot_has_latest_version_column?
      defined?(Annot) && Annot.respond_to?(:column_names) && Annot.column_names.include?('latest_version')
    end

    def scalar_from_annot(annot)
      return nil unless annot

      list = Basic.safe_parse_json(annot.list_cat_json, nil)
      if list.is_a?(Array)
        value = list.map { |entry| entry.to_s.strip }.reject(&:blank?).first
        return value if value.present?
      elsif list.is_a?(Hash)
        value = list.keys.map { |entry| entry.to_s.strip }.reject(&:blank?).first
        return value if value.present?
      end

      cats = Basic.safe_parse_json(annot.categories_json, nil)
      if cats.is_a?(Hash)
        value = cats.keys.map { |entry| entry.to_s.strip }.reject(&:blank?).first
        return value if value.present?
      end

      nil
    end

    def resolve_from_parsing
      path = parsing_output_json_path
      return {} unless path && File.exist?(path)

      data = JSON.parse(File.read(path))
      from_metadata = ensembl_values_from_parsing_metadata(data['metadata'])
      return from_metadata if from_metadata[:ensembl_assembly].present? || from_metadata[:ensembl_release].present?

      Array(data['messages']).each do |message|
        match = message.to_s.match(PARSING_ESTIMATE_RE)
        next unless match

        return {
          ensembl_release: match[1],
          ensembl_assembly: match[2]
        }
      end
      {}
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES
      {}
    end

    def ensembl_values_from_parsing_metadata(metadata)
      result = {}
      Array(metadata).each do |entry|
        next unless entry.is_a?(Hash)

        name = entry['name'].to_s
        key = ENSEMBL_ATTR_NAMES.key(name)
        next unless key

        cats = entry['categories']
        value =
          if cats.is_a?(Hash)
            cats.keys.map { |entry_key| entry_key.to_s.strip }.reject(&:blank?).first
          elsif entry['values'].is_a?(Array)
            entry['values'].map { |v| v.to_s.strip }.reject(&:blank?).first
          end
        result[key] = value if value.present?
      end
      result
    end

    def parsing_output_json_path
      return nil unless @project.respond_to?(:storage_dir)

      File.join(@project.storage_dir.to_s, 'parsing', 'output.json')
    end

    def resolve_release(organism, tool_versions)
      return nil if tool_versions.blank?

      if organism.tax_id.to_i == COVID_TAX_ID
        tool_versions['ensembl_genomes'] || tool_versions['ensembl_vertebrate']
      elsif organism.ensembl_subdomain&.name == VERTEBRATES_SUBDOMAIN
        tool_versions['ensembl_vertebrate']
      else
        tool_versions['ensembl_genomes']
      end
    end

    def resolve_database(organism)
      return 'EnsemblCOVID-19' if organism.tax_id.to_i == COVID_TAX_ID
      return 'Ensembl' if organism.ensembl_subdomain&.name == VERTEBRATES_SUBDOMAIN
      return 'EnsemblMetazoa' if organism.ensembl_subdomain_id.present?

      nil
    end

    def resolve_assembly(organism, release, remote_db)
      return nil if release.blank? || remote_db.blank?

      lookup = @lookup_override || EnsemblReferenceLookup.new(remote_db: remote_db)
      return nil unless lookup.remote_available?

      lookup.assembly_name_at_release_for_organism(organism.tax_id, release)
    end
  end
end
