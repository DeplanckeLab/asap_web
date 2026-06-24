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
  def validate_project_loom(loom_path, _project = nil, logger: Rails.logger, schema_id: nil)
    validate_loom_file_check(
      loom_path,
      logger: logger,
      schema_id: schema_id || DEFAULT_SCHEMA_ID
    )
  end

  def validate_loom_file(loom_path, project: nil, logger: Rails.logger, schema_id: nil)
    if use_extract_pipeline?
      resolved = schema_id || DEFAULT_SCHEMA_ID
      validate_loom_file_check(loom_path, logger: logger, schema_id: resolved)
    else
      ScfairLoomValidatorService.new(loom_path, project: project, logger: logger).validate
    end
  end

  def validate_loom_file_check(loom_path, logger: Rails.logger, schema_id: DEFAULT_SCHEMA_ID)
    core = ScfairComplianceService.new(
      file_path: loom_path,
      schema_id: schema_id,
      logger: logger
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
end
