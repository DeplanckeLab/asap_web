# frozen_string_literal: true

# Verifies Cla rows created by Basic.add_clas (ASAP auto annotations) against the same rules used at creation:
# - ASAP auto Clas must have a perfect ontology term match (no name-only free-text rows)
# - category string maps via Basic.h_cell_ontology_terms_by_cat_label (identifier before name, stable id;
#   chosen term: exact species ontology > same NCBI order > universal (empty tax_ids); multiple_cot_rows uses same tier)
# - cell_ontology_term_ids must equal that chosen term id
# - name must be blank when an ontology term is linked
# - ontology_term_type_id must match ClaOntologyTermTypeResolver when uniquely resolvable
# - cla.cat must match annot.list_cat_json at cla.cat_idx when list_cat_json is present
#
# Usage (docker-compose website container):
#   docker compose -f docker-compose.test.yml exec website bundle exec rake cla:verify_asap
#
# Optional env:
#   PROJECT_KEY=my_proj   only clas for that project
#   LIMIT=5000            max clas scanned (default 100000)
#   INCLUDE_OBSOLETE=1    include obsolete clas
#   MAX_WARN_LINES=50     cap warning lines printed (default 50)
#   MAX_ERROR_LINES=200   cap error lines printed (default 200)
#   RAISE_ON_ERROR=0      print summary only, exit 0 even when errors exist (for sampling)

