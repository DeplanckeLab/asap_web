# frozen_string_literal: true

# Before writing a new /col_attrs/_asap_consensus_* column, preserve any existing
# column as /col_attrs/_asap_consensus_*.bkp.<idx> (highest existing idx + 1).
# The existing Annot is renamed in place (not duplicated) so id/created_at stay on
# the backup for history. The canonical path is then freed so persist can create
# the new live Annot.
class ConsensusAnnotationMetadataBackupService
  BKP_SUFFIX = /\.bkp\.(\d+)\z/

  class << self
    def call(project:, loom_file:, metadata_path:, new_labels: nil)
      new(project: project, loom_file: loom_file, metadata_path: metadata_path, new_labels: new_labels).call
    end
  end

  def initialize(project:, loom_file:, metadata_path:, new_labels: nil)
    @project = project
    @loom_file = loom_file.to_s
    @metadata_path = metadata_path.to_s
    @new_labels = new_labels
  end

  def call
    loom_copied = false
    db_committed = false
    backup_path = nil
    loom_path = nil

    return error("Metadata path is required.") if @metadata_path.blank?
    return error("Loom file is required.") if @loom_file.blank?

    project_dir = Pathname.new(ENV.fetch("USER_DATA_DIR")) + @project.user_id.to_s + @project.key
    loom_path = project_dir + @loom_file
    return error("Loom file not found on disk: #{@loom_file}") unless File.exist?(loom_path)

    source_annots = @project.annots.where(name: @metadata_path).order(latest_version: :desc, id: :desc).to_a
    source_annot = source_annots.first
    loom_exists = H5DataService.metadata_dataset_exists?(loom_path.to_s, @metadata_path)

    unless source_annot || loom_exists
      return { ok: true, backed_up: false, unchanged: false }
    end

    if loom_exists && labels_unchanged?(loom_path.to_s)
      return { ok: true, backed_up: false, unchanged: true }
    end

    next_idx = next_backup_index
    backup_path = "#{@metadata_path}.bkp.#{next_idx}"
    backup_label = backup_path.split("/").last

    if H5DataService.metadata_dataset_exists?(loom_path.to_s, backup_path)
      return error("Backup path already exists in loom: #{backup_path}")
    end
    if @project.annots.exists?(name: backup_path)
      return error("Backup Annot already exists: #{backup_path}")
    end

    backup_annot = nil
    if loom_exists
      H5DataService.copy_metadata_dataset!(loom_path.to_s, @metadata_path, backup_path)
      loom_copied = true
    end

    ActiveRecord::Base.transaction do
      backup_annot = rename_or_create_backup_annot!(source_annot, source_annots, backup_path, backup_label, loom_path)
      update_path_references!(@metadata_path, backup_path)
    end
    db_committed = true

    if loom_exists
      H5DataService.delete_metadata_dataset!(loom_path.to_s, @metadata_path)
    end

    {
      ok: true,
      backed_up: true,
      unchanged: false,
      backup_path: backup_path,
      backup_idx: next_idx,
      backup_annot_id: backup_annot.id
    }
  rescue StandardError => e
    if loom_copied && !db_committed && loom_path && backup_path
      begin
        H5DataService.delete_metadata_dataset!(loom_path.to_s, backup_path)
      rescue StandardError => cleanup_error
        Rails.logger.error(
          "[ConsensusAnnotationMetadataBackupService] cleanup failed for #{backup_path}: #{cleanup_error.message}"
        )
      end
    end
    Rails.logger.error("[ConsensusAnnotationMetadataBackupService] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(20).join("\n"))
    error(e.message)
  end

  private

  def error(message)
    { ok: false, error: message }
  end

  def labels_unchanged?(loom_path)
    return false unless @new_labels.is_a?(Array)

    existing = H5DataService.get_metadata_vector(loom_path, @metadata_path)
    return false unless existing.is_a?(Array)
    return false unless existing.length == @new_labels.length

    existing.each_with_index.all? do |value, idx|
      value.to_s == @new_labels[idx].to_s
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[ConsensusAnnotationMetadataBackupService] Could not compare existing labels for #{@metadata_path}: #{e.message}"
    )
    false
  end

  def next_backup_index
    prefix = "#{@metadata_path}.bkp."
    names = @project.annots.where("name LIKE ?", "#{sanitize_like(prefix)}%").pluck(:name)
    idxs = names.filter_map do |name|
      match = name.to_s.match(BKP_SUFFIX)
      next unless match
      next unless name.to_s.start_with?(prefix)

      match[1].to_i
    end
    (idxs.max || 0) + 1
  end

  def sanitize_like(value)
    ActiveRecord::Base.sanitize_sql_like(value)
  end

  # Rename the existing Annot to the backup path so id/created_at are preserved.
  # Extra Annot rows that shared the canonical name are retargeted then destroyed.
  def rename_or_create_backup_annot!(source_annot, source_annots, backup_path, backup_label, loom_path)
    if source_annot
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
        name: backup_path,
        label: backup_label,
        latest_version: false,
        filepath: source_annot.filepath.presence || @loom_file
      )
      return source_annot
    end

    dim = if backup_path.start_with?("/col_attrs/")
            1
          elsif backup_path.start_with?("/row_attrs/")
            2
          else
            4
          end
    data_type_id = DataType.find_by(name: "DISCRETE")&.id || 3
    relative_path = loom_path.to_s.sub(%r{\A.*/#{@project.user_id}/#{@project.key}/}, "")

    @project.annots.create!(
      name: backup_path,
      label: backup_label,
      filepath: relative_path.presence || @loom_file,
      dim: dim,
      data_type_id: data_type_id,
      nber_cols: @project.nber_cols,
      latest_version: false,
      version_nber: 1,
      user_id: @project.user_id
    )
  end

  def update_path_references!(old_path, new_path)
    update_run_attrs_json(old_path, new_path)
    update_run_output_json(old_path, new_path)
    update_project_json_files(old_path, new_path)
    if defined?(ComplianceMapping)
      ComplianceMapping.where(project_id: @project.id, source_path: old_path)
                       .update_all(source_path: new_path)
    end
  end

  def update_run_attrs_json(old_path, new_path)
    Run.where(project_id: @project.id).where("attrs_json LIKE ?", "%#{old_path}%").find_each do |run|
      attrs = JSON.parse(run.attrs_json)
      next unless replace_path_in_json(attrs, old_path, new_path)

      run.update!(attrs_json: attrs.to_json)
    rescue StandardError => e
      Rails.logger.error("[ConsensusAnnotationMetadataBackupService] attrs_json Run ##{run.id}: #{e.message}")
    end
  end

  def update_run_output_json(old_path, new_path)
    Run.where(project_id: @project.id).where("output_json LIKE ?", "%#{old_path}%").find_each do |run|
      raw = run.output_json.to_s
      next unless raw.include?(old_path)

      begin
        parsed = JSON.parse(raw)
        next unless replace_path_in_json(parsed, old_path, new_path)

        run.update!(output_json: parsed.to_json)
      rescue JSON::ParserError
        # output_json is not always strict JSON; only replace exact path tokens.
        updated = raw.gsub(/(?<![.\w])#{Regexp.escape(old_path)}(?!\.bkp\.\d+)/, new_path)
        run.update!(output_json: updated) if updated != raw
      end
    rescue StandardError => e
      Rails.logger.error("[ConsensusAnnotationMetadataBackupService] output_json Run ##{run.id}: #{e.message}")
    end
  end

  def update_project_json_files(old_path, new_path)
    project_dir = File.join(
      ENV.fetch("USER_DATA_DIR", "/data/asap2/projects"),
      @project.user_id.to_s,
      @project.key
    )
    return unless File.directory?(project_dir)

    Dir.glob(File.join(project_dir, "**", "output.json")).each do |json_path|
      update_metadata_name_in_json(json_path, old_path, new_path)
    end
    Dir.glob(File.join(project_dir, "**", "list_metadata_to_copy*.json")).each do |json_path|
      update_meta_list_in_json(json_path, old_path, new_path)
    end
  rescue StandardError => e
    Rails.logger.error("[ConsensusAnnotationMetadataBackupService] project JSON files: #{e.message}")
  end

  def update_metadata_name_in_json(json_path, old_path, new_path)
    raw = File.read(json_path)
    return unless raw.include?(old_path)

    data = JSON.parse(raw)
    changed = false
    if data.is_a?(Hash) && data["metadata"].is_a?(Array)
      data["metadata"].each do |entry|
        next unless entry.is_a?(Hash) && entry["name"] == old_path

        entry["name"] = new_path
        changed = true
      end
    end
    File.write(json_path, JSON.pretty_generate(data)) if changed
  rescue StandardError => e
    Rails.logger.error("[ConsensusAnnotationMetadataBackupService] #{json_path}: #{e.message}")
  end

  def update_meta_list_in_json(json_path, old_path, new_path)
    raw = File.read(json_path)
    return unless raw.include?(old_path)

    data = JSON.parse(raw)
    changed = false
    if data.is_a?(Hash) && data["meta"].is_a?(Array)
      data["meta"].each_with_index do |entry, idx|
        next unless entry == old_path

        data["meta"][idx] = new_path
        changed = true
      end
    end
    File.write(json_path, JSON.pretty_generate(data)) if changed
  rescue StandardError => e
    Rails.logger.error("[ConsensusAnnotationMetadataBackupService] #{json_path}: #{e.message}")
  end

  def replace_path_in_json(obj, old_path, new_path)
    changed = false
    case obj
    when Hash
      obj.each do |key, value|
        if value.is_a?(String) && value == old_path
          obj[key] = new_path
          changed = true
        elsif replace_path_in_json(value, old_path, new_path)
          changed = true
        end
      end
    when Array
      obj.each_with_index do |value, idx|
        if value.is_a?(String) && value == old_path
          obj[idx] = new_path
          changed = true
        elsif replace_path_in_json(value, old_path, new_path)
          changed = true
        end
      end
    end
    changed
  end
end
