# frozen_string_literal: true

# Builds a finite list of {Regexp} rules for metadata import reserved names (R-NM1, R-NM3).
#
# Sources:
# - Optional {Version#env_json} key +metadata_import_reserved+ (exact_paths and regexp strings).
# - String values under +/col_attrs/+ and +/row_attrs/+ found in {Step} and {StdMethod} JSON columns
#   for the project's ASAP {DockerImage}.
# - {OntologyTermType} +term_path+ / +label_path+ and {ComplianceMapping} +target_path+ when they are
#   full LOOM attribute paths.
#
# Results are cached per +version+ and +docker_image+ (6 hours).
class MetadataImportReservedPatternCatalog
  # Full-path strings only (segment after prefix: letters, digits, underscore, dot, hyphen).
  LOOM_ATTR_PATH_STRING = %r{\A/(?:col_attrs|row_attrs)/[A-Za-z0-9_.\-]+\z}.freeze

  JSON_COLUMNS_STEP = %w[attrs_json command_json dashboard_card_json].freeze
  JSON_COLUMNS_STD_METHOD = %w[attrs_json obj_attrs_json output_json command_json attr_layout_json].freeze
  JSON_COLUMNS_VERSION_EXTRA = %w[tools_json docker_json].freeze

  class << self
    def regexps_for_project(project)
      version = project&.version
      return [] unless version

      docker = Basic.get_asap_docker(version)
      return [] unless docker

      Rails.cache.fetch(cache_key(version, docker), expires_in: 6.hours) do
        compile(build(docker, version))
      end
    end

    private

    def cache_key(version, docker)
      ["metadata_import_reserved_pattern_catalog", "v1", docker.id, version.id]
    end

    def build(docker, version)
      exact = Set.new
      regexp_sources = []

      load_from_version_reserved_block(version, exact, regexp_sources)
      walk_collect_strings(version.read_attribute(:env_json), exact)
      JSON_COLUMNS_VERSION_EXTRA.each do |col|
        next unless version.class.column_names.include?(col)

        walk_collect_strings(version.read_attribute(col), exact)
      end

      load_from_steps_and_std_methods(docker, exact)
      load_from_ontology_and_compliance(exact)
      load_from_output_attrs(exact)

      { exact: exact.to_a, regexp_sources: regexp_sources }
    end

    def load_from_version_reserved_block(version, exact, regexp_sources)
      data = Basic.safe_parse_json(version.env_json, {})
      block = data["metadata_import_reserved"] || data[:metadata_import_reserved]
      return unless block.is_a?(Hash)

      %w[exact_paths exact_path strings].each do |k|
        Array(block[k] || block[k.to_sym]).each do |p|
          s = p.to_s.strip
          exact << s if s.match?(LOOM_ATTR_PATH_STRING)
        end
      end

      %w[regexp regexps patterns].each do |k|
        Array(block[k] || block[k.to_sym]).each do |r|
          src = r.to_s.strip
          regexp_sources << src if src.present?
        end
      end
    end

    def load_from_steps_and_std_methods(docker, exact)
      Step.where(docker_image_id: docker.id).find_each do |step|
        JSON_COLUMNS_STEP.each do |col|
          walk_collect_strings(step.public_send(col), exact)
        end
      end

      StdMethod.where(docker_image_id: docker.id).find_each do |m|
        JSON_COLUMNS_STD_METHOD.each do |col|
          walk_collect_strings(m.public_send(col), exact)
        end
      end
    end

    def load_from_ontology_and_compliance(exact)
      OntologyTermType.find_each do |ott|
        [ott.term_path, ott.label_path].each do |p|
          s = p.to_s.strip
          exact << s if s.match?(LOOM_ATTR_PATH_STRING)
        end
      end

      ComplianceMapping.where.not(target_path: [nil, ""]).distinct.pluck(:target_path).each do |p|
        s = p.to_s.strip
        exact << s if s.match?(LOOM_ATTR_PATH_STRING)
      end
    end

    def load_from_output_attrs(exact)
      OutputAttr.where.not(name: [nil, ""]).pluck(:name).each do |n|
        s = n.to_s.strip
        exact << s if s.match?(LOOM_ATTR_PATH_STRING)
      end
    end

    def walk_collect_strings(raw, exact)
      obj = Basic.safe_parse_json(raw, nil)
      return if obj.nil?

      walk_json(obj) do |str|
        exact << str if str.match?(LOOM_ATTR_PATH_STRING)
      end
    end

    def walk_json(obj)
      case obj
      when Hash
        obj.each_value { |v| walk_json(v) { |s| yield s } }
      when Array
        obj.each { |e| walk_json(e) { |s| yield s } }
      when String
        yield obj if obj.present?
      end
    end

    def compile(h)
      regexps = []

      h[:exact].each do |path|
        regexps << Regexp.new("\\A#{Regexp.escape(path)}\\z")
      end

      h[:regexp_sources].each do |src|
        regexps << Regexp.new(src)
      rescue RegexpError => e
        Rails.logger.warn(
          "[MetadataImportReservedPatternCatalog] Ignoring invalid regexp from version env: #{src.inspect} (#{e.message})"
        )
      end

      dedupe_regexps(regexps)
    end

    def dedupe_regexps(list)
      seen = {}
      list.each do |re|
        key = "#{re.source}\0#{re.options}"
        seen[key] = re
      end
      seen.values
    end
  end
end
