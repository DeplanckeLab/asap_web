# frozen_string_literal: true

# Finds pipeline runs whose stored JSON (attrs / output / command) references a given Annot id.
# Used for metadata import overwrite safety (R-M5) — no silent replace while runs still point at the column.
class RunAnnotReferenceScanner
  class << self
    def run_ids_referencing_annot(project_id, annot_id)
      aid = annot_id.to_i
      return [] if aid <= 0

      hits = []
      Run.where(project_id: project_id).find_each do |run|
        next unless blob_references_annot_id?(run.attrs_json, aid) ||
                    blob_references_annot_id?(run.output_json, aid) ||
                    blob_references_annot_id?(run.command_json, aid)

        hits << run.id
      end
      hits
    end

    def dependent_run_count(project_id, annot_ids)
      annot_ids.map(&:to_i).uniq.select(&:positive?).sum do |aid|
        run_ids_referencing_annot(project_id, aid).size
      end
    end

    private

    def blob_references_annot_id?(raw, annot_id)
      parsed = Basic.safe_parse_json(raw, nil)
      return false if parsed.nil?

      walk(parsed, annot_id)
    end

    def walk(obj, annot_id)
      case obj
      when Hash
        obj.any? do |k, v|
          (k.to_s == "annot_id" && v.to_i == annot_id) || walk(v, annot_id)
        end
      when Array
        obj.any? { |e| walk(e, annot_id) }
      else
        false
      end
    end
  end
end
