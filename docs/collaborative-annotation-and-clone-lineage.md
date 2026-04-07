# Collaborative annotation and metadata across cloned projects

## 1. Purpose

This document defines rules and a roadmap for:

1. Making **cell-level annotation** (community labels, ontology links, marker lists, votes) work well in a **collaborative** setting.
2. **Reusing** metadata across **clones** and **accessible projects**: **metadata import** (current scope) only concerns LOOM paths **`/col_attrs/...`** and **`/row_attrs/...`**. The product already supports **import from an uploaded file** (current **import metadata** flow). Planned cross-project flows add (a) discovery by shared **`cell_set_id`** and (b) **explicit source project** with multi-select; all paths should align on **collision policies** (overwrite / cancel / versioned **`.vN`** keep-both) and **reserved patterns** under those prefixes for the target **version** where applicable.
3. **Federated visibility** of **`Cla`** rows: show annotations from **all public/private projects the user can read** that share the same cell set, **without importing** duplicate `Cla` rows; **always show source project**.
4. **Same cluster or selection across clones vs. data that belongs to one project:** The **cell set** (which group of cells) can stay **the same** after a clone, so we can relate labels to that group across projects. **Metadata, runs, and files** are **separate for each project** — new rows, new paths — so we match by **cell set**, not by reusing the same metadata id or file path from another project.

It is aligned with the current Rails model: `Project` (`cloned_project_id`, `project_cell_set_id`), `Annot`, `AnnotCellSet`, `CellSet`, `Cla`, `ClaVote`, and `ProjectAuthorization`.

---

## 2. Concepts (canonical definitions)

### 2.1 Cell identity (stable across clones of the same inputs)

- **`ProjectCellSet`**: One row per project in the common case; clone uses `Project#dup`, so the **clone keeps the same `project_cell_set_id` as the source** unless changed elsewhere.
- **`CellSet`**: Belongs to `project_cell_set_id`; identified by `(project_cell_set_id, key)` where `key` is the stable hash for a set of cells (e.g. cluster / selection).
- **`cell_set_id`**: Foreign key from `annot_cell_sets` and `clas` into `cell_sets`. **Same underlying cells in a clone lineage should share the same `cell_set_id`** when `project_cell_set_id` is unchanged and `AnnotCellSet` is copied with preserved `cell_set_id` (as in `ProjectCloneService#copy_annot_cell_sets`).

**Rule C1 (identity):** Treat **`cell_sets.key` + `project_cell_set_id`** (or equivalently `cell_set_id` when valid) as the **canonical cell-set identity** for matching annotations across projects that share the same `project_cell_set`.

### 2.2 Metadata annotations (project-local, versioned)

- **`Annot`**: Per `project_id`; ties labels to loom paths, runs, versions (`latest_version`, `version_nber`, `name`, etc.).
- **`AnnotCellSet`**: Links a category (`cat_idx`) of an `Annot` (metadata) to a `CellSet`.

**Rule M1 (metadata locality):** **`annot_id` is only meaningful inside a given `project_id`**. After clone, annots are duplicated with new ids; correspondence to the source is by **clone lineage** (`cloned_project_id`) plus **logical name** / structural matching, not by shared `annot_id`.

**Rule M2 (import metadata path scope):** Cross-project **metadata import** described in section **6.3** applies **only** to metadata whose **`Annot#name`** (or equivalent LOOM path) lives under **`/col_attrs/`** or **`/row_attrs/`** (e.g. `/col_attrs/my_clustering`, `/row_attrs/Gene`). Other dataset roots (e.g. **`/matrix`**) are **out of scope** for this import feature until explicitly extended.

### 2.3 Community annotations (`Cla`)

- **`Cla`**: Stores the visible annotation (ontology, genes, comment, votes); references `cell_set_id`, `annot_id`, `project_id`.

**Rule A1 (current implementation):** In the code as it exists now, `get_annot_info` loads `Cla.active` by **`cell_set_id` only**, not by `project_id`. So **all `Cla` rows attached to that cell set are returned** in any project whose `AnnotCellSet` points at the same `cell_set_id`, without filtering by which project created each `Cla`. Section **6.2 (R-V1)** describes tightening this to **`readable?(cla.project)`** for federation.

