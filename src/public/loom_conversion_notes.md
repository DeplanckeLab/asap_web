# Loom Conversion Notes for CXG Schema 7.1.0

This note documents how to translate CELLxGENE schema 7.1.0 requirements from the canonical AnnData/H5AD file layout to the Loom file layout that ASAP uses. Pair this with the full schema specifications in `cxg_7.1.0.md` (H5AD reference) and `cxg_7.1.0_loom.md` (Loom reinterpretation).

## 1. Location Equivalents

| H5AD / AnnData path | Purpose | Loom equivalent | Notes |
| --- | --- | --- | --- |
| `X` | Primary matrix shown in Explorer | `/matrix` | Keep shape `(n_cells, n_genes)` and sparse encoding requirements. |
| `raw.X` | “Raw” counts matrix | `/layers/raw` | Additional matrices go under `/layers/{name}`. |
| `layers/{name}` | Extra matrices (e.g. normalized) | `/layers/{name}` | Loom already names layers this way. |
| `obs[field]` | Cell metadata columns | `/row_attrs/{field}` | Each attribute is a 1-D array of length `n_cells`. |
| `var[field]` | Gene metadata columns | `/col_attrs/{field}` | Each attribute is a 1-D array of length `n_genes`. |
| `raw.var[field]` | Raw gene metadata | `/layers/raw/attrs/{field}` *or* `/col_attrs/{field}` copy | Loom lacks a dedicated raw.var table; duplicate metadata or store alongside raw layer attributes. |
| `obsm[key]` | Embeddings (UMAP, tSNE, spatial, …) | `/row_attrs/{key}` stored as 2-D arrays | Keep `(n_cells, m)` dense ndarrays. |
| `obsp[key]` | Pairwise cell matrices | No direct path | Store as separate dataset (e.g. `/pairwise/{key}`) or external file; see §3. |
| `varm[key]` | Multi-dimensional gene annotations | `/col_attrs/{key}` as 2-D arrays | Loom allows 2-D per attribute; keep `(n_genes, m)`. |
| `varp[key]` | Pairwise gene matrices | No direct path | Same workaround as `obsp`. |
| `uns[key]` | Dataset-level metadata | Global attributes (root) | Flatten nested dicts to names like `spatial/is_single`. |
| `uns['log1p']`, `uns['default_embedding']`, … | Explorer configuration | Global attributes with same keys; embed JSON strings when nesting is unavoidable. |
| `.obs.index` / `.var.index` | Cell & gene identifiers | `/row_attrs/CellID`, `/col_attrs/GeneID` (or similar) | Ensure uniqueness; use same IDs across matrices. |

## 2. Schema Metadata Name Reference

Below are the schema-reserved metadata names that have to be present verbatim, along with their Loom locations. This list mirrors the required and curator-added fields from CXG schema 7.1.0; add any curator-specific extras under the same rules.

### 2.1 Cell-Level (`obs`) Metadata → `/row_attrs/`

| Metadata name | Description (abridged) | Loom path |
| --- | --- | --- |
| `assay` | Human-readable assay label | `/row_attrs/assay` |
| `assay_ontology_term_id` | OBO ID for assay | `/row_attrs/assay_ontology_term_id` |
| `cell_type` | Cell type label | `/row_attrs/cell_type` |
| `cell_type_ontology_term_id` | CL/other ontology term | `/row_attrs/cell_type_ontology_term_id` |
| `development_stage` | Text label | `/row_attrs/development_stage` |
| `development_stage_ontology_term_id` | Stage ontology ID | `/row_attrs/development_stage_ontology_term_id` |
| `disease` | Display text (or `healthy`) | `/row_attrs/disease` |
| `disease_ontology_term_id` | MONDO term(s) | `/row_attrs/disease_ontology_term_id` |
| `donor_id` | Sample donor identifier | `/row_attrs/donor_id` |
| `is_primary_data` | `bool` flag | `/row_attrs/is_primary_data` |
| `sample_overlaps` | Overlap descriptors | `/row_attrs/sample_overlaps` |
| `sex` | Display value | `/row_attrs/sex` |
| `sex_ontology_term_id` | PATO term | `/row_attrs/sex_ontology_term_id` |
| `self_reported_ethnicity` | Text label | `/row_attrs/self_reported_ethnicity` |
| `self_reported_ethnicity_ontology_term_id` | HANCESTRO term | `/row_attrs/self_reported_ethnicity_ontology_term_id` |
| `suspension_type` | Single-cell vs nuclei | `/row_attrs/suspension_type` |
| `tissue` | Source tissue label | `/row_attrs/tissue` |
| `tissue_ontology_term_id` | UBERON term | `/row_attrs/tissue_ontology_term_id` |
| `tissue_type` | `tissue`, `organoid`, `cell line`, … | `/row_attrs/tissue_type` |
| `array_row`, `array_col` | Visium spot indices | `/row_attrs/array_row`, `/row_attrs/array_col` |
| `in_tissue` | Visium flag | `/row_attrs/in_tissue` |
| `genetic_perturbation_id` | References global perturbations | `/row_attrs/genetic_perturbation_id` |
| `genetic_perturbation_status` | `control`, `perturbation`, etc. | `/row_attrs/genetic_perturbation_status` |
| `cell_type_annotation` or other curator-added labels | Free-form | `/row_attrs/{name}` |

