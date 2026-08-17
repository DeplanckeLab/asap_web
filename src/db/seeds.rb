# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

puts "Seeding project types..."

project_types_seed = [
  { tag: "sc", name: "Single-cell (or nucleus) transcriptomics", row_label: "genes", col_label: "cells" },
  { tag: "bulk", name: "Bulk transcriptomics", row_label: "genes", col_label: "samples" },
  { tag: "spat", name: "Spatial transcriptomics", row_label: "genes", col_label: "cells" },
  { tag: "atac", name: "ATAC-seq", row_label: "genes", col_label: "cells" },
  { tag: "multi", name: "Multiomics", row_label: "genes", col_label: "cells" }
]

project_types_seed.each do |attrs|
  project_type = ProjectType.find_or_initialize_by(tag: attrs[:tag])
  project_type.assign_attributes(attrs)

  if project_type.new_record?
    project_type.save!
    puts "Created #{attrs[:tag]}: #{attrs[:name]} (row_label=#{attrs[:row_label]}, col_label=#{attrs[:col_label]})"
  elsif project_type.changed?
    project_type.save!
    puts "Updated #{attrs[:tag]}: #{attrs[:name]} (row_label=#{project_type.row_label}, col_label=#{project_type.col_label})"
  else
    puts "No change for #{attrs[:tag]}"
  end
end

puts "Seeding guided tours..."

def seed_guided_tour!(name, duration_time:, steps:)
  tour = GuidedTour.find_or_initialize_by(name: name)
  tour.duration_time = duration_time
  if tour.new_record?
    tour.rank = (GuidedTour.maximum(:rank) || 0) + 1
  end
  tour.save!
  tour.guided_tour_steps.destroy_all
  steps.each_with_index do |attrs, index|
    tour.guided_tour_steps.create!(attrs.merge(rank: index + 1))
  end
  puts "  Guided tour #{name.inspect}: #{tour.guided_tour_steps.count} steps (rank=#{tour.rank})."
end

demo_project = Project.guided_tour_demo_project

unless demo_project
  puts "  Skipped demo-based tours: no project in the database. Set GUIDED_TOUR_DEMO_PROJECT_ID or GUIDED_TOUR_DEMO_PROJECT_KEY, or create a project first."