**Rule A2 (filtering elsewhere):** `get_cell_set_annotations` restricts rows with **`readable?(cla.project)`**, so cross-project visibility follows **read access** on the **project stored on the `Cla`**.

**Rule A3 (target direction, see section 6.4):** **Do not duplicate** `Cla` rows when “bringing in” other projects’ contributions. **Aggregate in the UI/API** all `Cla` rows for the same `cell_set_id` from every project the user **can read**, and **label each row with its source project** (key, name, public id as needed). The underlying rows stay in their **original `project_id`**; provenance is always clear.

These behaviors define **per-cell-set federation** with **project-scoped read rights** on each `Cla`.

### 2.4 Votes (`cla_votes`)

- **`ClaVote`**: Optional per-user agreement on a `cla_id`; ties to `user_id` / `orcid_user_id` (see `db/schema.rb`).

**Rule V1 (who may vote):** Any **logged-in user** who **(1)** has an **associated ORCID** (same notion as elsewhere in annotation features) **and (2)** may **read** the **home project** of that `Cla` — i.e. **`readable?(cla.project)`** — may **create or update** a vote on that `Cla`. **Analyze** or full **annotate** rights on the project are **not** required to vote; read access plus ORCID is sufficient. (Same rule as **Rule P2** and section **6.7 (R-VT1)**.)

**Implementation note:** In code, **`cla_votable?`** may still follow **`annotable?(project)`** until refactored to evaluate **`readable?(cla.project)`** plus ORCID per **`Cla`**.

---

## 3. Permission model (as implemented)

Reference: `ProjectAuthorization`.

| Capability | Who (typical) |
|------------|----------------|
| **Read** project | Public; owner; share with view; sandbox session; admin; IP-restricted where applicable |
| **Export / clone** | Same as read for public/shared patterns (`exportable?` / `clonable?`) |
| **Run new analyses** (`analyzable?`) | Owner; share with analyze; sandbox session; admin — **not** mere public viewers |
| **Annotate** (`annotable?`) | Requires logged-in user with **ORCID**; **public projects**: allowed for such users; **private**: also requires `analyzable?` |

**Implication:** On a **public** project, collaborators can often **contribute annotations** (subject to ORCID) but **cannot** extend the pipeline unless the owner grants **analyze** share or they work on a **clone** they own.

