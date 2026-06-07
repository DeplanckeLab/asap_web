# frozen_string_literal: true

require 'open3'
require 'json'
require 'base64'

class ScfairH5adValidatorService
  class StreamingError < StandardError; end

  Result = Struct.new(:valid?, :errors, :warnings, :info, :valid_checks, :schema_version, :validated_at, :field_values, keyword_init: true)

  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER').freeze
  PROGRESS_PREFIX = 'PROGRESS'
  RESULT_PREFIX = 'RESULT'

  PYTHON_SCRIPT_TEMPLATE = <<~PYTHON
    import base64
    import json
    import re
    import sys
    import numpy as np
    import h5py
    import anndata as ad

    file_path = sys.argv[1]
    PROGRESS_PREFIX = "#{PROGRESS_PREFIX}"
    RESULT_PREFIX = "#{RESULT_PREFIX}"

    RULES = json.loads(base64.b64decode("__RULES_B64__").decode("utf-8"))
    REQUIRED_OBS = RULES["required_obs"]
    REQUIRED_UNS = RULES["required_uns"]
    ONTOLOGY_FIELDS = RULES["ontology_fields"]
    SPECIAL_VALUES = {k: set(v) for k, v in RULES["special_values"].items()}
    ENUM_FIELDS = RULES.get("enum_fields", {})
    SPATIAL_OBS_FIELDS = ["array_row", "array_col", "in_tissue"]
    PERTURB_OBS_FIELDS = ["genetic_perturbation_id", "genetic_perturbation_strategy"]

    TOTAL_STEPS = 8 + len(REQUIRED_OBS) + len(REQUIRED_UNS) + len(ONTOLOGY_FIELDS)

    errors = []
    warnings = []
    info = []
    valid_checks = []
    field_values = {}
    step = 0

    def emit_progress(stage, message):
      global step
      step += 1
      payload = {
        "stage": stage,
        "message": message,
        "current": step,
        "total": TOTAL_STEPS,
        "progress": int(round(100.0 * step / TOTAL_STEPS))
      }
      print(PROGRESS_PREFIX + "\\t" + json.dumps(payload), flush=True)

    def decode_attr(value):
      if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
      if isinstance(value, np.ndarray):
        return [decode_attr(v) for v in value.tolist()]
      return value

    def obs_dataset_keys(obs_group):
      skip = {"_index", "index", "__categories"}
      return {
        k for k in obs_group.keys()
        if k not in skip and not k.startswith("_")
      }

    def metadata_column_keys(group):
      skip = {"_index", "index", "__categories"}
      return sorted(k for k in group.keys() if k not in skip)

    def store_metadata_columns(layer, names):
      if names:
        field_values[f"metadata/{layer}/columns"] = sorted(names)

    def obs_declared_columns(obs_group):
      co = obs_group.attrs.get("column-order")
      if co is None:
        return set()
      if isinstance(co, np.ndarray):
        co = co.tolist()
      return {decode_attr(v) for v in co}

    def read_obs_column_values(obs_group, key):
      if key not in obs_group:
        return []
      node = obs_group[key]
      if isinstance(node, h5py.Dataset):
        raw = node[()]
      elif isinstance(node, h5py.Group):
        enc = decode_attr(node.attrs.get("encoding-type", ""))
        if enc == "categorical" and "categories" in node:
          codes = node["codes"][()]
          cats = node["categories"][()]
          raw = [cats[i] if 0 <= i < len(cats) else None for i in codes]
        else:
          return []
      else:
        return []
      if isinstance(raw, np.ndarray):
        items = raw.tolist()
      elif isinstance(raw, (list, tuple)):
        items = list(raw)
      else:
        items = [raw]
      out = []
      for v in items:
        if v is None:
          continue
        if isinstance(v, bytes):
          v = v.decode("utf-8", "replace")
        out.append(str(v))
      return sorted(set(out))

    def read_uns_value(uns_group, key):
      if key not in uns_group:
        return []
      node = uns_group[key]
      if isinstance(node, h5py.Dataset):
        val = node[()]
        if isinstance(val, bytes):
          val = val.decode("utf-8", "replace")
        return [str(val)]
      return []

    def store_array_metadata(path, shape, dtype, has_inf=None, has_nan=None):
      field_values[path] = ["__array__"]
      field_values[f"{path}#shape"] = [",".join(str(int(s)) for s in shape)]
      field_values[f"{path}#dtype"] = [str(dtype)]
      if has_inf is not None:
        field_values[f"{path}#has_inf"] = [str(bool(has_inf)).lower()]
      if has_nan is not None:
        field_values[f"{path}#has_nan"] = [str(bool(has_nan)).lower()]

    def store_obsm_spatial_metadata(arr):
      arr = np.asarray(arr)
      store_array_metadata(
        "obsm/spatial",
        arr.shape,
        arr.dtype,
        np.isinf(arr).any(),
        np.isnan(arr).any()
      )

    def flatten_spatial_h5py(group, prefix):
      for key in group.keys():
        path = f"{prefix}/{key}"
        node = group[key]
        if isinstance(node, h5py.Group):
          flatten_spatial_h5py(node, path)
        elif isinstance(node, h5py.Dataset):
          if len(node.shape) >= 3:
            store_array_metadata(path, node.shape, node.dtype)
          elif len(node.shape) == 0:
            val = node[()]
            if isinstance(val, bytes):
              val = val.decode("utf-8", "replace")
            field_values[path] = [str(val)]
          else:
            field_values[path] = ["__array__"]

    def flatten_spatial_dict(value, prefix):
      if not isinstance(value, dict):
        return
      for key, val in value.items():
        path = f"{prefix}/{key}"
        if isinstance(val, dict):
          flatten_spatial_dict(val, path)
        elif isinstance(val, np.ndarray):
          if val.ndim >= 3:
            store_array_metadata(path, val.shape, val.dtype)
          else:
            field_values[path] = ["__array__"]
        else:
          field_values[path] = [str(val)]

    def flatten_perturb_h5py(group, prefix):
      for key in group.keys():
        path = f"{prefix}/{key}"
        node = group[key]
        if isinstance(node, h5py.Group):
          flatten_perturb_h5py(node, path)
        elif isinstance(node, h5py.Dataset):
          if len(node.shape) == 0:
            val = node[()]
            if isinstance(val, bytes):
              val = val.decode("utf-8", "replace")
            field_values[path] = [str(val)]
          else:
            raw = node[()]
            if isinstance(raw, np.ndarray):
              items = raw.tolist()
            elif isinstance(raw, (list, tuple)):
              items = list(raw)
            else:
              items = [raw]
            vals = []
            for v in items:
              if v is None:
                continue
              if isinstance(v, bytes):
                v = v.decode("utf-8", "replace")
              vals.append(str(v))
            if vals:
              field_values[path] = sorted(set(vals))[:200]

    def flatten_perturb_dict(value, prefix):
      if not isinstance(value, dict):
        return
      for key, val in value.items():
        path = f"{prefix}/{key}"
        if isinstance(val, dict):
          flatten_perturb_dict(val, path)
        elif isinstance(val, (list, tuple, np.ndarray)):
          items = list(val) if not isinstance(val, np.ndarray) else val.tolist()
          field_values[path] = [str(v) for v in items][:200]
        else:
          field_values[path] = [str(val)]

    def extract_perturb_from_uns_h5py(uns_group):
      if uns_group is None or "genetic_perturbations" not in uns_group:
        return
      node = uns_group["genetic_perturbations"]
      if isinstance(node, h5py.Group):
        flatten_perturb_h5py(node, "uns/genetic_perturbations")
      elif isinstance(node, h5py.Dataset):
        vals = read_uns_value(uns_group, "genetic_perturbations")
        if vals:
          field_values["uns/genetic_perturbations"] = vals[:200]

    def extract_perturb_obs_h5py(obs_group, obs_present):
      if obs_group is None:
        return
      for field in PERTURB_OBS_FIELDS:
        if field not in obs_present:
          continue
        vals = read_obs_column_values(obs_group, field)
        if vals:
          field_values[f"obs/{field}"] = vals[:200]

    def extract_perturb_from_adata(adata):
      perturb = adata.uns.get("genetic_perturbations")
      if isinstance(perturb, dict):
        flatten_perturb_dict(perturb, "uns/genetic_perturbations")
      elif perturb is not None:
        field_values["uns/genetic_perturbations"] = [str(perturb)]
      for field in PERTURB_OBS_FIELDS:
        if field in adata.obs.columns:
          values = [str(v) for v in adata.obs[field].dropna().astype(str).unique().tolist()]
          if values:
            field_values[f"obs/{field}"] = values[:200]

    def extract_spatial_from_uns_h5py(uns_group):
      if uns_group is None or "spatial" not in uns_group:
        return
      spatial = uns_group["spatial"]
      if isinstance(spatial, h5py.Group):
        flatten_spatial_h5py(spatial, "uns/spatial")

    def extract_spatial_obs_h5py(obs_group, obs_present):
      if obs_group is None:
        return
      for field in SPATIAL_OBS_FIELDS:
        if field not in obs_present:
          continue
        vals = read_obs_column_values(obs_group, field)
        if vals:
          field_values[f"obs/{field}"] = vals[:200]

    def extract_spatial_from_adata(adata):
      spatial = adata.uns.get("spatial")
      if isinstance(spatial, dict):
        flatten_spatial_dict(spatial, "uns/spatial")
      for field in SPATIAL_OBS_FIELDS:
        if field in adata.obs.columns:
          values = [str(v) for v in adata.obs[field].dropna().astype(str).unique().tolist()]
          if values:
            field_values[f"obs/{field}"] = values[:200]

    def matrix_shape_h5py(root):
      if "X" not in root:
        return None, None
      x = root["X"]
      if isinstance(x, h5py.Dataset):
        sh = tuple(int(s) for s in x.shape)
        return sh[0], sh[1] if len(sh) >= 2 else None
      if isinstance(x, h5py.Group):
        sh = x.attrs.get("shape")
        if sh is not None:
          sh = tuple(int(s) for s in sh)
          return sh[0], sh[1] if len(sh) >= 2 else None
      return None, None

    def obsm_keys_h5py(root):
      if "obsm" not in root or not isinstance(root["obsm"], h5py.Group):
        return []
      return list(root["obsm"].keys())

    def obsm_array_h5py(obsm_group, key):
      node = obsm_group[key]
      if isinstance(node, h5py.Dataset):
        return np.asarray(node[()])
      if isinstance(node, h5py.Group):
        enc = decode_attr(node.attrs.get("encoding-type", ""))
        if enc in ("array", "dense_array") and "data" in node:
          return np.asarray(node["data"][()])
      return None

    def check_ontology_values(field_path, values):
      prefixes = ONTOLOGY_FIELDS[field_path]
      specials = SPECIAL_VALUES.get(field_path, set())
      field_values[field_path] = values
      issues = 0
      for value in values:
        for term in [t.strip() for t in value.split(" || ")]:
          if term in specials:
            continue
          if term.startswith("CVCL_"):
            if "CVCL" not in prefixes:
              errors.append({
                "field": field_path,
                "message": f"Invalid ontology format: {term}. Cellosaurus CVCL_* terms are not allowed for this field."
              })
              issues += 1
            continue
          if not re.match(r"^[A-Za-z]+:\\d+$", term):
            errors.append({"field": field_path, "message": f"Invalid ontology format: {term}"})
            issues += 1
            continue
          prefix = term.split(":")[0]
          if prefix not in prefixes:
            warnings.append({"field": field_path, "message": f"Unexpected ontology prefix '{prefix}' for {field_path}"})
            issues += 1
      if issues == 0:
        field_name = field_path.split("/")[-1]
        valid_checks.append({"field": field_path, "message": f"Ontology terms in '{field_name}' have valid format"})

    def check_enum_values(field_path, values):
      allowed = ENUM_FIELDS.get(field_path)
      if not allowed:
        return
      valid = {v.lower() for v in allowed}
      invalid = [v for v in values if v.lower() not in valid]
      if invalid:
        errors.append({
          "field": field_path,
          "message": f"Invalid value(s): {', '.join(invalid[:5])}. Allowed: {', '.join(allowed)}"
        })

    def validate_from_h5py(root):
      emit_progress("matrix", "Checking matrix dimensions")
      n_obs, n_vars = matrix_shape_h5py(root)
      if not n_obs or not n_vars or n_obs <= 0 or n_vars <= 0:
        errors.append({"field": "X", "message": "AnnData has invalid or unreadable matrix shape"})
      else:
        field_values["matrix/n_obs"] = [str(n_obs)]
        valid_checks.append({"field": "X", "message": f"Matrix shape OK ({n_obs} cells x {n_vars} genes)"})

      emit_progress("obs", "Checking observation metadata structure")
      obs_present = set()
      obs_group = None
      if "obs" in root and isinstance(root["obs"], h5py.Group):
        obs_group = root["obs"]
        obs_present = obs_dataset_keys(obs_group)
        declared = obs_declared_columns(obs_group)
        missing_declared = sorted(declared - obs_present)
        if missing_declared:
          sample = ", ".join(missing_declared[:8])
          suffix = f" (+{len(missing_declared) - 8} more)" if len(missing_declared) > 8 else ""
          errors.append({
            "field": "obs",
            "message": (
              f"obs column-order lists {len(missing_declared)} column(s) not stored in the file"
              f" (e.g. {sample}{suffix}); the H5AD obs table is inconsistent"
            )
          })
        extra = sorted(obs_present - declared) if declared else []
        if extra and declared:
          warnings.append({
            "field": "obs",
            "message": f"{len(extra)} obs column(s) stored but not listed in column-order (e.g. {', '.join(extra[:5])})"
          })
      else:
        errors.append({"field": "obs", "message": "Missing obs group"})

      if obs_group is not None:
        store_metadata_columns("obs", metadata_column_keys(obs_group))

      var_group = None
      if "var" in root and isinstance(root["var"], h5py.Group):
        var_group = root["var"]
        store_metadata_columns("var", metadata_column_keys(var_group))

      for field in REQUIRED_OBS:
        emit_progress("obs", f"Checking obs/{field}")
        if field in obs_present:
          valid_checks.append({"field": f"obs/{field}", "message": "Required field present"})
          if obs_group is not None:
            vals = read_obs_column_values(obs_group, field)
            if vals:
              field_path = f"obs/{field}"
              field_values[field_path] = vals[:200]
              check_enum_values(field_path, vals)
        else:
          errors.append({"field": f"obs/{field}", "message": "Missing required observation field"})

      uns_present = set()
      uns_group = None
      if "uns" in root and isinstance(root["uns"], h5py.Group):
        uns_group = root["uns"]
        uns_present = set(uns_group.keys())
        store_metadata_columns("uns", list(uns_present))

      for field in REQUIRED_UNS:
        emit_progress("uns", f"Checking uns/{field}")
        if field in uns_present:
          if field != "schema_version":
            valid_checks.append({"field": f"uns/{field}", "message": "Required field present"})
          if uns_group is not None:
            vals = read_uns_value(uns_group, field)
            if vals:
              field_values[f"uns/{field}"] = vals[:200]
        else:
          errors.append({"field": f"uns/{field}", "message": "Missing required dataset metadata field"})

      extract_spatial_from_uns_h5py(uns_group)
      extract_spatial_obs_h5py(obs_group, obs_present)
      extract_perturb_from_uns_h5py(uns_group)
      extract_perturb_obs_h5py(obs_group, obs_present)

      if obs_group is not None:
        for field_path in ONTOLOGY_FIELDS:
          if not field_path.startswith("obs/"):
            continue
          key = field_path.split("/", 1)[1]
          emit_progress("ontology", f"Checking {field_path} format")
          if key not in obs_present:
            continue
          values = read_obs_column_values(obs_group, key)
          if values:
            check_ontology_values(field_path, values)

      if uns_group is not None:
        for field_path in ONTOLOGY_FIELDS:
          if not field_path.startswith("uns/"):
            continue
          key = field_path.split("/", 1)[1]
          emit_progress("ontology", f"Checking {field_path} format")
          values = read_uns_value(uns_group, key)
          if values:
            check_ontology_values(field_path, values)

      emit_progress("obsm", "Checking embeddings (obsm)")
      obsm_key_list = []
      if "obsm" in root and isinstance(root["obsm"], h5py.Group):
        obsm_group = root["obsm"]
        obsm_key_list = obsm_keys_h5py(root)
        for key in obsm_key_list:
          arr = obsm_array_h5py(obsm_group, key)
          if arr is None:
            errors.append({"field": f"obsm/{key}", "message": "Could not read embedding array"})
            continue
          if key == "spatial":
            store_obsm_spatial_metadata(arr)
          if n_obs and arr.shape[0] != n_obs:
            errors.append({"field": f"obsm/{key}", "message": "Embedding row count does not match n_obs"})
          if arr.ndim != 2 or arr.shape[1] < 2:
            errors.append({"field": f"obsm/{key}", "message": "Embedding must be 2D with at least 2 columns"})
          if np.isinf(arr).any():
            errors.append({"field": f"obsm/{key}", "message": "Embedding contains infinity values"})
          if np.isnan(arr).all():
            errors.append({"field": f"obsm/{key}", "message": "Embedding contains only NaN values"})

      if len(obsm_key_list) == 0:
        warnings.append({"field": "obsm", "message": "No embeddings found"})
      else:
        valid_checks.append({"field": "obsm", "message": f"{len(obsm_key_list)} embedding(s) found"})

    def validate_from_adata(adata):
      emit_progress("matrix", "Checking matrix dimensions")
      if adata.n_obs <= 0 or adata.n_vars <= 0:
        errors.append({"field": "X", "message": "AnnData has invalid shape"})
      else:
        field_values["matrix/n_obs"] = [str(adata.n_obs)]
        valid_checks.append({"field": "X", "message": f"Matrix shape OK ({adata.n_obs} cells x {adata.n_vars} genes)"})

      store_metadata_columns("obs", list(adata.obs.columns))
      store_metadata_columns("var", list(adata.var.columns))
      store_metadata_columns("uns", list(adata.uns.keys()))

      emit_progress("obs", "Checking observation metadata columns")
      for field in REQUIRED_OBS:
        emit_progress("obs", f"Checking obs/{field}")
        if field in adata.obs.columns:
          valid_checks.append({"field": f"obs/{field}", "message": "Required field present"})
          values = [str(v) for v in adata.obs[field].dropna().astype(str).unique().tolist()]
          if values:
            field_path = f"obs/{field}"
            field_values[field_path] = values[:200]
            check_enum_values(field_path, values)
        else:
          errors.append({"field": f"obs/{field}", "message": "Missing required observation field"})

      for field in REQUIRED_UNS:
        emit_progress("uns", f"Checking uns/{field}")
        if field in adata.uns:
          valid_checks.append({"field": f"uns/{field}", "message": "Required field present"})
          field_values[f"uns/{field}"] = [str(adata.uns[field])][:200]
        else:
          errors.append({"field": f"uns/{field}", "message": "Missing required dataset metadata field"})

      extract_spatial_from_adata(adata)
      extract_perturb_from_adata(adata)

      for field_path in ONTOLOGY_FIELDS:
        space, key = field_path.split("/", 1)
        emit_progress("ontology", f"Checking {field_path} format")
        values = []
        if space == "obs" and key in adata.obs.columns:
          values = [str(v) for v in adata.obs[key].dropna().astype(str).unique().tolist()]
        elif space == "uns" and key in adata.uns:
          values = [str(adata.uns[key])]
        if values:
          check_ontology_values(field_path, values)

      emit_progress("obsm", "Checking embeddings (obsm)")
      for key in adata.obsm.keys():
        arr = np.asarray(adata.obsm[key])
        if key == "spatial":
          store_obsm_spatial_metadata(arr)
        if arr.shape[0] != adata.n_obs:
          errors.append({"field": f"obsm/{key}", "message": "Embedding row count does not match n_obs"})
        if arr.ndim != 2 or arr.shape[1] < 2:
          errors.append({"field": f"obsm/{key}", "message": "Embedding must be 2D with at least 2 columns"})
        if np.isinf(arr).any():
          errors.append({"field": f"obsm/{key}", "message": "Embedding contains infinity values"})
        if np.isnan(arr).all():
          errors.append({"field": f"obsm/{key}", "message": "Embedding contains only NaN values"})

      if len(adata.obsm.keys()) == 0:
        warnings.append({"field": "obsm", "message": "No embeddings found"})
      else:
        valid_checks.append({"field": "obsm", "message": f"{len(adata.obsm.keys())} embedding(s) found"})

    emit_progress("load", "Opening H5AD file")
    try:
      emit_progress("load", "Loading AnnData object")
      adata = ad.read_h5ad(file_path)
      validate_from_adata(adata)
    except Exception as exc:
      warnings.append({
        "field": "h5ad",
        "message": f"Could not load AnnData object ({type(exc).__name__}); running structural checks via HDF5"
      })
      emit_progress("load", "Using HDF5 fallback reader")
      with h5py.File(file_path, "r") as root:
        validate_from_h5py(root)

    payload = {
      "errors": errors,
      "warnings": warnings,
      "info": info,
      "valid_checks": valid_checks,
      "field_values": field_values
    }
    print(RESULT_PREFIX + "\\t" + json.dumps(payload), flush=True)
  PYTHON

  H5AD_PROGRESS_BASE = 15
  H5AD_PROGRESS_SPAN = 52

  def initialize(h5ad_path, logger: Rails.logger, progress_cb: nil)
    @h5ad_path = h5ad_path
    @logger = logger
    @progress_cb = progress_cb
  end

  def validate
    parsed = run_streaming_validation
    errors = parsed['errors'] || []
    warnings = parsed['warnings'] || []
    info = parsed['info'] || []
    valid_checks = parsed['valid_checks'] || []
    field_values = parsed['field_values'] || {}

    Result.new(
      valid?: errors.empty?,
      errors: errors,
      warnings: warnings,
      info: info,
      valid_checks: valid_checks,
      field_values: field_values,
      schema_version: Scfair::Rules.schema_version,
      validated_at: Time.current.iso8601
    )
  rescue StreamingError => e
    Result.new(
      valid?: false,
      errors: [{ field: 'h5ad', message: "H5AD validation failed: #{e.message}" }],
      warnings: [],
      info: [],
      valid_checks: [],
      field_values: {},
      schema_version: Scfair::Rules.schema_version,
      validated_at: Time.current.iso8601
    )
  rescue JSON::ParserError => e
    Result.new(
      valid?: false,
      errors: [{ field: 'h5ad', message: "Cannot parse H5AD validation output: #{e.message}" }],
      warnings: [],
      info: [],
      valid_checks: [],
      field_values: {},
      schema_version: Scfair::Rules.schema_version,
      validated_at: Time.current.iso8601
    )
  end

  private

  def run_streaming_validation
    cmd = ['docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-u', '-', @h5ad_path]
    result_payload = nil
    stderr_text = +''

    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      stdin.write(python_script)
      stdin.close

      stdout.each_line do |line|
        line = line.rstrip
        next if line.empty?

        if line.start_with?("#{PROGRESS_PREFIX}\t")
          handle_progress_line(line.delete_prefix("#{PROGRESS_PREFIX}\t"))
        elsif line.start_with?("#{RESULT_PREFIX}\t")
          result_payload = line.delete_prefix("#{RESULT_PREFIX}\t")
        else
          @logger.warn("[ScfairH5adValidatorService] Unexpected stdout: #{line[0, 200]}")
        end
      end

      stderr_text = stderr.read.to_s
      status = wait_thr.value
      raise StreamingError, stderr_text.strip.presence || 'Python validator exited with failure' unless status.success?
    end

    raise StreamingError, 'No RESULT line received from H5AD validator' if result_payload.blank?

    JSON.parse(result_payload)
  end

  def handle_progress_line(json_str)
    payload = JSON.parse(json_str)
    inner_progress = payload['progress']
    if inner_progress.nil? && payload['current'] && payload['total'].to_i.positive?
      inner_progress = ((payload['current'].to_f / payload['total']) * 100).round
    end
    inner_progress ||= 0

    global_progress = H5AD_PROGRESS_BASE + ((inner_progress * H5AD_PROGRESS_SPAN) / 100.0).round
    message = payload['message'].presence || 'Running H5AD checks'
    if payload['current'] && payload['total']
      message = "#{message} (#{payload['current']}/#{payload['total']})"
    end

    return unless @progress_cb

    @progress_cb.call(
      stage: payload['stage'] || 'h5ad',
      message: message,
      progress: global_progress,
      current: payload['current'],
      total: payload['total']
    )
  rescue JSON::ParserError => e
    @logger.warn("[ScfairH5adValidatorService] Invalid progress payload: #{e.message}")
  end

  def python_script
    @python_script ||= begin
      rules_b64 = Base64.strict_encode64(Scfair::Rules.h5ad_validator_config.to_json)
      PYTHON_SCRIPT_TEMPLATE.gsub('__RULES_B64__', rules_b64)
    end
  end
end