else
  pid = demo_project.id
  base = "/projects/#{demo_project.to_param}"
  demo_search_term =
    demo_project.key.to_s.strip.presence ||
    demo_project.name.to_s.strip.presence ||
    pid.to_s

  getting_started_steps = [
    {
      page_url: "/",
      title: "Welcome to ASAP",
      focus_element: '[data-guided-tour="welcome-search-projects-body"]',
      description: "<p>You are on the ASAP home page. Use <strong>Search projects</strong> in the hero to open the browse page. On smaller screens you can also reach it from the header menu under <strong>Search projects</strong>.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="welcome-search-projects-body"]', "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Search and filter form",
      focus_element: '[data-guided-tour="projects-search-form-section"]',
      description: "<p>Use this form to search by text and apply filters (organism, type, tissue, status, and more when signed in). By default, visitors see all <strong>public</strong> projects; signed-in users can also use visibility options that apply to their own projects.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-search-form-section"]', "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Search results",
      focus_element: '[data-guided-tour="projects-results-section"]',
      description: "<p>Matching projects appear in the table below. When you resume, earlier steps on this page run again when needed so filters and the search field are reset to match the demo flow.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-results-section"]', "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Search field",
      focus_element: "#q",
      description: "<p>The demo project key (#{ERB::Util.html_escape(demo_search_term)}) is filled in here. You can edit it. On the next step, use <strong>Search</strong> to update the results section.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => "#q", "timeout_ms" => 8000 },
        { "action" => "fill", "selector" => "#q", "value" => demo_search_term }
      ]
    },
    {
      page_url: "/projects",
      title: "Search button",
      focus_element: '[data-guided-tour="projects-search-submit"]',
      description: "<p>Click <strong>Search</strong> to apply the text query and refresh the list in the results section.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => "#q", "timeout_ms" => 8000 },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-search-submit"]', "timeout_ms" => 8000 },
        { "action" => "click", "selector" => '[data-guided-tour="projects-search-submit"]' }
      ]
    },
    {
      page_url: "/projects",
      title: "Organism filter",
      focus_element: 'div[data-organism-selector-target="dropdownMenu"]:not(.hidden)',
      description: "<p>Open the organism menu to narrow results by species. You can search inside the list or pick an entry.</p>",
      exclude_from_page_replay: true,
      step_actions: [
        { "action" => "wait_for_selector", "selector" => 'button[data-organism-selector-target="dropdownButton"]', "timeout_ms" => 8000 },
        { "action" => "click", "selector" => 'button[data-organism-selector-target="dropdownButton"]', "skip_if_selector" => 'div[data-organism-selector-target="dropdownMenu"]:not(.hidden)' },
        { "action" => "wait_for_selector", "selector" => 'div[data-organism-selector-target="dropdownMenu"]:not(.hidden)', "timeout_ms" => 4000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Open the demo project",
      focus_element: '[data-guided-tour="demo-project-view-list"]',
      description: "<p>Use <strong>View</strong> on the demo project row to open its summary. On resume, earlier steps on this page are replayed so the table still matches the demo search.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="demo-project-view-list"]', "timeout_ms" => 15000 }
      ]
    },
    {
      page_url: base,
      title: "Summary",
      focus_element: '[data-guided-tour="project-nav-summary"]',
      exclude_from_page_replay: true,
      description: "<p>The Summary icon opens the project overview: status, metrics, and shortcuts. We select it, then open each main area in turn.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-nav-summary"]', "timeout_ms" => 10000 },
        { "action" => "click", "selector" => '[data-guided-tour="project-nav-summary"]', "skip_if_selector" => ".adaptive-dashboard" },
        { "action" => "wait_for_selector", "selector" => ".adaptive-dashboard", "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: base,
      title: "Visualization",
      focus_element: '[data-guided-tour="project-visualization-view"]',
      exclude_from_page_replay: true,
      description: "<p>The Visualization area shows embeddings and linked views when coordinates exist. If none are available yet, you will see a short message here instead.</p>",
      step_actions: [
        { "action" => "visit", "path" => "#{base}?view=visualization", "skip_if_selector" => '[data-guided-tour="project-visualization-view"]' },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-visualization-view"]', "timeout_ms" => 20000 }
      ]
    },
    {
      page_url: base,
      title: "Analysis",
      focus_element: '[data-guided-tour="project-nav-analysis"]',
      exclude_from_page_replay: true,
      description: "<p>The Analysis icon opens pipeline steps, jobs, and result panels for this project.</p>",
      step_actions: [
        { "action" => "visit", "path" => "#{base}?view=analysis", "skip_if_selector" => '[data-controller="step-selector"]' },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-nav-analysis"]', "timeout_ms" => 10000 },
        { "action" => "wait_for_selector", "selector" => '[data-controller="step-selector"]', "timeout_ms" => 20000 }
      ]
    },
    {
      page_url: base,
      title: "Data",
      focus_element: '[data-guided-tour="project-nav-data"]',
      exclude_from_page_replay: true,
      description: "<p>The Data icon opens matrices, files, and download options.</p>",
      step_actions: [
        { "action" => "visit", "path" => "#{base}?view=data", "skip_if_selector" => '[data-controller="data-view"]' },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-nav-data"]', "timeout_ms" => 10000 },
        { "action" => "wait_for_selector", "selector" => '[data-controller="data-view"]', "timeout_ms" => 20000 }
      ]
    }
  ]

  seed_guided_tour!("Getting started", duration_time: 240, steps: getting_started_steps)
  puts "    Uses demo project id=#{pid} key=#{demo_project.key.inspect} (#{demo_project.display_name})."

  seed_guided_tour!(
    "Get project summary",
    duration_time: 660,
    steps: [
      {
        page_url: base,
        title: "Project navigation",
        focus_element: '[data-guided-tour="project-view-nav"]',
        description: "<p>From any project view, use the icons in the header to switch between Summary, Visualization, Analysis, Data, and more.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "visit", "path" => "#{base}?view=summary", "skip_if_selector" => '[data-guided-tour="project-summary-dashboard"]' },
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-view-nav"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Summary dashboard",
        focus_element: '[data-guided-tour="project-summary-dashboard"]',
        description: "<p>The <strong>Summary</strong> page is a dashboard of cards. This tour walks them in reading order: top row left to right, then the next rows, then source links and publications.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-summary-dashboard"]', "timeout_ms" => 15000 }
        ]
      },
      {
        page_url: base,
        title: "Visualization card",
        focus_element: '[data-guided-tour="summary-visualization-shortcut"]',
        description: "<p>First card: <strong>Visualization</strong>. The whole card opens the interactive plot when embeddings exist. The four counters below summarize collaboration around that view.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-visualization-shortcut"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Embeddings count",
        focus_element: '[data-guided-tour="summary-embeddings-trigger"]',
        description: "<p>This number is how many <strong>2D embeddings</strong> (coordinate sets) exist for the project. Click to open a list of LOOM file, run, and embedding name.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-embeddings-trigger"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Annotations count",
        focus_element: '[data-guided-tour="summary-annotations-trigger"]',
        description: "<p>Cell-level <strong>annotations</strong> with votes across the project. Click for a breakdown by metadata and label (see also the collaborative annotation tour).</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-annotations-trigger"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Checkpoints count",
        focus_element: '[data-guided-tour="summary-checkpoints-trigger"]',
        description: "<p>Saved <strong>checkpoints</strong> capture named views of the visualization. The count is how many checkpoints exist; click to inspect titles and authors.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-checkpoints-trigger"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Comments count",
        focus_element: '[data-guided-tour="summary-comments-trigger"]',
        description: "<p><strong>Comments</strong> attached to checkpoints. The number is total comments; click to read them in context of each checkpoint.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-comments-trigger"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Analysis card",
        focus_element: '[data-guided-tour="summary-analysis-card"]',
        description: "<p>Next card: <strong>Analysis</strong>. Opens the pipeline of runs and methods. The large number is the <strong>total run count</strong> (all statuses) across steps and methods.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-analysis-card"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Data card",
        focus_element: '[data-guided-tour="summary-data-card"]',
        description: "<p><strong>Data</strong> lists LOOM and related files. The large number counts <strong>LOOM files</strong> on the project; open the card to browse matrices, attributes, and downloads.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-data-card"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Settings card",
        focus_element: '[data-guided-tour="summary-settings-card"]',
        description: "<p><strong>Settings</strong> summarizes visibility at a glance: whether the project is public or private and how many users it is shared with.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-settings-card"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Public or private",
        focus_element: '[data-guided-tour="summary-settings-visibility-badge"]',
        description: "<p><strong>Public</strong> projects appear in browse and search; <strong>private</strong> ones are limited to owners and invited users.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-settings-visibility-badge"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Shared users",
        focus_element: '[data-guided-tour="summary-sharing-badge"]',
        description: "<p>How many distinct users have an explicit <strong>share</strong> on this project (not counting public visibility).</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-sharing-badge"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Identity card",
        focus_element: '[data-guided-tour="summary-identity-panel"]',
        description: "<p>Second row, left: <strong>Identity</strong>. Stable identifiers and provenance: key, display name, project type, and whether the project was cloned.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-identity-panel"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Project key",
        focus_element: '[data-guided-tour="summary-identity-key"]',
        description: "<p>The internal <strong>key</strong> never changes; APIs and file paths use it. It is not the same as the public ASAP id shown elsewhere.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-identity-key"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Project name",
        focus_element: '[data-guided-tour="summary-identity-name-row"]',
        description: "<p>The <strong>display name</strong> shown in headers and lists. Owners can rename it when the project is not public.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-identity-name-row"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Project type",
        focus_element: '[data-guided-tour="summary-identity-type-row"]',
        description: "<p><strong>Type</strong> (for example single-cell vs bulk) drives labels and which parts of the pipeline apply.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-identity-type-row"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Origin",
        focus_element: '[data-guided-tour="summary-identity-origin-row"]',
        description: "<p><strong>Origin</strong> states if the project was created from scratch or <strong>cloned</strong> from another; you can open full lineage when applicable.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-identity-origin-row"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Activity card",
        focus_element: '[data-guided-tour="summary-activity-panel"]',
        description: "<p>Middle card: <strong>Activity</strong> dates and traffic for the project as a whole.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-activity-panel"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Created date",
        focus_element: '[data-guided-tour="summary-activity-created"]',
        description: "<p>When the project record was <strong>created</strong> in ASAP.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-activity-created"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Last updated",
        focus_element: '[data-guided-tour="summary-activity-updated"]',
        description: "<p>Last time project metadata or related records were <strong>updated</strong> (not each individual run).</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-activity-updated"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "View count",
        focus_element: '[data-guided-tour="summary-activity-views"]',
        description: "<p>Cumulative <strong>views</strong> of the project (summary and other views) as recorded by the platform.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-activity-views"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Reproducibility card",
        focus_element: '[data-guided-tour="summary-reproducibility-panel"]',
        description: "<p>Right card: <strong>Reproducibility</strong> links for rerunning or auditing the project outside the browser.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-reproducibility-panel"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Instructions link",
        focus_element: '[data-guided-tour="summary-repro-instructions-link"]',
        description: "<p>Human-readable <strong>instructions</strong> to reproduce analyses with the recorded software and data layout.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-repro-instructions-link"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Commands link",
        focus_element: '[data-guided-tour="summary-repro-commands-link"]',
        description: "<p>Exported <strong>commands</strong> (shell or similar) matching how runs were executed.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-repro-commands-link"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Loom list (JSON)",
        focus_element: '[data-guided-tour="summary-repro-loom-json-link"]',
        description: "<p>Machine-readable <strong>list of LOOM paths</strong> for scripting and external tools.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-repro-loom-json-link"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Source repository links",
        focus_element: '[data-guided-tour="summary-repository-panel"]',
        description: "<p>Bottom section: external <strong>repository and accession</strong> metadata (GEO, ArrayExpress, etc.) when curators attached them.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-repository-panel"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Publications",
        focus_element: '[data-guided-tour="summary-publications-panel"]',
        description: "<p><strong>Publications</strong> linked by DOI, with resolved titles when metadata is available.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-publications-panel"]', "timeout_ms" => 12000 }
        ]
      }
    ]
  )

  seed_guided_tour!(
    "Visualize project",
    duration_time: 540,
    steps: [
      {
        page_url: base,
        title: "Open visualization",
        focus_element: '[data-guided-tour="project-visualization-view"]',
        description: "<p>The visualization view shows UMAP or other embeddings when coordinate data is available. Use the header icon or this tour to navigate here directly.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "visit", "path" => "#{base}?view=visualization", "skip_if_selector" => '[data-guided-tour="project-visualization-view"]' },
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-visualization-view"]', "timeout_ms" => 20000 }
        ]
      },
      {
        page_url: base,
        title: "Left panel overview",
        focus_element: '[data-guided-tour="visualization-metadata-panel"]',
        description: "<p>The <strong>left column</strong> is dedicated to cell metadata: expand rows to drive the plot. The thin bar between columns resizes the panel.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-metadata-panel"]', "timeout_ms" => 15000 }
        ]
      },
      {
        page_url: base,
        title: "Categorical metadata",
        focus_element: '[data-guided-tour="visualization-categorical-metadata"]',
        description: "<p><strong>Categorical</strong> metadata lists discrete fields (clusters, samples, and so on). Expand a row to see categories, cell counts, and optional annotation shortcuts. Use the header row to show or hide all categories at once where available.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-categorical-metadata"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Coloring, filters, and downloads",
        focus_element: '[data-guided-tour="visualization-sample-metadata-controls"]',
        description: "<p>On each metadata row you can <strong>color</strong> the embedding (palette), <strong>filter</strong> cells (toggle and per-category checkboxes), and combine filters across several fields. The <strong>download</strong> icon exports the current distribution. The small filter switch enables or disables filtering for that field only.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-sample-metadata-controls"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Continuous metadata",
        focus_element: '[data-guided-tour="visualization-continuous-metadata"]',
        description: "<p><strong>Continuous</strong> metadata uses a range slider and histogram: narrow the range to filter cells by value, adapt the color scale, and optionally map values to custom plot axes (x, y) or color. Several continuous filters combine with categorical ones.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-continuous-metadata"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Global filters",
        focus_element: '[data-guided-tour="visualization-global-filter-bar"]',
        description: "<p>The <strong>filter</strong> chip in the top bar shows how many active filters you have. Click it to review or clear them. The <strong>global switch</strong> turns all filters on or off at once without losing your selections.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-global-filter-bar"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Choose an embedding",
        focus_element: '[data-guided-tour="visualization-embedding-picker"]',
        description: "<p>Open the embedding menu to pick another <strong>LOOM</strong> group or <strong>2D/3D coordinate set</strong> when more than one is available.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-embedding-picker"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Expression matrix layer",
        focus_element: '[data-guided-tour="visualization-matrix-layer-picker"]',
        description: "<p>Gene expression values can come from different <strong>matrix layers</strong> or runs. Use <strong>Values from</strong> in the right stack to change the layer used for coloring and statistics.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-matrix-layer-picker"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Plot workspace",
        focus_element: '[data-guided-tour="visualization-plot-area"]',
        description: "<p>The <strong>main plot</strong> is the embedding: pick cells, read the tooltip, and use the mode buttons beside it. The footer shows quick instructions and selection counts.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-plot-area"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Interaction modes",
        focus_element: '[data-guided-tour="visualization-mode-buttons"]',
        description: "<p><strong>Pan/Zoom</strong> moves the view, <strong>Pick</strong> clicks single points for details, and <strong>Lasso</strong> draws a region. <strong>Labels</strong> toggles category labels on the plot when coloring by metadata.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-mode-buttons"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Save and checkpoints",
        focus_element: '[data-guided-tour="visualization-save-toolbar"]',
        description: "<p>The <strong>save</strong> menu exports the plot (SVG, PNG) and can store a <strong>checkpoint</strong> of the current view when you have edit access. <strong>History</strong> and <strong>comments</strong> relate to saved checkpoints.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-save-toolbar"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Diagnostics and plot settings",
        focus_element: '[data-guided-tour="visualization-utility-toolbar"]',
        description: "<p>Additional icons open <strong>memory and database diagnostics</strong> and <strong>plot settings</strong> for fine-tuning the visualization.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-utility-toolbar"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Right panel",
        focus_element: '[data-guided-tour="visualization-right-panel"]',
        description: "<p>The <strong>right column</strong> holds gene expression controls above and <strong>cell sets / gene set collections</strong> below. Drag the divider to resize.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-right-panel"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Gene expression",
        focus_element: '[data-guided-tour="visualization-gene-expression-panel"]',
        description: "<p>The gene panel loads expression for genes you choose, shows summaries, and can clear or extend the gene list. Results depend on the matrix layer selected in the menu bar.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-gene-expression-panel"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Search genes one by one or in batch",
        focus_element: '[data-guided-tour="visualization-gene-search"]',
        description: "<p>Type a symbol and pick from <strong>autocomplete</strong>, or <strong>paste many names</strong> separated by commas, spaces, or line breaks and confirm with Enter. Genes appear as removable tags; use clear to reset the list.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-gene-search"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Cell sets",
        focus_element: '[data-guided-tour="visualization-cell-sets-content"]',
        description: "<p><strong>Cell sets</strong> lists the current visible selection, lets you save lasso or filtered subsets, and shows saved sets with sort and filter. Open a set to recall that selection on the plot.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "click", "selector" => "#cells-tab" },
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-cell-sets-content"]', "timeout_ms" => 8000 }
        ]
      },
      {
        page_url: base,
        title: "Gene set collections",
        focus_element: '[data-guided-tour="visualization-gene-set-collections-list"]',
        description: "<p><strong>Gene set collections</strong> group curated or imported gene lists. Add a collection, browse gene sets inside it, rename or download, and send sets to the expression panel when the UI offers it.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "click", "selector" => "#gene-sets-tab" },
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="visualization-gene-set-collections-list"]', "timeout_ms" => 8000 }
        ]
      }
    ]
  )

  seed_guided_tour!(
    "Browse project data",
    duration_time: 140,
    steps: [
      {
        page_url: base,
        title: "Data view",
        focus_element: '[data-guided-tour="project-data-main"]',
        description: "<p>The Data view lists LOOM files and lets you explore matrices, cell and gene attributes, and global metadata. Pick a file if several are available, then browse or download.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "visit", "path" => "#{base}?view=data", "skip_if_selector" => '[data-guided-tour="project-data-main"]' },
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-data-main"]', "timeout_ms" => 20000 }
        ]
      },
      {
        page_url: base,
        title: "LOOM files list",
        focus_element: '[data-guided-tour="data-loom-files-panel"]',
        description: "<p>On wide layouts, the sidebar lists LOOM files for this project. Select one to load its matrix and attributes in the main panel.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="data-loom-files-panel"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Matrix, genes, and metadata",
        focus_element: '[data-guided-tour="data-type-tabs"]',
        description: "<p>Use the tabs to switch between the expression matrix, gene and cell attributes, and global metadata for the selected file.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="data-type-tabs"]', "timeout_ms" => 12000 }
        ]
      }
    ]
  )

  seed_guided_tour!(
    "Collaborative annotation",
    duration_time: 240,
    steps: [
      {
        page_url: base,
        title: "Summary overview",
        focus_element: '[data-guided-tour="project-summary-dashboard"]',
        description: "<p>Collaboration in ASAP includes cell-level annotations with votes, saved checkpoints of views, and comments. Start from the project summary to see counts at a glance.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "visit", "path" => "#{base}?view=summary", "skip_if_selector" => '[data-guided-tour="project-summary-dashboard"]' },
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-summary-dashboard"]', "timeout_ms" => 15000 }
        ]
      },
      {
        page_url: base,
        title: "Sharing and visibility",
        focus_element: '[data-guided-tour="summary-sharing-badge"]',
        description: "<p>Project owners can share access with other users. The Settings card shows whether the project is public or private and how many collaborators have access.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-sharing-badge"]', "timeout_ms" => 10000 }
        ]
      },
      {
        page_url: base,
        title: "Annotations detail",
        focus_element: '[data-guided-tour="summary-collab-popover"]',
        description: "<p>On the Visualization card, open <strong>annotations</strong> to see collaborative labels and vote counts per metadata. <strong>Checkpoints</strong> and <strong>comments</strong> cover saved views and discussion.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-annotations-trigger"]', "timeout_ms" => 10000 },
          { "action" => "click", "selector" => '[data-guided-tour="summary-annotations-trigger"]' },
          { "action" => "wait_for_selector", "selector" => '#summary-visual-details-popover:not(.hidden)', "timeout_ms" => 10000 },
          { "action" => "wait_for_selector", "selector" => '#summary-visual-details-popover [data-summary-detail-section="annotations"]:not(.hidden)', "timeout_ms" => 8000 }
        ]
      },
      {
        page_url: base,
        title: "Checkpoints detail",
        focus_element: '[data-guided-tour="summary-collab-checkpoints-section"]',
        description: "<p>Open <strong>checkpoints</strong> to see saved views of the embedding with authors and dates. Each checkpoint can carry threaded comments.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-checkpoints-trigger"]', "timeout_ms" => 8000 },
          { "action" => "click", "selector" => '[data-guided-tour="summary-checkpoints-trigger"]' },
          { "action" => "wait_for_selector", "selector" => '#summary-visual-details-popover [data-summary-detail-section="checkpoints"]:not(.hidden)', "timeout_ms" => 8000 }
        ]
      },
      {
        page_url: base,
        title: "Comments detail",
        focus_element: '[data-guided-tour="summary-collab-comments-section"]',
        description: "<p>Open <strong>comments</strong> to read discussion tied to checkpoints, including who wrote each note and when.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="summary-comments-trigger"]', "timeout_ms" => 8000 },
          { "action" => "click", "selector" => '[data-guided-tour="summary-comments-trigger"]' },
          { "action" => "wait_for_selector", "selector" => '#summary-visual-details-popover [data-summary-detail-section="comments"]:not(.hidden)', "timeout_ms" => 8000 }
        ]
      },
      {
        page_url: base,
        title: "Close the details panel",
        focus_element: "#summary-visual-details-close-button",
        description: "<p>When you are done, close the details panel to return to the summary dashboard layout.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "click", "selector" => "#summary-visual-details-close-button", "skip_if_selector" => "#summary-visual-details-popover.hidden" }
        ]
      }
    ]
  )

  seed_guided_tour!(
    "scFAIR compliant metadata",
    duration_time: 160,
    steps: [
      {
        page_url: base,
        title: "Compliance view",
        focus_element: '[data-guided-tour="project-compliance-view"]',
        description: "<p>The Compliance view (also linked to the scFAIR initiative) shows how project metadata aligns with a registered schema. Validation status, field coverage, and history appear here when a schema is attached to the project.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "visit", "path" => "#{base}?view=compliance", "skip_if_selector" => '[data-guided-tour="project-compliance-view"]' },
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-compliance-view"]', "timeout_ms" => 20000 }
        ]
      },
      {
        page_url: base,
        title: "Validation summary",
        focus_element: '[data-guided-tour="compliance-validation-summary"]',
        description: "<p>The validation summary aggregates pass and fail counts by requirement group so you can see overall scFAIR alignment at a glance.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="compliance-validation-summary"]', "timeout_ms" => 12000 }
        ]
      },
      {
        page_url: base,
        title: "Run validation",
        focus_element: '[data-guided-tour="compliance-validate-button"]',
        description: "<p>Use <strong>Re-run Validation</strong> to refresh the report after editing metadata. Editors can open <strong>Fix Compliance Issues</strong> when the project is not yet compliant, or <strong>Edit metadata</strong> when it already is.</p>",
        exclude_from_page_replay: true,
        step_actions: [
          { "action" => "wait_for_selector", "selector" => '[data-guided-tour="compliance-validate-button"]', "timeout_ms" => 12000 }
        ]
      }
    ]
  )