**Rule P1:** Any **import or sync** of **metadata** (`Annot` / loom columns) from project B into project A must require the acting user to be **`readable?` on B`**, and any **write** to A must satisfy **`analyzable?(A)`** (or owner rules for metadata import). **`Cla` rows are not imported** under the federated model (section 6.4); only **metadata columns** may be copied into A.

**Rule P2 (votes):** Casting a **`ClaVote`** on an existing `Cla` requires **`readable?(cla.project)`** (user may see that annotation’s home project) **and** a **logged-in user with a valid ORCID association** (`orcid_user_id` present on the user side). The vote is stored against the **canonical `cla_id`** (no per-viewer copy of `Cla`).

---

## 4. Clone behavior (as implemented)

Reference: `ProjectCloneService`.

On clone, the service:

- Sets **`cloned_project_id`** to the source project.
- Copies **files**, **runs** (with id remapping), **annots**, **annot_cell_sets** (new `annot_id`, **preserved `cell_set_id`** where present).
- Does **not** duplicate **`Cla`** rows in this service; existing `Cla` rows remain tied to their original `project_id` / `annot_id` but remain reachable by **`cell_set_id`** where the UI queries that way.

**Rule K1:** For a **first-generation clone** from a public project, **cell-set–level community data** can already **appear** in the clone UI when keyed by `cell_set_id`, while **metadata rows** are **new copies** linked to the new runs/files.

**Rule K2 (identity across clone generations):** Clones **keep the same `project_cell_set_id`** as the source (`ProjectCloneService` copies it). All **`CellSet`** rows in that lineage share that **`ProjectCellSet`**, so **`project_cell_set_id`** together with **`cell_sets.key`** is already the **stable identifier** for the same cells in a **clone of a clone** as well as a **first-generation** clone. **Federation, import discovery by shared cell set, and aligning `cell_set_id` do not need `root_project_id` or walking `cloned_project_id`.**

**Note:** **`cloned_project_id`** only points to the **immediate** parent **`Project`**. That still matters for code that resolves metadata by **one hop** (e.g. **`Basic.marker_groups_annot_id`** on `cloned_project_id` + name) or for product that must pick a **specific project record** (e.g. a fixed “cited” public URL). Walking the chain or adding **`root_project_id`** would only be for those **project-level** cases — **not** for answering “is this the same cell set?” (**`project_cell_set_id`** already does).

Not sure we need to have root_project_id: I do not find a case where we need it.

---

## 5. Metadata resolution for clones (existing pattern)

Reference: `Basic.marker_groups_annot_id`.

For some operations, the code resolves **source** metadata on **`cloned_project_id`** by **`Annot.name`** (latest version). If the annot **no longer exists** on the source, it **raises**.

**Rule R1:** Any **hard dependency** on the source project retaining a specific `Annot` is **fragile** if the owner **re-runs** steps, **prunes** outputs, or **replaces** metadata versions.

**Rule R2:** Prefer **explicit stable identifiers** for cross-project metadata mapping in the long term, for example:

- **`Annot`**: immutable logical name + optional **`stable_key`** (UUID) set at creation and copied on clone; or
- **Lineage table**: `(source_annot_id, target_annot_id, clone_event_id)`.

Until then, matching by **`name` + `cloned_project_id`** remains a **best-effort** strategy with documented failure modes.

---

## 6. Proposed product rules (formal)

### 6.1 Collaborative annotation on the canonical (e.g. public) project

- **R-C1:** **New `Cla` contributions** (creating rows) on a project follow **`annotable?`** (ORCID; on private projects also **`analyzable?`**). **`cla_votes`** on **existing** rows follow **Rule V1** / **section 6.7** (**readable?** + ORCID), which is **broader** than **`annotable?`** for viewers who only have read access.
- **R-C2:** **Runs that create or replace metadata** follow **`analyzable?`**. Owners may **delegate analyze** via shares to trusted collaborators instead of forcing clones.
- **R-C3:** Display **provenance**: each `Cla` should remain attributable (`user_id`, `orcid_user_id`, `project_id`) and the UI must show **which project** owns the row when listing federated cell-set data (**R-F2**).

### 6.2 Annotation visibility across projects with the same cells

- **R-V1 (adopted direction):** For a given **`cell_set_id`**, show **`Cla.active`** from **every** project where the current user is **`readable?(cla.project)`**. **Do not** create duplicate `Cla` rows in the viewer’s project; **merge for display** and attach **source project** metadata (key, display name) to each row. Align **`get_annot_info`** with this filter so security matches **`get_cell_set_annotations`**.
- **R-V2:** **Forks:** Clones share **`cell_set_id`** when `project_cell_set_id` is unchanged; federated CLA lists naturally include rows whose **`project_id`** is the canonical public project, a clone, or any other readable project in the lineage.

### 6.3 Import metadata (uploaded file and cross-project discovery)

**Metadata import** can bring **`Annot` / loom metadata** onto the **target** project for paths under **`/col_attrs/`** and **`/row_attrs/`** (**Rule M2**) in more than one way:

- **Uploaded file (existing):** User supplies a file through the current **import metadata** UI; the app runs the same **`prepare_metadata` / `do_import_metadata`** (and related) pipeline as today. No cross-project **discovery** step; compatibility and authorization follow the **existing** upload path.
- **Modes A and B (planned):** Cross-project **discovery** from other projects the user can read — separate from clone copy and separate from **CLA federation**.

**Common preconditions** (where they apply)

- **R-MS (eligible metadata):** Only **`Annot`** candidates whose names match **`/col_attrs/...`** or **`/row_attrs/...`** participate in discovery, compatibility checks, and import. Other paths are excluded from the UI lists and rejected by **`MetadataNameAuthorizationService`** for this feature.
- **R-M2 (cross-project modes A and B):** User must be **`readable?`** on every **source** project used; user must be **`analyzable?`** (or owner) on the **target** project. Validate **row counts / matrix compatibility** before write (same rules as existing metadata import; **R-N1** applies). **Uploaded-file import** does not use **R-M2** as stated here; it uses the **existing** target-project and file checks for that flow.
- **R-M3 (not CLA):** These paths **do not copy** `Cla` records. After import, **federated CLA UI** (section 6.4) still shows other projects’ `Cla` rows for the same **`cell_set_id`** when readable.

#### 6.3.1 Mode A — discovery by shared `cell_set_id`

- **R-M1a (scope):** From the **current** project context (cell set / metadata column), discover **all other projects** the user can **read** that share the same **`cell_set_id`** (equivalently **`cell_sets.key`** within the same **`project_cell_set_id`**). List **compatible** `Annot` candidates from those projects for import (multi-select).

#### 6.3.2 Mode B — explicit source project

- **R-M1b (scope):** User chooses a **specific** source **project** (by key, search, or recent list), subject to **`readable?`**. The system lists **compatible** metadata (`Annot` rows / columns) from **that project only**; user selects **one or several** to import.
- **R-M1c (compatibility):** “Compatible” means the same constraints as Mode A (e.g. matching **`project_cell_set_id`** / cell alignment, dimensions, loom scope). Incompatible rows are **not** offered or are shown disabled with **explicit** reason (**R-N1**).

#### 6.3.3 Uploaded file (current import metadata)

- **R-M0 (existing):** Users can already import metadata by **uploading a file** in the project’s **import metadata** flow. That path is **not** a third “discovery mode” from another ASAP project; it is the **current** mechanism for bringing column/row attributes from an external file into the target project, subject to the same **version** and validation stack as **`prepare_metadata` / `do_import_metadata`**. **Collision handling**, **reserved names** (**R-NM1–R-NM4**), and **overwrite safety** (**R-M5**) should stay **consistent** with this flow when extending the UI so users are not surprised when switching between **upload** and **cross-project** import.

#### 6.3.4 Name collision on the target project

When the **logical metadata name** (typically `Annot#name` / loom column basename) **already exists** on the **target** project for an import candidate, the UI must **not** proceed silently. For **each** colliding item, offer:

