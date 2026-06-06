# frozen_string_literal: true

class ComplianceFileCheckQueueService
  MAX_UPLOAD_SIZE = 50.gigabytes
  ALLOWED_EXTENSIONS = %w[.loom .h5ad].freeze

  class << self
    def allowed_extension?(filename)
      ext = File.extname(filename.to_s).downcase
      ALLOWED_EXTENSIONS.include?(ext)
    end

    def validate_upload!(filename:, file_size:)
      raise ArgumentError, 'File must be .loom or .h5ad' unless allowed_extension?(filename)
      raise ArgumentError, "Invalid file size (max #{MAX_UPLOAD_SIZE / 1.gigabyte}GB)" if file_size <= 0 || file_size > MAX_UPLOAD_SIZE
    end

    def call(fu:, schema_id: 'scfair_7_1_0')
      new(fu: fu, schema_id: schema_id).call
    end
  end

  def initialize(fu:, schema_id:)
    @fu = fu
    @schema_id = schema_id.to_s.presence || 'scfair_7_1_0'
  end

  def call
    path = @fu.file_path&.to_s
    raise ArgumentError, 'Upload file not found' if path.blank? || !File.exist?(path)

    self.class.validate_upload!(filename: @fu.name.presence || path, file_size: File.size(path))

    task_id = SecureRandom.uuid
    original_filename = @fu.name.presence || File.basename(path)
    initial = {
      status: 'queued',
      task_id: task_id,
      progress: 45,
      message: 'Validation queued'
    }
    IsolatedComplianceStatusStore.write(task_id, initial)
    @fu.update!(status: 'validating')
    IsolatedComplianceValidationJob.perform_later(
      task_id,
      path,
      @schema_id,
      original_filename,
      fu_id: @fu.id
    )

    {
      task_id: task_id,
      status: 'queued',
      filename: original_filename,
      schema_id: @schema_id
    }
  end
end
