#!/usr/bin/env python3
"""Parse H5AD or Loom files into minimal extract JSON (extraction only, no checks).

Output matches src/config/scfair/minimal_extract_spec.json.

Usage:
  python3 scripts/scfair_loom_h5ad_extract_parser.py path/to/file.h5ad
  python3 scripts/scfair_loom_h5ad_extract_parser.py path/to/file.loom --output tmp/extract.json
  python3 scripts/scfair_loom_h5ad_extract_parser.py test [path/to/fixture.h5ad]
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import h5py
import numpy as np

SPEC_REFERENCE = "src/config/scfair/minimal_extract_spec.json"
MAX_DISTINCT = 200

LABEL_PAIRS_OBS = {
    "assay_ontology_term_id": "assay",
    "cell_type_ontology_term_id": "cell_type",
    "development_stage_ontology_term_id": "development_stage",
    "disease_ontology_term_id": "disease",
    "self_reported_ethnicity_ontology_term_id": "self_reported_ethnicity",
    "sex_ontology_term_id": "sex",
    "tissue_ontology_term_id": "tissue",
}

SCHEMA_OBS_FIELDS = [
    "assay_ontology_term_id",
    "assay",
    "tissue_type",
    "tissue_ontology_term_id",
    "tissue",
    "cell_type_ontology_term_id",
    "cell_type",
    "development_stage_ontology_term_id",
    "development_stage",
    "sex_ontology_term_id",
    "sex",
    "self_reported_ethnicity_ontology_term_id",
    "self_reported_ethnicity",
    "strain_or_genetic_background_term_id",
    "strain_or_genetic_background",
    "disease_ontology_term_id",
    "disease",
    "experimental_condition_ontology_term_id",
    "experimental_condition",
    "perturbation_types",
    "donor_id",
    "is_primary_data",
    "suspension_type",
    "array_row",
    "array_col",
    "in_tissue",
    "genetic_perturbation_id",
    "genetic_perturbation_strategy",
]

SCHEMA_VAR_FIELDS = [
    "feature_is_filtered",
    "feature_biotype",
    "feature_length",
    "feature_name",
    "feature_reference",
    "feature_type",
    "feature_chromosome",
]

STRING_ARRAY_ENCODINGS = ("string-array", "ascii", "string", "nullable-string-array")


def decode_attr(value: Any) -> Any:
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    if isinstance(value, np.ndarray):
        return [decode_attr(v) for v in value.tolist()]
    return value


def decode_obs_value(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def to_json_safe(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, np.bool_):
        return bool(value)
    if isinstance(value, np.integer):
        return int(value)
    if isinstance(value, np.floating):
        return float(value)
    if isinstance(value, np.ndarray):
        return [to_json_safe(v) for v in value.tolist()]
    if isinstance(value, dict):
        return {k: to_json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_json_safe(v) for v in value]
    return value


def uns_scalar(value: Any, type_name: str | None = None) -> dict[str, Any]:
    value = to_json_safe(value)
    if type_name is None:
        if isinstance(value, bool):
            type_name = "boolean"
        elif isinstance(value, int) and not isinstance(value, bool):
            type_name = "integer"
        else:
            type_name = "string"
            value = str(value)
    if type_name == "string":
        value = str(value)
    elif type_name == "integer":
        value = int(value)
    elif type_name == "boolean":
        value = bool(value)
    return {"type": type_name, "value": value}


def obs_column(distinct_values: list[str]) -> dict[str, Any]:
    return {"distinct_values": distinct_values}


def var_column(per_feature_values: list[str]) -> dict[str, Any]:
    return {"per_feature_values": per_feature_values}


def paired_block(label_field: str, pairs: list[dict[str, str]]) -> dict[str, Any]:
    return {"label_field": label_field, "pairs": pairs}


def array_meta(shape: tuple | list, dtype: str, has_inf: bool = False, has_nan: bool = False) -> dict[str, Any]:
    return {
        "type": "array",
        "shape": [int(s) for s in shape],
        "dtype": dtype,
        "has_inf": bool(has_inf),
        "has_nan": bool(has_nan),
    }


def normalize_hwc_shape(shape: tuple[int, ...]) -> tuple[int, ...]:
    """Return height x width x channels for 3D image arrays.

    H5AD spatial images are stored as HWC. Only transpose channels-first CHW arrays.
    """
    if len(shape) == 3 and shape[0] in (3, 4):
        return (shape[1], shape[2], shape[0])
    return shape


def truncate_unique(values: list[str | None], max_n: int = MAX_DISTINCT) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for raw in values:
        if raw is None:
            continue
        val = str(raw).strip()
        if not val or val in seen:
            continue
        seen.add(val)
        out.append(val)
        if len(out) >= max_n:
            break
    return out


def read_h5py_raw_items(node: h5py.Dataset | h5py.Group) -> list[Any] | None:
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


def read_h5py_encoded_string_series(node: h5py.Group, encoding: str) -> list[str | None]:
    if "values" not in node:
        return []
    items = read_h5py_raw_items(node["values"])
    if items is None:
        return []
    if encoding == "nullable-string-array" and "mask" in node:
        mask = node["mask"][()]
        mask_list = mask.tolist() if isinstance(mask, np.ndarray) else list(mask)
        out: list[str | None] = []
        for idx, item in enumerate(items):
            if idx < len(mask_list) and mask_list[idx]:
                out.append(None)
                continue
            out.append(decode_obs_value(item))
        return out
    return [decode_obs_value(v) for v in items]


def read_h5py_category_values(categories_node: h5py.Dataset | h5py.Group) -> list[str | None]:
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


def read_string_series(group: h5py.Group, key: str) -> list[str | None]:
    if key not in group:
        return []
    node = group[key]
    if isinstance(node, h5py.Dataset):
        raw = node[()]
        if isinstance(raw, np.ndarray):
            items = raw.tolist()
        elif isinstance(raw, (list, tuple)):
            items = list(raw)
        else:
            items = [raw]
        return [decode_obs_value(v) for v in items]

    if isinstance(node, h5py.Group):
        enc = decode_attr(node.attrs.get("encoding-type", ""))
        if enc == "categorical" and "codes" in node and "categories" in node:
            codes = node["codes"][()]
            cats = read_h5py_category_values(node["categories"])
            code_list = codes.tolist() if isinstance(codes, np.ndarray) else list(codes)
            out: list[str | None] = []
            for code in code_list:
                if code is None or code < 0 or code >= len(cats):
                    out.append(None)
                    continue
                out.append(cats[code])
            return out
        if enc in STRING_ARRAY_ENCODINGS and "values" in node:
            return read_h5py_encoded_string_series(node, enc)
    return []


def read_dataset_scalar(group: h5py.Group, key: str) -> Any | None:
    if key not in group:
        return None
    node = group[key]
    if not isinstance(node, h5py.Dataset):
        return None
    val = node[()]
    if isinstance(val, bytes):
        return val.decode("utf-8", "replace")
    if isinstance(val, np.ndarray) and val.shape == ():
        val = val.item()
    if np.ndim(val) == 0:
        return val
    return None


def list_group_columns(group: h5py.Group) -> list[str]:
    skip = {"_index", "index", "__categories"}
    return sorted(k for k in group.keys() if k not in skip and not k.startswith("_"))


def top_level_groups(f: h5py.File, candidates: list[str]) -> list[str]:
    return sorted(name for name in candidates if name in f)


def read_matrix_dims_h5ad(f: h5py.File) -> dict[str, Any]:
    n_obs = None
    n_vars = None
    encoding = None
    if "X" not in f:
        return {"n_obs": n_obs, "n_vars": n_vars, "encoding": encoding}

    x = f["X"]
    encoding = decode_attr(x.attrs.get("encoding-type"))
    shape_attr = x.attrs.get("shape")
    if shape_attr is not None:
        sh = tuple(int(s) for s in shape_attr)
        if len(sh) >= 2:
            return {"n_obs": sh[0], "n_vars": sh[1], "encoding": encoding}

    if isinstance(x, h5py.Dataset) and len(x.shape) >= 2:
        return {"n_obs": int(x.shape[0]), "n_vars": int(x.shape[1]), "encoding": encoding}

    return {"n_obs": n_obs, "n_vars": n_vars, "encoding": encoding}


def read_obs_declared_columns(f: h5py.File) -> list[str]:
    if "obs" not in f:
        return []
    co = f["obs"].attrs.get("column-order")
    if co is None:
        return []
    if isinstance(co, np.ndarray):
        co = co.tolist()
    if isinstance(co, (list, tuple)):
        return [str(decode_attr(v)) for v in co]
    return [str(decode_attr(co))]


def array_stats(arr: np.ndarray) -> tuple[bool, bool]:
    if not np.issubdtype(arr.dtype, np.floating):
        return False, False
    return bool(np.isinf(arr).any()), bool(np.isnan(arr).any())


def read_obsm_array_meta(obsm_group: h5py.Group, key: str) -> dict[str, Any] | None:
    if key not in obsm_group:
        return None
    node = obsm_group[key]
    if isinstance(node, h5py.Group):
        enc = decode_attr(node.attrs.get("encoding-type", ""))
        if enc in ("array", "dense_array") and "data" in node:
            data = np.asarray(node["data"][()])
            has_inf, has_nan = array_stats(data)
            return array_meta(data.shape, str(data.dtype), has_inf, has_nan)
        return None
    if isinstance(node, h5py.Dataset):
        data = np.asarray(node[()])
        has_inf, has_nan = array_stats(data)
        return array_meta(data.shape, str(data.dtype), has_inf, has_nan)
    return None


def read_col_embedding_meta(f: h5py.File, path: str) -> dict[str, Any] | None:
    if path not in f:
        return None
    node = f[path]
    if not isinstance(node, h5py.Dataset):
        return None
    data = np.asarray(node[()])
    if data.ndim == 0:
        return None
    has_inf, has_nan = array_stats(data)
    return array_meta(data.shape, str(data.dtype), has_inf, has_nan)


def walk_nested_extension(group: h5py.Group, prefix_parts: list[str], scalars: dict, arrays: dict) -> None:
    for key in group.keys():
        node = group[key]
        rel = "/".join(prefix_parts + [key])
        if isinstance(node, h5py.Group):
            walk_nested_extension(node, prefix_parts + [key], scalars, arrays)
            continue
        if not isinstance(node, h5py.Dataset):
            continue
        if node.ndim == 0:
            val = node[()]
            if isinstance(val, bytes):
                val = val.decode("utf-8", "replace")
            scalars[rel] = uns_scalar(val)
        else:
            shape = normalize_hwc_shape(tuple(int(s) for s in node.shape))
            has_inf = has_nan = False
            if node.size > 0 and np.issubdtype(node.dtype, np.floating):
                sample = np.asarray(node[()])
                has_inf, has_nan = array_stats(sample)
            arrays[rel] = array_meta(shape, str(node.dtype), has_inf, has_nan)


def build_nested_extension(f: h5py.File, prefix: str) -> dict[str, Any] | None:
    if prefix not in f:
        return None
    root = f[prefix]
    if not isinstance(root, h5py.Group):
        return None
    scalars: dict[str, Any] = {}
    arrays: dict[str, Any] = {}
    walk_nested_extension(root, [], scalars, arrays)
    if not scalars and not arrays:
        return None
    out: dict[str, Any] = {"type": "nested"}
    if scalars:
        out["scalars"] = scalars
    if arrays:
        out["arrays"] = arrays
    return out


def store_obs_label_pairs(
    obs_series: dict[str, list[str | None]],
    id_field: str,
    label_field: str,
    max_pairs: int = MAX_DISTINCT,
) -> dict[str, Any] | None:
    ids = obs_series.get(id_field)
    labels = obs_series.get(label_field)
    if not ids or not labels or len(ids) != len(labels):
        return None
    pairs: list[dict[str, str]] = []
    seen: set[str] = set()
    for id_val, label_val in zip(ids, labels):
        if not id_val or not label_val:
            continue
        token = f"{id_val} || {label_val}"
        if token in seen:
            continue
        seen.add(token)
        pairs.append({"id": str(id_val), "label": str(label_val)})
        if len(pairs) >= max_pairs:
            break
    if not pairs:
        return None
    return paired_block(label_field, pairs)


def paired_obs_column_names(paired_obs: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for id_field, block in paired_obs.items():
        names.add(id_field)
        names.add(block["label_field"])
    return names


def build_paired_obs(obs_series: dict[str, list[str | None]], obs_cols: list[str]) -> dict[str, Any]:
    paired: dict[str, Any] = {}
    for id_field, label_field in LABEL_PAIRS_OBS.items():
        if id_field not in obs_cols or label_field not in obs_cols:
            continue
        block = store_obs_label_pairs(obs_series, id_field, label_field)
        if block:
            paired[id_field] = block
    return paired


def build_obs_columns(
    obs_series: dict[str, list[str | None]],
    obs_cols: list[str],
    paired_obs: dict[str, Any],
) -> dict[str, Any]:
    skip = paired_obs_column_names(paired_obs)
    columns: dict[str, Any] = {}
    for col in obs_cols:
        if col in skip or col not in SCHEMA_OBS_FIELDS:
            continue
        series = obs_series.get(col)
        if not series:
            continue
        distinct = truncate_unique(series)
        if distinct:
            columns[col] = obs_column(distinct)
    return columns


def build_var_columns(var_series: dict[str, list[str | None]], var_cols: list[str]) -> dict[str, Any]:
    columns: dict[str, Any] = {}
    for col in var_cols:
        if col not in SCHEMA_VAR_FIELDS:
            continue
        series = var_series.get(col)
        if not series:
            continue
        columns[col] = var_column([str(v) if v is not None else "" for v in series])
    return columns


def build_paired_uns(uns_scalars: dict[str, Any]) -> dict[str, Any]:
    paired: dict[str, Any] = {}
    term_id = uns_scalars.get("organism_ontology_term_id")
    label = uns_scalars.get("organism")
    if term_id is not None and label is not None:
        paired["organism_ontology_term_id"] = paired_block(
            "organism",
            [{"id": str(term_id), "label": str(label)}],
        )
    return paired


def resolve_var_index_series(var_group: h5py.Group) -> list[str] | None:
    for idx_key in ("_index", "index"):
        if idx_key not in var_group:
            continue
        series = read_string_series(var_group, idx_key)
        if series:
            return [str(v) if v is not None else "" for v in series]

    index_attr = var_group.attrs.get("_index")
    if index_attr is not None:
        if isinstance(index_attr, bytes):
            index_attr = index_attr.decode("utf-8", "replace")
        col_name = str(index_attr)
        if col_name in var_group:
            series = read_string_series(var_group, col_name)
            if series:
                return [str(v) if v is not None else "" for v in series]
    return None


def assemble_extract(parsed: dict[str, Any]) -> dict[str, Any]:
    doc = {
        "specification": SPEC_REFERENCE,
        "source_url": parsed["source_url"],
        "format": parsed["format"],
        "extracted_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    rest = {k: v for k, v in parsed.items() if k not in {"source_url", "format"}}
    return {**doc, **rest}


def parse_h5ad(file_path: Path) -> dict[str, Any]:
    with h5py.File(file_path, "r") as f:
        obs_cols = list_group_columns(f["obs"]) if "obs" in f else []
        var_cols = list_group_columns(f["var"]) if "var" in f else []
        uns_keys = list_group_columns(f["uns"]) if "uns" in f else []

        dims = read_matrix_dims_h5ad(f)
        n_obs = dims["n_obs"]
        n_vars = dims["n_vars"]
        matrix_encoding = dims["encoding"]
        declared_obs = read_obs_declared_columns(f)
        groups_present = top_level_groups(f, ["obs", "var", "X", "uns", "obsm"])

        obs_series: dict[str, list[str | None]] = {}
        if "obs" in f:
            for col in obs_cols:
                series = read_string_series(f["obs"], col)
                if series:
                    obs_series[col] = series

        paired_obs = build_paired_obs(obs_series, obs_cols)
        obs_columns = build_obs_columns(obs_series, obs_cols, paired_obs)

        uns: dict[str, Any] = {}
        uns_scalars: dict[str, Any] = {}
        if "uns" in f:
            for key in uns_keys:
                val = read_dataset_scalar(f["uns"], key)
                if val is not None:
                    uns[key] = uns_scalar(val)
                    uns_scalars[key] = val

        paired_uns = build_paired_uns(uns_scalars)

        var_series: dict[str, list[str | None]] = {}
        if "var" in f:
            for col in var_cols:
                series = read_string_series(f["var"], col)
                if series:
                    var_series[col] = series
        var_columns = build_var_columns(var_series, var_cols)

        var_index = None
        if "var" in f:
            series = resolve_var_index_series(f["var"])
            if series:
                var_index = var_column(series)

        obsm_keys = list(f["obsm"].keys()) if "obsm" in f else []
        obsm: dict[str, Any] = {}
        if "obsm" in f:
            for key in obsm_keys:
                meta = read_obsm_array_meta(f["obsm"], key)
                if meta:
                    obsm[key] = meta

        extensions: dict[str, Any] = {}
        spatial = build_nested_extension(f, "uns/spatial")
        if spatial:
            extensions["spatial"] = spatial
        perturb = build_nested_extension(f, "uns/genetic_perturbations")
        if perturb:
            extensions["genetic_perturbations"] = perturb

        matrix_inventory: dict[str, Any] = {"n_obs": n_obs, "n_vars": n_vars}
        if matrix_encoding:
            matrix_inventory["encoding"] = str(matrix_encoding)

        obs_inventory: dict[str, Any] = {"column_names": obs_cols}
        if declared_obs:
            obs_inventory["declared_column_names"] = declared_obs

        var_doc: dict[str, Any] = {"columns": var_columns}
        if var_index is not None:
            var_doc["index"] = var_index

        return {
            "source_url": str(file_path.resolve()),
            "format": "h5ad",
            "file_inventory": {
                "matrix": matrix_inventory,
                "structure": {"groups_present": groups_present},
                "obs": obs_inventory,
                "var": {"column_names": var_cols},
                "uns": {"top_level_keys": uns_keys},
                "obsm": {"keys": obsm_keys},
            },
            "uns": uns,
            "paired_fields": {"obs": paired_obs, "uns": paired_uns},
            "obs": {"columns": obs_columns},
            "var": var_doc,
            "extensions": extensions or None,
            "obsm": obsm or None,
        }


def parse_loom(file_path: Path) -> dict[str, Any]:
    with h5py.File(file_path, "r") as f:
        col_attrs = sorted(f["col_attrs"].keys()) if "col_attrs" in f else []
        row_attrs = sorted(f["row_attrs"].keys()) if "row_attrs" in f else []
        global_attrs = sorted(f["attrs"].keys()) if "attrs" in f else []

        n_obs = None
        n_vars = None
        if "matrix" in f:
            sh = f["/matrix"].shape
            if len(sh) >= 2:
                n_vars = int(sh[0])
                n_obs = int(sh[1])

        obs_series: dict[str, list[str | None]] = {}
        if "col_attrs" in f:
            for col in col_attrs:
                series = read_string_series(f["col_attrs"], col)
                if series:
                    obs_series[col] = series

        paired_obs = build_paired_obs(obs_series, col_attrs)
        obs_columns = build_obs_columns(obs_series, col_attrs, paired_obs)

        uns: dict[str, Any] = {}
        uns_scalars: dict[str, Any] = {}
        if "attrs" in f:
            for key in global_attrs:
                val = read_dataset_scalar(f["attrs"], key)
                if val is not None:
                    uns[key] = uns_scalar(val)
                    uns_scalars[key] = val

        paired_uns = build_paired_uns(uns_scalars)

        groups_present = top_level_groups(f, ["matrix", "col_attrs", "row_attrs", "attrs"])
        anndata_mapping_present = "attrs" in f and "anndata_mapping" in f["attrs"]

        col_embeddings: dict[str, Any] = {}
        spatial_emb = read_col_embedding_meta(f, "/col_attrs/spatial")
        if spatial_emb:
            col_embeddings["/col_attrs/spatial"] = spatial_emb

        extensions: dict[str, Any] = {}
        spatial_ext = build_nested_extension(f, "attrs/spatial")
        if spatial_ext:
            extensions["spatial"] = spatial_ext
        perturb_ext = build_nested_extension(f, "attrs/genetic_perturbations")
        if perturb_ext:
            extensions["genetic_perturbations"] = perturb_ext

        var_series: dict[str, list[str | None]] = {}
        if "row_attrs" in f:
            for col in row_attrs:
                series = read_string_series(f["row_attrs"], col)
                if series:
                    var_series[col] = series
        var_columns = build_var_columns(var_series, row_attrs)

        var_index = None
        if "row_attrs" in f:
            for idx_key in ("Accession", "index", "_index"):
                if idx_key not in f["row_attrs"]:
                    continue
                series = read_string_series(f["row_attrs"], idx_key)
                if series:
                    var_index = var_column([str(v) if v is not None else "" for v in series])
                    break

        var_doc: dict[str, Any] = {"columns": var_columns}
        if var_index is not None:
            var_doc["index"] = var_index

        return {
            "source_url": str(file_path.resolve()),
            "format": "loom",
            "file_inventory": {
                "matrix": {"n_obs": n_obs, "n_vars": n_vars},
                "structure": {
                    "groups_present": groups_present,
                    "anndata_mapping_present": bool(anndata_mapping_present),
                },
                "obs": {"column_names": col_attrs},
                "var": {"column_names": row_attrs},
                "uns": {"top_level_keys": global_attrs},
                "obsm": {"keys": []},
            },
            "uns": uns,
            "paired_fields": {"obs": paired_obs, "uns": paired_uns},
            "obs": {"columns": obs_columns},
            "var": var_doc,
            "extensions": extensions or None,
            "obsm": None,
            "col_embeddings": col_embeddings or None,
        }


def parse_file(file_path: Path) -> dict[str, Any]:
    ext = file_path.suffix.lower()
    if ext == ".h5ad":
        parsed = parse_h5ad(file_path)
    elif ext == ".loom":
        parsed = parse_loom(file_path)
    else:
        raise ValueError(f"Unsupported extension: {ext} (expected .h5ad or .loom)")
    return assemble_extract(parsed)


def run_self_tests(fixture_path: Path | None = None) -> None:
    print("Running scfair_loom_h5ad_extract_parser self-tests...")
    errors: list[str] = []

    def assert_true(cond: bool, msg: str) -> None:
        if not cond:
            errors.append(msg)

    fixture = fixture_path
    if fixture is None:
        for candidate in (
            Path("/data/asap2_test/tmp/cxg_example.h5ad"),
            Path("tmp/cxg_example.h5ad"),
        ):
            if candidate.exists():
                fixture = candidate
                break

    if fixture is None or not fixture.exists():
        print("Skipping file parse tests (fixture not found)")
    else:
        ex = parse_file(fixture)
        assert_true(ex["format"] == "h5ad", "detects h5ad format")
        assay_pairs = ex.get("paired_fields", {}).get("obs", {}).get("assay_ontology_term_id", {}).get("pairs", [])
        assert_true(bool(assay_pairs and assay_pairs[0].get("id")), "structured paired_fields")
        assert_true((ex.get("file_inventory", {}).get("matrix", {}).get("n_obs") or 0) > 0, "reads n_obs")
        assert_true(len(ex.get("obs", {}).get("columns", {})) > 0, "reads obs columns")
        assert_true("missing_for_full_compliance" not in ex, "extract must not include compliance diagnostics")

    assert_true(uns_scalar("x")["type"] == "string", "uns_scalar helper")
    assert_true(uns_scalar(np.int64(51))["value"] == 51, "uns_scalar converts numpy integers")
    assert_true(isinstance(uns_scalar(np.int64(51))["value"], int), "uns_scalar value is native int")
    assert_true(bool(paired_block("a", [{"id": "1", "label": "2"}])["pairs"]), "paired_block helper")
    assert_true(normalize_hwc_shape((1820, 2000, 3)) == (1820, 2000, 3), "preserves HWC image shape")
    assert_true(normalize_hwc_shape((3, 1820, 2000)) == (1820, 2000, 3), "converts CHW image shape to HWC")

    if errors:
        print("FAILED:")
        for err in errors:
            print(f"  {err}")
        sys.exit(1)
    print("All self-tests passed.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", help="Input .h5ad or .loom file, or 'test'")
    parser.add_argument("fixture", nargs="?", help="Optional fixture path when input is 'test'")
    parser.add_argument("--output", "-o", dest="output", help="Output JSON path")
    args = parser.parse_args()

    if args.input == "test":
        fixture = Path(args.fixture) if args.fixture else None
        run_self_tests(fixture)
        return 0

    if not args.input:
        parser.error("Usage: python3 scfair_loom_h5ad_extract_parser.py <file> [--output path.json]")

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"File not found: {input_path}", file=sys.stderr)
        return 1

    output_path = input_path.with_name(input_path.stem + "_extract.json")
    if args.output:
        output_path = Path(args.output)

    extract = to_json_safe(parse_file(input_path))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as fh:
        json.dump(extract, fh, indent=2)
        fh.write("\n")
    print(f"Wrote {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
