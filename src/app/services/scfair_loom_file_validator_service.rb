# frozen_string_literal: true

require 'open3'
require 'json'
require 'timeout'

class ScfairLoomFileValidatorService
  Result = Struct.new(:valid?, :errors, :warnings, :info, :valid_checks, :schema_version, :validated_at, :field_values, keyword_init: true)

  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER').freeze

  LOOM_FIELD_VALUE_PATHS = (
    Scfair::Rules.required_uns_fields('loom').map { |name| "/attrs/#{name}" } +
    %w[
      /col_attrs/assay_ontology_term_id
      /col_attrs/cell_type_ontology_term_id
      /col_attrs/development_stage_ontology_term_id
      /col_attrs/disease_ontology_term_id
      /col_attrs/sex_ontology_term_id
      /col_attrs/tissue_ontology_term_id
      /col_attrs/self_reported_ethnicity_ontology_term_id
    ]
  ).uniq.freeze

  FIELD_VALUES_PY_TEMPLATE = <<~'PYTHON'
    import json
    import sys
    import h5py

    loom_path = sys.argv[1]
    fields = %<fields>s

    out = {}
    with h5py.File(loom_path, "r") as f:
      for path in fields:
        if path not in f:
          continue
        ds = f[path]
        vals = []
        if len(ds.shape) == 0:
          vals = [str(ds[()])]
        else:
          raw = ds[()]
          try:
            itr = raw.tolist()
          except Exception:
            itr = [raw]
          if not isinstance(itr, list):
            itr = [itr]
          for v in itr:
            if isinstance(v, bytes):
              vals.append(v.decode("utf-8", "replace"))
            else:
              vals.append(str(v))
        vals = [v for v in vals if v and v != "None"]
        out[path] = sorted(list(set(vals)))[:200]
    print(json.dumps(out))
  PYTHON

  LOOM_PRECHECK_PY = <<~PYTHON
    import sys
    import h5py
    path = sys.argv[1]
    try:
      with h5py.File(path, "r") as f:
        ok = "/matrix" in f
      if not ok:
        print("missing_matrix")
        sys.exit(2)
      print("ok")
      sys.exit(0)
    except Exception as e:
      print(str(e))
      sys.exit(1)
  PYTHON

  def initialize(loom_path, logger: Rails.logger)
    @loom_path = loom_path
    @logger = logger
  end

  def validate
    pre = precheck
    return pre if pre

    base = Timeout.timeout(60) do
      ScfairLoomValidatorService.new(@loom_path, logger: @logger).validate
    end
    field_values = extract_field_values

    errors = base.errors.dup
    warnings = base.warnings.dup
    valid_checks = base.valid_checks.dup

    manifest_present = global_attr_exists?('anndata_mapping')
    if manifest_present
      valid_checks << { field: '/attrs/anndata_mapping', message: 'Found anndata_mapping manifest' }
    else
      warnings << { field: '/attrs/anndata_mapping', message: 'Missing anndata_mapping manifest (recommended for deterministic Loom->H5AD conversion)' }
    end

    Result.new(
      valid?: errors.empty?,
      errors: errors,
      warnings: warnings,
      info: base.info,
      valid_checks: valid_checks,
      field_values: normalize_paths_for_checker(field_values),
      schema_version: base.schema_version,
      validated_at: base.validated_at
    )
  rescue Timeout::Error
    Result.new(
      valid?: false,
      errors: [{ field: 'loom', message: 'Validation timed out while reading Loom file' }],
      warnings: [],
      info: [],
      valid_checks: [],
      field_values: {},
      schema_version: '7.1.0',
      validated_at: Time.current.iso8601
    )
  end

  private

  def precheck
    cmd = ['docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-', @loom_path]
    stdout, _stderr, status = Open3.capture3(*cmd, stdin_data: LOOM_PRECHECK_PY)
    return nil if status.success?

    msg = stdout.to_s.strip
    message = if msg == 'missing_matrix'
                'Loom file missing /matrix dataset'
              else
                "Invalid Loom file: #{msg.presence || 'cannot be opened'}"
              end
    Result.new(
      valid?: false,
      errors: [{ field: 'loom', message: message }],
      warnings: [],
      info: [],
      valid_checks: [],
      field_values: {},
      schema_version: '7.1.0',
      validated_at: Time.current.iso8601
    )
  rescue StandardError => e
    Result.new(
      valid?: false,
      errors: [{ field: 'loom', message: "Invalid Loom file: #{e.message}" }],
      warnings: [],
      info: [],
      valid_checks: [],
      field_values: {},
      schema_version: '7.1.0',
      validated_at: Time.current.iso8601
    )
  end

  def extract_field_values
    py = format(FIELD_VALUES_PY_TEMPLATE, fields: LOOM_FIELD_VALUE_PATHS.to_json)
    cmd = ['docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-', @loom_path]
    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: py)
    return {} unless status.success?
    JSON.parse(stdout)
  rescue JSON::ParserError => e
    @logger.warn("[ScfairLoomFileValidatorService] Could not parse field values: #{e.message}")
    {}
  rescue StandardError => e
    @logger.warn("[ScfairLoomFileValidatorService] Could not extract field values: #{e.message}")
    {}
  end

  def global_attr_exists?(key)
    cmd = ['docker', 'exec', ASAP_RUN_CONTAINER, 'java', '-jar', '/srv/ASAP.jar', '-T', 'ExtractGlobalAttr', '-attr', key, '-loom', @loom_path]
    _stdout, _stderr, status = Open3.capture3(*cmd)
    status.success?
  end

  def normalize_paths_for_checker(field_values)
    field_values.transform_keys do |k|
      k.sub(%r{\A/col_attrs/}, '/col_attrs/')
       .sub(%r{\A/attrs/}, '/attrs/')
    end
  end
end

