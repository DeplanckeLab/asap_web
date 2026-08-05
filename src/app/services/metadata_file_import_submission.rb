# frozen_string_literal: true

# Server-side gate for do_import_metadata: reserved names, collisions, keep-both / overwrite.
#
# Collision policies:
# - keep_both: rename/archive existing Annot to base.bkp.N; import writes at the canonical name
# - overwrite: delete existing Annot + dependents; import writes at the canonical name
class MetadataFileImportSubmission
  class << self
    def prepare_staged_file!(project:, fu:, metadata_type_id:, input_type_id:, name:, header_name:, has_header:,
                             collision_resolution:, loom_file: nil)
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
          error: "This import overlaps existing metadata columns. Choose keep both (rename existing to .bkp.N) or overwrite existing metadata.",
          status: :unprocessable_entity
        }
      end

      unless %w[keep_both overwrite].include?(res)
        return { ok: false, error: "Invalid collision resolution.", status: :unprocessable_entity }
      end

      colliding.each do |c|
        unless loom_file.present?
          return {
            ok: false,
            error: "#{res == 'keep_both' ? 'Keep both' : 'Overwrite'} requires a loom file so existing metadata can be renamed or removed.",
            status: :unprocessable_entity,
            blocking_path: c.path
          }
        end

        if res == "keep_both"
          archived = MetadataAnnotVersionArchiveService.call(
            project: project,
            loom_file: loom_file,
            metadata_path: c.path
          )
          unless archived[:ok]
            return {
              ok: false,
              error: archived[:error] || "Failed to rename existing metadata at #{c.path} to .bkp.N",
              status: :unprocessable_entity,
              blocking_path: c.path
            }
          end
        elsif res == "overwrite"
          annots = Annot.where(project_id: project.id, name: c.path).to_a
          next if annots.empty?

          gate = MetadataRewritePolicyGate.call(
            project: project,
            annots: annots,
            loom_file: loom_file,
            previous_metadata_policy: "delete"
          )
          unless gate[:ok]
            return {
              ok: false,
              error: gate[:error] || "Failed to overwrite existing metadata at #{c.path}",
              status: :unprocessable_entity,
              blocking_path: c.path
            }
          end
        end
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
