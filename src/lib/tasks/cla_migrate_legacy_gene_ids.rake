# frozen_string_literal: true

# Migrate Cla up/down gene fields from legacy asap_data genes.id to loom _StableID.
#
# Mapping:
#   1. genes.id -> ensembl_id -> autocomplete stable id
#   2. if ensembl miss: genes.name -> exact autocomplete symbol with a single stable id
#
# When project files are missing on disk and the project is archived on S3, the task
# temporarily unarchives, migrates, then deletes local files and sets archive_status_id=3
# again (no S3 re-upload).
#
# Usage:
#   docker compose exec website \
#     bundle exec rake cla:migrate_legacy_gene_ids
#   docker compose exec website \
#     bundle exec rake cla:migrate_legacy_gene_ids DRY_RUN=0
#
# Optional env:
#   PROJECT_KEY=v9ylud
#   LIMIT=100000
#   INCLUDE_OBSOLETE=1
#   DRY_RUN=1             default: no writes to clas (set DRY_RUN=0 to persist)
#   WITH_UNARCHIVE=1      default: temporarily unarchive archived projects missing on disk
#   MAX_REPORT_LINES=200
#   MAX_UNRESOLVED_LINES=200

namespace :cla do
  desc "Migrate Cla gene fields from asap_data genes.id to loom stable ids (DRY_RUN=1 by default)"
  task migrate_legacy_gene_ids: :environment do
    dry_run = ENV["DRY_RUN"].to_s.strip != "0"
    with_unarchive = ENV["WITH_UNARCHIVE"].to_s.strip != "0"
    limit = (ENV["LIMIT"].presence || 100_000).to_i
    max_report = (ENV["MAX_REPORT_LINES"].presence || 200).to_i
    max_unresolved = (ENV["MAX_UNRESOLVED_LINES"].presence || 200).to_i
    project_key = ENV["PROJECT_KEY"].to_s.strip

    scope = Cla.all
    scope = scope.where(obsolete: [false, nil]) unless ENV["INCLUDE_OBSOLETE"].present?
    if project_key.present?
      project = Project.find_by(key: project_key)
      raise "project with key #{project_key.inspect} not found" unless project

      scope = scope.where(project_id: project.id)
    end

    min_id = ClaLegacyGeneIdMigrator::LEGACY_GENE_ID_MIN
    scope = scope.where(
      "(up_gene_ids ~ ? OR down_gene_ids ~ ? OR sorted_up_gene_ids ~ ? OR sorted_down_gene_ids ~ ?)",
      "(^|,)[0-9]{6,}(,|$)",
      "(^|,)[0-9]{6,}(,|$)",
      "(^|,)[0-9]{6,}(,|$)",
      "(^|,)[0-9]{6,}(,|$)"
    )

    counts = Hash.new(0)
    reports = []
    unresolved_reports = []
    scanned = 0
    caches = {
      project: {},
      db_name: {},
      gene_by_id: {},
      autocomplete_by_project_annot: {}
    }
    migrator = ClaLegacyGeneIdMigrator.new(caches: caches)

    puts "cla:migrate_legacy_gene_ids starting dry_run=#{dry_run} with_unarchive=#{with_unarchive} " \
         "project_key=#{project_key.inspect} legacy_gene_id_min=#{min_id}"

    clas_by_project = Hash.new { |h, k| h[k] = [] }
    scope.find_each do |cla|
      break if scanned >= limit

      scanned += 1
      clas_by_project[cla.project_id] << cla
    end

    clas_by_project.each do |project_id, clas|
      project = Project.find_by(id: project_id)
      unless project
        counts[:missing_project] += clas.size
        clas.each do |cla|
          counts[:skip] += 1
          reports << "skip missing_project cla_id=#{cla.id} project_id=#{project_id}"
        end
        next
      end

      ensure_info = { status: :present }
      if with_unarchive && !migrator.autocomplete_available?(project)
        ensure_info = migrator.ensure_local_data!(project)
        counts[:"ensure_#{ensure_info[:status]}"] += 1
        puts "project=#{project.key} ensure_local_data status=#{ensure_info[:status]} " \
             "detail=#{ensure_info[:detail].inspect}"
      end

      begin
        clas.each do |cla|
          result = migrator.call(cla, dry_run: dry_run)
          counts[result.action] += 1
          counts[result.reason] += 1 if result.reason.present?
          (result.resolved_via || {}).each do |via, n|
            counts[:"via_#{via}"] += n
          end

          case result.action
          when :would_update, :updated
            changes = result.field_changes.map { |field, change|
              "#{field}:#{change[:from]}=>#{change[:to]}"
            }.join(" | ")
            via_note = result.resolved_via.present? ? " via=#{result.resolved_via.inspect}" : ""
            prefix = result.action == :would_update ? "dry_run would_update" : "updated"
            reports << "#{prefix} cla_id=#{result.cla_id} project=#{result.project_key}#{via_note} #{changes}"
          when :unresolved
            result.unresolved.each do |item|
              hits = Array(item[:autocomplete_symbol_hits])
              hit_note = hits.empty? ? "autocomplete_symbol_hits=(none)" : "autocomplete_symbol_hits=#{hits.inspect}"
              unresolved_reports << (
                "unresolved cla_id=#{result.cla_id} project=#{result.project_key} " \
                "field=#{item[:field]} gene_id=#{item[:gene_id]} reason=#{item[:reason]} " \
                "ensembl_id=#{item[:ensembl_id].inspect} gene_name=#{item[:gene_name].inspect} " \
                "#{hit_note}"
              )
            end
            counts[:unresolved_gene_refs] += result.unresolved.size
          when :skip
            # counted via reason
          end
        end
      ensure
        if ensure_info[:status] == :unarchived
          puts "project=#{project.key} restore_archived disk_size_archived=#{ensure_info[:disk_size_archived].inspect}"
          migrator.restore_archived!(project, disk_size_archived: ensure_info[:disk_size_archived])
          counts[:restored_archived] += 1
        end
      end
    end

    puts "--- updates (first #{max_report}) ---"
    reports.first(max_report).each { |line| puts line }
    puts "... (#{reports.size - max_report} more update lines)" if reports.size > max_report

    puts "--- unresolved stable ids (first #{max_unresolved}) ---"
    if unresolved_reports.empty?
      puts "(none)"
    else
      unresolved_reports.first(max_unresolved).each { |line| puts line }
      puts "... (#{unresolved_reports.size - max_unresolved} more unresolved lines)" if unresolved_reports.size > max_unresolved
    end

    puts "cla:migrate_legacy_gene_ids finished scanned=#{scanned} dry_run=#{dry_run} " \
         "with_unarchive=#{with_unarchive} update_lines=#{reports.size} " \
         "unresolved_lines=#{unresolved_reports.size} counts=#{counts.inspect}"

    if unresolved_reports.any?
      puts "NOTE: Clas with unresolved genes were left unchanged. Fix loom/autocomplete coverage " \
           "or review those gene ids before re-running with DRY_RUN=0."
    end
  end
end
