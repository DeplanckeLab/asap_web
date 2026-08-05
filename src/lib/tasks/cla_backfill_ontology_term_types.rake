# frozen_string_literal: true

# Backfill clas.ontology_term_type_id from cell_ontology_term_ids using
# ClaOntologyTermTypeResolver (ontology whitelist + rules.yaml semantic roots).
#
# Usage:
#   docker compose -f docker-compose.test.yml exec website \
#     bundle exec rake cla:backfill_ontology_term_types DRY_RUN=1
#   docker compose -f docker-compose.test.yml exec website \
#     bundle exec rake cla:backfill_ontology_term_types DRY_RUN=0
#
# Optional env:
#   PROJECT_KEY=my_proj
#   LIMIT=100000
#   INCLUDE_OBSOLETE=1
#   FORCE=1               also overwrite already-set ontology_term_type_id when uniquely resolvable
#   DRY_RUN=1             default: no writes (set DRY_RUN=0 to persist)
#   MAX_REPORT_LINES=100

namespace :cla do
  desc "Backfill ontology_term_type_id on Clas that have cell_ontology_term_ids"
  task backfill_ontology_term_types: :environment do
    dry_run = ENV["DRY_RUN"].to_s.strip != "0"
    force = ENV["FORCE"].to_s.strip == "1"
    limit = (ENV["LIMIT"].presence || 100_000).to_i
    max_report = (ENV["MAX_REPORT_LINES"].presence || 100).to_i
    project_key = ENV["PROJECT_KEY"].to_s.strip

    scope = Cla.where.not(cell_ontology_term_ids: [nil, ""])
    scope = scope.where("BTRIM(clas.cell_ontology_term_ids::text) <> ''")
    if project_key.present?
      project = Project.find_by(key: project_key)
      raise "project with key #{project_key.inspect} not found" unless project

      scope = scope.where(project_id: project.id)
    end
    scope = scope.where(obsolete: [false, nil]) unless ENV["INCLUDE_OBSOLETE"].present?
    scope = scope.where(ontology_term_type_id: nil) unless force

    counts = Hash.new(0)
    reports = []
    scanned = 0

    puts "cla:backfill_ontology_term_types starting dry_run=#{dry_run} force=#{force}"

    scope.find_each do |cla|
      break if scanned >= limit

      scanned += 1
      result = ClaOntologyTermTypeResolver.call(cla.cell_ontology_term_ids)
      counts[result.status] += 1

      case result.status
      when :unique
        if cla.ontology_term_type_id == result.ontology_term_type_id
          counts[:unchanged] += 1
        elsif cla.ontology_term_type_id.present? && !force
          counts[:skipped_existing] += 1
        else
          counts[:would_update] += 1
          detail = "cla_id=#{cla.id} project_id=#{cla.project_id} " \
                   "cot_ids=#{cla.cell_ontology_term_ids.inspect} " \
                   "from=#{cla.ontology_term_type_id.inspect} to=#{result.ontology_term_type_id}"
          reports << (dry_run ? "dry_run would_set #{detail}" : "updated #{detail}")
          unless dry_run
            cla.update!(ontology_term_type_id: result.ontology_term_type_id)
            counts[:updated] += 1
          end
        end
      when :ambiguous
        groups = ClaOntologyTermTypeResolver.group_cot_ids_by_type(cla.cell_ontology_term_ids)
        typed = groups.reject { |ott_id, _| ott_id.nil? }
        if typed.size >= 2
          counts[:needs_split] += 1
          reports << "needs_split cla_id=#{cla.id} cot_ids=#{cla.cell_ontology_term_ids.inspect} " \
                     "groups=#{typed.transform_values { |ids| ids.join(',') }.inspect} " \
                     "(run cla:split_mixed_ontology_term_types)"
        else
          reports << "ambiguous cla_id=#{cla.id} cot_ids=#{cla.cell_ontology_term_ids.inspect} " \
                     "candidates=#{result.candidate_ids.inspect} stored=#{cla.ontology_term_type_id.inspect}"
        end
      when :unresolved, :missing_terms, :missing_ontology, :empty
        reports << "#{result.status} cla_id=#{cla.id} cot_ids=#{cla.cell_ontology_term_ids.inspect} " \
                   "stored=#{cla.ontology_term_type_id.inspect}"
      end
    end

    reports.first(max_report).each { |line| puts line }
    puts "... (#{reports.size - max_report} more report lines)" if reports.size > max_report

    puts "cla:backfill_ontology_term_types finished scanned=#{scanned} dry_run=#{dry_run} counts=#{counts.inspect}"
  end
end
