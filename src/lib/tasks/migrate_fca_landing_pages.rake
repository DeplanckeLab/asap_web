# frozen_string_literal: true

# Convert legacy projects.landing_page_json (old cell_scatter URL state) into
# visualization checkpoints marked as landing page.
#
# Example legacy payload:
#   {"step":"cell_scatter","s":{
#     "s[csp_params][annot_id]":480566,
#     "s[dr_params][cat_annot_id]":480565,
#     "s[dr_params][dot_size]":5,
#     ...
#   }}
#
# Dry-run (default):
#   docker compose exec website bundle exec rake checkpoints:migrate_fca_landing_pages
#
# Apply:
#   docker compose exec website bundle exec rake checkpoints:migrate_fca_landing_pages APPLY=1
#
# Optional filters:
#   PUBLIC_ID=74   # single ASAP public id
#   PROJECT_KEY=ef1sv5
#   FORCE=1        # replace an existing landing-page checkpoint
namespace :checkpoints do
  desc "Migrate FCA legacy landing_page_json into visualization landing checkpoints"
  task migrate_fca_landing_pages: :environment do
    apply = ENV["APPLY"].to_s == "1"
    force = ENV["FORCE"].to_s == "1"
    title = "Landing page"

    atlas_filter_sql =
      "LOWER(COALESCE(projects.name, '') || ' ' || COALESCE(projects.key, '') || ' ' || COALESCE(projects.description, '')) LIKE ?"
    atlas_terms = ["fca", "fly cell atlas", "flycellatlas"]
    atlas_values = atlas_terms.map { |term| "%#{ActiveRecord::Base.sanitize_sql_like(term)}%" }
    atlas_conditions = atlas_terms.map { atlas_filter_sql }.join(" OR ")

    scope = Project
      .where(public: true, being_deleted: false, cloned_project_id: nil)
      .where([atlas_conditions, *atlas_values])
      .order(:id)

    if ENV["PUBLIC_ID"].present?
      scope = scope.where(public_id: ENV["PUBLIC_ID"].to_i)
    end
    if ENV["PROJECT_KEY"].present?
      scope = scope.where(key: ENV["PROJECT_KEY"].to_s)
    end

    created = 0
    updated = 0
    skipped = 0
    failed = 0

    puts "Mode: #{apply ? 'APPLY' : 'DRY-RUN'}#{force ? ' FORCE' : ''}"
    puts "Projects in scope: #{scope.count}"

    scope.find_each do |project|
      label = "ASAP#{project.public_id || '?'} id=#{project.id} key=#{project.key}"

      data = project.landing_page_data
      settings = data.is_a?(Hash) ? (data["s"] || {}) : {}
      embedding_annot_id = settings["s[csp_params][annot_id]"].presence
      coloring_annot_id = settings["s[dr_params][cat_annot_id]"].presence
      point_size = settings["s[dr_params][dot_size]"].presence

      if embedding_annot_id.blank? || coloring_annot_id.blank?
        puts "SKIP #{label}: missing landing_page_json annot ids"
        skipped += 1
        next
      end

      embedding_annot = Annot.find_by(id: embedding_annot_id, project_id: project.id)
      coloring_annot = Annot.find_by(id: coloring_annot_id, project_id: project.id)
      if embedding_annot.nil? || coloring_annot.nil?
        puts "FAIL #{label}: annot not found emb=#{embedding_annot_id}/#{!!embedding_annot} cat=#{coloring_annot_id}/#{!!coloring_annot}"
        failed += 1
        next
      end

      loom_file = embedding_annot.filepath.presence || coloring_annot.filepath.presence
      if loom_file.blank?
        puts "FAIL #{label}: blank loom filepath on annots"
        failed += 1
        next
      end

      existing = project.checkpoints.visualization.find_by(is_landing_page: true)
      if existing && !force
        puts "SKIP #{label}: landing checkpoint already exists id=#{existing.id} title=#{existing.title.inspect}"
        skipped += 1
        next
      end

      state = {
        "version" => 1,
        "loomFile" => loom_file,
        "embedding" => {
          "id" => embedding_annot.id.to_s,
          "loomFile" => loom_file
        },
        "visualizationEmbedding" => {
          "id" => embedding_annot.id.to_s,
          "loomFile" => loom_file,
          "name" => embedding_annot.name,
          "dimension" => nil
        },
        "matrix" => {
          "layer" => nil,
          "annotId" => nil
        },
        "coloring" => {
          "metadataId" => coloring_annot.id.to_s,
          "geneSetItem" => nil,
          "categoryColorOverrides" => {},
          "customColorRange" => nil,
          "currentColorScheme" => nil,
          "gradientScale" => "normal",
          "metadataGradients" => {},
          "history" => []
        },
        "filters" => {
          "selectedCategories" => {},
          "selectedRanges" => {},
          "metadataFilterSwitches" => {},
          "geneFilterSwitches" => {},
          "globalFiltersEnabled" => true
        },
        "adaptColorRangeByMetadataId" => {},
        "axes" => { "x" => nil, "y" => nil },
        "foldState" => {
          "metadata" => { coloring_annot.id.to_s => true },
          "genes" => {}
        },
        "panelScroll" => {},
        "bottomRightPanel" => nil,
        "genes" => { "tags" => [] },
        "display" => {
          "pointSize" => point_size.present? ? point_size.to_f : nil,
          "categoryOrder" => "largest-first",
          "numericalOrder" => "negative-to-positive",
          "histogramScale" => "normal",
          "histogramIgnoreZeros" => true,
          "metadataHistogramOptions" => {},
          "showGrid" => true,
          "showAxes" => true,
          "showCategories" => true,
          "showLabelBoxes" => true,
          "labelFontSizeMode" => "auto",
          "labelFontSize" => 12,
          "truncateLongLabels" => true,
          "freezeMovedLabels" => true,
          "labelPlacementMode" => "avoid-collisions",
          "manualLabelLocks" => {}
        },
        "customPlotWindow" => nil,
        "interaction" => {
          "mode" => "pick",
          "bounds" => nil
        },
        "selection" => {
          "selectedCells" => [],
          "activeTab" => "gene-sets"
        }
      }

      action = existing ? "UPDATE" : "CREATE"
      puts "#{action} #{label}: emb=#{embedding_annot.id}(#{embedding_annot.name}) color=#{coloring_annot.id}(#{coloring_annot.name}) loom=#{loom_file} pointSize=#{state.dig('display', 'pointSize').inspect}"

      next unless apply

      ActiveRecord::Base.transaction do
        project.checkpoints.visualization.where(is_landing_page: true).update_all(is_landing_page: false)

        checkpoint = existing || project.checkpoints.visualization.new
        checkpoint.user = project.user
        checkpoint.title = title
        checkpoint.kind = Checkpoint::KIND_VISUALIZATION
        checkpoint.run_id = nil
        checkpoint.state = state
        checkpoint.comments = checkpoint.comments.presence || []
        checkpoint.is_landing_page = true
        checkpoint.save!
      end

      if existing
        updated += 1
      else
        created += 1
      end
    end

    puts "Done. created=#{created} updated=#{updated} skipped=#{skipped} failed=#{failed} apply=#{apply}"
  end
end
