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
  TIMING_PREFIX = 'TIMING'

  PYTHON_SCRIPT_TEMPLATE = <<~PYTHON
    import base64
    import json
    import re
    import sys
    import time
    import numpy as np
    import h5py

    file_path = sys.argv[1]
    PROGRESS_PREFIX = "#{PROGRESS_PREFIX}"
    RESULT_PREFIX = "#{RESULT_PREFIX}"
    TIMING_PREFIX = "#{TIMING_PREFIX}"
    script_start = time.perf_counter()
    timing_entries = []

    RULES = json.loads(base64.b64decode("__RULES_B64__").decode("utf-8"))
    REQUIRED_OBS = RULES["required_obs"]
    REQUIRED_UNS = RULES["required_uns"]
    ONTOLOGY_FIELDS = RULES["ontology_fields"]
    ONTOLOGY_TERM_FORMATS = RULES.get("ontology_term_formats", {})
    ONTOLOGY_FORMAT_EXAMPLES = RULES.get("ontology_format_examples", {})
    DEFAULT_OBO_EXAMPLE = ONTOLOGY_TERM_FORMATS.get("obo_example", "CL:0000540")
    OBO_ONTOLOGY_PATTERN = re.compile(ONTOLOGY_TERM_FORMATS.get("obo_pattern", r"^[A-Za-z]+:\\d+$"))
    CELLOSAURUS_PREFIX = ONTOLOGY_TERM_FORMATS.get("cellosaurus_prefix", "CVCL_")
    SPECIAL_VALUES = {k: set(v) for k, v in RULES["special_values"].items()}
    ENUM_FIELDS = RULES.get("enum_fields", {})
    LABEL_PAIRS = RULES.get("label_pairs", {})
    OPTIONAL_UNS = RULES.get("optional_uns", [])
    SPATIAL_OBS_FIELDS = ["array_row", "array_col", "in_tissue"]
    PERTURB_OBS_FIELDS = ["genetic_perturbation_id", "genetic_perturbation_strategy"]
    EXPERIMENTAL_OBS_FIELDS = RULES.get("experimental_obs", [])
    REQUIRED_VAR = RULES.get("required_var", [])

    CHECK_MESSAGES = RULES.get("check_messages", {})
    ONTOLOGY_FORMAT_CHECK_ID = "ontology.format"

    TOTAL_STEPS = 8 + len(REQUIRED_OBS) + len(REQUIRED_UNS) + len(ONTOLOGY_FIELDS)

    errors = []
    warnings = []
    info = []
    valid_checks = []
    field_values = {}
    step = 0

    def emit_timing(label, started_at, detail=None):
      elapsed_ms = round((time.perf_counter() - started_at) * 1000.0, 2)
      payload = {"label": label, "duration_ms": elapsed_ms}
      if detail:
        payload["detail"] = detail
      timing_entries.append(payload)
      print(TIMING_PREFIX + "\\t" + json.dumps(payload), flush=True)
      return elapsed_ms

    class Timer:
      def __init__(self, label, detail=None):
        self.label = label
        self.detail = detail
        self.started_at = None

      def __enter__(self):
        self.started_at = time.perf_counter()
        return self

      def __exit__(self, exc_type, exc, tb):
        emit_timing(self.label, self.started_at, self.detail)
        return False

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
      # Only AnnData structural keys are excluded. Single leading "_" (e.g. _Depth)
      # is a valid column name; scFAIR forbids only the "__" prefix.
      skip = {"_index", "index", "__categories"}
      return {k for k in obs_group.keys() if k not in skip}

    def metadata_column_keys(group):
      skip = {"_index", "index", "__categories"}
      return sorted(k for k in group.keys() if k not in skip)

    def store_metadata_columns(layer, names):
      if names:
        field_values[f"metadata/{layer}/columns"] = sorted(names)

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

    def decode_obs_value(value):
      if value is None:
        return None
      if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
      return str(value)

    STRING_ARRAY_ENCODINGS = ("string-array", "ascii", "string", "nullable-string-array")

    def read_h5py_raw_items(node):
      if isinstance(node, h5py.Dataset):
        raw = node[()]
      elif isinstance(node, h5py.Group):
        enc = decode_attr(node.attrs.get("encoding-type", ""))
        if enc in STRING_ARRAY_ENCODINGS and "values" in node:
          return read_h5py_raw_items(node["values"])
        return None
      else:
        return None
      if isinstance(raw, np.ndarray):
        return raw.tolist()
      if isinstance(raw, (list, tuple)):
        return list(raw)
      return [raw]

    def read_h5py_encoded_string_series(node, encoding):
      if "values" not in node:
        return []
      items = read_h5py_raw_items(node["values"])
      if items is None:
        return []
      if encoding == "nullable-string-array" and "mask" in node:
        mask = node["mask"][()]
        mask_list = mask.tolist() if isinstance(mask, np.ndarray) else list(mask)
        out = []
        for idx, item in enumerate(items):
          if idx < len(mask_list) and mask_list[idx]:
            out.append(None)
            continue
          out.append(decode_obs_value(item))
        return out
      return [decode_obs_value(v) for v in items]

    def read_h5py_category_values(categories_node):
      if isinstance(categories_node, h5py.Dataset):
        raw = categories_node[()]
        if isinstance(raw, np.ndarray):
          items = raw.tolist()
        elif isinstance(raw, (list, tuple)):
          items = list(raw)
        else:
          items = [raw]
        return [decode_obs_value(v) for v in items]

      if isinstance(categories_node, h5py.Group):
        enc = decode_attr(categories_node.attrs.get("encoding-type", ""))
        if enc in STRING_ARRAY_ENCODINGS and "values" in categories_node:
          return read_h5py_encoded_string_series(categories_node, enc)
      return []

    def read_obs_column_series(obs_group, key):
      if key not in obs_group:
        return []
      node = obs_group[key]
      if isinstance(node, h5py.Dataset):
        raw = node[()]
      elif isinstance(node, h5py.Group):
        enc = decode_attr(node.attrs.get("encoding-type", ""))
        if enc == "categorical" and "codes" in node and "categories" in node:
          codes = node["codes"][()]
          cats = read_h5py_category_values(node["categories"])
          code_list = codes.tolist() if isinstance(codes, np.ndarray) else list(codes)
          out = []
          for code in code_list:
            if code is None or code < 0 or code >= len(cats):
              out.append(None)
              continue
            out.append(cats[code])
          return out
        if enc in STRING_ARRAY_ENCODINGS and "values" in node:
          return read_h5py_encoded_string_series(node, enc)
        return []
      else:
        return []
      if isinstance(raw, np.ndarray):
        items = raw.tolist()
      elif isinstance(raw, (list, tuple)):
        items = list(raw)
      else:
        items = [raw]
      return [decode_obs_value(v) for v in items]

    def read_obs_column_values(obs_group, key):
      if key not in obs_group:
        return []
      node = obs_group[key]
      if isinstance(node, h5py.Group):
        enc = decode_attr(node.attrs.get("encoding-type", ""))
        if enc == "categorical" and "categories" in node:
          cats = read_h5py_category_values(node["categories"])
          out = [v for v in cats if v]
          return sorted(set(out))

      series = read_obs_column_series(obs_group, key)
      out = [v for v in series if v]
      return sorted(set(out))

    def store_obs_label_pairs(obs_group, obs_present):
      if obs_group is None:
        return
      for id_field, label_field in LABEL_PAIRS.items():
        if id_field == "organism_ontology_term_id":
          continue
        if id_field not in obs_present or label_field not in obs_present:
          continue
        ids = read_obs_column_series(obs_group, id_field)
        labels = read_obs_column_series(obs_group, label_field)
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
          field_values[f"obs/{id_field}#label_pairs"] = pairs[:200]
          label_vals = read_obs_column_values(obs_group, label_field)
          if label_vals:
            field_values[f"obs/{label_field}"] = label_vals[:200]

    def store_uns_label_pairs(uns_group, uns_present):
      id_field = "organism_ontology_term_id"
      label_field = LABEL_PAIRS.get(id_field)
      if not label_field or id_field not in uns_present or label_field not in uns_present:
        return
      id_vals = read_uns_value(uns_group, id_field)
      label_vals = read_uns_value(uns_group, label_field)
      if id_vals and label_vals:
        field_values[f"uns/{id_field}#label_pairs"] = [f"{id_vals[0]} || {label_vals[0]}"]

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

    def extract_experimental_obs_h5py(obs_group, obs_present):
      if obs_group is None:
        return
      for field in EXPERIMENTAL_OBS_FIELDS:
        if field not in obs_present:
          continue
        vals = read_obs_column_values(obs_group, field)
        if vals:
          field_values[f"obs/{field}"] = vals[:200]

    def extract_var_series_h5py(var_group, field):
      if field not in var_group:
        return []
      series = read_obs_column_series(var_group, field)
      if not series:
        return []
      return [decode_obs_value(v) or "" for v in series[:500]]

    def extract_var_series_h5py(var_group, field):
      if field not in var_group:
        return []
      series = read_obs_column_series(var_group, field)
      if not series:
        return []
      return [decode_obs_value(v) or "" for v in series[:500]]

    def extract_var_series_h5py(var_group, field):
      if field not in var_group:
        return []
      series = read_obs_column_series(var_group, field)
      if not series:
        return []
      return [decode_obs_value(v) or "" for v in series[:500]]

    def extract_var_fields_h5py(var_group, var_present):
      if var_group is None:
        return
      logical_index_path = "var@_index"
      for field in REQUIRED_VAR:
        if field not in var_present:
          continue
        vals = read_obs_column_values(var_group, field)
        if vals:
          field_values[f"var/{field}"] = vals[:200]
        series = extract_var_series_h5py(var_group, field)
        if series:
          field_values[f"var/{field}#series"] = series
      for index_key in ("_index", "index"):
        if index_key not in var_group:
          continue
        series = extract_var_series_h5py(var_group, index_key)
        if not series:
          continue
        field_values[f"{logical_index_path}#series"] = series
        field_values[logical_index_path] = sorted({v for v in series if v})[:200]
        break
        series = extract_var_series_h5py(var_group, field)
        if series:
          field_values[f"var/{field}#series"] = series
      for index_key in ("_index", "index"):
        if index_key not in var_group:
          continue
        series = extract_var_series_h5py(var_group, index_key)
        if not series:
          continue
        storage_path = "var/_index"
        field_values[f"{storage_path}#series"] = series
        field_values[storage_path] = sorted({v for v in series if v})[:200]
        break
        series = extract_var_series_h5py(var_group, field)
        if series:
          field_values[f"var/{field}#series"] = series
      for index_key in ("_index", "index"):
        if index_key not in var_group:
          continue
        series = extract_var_series_h5py(var_group, index_key)
        if series:
          field_values["var/_index#series"] = series
          field_values["var/_index"] = sorted({v for v in series if v})[:200]
        break

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

    def ontology_format_message(template, **kwargs):
        message = template
        for key, value in kwargs.items():
            message = message.replace("%{" + key + "}", str(value))
        return message

    def obo_format_example_for_field(field_path):
        field_name = field_path.split("/")[-1]
        return ONTOLOGY_FORMAT_EXAMPLES.get(field_name, DEFAULT_OBO_EXAMPLE)

    def presence_check_id_for_field(field):
      if field.startswith("var/"):
        return "var.required"
      if field.startswith("uns/"):
        return "uns.required_presence"
      return "obs.required_presence"

    def check_message(check_id, code, **kwargs):
      messages = CHECK_MESSAGES.get(check_id, {})
      raw = messages.get(code, "")
      if isinstance(raw, dict):
        template = raw.get("h5ad") or raw.get("default") or ""
      else:
        template = raw or ""
      message = template
      for key, value in kwargs.items():
        message = message.replace("%{" + key + "}", str(value))
      return message

    def presence_entry(field, status, code, **kwargs):
      check_id = presence_check_id_for_field(field)
      return {
        "field": field,
        "check_id": check_id,
        "status": status,
        "code": code,
        "message": check_message(check_id, code, path=field, **kwargs),
      }

    def check_ontology_values(field_path, values):
      prefixes = ONTOLOGY_FIELDS[field_path]
      specials = SPECIAL_VALUES.get(field_path, set())
      field_values[field_path] = values
      issues = 0
      for value in values:
        for term in [t.strip() for t in value.split(" || ")]:
          if term in specials:
            continue
          if term.startswith(CELLOSAURUS_PREFIX):
            if CELLOSAURUS_PREFIX.rstrip("_") not in prefixes:
              errors.append({
                "field": field_path,
                "check_id": ONTOLOGY_FORMAT_CHECK_ID,
                "status": "failed",
                "code": "cellosaurus_disallowed",
                "message": ontology_format_message(
                  ONTOLOGY_TERM_FORMATS["cellosaurus_disallowed_message"],
                  term=term
                )
              })
              issues += 1
            continue
          if not OBO_ONTOLOGY_PATTERN.match(term):
            errors.append({
              "field": field_path,
              "check_id": ONTOLOGY_FORMAT_CHECK_ID,
              "status": "failed",
              "code": "invalid_obo",
              "message": ontology_format_message(
                ONTOLOGY_TERM_FORMATS["obo_invalid_message"],
                term=term,
                example=obo_format_example_for_field(field_path)
              )
            })
            issues += 1
            continue
          prefix = term.split(":", 1)[0]
          if prefix not in prefixes:
            errors.append({
              "field": field_path,
              "check_id": ONTOLOGY_FORMAT_CHECK_ID,
              "status": "failed",
              "code": "unexpected_prefix",
              "message": f"Unexpected ontology prefix '{prefix}' for {field_path}"
            })
            issues += 1
      if issues == 0:
        field_name = field_path.split("/")[-1]
        valid_checks.append({
          "field": field_path,
          "check_id": ONTOLOGY_FORMAT_CHECK_ID,
          "status": "passed",
          "code": "valid",
          "message": check_message(ONTOLOGY_FORMAT_CHECK_ID, "valid", path=field_path)
        })

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
      with Timer("validate_from_h5py"):
        validate_from_h5py_inner(root)

    def validate_from_h5py_inner(root):
      emit_progress("matrix", "Checking matrix dimensions (shape only)")
      with Timer("h5py.matrix_shape"):
        n_obs, n_vars = matrix_shape_h5py(root)
      if not n_obs or not n_vars or n_obs <= 0 or n_vars <= 0:
        errors.append({"field": "X", "message": "AnnData has invalid or unreadable matrix shape"})
      else:
        field_values["matrix/n_obs"] = [str(n_obs)]
        valid_checks.append({"field": "X", "message": f"Matrix shape OK ({n_obs} cells x {n_vars} genes)"})

      emit_progress("obs", "Checking observation metadata structure")
      obs_present = set()
      obs_group = None
      obs_structure_started = time.perf_counter()
      if "obs" in root and isinstance(root["obs"], h5py.Group):
        obs_group = root["obs"]
        obs_present = obs_dataset_keys(obs_group)
        declared = obs_declared_columns(obs_group)
        missing_declared = sorted(declared - obs_present)
        if missing_declared:
          sample = ", ".join(missing_declared[:8])
          suffix = f" (+{len(missing_declared) - 8} more)" if len(missing_declared) > 8 else ""
          if len(missing_declared) == 1:
            message = (
              f"The obs column-order attribute lists {sample}, which is not stored in the file. "
              "The obs table and column-order attribute are inconsistent."
            )
          else:
            message = (
              f"The obs column-order attribute lists {len(missing_declared)} columns not stored in the file: "
              f"{sample}{suffix}. The obs table and column-order attribute are inconsistent."
            )
          errors.append({"field": "obs", "message": message})
        extra = sorted(obs_present - declared) if declared else []
        if extra and declared:
          sample = ", ".join(extra[:15])
          suffix = f" (+{len(extra) - 15} more)" if len(extra) > 15 else ""
          names = f"{sample}{suffix}"
          if len(extra) == 1:
            message = (
              f"The obs column {names} is stored in the file but not listed in the obs column-order attribute. "
              "The column-order attribute should list every stored obs column."
            )
          else:
            message = (
              f"The obs columns {names} are stored in the file but not listed in the obs column-order attribute. "
              "The column-order attribute should list every stored obs column."
            )
          warnings.append({"field": "obs", "message": message})
      else:
        errors.append({"field": "obs", "message": "Missing obs group"})
      emit_timing("h5py.obs_structure", obs_structure_started, {"n_obs": n_obs, "n_vars": n_vars})

      if obs_group is not None:
        store_metadata_columns("obs", metadata_column_keys(obs_group))

      var_group = None
      var_present = set()
      if "var" in root and isinstance(root["var"], h5py.Group):
        var_group = root["var"]
        var_present = obs_dataset_keys(var_group)
        store_metadata_columns("var", metadata_column_keys(var_group))

      required_obs_started = time.perf_counter()
      for field in REQUIRED_OBS:
        emit_progress("obs", f"Checking obs/{field}")
        field_started = time.perf_counter()
        if field in obs_present:
          valid_checks.append(presence_entry(f"obs/{field}", "passed", "found"))
          if obs_group is not None:
            vals = read_obs_column_values(obs_group, field)
            if vals:
              field_path = f"obs/{field}"
              field_values[field_path] = vals[:200]
              check_enum_values(field_path, vals)
        else:
          errors.append(presence_entry(f"obs/{field}", "failed", "missing"))
        emit_timing(f"h5py.obs/{field}", field_started, {"n_unique": len(field_values.get(f"obs/{field}", []))})
      emit_timing("h5py.required_obs", required_obs_started, {"fields": len(REQUIRED_OBS)})

      uns_present = set()
      uns_group = None
      uns_started = time.perf_counter()
      if "uns" in root and isinstance(root["uns"], h5py.Group):
        uns_group = root["uns"]
        uns_present = set(uns_group.keys())
        store_metadata_columns("uns", list(uns_present))

      for field in REQUIRED_UNS:
        emit_progress("uns", f"Checking uns/{field}")
        if field in uns_present:
          if field != "schema_version":
            valid_checks.append(presence_entry(f"uns/{field}", "passed", "found"))
          if uns_group is not None:
            vals = read_uns_value(uns_group, field)
            if vals:
              field_values[f"uns/{field}"] = vals[:200]
        else:
          errors.append(presence_entry(f"uns/{field}", "failed", "missing"))
      emit_timing("h5py.required_uns", uns_started, {"fields": len(REQUIRED_UNS)})

      if uns_group is not None:
        for field in OPTIONAL_UNS:
          if field in uns_present:
            vals = read_uns_value(uns_group, field)
            field_values[f"uns/{field}"] = vals[:200] if vals else []

      extensions_started = time.perf_counter()
      extract_spatial_from_uns_h5py(uns_group)
      extract_spatial_obs_h5py(obs_group, obs_present)
      extract_perturb_from_uns_h5py(uns_group)
      extract_perturb_obs_h5py(obs_group, obs_present)
      extract_experimental_obs_h5py(obs_group, obs_present)
      extract_var_fields_h5py(var_group, var_present)
      emit_timing("h5py.extensions", extensions_started)

      label_pairs_started = time.perf_counter()
      store_obs_label_pairs(obs_group, obs_present)
      store_uns_label_pairs(uns_group, uns_present)
      emit_timing("h5py.label_pairs", label_pairs_started)

      ontology_started = time.perf_counter()
      if obs_group is not None:
        for field_path in ONTOLOGY_FIELDS:
          if not field_path.startswith("obs/"):
            continue
          key = field_path.split("/", 1)[1]
          emit_progress("ontology", f"Checking {field_path} format")
          if key not in obs_present:
            continue
          field_started = time.perf_counter()
          values = read_obs_column_values(obs_group, key)
          if values:
            check_ontology_values(field_path, values)
          emit_timing(f"h5py.ontology/{field_path}", field_started, {"n_unique": len(values)})

      if uns_group is not None:
        for field_path in ONTOLOGY_FIELDS:
          if not field_path.startswith("uns/"):
            continue
          key = field_path.split("/", 1)[1]
          emit_progress("ontology", f"Checking {field_path} format")
          field_started = time.perf_counter()
          values = read_uns_value(uns_group, key)
          if values:
            check_ontology_values(field_path, values)
          emit_timing(f"h5py.ontology/{field_path}", field_started, {"n_unique": len(values)})
      emit_timing("h5py.ontology", ontology_started)

      emit_progress("obsm", "Checking embeddings (obsm)")
      obsm_started = time.perf_counter()
      obsm_key_list = []
      if "obsm" in root and isinstance(root["obsm"], h5py.Group):
        obsm_group = root["obsm"]
        obsm_key_list = obsm_keys_h5py(root)
        for key in obsm_key_list:
          key_started = time.perf_counter()
          arr = obsm_array_h5py(obsm_group, key)
          detail = {"shape": list(arr.shape) if arr is not None else None}
          if arr is None:
            errors.append({"field": f"obsm/{key}", "message": "Could not read embedding array"})
            emit_timing(f"h5py.obsm/{key}", key_started, detail)
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
          emit_timing(f"h5py.obsm/{key}", key_started, detail)

      if len(obsm_key_list) == 0:
        valid_checks.append({"field": "obsm", "status": "skipped", "message": "No embeddings present (optional per schema)"})
      else:
        valid_checks.append({"field": "obsm", "status": "passed", "message": f"{len(obsm_key_list)} embedding(s) found"})
      emit_timing("h5py.obsm", obsm_started, {"keys": len(obsm_key_list)})

    emit_progress("load", "Opening H5AD file (metadata only, matrix not loaded)")
    with Timer("h5py.open"):
      with h5py.File(file_path, "r") as root:
        validate_from_h5py(root)

    total_ms = round((time.perf_counter() - script_start) * 1000.0, 2)
    emit_timing("total", script_start, {"path": file_path})

    payload = {
      "errors": errors,
      "warnings": warnings,
      "info": info,
      "valid_checks": valid_checks,
      "field_values": field_values,
      "performance": {
        "total_ms": total_ms,
        "entries": timing_entries
      }
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
    log_performance_summary(parsed['performance'], path: @h5ad_path)

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
        elsif line.start_with?("#{TIMING_PREFIX}\t")
          handle_timing_line(line.delete_prefix("#{TIMING_PREFIX}\t"))
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

  def handle_timing_line(json_str)
    payload = JSON.parse(json_str)
    label = payload['label']
    duration_ms = payload['duration_ms']
    detail = payload['detail']
    detail_suffix = detail.present? ? " #{detail.to_json}" : ''
    @logger.info("[ScfairH5adValidatorService][TIMING] #{label}: #{duration_ms}ms#{detail_suffix}")
  rescue JSON::ParserError => e
    @logger.warn("[ScfairH5adValidatorService] Invalid timing payload: #{e.message}")
  end

  def log_performance_summary(performance, path:)
    return if performance.blank?

    total_ms = performance['total_ms']
    entries = Array(performance['entries'])
    @logger.info(
      "[ScfairH5adValidatorService][TIMING] summary for #{path}: total=#{total_ms}ms, stages=#{entries.size}"
    )

    entries
      .reject { |entry| entry['label'].to_s == 'total' }
      .sort_by { |entry| -entry['duration_ms'].to_f }
      .first(15)
      .each do |entry|
        detail = entry['detail']
        detail_suffix = detail.present? ? " #{detail.to_json}" : ''
        @logger.info(
          "[ScfairH5adValidatorService][TIMING]   #{entry['label']}: #{entry['duration_ms']}ms#{detail_suffix}"
        )
      end
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
