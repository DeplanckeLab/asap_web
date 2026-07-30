# Loom Creation Specification for Deterministic H5AD Reconstruction

## Purpose

Define a Loom creation contract that guarantees a deterministic Loom -> H5AD conversion, so that the resulting AnnData object can be validated against scFAIR/CELLxGENE-style metadata requirements.

This specification is format-bridge focused: it defines how to store data in Loom so conversion can rebuild native AnnData slots (`obs`, `var`, `uns`, `obsm`, `varm`, `obsp`, `varp`, `raw`) without inference.

## Principles

1. Store primary analytical arrays as HDF5 datasets, not JSON blobs.
2. Use JSON only for small mapping/config metadata.
3. Make orientation explicit.
4. Provide a mandatory mapping manifest in global metadata.
5. Avoid fallback heuristics during conversion. Conversion must use declared paths.

## Matrix orientation and canonical paths

ASAP internal Loom orientation is genes x cells.

`parse.v8.py` selects one primary matrix from `"/X"`, `"/raw/X"`, or `"/raw.X"` (or `--sel`) and writes it to `"/matrix"`. Other candidate matrices with matching dimensions are written to `"/layers/{safe_name}"` (for example `"/layers/X"`, `"/layers/raw_X"`).

| Logical AnnData object | Loom storage (ASAP orientation) |
| --- | --- |
| `X` | path declared in `x_path` (often `"/matrix"` or `"/layers/X"`) |
| `layers[name]` | `/layers/{name}` |
| `raw.X` | path declared in `raw_x_path`; can be `"/matrix"` when raw is selected as primary |
| `obs` columns | `/col_attrs/{field}` |
| `var` columns | `/row_attrs/{field}` |
| `obs.index` | `/col_attrs/CellID` (or declared equivalent) |
| `var.index` | `/row_attrs/Accession` (or declared equivalent) |

## Mandatory global manifest

Loom file MUST contain a global metadata JSON named:

`/attrs/anndata_mapping`

This manifest is the single source of truth used by the conversion tool.

### Required keys

- `version` (string): mapping schema version, e.g. `"1.0.0"`
- `orientation` (string): `"genes_x_cells"` for ASAP Loom
- `x_path` (string): path to the normalized (or primary analysis) matrix for `adata.X`
- `obs_path` (string): path prefix for obs columns, normally `"/col_attrs"`
- `var_path` (string): path prefix for var columns, normally `"/row_attrs"`
- `obs_index_key` (string): e.g. `"CellID"`
- `var_index_key` (string): e.g. `"Accession"`

### Required when data exists

- `raw_x_path` (string): required only when a raw matrix exists in Loom
- `raw_var_path` (string): required if raw var table is stored separately
- `layers` (object): mapping from AnnData layer names to Loom dataset paths (only for matrices distinct from `x_path` and `raw_x_path`)
- `obsm` (object): mapping from obsm keys to Loom dataset paths
- `varm` (object): mapping from varm keys to Loom dataset paths
- `obsp` (object): mapping from obsp keys to Loom dataset paths
- `varp` (object): mapping from varp keys to Loom dataset paths

### Recommended keys

- `categoricals` (object): field-level category/code metadata
- `dtypes` (object): explicit target dtype declarations
- `uns_json_keys` (array): list of global attrs that are JSON-encoded
- `notes` (string): human-readable mapping notes

## Data storage requirements

### 1) Required metadata fields

All required schema fields for target use case MUST be present as first-class arrays under the declared obs/var path prefixes.

If a required field is missing in Loom, conversion cannot reconstruct it.

### 2) Pairwise and multidimensional data

To rebuild native AnnData slots:

- `obsm` entries MUST be stored as 2D datasets.
- `varm` entries MUST be stored as 2D datasets.
- `obsp` entries MUST be stored as 2D square datasets.
- `varp` entries MUST be stored as 2D square datasets.

Recommended storage prefixes:

- `/embeddings/obsm/{key}`
- `/embeddings/varm/{key}`
- `/pairwise/obsp/{key}`
- `/pairwise/varp/{key}`