| Option | Behavior |
|--------|----------|
| **Overwrite** | Replace the **existing** metadata in the target project. **Requires removing or invalidating runs that depend on** that metadata (same dependency rules as today when deleting or replacing an `Annot` / column). Document clearly which **runs/steps** will be affected **before** confirmation. |
| **Cancel** | Skip import for **this** metadata only; other selected items may still import. |
| **Keep both** | Keep the existing metadata unchanged and import the source as a **new** `Annot` using a **versioned name**, so **no run deletion** is required for the preserved column. |

**R-M4 (versioned name, “keep both”):** Follow the same **suffix convention** already used around compliance workflows: names ending with **`.vN`** where **N** is a positive integer (see **`lib/tasks/compliance_audit.rake`** for patterns such as `%.v%` and stripping **`\.v\d+\z`** to obtain the base name). On “keep both”, assign the **next free N** for that **base name** in the **target** project so **`base.v{N}`** does not collide with any existing `Annot.name`. Increment **`version_nber`** / **`latest_version`** flags consistently with how the application already represents successive metadata versions (align with compliance and `Annot` versioning rules).

**R-M5 (overwrite safety):** Overwrite is allowed only after **enumerating dependent runs** (pipeline steps whose `attrs_json` / `output_json` / lineage reference that metadata). If enumeration fails, **block** overwrite and show **R-N1**-style messaging.

#### 6.3.5 Reserved and ASAP-like metadata names (imports and user-chosen names)

**Scope:** Applies to **import metadata** names that already satisfy **R-MS** (only **`/col_attrs/...`** and **`/row_attrs/...`**). Reserved rules are evaluated on the **full path string** (e.g. `/col_attrs/foo.sel_123`).

