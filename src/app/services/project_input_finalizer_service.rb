class ProjectInputFinalizerService
  # Shared with summary / get_file links: canonical basename under fus/<fu_id>/.
  def self.extract_upload_extension(filename)
    normalized = filename.to_s.downcase
    multi_part_extension = %w[
      .tar.gz
      .tar.bz2
      .tar.xz
      .tar.zst
      .tgz
      .tbz2
      .txz
    ].find { |ext| normalized.end_with?(ext) }

    multi_part_extension || File.extname(filename.to_s)
  end

  def self.canonical_input_filename_parts(upload_file_name)
    ext = extract_upload_extension(upload_file_name.to_s)
    canonical_name = ext.present? ? "input_file#{ext}" : "input_file"
    [canonical_name, ext.delete_prefix(".").presence]
  end

  # v8 preparsing materializes MTX triplets under fus/<fu_id>/input_file/ (matrix.mtx + barcodes/features TSV).
  # The project root should symlink to that directory so parsing receives a single directory layout.
  def self.mtx_preparsed_bundle_dir?(upload_dir)
    d = Pathname.new(upload_dir.to_s) + "input_file"
    return false unless d.directory?

    return true if d.join("matrix.mtx").file?

    mtx = Dir.children(d.to_s).select { |e| e.end_with?(".mtx") && !e.start_with?(".") }
    mtx.size == 1
  end

  def self.mtx_detected_in_preparsing?(upload_dir)
    outp = Pathname.new(upload_dir.to_s) + "output.json"
    return false unless outp.file?

    h = Basic.safe_parse_json(File.read(outp), {})
    h["detected_format"].to_s.casecmp("mtx").zero?
  rescue StandardError
    false
  end

  def self.use_mtx_preparsed_bundle_layout?(upload_dir)
    mtx_detected_in_preparsing?(upload_dir) && mtx_preparsed_bundle_dir?(upload_dir)
  end

  # Finalizes uploaded input storage when a project is created:
  # - resolve source from Fu staging
  # - persist detected format in parsing attrs
  # - store canonical project input name
  # - move Fu staging under project/fus and create root symlink
  def self.call(project:, project_dir:, input_file:, formats_by_name:, logger: Rails.logger)
    new(
      project: project,
      project_dir: project_dir,
      input_file: input_file,
      formats_by_name: formats_by_name,
      logger: logger
    ).call
  end

  def initialize(project:, project_dir:, input_file:, formats_by_name:, logger:)
    @project = project
    @project_dir = project_dir
    @input_file = input_file
    @formats_by_name = formats_by_name || {}
    @logger = logger
  end

  def call
    # 1) Locate the uploaded file source and name.
    upload_dir, input_filename = resolve_upload_source
    # 2) Persist detected format early so parsing does not depend on transient files.
    persist_detected_format_from_preparsing(upload_dir)
    # 3) Normalize root filename (input_file.<ext>) and project extension metadata.
    canonical_project_input_filename, ext = self.class.canonical_input_filename_parts(input_filename)
    if self.class.use_mtx_preparsed_bundle_layout?(upload_dir)
      canonical_project_input_filename = "input_file"
      ext = "mtx"
    end

    @project.input_filename = canonical_project_input_filename
    @project.fu_id = @input_file&.id
    @project.extension = ext
    # Persist these fields before touching files so downstream code has stable metadata.
    @project.save!

    # 4) Move/canonicalize actual file storage and create project root symlink.
    finalize_storage!(
      upload_dir: upload_dir,
      input_filename: input_filename,
      canonical_project_input_filename: canonical_project_input_filename
    )
  end

  private

  def resolve_upload_source
    @logger.info("[ProjectsController#create] ===== DETERMINING UPLOAD PATH =====")
    @logger.info("[ProjectsController#create] input_file: #{@input_file.inspect}")
    @logger.info("[ProjectsController#create] input_file && input_file.id: #{@input_file && @input_file.id}")

    # Strict invariant: by project creation finalization time we must have a Fu row.
    # Session-only fallbacks are intentionally not supported anymore.
    raise "Cannot locate uploaded file" unless @input_file && @input_file.id

    # Fu files live under upload_dir (global staging before project, or project/fus/<fu_id> after).
    # Do not use only global_upload_root: the same Fu can be reused (e.g. reset flow) while still under a project tree.
    upload_dir = Pathname.new(@input_file.upload_dir.to_s)
    input_filename = @input_file.upload_file_name
    @logger.info("[ProjectsController#create] Using input_file path - upload_dir: #{upload_dir}, input_filename: #{input_filename}")
    [upload_dir, input_filename]
  end

  def persist_detected_format_from_preparsing(upload_dir)
    # The preparsing output is generated in the staging upload dir and can disappear
    # after cleanup; copy the useful format signal into project attrs now.
    return unless @input_file && @input_file.id

    preparsing_output_file = upload_dir + "output.json"
    return unless File.exist?(preparsing_output_file)

    h_preparsing = Basic.safe_parse_json(File.read(preparsing_output_file), {})
    detected_format = h_preparsing["detected_format"]
    return unless detected_format.present?

    h_parsing_attrs = Basic.safe_parse_json(@project.parsing_attrs_json, {}).deep_symbolize_keys
    h_parsing_attrs[:file_type] = detected_format
    format_obj = @formats_by_name[detected_format] || @formats_by_name[detected_format.to_s.upcase]
    is_raw_text = (detected_format.to_s == "RAW_TEXT") || (format_obj && format_obj.child_format == "RAW_TEXT")
    unless is_raw_text
      [:delimiter, :gene_name_col, :has_header].each { |k| h_parsing_attrs.delete(k) }
    end
    @project.parsing_attrs_json = h_parsing_attrs.to_json
    @logger.info("[ProjectsController#create] Stored detected file_type '#{detected_format}' in parsing_attrs_json")
  rescue => e
    @logger.warn("[ProjectsController#create] Could not persist preparsing detected_format: #{e.class} - #{e.message}")
  end

  def finalize_storage!(upload_dir:, input_filename:, canonical_project_input_filename:)
    canonical_upload_path = upload_dir + input_filename
    # Source file must exist in staging before we mutate Fu linkage or move dirs.
    raise "Uploaded file not found" unless File.exist?(canonical_upload_path)

    project_input_backup_path = @project_dir + canonical_project_input_filename

    if @input_file.present?
      # Canonical path for Fu-backed projects:
      # project_dir/fus/<fu_id>/input_file.<ext>, with project root symlink.
      move_fu_under_project!
      # mtx_preparsed_bundle_dir? expects the Fu directory (parent of input_file/), not the bundle path itself.
      bundle_dir = @input_file.upload_dir + "input_file"
      if @project.input_filename.to_s == "input_file" && self.class.mtx_preparsed_bundle_dir?(@input_file.upload_dir)
        project_input_backup_path = @project_dir + "input_file"
        File.delete(project_input_backup_path) if File.exist?(project_input_backup_path) || File.symlink?(project_input_backup_path)
        bundle_abs = File.expand_path(bundle_dir.to_s)
        File.symlink(bundle_abs, project_input_backup_path.to_s)
        @logger.info("[ProjectsController#create] MTX bundle: symlinked #{project_input_backup_path} -> #{bundle_abs}")
        return
      end

      src_in_fus = @input_file.upload_dir + input_filename
      dest_fus = @input_file.upload_dir + canonical_project_input_filename
      raise "Uploaded file not found after staging move" unless File.exist?(src_in_fus)
      if File.directory?(dest_fus.to_s)
        raise "Canonical input path conflicts with existing directory: #{dest_fus}"
      end

      unless src_in_fus.to_s == dest_fus.to_s
        # Keep original uploaded name intact, and materialize canonical alias by copy.
        FileUtils.cp(src_in_fus, dest_fus)
        @logger.info("[ProjectsController#create] Stored canonical name in fus: #{dest_fus}")
      end

      canonical_fus_abs = File.expand_path(dest_fus.to_s)
      # Project root should point to the canonical file inside project/fus.
      File.delete(project_input_backup_path) if File.exist?(project_input_backup_path) || File.symlink?(project_input_backup_path)
      File.symlink(canonical_fus_abs, project_input_backup_path.to_s)
      @logger.info("[ProjectsController#create] Symlinked #{project_input_backup_path} -> #{canonical_fus_abs}")
      return
    end

    # Defensive guard; with strict Fu-based flow this branch should never execute.
    raise "Cannot finalize input storage without Fu record"
  end

  def move_fu_under_project!
    # Attaching the Fu to the project changes Fu#upload_dir from global to project-local.
    # We then move the directory so subsequent reads use project/fus/<fu_id>.
    # Capture current physical directory before linking Fu to this project; upload_dir
    # may already point at a previous project's fus/ after reset, not global staging.
    old_upload_dir = Pathname.new(@input_file.upload_dir.to_s)
    attrs = { project_id: @project.id, project_key: @project.key, status: "completed" }
    attrs[:user_id] = @project.user_id if @project.user_id.present?
    @input_file.update!(attrs)
    @input_file.reload

    new_upload_dir = @input_file.upload_dir
    # No-op when source is already at destination or source does not exist.
    return unless File.exist?(old_upload_dir.to_s) && old_upload_dir.to_s != new_upload_dir.to_s

    FileUtils.mkdir_p(new_upload_dir.parent)
    FileUtils.rm_rf(new_upload_dir) if File.exist?(new_upload_dir.to_s)
    FileUtils.mv(old_upload_dir.to_s, new_upload_dir.to_s)
    @logger.info("[ProjectsController#create] Moved upload directory from #{old_upload_dir} to #{new_upload_dir}")
  end
end
