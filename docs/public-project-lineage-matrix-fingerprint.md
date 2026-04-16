# Public project lineage: Sample/Cell cohorts, matrix fingerprints, and variant IDs

This document describes how we **group public projects** that share the **same ordered cells** (`ProjectCellSet`) but may differ in **genes, initial matrix, or analyses**. **To be publishable, a project must satisfy novelty and compliance together:** **(1) novelty** — at least one new counted `**cell_sets.key`** vs public peers (**§4.1**); **(2) compliance** — when **applicable**, validation against the **reference schema** for that project’s **project type** and `**version_id`** (see below). If (2) does **not** apply, only (1) gates publication for that project.

**When compliance applies:** Resolve active `**ComplianceSchema`** rows that match **this project’s `project_type`** **and** the **platform / ASAP version** for **this project’s `version_id`** (how you encode that mapping is product data — e.g. schema records keyed by type + version). When a matching schema ties `**allow_public**` to a successful validation (e.g. scFAIR-style — §4.1a), the project **must** pass that check **as well as** novelty.

**This document’s center of gravity** is **novelty**; **Sample/Cell cohort**, `**F`**, and `**ASAP…**` support lineage and citation around that.

**UI label for `ProjectCellSet`:** **Sample/Cell cohort** (same ordered cells; shared identity for search and lineage).

**Related documents**

- [collaborative-annotation-and-clone-lineage.md](./collaborative-annotation-and-clone-lineage.md) — cell identity, `Cla` federation, clone rules.
- [collaborative-annotation-implementation-plan.md](./collaborative-annotation-implementation-plan.md) — phased roadmap for metadata import and federated UI.

---

## 1. Problem statement

Several **public** projects can look like “the same dataset” if they share the **same cells**. **What must not be duplicated without a new public value** is the **same partition of those cells** into discrete groups (`**CellSet`** / `**cell_sets.key**`). **Gene panel**, **starting matrix** (`**F`**), and other facets help users **browse and compare** projects; they refine **which peers** count for novelty when `**F` scoping** is on, but **the decisive signal** remains **new keys** (§4.1).

---

## 2. Core concepts

### 2.1 Sample/Cell cohort grouping (`ProjectCellSet`)

- `**ProjectCellSet`** remains the canonical link for projects that share the **same ordered list of cells**.
- **User-facing terminology:** use **Sample/Cell cohort** everywhere in UI and search copy (avoids vague “cell set,” which clashes with `CellSet` / cluster semantics, and covers both **sample-level** framing and **cell-level** identity in one label).
- **Code:** keep the model name `ProjectCellSet`; map labels in presenters and i18n to **Sample/Cell cohort** as needed.

### 2.2 Gene / feature set (metadata; optional in display id)

- Represents **which features** the project uses (e.g. full transcriptome vs filtered panel).
- Aligns with an existing concept such as `**ProjectGeneSet`** (or equivalent) in the data model.
- **Primary publication signal** (§4.1): **novel `cell_sets.key`** vs peers on the same cohort; optional `**F**` scoping only narrows **which peer keys** enter `**U_keys`**. **Gene panel** is **not** the publishability test — it belongs in UI / facets, not in the `**ASAP…`** string (§3).
- **Distinct** from the raw matrix file: two projects can share the same gene set definition but differ in normalization → different `**F`** (§2.3).

### 2.3 Initial matrix fingerprint (internal; not a public id segment)

A **stable digest** of the **initial input matrix** (the scientific substrate **before** downstream analyses produce new matrices).

**Why not put “matrix level” in the public display id:** Pipeline runs **continuously produce new matrices** (normalized layers, scaled data, integrated objects). Encoding “matrix state” in the public string would either drift every run or duplicate information already implied by **which analyses exist** and their outputs. What usually matters for discoverability is **analysis results** (e.g. clusterings, embeddings, annotations), not another ordinal tied to intermediate files.

**Purpose of the fingerprint (product logic):**

1. **Publication gate (see §4.1):** **Novel `cell_sets.key`** values vs public peers (same `**project_cell_set_id**`, optional `**F**` scope).
2. **Search / faceting / provenance:** Filter and explain “same cells + same gene panel but different starting matrix” without overloading the human-facing id.

**Recommended hash for `F`:** **SHA-256**. MD5 is weaker; do not use for new `**F`** digests.