> Categorical helper arrays (e.g. `{field}_categories`, `{field}_colors`) also live under `/row_attrs/`.

### 2.2 Gene-Level (`var` / `raw.var`) Metadata → `/col_attrs/`

| Metadata name | Description | Loom path |
| --- | --- | --- |
| `feature_id` / `feature_name` | Stable gene ID / display symbol | `/col_attrs/feature_id`, `/col_attrs/feature_name` |
| `feature_type` | Gene vs spike-in | `/col_attrs/feature_biotype` |
| `feature_length` | Median transcript length | `/col_attrs/feature_length` |
| `feature_is_filtered` | Flag for masked genes | `/col_attrs/feature_is_filtered` |
| `gene_version_removed` (implicit) | Ensure IDs lack ENS version suffix | `/col_attrs/feature_id` |
| `feature_reference` (if supplied) | Reference genome | `/col_attrs/feature_reference` |

If separate raw metadata are required, duplicate the same arrays or store them in `/layers/raw/attrs/{name}` and note the location in a global attribute.

### 2.3 Dataset-Level (`uns`) Metadata → Global Attributes

| Metadata name | Purpose | Loom global attribute |
| --- | --- | --- |
| `schema_version` | Must be `7.1.0` | `schema_version` |
| `title` | Dataset title | `title` |
| `dataset_id` | Stable dataset identifier | `dataset_id` |
| `collection_id`, `collection_name` | Parent collection info | `collection_id`, `collection_name` |
| `organism_ontology_term_id` | Primary organism | `organism_ontology_term_id` |
| `default_embedding` | Key of embedding to show | `default_embedding` |
| `layer_descriptions` / `matrix_layers` | Raw vs normalized mapping | `matrix_layers` (JSON) |
| `genetic_perturbations` | Dict of perturbation metadata | `genetic_perturbations` (JSON or flattened keys `genetic_perturbations/{id}/role`, etc.) |
| `raw_schema_version` or `schema_lint_version` | Export metadata | same key names |
| `citation` / `publication_doi` / `primary_data_source` | Provenance | same key names as `uns` |

Nested objects (e.g. `spatial`, `contributors`) should be flattened using slash-delimited keys (`spatial/is_single`) or stored as JSON strings referenced by the same key name.

## 2. Additional Adjustments for Loom Compliance

- **Categorical data**: Loom does not natively store pandas categoricals. Serialize categories via:
  - `/row_attrs/{field}` string array containing the category label for each cell.
  - Optional `/row_attrs/{field}_categories` array to retain the ordered list used for colors and legends.
- **Color palettes**: Store `{field}_colors` arrays under `/row_attrs/` (or `/col_attrs/`) with the same ordering as the `{field}_categories` array.
- **Sparse matrices**: Loom matrices are chunked dense datasets; to honor CXG requirements about ≥50 % sparsity encoding, keep the input csr matrix during processing, but write chunks in Loom using compression (LZF) to minimize file size.
- **Raw/normalized linkage**: Because Loom lacks `raw` namespaces, document which `/layers/` entry represents “raw” vs “normalized” in the global attribute `matrix_definitions` (JSON) or reuse `/layers/raw` naming consistently.
- **Global attributes**: Mirror every required `uns` key as `/<attr>` on the file root. Nested dictionaries (e.g. `spatial`) can be flattened with slash- or dot-separated keys (e.g. `spatial/is_single`, `spatial/array_id`). Use JSON strings for structures that cannot be flattened cleanly (make sure to note UTF-8 encoding).
- **Unique name enforcement**: Loom allows arbitrary attribute names—ensure schema-reserved names remain unique and avoid double definitions that might exist in AnnData column namespace.
- **Index alignment**: Loom requires row/column attributes to align strictly with `/matrix`. Perform the same barcode/gene filtering on all layers before exporting to Loom so that `/row_attrs` and `/col_attrs` stay consistent with CXG rules.

## 3. Features Without First-Class Loom Support

| Feature | Impact | Suggested Workaround |
| --- | --- | --- |
| `obsp` / `varp` (pairwise matrices) | Loom has no built-in two-dimensional attribute groups | Store each matrix under a custom group such as `/pairwise/obsp/{key}` with dataset shape `(n_cells, n_cells)` or persist the matrix as an auxiliary `.npz` referenced via global attribute (`pairwise_obsp_{key}_uri`). |
| Hierarchical `uns` dictionaries | Loom attributes are flat key/value | Flatten hierarchy using slash-delimited keys (`spatial/scale_factor_tissue_hires`). For deeply nested data (e.g. `organism_metadata`) encode as JSON strings and document the schema in `global_attribute_schema`. |
| pandas `CategoricalDtype` metadata (ordering, codes) | Loom stores only raw arrays | Persist `{field}_categories` and `{field}_category_codes` arrays. When loading, rebuild the categorical with pandas using these helpers. |
| Mixed dtypes within a single column (e.g. strings + NaN) | Loom requires homogeneous array dtypes | Cast to string and use sentinel values (`"na"` or `"unknown"`) per CXG rules. |
| `raw.var` distinct from `var` | Loom does not have a second gene table tied to `/layers/raw` | Duplicate required columns into `/col_attrs/` and record the raw/normalized relationship in a global attribute (e.g. `raw_var_fields=["feature_is_filtered"]`). |
| Sparse neighbor graphs (from `uns['neighbors']`) | No canonical storage | Store adjacency lists in `/row_attrs/neighbors_indices` & `/row_attrs/neighbors_distances`, or export `.npz` graph referenced by a global attribute. |

