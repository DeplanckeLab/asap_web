# Guided tours: current implementation and "Getting started" proposal

## 1. What is already implemented

### 1.1 Data model

- **`guided_tours`**: `name`, `rank`, optional `duration_time` (seconds; split across steps for auto-advance in the end-user player).
- **`guided_tour_steps`**: ordered steps per tour with:
  - `page_url` (string): target path for the step, e.g. `/projects/123?view=analysis`
  - `title` (string): step heading shown in the player (once built)
  - `focus_element` (string): CSS selector for the highlighted target
  - `description` (text): rich text via Trix in the admin UI
  - `rank` (integer): order within the tour
  - `step_actions` (jsonb, default `[]`): declarative pre-step actions validated in the model

### 1.2 Step actions (server-side contract)

`GuidedTourStep` validates `step_actions` as a JSON array of objects. Supported `action` values:

| Action | Required fields | Notes |
|--------|-------------------|--------|
| `scroll_to` | `selector` | Scroll target into view |
| `click` | `selector` | Programmatic click |
| `wait_for_selector` | `selector` | Optional `timeout_ms` (positive integer) |

Unknown actions or missing required keys fail validation. This matches the inline admin hint: *"Declarative steps: scroll_to, click, wait_for_selector"*.

### 1.3 Rails API and authorization

- **Admin only**: `GuidedToursController` and `GuidedTourStepsController` use `before_action :authorize_admin`.
- **Public read JSON** for the player: `Api::GuidedToursController` under `/api/guided_tours` (see 1.5).
- **Routes** (`config/routes.rb`):
  - `resources :guided_tours` with `patch :reorder` on collection
  - Nested `resources :guided_tour_steps, path: :steps` (create, update, destroy)
  - `patch :reorder_steps` on member tour for step reordering
  - Inside `namespace :api`: `resources :guided_tours, only: [:index, :show]`

### 1.4 Admin UI

- **Index** (`/guided_tours`): lists tours with drag-and-drop reorder (Stimulus `sortable-list`), links to open/edit/delete, "New Guided Tour", and "Start All Chapters" (opens first tour’s show page).
- **Show** (per tour): sidebar of all tours; form to edit tour name and duration; inline create/edit/delete for steps with `page_url`, `focus_element`, Trix `description`, and JSON textarea for `step_actions_json`; drag-and-drop step reorder.

### 1.5 End-user tour player (implemented)

- **Read-only JSON API** (no admin gate; same `skip_before_action` rules as other `index`/`show` actions on `ApplicationController`):
  - `GET /api/guided_tours` — `{ "guided_tours": [ { "id", "name" } ] }` ordered by rank
  - `GET /api/guided_tours/:id` — tour `name`, `duration_time`, and `steps` with `page_url`, `title`, `focus_element`, `description`, `step_actions`
- **Stimulus `guided-tour-player`** (`guided_tour_player_controller.js`): loads a tour, runs `step_actions` (`wait_for_selector`, `scroll_to`, `click`), highlights `focus_element` above the dimmed backdrop (high z-index so the target is not greyed out), shows a bottom panel with HTML description, Back / Next / **Try it** / Exit, Escape exits the tour. **Try it** pauses the tour (clears overlay and highlight) and shows a bottom-right bar with **Resume guided tour** and **Exit guided tour**. Uses **Turbo.visit** when `page_url` does not match the current path (query string must match if the step’s `page_url` includes one).
- **Layout integration**: `shared/_guided_tour_player` is rendered from `layouts/application.html.erb` on all pages using that layout. When at least one tour exists, **Guided tour** appears in the main header (dropdown listing tours) and under **Info** as a single **Guided tours** row that expands to list each tour. Each link adds `?guided_tour=<id>` to the current path to start that tour.
- **Deep link**: append `?guided_tour=<id>` to any URL; the param is stripped after read and that tour starts.
- **Resume**: `sessionStorage` key `guidedTourPlayerState` stores `{ tourId, stepIndex, tryIt }` across navigations until the user finishes or exits. When `tryIt` is true, only the resume/exit bar is shown after navigation until the user resumes or exits.
- **`duration_time`**: if set to a positive integer (seconds), auto-advance time per step is `max(3000, round(duration_time * 1000 / step_count))` ms; otherwise steps advance only via the buttons.

**Still recommended for polish:** add stable `data-tour` attributes on browse and project chrome so `focus_element` selectors do not depend on fragile CSS or `title` attributes.

---

## 2. Project navigation (reference for tour URLs)

