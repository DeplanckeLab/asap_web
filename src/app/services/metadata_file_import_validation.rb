# frozen_string_literal: true

# Validates file metadata import: reserved names (R-NM2), collisions, and overwrite safety (R-M5).
class MetadataFileImportValidation
  Check = Struct.new(:path, :authorized, :auth_reason, :auth_message, :collision, :annot_ids, :dependent_run_ids,
                     keyword_init: true)

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

      return { skip_name_checks: true, checks: [], paths: [] } if paths == :global
      return { skip_name_checks: false, error: missing_name_message(input_type_id, has_header), checks: [], paths: [] } if paths.empty?

      checks = paths.map { |path| build_check(project, path) }
      {
        skip_name_checks: false,
        error: nil,
        checks: checks,
        paths: paths
      }
    end

    def next_versioned_path(project, import_path)
      base = import_path.to_s.sub(MetadataNameAuthorizationService::VERSION_SUFFIX_PATTERN, "")
      existing = Annot.where(project_id: project.id).pluck(:name)
      n = 1
      loop do
        candidate = "#{base}.v#{n}"
        return candidate unless existing.include?(candidate)

        n += 1
      end
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
          dependent_run_ids: []
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
          dependent_run_ids: []
        )
      end

      ids = annots.map(&:id)
      dep_run_ids = ids.flat_map { |aid| RunAnnotReferenceScanner.run_ids_referencing_annot(project.id, aid) }.uniq
      Check.new(
        path: path,
        authorized: true,
        auth_reason: nil,
        auth_message: nil,
        collision: true,
        annot_ids: ids,
        dependent_run_ids: dep_run_ids
      )
    end
  end
end