**Canonical matrix layout (normative):** Before hashing, **reorder** the matrix so **one axis** is **every** cell or sample-at-cell unit in **ascending lexicographic (string) order** of stable cohort id, and the **other axis** is **every** feature in **ascending lexicographic (string) order** of Ensembl gene ID (transcriptomics). Other modalities use **one documented stable id per feature** per assay, **sorted the same way** (string, ascending). Rows/columns must match that order **exactly** when serializing. **Always** apply the same rule — permutation on disk does not change `**F`**.

The digest is computed over the **matrix values** in this **row-major or column-major convention** (fixed per `matrix_fingerprint_algorithm` version), together with the **ordered ID lists** and the metadata below. Two files that differ only by **permutation** of cells or features on disk must yield the **same** digest after canonical reordering; two matrices that differ in **any** cell–feature value after alignment must yield a **different** digest.

**Fingerprint payload (conceptual “v1”) should therefore include:**

- The **ordered cell / sample ID** sequence (defines one matrix axis).
- The **ordered feature ID** sequence (defines the other axis).
- A **serialization** of numeric (or encoded) matrix entries **in canonical order** (after alignment to those sequences).
- **Matrix role / modality** (e.g. RNA vs lipid vs derived scores), if one Sample/Cell cohort can hold multiple modalities.
- **Value semantics** (e.g. raw counts vs log-normalized vs scaled), as encoded by the pipeline.
- **Structural metadata** that changes meaning: e.g. sparse vs dense representation **if** it affects interpretation, assay tag, normalization tag.
- **Headers / column-row annotation** that are part of the **scientific contract** (as you described), when they are not fully captured by the ordered ID lists alone.

**Typically exclude:** timestamps, random seeds, volatile paths, purely cosmetic labels.

**Persistence:** Store at least `matrix_fingerprint_algorithm` (e.g. `v1`) and `matrix_fingerprint_digest` (hex) on the appropriate object (`Project`, input attachment, or finalized input record).

**Important:** Document which dimension is cells vs features and **numeric normalization** (e.g. rounding) for hashing. Use the **same lexicographic ascending string comparator** for cohort cell/sample ids and Ensembl (or feature) ids in **every** code path that computes `**F`**. With that fixed, `**F**` is reproducible; **rule changes** (sort, rounding, payload) require bumping `**matrix_fingerprint_algorithm`**.

### 2.4 Occurrence (short public id)

- `**public_occurrence**` is a **monotonic counter per cohort `public_id`** (per Sample/Cell cohort) when using the **simplified display id** (§3.1). It labels **which** public child of that cohort this row is, for citation — **not** the full scientific identity (gene panel, matrix, analyses live elsewhere).

### 2.5 Cohort and partition keys (`ProjectCellSet.key`, `CellSet.key`)

These strings identify **the ordered cell list** (cohort) and **each discrete partition** (grouping). They drive federation and `**U_keys` / `N_k`** (§4.1).

**Target algorithm:** **SHA-256** hex (same preference as `**F`**).

**Current implementation (verified):** The Rails app still computes both with **MD5**:

- `**ProjectCellSet.key`:** `Digest::MD5.hexdigest({ :cells => cells.sort }.to_json)` in `upd_project_cell_set`:

```225:229:src/lib/basic.rb
        dataset_md5 = Digest::MD5.hexdigest({:cells => cells.sort}.to_json)
        
        pc = ProjectCellSet.where(:key => dataset_md5).first
        if !pc
          pc = ProjectCellSet.new(:key => dataset_md5, :nber_cells => cells.size)
```

- `**CellSet.key`:** `Digest::MD5.hexdigest(h_cells[cat].sort.to_json)` per category:

```1503:1507:src/lib/basic.rb
              md5 = Digest::MD5.hexdigest h_cells[cat].sort.to_json
              
              h_cell_set = {
                :key => md5,
                :project_cell_set_id => pc.id,
```

**Migration to SHA-256:** Add a **data migration** (and code change) that, for each row, recomputes the digest from the **same canonical inputs** as today (`cells.sort` JSON for `project_cell_sets`; sorted cell-list JSON per partition for `cell_sets`), writes **SHA-256** into `**project_cell_sets.key`** and `**cell_sets.key**`, then ships application code that **only** uses SHA-256 for new rows. Plan for:

