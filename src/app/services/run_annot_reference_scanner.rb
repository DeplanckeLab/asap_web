# frozen_string_literal: true

# Finds pipeline runs that depend on a target {Annot} for metadata import overwrite
# safety (R-M5), type-edit blocking, and annot show "used as input" listing.
#
# A run is considered dependent only when {attrs_json}, {output_json}, or
# {command_json} directly references this annot:
# - annot id via annot_id and common *_annot_id / *_metadata_id keys
# - LOOM path string exactly ({/col_attrs/...}, {/row_attrs/...})
#
# Downstream lineage alone (run.lineage_run_ids including the producing run, or
# input_run_ids pointing at that run) is not enough: a parsing run produces many
# columns, and later steps typically consume the matrix, not every metadata field.
class RunAnnotReferenceScanner
  PATH_PREFIX_RE = %r{\A/(?:col_attrs|row_attrs)/}.freeze

  class << self
    def run_ids_referencing_annot(project_id, annot_or_id)
      annot = resolve_annot(project_id, annot_or_id)
      return [] unless annot

      hits = []

      Run.where(project_id: project_id).find_each do |run|
        hits << run.id if run_depends_on_annot?(run, annot)
      end

      hits.uniq
    end

    # Same-name Annot rows (across loom files) share type-edit / overwrite fate.
    def run_ids_referencing_annot_name(project_id, annot_name)
      Annot.where(project_id: project_id, name: annot_name).flat_map do |a|
        run_ids_referencing_annot(project_id, a)
      end.uniq
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

    def run_depends_on_annot?(run, annot)
      json_blobs_reference_annot?(run.attrs_json, annot) ||
        json_blobs_reference_annot?(run.output_json, annot) ||
        json_blobs_reference_annot?(run.command_json, annot)
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
           "source_annot_id", "target_annot_id", "selection_annot_id", "metadata_id",
           "source_metadata_id"
        value.to_i == annot_id
      else
        if key.end_with?("_annot_id") || key.end_with?("_metadata_id")
          i = Integer(value) rescue nil
          !i.nil? && i == annot_id
        elsif path_match && value.is_a?(String) && value == path
          true
        else
          false
        end
      end
    end
  end
end
