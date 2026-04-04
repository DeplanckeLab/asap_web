# Pending Database Migration Steps

All database schema and data changes to apply on production, in order.

Run each step from the host with `docker-compose exec website bin/rake ...`.

Last updated: 2026-02-20

---

## Step 1 -- Schema migrations

A single `db:migrate` applies all pending migrations in chronological order:

```bash
docker-compose exec website bin/rake db:migrate
```

Migrations included (oldest first):

| Timestamp | File | What it does |
|-----------|------|-------------|
| 20250111000000 | add_slurm_job_id_to_runs | Adds `slurm_job_id` column to `runs` |
| 20260106044755 | add_row_label_and_col_label_to_project_types | Adds `row_label`, `col_label` to `project_types` |
| 20260115080259 | set_multiple_runs_false_for_v8_steps | Sets `multiple_runs = false` on v8 steps (rank 6-16) |
| 20260128181623 | set_cell_scatter_steps_hidden | Sets `hidden = true` on `cell_scatter` steps |
| 20260204000000 | populate_status_icons | Populates `icon_class` on `statuses` |
| 20260204000001 | add_status_icon_styles | Adds `icon_spin`, `active_color`, `inactive_color` to `statuses` |
| 20260206000000 | add_label_template_to_data_classes | Adds `label_template` to `data_classes` + populates values |
| 20260206000001 | add_category_to_data_classes | Adds `category` to `data_classes` + populates values |
| 20260212173146 | create_compliance_mappings | Creates `compliance_mappings` and `compliance_term_replacements` tables |
| 20260212173655 | add_field_group_id_to_ontology_term_types | Adds `field_group_id` to `ontology_term_types` + maps existing records |
| 20260213110343 | add_versioning_to_annots | Adds `version_nber`, `latest_version` to `annots` |
| 20260216121220 | add_compliance_fields_to_ontology_term_types | Adds compliance config columns to `ontology_term_types` + creates new OTT records (organism, title, tissue_type, suspension_type, donor_id, is_primary_data) |
| 20260217060145 | set_multi_value_for_tissue_and_cell_type | Sets `multi_value = true` for tissue and cell_type OTTs |
| 20260217100000 | add_ontology_term_type_id_to_compliance_mappings | Adds `ontology_term_type_id` column + FK to `compliance_mappings` |
| 20260218170000 | create_compliance_schemas | Creates `compliance_schemas` table (replaces env_json compliance config) |
| 20260218180000 | create_compliance_validations | Creates `compliance_validations` table (validation history log) |
| 20260218180001 | add_compliance_schema_id_to_compliance_mappings | Adds `compliance_schema_id` FK to `compliance_mappings` |
| 20260218200000 | rename_valid_to_passed_in_compliance_validations | Renames `valid` column to `passed` (ActiveRecord conflict) |
| 20260218201000 | add_result_digest_to_compliance_validations | Adds `result_digest` (MD5) column for change detection |

---

## Step 2 -- YAML-based data updates

Applies one-off record updates defined in `db/data_updates.yml`:

```bash
docker-compose exec website bin/rake db:apply_data_updates
```

Currently sets `has_std_view = false` on the `parsing` step.

---

## Step 3 -- Version env_json: set default schema version

Ensures every `Version` record has `cxg_schema_version` set in its `env_json`
(defaults to `7.1.0`). Idempotent -- skips records that already have it.

```bash
docker-compose exec website bin/rake versions:set_cxg_schema_version
```

---

## Step 4 -- Version env_json: migrate to compliance structure

Restructures `env_json` from the old flat `validation` / `cxg_schema_version`
layout into the new nested `compliance` structure. Idempotent.

```bash
docker-compose exec website bin/rake versions:migrate_compliance_structure
```

---

## Step 5 -- Version env_json: rebrand to scFAIR

Replaces CELLxGENE references in the `compliance` section with scFAIR
(source_url, source_schema_name, description). Must run after step 4.
Idempotent.

```bash
docker-compose exec website bin/rake versions:update_compliance_to_scfair
```

---

## Step 6 -- Seed compliance_schemas from env_json

Reads the compliance config from Version env_json (populated by steps 3-5)
and creates ComplianceSchema records. Must run after step 1 (creates the table)
and after step 5 (env_json has the final scFAIR values). Idempotent.

```bash
docker-compose exec website bin/rake compliance_schemas:seed_from_env_json
```

After this step, compliance config is served from the `compliance_schemas`
table. The `compliance` key in Version env_json is no longer read by the app.

---

## Step 7 -- Load ontology terms

Downloads and imports ontology terms from OBO files. This is needed if
ontology data is stale or missing (especially for new ontologies added to
`cell_ontologies`).

```bash
docker-compose exec website bin/rake load_ontologies
```

---

## Step 8 -- Compute ontology lineage and relationships

Computes `parent_term_ids`, `lineage`, and `children_term_ids` for all
`CellOntologyTerm` records. Must run after step 7.

```bash
docker-compose exec website bin/rake extract_ids_from_ontologies
```

---

## Step 9 -- Backfill compliance mapping OTT references

Populates `ontology_term_type_id` on `compliance_mappings` records that were
created before that column existed. Must run after step 1 (migration adds the
column) and after step 7 (OTT records must have `field_group_id`).

```bash
docker-compose exec website bin/rake compliance:backfill_mapping_ott
```

---

## Step 10 -- Set project type for public single-cell projects

Sets `project_type_id = 1` (Single-cell transcriptomics) for public projects
with more than 100 columns that don't already have it.

```bash
docker-compose exec website bin/rake projects:set_single_cell_for_public
```

---

## Step 11 -- Update integration std_method

Updates all `integration` std_methods:
- Adds `allowed_downstream_steps: ["umap", "clustering"]` to `obj_attrs_json`,
  restricting integrated projects so that only UMAP and Clustering steps are
  unlocked after integration (skipping Filtering, Normalization, Scaling, PCA, etc.)
- Updates the R script name from `integration.R` to `integration.v8.R` in `command_json`

Idempotent.

```bash
docker-compose exec website bin/rake std_methods:update_integration
```

---

## Step 12 -- Fix parsing matrix data classes

Backfills missing `num_matrix` or `int_matrix` data class on parsing `/matrix`
annotations that only have `dataset`. The correct type is read from each run's
`output_json`. Without this fix, the Cell filtering step appears locked on
affected projects.

```bash
docker-compose exec website bin/rake projects:fix_parsing_matrix_data_classes
```