- **Indexes** on `key` (both tables): update in place keeps `**id`** stable, so `**project_cell_set_id**` / `**AnnotCellSet**` / `**Cla**` foreign keys need no change.
- **APIs and URLs** that expose `**cell_sets.key`** as opaque strings: clients store the hash — they pick up new values after migration.
- **Deduping:** After migration, two rows that were distinct under MD5 should remain distinct under SHA-256 if inputs differ; identical inputs still collide as today (by design).

Until migration ships, documentation and **new** features (e.g. materialized `**U_keys`**) must treat existing keys as **MD5**; after migration, treat as **SHA-256**.

---

## 3. Public display identifier

### 3.1 Recommended form (simplified)

**Priority:** keep the **human-facing id short**; render **gene panel, initial matrix, and analyses** from **structured fields** (and search facets), not from extra dot-segments.

Display as:

`ASAP{public_id}.{occurrence}`


| Segment      | Meaning                                                                                                                                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `public_id`  | **Integer** that names **which cell cohort** this is — **one value per cohort**, assigned the first time that cohort goes public (**§3.4**). Shown as the **first** numeric segment (e.g. `**ASAP48.1`** → cohort `**48**`). |
| `occurrence` | **Integer**, **n-th** public project under this cohort (**monotonic** when a project is allowed to go public under §4.1).                                                                                                    |


**Rendered dynamically next to or below the id** (same screen, cards, search hits):

- **Gene / feature set** (name, panel, or link to `ProjectGeneSet`),
- **Initial matrix** summary or fingerprint label,
- **Key analyses** (clustering, embedding, etc.),
- optional **modality** / project type.

That way the **identifier string** stays easy to cite; **discovery** uses filters and subtitles, not a long `ASAP.x.y.z…` code.

**Grouping:** Search and project pages can list **occurrences** that share the **same initial gene set** or the **same initial matrix** (`**F`**) so users see related public siblings without encoding those dimensions in the `**ASAP…**` string. That is **navigation and context** only: **permission to go public** still depends on `**N_k`** (**novel `cell_sets.key`**, §4.1), not on sharing or differing gene panel / `**F**` alone.

### 3.2 Alternative (verbose id)

If product later requires **gene** in the string (e.g. legacy parity or external APIs):

`ASAP{public_id}.{gene}.{occurrence}`

Treat `**gene`** as an optional **presentation** segment, not the source of truth — storage remains `**project_gene_set_id`** (or equivalent) + fingerprint + **novel `cell_sets.key`** metadata for eligibility.

### 3.3 Storage (recommended)

Avoid parsing the display string in application logic. Prefer columns such as:

- `**public_id**` (integer, **one per `project_cell_set_id`**) — store on the cohort (`project_cell_sets` or lineage row), not reinvented per project
- `**public_occurrence**` (integer, scoped per cohort `**public_id**` for the simplified form)
- `project_gene_set_id` (or canonical feature-space digest) — **not** required in the display string
- `matrix_fingerprint_digest` (+ algorithm version)
- optional **index** or **materialized set** of **publication-relevant `cell_sets.key`** per public project — only if profiling says `**U_keys**` needs it; **few** occurrences per cohort usually make this unnecessary (§8)

Compute `**ASAP{public_id}.{occurrence}`** (or the verbose form) in presenters / serializers (concatenate integers; e.g. `**ASAP48.2**`).

**Relation to legacy `public_variant_id`:** Map old counters to `**public_occurrence`** under the chosen cohort `**public_id**`; migrate old dotted forms with **redirects** or **display aliases** if needed.

**Current product (`projects.public_id`):** Today `**Project#public_id`** is a **single** global integer per public project, displayed as `**ASAP`** + that number **with no second segment**. The model in this doc is **cohort `public_id` + `public_occurrence`**; moving there means storing the **cohort** integer once (per `**project_cell_set_id`**) and a **per-project** occurrence, then rendering `**ASAP{id}.{occurrence}`**. Existing `**ASAP48**`-style ids need a **migration** story if you split the display.

### 3.4 The cohort integer in the public id (`public_id`)

The display id is `**ASAP` + two integer pieces:** `**{public_id}.{occurrence}`** (both **integers**).

- `**public_id`** — “**which** group of cells (Sample/Cell cohort) is this?” It stays the **same** for **every** public project that shares that cohort. It is **not** a string slug; it is the same `**public_id`** column concept as in the app, held at **cohort** scope (**§3.3**).
- `**occurrence`** — “**which** public project is this **within** that cohort?” It goes **1, 2, 3, …** as new distinct public projects appear (§3.1).