**Goal:** Avoid user-imported or user-typed names that **look like** or **collide with** names **generated automatically** by ASAP pipeline steps under those attributes, which would confuse the UI, compliance, or downstream tools.

**R-NM0 (patterns, not enumerations):** There is an **unbounded** number of concrete **`/col_attrs/xxx`** and **`/row_attrs/yyy`** strings ASAP may emit (only the **run id** or similar token may change). Maintaining an exhaustive **list of names** is impossible. The implementation must use a **finite set of rules**, primarily **regular expressions** (and a small set of **fixed** strings where needed), extended per **Version** from the same sources as pipeline definitions for **column and row attributes** — **not** a growing denylist of every observed name.

- **R-NM1 (blocklist source of truth):** For the **target** project, build the reserved policy from the **current project `version`** (same family as selecting steps for runs: `Basic.get_asap_docker(@project.version)` and associated **`Step`** / **`StdMethod`** definitions). Include:
  - **Regexp (or equivalent) rules** that match **families** of auto-generated **col_attr / row_attr** paths (e.g. segments that embed **run ids**, standard **output_attr** shapes, selection suffixes **`.sel_<n>`** on an embedding column, etc.).
  - Optional **additional exact strings** only where a pattern would be too broad.
  - **Out of scope for this subsection:** roots such as **`/matrix`** or **`/attrs/...`** — not part of **metadata import** until **Rule M2** is extended.
- **R-NM2 (validation):** Before finalizing an import (or a rename within the same path scope), reject names that match any **reserved pattern** for that version. Message should say **why** (reserved for automatic ASAP outputs). Reference: **`MetadataNameAuthorizationService`** (central policy).
- **R-NM3 (maintenance):** When a new **Version** is released, refresh the **regexp set** (and any fixed strings) from **machine-readable** step/output definitions for **col_attrs / row_attrs** for that version.
- **R-NM4:** Versioned suffixes **`base.vN`** used for “keep both” (**R-M4**) should **not** bypass **R-NM1**: apply the same patterns to **both** the full string and the **base** after stripping **`\.v\d+\z`**. If either matches, require a **user-visible** rename or a different base name.

### 6.4 Federated CLA visibility (no import)

- **R-F1:** **Never import** `Cla` rows into the viewer’s project solely to “see” them. Visibility is **read-time aggregation** keyed by **`cell_set_id`** plus **`readable?(cla.project)`**.
- **R-F2:** **Provenance is mandatory** in API and UI: each row includes **`cla.project_id`** (or nested `project: { key, name, public_id }`) so users always know **which project owns** the annotation.
- **R-F3:** Creating a **new** `Cla` (new label, ontology, markers) remains governed by **`annotable?` on the project that will own the row** (typically the project open in the UI), not by federation rules.

### 6.5 Transferring or syncing metadata between clones (legacy / narrow sync)

Distinguish:

1. **Cell-set annotations (`Cla`)** — already keyed by `cell_set_id`; “transfer” is often **visibility + provenance policy**, not a second copy.
2. **Categorical metadata (`Annot` columns)** — **project-local**; “transfer” means **create or update** `Annot` / loom columns on the target project.

**Proposed rules:**

