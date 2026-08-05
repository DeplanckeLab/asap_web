# frozen_string_literal: true

# Find Clas whose ontology terms map to multiple annotation types and split them
# into one Cla per OntologyTermType (unresolved terms become a null-type Cla).
#
# Usage:
#   docker compose -f docker-compose.test.yml exec website \
#     bundle exec rake cla:split_mixed_ontology_term_types DRY_RUN=1
#   docker compose -f docker-compose.test.yml exec website \
#     bundle exec rake cla:split_mixed_ontology_term_types DRY_RUN=0
#
# Optional env:
#   PROJECT_KEY=my_proj
#   LIMIT=100000
#   INCLUDE_OBSOLETE=1
#   DRY_RUN=1             default: no writes (set DRY_RUN=0 to persist)
#   MAX_REPORT_LINES=100

namespace :cla do
  desc "Split Clas whose cell_ontology_term_ids resolve to multiple annotation types (DRY_RUN=1 by default)"
  task split_mixed_ontology_term_types: :environment do
    dry_run = ENV["DRY_RUN"].to_s.strip != "0"
    limit = (ENV["LIMIT"].presence || 100_000).to_i
    max_report = (ENV["MAX_REPORT_LINES"].presence || 100).to_i
    project_key = ENV["PROJECT_KEY"].to_s.strip

    scope = Cla.where.not(cell_ontology_term_ids: [nil, ""])
    scope = scope.where("BTRIM(clas.cell_ontology_term_ids::text) <> ''")
    scope = scope.where("clas.cell_ontology_term_ids LIKE '%,%'")
    if project_key.present?
      project = Project.find_by(key: project_key)
      raise "project with key #{project_key.inspect} not found" unless project

      scope = scope.where(project_id: project.id)
    end
    scope = scope.where(obsolete: [false, nil]) unless ENV["INCLUDE_OBSOLETE"].present?

    counts = Hash.new(0)
    reports = []
    scanned = 0

    puts "cla:split_mixed_ontology_term_types starting dry_run=#{dry_run}"

    scope.find_each do |cla|
      break if scanned >= limit

      scanned += 1
      result = ClaMixedOntologyTypeSplitter.apply!(cla, dry_run: dry_run)
      plan = result[:plan]
      counts[plan.action] += 1
      counts[plan.message] += 1 if plan.message.present?

      next unless plan.action == :split

      counts[:would_split] += 1 if dry_run
      counts[:split] += 1 unless dry_run
      counts[:created_clas] += plan.creates.size unless dry_run

      creates_detail = plan.creates.map { |c|
        "ott=#{c.ontology_term_type_id.inspect}:cots=#{c.cot_ids.join(',')}"
      }.join(' | ')
      prefix = dry_run ? 'dry_run would_split' : 'split'
      reports << "#{prefix} cla_id=#{cla.id} project_id=#{cla.project_id} " \
                 "primary_ott=#{plan.primary_ott_id} primary_cots=#{plan.primary_cot_ids.join(',')} " \
                 "creates=[#{creates_detail}]"

      unless dry_run
        result[:created].each do |new_cla|
          reports << "  created cla_id=#{new_cla.id} ott=#{new_cla.ontology_term_type_id.inspect} " \
                     "cots=#{new_cla.cell_ontology_term_ids} clone_of=#{cla.id}"
        end
      end
    end

    reports.first(max_report).each { |line| puts line }
    puts "... (#{reports.size - max_report} more report lines)" if reports.size > max_report

    puts "cla:split_mixed_ontology_term_types finished scanned=#{scanned} dry_run=#{dry_run} counts=#{counts.inspect}"
  end
end
