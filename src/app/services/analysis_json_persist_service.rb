# frozen_string_literal: true

# Writes /attrs/analysis_pipeline into a project loom file from DB-backed run history,
# and creates or updates the matching Annot row (dim=4 global attribute).
class AnalysisJsonPersistService
  class << self
    def call(project:, loom_filepath:)
      new(project: project, loom_filepath: loom_filepath).call
    end
  end

  def initialize(project:, loom_filepath:)
    @project = project
    @loom_filepath = loom_filepath.to_s.sub(%r{\A/+}, '').sub(/\.h5ad\z/i, '.loom')
  end

  def call
    raise ArgumentError, 'Project is required' if @project.nil?
    raise ArgumentError, 'Loom filepath is required' if @loom_filepath.blank?
    raise ArgumentError, 'Loom filepath must end with .loom' unless @loom_filepath.end_with?('.loom')

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    loom_path = project_dir + @loom_filepath
    raise "Loom file not found: #{@loom_filepath}" unless File.exist?(loom_path)

    payload = AnalysisJsonBuilder.call(project: @project, loom_filepath: @loom_filepath)
    json_string = JSON.generate(payload)

    H5DataService.with_loom_write_lock(loom_path) do
      H5DataService.write_global_attr_string!(
        loom_path.to_s,
        AnalysisJsonBuilder::LOOM_ATTR_PATH,
        json_string,
        already_locked: true
      )
      remove_legacy_attr!(loom_path.to_s)
    end

    annot = upsert_annot!(json_string)

    {
      ok: true,
      loom_filepath: @loom_filepath,
      attr_path: AnalysisJsonBuilder::LOOM_ATTR_PATH,
      annot_id: annot.id,
      nber_steps: Array(payload['steps']).size,
      bytes: json_string.bytesize
    }
  end

  private

  def remove_legacy_attr!(loom_path)
    if H5DataService.metadata_dataset_exists?(loom_path, AnalysisJsonBuilder::LEGACY_LOOM_ATTR_PATH)
      H5DataService.delete_metadata_dataset!(
        loom_path,
        AnalysisJsonBuilder::LEGACY_LOOM_ATTR_PATH,
        already_locked: true
      )
    end
    delete_legacy_file_attr!(loom_path)

    @project.annots
            .where(name: AnalysisJsonBuilder::LEGACY_LOOM_ATTR_PATH, filepath: @loom_filepath)
            .find_each(&:destroy!)
  end

  def delete_legacy_file_attr!(loom_path)
    script = <<~PYTHON
      import h5py
      import sys

      with h5py.File(sys.argv[1], 'r+') as f:
          if sys.argv[2] in f.attrs:
              del f.attrs[sys.argv[2]]
      print('OK')
    PYTHON
    stdout, stderr, status = H5DataService.docker_exec_h5_write_python3!(
      loom_path.to_s, AnalysisJsonBuilder::LEGACY_ATTR_NAME,
      stdin_data: script
    )
    unless status.success? && stdout.strip.start_with?('OK')
      raise "Failed to delete legacy file attr #{AnalysisJsonBuilder::LEGACY_ATTR_NAME}: #{stderr.presence || stdout}"
    end
  end

  def upsert_annot!(json_string)
    data_type_id = DataType.find_by(name: 'STRING')&.id
    raise 'STRING DataType not found' if data_type_id.nil?

    attrs = {
      name: AnalysisJsonBuilder::LOOM_ATTR_PATH,
      label: AnalysisJsonBuilder::ATTR_NAME,
      filepath: @loom_filepath,
      dim: 4,
      data_type_id: data_type_id,
      nber_rows: 1,
      nber_cols: 1,
      mem_size: json_string.bytesize,
      imported: false,
      latest_version: true
    }

    existing = @project.annots
                       .where(name: AnalysisJsonBuilder::LOOM_ATTR_PATH, filepath: @loom_filepath)
                       .order(latest_version: :desc, id: :desc)
                       .to_a
    annot = existing.first
    if annot
      extras = existing.drop(1)
      extras.each(&:destroy!)
      annot.update!(attrs)
      annot
    else
      @project.annots.create!(
        attrs.merge(
          version_nber: 1,
          user_id: @project.user_id
        )
      )
    end
  end
end