end

create_tour_loom_sample_url = "https://asap-test.epfl.ch/projects/ASAP48/get_file?filename=output.loom&step=parsing"
create_tour_demo_project_name = "Guided tour demo project"
create_tour_project_type_id = ProjectType.order(:id).first&.id
create_tour_version_id = Version.activated.order(id: :desc).first&.id
create_tour_organism_id = Organism.find_by(tax_id: 7227)&.id
create_tour_fill_for_submit = []
if create_tour_project_type_id && create_tour_version_id && create_tour_organism_id
  create_tour_fill_for_submit = [
    { "action" => "fill", "selector" => 'select[name="project[project_type_id]"]', "value" => create_tour_project_type_id.to_s },
    { "action" => "fill", "selector" => 'select[name="project[version_id]"]', "value" => create_tour_version_id.to_s },
    { "action" => "fill", "selector" => 'input[name="project[organism_id]"]', "value" => create_tour_organism_id.to_s },
    { "action" => "fill", "selector" => 'input[name="project[name]"]', "value" => create_tour_demo_project_name }
  ]
else
  missing = []
  missing << "ProjectType" unless create_tour_project_type_id
  missing << "activated Version" unless create_tour_version_id
  missing << "Organism tax_id 7227 (fruit fly)" unless create_tour_organism_id
  puts "  Create project tour: auto-fill uses only the wait step (missing: #{missing.join(', ')})."
