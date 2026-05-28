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

| Logical AnnData object | Loom storage (ASAP orientation) |
| --- | --- |
| `X` | `/matrix` (genes x cells in ASAP Loom) |
| `layers[name]` | `/layers/{name}` |
| `raw.X` | `/layers/raw` (required if raw exists) |
| `obs` columns | `/col_attrs/{field}` |
| `var` columns | `/row_attrs/{field}` |
| `obs.index` | `/col_attrs/CellID` (or declared equivalent) |
| `var.index` | `/row_attrs/feature_id` (or declared equivalent) |

## Mandatory global manifest

Loom file MUST contain a global metadata JSON named:

`/attrs/anndata_mapping`

This manifest is the single source of truth used by the conversion tool.

### Required keys

- `version` (string): mapping schema version, e.g. `"1.0.0"`
- `orientation` (string): `"genes_x_cells"` for ASAP Loom
- `x_path` (string): path to main matrix, normally `"/matrix"`
- `obs_path` (string): path prefix for obs columns, normally `"/col_attrs"`
- `var_path` (string): path prefix for var columns, normally `"/row_attrs"`
- `obs_index_key` (string): e.g. `"CellID"`
- `var_index_key` (string): e.g. `"feature_id"`

### Required when data exists

- `raw_x_path` (string): required if raw matrix exists
- `raw_var_path` (string): required if raw var table is stored separately
- `layers` (object): mapping from AnnData layer names to Loom dataset paths
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

### 3) Raw representation

If raw is intended in H5AD:

- raw matrix MUST exist as `/layers/raw` (or path declared in manifest)
- raw var metadata MUST be available, either:
  - at dedicated dataset/table path (preferred), or
  - duplicated in var with explicit `raw_var_fields` declaration in manifest

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

If any check fails, file is non-compliant for deterministic H5AD reconstruction.

## Minimal manifest example

```json
{
  "version": "1.0.0",
  "orientation": "genes_x_cells",
  "x_path": "/matrix",
  "obs_path": "/col_attrs",
  "var_path": "/row_attrs",
  "obs_index_key": "CellID",
  "var_index_key": "feature_id",
  "raw_x_path": "/layers/raw",
  "layers": {
    "normalized": "/matrix",
    "raw": "/layers/raw"
  },
  "obsm": {
    "X_umap": "/embeddings/obsm/X_umap"
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

## Non-goals

- This spec does not redefine scFAIR biological semantics.
- This spec only guarantees representational completeness for conversion.

