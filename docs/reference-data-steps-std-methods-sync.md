# Step and StdMethod reference synchronisation

This document describes how to copy **Step**, **StdMethod**, and related reference rows (**Version**, **DockerImage**, **DockerBuild**, **Speed**) from development into **production**.

| Piece | Location |
|-------|----------|
| Preferred apply | `bin/rake reference_data:steps_std_methods:sync_from_dev` |
| Apply implementation | `src/lib/reference_data_steps_std_methods_sync.rb`, `src/lib/tasks/reference_data_steps_std_methods_sync.rake` |
| Export / compare snapshots | `bin/rake reference_data:export` / `reference_data:compare` (still useful for diffs; not the preferred apply path) |

## Preferred path: `sync_from_dev`

ASAP keeps **multiple Step rows with the same `name`** (one per pipeline version, e.g. `parsing` for versions 4–8). Sync must therefore match by **primary key id**, not by name alone.

**`reference_data:steps_std_methods:sync_from_dev`** reads the development database directly, filters by `version_id` / version `id` **&lt; `MAX_VERSION_ID`** (default **9**), and applies Step, StdMethod, Version, DockerImage, and DockerBuild onto production.

Run inside the `website` service with the Compose file that talks to production (often `docker-compose.prod.yml`). Ensure `DEV_POSTGRES_DB` (and host/port if needed) is set so the container can reach the development database.

```bash
# Dry run (transaction rolled back)
docker compose -f docker-compose.prod.yml exec website \
  bash -lc 'RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync_from_dev DRY_RUN=1'

# Field-level diffs
docker compose -f docker-compose.prod.yml exec website \
  bash -lc 'RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync_from_dev DRY_RUN=1 VERBOSE=1'

# Apply for real
docker compose -f docker-compose.prod.yml exec website \
  bash -lc 'RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync_from_dev'
```

Optional: `MAX_VERSION_ID=9`, `DEV_POSTGRES_DB=asap2_development`, `DEV_DB_HOST`, `DEV_DB_PORT`.

Hidden steps are included; obsolete std methods are excluded. The task requires `RAILS_ENV=production` so the write target is production.

### What it updates

- **Creates** / **updates** `Step`, `StdMethod`, and `Version` (matched by **id**).
- **Creates** / **updates** `DockerImage` (matched by `name`+`tag`, with id fallback) and `DockerBuild` (matched by **digest** only). New digests are inserted; existing digests are never rewritten or deleted; only non-identity fields (e.g. tag, `docker_image_id`) may update on a digest match. Source primary keys are not forced. All DockerImage/DockerBuild rows from the source DB are included (not filtered by `MAX_VERSION_ID`).
- **Does not delete** anything on the target.

Foreign keys (`docker_image_id`, `version_id`, `speed_id`) are remapped when source and target ids differ.

## Other direct DB-to-DB tasks

These still support `DRY_RUN=1` and `VERBOSE=1`.

### Production legacy → development (`sync_legacy_versions_to_dev`)

Applies production Step/StdMethod (and related rows) with `version_id < MAX_VERSION_ID` (default **8**) onto the **current** DB. Requires **not** `RAILS_ENV=production` (typically `development`). Set `PROD_POSTGRES_DB` or `SOURCE_DATABASE_URL` (optional `PROD_DB_HOST` / `PROD_DB_PORT`).

```bash
docker compose -f docker-compose.test.yml exec -e RAILS_ENV=development website \
  bin/rake reference_data:steps_std_methods:sync_legacy_versions_to_dev \
  PROD_POSTGRES_DB=asap2_production DRY_RUN=1
```

### Compare without writing (`compare_legacy_versions`)

Compares Step/StdMethod with `version_id < MAX_VERSION_ID` (default **8**) between the source DB and the current DB. Exits with status 1 if differences exist. Optional `OUT=/path/to/report.json`, `VERBOSE=1`.

```bash
docker compose -f docker-compose.test.yml exec -e RAILS_ENV=production website \
  bin/rake reference_data:steps_std_methods:compare_legacy_versions \
  DEV_POSTGRES_DB=asap2_development VERBOSE=1 OUT=/tmp/legacy-diff.json
```

## Related tooling (export / compare)

- **`bin/rake reference_data:export`** — build a JSON snapshot (`LABEL`, `OUT`, optional `MODELS`, `INCLUDE_TIMESTAMPS`). Useful for inspection or `reference_data:compare`, not for the preferred apply path.
- **`bin/rake reference_data:compare`** — compare two snapshots without touching the database (`LEFT`, `RIGHT`, optional `OUT`, `MODELS`).

## OBSOLETE: name-based `reference_data:steps_std_methods:sync`

**Do not use for day-to-day dev → production.** This older task matches Steps by **name** only. A full multi-version export has duplicate names (`parsing` once per version) and the task aborts. Prefer **`sync_from_dev`**.

The task still exists for exceptional cases (e.g. a hand-built snapshot with unique step names). It prints an obsolete warning when run. The same name-based mode in `ReferenceDataStepsStdMethodsSync` (no `max_version_id`) is marked obsolete in code comments and emits a warning.

Legacy invocation (not recommended):

```bash
docker compose -f docker-compose.test.yml exec -e RAILS_ENV=production website \
  bin/rake reference_data:steps_std_methods:sync SNAPSHOT=/tmp/ref.json DRY_RUN=1
```

## Troubleshooting

- **Duplicate step names in snapshot** — expected when using the obsolete name-based `sync` on a full export. Use **`sync_from_dev`** instead.
- **`sync_from_dev` refuses to run** — it requires `RAILS_ENV=production` so the write target is production.
- **`sync_legacy_versions_to_dev` refuses to run** — it refuses `RAILS_ENV=production` so the write target is not production.
- **Docker image remap errors** — ensure production has a `DockerImage` with the same **`name`** and **`tag`** as in development (or allow the sync to create it).
- **Version remap errors** — with `sync_from_dev`, versions are matched by id; keep version primary keys aligned between dev and prod when possible.