## 4. Loom Compliance Checklist

1. **Create core datasets**
   - `/matrix`: normalized (or canonical) matrix.
   - `/layers/raw`: raw counts matrix (same shape and ordering).
2. **Populate attributes**
   - `/row_attrs/CellID`, `/col_attrs/GeneID` with unique identifiers.
   - All required schema fields under `/row_attrs/` and `/col_attrs/`.
   - Embeddings as `/row_attrs/{embedding_name}` with shape `(n_cells, ≥2)`.
3. **Encode categories and colors**
   - `{field}` string array + `{field}_categories` list + `{field}_colors` palette where applicable.
4. **Write global attributes**
   - Flatten every required `uns` key (e.g. `title`, `default_embedding`, `schema_version`).
   - Include JSON blobs for complex structures and document encoding.
5. **Document raw/normalized mapping**
   - Global attribute `matrix_layers = {"raw": "/layers/raw", "normalized": "/matrix"}` (JSON).
6. **Handle non-transposable features**
   - Record locations of pairwise matrices or neighbor graphs via `*_uri` attributes if stored externally.
7. **Validate**
   - Re-run schema validations against `cxg_7.1.0_loom.md`.
   - Spot-check that Loom consumers (loompy, loomR) can load attributes without dtype coercion failures.

Following this guide should keep Loom exports compliant with the H5AD-based schema expectations while highlighting where manual documentation or auxiliary files are required.

## 5. Deterministic Loom -> H5AD Reconstruction Contract

To ensure conversion can rebuild proper AnnData fields without heuristics, Loom files SHOULD embed a global JSON manifest:

- Global attribute key: `anndata_mapping`
- Type: JSON object
- Role: explicit path contract between Loom datasets and AnnData slots

### 5.1 Required manifest keys

| Key | Type | Purpose |
| --- | --- | --- |
| `version` | `str` | Mapping schema version |
| `orientation` | `str` | Matrix orientation (`genes_x_cells` for ASAP Loom) |
| `x_path` | `str` | Path to main matrix (usually `/matrix`) |
| `obs_path` | `str` | Prefix for observation metadata (ASAP: `/col_attrs`) |
| `var_path` | `str` | Prefix for variable metadata (ASAP: `/row_attrs`) |
| `obs_index_key` | `str` | Observation index key (e.g. `CellID`) |
| `var_index_key` | `str` | Variable index key (e.g. `feature_id`) |

### 5.2 Required when present

| Key | Purpose |
| --- | --- |
| `raw_x_path` | Path for raw matrix (`raw.X`) |
| `raw_var_path` | Path for raw variable metadata table |
| `layers` | Mapping `layer_name -> loom_path` |
| `obsm` | Mapping `obsm_key -> loom_path` |
| `varm` | Mapping `varm_key -> loom_path` |
| `obsp` | Mapping `obsp_key -> loom_path` |
| `varp` | Mapping `varp_key -> loom_path` |

### 5.3 Conversion behavior (how to apply metadata)

The conversion tool MUST follow the manifest as source of truth:

1. Read and validate `anndata_mapping`.
2. Resolve paths exactly as declared (no path guessing/fallback).
3. Build `adata.X` from `x_path` with orientation-aware transpose as needed.
4. Build `adata.obs` from `obs_path/*`, using `obs_index_key` as `.obs_names`.
5. Build `adata.var` from `var_path/*`, using `var_index_key` as `.var_names`.
6. Build `adata.layers` from manifest `layers`.
7. Build `adata.raw` from `raw_x_path` and `raw_var_path` (or declared raw-var strategy).
8. Build `adata.obsm`, `adata.varm`, `adata.obsp`, `adata.varp` from declared mappings.
9. Copy global metadata to `adata.uns`, decoding JSON for keys declared as JSON entries.
10. Run post-conversion validations required by target schema.

### 5.4 Validation requirements after conversion

After reconstructing H5AD, converter (or post-step validator) SHOULD enforce:

- index uniqueness (`obs_names`, `var_names`)
- matrix/layer alignment
- pairwise matrix shape checks for `obsp`/`varp`
- required metadata presence
- AnnData-specific encoding checks (dtype/sparsity/categories)

### 5.5 Why this contract is needed

Without an explicit manifest, conversion tools must infer orientation and metadata paths. That inference is fragile and can silently misplace fields (`obs` vs `var`) or fail to reconstruct optional AnnData slots (`raw`, `obsp`, `varp`, `varm`, `obsm`) in a schema-valid way.

