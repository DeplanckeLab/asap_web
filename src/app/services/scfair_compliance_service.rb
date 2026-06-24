class ScfairComplianceService
  def initialize(file_path:, schema_id:, logger: Rails.logger, &progress_cb)
    @file_path = file_path
    @schema_id = schema_id
    @logger = logger
    @progress_cb = progress_cb
  end

  def validate
    Scfair::ComplianceValidationCore.call(
      file_path: @file_path,
      schema_id: @schema_id,
      logger: @logger,
      progress_cb: @progress_cb
    )
  end
end