- **R-T1 (read precondition):** User may **pull metadata** (not `Cla` rows; see **R-F1**) from project **S** into project **T** only if **`readable?(S)`** for every source object.
- **R-T2 (write precondition):** User may **apply** to **T** only if **`analyzable?(T)`** (or owner editing rules for metadata import).
- **R-T3 (matching):** Match categories by **`cell_set_id`** (or `cell_sets.key` within the same `project_cell_set_id`) **and** **`cat_idx` / category name`**; if the target lacks the `Annot` or `AnnotCellSet`, **create** them or **reject** with a clear error (no silent wrong assignment).
- **R-T4 (missing source metadata):** If **S** no longer has the `Annot` (deleted, version replaced), allow **optional** sync from **another readable project in the same lineage** (e.g. walk `cloned_project_id`) or from a **snapshot export** — product choice; implementation must not guess.

### 6.6 No “fallback” masking

- **R-N1:** Failed resolution (missing source annot, mismatched dimensions, missing `AnnotCellSet`) must **surface explicit errors** to the user or skip the row with **logging** — **no silent fallback** to unrelated metadata.

### 6.7 Voting (`cla_votes`) on federated CLAs

**Target policy (differs from `cla_votable?` today):**

- **R-VT1 (who may vote):** Same as **Rule V1** (section **2.4**): any **authenticated user with a valid ORCID association** may **agree / disagree** (create or update a `ClaVote`) on a **`Cla`** if they can **read** the **home project** of that `Cla`: **`readable?(cla.project)`**. They **do not** need **`annotable?`** on that project. Rationale: voting is lightweight curation on **shared cell-set identity**, while **creating** new `Cla` content stays stricter (see **R-F3** and **`annotable?`**).
- **R-VT2 (identity):** Votes are stored on the **existing `cla_id`**; no duplicate `Cla` per viewer project.
- **R-VT3 (implementation note):** Refactor **`cla_votable?`** (or introduce **`cla_vote_allowed?(cla)`**) to implement **R-VT1** / **Rule V1**: **`readable?(cla.project)`** and **ORCID** on the user. **Anonymous** users: no votes; **logged-in without ORCID:** no votes.
- **R-VT4 (abuse / scale):** Optional caps, rate limits, or “one vote per user per `cla_id`” enforced in DB (unique index if not already present) should be verified when enabling cross-project visibility.

### 6.8 Relationship between sections 6.1 and 6.7

- **R-C1 (updated):** **Creating** new `Cla` rows and rich annotation actions on a project still follow **`annotable?`** where that applies today. **Voting** on **existing** `Cla` rows follows **R-VT1** so users who only have **read** access to the owning project can still participate in consensus **if** they have ORCID.

---

## 7. Implementation roadmap (next steps)

### Phase 0 — Inventory and consistency (short)

1. **Align `get_annot_info`** with **R-V1**: filter `Cla` by **`readable?(cla.project)`**; include **project provenance** in JSON for each row (**R-F2**).
2. **Audit** summaries, visualization overlays, and exports that list `Cla` so federated rows do not leak projects the user cannot read.
3. **Document** for support: clone **does not copy `Cla` rows**; federation **aggregates by `cell_set_id`** without duplicating rows.
4. **List** call sites like **`marker_groups_annot_id`** that assume source `Annot` still exists; add **user-visible** errors (**R-N1**).

### Phase 1 — Metadata import (upload + Modes A and B) (medium)

1. **Uploaded file (already shipped):** Keep **import metadata** by file as the baseline; extend or align **collision**, **reserved patterns**, and **overwrite** behavior (**R-M4**, **R-M5**, **R-NM1–R-NM4**) with new cross-project UI per **R-M0**.
2. **Discovery service (Mode A):** Given **`project_id`** + **`cell_set_id`** (or key), list **other projects** with the same **`project_cell_set_id`** / cell-set identity where the user is **`readable?`**, and list **compatible** `Annot` candidates.
3. **Explicit project picker (Mode B):** Given **`readable?`** source **`project_id`**, list **compatible** metadata for multi-select import (**R-M1b–R-M1c**). **API done:** `GET /projects/:id/discover_metadata_import_from_project` with `source_project_id` or `source_project_key`; see **section 9** and [collaborative-annotation-implementation-plan.md](./collaborative-annotation-implementation-plan.md) Phase 1 item 3. **UI:** Phase 1 item 4.
4. **Import wizard / API:** Apply **R-M2–R-M5**, **R-M4** (collision UI: overwrite / cancel / keep both with **`.vN`**), **R-NM1–R-NM4**; reuse validation and run orchestration from **`prepare_metadata` / `do_import_metadata`** and related jobs where applicable.
5. **Dependency graph:** Implement **R-M5** — query runs that reference target `Annot` / paths before allowing **overwrite**.
6. **Reserved-pattern builder:** Implement **R-NM1–R-NM3** as a **finite regexp list** (plus optional fixed strings) from **`Version`**, **`Step`**, **`StdMethod`**, and **`env_json`** for the **target** project’s version; wire into **`MetadataNameAuthorizationService`**.
7. **Optional:** If the UI must rank or label **which `Project` row** to cite (not needed for cell-set matching — use **`project_cell_set_id`**), walk **`cloned_project_id`** or add **`root_project_id`**.

### Phase 2 — Federated CLA UI and vote policy (medium–long)

1. **Visualization / annotation panels:** Unified list of **`Cla.active`** for **`cell_set_id`**, merged from all readable projects, **with source project badge** (**R-F1–R-F2**).
2. **`cla_votes` endpoints:** Implement **R-VT1–R-VT3**; replace or narrow uses of **`cla_votable? == annotable?`** for vote submission only.
3. **Optional:** Filter toggles (“this project only” vs “all accessible projects”) for power users.

### Phase 3 — Collaboration and ops (product-dependent)

1. **Share analyze** on canonical public projects for labs that need new runs without cloning.
2. **“Suggest annotation”** queue if **new `Cla`** creation must stay owner-only in some contexts.
3. **Audit log** for metadata imports and for vote spikes (moderation).

### Phase 4 — Stable metadata keys (longer term)

1. **`annot_lineages`** or **`stable_key` on `Annot`** so imports and sync do not depend only on **`name`** on the source (**R2**).
2. **Narrow clone-to-clone sync** (**section 6.5**) as an alternative path when **`cloned_project_id`** is set.

---

## 8. Open decisions (for product / science leads)

1. **Resolved (see R-V1, R-F1):** Federated listing with **`readable?`** per `Cla`; **no** `Cla` duplication for display.
2. **Resolved (see R-F1, R-VT2):** Votes attach to the **canonical `cla_id`**; no duplicate `Cla` per clone for voting isolation (if isolation is ever required, that would be a **new** product line with copied rows and is **out of scope** for this federation model).
3. When the **source** public project **deletes** metadata, should import/sync **default source** prefer another **`Project`** in the same **`project_cell_set_id`** lineage, or treat lineage as **immutable** for hints? (Cell identity itself stays keyed by **`project_cell_set_id`**; this is only about **which project id** the UI suggests.)
4. **Resolved:** Voting requires **ORCID** (**Rule V1**, **R-VT3**); no votes for users without an associated ORCID.
5. **Private projects in federation:** Confirm that **shared-with-view** private projects participate in **both** metadata import discovery and federated CLA lists for users who have access (expected: yes, per **readable?**).
6. **Overwrite scope:** Must **overwrite** remove **all** runs downstream of the replaced metadata, or only runs that **directly** reference it (stricter graph)? Product must confirm default for **R-M5** messaging.

---

## 9. References in this repository

- `app/controllers/concerns/project_authorization.rb` — `readable?`, `analyzable?`, `annotable?`, `cla_votable?`, `exportable?`
- `app/services/project_clone_service.rb` — clone steps, `annot_cell_sets`, `cloned_project_id`
- `app/controllers/projects_controller.rb` — `get_annot_info`, `get_cell_set_annotations`, `discover_metadata_import_sources` (Mode A), `discover_metadata_import_from_project` (Mode B)
- `app/services/metadata_import_discovery_helpers.rb` — shared discovery payloads (R-M1c)
- `app/services/metadata_import_mode_a_discovery_service.rb` — Mode A (R-M1a)
- `app/services/metadata_import_mode_b_discovery_service.rb` — Mode B (R-M1b)
- `app/services/metadata_name_authorization_service.rb` — reserved **regexp** policy for metadata names (R-NM0–R-NM4)
- `app/models/cla_vote.rb` — `ClaVote` model
- `lib/basic.rb` — `add_clas`, `marker_groups_annot_id`
- `lib/tasks/compliance_audit.rake` — versioned **`Annot`** names (`%.v%`, **`\.v\d+\z`** pattern)
- `db/schema.rb` — `annot_cell_sets`, `cell_sets`, `clas`, `cla_votes`, `annots`, `projects` (`version_nber`, `latest_version` on `annots`)

---

*Document version: 1.4 — 2026-04-06*
