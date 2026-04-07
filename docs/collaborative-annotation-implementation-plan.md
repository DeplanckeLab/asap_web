# Implementation plan: collaborative annotation and metadata

This file tracks the **phased implementation roadmap** for collaborative annotation, federated CLA visibility, and metadata import. Normative rules, rationale, and rule IDs (**R-V1**, **R-M2**, etc.) live in [collaborative-annotation-and-clone-lineage.md](./collaborative-annotation-and-clone-lineage.md).

**Metadata import** includes three conceptual paths: **uploaded file** (current **import metadata**; **`prepare_metadata` / `do_import_metadata`**) and planned cross-project **Mode A** (discovery by shared `cell_set_id`) and **Mode B** (explicit source project). Phase 1 treats file import as the baseline and aligns new UI with it where rules apply.

---

## Phase 0 — Inventory and consistency (short)

1. **Align `get_annot_info`** with **R-V1**: filter `Cla` by **`readable?(cla.project)`**; include **project provenance** in JSON for each row (**R-F2**).
2. **Audit** summaries, visualization overlays, and exports that list `Cla` so federated rows do not leak projects the user cannot read.
3. **Document** for support: clone **does not copy `Cla` rows**; federation **aggregates by `cell_set_id`** without duplicating rows. **Done:** [support-clones-and-community-annotations.md](./support-clones-and-community-annotations.md).
4. **List** call sites like **`marker_groups_annot_id`** that assume source `Annot` still exists; add **user-visible** errors (**R-N1**). **Done:** `Basic::SourceAnnotResolutionError`, clearer copy in **`Basic.marker_groups_annot_id`**, structured **`{ error: }`** from **`Basic.find_markers`**, handled in **`find_or_start_marker_run_for_annot`** (surfaced by **`get_annot_evidences`** as **`state: error`** + **`message`**). Inventory: [support-clones-and-community-annotations.md](./support-clones-and-community-annotations.md) (FindMarkers / clone source metadata).

---

## Phase 1 — Metadata import (upload + Modes A and B) (medium)

1. **Uploaded file (already shipped):** Keep **import metadata** by file as the baseline; extend or align **collision**, **reserved patterns**, and **overwrite** behavior (**R-M4**, **R-M5**, **R-NM1–R-NM4**) with new cross-project UI per **R-M0** in the main document.
2. **Discovery service (Mode A):** Given **`project_id`** + **`cell_set_id`** (or key), list **other projects** with the same **`project_cell_set_id`** / cell-set identity where the user is **`readable?`**, and list **compatible** `Annot` candidates.
3. **Explicit project picker (Mode B):** Given **`readable?`** source **`project_id`**, list **compatible** metadata for multi-select import (**R-M1b–R-M1c**).
4. **Import wizard / API:** Apply **R-M2–R-M5**, **R-M4** (collision UI: overwrite / cancel / keep both with **`.vN`**), **R-NM1–R-NM4**; reuse validation and run orchestration from **`prepare_metadata` / `do_import_metadata`** and related jobs where applicable.
5. **Dependency graph:** Implement **R-M5** — query runs that reference target `Annot` / paths before allowing **overwrite**.
6. **Reserved-pattern builder:** Implement **R-NM1–R-NM3** as a **finite regexp list** (plus optional fixed strings) from **`Version`**, **`Step`**, **`StdMethod`**, and **`env_json`** for the **target** project’s version; wire into **`MetadataNameAuthorizationService`**.
7. **Optional:** If the UI must rank or label **which `Project` row** to cite (not needed for cell-set matching — use **`project_cell_set_id`**), walk **`cloned_project_id`** or add **`root_project_id`**.

---

## Phase 2 — Federated CLA UI and vote policy (medium–long)

1. **Visualization / annotation panels:** Unified list of **`Cla.active`** for **`cell_set_id`**, merged from all readable projects, **with source project badge** (**R-F1–R-F2**).
2. **`cla_votes` endpoints:** Implement **R-VT1–R-VT3**; replace or narrow uses of **`cla_votable? == annotable?`** for vote submission only.
3. **Optional:** Filter toggles (“this project only” vs “all accessible projects”) for power users.

---

## Phase 3 — Collaboration and ops (product-dependent)

1. **Share analyze** on canonical public projects for labs that need new runs without cloning.
2. **“Suggest annotation”** queue if **new `Cla`** creation must stay owner-only in some contexts.
3. **Audit log** for metadata imports and for vote spikes (moderation).

---

## Phase 4 — Stable metadata keys (longer term)

1. **`annot_lineages`** or **`stable_key` on `Annot`** so imports and sync do not depend only on **`name`** on the source (**R2** in the main document).
2. **Narrow clone-to-clone sync** (main document **section 6.5**) as an alternative path when **`cloned_project_id`** is set.

---

## Open decisions and references

Product and engineering trade-offs that affect sequencing are listed in **section 8** of [collaborative-annotation-and-clone-lineage.md](./collaborative-annotation-and-clone-lineage.md). Code and model references are in **section 9** of that document.