**Example:** Cohort **A** might be assigned `**public_id = 48`**. The first public project is `**ASAP48.1**`. Another public project on the **same** cells but new science (new `**cell_sets.key`**) becomes `**ASAP48.2**`. A **different** cohort **B** gets another integer, e.g. `**public_id = 51`**, first publication `**ASAP51.1**`.

**Assigning `public_id` and `occurrence` when a project goes public:**

1. **Look for an existing public sibling** on the **same** `**project_cell_set_id`**:
  `Project.where(public: true, project_cell_set_id: this.project_cell_set_id)` (or equivalent).
2. **If any exist:** **Do not** mint a **new** cohort `**public_id`**. **Reuse** the `**public_id`** on those public rows (same `**project_cell_set_id**` ⇒ same integer). Set **this** project’s `**public_occurrence`** to the **next** value in the per-cohort sequence (e.g. max existing occurrence + 1, starting at `**1`** for the second public sibling).
3. **If none exist:** This `**project_cell_set_id`** has **no** public project yet. **Mint** a **new** global integer `**public_id`** (e.g. `max(public_id) + 1` over all projects or over cohort records). Set `**public_occurrence**` to `**1**` for this first public project (document if you use `**0**`-based occurrence).

That single rule — **never mint a new cohort `public_id` while another public project already shares this `project_cell_set_id`** — gives **one integer per cohort** and avoids duplicate cohort labels.

**Invariants:** Do not **reassign** a cohort’s `**public_id`** after citations. **Different** `**project_cell_set_id`** → **different** cohort `**public_id`** when each goes public for the first time.

**Legacy:** How to **migrate** from today’s **single** `projects.public_id` (no occurrence segment) to **cohort `public_id` + `public_occurrence`** remains an engineering task if you change the display (**§3.3** paragraph on current product).

---

## 4. When a project may become public

### 4.1 Eligibility rules (normative intent)

**Publication = novelty AND compliance (when the latter applies):**

- **Novelty (`cell_sets.key`):** At least one **new** counted partition vs **public** peers on this cohort (optional `**F`** scope) — `**N_k` non-empty** (below).
- **Compliance (reference schema):** **If** this project’s `**project_type`** and `**version_id**` associate it to an active `**ComplianceSchema**` that requires validation for `**allow_public**`, the dataset must **pass** that validation (**§4.1a**). **If** no such schema applies to this project, there is **no** compliance gate for publication (other prerequisites still apply).

**Allow public only if** cohort / `**F`** prerequisites (steps 1–2) **and** novelty **and** every **applicable** compliance rule **all** pass.

**Novelty gate — `N_k`:** At least one publication-counted `**cell_sets.key`** that no public peer already has (under optional `**F` scoping**). If `**N_k` is empty**, the project fails the **novelty** criterion even if compliance passed.

> **Note:** We do **not** use a **per-run tuple** (e.g. fingerprint + method + normalized `Run` attrs) to decide if a project is **publishable**. That path breaks down after **clones** (new `Annot`s, unstable paths and ids inside attrs, fragile equality) and needs either painful normalization or expensive output hashing. **Publishable novelty** here is intentionally simple: at least one **new partition of the cohort’s cells**, identified by `**cell_sets.key`**, compared to **public peers** on the same `**project_cell_set_id`**, with optional scoping by the same initial matrix fingerprint `**F**`.

Allow toggling **public** only if:

1. **Sample/Cell cohort** is set (`project_cell_set_id` valid).
2. **Initial matrix fingerprint** stored when the product needs `**F`** for scoping, faceting, or provenance (§2.3).
3. **Novelty — `cell_sets.key`:** The project meets the **novelty** criterion if it has at least one publication-counted `**CellSet`** whose `**key**` is **not** already on a public peer. The grouping may come from a **pipeline step** (e.g. clustering) **or** from **user-uploaded / imported metadata** that defines a **discrete** assignment of cells or samples to categories — if the product maps that to a counted `**CellSet`**, it is the **same** novelty signal: a **new `key`** vs peers is **valid** publication value. Same definition as federation ([collaborative-annotation-and-clone-lineage.md](./collaborative-annotation-and-clone-lineage.md)); **Rule K2**: identical partition after clone keeps the **same** `**key`** (replay is not novel).
  - `**K_this`:** keys on **this** project that **count** (product allowlist: e.g. clustering-like `**AnnotCellSet`** links **and** imported categorical columns you treat as first-class partitions; exclude scratch, internal-only, markers-only noise).
  - `**U_keys`:** all such keys on **public** projects with the same `**project_cell_set_id`**.
  - `**F` scoping (optional):** restrict `**U_keys`** to peers with the **same** `**initial_matrix_fingerprint`** as this project so the **same** labels on a **different** input still count as new. With no scoping, **any** peer’s keys apply (stricter).
  - `**N_k = K_this ∖ U_keys`**. **Pass** iff `**N_k` non-empty**.
  - **UI:** show which groupings are in `**N_k`** (clustering name, **uploaded column** label, run name, etc.).
   **Not covered:** outputs that **never** produce a counted `**CellSet`** (e.g. only continuous scores) do **not** open this gate; handle elsewhere if needed.
