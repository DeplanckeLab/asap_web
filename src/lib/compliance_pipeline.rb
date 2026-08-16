# frozen_string_literal: true

# Feature toggle and shared entry points for project compliance validation.
module CompliancePipeline
  DEFAULT_SCHEMA_ID = 'scfair_7_1_0'

  # Normalized wrapper around ScfairComplianceService (file-check) result hash.
  Result = Struct.new(
    :valid?, :errors, :warnings, :info, :valid_checks,
    :schema_version, :validated_at, :field_values,
    :check_groups, :format, :schema_id,
    keyword_init: true
  )

  module_function

  def use_extract_pipeline?
    ENV.fetch('COMPLIANCE_USE_EXTRACT_PIPELINE', 'true') == 'true'
  end

  # Project compliance report uses the same validator as file-check.
  # Refreshes /attrs/analysis_pipeline and /attrs/anndata_mapping from DB/Annots
  # before validating so the report matches attrs written before loom/h5ad download.
  def validate_project_loom(loom_path, project = nil, logger: Rails.logger, schema_id: nil, &progress_cb)
    ensure_loom_attrs_before_project_validation!(loom_path, project, logger)
    validate_loom_file_check(
      loom_path,
      logger: logger,
      schema_id: schema_id || DEFAULT_SCHEMA_ID,
      project_compliance: true,
      remote_db: asap_data_db_name_for_project(project),
      &progress_cb
    )
  end

  # Kept for callers/tests that still use the old name.
  def ensure_anndata_mapping_before_project_validation!(loom_path, project, logger)
    ensure_loom_attrs_before_project_validation!(loom_path, project, logger)
  end

  def ensure_loom_attrs_before_project_validation!(loom_path, project, logger)
    return if project.nil? || loom_path.blank?

    loom_rel = loom_rel_under_project(project, loom_path)
    if loom_rel.blank?
      logger&.info(
        "[CompliancePipeline] skip analysis_pipeline/anndata_mapping refresh: loom not under project dir " \
        "project=#{project.try(:key)} path=#{loom_path}"
      )
      return
    end

    result = AnalysisJsonPersistService.call(project: project, loom_filepath: loom_rel)
    logger&.info(
      "[CompliancePipeline] analysis_pipeline refreshed project=#{project.try(:key)} " \
      "loom=#{loom_rel} annot_id=#{result[:annot_id]} steps=#{result[:nber_steps]}"
    )
    Basic.refresh_anndata_mapping_for_loom(logger, project, loom_rel)
  end

  def loom_rel_under_project(project, loom_path)
    return nil unless project.respond_to?(:user_id) && project.respond_to?(:key)
    return nil if project.user_id.blank? || project.key.blank?

    project_dir = Basic.project_user_dir(project).expand_path
    abs = Pathname.new(loom_path.to_s).expand_path
    root_s = project_dir.to_s
    abs_s = abs.to_s
    return nil unless abs_s.start_with?(root_s + File::SEPARATOR) || abs_s == root_s

    abs.relative_path_from(project_dir).to_s
  rescue ArgumentError
    nil
  end

  def validate_loom_file(loom_path, project: nil, logger: Rails.logger, schema_id: nil, &progress_cb)
    if use_extract_pipeline?
      resolved = schema_id || DEFAULT_SCHEMA_ID
      validate_loom_file_check(
        loom_path,
        logger: logger,
        schema_id: resolved,
        remote_db: asap_data_db_name_for_project(project),
        &progress_cb
      )
    else
      ScfairLoomValidatorService.new(loom_path, project: project, logger: logger).validate
    end
  end

  def validate_loom_file_check(loom_path, logger: Rails.logger, schema_id: DEFAULT_SCHEMA_ID, project_compliance: false, remote_db: nil, &progress_cb)
    core = ScfairComplianceService.new(
      file_path: loom_path,
      schema_id: schema_id,
      logger: logger,
      project_compliance: project_compliance,
      remote_db: remote_db,
      &progress_cb
    ).validate
    wrap_file_check_result(core)
  rescue StandardError => e
    logger.error("[CompliancePipeline] Validation error: #{e.message}")
    logger.error(e.backtrace.join("\n")) if e.backtrace

    Result.new(
      valid?: false,
      errors: [{ field: 'validation', message: "Validation failed with error: #{e.message}" }],
      warnings: [],
      info: [],
      valid_checks: [],
      schema_version: Scfair::Rules.for(schema_id).schema_version,
      validated_at: Time.current.iso8601,
      field_values: {},
      check_groups: [],
      format: 'loom',
      schema_id: schema_id
    )
  end

  def wrap_file_check_result(core)
    hash = core.deep_symbolize_keys
    Result.new(
      valid?: hash[:valid] == true,
      errors: Array(hash[:errors]),
      warnings: Array(hash[:warnings]),
      info: Array(hash[:info]),
      valid_checks: Array(hash[:valid_checks]),
      schema_version: hash[:schema_version] || Scfair::Rules.for(hash[:schema_id]).schema_version,
      validated_at: hash[:validated_at] || Time.current.iso8601,
      field_values: hash[:field_values] || {},
      check_groups: Array(hash[:check_groups]),
      format: hash[:format] || 'loom',
      schema_id: hash[:schema_id] || DEFAULT_SCHEMA_ID
    )
  end

  def displayable_valid_checks(valid_checks)
    Array(valid_checks).reject do |check|
      status = (check[:status] || check['status']).to_s.strip.downcase
      status == 'failed' || status == 'warning'
    end
  end

  def asap_data_db_name_for_project(project)
    return nil unless project

    version = project.respond_to?(:version_for_catalog) ? project.version_for_catalog : project.try(:version)
    return nil unless version

    env = version.env_data
    env['asap_data_db_name'].presence ||
      (env['asap_data_db_version'].present? && "asap_data_v#{env['asap_data_db_version']}") ||
      nil
  end
end
