# scFAIR 7.1.0 schema gap review (ASAP validator)

Reference schema: [scFAIR 7.1.0 `schema.md`](https://github.com/scFAIR/scFAIR/blob/main/schema/7.1.0/schema.md)

Rules single source of truth: `src/config/scfair/7.1.0/rules.yaml`

Compliance pipeline: `ScfairComplianceService` (Loom + H5AD)

**Legend:** **Yes** = substantially enforced · **Partial** = presence or subset only · **No** = not implemented · **N/A** = policy / not automatable

Last updated: 2026-06-06 (AnnData format gate section added; deferred)

---

## Implementation status summary

| Area | Status | Check IDs |
| --- | --- | --- |
| General metadata naming | **Yes** | `metadata.other` |
| Schema reference URL | **Partial** | `schema.reference` (warning on mismatch) |
| Ensembl uns metadata | **Partial** | `uns.ensembl` (release int, database enum, optional assembly) |
| Core obs required fields | **Partial** | `obs.required_presence` |
| Experimental condition obs | **Partial** | `obs.experimental_condition` |
| Var gene metadata | **Partial** | `var.required` |
| Ontology format / semantics / DB | **Partial** | `ontology.*` |
| Cross-field constraints | **Partial** | `cross-field.constraints` |
| Spatial / perturb extensions | **Partial** | `extension.spatial`, `extension.perturb` |
| Matrix / layers / raw.var | **No** | — |
| AnnData format gate (≥0.8 / spec v0.1.0) | **Partial** | H5AD only; see [§10](#10-deferred-anndata-format-gate-h5ad-only) |
| Organism label ↔ term ID | **Yes** | `ontology.semantics.organism_ontology_term_id.label_pair` (organisms table) |
| obs index uniqueness | **No** | — |

---

## 1. General requirements

| Rule | Status | Notes |
| --- | --- | --- |
| AnnData ≥ 0.8, HDF5 spec v0.1.0 | **Partial** | H5AD structural checks only; full gate deferred ([§10](#10-deferred-anndata-format-gate-h5ad-only)) |
| Metadata names must not start with `__` | **Yes** | `metadata.other.reserved_prefix` |
| Unique names in `obs` / `var` | **Yes** | `metadata.other.unique_names.*` |
| Deprecated reserved names absent | **Yes** | `metadata.other.deprecated` |
| Redundant metadata (SHOULD) | **No** | Heuristic not implemented |
| No PII (policy) | **N/A** | Not automatable |
| Ontology CURIE format + CVCL | **Yes** | `ontology.format` |
| Obsolete ontology terms MUST NOT be used | **Partial** | Needs obsolete flag in ASAP ontology DB |
| Uberon collected/composite SHOULD | **No** | Not enforced |

---

## 2. `obs` — cell metadata

### Index

| Rule | Status | Notes |
| --- | --- | --- |
| Unique `str` observation identifiers | **Partial** | Loom: `/col_attrs/CellID` presence only; uniqueness not checked |

### Required fields (core)

| Field | In rules | Validator | Gaps |
| --- | --- | --- | --- |
| `assay_ontology_term_id` + `assay` | Yes | **Partial** | Semantic roots, Visium uniformity |
| `tissue_type` | Yes | **Yes** | enum OK |
| `tissue_ontology_term_id` + `tissue` | Yes | **Partial** | Organoid embryo ban; label pairs |
| `cell_type_ontology_term_id` + `cell_type` | Yes | **Partial** | Visium+`in_tissue`; banned terms differ from schema |
| `development_stage_*` | Yes | **Partial** | Cell line should be `na`, rules force `unknown` |
| `sex_*` | Yes | **Partial** | C. elegans partial |
| `self_reported_ethnicity_*` | Yes | **Partial** | sorted `||`, label order |
| `disease_*` | Yes | **Partial** | MONDO sorted `||`, label order |
| `donor_id` | Yes | **Partial** | CF-3 only |
| `is_primary_data` | Yes | **Partial** | CF-6 spatial; no `bool` dtype on H5AD |
| `suspension_type` | Yes | **Partial** | CF-1 assay map (subset of full schema table) |

### scFAIR-specific `obs` fields

| Field | Schema | Status |
| --- | --- | --- |
| `experimental_condition_ontology_term_id` | REQUIRED when any non-`na` condition; absent if all `na` | **Partial** | `obs.experimental_condition` |
| `experimental_condition` | Required when ID field present | **Partial** | presence + `na` label pairing |
| `perturbation_types` | Required when experimental_condition or genetic_perturbation_id present | **Partial** | presence + enum / `no perturbations` |
| `strain_or_genetic_background_*` | OPTIONAL | **No** | — |

### Extension `obs` fields

| Field | Location | Status |
| --- | --- | --- |
| `array_row`, `array_col`, `in_tissue` | `schema_spatial.md` | **Partial** |
| `genetic_perturbation_id`, `genetic_perturbation_strategy` | `schema_perturb.md` | **Partial** |

### Known rules.yaml mismatches

| Issue | Schema | Current rules |
| --- | --- | --- |
| Cell line `development_stage` | `na` | forces `unknown` |
| Banned cell types | `CL:0000255`, `CL:0000257`, `CL:0000548` | different set |
| `schema_version` identifier | `7.1.0+scfair1.0` | `7.1.0_scfair` + semver only |

---

## 3. `X` (matrix layers)

| Rule | Status |
| --- | --- |
| ≥50% zeros → CSR sparse | **No** |
| All layers same shape / aligned barcodes | **No** |
| Cell filtering applied to raw + normalized | **No** |
| Genes SHOULD NOT be filtered from raw | **No** |
| Filtered genes → zeros + `feature_is_filtered` | **No** |
| scATAC-specific matrix rules | **No** |

---

## 4. `obsm`, `obsp`, `varm`, `varp`

| Rule | Status | Notes |
| --- | --- | --- |
| `obsm`: ≥1 embedding for non-spatial assays | **Partial** | H5AD shape/dtype/inf only |
| `obsm/spatial` | **Partial** | Spatial extension |
| `obsp` / `varm` / `varp` non-zero size | **No** | — |
| `default_embedding` must match `obsm` key | **No** | optional `uns` |

---

## 5. `var` and `raw.var`

| Field / rule | Required | Status |
| --- | --- | --- |
| `var` index: unique feature IDs | Yes | **No** |
| Genes: Ensembl ID; strip `.version` | Yes | **No** |
| Spike-ins: `ERCC-*` | Yes | **No** |
| `raw.var` index identical to `var` | When raw present | **No** |
| `feature_is_filtered` | Yes (`var` only) | **Partial** | `var.required` presence + bool values |
| `feature_biotype` | Yes | **Partial** | presence + enum |
| `feature_length` | Yes | **Partial** | presence + uint check |
| `feature_name` | Yes | **Partial** | presence |
| `feature_reference` | Yes | **Partial** | presence + NCBITaxon format |
| `feature_type` | Yes | **Partial** | presence |
| `feature_chromosome` | Yes (scFAIR) | **Partial** | presence |
| Unique `var` column names | Yes | **Yes** | `metadata.other.unique_names.var` |

---

## 6. `uns` — dataset metadata

### Required fields

| Field | Status | Notes |
| --- | --- | --- |
| `title` | **Partial** | presence only |
| `organism_ontology_term_id` | **Partial** | format; not full species table |
| `organism` | **Partial** | presence; label paired with term ID via organisms table |
| `schema_version` | **Partial** | semver ≥ 7.1.0 |
| `schema_reference` | **Partial** | H5AD presence; URL warning |
| `ensembl_release` | **Partial** | presence + int validation (`uns.ensembl`) |
| `ensembl_database` | **Partial** | presence + enum (`uns.ensembl`) |
| `ensembl_assembly` | **Partial** | optional; non-empty when present |

### Optional `uns` (validate when present)

| Field | Status |
| --- | --- |
| `analysis_pipeline` | **Partial** (warn if absent) |
| `batch_condition`, `citation`, `{column}_colors`, `default_embedding`, `X_approximate_distribution` | **No** |

### General `uns` rule

Values MUST NOT have zero size when key is present — **No**

---

## 7. Extension schemas

| Extension | Status |
| --- | --- |
| **spatial** (`schema_spatial.md`) | **Partial** |
| **perturb** (`schema_perturb.md`) | **Partial** |
| **atac** (`schema_atac.md`) | **Partial** (warn) |
| **analysis_json** | **Partial** (warn) |

---

## 8. Recommended implementation priority (remaining)

1. ~~`uns.ensembl` value checks~~ — implemented (release, database, assembly)
2. ~~`experimental_condition_*` + `perturbation_types`~~ — partial implementation
3. ~~`var` gene metadata~~ — partial implementation (presence + basic values)
4. Label ↔ ID pairs and sorted `||` for disease/ethnicity/experimental_condition (semantics)
5. Fix cell line `development_stage` (`na` not `unknown`) and banned cell type list
6. `strain_or_genetic_background_*` optional fields
7. Matrix / layers / `raw.var` alignment
8. Obsolete ontology term enforcement
9. Optional `uns` when-present rules
10. AnnData format gate (H5AD) — deferred; see [§10](#10-deferred-anndata-format-gate-h5ad-only)

---

## 9. Suggested future check categories

| Category | Would cover |
| --- | --- |
| `h5ad.anndata_spec` | Root `encoding-type` / `encoding-version`, `n_obs`/`n_var` alignment, optional full encoding walk |
| `obs.strain` | optional strain fields |
| `var.index` | **Yes** — presence (`var/_index` or Loom `/row_attrs/Accession` / `_index`), uniqueness, ERCC/Ensembl format; gene reference at release under `var.cross_field.index.release` |
| `uns.optional` | batch_condition, default_embedding, etc. |
| `h5ad.layers` | matrix alignment, CSR, raw vs normalized |
| `ontology.obsolete` | obsolete term ban |

---

## 10. Deferred: AnnData format gate (H5AD only)

**Status:** planned for later; not implemented.

scFAIR general requirements bundle two related but distinct constraints:

1. **Writer stack:** files should be produced with **AnnData Python ≥ 0.8.0** (library that writes modern on-disk conventions).
2. **On-disk contract:** files must conform to the **[AnnData HDF5 specification v0.1.0](https://anndata.readthedocs.io/en/latest/fileformat-prose.html#anndata-specification-v0-1-0)** — root group metadata `encoding-type: anndata`, `encoding-version: 0.1.0`, plus typed encodings for every element (`dataframe`, `csr_matrix`, `categorical`, `dict`, etc.).

The spec is inspectable in the HDF5 file. The library version is **not** stored as a single attribute; it can only be **inferred** from encoding versions and conventions (e.g. `dataframe` 0.2.0 vs legacy 0.1.0), or from optional provenance in `uns`.

This gate applies to **H5AD only**. Loom has no AnnData container; validation would run on **converted H5AD** after sceasy export if needed.

### 10.1 What ASAP checks today

`ScfairH5adValidatorService` uses **h5py only** (no `ad.read_h5ad`). Relevant check categories:

| Area | Check ID(s) | Current coverage |
| --- | --- | --- |
| Root `encoding-type` / `encoding-version` | — | **No** |
| `obs` / `var` / `uns` groups | `h5ad.structure`, presence checks | **Partial** — `obs`/`uns` deeply; `var` column list only |
| `obs` `column-order` vs stored columns | `h5ad.structure` | **Yes** (subset of dataframe spec) |
| `X` shape `(n_obs, n_var)` | `h5ad.matrix_encoding` | **Partial** — shape only |
| `X` sparse CSR/CSC internals | `h5ad.matrix_encoding` | **No** (documented in UI copy, not implemented) |
| `layers` / `raw` slot | — | **No** |
| `var` dataframe encoding | `var.required` | **No** — scFAIR column names/values only, not AnnData encoding |
| Per-column HDF5 encodings | — | **Partial** — only where needed to read metadata values |
| `obsm` shape / finiteness | `h5ad.embeddings` | **Partial** |
| `varm` / `obsp` / `varp` | — | **No** |
| Recursive `encoding-type` + `encoding-version` | — | **No** |
| scFAIR matrix rules (≥50% zeros → CSR, layer alignment) | — | **No** |

So “partial” in §1 means: **scFAIR-relevant structure and metadata usability**, not full AnnData IO compliance.

### 10.2 What a full gate would comprise (three tiers)

#### Tier 1 — Container gate (small, high value)

- Root attrs: `encoding-type == "anndata"`, `encoding-version >= "0.1.0"`.
- Top-level: must have `obs` and `var`; optional slots per spec (`X`, `layers`, `obsm`, …).
- `n_obs` / `n_var` from `obs`/`var` index lengths and `X.shape` (or sparse `shape` attr) must agree.

**Effort:** ~1–2 days. **Suggested check ID:** `h5ad.anndata_spec.root`.

Covers the **HDF5 spec v0.1.0** requirement at container level only.

#### Tier 2 — Encoding walker (full on-disk spec)

- DFS over the file; every group/array has `encoding-type` and `encoding-version`.
- Type-specific rules: `dataframe` (`_index`, `column-order`), `csr_matrix`/`csc_matrix` (`data`, `indices`, `indptr`, `shape`), `categorical` (`categories`, `codes`), `dict` mappings, etc.
- Reject unknown or legacy encodings (pre–0.8 era).

**Implementation options:**

| Approach | Effort | Notes |
| --- | --- | --- |
| h5py walker in validator Python | ~1–2 weeks | Fits current architecture; must track upstream spec |
| AnnData `read_h5ad(..., backed="r")` in `asap_run` | ~3–5 days | Reference implementation; memory/time on large files |
| Upstream AnnData validation API | variable | No single public `validate_h5ad()` today |

#### Tier 3 — scFAIR semantic alignment on top of AnnData

- Infer writer era from encoding versions; fail likely pre–0.8 files.
- Schema dtypes (`bool`, `uint`, categorical `str`) at AnnData encoding level.
- Index rules (unique `obs`/`var` names; Ensembl/ERCC; `raw.var` identical to `var`).
- Matrix rules from scFAIR schema (CSR when ≥50% zeros, layers, `feature_is_filtered` cross-checks).

Overlaps with §3, §5, and planned `h5ad.layers` work — separate from pure AnnData spec.

### 10.3 Redundancy with existing checks

**Not redundant (net-new if implemented):**

- Root `encoding-type` / `encoding-version`
- Full `var` group as AnnData `dataframe`
- `layers`, `raw`, `varm`, `obsp`, `varp` structure
- Per-element encoding metadata across the tree
- Sparse `X` internal layout
- Legacy format detection
- Global `n_obs` / `n_var` alignment across all slots
- HDF5-level dtype/encoding (vs scFAIR value rules)

**Partial overlap (duplicate logic if added naïvely):**

| Existing check | Overlap |
| --- | --- |
| `h5ad.structure` | `obs` exists; `column-order`; required scFAIR fields |
| `h5ad.matrix_encoding` | `X` shape only today |
| `h5ad.embeddings` | `obsm` rows vs `n_obs`, 2D, finiteness |
| `var.required` | scFAIR `feature_*` columns, not AnnData encoding |
| `metadata.other` | unique column names, not index uniqueness |

**Not replaced by AnnData spec:** ontology format/semantics, cross-field rules, experimental condition, Ensembl, spatial/perturb extensions, organism label pair (organisms table).

A **narrow** Tier 1 gate is **not** redundant with current checks. A **full** Tier 2 walk **would** overlap `h5ad.structure` / `h5ad.embeddings` unless refactored into a **single structural pass**. The `h5ad.matrix_encoding` catalog text describes CSR/finite checks that are **not implemented**; future matrix work should be **one** module (AnnData sparse spec + scFAIR matrix rules), not three parallel checks.

### 10.4 Recommended approach when implemented

1. Add **`h5ad.anndata_spec`** (Tier 1 first) in `rules.yaml` / checks catalog.
2. Extend embedded Python in `ScfairH5adValidatorService` (or a dedicated `lib/scfair_h5ad_anndata_validator.py`).
3. Pin **`anndata>=0.8`** in `asap_run` if Tier 2 uses the library reader.
4. Keep **h5py-first** for metadata compliance; use full AnnData read only for strict mode or post-conversion validation.
5. Add fixtures: minimal valid `.h5ad`, legacy pre–0.8 file, broken sparse `X`, wrong root `encoding-version`.
6. **Consolidate** overlapping probes rather than stacking a second full file read.

**Rough effort summary:**

| Scope | Effort |
| --- | --- |
| Tier 1 only | ~1–2 days |
| Tier 2 via AnnData `backed="r"` | ~3–5 days |
| Tier 2 pure h5py walker | ~1–2 weeks |
| Tier 3 (scFAIR matrix/raw/index) | several weeks; mostly separate buckets |

**Decision (2026-06):** defer implementation; document here for future work.