`ProjectsController#resolve_project_view_type` accepts these `view` values:

`summary`, `visualization`, `analysis`, `data`, `settings`, `compliance`

Invalid or missing `view` falls back to **`summary`**.

Typical URLs:

- Browse / search: **`/projects`** (`ProjectsController#index`, page title "Search projects")
- Project shell: **`/projects/:id`** or **`/projects/:id?view=<view>`**

**Conditional nav** (from `shared/_project_header.html.erb`):

- **Visualization** link appears only if the project has visualization embeddings (`has_visualization_embeddings`).
- **Settings** appears only if the user can edit the project (`editable?`).
- **Compliance** appears only if `@project.compliance_schemas.any?`

A global tour should either use a **demo project** chosen for stable features (public, embeddings, optional compliance) or skip conditional steps when elements are absent.

---

## 3. Proposed tour: "Getting started"

Goal: orient a new user from **finding projects** to **understanding the main areas inside a project**, without deep-diving into analysis sub-panels.

Suggested tour record:

- **Name**: Getting started
- **Duration** (optional): e.g. 120–180 seconds, once the player respects it

### 3.1 Step outline

| # | Page URL (pattern) | Title (example) | What to explain | Focus / actions notes |
|---|--------------------|-----------------|-----------------|------------------------|
| 1 | `/projects` | Search and browse projects | ASAP lists public (and your private) projects; use the search box, filters, and visibility when signed in. | Highlight search input: selector for `#q` (projects index). Optional `step_actions`: `wait_for_selector` on `#q` or the form. |
| 2 | `/projects` | Filters and results | Organism and other filters narrow the list; results link into a project. | Highlight a stable container: e.g. `[data-test="organism-selector-container"]` or the filters card; avoid brittle table row selectors. |
| 3 | `/projects/:demo_id` | Summary: project overview | Default landing view: status, lineage, and shortcuts into other areas. | Prefer adding a stable hook on the summary hero or first dashboard card, e.g. `data-tour="project-summary"` on the main summary block in `projects/views/_summary.html.erb`. |
| 4 | `/projects/:demo_id?view=visualization` | Visualization | Explore embeddings and linked views (skip step if tour detects no visualization tab). | Add `data-tour` on a root panel in `_visualization.html.erb` or use `title="Visualization"` on the desktop nav link inside the project header (fragile if markup changes). |
| 5 | `/projects/:demo_id?view=analysis` | Analysis | Pipeline steps, runs, and result panels. | Target a stable wrapper in `_analysis.html.erb` or the Analysis nav control. |
| 6 | `/projects/:demo_id?view=data` | Data | Matrices, files, and downloads. | Target `_data.html.erb` intro or Data nav link. |
| 7 | `/projects/:demo_id?view=settings` | Settings (owners) | Project metadata and options for editors (skip for read-only or non-editors). | Only include if the audience is project owners; use Settings nav or settings view wrapper. |
| 8 | `/projects/:demo_id?view=compliance` | Compliance (when enabled) | Schema-driven compliance UI (skip if project has no compliance schemas). | Optional last step. |

### 3.2 Practical notes for implementers

1. **Seeding the default tour**: `bin/rails db:seed` creates or updates the **Getting started** tour when at least one `Project` exists. It picks the first public project by id, or the first project overall, unless **`GUIDED_TOUR_DEMO_PROJECT_ID`** is set to a specific project id.
2. **Replace `:demo_id`** with a real project ID in each `page_url` (or teach the player to substitute a query param / session "tour project").
3. **Stable selectors**: Relying on `title="Summary"` on icon-only links works short-term but breaks easily; prefer explicit `data-tour="..."` attributes on browse and project chrome.
4. **Cross-page flow**: The player must load `/projects`, then after "Next" navigate to `/projects/ID?view=summary`, etc. Either full page loads or Turbolinks/Turbo-aware navigation must be handled.
5. **Auth**: Browse is largely public; some filters require sign-in. Decide whether the tour is "anonymous" (public search only) or "logged-in" (include visibility filters).
6. **`step_actions`**: Use `wait_for_selector` after navigation for heavy views (visualization, analysis) before attaching the spotlight.

---

## 4. Summary

| Layer | Status |
|-------|--------|
| Database + models | Done |
| Admin CRUD + reorder + rich text + JSON actions | Done |
| End-user tour player + API + page integration | Done |

The proposed **Getting started** tour connects **`/projects`** (search/browse) with the six main **`view=`** modes on **`/projects/:id`**, using optional steps for settings and compliance when the UI exposes them.
