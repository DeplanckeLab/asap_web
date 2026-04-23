# Step and StdMethod reference synchronisation

This document describes how to copy **Step** and **StdMethod** definitions from one Rails environment (for example staging or development) into another (typically **production**) using a JSON snapshot and a rake task.

The snapshot format is the same as produced by **`reference_data:export`** (implemented by `ReferenceDataCompare` in `src/lib/reference_data_compare.rb`). The apply step is implemented by **`ReferenceDataStepsStdMethodsSync`** (`src/lib/reference_data_steps_std_methods_sync.rb`) and invoked via **`reference_data:steps_std_methods:sync`** (`src/lib/tasks/reference_data_steps_std_methods_sync.rake`).

## What the sync does

- **Creates** production `Step` rows that do not exist yet (matched by step **name**).
- **Updates** existing production `Step` rows when any exported column differs (again keyed by **name**).
- **Creates** production `StdMethod` rows that do not exist for the target step (matched by **step name** plus std method **name**).
- **Updates** existing production `StdMethod` rows when exported data differs.
- **Does not delete** anything on the target database. Extra steps or std methods that exist only in production are left unchanged.

Foreign keys (`docker_image_id`, `version_id`, `speed_id`) are **remapped** on the target so that numeric ids from the source environment are resolved to the correct rows in production (see below).

## Snapshot requirements

The JSON file must contain at least:

- `records.Step` — array of step hashes (as exported).
- `records.StdMethod` — array of std method hashes.

Whenever a non-null **`docker_image_id`** appears on any step or std method in the snapshot, the file must also include the corresponding **`DockerImage`** rows under `records.DockerImage`, so each referenced id can be resolved to production by **`name` and `tag`**.

Whenever a non-null **`version_id`** appears:

- If production already has a `Version` with the **same primary key**, that id is kept.
- Otherwise the snapshot must include **`records.Version`** for that id, and production must match **uniquely** either by **`description`** or by the pair **`release_date` + `beta`**. If neither yields exactly one row, the sync aborts with an error.

Whenever a non-null **`speed_id`** appears on a std method:

- If production already has a `Speed` with the **same primary key**, that id is kept.
- Otherwise the snapshot must include **`records.Speed`** for that id, and production must have a **`Speed`** with the same **`name`**.

**Recommended export** from the source environment (adjust `LABEL` and `OUT`):

```bash
bin/rake reference_data:export LABEL=dev OUT=/tmp/ref.json \
  MODELS=Step,StdMethod,DockerImage,Version,Speed
```

You can omit `Version` or `Speed` from `MODELS` only if no non-null `version_id` or `speed_id` appears in the exported steps and std methods (or those ids already exist unchanged on production).

The default export omits `created_at` and `updated_at`; that is fine for sync. To include timestamps, add `INCLUDE_TIMESTAMPS=1` to the export (the sync still keys off logical fields, not timestamps).

## Rake task: apply or dry run

All commands are run from the application directory (for example `src/`) with **`bin/rake`**, in the target environment (set **`RAILS_ENV=production`** when applying to production). If you normally run Rails through Docker Compose, use the same service you use for other rake tasks.

### Environment variables

| Variable    | Required | Meaning |
|------------|----------|---------|
| `SNAPSHOT` | Yes      | Absolute or relative path to the JSON snapshot file. |
| `DRY_RUN`  | No       | Set to `1` to perform all checks and print intended creates/updates, then **roll back** the transaction so **no data is written**. |
| `VERBOSE`  | No       | Set to `1` to print per-column differences for rows that would be updated (with `DRY_RUN=1` or on real apply). |

### Examples

Dry run (recommended before production apply):

```bash
RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync SNAPSHOT=/tmp/ref.json DRY_RUN=1
```

Dry run with field-level detail:

```bash
RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync SNAPSHOT=/tmp/ref.json DRY_RUN=1 VERBOSE=1
```

Apply changes:

```bash
RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync SNAPSHOT=/tmp/ref.json
```

If `SNAPSHOT` is missing, the task prints usage and exits with status 1.

## Matching rules and ordering

- **Steps** in the snapshot must have **unique `name`** values. Duplicate names in the snapshot cause the sync to abort.
- On production, at most **one** `Step` per `name` is allowed for the sync to proceed. If multiple rows share the same name, fix the data manually first.
- **Std methods** are tied to steps via the snapshot’s `step_id`; that id is translated to the **step `name`** in the snapshot, then to the production **`Step`** with that name. The production **`std_methods.step_id`** is set from that row.
- **Std methods** are matched on production by **`(step_id, name)`**. Multiple rows for the same pair cause the sync to abort.

Processing order: **all steps first**, then **all std methods**, so new steps exist before std methods that reference them.

### Dry run and brand-new steps

In dry run mode, new steps are **not** inserted, so std methods that belong only to those future steps cannot be attached to a real `step_id` yet. For those rows the task prints a **create** line noting that the std method would be created **after** the new step in the same run. On a real apply, steps are created first, so those std methods are created normally.

## JSON columns

Exported JSON/text columns may appear in the snapshot as structured objects (arrays or hashes). Before save, the sync serialises them back to JSON strings for columns such as `attrs_json`, `command_json`, and similar fields on `Step` and `StdMethod`. Comparisons normalise JSON text so equivalent content does not trigger unnecessary updates.

## Related tooling

- **`bin/rake reference_data:export`** — build the snapshot (`LABEL`, `OUT`, optional `MODELS`, `INCLUDE_TIMESTAMPS`).
- **`bin/rake reference_data:compare`** — compare two snapshots without touching the database (`LEFT`, `RIGHT`, optional `OUT`, `MODELS`).

## Troubleshooting

- **Missing `records[Step]` or `records[StdMethod]`** — export with at least `MODELS=Step,StdMethod,...`.
- **Docker image remap errors** — include `DockerImage` in the export; ensure production has a row with the same **`name`** and **`tag`** as in the snapshot.
- **Version remap errors** — include `Version` in the export when ids differ, or align version primary keys; ensure `description` or `release_date`+`beta` identifies exactly one production version.
- **Speed remap errors** — include `Speed` in the export when `speed_id` differs; ensure production has a `Speed` with the same **`name`** (see `app/models/speed.rb`).
- **Unknown model `Speed`** — the application must define the `Speed` ActiveRecord model for exports that list `Speed` in `MODELS`.
