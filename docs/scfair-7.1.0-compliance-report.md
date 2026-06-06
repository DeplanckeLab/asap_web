# scFAIR 7.1.0 Compliance Report (ASAP validator coverage)

## Scope

This report compares the **scFAIR core schema 7.1.0** ([`schema.md`](https://github.com/scFAIR/scFAIR/blob/main/schema/7.1.0/schema.md)) with ASAP’s **Loom cell metadata compliance validator**:

* Validator: `ScfairLoomValidatorService` (`src/app/services/scfair_loom_validator_service.rb`)
* Shared cross-field rules: `ScfairSchemaRules` (`src/app/models/concerns/scfair_schema_rules.rb`)

The validator focuses on Loom/ASAP metadata paths:

* Cell metadata: `/col_attrs/*` (ASAP matrix orientation: **genes × cells**, cells are columns)
* Gene metadata (not validated today): `/row_attrs/*`
* Global metadata: `/attrs/*`

It is **not** a full AnnData/H5AD validator for `X`, `var`, `obsm`, `obsp`, `varm`, `varp`, or AnnData-specific encodings.

Related ASAP docs:

* H5AD-centric CXG reference: `src/public/cxg_7.1.0.md`
* Loom-centric CXG reference (cells = `/row_attrs/`): `src/public/cxg_7.1.0_loom.md`
* Path mapping notes: `src/public/loom_conversion_notes.md`

## Format applicability (H5AD vs Loom)

scFAIR’s canonical schema is written for **AnnData/H5AD**. ASAP’s working format is **Loom**. Most **metadata rules** are format-agnostic (same field names and values); **structural/container rules** are H5AD-specific.

### Path mapping (semantic equivalence)

| scFAIR / AnnData | Standard Loom (CXG-style) | ASAP Loom (genes × cells) |
| --- | --- | --- |
| `obs` | `/row_attrs/` | `/col_attrs/` |
| `var` | `/col_attrs/` | `/row_attrs/` |
| `uns` | global attributes | `/attrs/` |
| `X` | `/matrix` | `/matrix` |
| `layers[*]` | `/layers/{name}` | `/layers/{name}` |
| `raw.X` | `/layers/raw` | `/layers/raw` |
| `obsm` | `/row_attrs/` (2-D) | `/col_attrs/` or `/row_attrs/` (2-D), if stored |
| `obsp` / `varp` | custom group / external | custom group / external |
| `.obs.index` | `/row_attrs/CellID` | `/col_attrs/CellID` (or `cell_id`, `obs_names`) |

When this report says **Both**, the rule applies to the **same metadata or matrix semantics** in either format, subject to the path mapping above.

### Column legend (added to tables below)

| Column | Meaning |
| --- | --- |
| **Format** | **Both** = metadata/semantic rule; **H5AD** = AnnData container, encoding, or slot rules only |
| **Loom** | Can the rule be checked on an ASAP Loom file as stored today? **Yes** / **Partial** / **No** / **N/A** |
| **At Loom→H5AD** | If the rule is not applicable on Loom alone, can it be enforced when converting Loom to H5AD? See [Conversion enforcement](#loom-to-h5ad-conversion-enforcement) |

### Validator implementation status (unchanged)

| Status | Meaning |
| --- | --- |
| Yes | Enforced (or substantially enforced) in `ScfairLoomValidatorService` today |
| Partial | Presence, format, or subset of constraints only |
| No | Not implemented |
| N/A | Out of validator scope (not “not applicable to Loom”) |

## Loom → H5AD conversion enforcement

ASAP generates H5AD on demand from Loom using **sceasy** inside the `asap_run` Docker image:

```ruby
# projects_controller.rb (export path)
sceasy::convertFormat(loom_file, from="loom", to="anndata", outFile=...)
```

**What conversion does:** structural mapping (Loom HDF5 → AnnData/H5AD). It does **not** run scFAIR validation or repair metadata by itself.

**What can be enforced at conversion time** (recommended approach: validate/transform the **output H5AD**, optionally after a custom post-processing step):

| Category | Enforceable at conversion? | Notes |
| --- | --- | --- |
| Metadata already in Loom (`/col_attrs`, `/row_attrs`, `/attrs`) | **Yes** (validate on H5AD) | After sceasy, same values appear under `obs` / `var` / `uns` (watch matrix transpose). Validator logic written for Loom paths can be reused on AnnData with a path adapter. |
| Metadata missing in Loom | **No** | Conversion cannot invent required fields (e.g. `ensembl_release`, `experimental_condition_*`). Must be curated in Loom (or injected in a pre-conversion ETL step). |
| AnnData encoding (CSR sparse, `dtype.kind`, categoricals) | **Partial** | Can be enforced in a **post-conversion** Python step when writing H5AD (re-encode sparse `X`, set categorical columns, dtype checks). sceasy alone does not guarantee scFAIR encodings. |
| `raw` slot + `raw.var` vs `var` | **Partial** | Only if `/layers/raw` exists and the converter maps it to `adata.raw`; otherwise must build `raw` in post-processing. |
| `obsm` / `obsp` / `varm` / `varp` | **Partial** | Only if embeddings/pairwise data were stored in Loom (2-D attrs or custom groups). sceasy may not map non-standard groups; custom export/import may be required. |
| H5AD file format / AnnData ≥ 0.8 / spec v0.1.0 | **Yes** (validate) | Check the written `.h5ad` with AnnData/`cellxgene-schema`-style tools; not checkable on Loom alone. |
| Ontology semantics (descendants, obsolete terms, sorted `||`) | **Yes** (validate) | Same as on Loom: requires a validator implementation, not sceasy. |
| PII / curator attestation | **No** | Policy; not automatable at conversion. |

**Practical recommendation:** treat **Loom validation** (metadata + ASAP paths) and **H5AD validation** (full scFAIR + AnnData structure) as two stages: comply on Loom where possible; run an H5AD validator after `convertFormat` for H5AD-only rules, using data already present in the Loom file.

## Important note on ontology pinning

The validator’s code explicitly states it **does not enforce pinned ontology versions** from Appendix B; it checks **format** and (when a project is loaded) term existence in ASAP’s ontology DB / authorized ontology sets. This applies to **Both** formats; conversion does not change ontology versioning behavior.

---

## General requirements

| Rule | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| AnnData HDF5 format, AnnData ≥ 0.8, spec v0.1.0 | H5AD | N/A | Yes (validate output) | N/A | Not meaningful on Loom; validate `.h5ad` after conversion |
| Metadata field names MUST NOT start with `__` | Both | Yes | Yes (validate) | No | Same attribute names in `/col_attrs`, `/row_attrs`, `/attrs` |
| Unique names in `obs` / `var` | Both | Yes | Yes (validate) | No | Loom: unique `/col_attrs` and `/row_attrs` names |
| Deprecated reserved names MUST NOT be present | Both | Yes | Yes (validate) | No | Same reserved names in either layout |
| Redundant metadata (STRONGLY RECOMMENDED) | Both | Partial | Partial | No | Heuristic check possible on either format; not implemented |
| No PII (curator commitment) | Both | N/A | No | No | Policy; not automatable |
| Ontology CURIE format (OBO); Cellosaurus `CVCL_` | Both | Yes | Yes (validate) | Partial | Implemented for Loom paths today |
| Obsolete ontology terms MUST NOT be used | Both | Yes | Yes (validate) | Partial | Needs explicit obsolete flag in ontology DB |
| Uberon collected/composite SHOULD guidance | Both | Yes | Yes (validate) | No | Semantic validator on either format |

---

## `X` (matrix layers)

| Rule | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| ≥50% zeros → CSR sparse encoding | H5AD | N/A | Partial | No | Enforce when **writing** H5AD (sparse `X`); Loom stores chunked dense datasets |
| All layers same shape / same cell & gene labels | Both | Partial | Yes (validate) | No | Checkable on Loom `/matrix` + `/layers/*` if layers exist; repeat on H5AD |
| Cell filtering applied to both raw and normalized | Both | Partial | Yes (validate) | No | Needs `/layers/raw` and aligned barcodes; ASAP may only have `/matrix` |
| Genes SHOULD NOT be filtered from raw | Both | Partial | Yes (validate) | No | Compare raw vs normalized layer gene sets |
| Filtered genes in normalized → zeros + `feature_is_filtered` | Both | Partial | Yes (validate) | No | Needs `/layers/raw`, normalized matrix, and `/row_attrs/feature_is_filtered` (ASAP gene attrs) |
| Extra layers same cells/genes | Both | Partial | Yes (validate) | No | Loom `/layers/{name}` equivalent to `layers` |

---

## `obs` (cell metadata)

### `obs` index

| Rule | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| Index: unique `str` observation identifiers | Both | Partial | Yes (validate) | Partial | Loom: `/col_attrs/CellID` (presence checked; uniqueness not) |

### Required fields and semantics

| Field / rule | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `assay_ontology_term_id` — required | Both | Yes | Yes | Yes | |
| `assay_ontology_term_id` — EFO descendant / Visium / scATAC rules | Both | Yes | Yes | No | Semantic validation |
| `assay` — label matches ontology term | Both | Yes | Yes | Partial | Presence only today |
| `tissue_type` — enum | Both | Yes | Yes | Yes | |
| `tissue_ontology_term_id` — required + conditional logic | Both | Yes | Yes | Partial | |
| `tissue` — label | Both | Yes | Yes | Partial | |
| `cell_type_ontology_term_id` — required | Both | Yes | Yes | Yes | |
| `cell_type_ontology_term_id` — CL descendants, banned terms, Visium+`in_tissue` | Both | Yes | Yes | No | |
| `cell_type` — conditional / label rules | Both | Yes | Yes | Partial | Legacy `is_pre_analysis` skip |
| `development_stage_ontology_term_id` — required | Both | Yes | Yes | Yes | |
| `development_stage_ontology_term_id` — `na` for cell line | Both | Yes | Yes | Partial | Validator forces `unknown`; schema says `na` |
| `development_stage_ontology_term_id` — descendant semantics | Both | Yes | Yes | Partial | Prefix hints only |
| `development_stage` — label | Both | Yes | Yes | Partial | |
| `sex_ontology_term_id` — required | Both | Yes | Yes | Yes | |
| `sex_ontology_term_id` — PATO set; C. elegans-specific | Both | Yes | Yes | Partial | |
| `sex_ontology_term_id` — `na` for cell line | Both | Yes | Yes | Yes | |
| `sex` — label | Both | Yes | Yes | Partial | |
| `self_reported_ethnicity_ontology_term_id` — required | Both | Yes | Yes | Yes | |
| `self_reported_ethnicity_ontology_term_id` — HANCESTRO/`||`/order | Both | Yes | Yes | Partial | |
| `self_reported_ethnicity` — label | Both | Yes | Yes | Partial | |
| `disease_ontology_term_id` — PATO / MONDO `||` | Both | Yes | Yes | Partial | |
| `disease` — label order | Both | Yes | Yes | Partial | |
| `experimental_condition_ontology_term_id` | Both | Yes | Yes | No | Same metadata in Loom if curated |
| `experimental_condition` | Both | Yes | Yes | No | |
| `perturbation_types` | Both | Yes | Yes | No | Perturb extension |
| `donor_id` — required; cell line `na` | Both | Yes | Yes | Partial | |
| `is_primary_data` — `bool` | Both | Yes | Yes | Partial | Loom stores strings/bools; H5AD needs `bool` dtype |
| `suspension_type` — enum | Both | Yes | Yes | Yes | |
| `suspension_type` — assay table | Both | Yes | Yes | Partial | |
| Visium: `array_row`, `array_col`, `in_tissue` | Both | Yes | Yes | Partial | Spatial extension; needs `spatial/is_single` in `/attrs` |
| `genetic_perturbation_id` / `strategy` | Both | Yes | Yes | Partial | If `/attrs/genetic_perturbations` present |

### Cross-field constraints

| Rule | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| Non-human → ethnicity `na` | Both | Yes | Yes | Partial | In `ScfairSchemaRules` |
| assay → `suspension_type` | Both | Yes | Yes | Partial | |
| `tissue_type` = cell line cascade | Both | Yes | Yes | Partial | |
| CL descendants, banned terms, sorted `||` | Both | Yes | Yes | No | Validator gap; enforceable on H5AD after convert |

---

## `obsm`, `obsp`, `var`, `raw.var`, `varm`, `varp`

| Rule | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `obsm` — ≥1 embedding; `X_{suffix}`; shape/dtype/finite/NaN | H5AD | Partial | Partial | No | Loom: 2-D arrays in attrs if stored; AnnData slot rules apply only on H5AD. sceasy may map 2-D row/col attrs → `obsm` depending on orientation |
| `obsp` / `varm` / `varp` — non-zero size | H5AD | No | Partial | No | No first-class Loom slot; only if custom groups or external URIs exist |
| `var` index — Ensembl/ERCC, strip version | Both | Yes | Yes | No | ASAP: `/row_attrs/` gene IDs (validator not implemented) |
| `raw.var` index identical to `var` | H5AD | Partial | Partial | No | Needs `adata.raw` mapping from `/layers/raw` + gene attrs |
| `feature_is_filtered` (var only) | Both | Yes | Yes | No | ASAP: `/row_attrs/feature_is_filtered` |
| `feature_biotype`, `feature_length`, `feature_name`, `feature_reference`, `feature_type`, `feature_chromosome` | Both | Yes | Yes | No | Gene metadata in `/row_attrs/` |

---

## `uns` (dataset metadata)

| Field / rule | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `ensembl_release` — required `int` | Both | Yes | Yes | No | `/attrs/ensembl_release` |
| `ensembl_database` — required enum | Both | Yes | Yes | No | `/attrs/ensembl_database` |
| `ensembl_assembly` — optional | Both | Yes | Yes | No | |
| `organism_ontology_term_id` | Both | Yes | Yes | Yes | `/attrs/` |
| `organism` label | Both | Yes | Yes | Yes | |
| `title` | Both | Yes | Yes | Yes | |
| `schema_reference` — fixed URL | Both | Yes | Yes (inject) | No | Can **inject** at conversion if missing |
| `schema_version` — `7.1.0_scfair` | Both | Yes | Yes (inject) | No | Can **inject** at conversion; validator reports `7.1.0` only |
| Optional: `analysis_pipeline`, `batch_condition`, `citation`, `{column}_colors`, `default_embedding`, `X_approximate_distribution` | Both | Yes | Yes | No | If present in `/attrs/`; optional rules validate when key exists |

---

## Extension schemas (spatial, perturb, atac, analysis JSON)

| Schema | Format | Loom | At Loom→H5AD | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `schema_spatial.md` | Both | Partial | Partial | Partial | Flattened `/attrs/spatial/...`; Visium col attrs |
| `schema_perturb.md` | Both | Partial | Partial | Partial | `/attrs/genetic_perturbations` + col attrs |
| `schema_atac.md` | Both | No | Partial | No | External fragment assets; not in typical Loom |
| `schema_analysis_json.md` | Both | Yes | Yes | No | `/attrs/analysis_pipeline` JSON string |

---

## Summary by format

| Category | Rules mainly **Both** (Loom + H5AD) | Rules **H5AD-only** | Validator today (Loom) |
| --- | --- | --- | --- |
| General | Reserved names, ontology format, uniqueness | AnnData file spec version | Metadata subset only |
| `obs` / cell metadata | All required fields and cross-field semantics | `bool` dtype for `is_primary_data` | ~85% presence; ~25–35% semantics |
| `X` / layers | Alignment, filtering consistency | CSR sparse encoding | ~0% |
| `var` / genes | All `feature_*` fields | `raw.var` vs `var` linkage | ~0% |
| `obsm` / embeddings | Data may live in Loom 2-D attrs | AnnData `obsm` dtype/shape/inf rules | ~0% |
| `uns` | All required keys | Nested dict native types | ~40% (`title`, `organism_*`) |

## Highest-impact gaps

1. **Both formats:** `/attrs` (or `uns`) — `schema_version`, `schema_reference`, `ensembl_release`, `ensembl_database`
2. **Both formats:** label ↔ ontology ID consistency
3. **Both formats:** ontology semantics (descendants, banned terms, sorted `||`)
4. **Both formats:** fix cell line `development_stage_ontology_term_id` (`na` vs `unknown`)
5. **Both formats:** `experimental_condition_*`, perturbation fields
6. **Both formats:** gene metadata on `/row_attrs/` (Loom) / `var` (H5AD)
7. **H5AD export path:** post-conversion validator for AnnData structure (sparse `X`, `obsm`, `raw` slot) after sceasy `convertFormat`