These paths MUST be declared in `anndata_mapping`.

For ASAP Loom files where embeddings are stored directly in attribute groups (as written by `parse.v8.py`), map them to the corresponding axis:

- obs-level embeddings (for example `X_umap`) -> `/col_attrs/...` in `obsm`
- var-level embeddings -> `/row_attrs/...` in `varm`

### 3) Raw representation

scFAIR does not require `raw.X` in all cases. When raw is absent, `var.feature_is_filtered` must be present with all values `False`.

If raw is intended in H5AD:

- raw matrix MUST be declared via `raw_x_path` only (do not also map the same dataset under `layers`)
- when raw is selected as primary during Loom creation, `raw_x_path` SHOULD be `"/matrix"` and normalized `X` SHOULD be declared in `x_path` (for example `"/layers/X"`)
- raw var metadata MUST be available, either:
  - at dedicated dataset/table path (preferred), or
  - duplicated in var with explicit `raw_var_fields` declaration in manifest

If normalized `X` is selected as primary and written to `"/matrix"`, raw is considered absent: omit `raw_x_path` and do not declare a raw entry in `layers`.

### 4) Categorical metadata

For categorical fields, Loom SHOULD store:

- value vector (`/col_attrs/{field}` or `/row_attrs/{field}`)
- category list (optional dataset or manifest entry)
- ordering info (manifest)

Converter must use this to rebuild pandas categoricals in H5AD.

### 5) JSON usage policy

Allowed:

- small global metadata (`uns`-like configs, mapping, provenance)
- serialized nested dictionaries

Not allowed for primary analytical arrays:

- `X`, `layers`, `obsm`, `varm`, `obsp`, `varp`, `raw.X`, raw var tables

## Validation checks before accepting Loom

1. Manifest exists and is valid JSON.
2. All declared paths exist.
3. Declared index keys exist and are unique.
4. Dimensions align with orientation declaration.
5. Pairwise matrices are square and dimensions match obs/var cardinality.
6. Required schema metadata fields are present.
7. The same Loom dataset path is not mapped to both `raw_x_path` and `layers` (avoids duplicate raw representation in H5AD).

If any check fails, file is non-compliant for deterministic H5AD reconstruction.

## Minimal manifest examples

Case A: raw selected as primary during Loom creation (`/matrix` stores raw matrix, normalized `X` in a layer).

```json
{
  "version": "1.0.0",
  "orientation": "genes_x_cells",
  "x_path": "/layers/X",
  "obs_path": "/col_attrs",
  "var_path": "/row_attrs",
  "obs_index_key": "CellID",
  "var_index_key": "Accession",
  "raw_x_path": "/matrix",
  "layers": {
    "X": "/layers/X"
  },
  "obsm": {
    "X_umap": "/col_attrs/X_umap"
  },
  "varm": {},
  "obsp": {
    "connectivities": "/pairwise/obsp/connectivities",
    "distances": "/pairwise/obsp/distances"
  },
  "varp": {},
  "uns_json_keys": ["analysis_pipeline", "spatial"],
  "categoricals": {
    "cell_type": {
      "categories": ["T cell", "B cell", "myeloid cell"],
      "ordered": false
    }
  }
}
```

Case B: normalized `X` selected as primary (`/matrix` stores normalized matrix, no raw matrix).

```json
{
  "version": "1.0.0",
  "orientation": "genes_x_cells",
  "x_path": "/matrix",
  "obs_path": "/col_attrs",
  "var_path": "/row_attrs",
  "obs_index_key": "CellID",
  "var_index_key": "Accession",
  "layers": {},
  "obsm": {
    "X_umap": "/col_attrs/X_umap"
  },
  "varm": {},
  "obsp": {
    "connectivities": "/pairwise/obsp/connectivities",
    "distances": "/pairwise/obsp/distances"
  },
  "varp": {},
  "uns_json_keys": ["analysis_pipeline", "spatial"]
}
```

## Non-goals

- This spec does not redefine scFAIR biological semantics.
- This spec only guarantees representational completeness for conversion.
