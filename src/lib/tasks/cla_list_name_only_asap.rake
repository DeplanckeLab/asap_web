# frozen_string_literal: true

# Lists ASAP auto Clas that have a free-text name and/or no ontology term link.
# These are legacy rows from before match-only creation; review manually before cleanup.
#
# Usage:
#   docker compose -f docker-compose.test.yml exec website bundle exec rake cla:list_name_only_asap
#
# Optional env:
#   PROJECT_KEY=my_proj
#   LIMIT=100000
#   INCLUDE_OBSOLETE=1
#   CSV=1                 print CSV header + rows instead of human lines

module ClaListNameOnlyAsap
  module_function

  def csv_escape(value)
    s = value.nil? ? "" : value.to_s
    if s.include?(",") || s.include?('"') || s.include?("\n")
      "\"#{s.gsub('"', '""')}\""
    else
      s
    end
  end
end

namespace :cla do
  desc "List ASAP auto Clas with name set or missing cell_ontology_term_ids (read-only)"
  task list_name_only_asap: :environment do
    source_id = Basic::ASAP_AUTO_CLA_SOURCE_ID
    source = ClaSource.find_by(id: source_id)
    raise "cla_sources id #{source_id} missing (Basic::ASAP_AUTO_CLA_SOURCE_ID)" unless source

    limit = (ENV["LIMIT"].presence || 100_000).to_i
    project_key = ENV["PROJECT_KEY"].to_s.strip
    csv = ENV["CSV"].to_s.strip == "1"

    scope = Cla.where(cla_source_id: source_id)
    if project_key.present?
      project = Project.find_by(key: project_key)
      raise "project with key #{project_key.inspect} not found" unless project

      scope = scope.where(project_id: project.id)
    end
    scope = scope.where(obsolete: [false, nil]) unless ENV["INCLUDE_OBSOLETE"].present?

    scope = scope.where(
      "((clas.name IS NOT NULL AND BTRIM(clas.name) <> '') OR clas.cell_ontology_term_ids IS NULL OR BTRIM(clas.cell_ontology_term_ids::text) = '')"
    )

    puts "cla_id,project_id,project_key,annot_id,annot_name,cat_idx,cat,name,cell_ontology_term_ids,ontology_term_type_id,obsolete" if csv

    scanned = 0
    scope.includes(:annot, :project).find_each do |cla|
      break if scanned >= limit

      scanned += 1
      project = cla.project
      annot = cla.annot
      row = [
        cla.id,
        cla.project_id,
        project&.key,
        cla.annot_id,
        annot&.name,
        cla.cat_idx,
        cla.cat,
        cla.name,
        cla.cell_ontology_term_ids,
        cla.ontology_term_type_id,
        cla.obsolete
      ]

      if csv
        puts row.map { |v| ClaListNameOnlyAsap.csv_escape(v) }.join(",")
      else
        puts "name_only_asap_cla cla_id=#{cla.id} project=#{project&.key.inspect} annot_id=#{cla.annot_id} " \
             "annot=#{annot&.name.inspect} cat_idx=#{cla.cat_idx} cat=#{cla.cat.inspect} " \
             "name=#{cla.name.inspect} cot_ids=#{cla.cell_ontology_term_ids.inspect} " \
             "ott_id=#{cla.ontology_term_type_id.inspect}"
      end
    end

    puts "cla:list_name_only_asap cla_source_id=#{source_id} listed=#{scanned}" unless csv
  end
end
