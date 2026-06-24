# frozen_string_literal: true

require 'open3'

# Shared helpers for loading compliance validation data.
# Included by ComplianceController and ProjectsController.
module ComplianceHelpers
  extend ActiveSupport::Concern

  included do
    if respond_to?(:helper_method)
      helper_method :compliance_report_uses_check_groups?
      helper_method :compliance_check_report_payload
    end
  end

  def compliance_report_uses_check_groups?(validation_result)
    return false if validation_result.blank?

    stored = validation_result[:check_groups] || validation_result['check_groups']
    stored.is_a?(Array) && stored.any?
  end

  def compliance_check_report_payload(validation_result, check_groups)
    schema_id = resolve_validation_schema_id(validation_result)
    bundle = Scfair::Rules.for(schema_id)
    {
      valid: validation_result[:valid] == true || validation_result['valid'] == true,
      errors: validation_result[:errors] || validation_result['errors'] || [],
      warnings: validation_result[:warnings] || validation_result['warnings'] || [],
      check_groups: check_groups || [],
      format: (validation_result[:format] || validation_result['format'] || 'loom').to_s,
      schema_id: schema_id,
      rules_yaml_path: bundle.rules_relative_path
    }
  end

  def resolve_project_schema_id(project, validation_result: nil)
    resolve_validation_schema_id(validation_result || load_validation_result(project), project: project)
  end

  def resolve_validation_schema_id(validation_result, project: nil)
    stored = validation_result&.dig(:schema_id) || validation_result&.dig('schema_id')
    return stored.to_s if stored.present?

    if project
      cs = project.compliance_schemas.first
      mapped = schema_id_for_compliance_schema(cs)
      return mapped if mapped.present?
    end

    Scfair::Rules::DEFAULT_SCHEMA_ID
  end

  def schema_id_for_compliance_schema(compliance_schema)
    return nil unless compliance_schema&.version.present?

    version = compliance_schema.version.to_s
    entry = Scfair::RulesRegistry.entries.values.find { |e| e.version == version }
    entry&.id
  end

  def project_fix_field_resolutions(project, field_values, format: 'loom')
    Scfair::ProjectOntologyResolutionChecker.new(
      field_values: field_values || {},
      project: project,
      format: format
    ).call[:field_resolutions] || {}
  end

  def merge_field_resolutions!(resolved_hash, resolutions)
    return resolved_hash unless resolutions.is_a?(Hash)

    resolutions.each do |path, vals|
      next unless vals.is_a?(Hash)

      path_s = path.to_s
      resolved_hash[path_s] ||= {}
      vals.each do |value, status|
        value_s = value.to_s
        resolved_hash[path_s][value_s] = status unless resolved_hash[path_s].key?(value_s)
      end
    end
    resolved_hash
  end

  private

  def run_project_compliance_validation(loom_path, project, logger: Rails.logger)
    schema_id = resolve_project_schema_id(project)
    CompliancePipeline.validate_project_loom(loom_path, project, logger: logger, schema_id: schema_id)
  end

  def loom_compliance_result(loom_path, project: nil, logger: Rails.logger)
    CompliancePipeline.validate_loom_file(loom_path, project: project, logger: logger)
  end

  def project_validation_payload(project, result, loom_path, schema_config)
    payload = {
      valid: result.valid?,
      schema_version: result.schema_version,
      schema_name: schema_config['name'],
      source_url: schema_config['source_url'],
      source_schema_name: schema_config['source_schema_name'],
      description: schema_config['description'],
      url: schema_config['url'],
      compliant_icon: schema_config['compliant_icon'],
      not_compliant_icon: schema_config['not_compliant_icon'],
      validated_at: result.validated_at,
      loom_path: loom_path,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info,
      valid_checks: CompliancePipeline.displayable_valid_checks(result.valid_checks),
      errors_count: result.errors.count,
      warnings_count: result.warnings.count,
      info_count: result.info.count,
      valid_checks_count: CompliancePipeline.displayable_valid_checks(result.valid_checks).count,
      report_format: 'file_check',
      schema_id: result.respond_to?(:schema_id) ? result.schema_id : Scfair::Rules::DEFAULT_SCHEMA_ID
    }
    if result.respond_to?(:field_values) && result.field_values.present?
      payload[:field_values] = result.field_values
    end
    if result.respond_to?(:check_groups) && result.check_groups.present?
      payload[:check_groups] = result.check_groups
    end
    if result.respond_to?(:format) && result.format.present?
      payload[:format] = result.format
    end
    payload
  end

  def resolve_compliance_check_groups(validation_result)
    return [] if validation_result.blank?

    stored = validation_result[:check_groups] || validation_result['check_groups']
    return symbolize_check_groups(stored) if stored.present?

    format = (validation_result[:format] || validation_result['format'] || 'loom').to_s
    field_values = validation_result[:field_values] || validation_result['field_values'] || {}
    errors = validation_result[:errors] || validation_result['errors'] || []
    warnings = validation_result[:warnings] || validation_result['warnings'] || []
    valid_checks = validation_result[:valid_checks] || validation_result['valid_checks'] || []

    schema_id = resolve_validation_schema_id(validation_result)

    Scfair::Rules.with_bundle(schema_id) do
      Scfair::ComplianceCheckGroupsBuilder.call(
        errors: errors,
        warnings: warnings,
        valid_checks: valid_checks,
        field_values: field_values,
        format: format
      )
    end
  end

  def symbolize_check_groups(groups)
    Array(groups).map do |group|
      g = group.deep_symbolize_keys
      g[:items] = Array(g[:items]).map(&:deep_symbolize_keys)
      g
    end
  end

  def fix_ui_values_from_validation_or_loom(validation_result, loom_path, field_paths, paired_paths: [])
    cached = validation_result[:field_values] || validation_result['field_values']
    if cached.present?
      return Scfair::FieldValuesFixUiAdapter.call(
        field_values: cached,
        field_paths: field_paths,
        paired_paths: paired_paths
      )
    end

    batch_read_field_values(loom_path, field_paths, paired_paths: paired_paths)
  end

  # valid_checks may include mirrored failed/warning entries for file-check grouping;
  # project compliance UI should only show passed checks in the green list.
  def displayable_valid_checks(valid_checks)
    CompliancePipeline.displayable_valid_checks(valid_checks)
  end

  # Load the validation result for a project, trying multiple storage locations.
  # Returns a Hash with symbolized keys, or nil.
  def load_validation_result(project)
    if project.respond_to?(:cxg_validation_result)
      result = project.cxg_validation_result
      return result.deep_symbolize_keys if result.present?
    end

    if project.respond_to?(:metadata) && project.metadata&.dig('cxg_validation')
      return project.metadata['cxg_validation'].deep_symbolize_keys
    end

    # Try loading from project directory first (primary location)
    if project.respond_to?(:key) && project.respond_to?(:user_id) && project.key.present? && project.user_id.present?
      project_validation_path = File.join(
        ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
        project.user_id.to_s,
        project.key,
        'cxg_validation_result.json'
      )

      if File.exist?(project_validation_path)
        begin
          return JSON.parse(File.read(project_validation_path), symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      end
    end

    Fu.where(project_id: project.id).find_each do |fu|
      validation_path = File.join(fu.upload_dir.to_s, 'cxg_validation_result.json')
      next unless File.exist?(validation_path)

      begin
        return JSON.parse(File.read(validation_path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
    end

    nil
  end

  # Find the primary loom file for validation (parsing/output.loom)
  def find_project_loom_path(project)
    return nil unless project.respond_to?(:key) && project.respond_to?(:user_id)
    return nil unless project.key.present? && project.user_id.present?

    user_data_dir = ENV.fetch('USER_DATA_DIR', '/data/asap2/projects')

    parsing_output = File.join(user_data_dir, project.user_id.to_s, project.key, 'parsing', 'output.loom')
    return parsing_output if File.exist?(parsing_output)

    project_dir = File.join(user_data_dir, project.user_id.to_s, project.key)
    if File.directory?(project_dir)
      loom_files = Dir.glob(File.join(project_dir, '**', '*.loom'))
      return loom_files.first if loom_files.any?
    end

    nil
  end

  # Read unique values (and optional co-occurrence pairs) from a LOOM file.
  # Returns { field_path => [unique_values], "tp||lp" => [[term, label], ...] }
  def batch_read_field_values(loom_path, field_paths, paired_paths: [])
    return {} if field_paths.blank? || loom_path.blank?

    container = ENV.fetch('ASAP_RUN_CONTAINER')
    fields_json = field_paths.to_json
    pairs_json = paired_paths.to_json

    script = <<~PY
      import h5py, sys, json

      def decode(v):
          return v.decode() if hasattr(v, 'decode') else str(v)

      f = h5py.File(sys.argv[1], 'r')
      fields = json.loads(sys.argv[2])
      pairs = json.loads(sys.argv[3])
      result = {}

      for fp in fields:
          parts = fp.lstrip('/').split('/')
          try:
              ds = f
              for p in parts:
                  ds = ds[p]
              vals = ds[:]
              unique = sorted(set(decode(v) for v in vals))
              result[fp] = unique
          except Exception:
              result[fp] = []

      for term_fp, label_fp in pairs:
          tp = term_fp.lstrip('/').split('/')
          lp = label_fp.lstrip('/').split('/')
          try:
              tds = f
              for p in tp:
                  tds = tds[p]
              lds = f
              for p in lp:
                  lds = lds[p]
              tvals = tds[:]
              lvals = lds[:]
              seen = set()
              ordered_pairs = []
              for tv, lv in zip(tvals, lvals):
                  tv_s = decode(tv)
                  lv_s = decode(lv)
                  key = (tv_s, lv_s)
                  if key not in seen:
                      seen.add(key)
                      ordered_pairs.append([tv_s, lv_s])
              ordered_pairs.sort(key=lambda x: x[1])
              result[term_fp + '||' + label_fp] = ordered_pairs
          except Exception:
              pass

      f.close()
      print(json.dumps(result))
    PY

    stdout, _stderr, status = Open3.capture3(
      'docker', 'exec', container, 'python3', '-c', script, loom_path, fields_json, pairs_json
    )
    return {} unless status.success?

    JSON.parse(stdout) rescue {}
  end

  # Resolve field values against the ontology database.
  # Returns a hash of { path => { value => true/false } } where true means
  # the value is a valid ontology term (or allowed free-text value).
  def resolve_field_values(groups, raw_values)
    group_defs = Array(groups).map { |g| g.is_a?(Hash) && g[:group] ? g[:group] : g }
    Scfair::OntologyValueResolver.call(
      groups: group_defs,
      field_values: raw_values,
      format: 'loom'
    )
  end
end