4. **Compliance:** Where **this project’s `project_type` and `version_id`** match an active `**ComplianceSchema**` that **gates** public release, validation must be **valid** before public (e.g. scFAIR when configured for that type/version). Failing this blocks publication **even when `N_k` is non-empty**; see §4.1a.

**Genes vs partition:** `**cell_sets.key`** is **who is in which group**; gene panel is mostly inside `**F`**. Use `**F` scoping** when the cohort can have **different** starting matrices.

### 4.1a Compliance gating (current product behavior)

**Publishable** means **novelty satisfied** **and** **compliance satisfied for every schema that applies** to **this** project. **Applicability** is **not** “project type alone”: it is **project type together with the project’s `version_id`** (ASAP / platform version), which determines **which** `**ComplianceSchema`** rows are in effect. A project can fail publication because `**N_k**` is empty, because required validation **did not run** or **failed**, or **both**.

Active `**ComplianceSchema`** rows (matched to **type** and **version** as your data model defines) can require a **valid** validation outcome for `**allow_public`**. Today much of this flows through `**Project#can_be_public?**` / `**ProjectsController#toggle_public**` (e.g. `**cxg_validation_result**` with `**valid: true**`). Any **central eligibility service** must evaluate **both** novelty **and** applicable compliance and report **which** condition fails (**§8**).

### 4.2 Blocked vs allowed

- **Blocked (novelty):** `**N_k` empty** (all counted keys already on a peer, or **no** counted `**CellSet`**). Message: add a **new grouping** (analysis **or** uploaded metadata) or change inputs if `**F`** scoping applies.
- **Blocked (compliance):** validation **invalid** or missing where the **reference schema** requires it — even if `**N_k` non-empty**. Message: fix validation; name the **actual schema** in copy (§4.3).
- **Allowed:** **Compliance OK** (where required) **and** `**N_k` non-empty** — show novel groupings, assign next `**public_occurrence`** (§3), optional contribute flow (§5).

**Examples (novelty only; compliance must also pass where required):** New clustering → new `**key`** → passes novelty. **New uploaded categorical metadata** (new partition) → new `**key`** → passes novelty. Clone, same partitions → same keys → novelty blocked. Peer already has that `**key**` → that column does not help; another **new** `**key`** does. Only continuous layers → usually **no** `**N_k`** → novelty blocked unless another policy applies.

### 4.3 Types / versions without a compliance gate

If **no** `**ComplianceSchema`** applies to this project’s `**project_type**` + `**version_id**`, or none of the applicable schemas tie `**allow_public**` to validation, publication depends on **novelty** (and other rules here) **only** for that axis. Use the **real schema name** in UI errors when a schema **does** apply.

---

## 5. Transferring annotations and votes to a related public dataset

**Scope:** Only **annotations** and **votes** that are eligible under the rules below may be **merged** into a **public** project. Everything else stays private or is reported as **not mergeable** with an explicit **reason**.

### 5.1 Who may contribute (ORCID)

- **Mergeable** annotations and votes are limited to those created by users **associated with an ORCID** (product-defined: e.g. linked account on record at creation time).
- If **no** annotation or vote qualifies, there is **nothing to merge** for that category; the UI should still show **counts** (see §5.4).

### 5.2 Matching a public target project

A private-side annotation or vote can only merge into public project `**XXX`** if `**XXX**` is the **unique** (or product-selected) public target such that:

1. `**XXX`** has the **same metadata name** as required by the merge flow (same field the product uses to line up private vs public metadata / annotation identity), **and**
2. `**XXX`** has the **same ordered list of `cell_sets` ids** (the same discrete groupings the annotation or vote refers to — product: internal ids of `**CellSet`** rows or equivalent stable list) as the private source for that item.

