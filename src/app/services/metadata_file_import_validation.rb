# frozen_string_literal: true

# Validates file metadata import: reserved names (R-NM2), collisions, and overwrite safety (R-M5).
class MetadataFileImportValidation
  Check = Struct.new(:path, :authorized, :auth_reason, :auth_message, :collision, :annot_ids, :dependent_run_ids,
                     :dependents, keyword_init: true)

  class << self
    def analyze(project:, metadata_type_id:, input_type_id:, name:, header_name:, has_header:, raw_content:)
      paths = MetadataImportPathResolver.candidate_paths(
        metadata_type_id: metadata_type_id,
        input_type_id: input_type_id,
        name: name,
        header_name: header_name,
        has_header: has_header,
        raw_content: raw_content
      )

      return { skip_name_checks: true, checks: [], paths: [], dependents: nil } if paths == :global
      return { skip_name_checks: false, error: missing_name_message(input_type_id, has_header), checks: [], paths: [], dependents: nil } if paths.empty?

      checks = paths.map { |path| build_check(project, path) }
      colliding_dependents = checks.select(&:collision).filter_map(&:dependents)
      {
        skip_name_checks: false,
        error: nil,
        checks: checks,
        paths: paths,
        dependents: merge_check_dependents(colliding_dependents)
      }
    end

    def next_versioned_path(project, import_path)
      MetadataCollisionBackupNaming.next_path(project, import_path)
    end

    # Alias used by callers that archive on name collision.
    def next_backup_path(project, import_path)
      next_versioned_path(project, import_path)
    end

    private

    def missing_name_message(input_type_id, has_header)
      it = input_type_id.to_s
      if it == "2" && !MetadataImportPathResolver.truthy_header?(has_header)
        "Matrix import requires a header row with column names after the first column."
      elsif it == "1"
        "Enter a metadata name (LOOM path or basename) before previewing."
      else
        "Could not determine metadata column name from this file."
      end
    end

    def build_check(project, path)
      auth = MetadataNameAuthorizationService.call(project: project, name: path)
      unless auth.authorized
        return Check.new(
          path: path,
          authorized: false,
          auth_reason: auth.reason,
          auth_message: auth.message,
          collision: false,
          annot_ids: [],
          dependent_run_ids: [],
          dependents: nil
        )
      end

      annots = Annot.where(project_id: project.id, name: path).to_a
      if annots.empty?
        return Check.new(
          path: path,
          authorized: true,
          auth_reason: nil,
          auth_message: nil,
          collision: false,
          annot_ids: [],
          dependent_run_ids: [],
          dependents: nil
        )
      end

      ids = annots.map(&:id)
      inventories = annots.map { |annot| AnnotDependentsInventory.call(project: project, annot: annot) }
      dependents = AnnotDependentsInventory.merge_results(inventories)
      dep_run_ids = Array(dependents && dependents[:run_ids_to_delete]).map(&:to_i)
      Check.new(
        path: path,
        authorized: true,
        auth_reason: nil,
        auth_message: nil,
        collision: true,
        annot_ids: ids,
        dependent_run_ids: dep_run_ids,
        dependents: dependents
      )
    end

    def merge_check_dependents(dependents_list)
      list = Array(dependents_list).compact
      return nil if list.empty?
      return list.first if list.size == 1

      annot_results = list.flat_map { |d| Array(d[:annots]) }
      run_ids = list.flat_map { |d| Array(d[:run_ids_to_delete]) }.map(&:to_i).uniq.select(&:positive?)
      summary = list.map { |d| d[:summary] || {} }
      {
        annots: annot_results,
        run_ids_to_delete: run_ids,
        summary: {
          annot_count: annot_results.size,
          selection_count: summary.sum { |s| s[:selection_count].to_i },
          run_count: summary.sum { |s| s[:run_count].to_i },
          run_ids_to_delete_count: run_ids.size,
          cla_count: summary.sum { |s| s[:cla_count].to_i },
          annot_cell_set_count: summary.sum { |s| s[:annot_cell_set_count].to_i },
          manual_review_count: summary.sum { |s| s[:manual_review_count].to_i },
          has_cascade_targets: run_ids.any?
        }
      }
    end
  end
end
