# frozen_string_literal: true

# Server-side gate for do_import_metadata: reserved names, collisions, overwrite safety, keep-both rewrites.
class MetadataFileImportSubmission
  class << self
    def prepare_staged_file!(project:, fu:, metadata_type_id:, input_type_id:, name:, header_name:, has_header:,
                             collision_resolution:)
      stage_path = fu.upload_dir + "clipboard.txt"
      unless File.exist?(stage_path)
        return { ok: false, error: "Staged import file is missing. Run preview again.", status: :unprocessable_entity }
      end

      raw_content = File.read(stage_path)
      header_name = header_name.presence || extract_list_header_from_file(metadata_type_id, input_type_id, raw_content)

      validation = MetadataFileImportValidation.analyze(
        project: project,
        metadata_type_id: metadata_type_id,
        input_type_id: input_type_id,
        name: name,
        header_name: header_name,
        has_header: has_header,
        raw_content: raw_content
      )

      if validation[:skip_name_checks]
        return { ok: true }
      end

      if validation[:error].present?
        return { ok: false, error: validation[:error], status: :unprocessable_entity }
      end

      checks = validation[:checks]
      if checks.any? { |c| !c.authorized }
        msg = checks.reject(&:authorized).map(&:auth_message).compact.join(" ")
        return { ok: false, error: msg.presence || "Metadata name is not allowed for import.", status: :unprocessable_entity }
      end

      colliding = checks.select(&:collision)
      if colliding.empty?
        return { ok: true }
      end

      res = collision_resolution.to_s.strip.downcase
      if res.blank?
        return {
          ok: false,
          error: "This import overlaps existing metadata columns. Choose keep both (adds a .vN suffix), overwrite (only if no runs use the column), or cancel.",
          status: :unprocessable_entity
        }
      end

      unless %w[keep_both overwrite skip].include?(res)
        return { ok: false, error: "Invalid collision resolution.", status: :unprocessable_entity }
      end

      if res == "skip"
        return { ok: false, error: "Import cancelled.", status: :unprocessable_entity }
      end

      path_map = {}
      colliding.each do |c|
        if res == "keep_both"
          path_map[c.path] = MetadataFileImportValidation.next_versioned_path(project, c.path)
        elsif res == "overwrite"
          if c.dependent_run_ids.any?
            return {
              ok: false,
              error: "Cannot overwrite metadata at #{c.path} because pipeline runs still reference it (run ids: #{c.dependent_run_ids.join(', ')}). Finish or remove those runs, then retry.",
              status: :unprocessable_entity,
              blocking_path: c.path,
              dependent_run_ids: c.dependent_run_ids
            }
          end
          Annot.where(project_id: project.id, name: c.path).find_each(&:destroy)
        end
      end

      if res == "keep_both" && path_map.any?
        MetadataImportUploadRewriter.apply_path_map!(
          filepath: stage_path.to_s,
          metadata_type_id: metadata_type_id,
          input_type_id: input_type_id,
          path_map: path_map
        )
      end

      { ok: true }
    end

    private

    def extract_list_header_from_file(metadata_type_id, input_type_id, raw_content)
      return nil if metadata_type_id.to_s == "4"
      return nil unless input_type_id.to_s == "1"

      line = raw_content.to_s.split("\n").first.to_s
      m = line.match(/\A(cells|genes)\t(.+)\z/)
      m ? m[2].strip : nil
    end
  end
end