**Votes** use the **same** pairing rules: merge only when the vote targets metadata that matches **by name** and the `**cell_sets` id list** matches the public project’s list for that metadata.

If **no** public project satisfies both conditions for a given item, that item is **not mergeable** (reason: missing or ambiguous target, name mismatch, or `**cell_sets` id list** mismatch).

### 5.3 Mixed mergeable and non-mergeable

The private project may contain **new** annotations and votes where **some** pass all checks and **some** do not. The UI must support:

- **Mergeable** subset: user action to merge only that subset into the resolved public `**XXX`**.
- **Non-mergeable** subset: do not merge; show **why** each row fails (see §5.5).

### 5.4 Summary message

Always show a clear **summary**, for example:

- **Annotations:** “**m** annotations **out of n** can be merged into public project **XXX**” (or “**0** out of **n**” when none qualify), where `**XXX`** is the public project identified by **metadata name** + `**cell_sets` id list** match when a target exists; if **no** target exists, say so and omit a false `**XXX`**.
- **Votes:** same pattern — “**m** votes **out of v** can be merged …” with the same matching rules.

When there is **new** content but **merge conditions** fail (ORCID, name, `**cell_sets` ids**, or missing public sibling), the summary should still appear and the detail tables (§5.5) explain **per item**.

### 5.5 UI: reasons for non-mergeable rows

For items that **cannot** be merged, show **two tables** (separate concerns):

1. **Annotations** — one row per non-mergeable annotation; **reason** column (e.g. author not ORCID-linked; no public project with matching metadata name; `**cell_sets` id list** differs from public target; other product rules).
2. **Votes** — one row per non-mergeable vote; **reason** column (same classes of failure).

**Merge security and audit:** Only **authorized** users may execute a merge on the public project. **Audit** each merge: **who**, **when**, **source private `project_id`**, **public target `project_id`**, **which annotation / vote ids** were applied, and any **conflict** handling.

---

## 6. Search and grouping

Facets: **Sample/Cell cohort** first, then **genes**, **matrix / `F`**, **modality**, then **occurrence** for citation. **Novelty for publication** is **not** “picked from facets”; it is `**cell_sets.key`** vs peers (§4.1). Facets organize **discovery**.

---

## 7. Implementation plan (phased)

### Phase 0 — Vocabulary and schema design

- Use **Sample/Cell cohort** as the **UI term** for `ProjectCellSet` grouping (see §2.1).
- Add or extend entities for **cohort `public_id` (integer) + `public_occurrence`** (simplified display id) and/or a `**PublicLineage**` record; **materialized `cell_sets.key` sets** for `**U_keys`** are **optional** (§8 — few occurrences per cohort) (**no matrix / gene digits** required in the cited string if product adopts §3.1).
- Decide migration path for existing `public_id` / variant fields.

### Phase 1 — Matrix fingerprint pipeline

- At **input finalization** (or project creation): build **ordered cell/sample ID** and **ordered feature ID** sequences, **reorder the matrix** to match §2.3, serialize values in the fixed row/column convention, add metadata → compute digest → persist with algorithm version.
- Optional **backfill** job for legacy projects (feature-flagged).

### Phase 2 — Publication eligibility service

Service returns **allowed**, **reason**, **novel keys** (and peer links). Order: **sandbox**, **permissions**, `**Project#can_be_public?`**, then `**K_this` / `U_keys` / `N_k**`.

### Phase 3 — UI

Public toggle uses the eligibility logic; when **disabled**, show **all applicable reasons**: **no novelty** (`**N_k`** empty), **compliance not run**, and/or **compliance failed** (§8). When **enabled**, show novel keys (`**N_k`**). Search facets: cohort, gene, `**F**` / matrix label, occurrence. Contribute / merge UI (§5): ORCID-only mergeable subset, `**m` of `n**` summary, two **reason** tables for blocked annotations and votes.

### Phase 4 — Migration and URLs

- Map legacy public identifiers to the new segmented model; add **redirects** if public URLs change.

---

## 8. Risks and open decisions

### Solved or mitigated

These were plausible failure modes; **ASAP rules** remove them in normal operation.