namespace :cla do
  desc "Verify ASAP auto Clas against Basic.add_clas ontology and list_cat rules (see task file for env vars)"
  task verify_asap: :environment do
    source_id = Basic::ASAP_AUTO_CLA_SOURCE_ID
    source = ClaSource.find_by(id: source_id)
    raise "cla_sources id #{source_id} missing (Basic::ASAP_AUTO_CLA_SOURCE_ID)" unless source

    limit = (ENV["LIMIT"].presence || 100_000).to_i
    max_warn = (ENV["MAX_WARN_LINES"].presence || 50).to_i
    max_err = (ENV["MAX_ERROR_LINES"].presence || 200).to_i
    raise_on_error = ENV["RAISE_ON_ERROR"] != "0"
    project_key = ENV["PROJECT_KEY"].to_s.strip

    scope = Cla.where(cla_source_id: source_id)
    if project_key.present?
      project = Project.find_by(key: project_key)
      raise "project with key #{project_key.inspect} not found" unless project

      scope = scope.where(project_id: project.id)
    end
    scope = scope.where(obsolete: [false, nil]) unless ENV["INCLUDE_OBSOLETE"].present?

    scanned = 0
    errors_by_cla = {}
    warnings = []

    scope.includes(:annot, project: :organism).find_each do |cla|
      break if scanned >= limit

      scanned += 1
      cat = cla.cat.to_s
      annot = cla.annot
      cla_errs = []

      if annot && annot.list_cat_json.present?
        list_cats = Basic.safe_parse_json(annot.list_cat_json, [])
        expected = list_cats[cla.cat_idx]
        if expected.nil?
          cla_errs << "list_cat_idx cat_idx=#{cla.cat_idx} out of range (list size #{list_cats.size}) annot_id=#{annot.id}"
        elsif expected.to_s != cat
          cla_errs << "list_cat_mismatch cla.cat=#{cat.inspect} list_cat_json[#{cla.cat_idx}]=#{expected.inspect} annot_id=#{annot.id}"
        end
      end

      if cat.blank?
        warnings << { id: cla.id, kind: "empty_cat", detail: "annot_id=#{cla.annot_id}" }
        errors_by_cla[cla.id] = cla_errs.join("; ") if cla_errs.any?
        next
      end

      project_tax_id = cla.project&.organism&.tax_id
      order_memo = {}
      chosen = Basic.h_cell_ontology_terms_by_cat_label([cat], project_tax_id)[cat]
      tier = if project_tax_id.present?
               chosen && Basic.cell_ontology_match_tier(chosen, project_tax_id, order_tax_id_memo: order_memo)
             end

      all_matches = CellOntologyTerm.original.with_active_cell_ontology
        .where("cell_ontology_terms.identifier IN (?) OR cell_ontology_terms.name IN (?)", [cat], [cat])
        .includes(:cell_ontology)
        .order(:id)
        .to_a
        .select { |term| Basic.cell_ontology_term_applicable_to_tax_id?(term, project_tax_id, order_tax_id_memo: order_memo) }

      if tier
        all_matches = all_matches.select { |t| Basic.cell_ontology_match_tier(t, project_tax_id, order_tax_id_memo: order_memo) == tier }
      end

      stored_raw = cla.cell_ontology_term_ids.to_s.strip
      stored_ids = stored_raw.split(",").map(&:strip).reject(&:empty?).map(&:to_i).uniq

      if all_matches.size > 1
        warnings << { id: cla.id, kind: "multiple_cot_rows_for_label", detail: "cat=#{cat.inspect} term_ids=#{all_matches.map(&:id).join(',')} chosen_id=#{chosen&.id}" }
      end

      # Match-only rule: ASAP auto Clas without a resolvable ontology term are invalid
      # (use cla:list_name_only_asap to inventory them for manual cleanup).
      if chosen.nil?
        cla_errs << "name_only_or_unmatched_asap_auto cat=#{cat.inspect} name=#{cla.name.inspect} stored_ids=#{stored_ids.inspect}"
        errors_by_cla[cla.id] = cla_errs.join("; ")
        next
      end

      if stored_ids.empty?
        cla_errs << "missing_ontology_ids cat=#{cat.inspect} expected_term_id=#{chosen.id}"
      elsif stored_ids.size > 1
        cla_errs << "multiple_stored_ids stored=#{stored_ids.inspect} cat=#{cat.inspect}"
      elsif stored_ids.first != chosen.id
        cla_errs << "ontology_id_wrong stored_id=#{stored_ids.first} expected_id=#{chosen.id} cat=#{cat.inspect}"
      end

      if cla.name.to_s.strip != ""
        cla_errs << "name_should_be_blank ontology linked but name=#{cla.name.inspect}"
      end

      type_ids = stored_ids.presence || [chosen.id]
      type_result = ClaOntologyTermTypeResolver.call(type_ids)
      if type_result.status == :unique
        if cla.ontology_term_type_id.nil?
          cla_errs << "missing_ontology_term_type_id expected=#{type_result.ontology_term_type_id}"
        elsif cla.ontology_term_type_id != type_result.ontology_term_type_id
          cla_errs << "ontology_term_type_id_wrong stored=#{cla.ontology_term_type_id} expected=#{type_result.ontology_term_type_id}"
        end
      elsif type_result.status == :ambiguous
        warnings << {
          id: cla.id,
          kind: "ambiguous_ontology_term_type",
          detail: "cot_ids=#{type_ids.inspect} candidates=#{type_result.candidate_ids.inspect} stored_ott=#{cla.ontology_term_type_id.inspect}"
        }
      elsif cla.ontology_term_type_id.present?
        warnings << {
          id: cla.id,
          kind: "unresolved_ontology_term_type_but_set",
          detail: "status=#{type_result.status} stored_ott=#{cla.ontology_term_type_id}"
        }
      end

      errors_by_cla[cla.id] = cla_errs.join("; ") if cla_errs.any?
    end

    error_count = errors_by_cla.size
    puts "cla:verify_asap cla_source_id=#{source_id} (#{source.name}) scanned=#{scanned} errors=#{error_count} warnings=#{warnings.size}"

    warnings.first(max_warn).each do |w|
      puts "WARN cla_id=#{w[:id]} #{w[:kind]} #{w[:detail]}"
    end
    puts "WARN ... (#{warnings.size - max_warn} more)" if warnings.size > max_warn

    errors_by_cla.first(max_err).each do |cla_id, msg|
      puts "ERR  cla_id=#{cla_id} #{msg}"
    end
    puts "ERR  ... (#{error_count - max_err} more)" if error_count > max_err

    if error_count.positive? && raise_on_error
      raise "cla:verify_asap failed: #{error_count} cla(s) with errors"
    end
  end
end
