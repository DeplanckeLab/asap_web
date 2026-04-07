# frozen_string_literal: true

# Finds pipeline runs that depend on a target {Annot} for metadata import overwrite safety (R-M5).
#
# A run is considered dependent if any of the following hold:
# - {attrs_json}, {output_json}, or {command_json} references the annot id (annot_id and common *\_annot_id keys)
#   or embeds the LOOM path string exactly ({/col_attrs/...}, {/row_attrs/...})
# - Those JSON blobs list the annot's producing run in {input_run_ids}, {input_run_id}, or {lineage_run_ids}
# - The run's own {lineage_run_ids} includes the annot's producing run (downstream steps in the same pipeline)
#
# The producing run is {Annot#run_id} or, if absent, {Annot#ori_run_id}. The producing run itself is excluded.
class RunAnnotReferenceScanner
  PATH_PREFIX_RE = %r{\A/(?:col_attrs|row_attrs)/}.freeze

  INPUT_RUN_KEYS = %w[input_run_ids lineage_run_ids].freeze

  class << self
    def run_ids_referencing_annot(project_id, annot_or_id)
      annot = resolve_annot(project_id, annot_or_id)
      return [] unless annot

      producer_id = producer_run_id(annot)
      hits = []

      Run.where(project_id: project_id).find_each do |run|
        hits << run.id if run_depends_on_annot?(run, annot, producer_id)
      end

      hits.uniq
    end

    def dependent_run_count(project_id, annot_ids)
      annot_ids.map(&:to_i).uniq.select(&:positive?).sum do |aid|
        run_ids_referencing_annot(project_id, aid).size
      end
    end

    private

    def resolve_annot(project_id, annot_or_id)
      case annot_or_id
      when Annot
        annot_or_id.project_id.to_i == project_id.to_i ? annot_or_id : nil
      else
        Annot.find_by(id: annot_or_id.to_i, project_id: project_id)
      end
    end

    def producer_run_id(annot)
      rid = annot.run_id.presence || annot.ori_run_id
      rid.to_i
    end

    def run_depends_on_annot?(run, annot, producer_id)
      if json_blobs_reference_annot?(run.attrs_json, annot) ||
         json_blobs_reference_annot?(run.output_json, annot) ||
         json_blobs_reference_annot?(run.command_json, annot)
        return true
      end

      return false unless producer_id.positive?
      return false if run.id == producer_id

      if lineage_field_includes_run?(run.lineage_run_ids, producer_id)
        return true
      end

      if json_blobs_reference_producer_run?(run.attrs_json, producer_id) ||
         json_blobs_reference_producer_run?(run.output_json, producer_id) ||
         json_blobs_reference_producer_run?(run.command_json, producer_id)
        return true
      end

      false
    end

    def lineage_field_includes_run?(lineage_raw, run_id)
      lineage_raw.to_s.split(",").map(&:strip).map(&:to_i).include?(run_id)
    end

    def json_blobs_reference_annot?(raw, annot)
      parsed = Basic.safe_parse_json(raw, nil)
      return false if parsed.nil?

      walk_annot_ref(parsed, annot)
    end

    def walk_annot_ref(obj, annot)
      aid = annot.id.to_i
      path = annot.name.to_s
      path_match = path.match?(PATH_PREFIX_RE)

      case obj
      when Hash
        obj.any? do |k, v|
          key = k.to_s
          if key_reference_matches_annot?(key, v, aid, path, path_match)
            true
          else
            walk_annot_ref(v, annot)
          end
        end
      when Array
        obj.any? { |e| walk_annot_ref(e, annot) }
      when String
        path_match && obj == path
      else
        false
      end
    end

    def key_reference_matches_annot?(key, value, annot_id, path, path_match)
      case key
      when "annot_id", "embedding_metadata_id", "matrix_annot_id", "metadata_annot_id",
           "source_annot_id", "target_annot_id", "selection_annot_id"
        value.to_i == annot_id
      else
        if key.end_with?("_annot_id")
          i = Integer(value) rescue nil
          !i.nil? && i == annot_id
        elsif path_match && value.is_a?(String) && value == path
          true
        else
          false
        end
      end
    end

    def json_blobs_reference_producer_run?(raw, producer_id)
      parsed = Basic.safe_parse_json(raw, nil)
      return false if parsed.nil?

      walk_producer_run_ref(parsed, producer_id)
    end

    def walk_producer_run_ref(obj, producer_id)
      case obj
      when Hash
        obj.any? do |k, v|
          key = k.to_s
          if INPUT_RUN_KEYS.include?(key) && comma_list_includes_id?(v, producer_id)
            true
          elsif key == "input_run_id" && v.to_i == producer_id
            true
          else
            walk_producer_run_ref(v, producer_id)
          end
        end
      when Array
        obj.any? { |e| walk_producer_run_ref(e, producer_id) }
      else
        false
      end
    end

    def comma_list_includes_id?(value, id)
      value.to_s.split(",").map(&:strip).map(&:to_i).include?(id)
    end
  end
end