- `**F` digest reproducibility:** **§2.3** fixes **ascending string sort** on **cohort cell/sample ids** and **Ensembl** (and modality) feature ids in **every** code path that hashes. The same biology then yields the same digest. When you **change** sort rules, value rounding, or hash payload, **bump `matrix_fingerprint_algorithm`** and treat stored digests accordingly (migration or reinterpretation).
- **Cohort identity after public:** Cohort `**public_id`**, `**U_keys**`, `**N_k**`, and `**F**` all refer to the `**ProjectCellSet**` ordered list. **Public** projects **lock** the **runs** that matter, including **parsing / finalization** of the **initial matrix** and **initial cell cohort**, so that list **cannot** be edited in place after publication. Do not later allow **re-parsing or re-attaching** a public project without a **new** cohort or public identity.
- **Short id vs many occurrences under one cohort:** The display id stays `**ASAP{public_id}.{occurrence}`** (§3.1). **Gene set** and **initial matrix** are in structured fields; the UI can **group or filter** by them (§3.1). **Publishability** is unchanged: it turns on **novel `cell_sets.key`** (`**N_k**`, §4.1), not on how occurrences are listed.
- **Merge security and audit:** **Solved** when implemented as in **§5**: mergeable surface is **only** ORCID-sourced annotations and votes; target public `**XXX`** is constrained by **metadata name** + `**cell_sets` id list**; **only authorized** users run the merge; **audit** records **who**, **when**, source/target `**project_id`s**, and **which** ids merged; **UX** exposes **m/n** summaries and **two reason tables** for blocked rows — so arbitrary or opaque pushes into public data are not possible by design.
- **Cohort `public_id` (integer):** **Solved** by the rule in **§3.4**: before **minting** a **new** cohort `**public_id`**, check that **no other public project** already has this `**project_cell_set_id`**. If one does, **reuse** its `**public_id`** and only bump `**public_occurrence**`. If none do, allocate a **new** integer `**public_id`**. Duplicate cohort labels and split-brain ids are then an **implementation bug**, not an open design gap. **Migration** from today’s single `projects.public_id` column (§3.3) is still **engineering work** if you adopt `**ASAP{id}.{occurrence}`** display.
- `**U_keys` query size:** **Not** a scaling worry in practice: there will be **few** public **occurrences** per cohort `**public_id`**, so the union of peer `**cell_sets.key**` values stays **small**. A normal **indexed** query over public projects with that `**project_cell_set_id`** (and optional `**F**`) is enough; **materialized** key sets (§3.3, Phase 0) are **optional** polish, not a requirement.
- **Why the public toggle is disabled:** **Solved** by clear **UX** (see Phase 3). Whenever publication is **not** allowed, the UI must **report the reasons** that apply — **not** a single vague message. At minimum, distinguish: **(a)** **no novelty** — `**N_k` empty** / no counted partition new vs public peers; **(b)** **compliance** — when a `**ComplianceSchema`** applies to this project’s **type** + `**version_id`**, say if the check was **not run** or **failed** (schema-specific errors). **Both** can apply; show **both** when they do (**§4.1**, **§4.1a**).

### Risks and open decisions

- **Hash algorithms:** Use **SHA-256** for **`F`** (§2.3) and for **`ProjectCellSet.key`** / **`CellSet.key`** (§2.5). **Today** cohort and partition keys are still **MD5** in `src/lib/basic.rb`; schedule the **§2.5 migration** before relying on stronger hashes in production comparisons.

---

## 9. Verdict

**Center of gravity (this doc):** **Cell-set novelty** — at least one **new `cell_sets.key`** vs public siblings on the same **`project_cell_set_id`**, optionally scoped by **`F`**. **Publication in the product** is **novelty AND compliance** when a **`ComplianceSchema`** applies to the project’s **`project_type`** and **`version_id`** (**§4.1a**); otherwise **novelty** (and the other rules here) for that axis. Partitions may come from **analysis** or **uploaded / imported metadata** ([collaborative-annotation-and-clone-lineage.md](./collaborative-annotation-and-clone-lineage.md)). **No per-run tuple gate**; **`Run` attrs** are not the primary signal (**Note**, §4.1).

**What to implement next:** Write the **queries** (SQL or Rails scopes) that power the public toggle: **which clusterings on this project count** toward novelty, **which keys already exist on public projects** that share the same cells (and, if you use it, the **same initial matrix `F`**). **§4.1** describes the rules; turn that into code, then **adjust the rules when real projects** show cases you did not expect.