end
create_tour_fill_demo_step_actions =
  if create_tour_fill_for_submit.any?
    create_tour_fill_for_submit + [
      { "action" => "wait_for_selector", "selector" => '#submit-button:not([disabled])', "timeout_ms" => 60000 }
    ]
  else
    [
      { "action" => "wait_for_selector", "selector" => "#submit-button", "timeout_ms" => 5000 }
    ]
  end
create_tour_fill_demo_description =
  if create_tour_fill_for_submit.any?
    "<p>The tour now fills <strong>project type</strong>, <strong>ASAP release</strong>, <strong>organism</strong>, and <strong>name</strong> with sample values from your database so the button can turn on. Adjust them if you plan to submit for real.</p>"
  else
    "<p>Choose <strong>project type</strong>, <strong>ASAP release</strong>, <strong>organism</strong>, and <strong>name</strong> yourself so the requirements match preparsing; the button enables when everything is valid.</p>"
  end

seed_guided_tour!(
  "Create a new project",
  duration_time: 600,
  steps: [
    {
      page_url: "/",
      title: "Start from the home page",
      focus_element: '[data-guided-tour="welcome-create-project-cta"]',
      description: "<p>Choose <strong>Try it now!</strong> to open the project creation form. You can also use <strong>New Project</strong> from the project browse page when signed in. Use <strong>Next</strong> when you are ready to open the form.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="welcome-create-project-cta"]', "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "The create project form",
      focus_element: '[data-guided-tour="project-new-form"]',
      description: "<p>This page collects project details, your input file (or a URL), preparsing feedback, and the final action to start parsing. Use <strong>Next</strong> to walk through each block.</p>",
      step_actions: [
        { "action" => "visit", "path" => "/projects/new", "skip_if_selector" => '[data-guided-tour="project-new-form"]' },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-form"]', "timeout_ms" => 15000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Project name",
      focus_element: '[data-guided-tour="project-new-field-name"]',
      description: "<p>Give the project a clear <strong>name</strong>. It is required and shown in lists and headers.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-field-name"]', "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Project type and ASAP release",
      focus_element: '[data-guided-tour="project-new-type-and-release"]',
      description: "<p><strong>Project type</strong> sets whether you work with single-cell or bulk data and adjusts labels (for example genes versus cells). <strong>ASAP release</strong> pins the pipeline version and can change which organisms and features are available.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-type-and-release"]', "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Organism",
      focus_element: '[data-guided-tour="project-new-field-organism"] div[data-organism-selector-target="dropdownMenu"]:not(.hidden)',
      description: "<p>The organism list is opened for you. Choose the species that matches your data; available entries depend on the selected <strong>ASAP release</strong>. Use the search field at the top of the list to filter by <strong>scientific name</strong>, <strong>common name</strong>, or <strong>NCBI taxonomy ID</strong>.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-field-organism"]', "timeout_ms" => 8000 },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-field-organism"] button[data-organism-selector-target="dropdownButton"]', "timeout_ms" => 8000 },
        { "action" => "click", "selector" => '[data-guided-tour="project-new-field-organism"] button[data-organism-selector-target="dropdownButton"]', "skip_if_selector" => '[data-guided-tour="project-new-field-organism"] div[data-organism-selector-target="dropdownMenu"]:not(.hidden)' },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-field-organism"] div[data-organism-selector-target="dropdownMenu"]:not(.hidden)', "timeout_ms" => 4000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Supported data formats",
      focus_element: '[data-guided-tour="project-new-upload-intro"]',
      description: "<p>The <strong>Upload Data File</strong> section lists supported formats (10x, LOOM, text tables, H5AD, archives, and more). Choose a type that matches your project; incompatible extensions are rejected before preparsing.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-upload-intro"]', "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Upload from your computer",
      focus_element: '[data-guided-tour="project-new-file-upload-local"]',
      description: "<p>Click the dashed area or drag a file in. Large uploads can <strong>resume</strong> if the connection drops. Progress and filename appear below the drop zone while the file is transferring.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-file-upload-local"]', "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Download a public parsing LOOM by URL",
      focus_element: '[data-guided-tour="project-new-file-url"]',
      exclude_from_page_replay: true,
      description: "<p>Paste an <strong>https</strong> URL and use <strong>Download</strong> so ASAP fetches the file <strong>on the server</strong>. This tour fills the field with a sample link to a <strong>public</strong> parsing output LOOM (ASAP48 <code>output.loom</code>) and clicks Download. Preparsing starts after the file is fetched; this can take up to a few minutes.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-file-url"]', "timeout_ms" => 10000 },
        { "action" => "fill", "selector" => "#file-url", "value" => create_tour_loom_sample_url, "skip_if_selector" => '[data-file-upload-target="preparsingResult"] p' },
        { "action" => "click", "selector" => '[data-file-upload-target="downloadUrlButton"]', "skip_if_selector" => '[data-file-upload-target="preparsingResult"] p' },
        { "action" => "wait_for_selector", "selector" => '#preparsing-panel:not(.hidden)', "timeout_ms" => 180000 },
        { "action" => "wait_for_selector", "selector" => '[data-file-upload-target="preparsingResult"] p', "timeout_ms" => 180000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Preparsing results",
      focus_element: '[data-guided-tour="project-new-preparsing-results"]',
      description: "<p>The <strong>preparsing</strong> panel shows status while the file is analyzed. When it finishes, this area lists detected structure (dimensions, format hints, warnings). Use <strong>Reset</strong> if you need to replace the file. Dataset or archive choices may appear here when the file contains several options.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-preparsing-results"]', "timeout_ms" => 15000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Create project stays disabled until valid",
      focus_element: '#submit-button',
      description: "<p>The <strong>Create project</strong> button at the bottom stays <strong>disabled</strong> while the form is incomplete or invalid: missing project name, type, ASAP release, or organism, or preparsing still running / not successful. It only enables when every requirement is satisfied so you do not submit a broken configuration.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-form-actions"]', "timeout_ms" => 8000 },
        { "action" => "wait_for_selector", "selector" => "#submit-button", "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects/new",
      title: "Fill the form for this demo",
      focus_element: '[data-guided-tour="project-new-project-info"]',
      description: create_tour_fill_demo_description,
      step_actions: create_tour_fill_demo_step_actions
    },
    {
      page_url: "/projects/new",
      title: "Create project (parsing)",
      focus_element: '[data-guided-tour="project-new-submit"]',
      description: "<p><strong>Create project</strong> is now enabled. Submitting creates the project and starts the <strong>parsing</strong> pipeline. Use <strong>Back to projects</strong> if you want to leave without saving.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="project-new-submit"]', "timeout_ms" => 8000 }
      ]
    }
  ]
)

