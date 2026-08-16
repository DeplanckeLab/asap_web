# frozen_string_literal: true

require 'open3'
require 'json'
require 'timeout'

class ScfairLoomFileValidatorService
  Result = Struct.new(:valid?, :errors, :warnings, :info, :valid_checks, :schema_version, :validated_at, :field_values, keyword_init: true)

  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER').freeze

  LOOM_FIELD_VALUE_PATHS = Scfair::Rules.compliance_field_value_paths('loom').freeze

  FIELD_VALUES_PY_TEMPLATE = <<~'PYTHON'
    import json
    import sys
    import h5py
    import numpy as np

    loom_path = sys.argv[1]
    fields = %<fields>s
    label_pairs = %<label_pairs>s

    def decode_obs_value(value):
      if value is None:
        return None
      if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
      return str(value)

    def read_col_series(col_group, key):
      if key not in col_group:
        return []
      ds = col_group[key]
      if not isinstance(ds, h5py.Dataset):
        return []
      raw = ds[()]
      if isinstance(raw, np.ndarray):
        items = raw.tolist()
      elif isinstance(raw, (list, tuple)):
        items = list(raw)
      else:
        items = [raw]
      return [decode_obs_value(v) for v in items]

    def capture_dataset(path, ds, out):
      if len(ds.shape) == 0:
        val = ds[()]
        if isinstance(val, bytes):
          val = val.decode("utf-8", "replace")
        out[path] = [str(val)]
        return

      if len(ds.shape) >= 2:
        out[path] = ["__array__"]
        out[f"{path}#shape"] = [",".join(str(int(s)) for s in ds.shape)]
        out[f"{path}#dtype"] = [str(ds.dtype)]
        if len(ds.shape) == 2 and np.issubdtype(ds.dtype, np.floating):
          arr = ds[()]
          out[f"{path}#has_inf"] = [str(bool(np.isinf(arr).any())).lower()]
          out[f"{path}#has_nan"] = [str(bool(np.isnan(arr).any())).lower()]
        return

      raw = ds[()]
      try:
        itr = raw.tolist()
      except Exception:
        itr = [raw]
      if not isinstance(itr, list):
        itr = [itr]
      vals = []
      for v in itr:
        if isinstance(v, bytes):
          vals.append(v.decode("utf-8", "replace"))
        else:
          vals.append(str(v))
      vals = [v for v in vals if v and v != "None"]
      if vals:
        out[path] = sorted(list(set(vals)))[:200]

    def capture_series(path, ds, out):
      if len(ds.shape) == 0:
        val = ds[()]
        if isinstance(val, bytes):
          val = val.decode("utf-8", "replace")
        out[f"{path}#series"] = [str(val)]
        out[path] = [str(val)]
        return

      raw = ds[()]
      try:
        itr = raw.tolist()
      except Exception:
        itr = [raw]
      if not isinstance(itr, list):
        itr = [itr]
      vals = []
      for v in itr:
        if isinstance(v, bytes):
          vals.append(v.decode("utf-8", "replace"))
        else:
          vals.append(str(v))
      vals = [v for v in vals if v and v != "None"]
      if not vals:
        return
      out[f"{path}#series"] = vals[:500]
      out[path] = sorted(list(set(vals)))[:200]

    out = {}
    with h5py.File(loom_path, "r") as f:
      paths = set(fields)
      paths.update(path for path in f.keys() if path.startswith("/attrs/spatial/"))
      paths.update(path for path in f.keys() if path.startswith("/attrs/genetic_perturbations/"))
      paths.update(path for path in f.keys() if path == "/col_attrs/spatial")
      for path in sorted(paths):
        if path not in f:
          continue
        capture_dataset(path, f[path], out)
      if "/matrix" in f:
        sh = f["/matrix"].shape
        if len(sh) >= 2:
          out["matrix/n_obs"] = [str(int(sh[1]))]
      for layer, group_name in [("obs", "col_attrs"), ("var", "row_attrs"), ("uns", "attrs")]:
        if group_name in f and isinstance(f[group_name], h5py.Group):
          out[f"metadata/{layer}/columns"] = sorted(f[group_name].keys())

      var_series_fields = %<var_series_fields>s
      if "row_attrs" in f and isinstance(f["row_attrs"], h5py.Group):
        row_attrs = f["row_attrs"]
        for field in var_series_fields:
          if field not in row_attrs:
            continue
          ds = row_attrs[field]
          if not isinstance(ds, h5py.Dataset) or len(ds.shape) != 1:
            continue
          raw = ds[()]
          try:
            itr = raw.tolist()
          except Exception:
            itr = [raw]
          if not isinstance(itr, list):
            itr = [itr]
          vals = []
          for v in itr[:500]:
            if isinstance(v, bytes):
              vals.append(v.decode("utf-8", "replace"))
            else:
              vals.append(str(v))
          if vals:
            out[f"/row_attrs/{field}#series"] = vals
        var_index_keys = %<var_index_keys>s
        if "/attrs/anndata_mapping" in f:
          try:
            raw = f["/attrs/anndata_mapping"][()]
            if isinstance(raw, bytes):
              raw = raw.decode("utf-8", "replace")
            mapping = json.loads(raw) if isinstance(raw, str) else {}
            if isinstance(mapping, dict):
              manifest_key = mapping.get("var_index_key")
              if manifest_key and manifest_key not in var_index_keys:
                var_index_keys.append(str(manifest_key))
              if manifest_key:
                out["/attrs/anndata_mapping#var_index_key"] = [str(manifest_key)]
          except Exception:
            pass
        for index_key in var_index_keys:
          if index_key not in row_attrs:
            continue
          ds = row_attrs[index_key]
          if not isinstance(ds, h5py.Dataset) or len(ds.shape) != 1:
            continue
          raw = ds[()]
          try:
            itr = raw.tolist()
          except Exception:
            itr = [raw]
          if not isinstance(itr, list):
            itr = [itr]
          vals = []
          for v in itr:
            if isinstance(v, bytes):
              vals.append(v.decode("utf-8", "replace"))
            else:
              vals.append(str(v))
          vals = [v for v in vals if v and v != "None"]
          if vals:
            out[f"/row_attrs/{index_key}#series"] = vals
            out[f"/row_attrs/{index_key}"] = sorted(list(set(vals)))[:200]
            break
      if "col_attrs" in f and isinstance(f["col_attrs"], h5py.Group):
        col = f["col_attrs"]
        col_keys = set(col.keys())
        for id_field, label_field in label_pairs.items():
          if id_field == "organism_ontology_term_id":
            continue
          if id_field not in col_keys or label_field not in col_keys:
            continue
          ids = read_col_series(col, id_field)
          labels = read_col_series(col, label_field)
          if not ids or len(ids) != len(labels):
            continue
          pairs = []
          seen = set()
          for id_val, label_val in zip(ids, labels):
            if not id_val or not label_val:
              continue
            token = f"{id_val} || {label_val}"
            if token in seen:
              continue
            seen.add(token)
            pairs.append(token)
          if pairs:
            out[f"/col_attrs/{id_field}#label_pairs"] = pairs[:200]
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
      warnings << { field: '/attrs/anndata_mapping', message: 'Missing anndata_mapping manifest (ASAP writes /attrs/anndata_mapping from Annots before validation, download, and H5AD export)' }
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
    py = format(
      FIELD_VALUES_PY_TEMPLATE,
      fields: LOOM_FIELD_VALUE_PATHS.to_json,
      var_series_fields: Scfair::Rules.required_var_fields.to_json,
      var_index_keys: Scfair::Rules.var_index_column_keys('loom').to_json,
      label_pairs: Scfair::Rules.label_pairs.to_json
    )
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
