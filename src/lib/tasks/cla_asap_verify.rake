# frozen_string_literal: true

# Verifies Cla rows created by Basic.add_clas (ASAP auto annotations) against the same rules used at creation:
# - category string maps via Basic.h_cell_ontology_terms_by_cat_label (identifier before name, stable id)
# - cell_ontology_term_ids must equal that chosen term id (or be empty when there is no match)
# - name must be blank when an ontology term is linked, else equal to the category label
# - cla.cat must match annot.list_cat_json at cla.cat_idx when list_cat_json is present
#
# Usage (docker-compose website container):
#   docker compose -f docker-compose.test.yml exec website bundle exec rake cla:verify_asap
#
# Optional env:
#   PROJECT_ID=123        only clas for that project
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

    scope = Cla.where(cla_source_id: source_id)
    scope = scope.where(project_id: ENV["PROJECT_ID"].to_i) if ENV["PROJECT_ID"].present?
    scope = scope.where(obsolete: [false, nil]) unless ENV["INCLUDE_OBSOLETE"].present?

    scanned = 0
    errors_by_cla = {}
    warnings = []

    scope.includes(:annot).find_each do |cla|
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

      chosen = Basic.h_cell_ontology_terms_by_cat_label([cat])[cat]
      all_matches = CellOntologyTerm.original
        .where("identifier IN (?) OR name IN (?)", [cat], [cat])
        .order(:id)
        .to_a

      stored_raw = cla.cell_ontology_term_ids.to_s.strip
      stored_ids = stored_raw.split(",").map(&:strip).reject(&:empty?).map(&:to_i).uniq

      if all_matches.size > 1
        warnings << { id: cla.id, kind: "multiple_cot_rows_for_label", detail: "cat=#{cat.inspect} term_ids=#{all_matches.map(&:id).join(',')} chosen_id=#{chosen&.id}" }
      end

      if chosen.nil?
        if stored_ids.any?
          cot = CellOntologyTerm.where(id: stored_ids).pick(:id, :identifier, :name)
          cla_errs << "stored_ontology_not_exact_match cat=#{cat.inspect} stored_ids=#{stored_ids.inspect} term=#{cot.inspect}"
        elsif cla.name.to_s.strip != cat
          cla_errs << "name_without_match expected name==cat #{cat.inspect}, got #{cla.name.inspect}"
        end
      else
        if stored_ids.empty?
          cla_errs << "missing_ontology_ids cat=#{cat.inspect} expected_term_id=#{chosen.id}"
        elsif stored_ids.size > 1
          cla_errs << "multiple_stored_ids stored=#{stored_ids.inspect} cat=#{cat.inspect}"
        elsif stored_ids.first != chosen.id
          cla_errs << "ontology_id_wrong stored_id=#{stored_ids.first} expected_id=#{chosen.id} cat=#{cat.inspect}"
        end

        if stored_ids.any? && cla.name.to_s.strip != ""
          cla_errs << "name_should_be_blank ontology linked but name=#{cla.name.inspect}"
        end
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
