# frozen_string_literal: true

# Copies a Fu-staged DNA accessibility asset into the project parsing directory.
# Fragments: dna_accessibility.tsv.bgz
# Tabix index: dna_accessibility.tsv.bgz.tbi
class DnaAccessibilityFinalizeService
  ASSETS = {
    'dna_accessibility' => {
      target_name: 'dna_accessibility.tsv.bgz',
      allowed_extensions: %w[.tsv.bgz],
      label: 'DNA accessibility fragments (.tsv.bgz)'
    },
    'dna_accessibility_tbi' => {
      target_name: 'dna_accessibility.tsv.bgz.tbi',
      allowed_extensions: %w[.tsv.bgz.tbi],
      label: 'DNA accessibility tabix index (.tsv.bgz.tbi)'
    }
  }.freeze

  UPLOAD_TYPE_NAMES = ASSETS.keys.freeze

  class Error < StandardError; end

  def self.asset_config_for(upload_type_name)
    ASSETS[upload_type_name.to_s]
  end

  def self.dna_accessibility_upload_type?(upload_type_name)
    ASSETS.key?(upload_type_name.to_s)
  end

  def self.target_names
    ASSETS.values.map { |cfg| cfg[:target_name] }
  end

  # True when every required DNA accessibility asset exists and is non-empty.
  def self.assets_present?(parsing_dir)
    root = parsing_dir.present? ? Pathname.new(parsing_dir.to_s) : nil
    return false unless root&.directory?

    target_names.all? do |name|
      path = root.join(name)
      path.exist? && path.file? && path.size.positive?
    end
  end

  def self.validate_filename!(filename, upload_type_name:)
    config = asset_config_for(upload_type_name)
    raise Error, "Unknown DNA accessibility upload type: #{upload_type_name}" unless config

    ext = extension_for(filename)
    return if config[:allowed_extensions].include?(ext)

    raise Error, "#{config[:label]} must be a #{config[:allowed_extensions].join(' or ')} file"
  end

  def self.extension_for(filename)
    normalized = filename.to_s.downcase
    return '.tsv.bgz.tbi' if normalized.end_with?('.tsv.bgz.tbi')
    return '.tsv.bgz' if normalized.end_with?('.tsv.bgz')

    File.extname(normalized)
  end

  def self.default_filename_for(upload_type_name)
    asset_config_for(upload_type_name)&.dig(:target_name)
  end

  def initialize(fu:, project:, upload_type_name: nil)
    @fu = fu
    @project = project
    @upload_type_name = upload_type_name.presence || UploadType.name_for(fu&.upload_type)
  end

  def call
    raise Error, 'Upload record is missing' unless @fu
    raise Error, 'Project is required' unless @project

    config = self.class.asset_config_for(@upload_type_name)
    raise Error, "Unknown DNA accessibility upload type: #{@upload_type_name}" unless config

    source = @fu.file_path
    raise Error, 'Uploaded file not found' unless source && File.exist?(source) && File.size(source).positive?

    self.class.validate_filename!(
      @fu.name.presence || @fu.upload_file_name,
      upload_type_name: @upload_type_name
    )

    parsing_dir = @project.data_dir.join('parsing')
    FileUtils.mkdir_p(parsing_dir)
    dest = parsing_dir.join(config[:target_name])
    FileUtils.cp(source, dest)

    @fu.update!(
      status: 'completed',
      project_id: @project.id,
      project_key: @project.key,
      upload_file_size: File.size(source)
    )

    {
      path: dest.to_s,
      size: File.size(dest),
      filename: config[:target_name],
      upload_type_name: @upload_type_name
    }
  end
end