seed_guided_tour!(
  "Search projects",
  duration_time: 180,
  steps: [
    {
      page_url: "/",
      title: "Browse from the home page",
      focus_element: '[data-guided-tour="welcome-search-projects-body"]',
      description: "<p>Use <strong>Search projects</strong> to open the public browse page. Signed-in users also get extra filters for their own projects. Use <strong>Next</strong> to go to the browse page.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="welcome-search-projects-body"]', "timeout_ms" => 8000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Browse header",
      focus_element: '[data-guided-tour="projects-browse-header"]',
      description: "<p>The browse page title and <strong>New Project</strong> shortcut sit here. Use New Project when you are signed in and ready to upload.</p>",
      step_actions: [
        { "action" => "visit", "path" => "/projects", "skip_if_selector" => '[data-guided-tour="projects-search-form-section"]' },
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-browse-header"]', "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Search and filters",
      focus_element: '[data-guided-tour="projects-search-form-section"]',
      description: "<p>Enter text in the search field and refine the list with organism, project type, tissue, and other filters. Visibility options apply to your own projects when you are logged in.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-search-form-section"]', "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Quick filters",
      focus_element: '[data-guided-tour="projects-filter-row"]',
      description: "<p>The first row of filters covers organism, project type, tissue, technology, and similar facets. Combine them with the search box to narrow the table.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-filter-row"]', "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Sort and view options",
      focus_element: '[data-guided-tour="projects-results-toolbar"]',
      description: "<p>Above the table, adjust sorting and other list controls to reorder results without changing your filter choices.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-results-toolbar"]', "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Results",
      focus_element: '[data-guided-tour="projects-results-section"]',
      description: "<p>Matching projects appear in the table with key metadata. Use <strong>View</strong> on a row to open that project.</p>",
      step_actions: [
        { "action" => "wait_for_selector", "selector" => '[data-guided-tour="projects-results-section"]', "timeout_ms" => 10000 }
      ]
    },
    {
      page_url: "/projects",
      title: "Organism filter",
      focus_element: 'div[data-organism-selector-target="dropdownMenu"]:not(.hidden)',
      description: "<p>Open the organism dropdown to filter by species. You can type to search the list.</p>",
      exclude_from_page_replay: true,
      step_actions: [
        { "action" => "wait_for_selector", "selector" => 'button[data-organism-selector-target="dropdownButton"]', "timeout_ms" => 8000 },
        { "action" => "click", "selector" => 'button[data-organism-selector-target="dropdownButton"]', "skip_if_selector" => 'div[data-organism-selector-target="dropdownMenu"]:not(.hidden)' },
        { "action" => "wait_for_selector", "selector" => 'div[data-organism-selector-target="dropdownMenu"]:not(.hidden)', "timeout_ms" => 4000 }
      ]
    }
  ]
)

puts "  Users can start tours from the Guided tour menu in the header or the Info menu on a project page."
