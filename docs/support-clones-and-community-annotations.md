# Support: clones and community annotations (`Cla`)

Short reference for support and operators. Technical rules and roadmap: [collaborative-annotation-and-clone-lineage.md](./collaborative-annotation-and-clone-lineage.md).

## Cloning does not copy community annotation rows

When a user **clones** a project, **`ProjectCloneService`** copies runs, metadata (`Annot`), links between metadata and cell sets (`AnnotCellSet`), files, and related project data. It does **not** create new rows in the **`clas`** table and does **not** copy existing **`Cla`** records into the clone.

- Each **`Cla`** row stays tied to its original **`project_id`** (and original **`annot_id`** where set).
- The clone gets **new** `Annot` / `AnnotCellSet` rows as part of the copy, but **`CellSet`** identity is aligned so the same logical group of cells can share the same **`cell_set_id`** where `AnnotCellSet` is copied with that id preserved.

So: **missing `Cla` rows on the clone database row is expected**, not a failed clone.

## Why users can still see annotations from another project

The app can **list** community annotations by **`cell_set_id`** (the same cell grouping across projects that share the same underlying cell-set identity). For a user who can **read** the project that **owns** a given **`Cla`**, that annotation may appear in visualization or summary flows together with annotations from the project they have open.

- This is **read-time aggregation**, not a second copy of the row stored on the viewer’s project.
- The UI should indicate **which project** owns each annotation where multiple sources are shown (see API fields such as **`project`** / **`project_key`** on relevant JSON endpoints).

Users who **cannot** read the owning project must **not** see that project’s **`Cla`** content; enforcement is via **`readable?`** on the home project of each **`Cla`**.

## Phrasing for tickets

- **“I cloned a public project and my clone has no annotations in the database.”**  
  Expected: **`Cla`** rows were not duplicated. The user may still see federated annotations in the UI when they have read access to the source project and the same **`cell_set_id`** applies.

- **“Annotations from project X appear while I am in project Y.”**  
  If X and Y share the same cell set identity and the user can read X, federated listing by **`cell_set_id`** is intentional; check **source project** labels in the UI.

- **“I need annotations copied into my clone as new rows.”**  
  That is **not** what clone does today. Product direction is federation and provenance, not silent duplication of **`Cla`** rows (see spec **R-F1** / section 6.4).

## Code pointers

- **`app/services/project_clone_service.rb`** — clone steps; no **`Cla`** copy step.
- **`app/controllers/projects_controller.rb`** — **`get_annot_info`**, **`get_cell_set_annotations`**, and visualization **`build_best_cla_category_map`** apply **`readable?(cla.project)`** where rows from multiple projects can appear.
