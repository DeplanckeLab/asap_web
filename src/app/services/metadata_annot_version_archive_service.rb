# frozen_string_literal: true

# Archives an existing discrete metadata Annot to a .bkp.N name (same annot_id),
# renames the loom dataset, and rewrites path-based run/project references.
# Used so replacements can write a new Annot at the canonical path without
# destroying dependents that still point at the archived annot_id.
class MetadataAnnotVersionArchiveService
  class << self
    def call(project:, loom_file:, metadata_path:)
      new(project: project, loom_file: loom_file, metadata_path: metadata_path).call
    end
  end

  def initialize(project:, loom_file:, metadata_path:)
    @project = project
    @loom_file = loom_file.to_s
    @metadata_path = metadata_path.to_s
  end

  def call
    return { ok: false, error: "Metadata path is required." } if @metadata_path.blank?
    return { ok: false, error: "Loom file is required." } if @loom_file.blank?

    source_annots = @project.annots.where(name: @metadata_path).order(latest_version: :desc, id: :desc).to_a
    source_annot = source_annots.first
    return { ok: true, archived: false, unchanged: true } unless source_annot

    archive_path = MetadataCollisionBackupNaming.next_path(@project, @metadata_path)
    archive_label = archive_path.split("/").last

    project_dir = Pathname.new(ENV.fetch("USER_DATA_DIR")) + @project.user_id.to_s + @project.key
    loom_path = project_dir + @loom_file
    return { ok: false, error: "Loom file not found: #{@loom_file}" } unless File.exist?(loom_path)

    if H5DataService.metadata_dataset_exists?(loom_path.to_s, archive_path)
      return { ok: false, error: "Archive path already exists in loom: #{archive_path}" }
    end
    if @project.annots.exists?(name: archive_path)
      return { ok: false, error: "Archive Annot already exists: #{archive_path}" }
    end

    loom_copied = false
    if H5DataService.metadata_dataset_exists?(loom_path.to_s, @metadata_path)
      H5DataService.copy_metadata_dataset!(loom_path.to_s, @metadata_path, archive_path)
      loom_copied = true
    end

    ActiveRecord::Base.transaction do
      extras = source_annots.reject { |annot| annot.id == source_annot.id }
      if extras.any?
        extra_ids = extras.map(&:id)
        Cla.where(annot_id: extra_ids).update_all(annot_id: source_annot.id)
        AnnotCellSet.where(annot_id: extra_ids).update_all(annot_id: source_annot.id)
        extras.each do |annot|
          annot.reload
          annot.destroy!
        end
      end

      source_annot.update!(
        name: archive_path,
        label: archive_label,
        latest_version: false,
        filepath: source_annot.filepath.presence || @loom_file
      )
      update_path_references!(@metadata_path, archive_path)
    end

    if loom_copied
      H5DataService.delete_metadata_dataset!(loom_path.to_s, @metadata_path)
    end

    {
      ok: true,
      archived: true,
      archive_path: archive_path,
      archive_annot_id: source_annot.id
    }
  rescue StandardError => e
    Rails.logger.error("[MetadataAnnotVersionArchiveService] #{e.class}: #{e.message}")
    { ok: false, error: e.message }
  end

  private

  def update_path_references!(old_path, new_path)
    update_run_json_column(:attrs_json, old_path, new_path)
    update_run_json_column(:output_json, old_path, new_path)
    if defined?(ComplianceMapping)
      ComplianceMapping.where(project_id: @project.id, source_path: old_path)
                       .update_all(source_path: new_path)
    end
  end

  def update_run_json_column(column, old_path, new_path)
    Run.where(project_id: @project.id).where("#{column} LIKE ?", "%#{old_path}%").find_each do |run|
      raw = run.public_send(column).to_s
      next unless raw.include?(old_path)

      begin
        parsed = JSON.parse(raw)
        next unless replace_path_in_json(parsed, old_path, new_path)

        run.update!(column => parsed.to_json)
      rescue JSON::ParserError
        updated = raw.gsub(/(?<![.\w])#{Regexp.escape(old_path)}(?!\.v\d+)/, new_path)
        run.update!(column => updated) if updated != raw
      end
    rescue StandardError => e
      Rails.logger.error("[MetadataAnnotVersionArchiveService] #{column} Run ##{run.id}: #{e.message}")
    end
  end

  def replace_path_in_json(obj, old_path, new_path)
    case obj
    when Hash
      changed = false
      obj.each do |key, value|
        if value.is_a?(String) && value == old_path
          obj[key] = new_path
          changed = true
        elsif replace_path_in_json(value, old_path, new_path)
          changed = true
        end
      end
      changed
    when Array
      changed = false
      obj.each_with_index do |value, idx|
        if value.is_a?(String) && value == old_path
          obj[idx] = new_path
          changed = true
        elsif replace_path_in_json(value, old_path, new_path)
          changed = true
        end
      end
      changed
    else
      false
    end
  end
end
