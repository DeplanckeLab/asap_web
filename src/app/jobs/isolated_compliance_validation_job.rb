# frozen_string_literal: true

class IsolatedComplianceValidationJob < ApplicationJob
  queue_as :default

  def perform(task_id, file_path, schema_id, original_filename, fu_id: nil)
    meta = metadata_from_fu(fu_id, original_filename)
    recorded = false

    started_payload = {
      status: 'started',
      task_id: task_id,
      message: 'Validation started',
      progress: 1,
      filename: meta[:filename]
    }
    write_status(task_id, started_payload)
    broadcast(task_id, started_payload)

    service = ScfairComplianceService.new(file_path: file_path, schema_id: schema_id, logger: Rails.logger) do |evt|
      payload = {
        status: 'progress',
        task_id: task_id,
        progress: evt[:progress],
        stage: evt[:stage],
        format: evt[:format],
        message: evt[:message],
        current: evt[:current],
        total: evt[:total]
      }.compact
      write_status(task_id, payload)
      broadcast(task_id, payload)
    end

    result = service.validate
    StandaloneComplianceCheckRecorder.record_completed!(
      task_id: task_id,
      result: result,
      filename: meta[:filename],
      schema_id: schema_id,
      user_id: meta[:user_id],
      source_url: meta[:source_url],
      fu_id: fu_id,
      admin_run: meta[:admin_run],
      creator_ip: meta[:creator_ip]
    )
    recorded = true

    completed_payload = {
      status: 'completed',
      task_id: task_id,
      progress: 100,
      message: result[:valid] ? 'Validation completed successfully' : 'Validation completed with issues',
      result: result,
      fu_id: fu_id
    }.compact
    write_status(task_id, completed_payload)
    broadcast(task_id, completed_payload)
    mark_fu_validated(fu_id)
  rescue StandardError => e
    failed_payload = {
      status: 'failed',
      task_id: task_id,
      message: "Validation failed: #{e.message}",
      error: e.message
    }
    write_status(task_id, failed_payload)
    broadcast(task_id, failed_payload)
    mark_fu_failed(fu_id, e.message)
    record_failure_safely(task_id, e, schema_id, original_filename, fu_id) unless recorded
    Rails.logger.error("[IsolatedComplianceValidationJob] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
  ensure
    # When a Fu record tracks the file, keep it so the user can create a project
    # from the validated file without re-uploading. Orphaned temp files (no fu_id)
    # are cleaned up immediately.
    cleanup_file(file_path) if fu_id.blank?
  end

  private

  def metadata_from_fu(fu_id, original_filename)
    filename = original_filename.to_s.presence
    return { filename: filename, user_id: nil, source_url: nil, admin_run: false, creator_ip: nil } if fu_id.blank?

    fu = Fu.find(fu_id)
    {
      filename: fu.name.presence || fu.upload_file_name.presence || filename,
      user_id: fu.user_id,
      source_url: fu.url.presence,
      admin_run: ActiveModel::Type::Boolean.new.cast(fu.admin_run),
      creator_ip: fu.creator_ip.to_s.strip.presence
    }
  end

  # Persistence of the failure row must not raise out of the rescue handler.
  def record_failure_safely(task_id, error, schema_id, original_filename, fu_id)
    fu = fu_id.present? ? Fu.find_by(id: fu_id) : nil
    StandaloneComplianceCheckRecorder.record_failed!(
      task_id: task_id,
      error_message: error.message,
      filename: fu&.name.presence || fu&.upload_file_name.presence || original_filename,
      schema_id: schema_id,
      user_id: fu&.user_id,
      source_url: fu&.url.presence,
      fu_id: fu_id,
      admin_run: fu ? ActiveModel::Type::Boolean.new.cast(fu.admin_run) : false,
      creator_ip: fu&.creator_ip
    )
  rescue StandardError => record_error
    Rails.logger.error(
      "[IsolatedComplianceValidationJob] Could not record failed check: " \
      "#{record_error.class}: #{record_error.message}"
    )
  end

  def mark_fu_validated(fu_id)
    return if fu_id.blank?

    fu = Fu.find_by(id: fu_id)
    return unless fu

    fu.update!(status: 'validated')
  rescue StandardError => e
    Rails.logger.warn("[IsolatedComplianceValidationJob] Could not update Fu##{fu_id}: #{e.message}")
  end

  def mark_fu_failed(fu_id, _message)
    return if fu_id.blank?

    fu = Fu.find_by(id: fu_id)
    return unless fu

    fu.update!(status: 'validation_failed')
  rescue StandardError => e
    Rails.logger.warn("[IsolatedComplianceValidationJob] Could not update Fu##{fu_id}: #{e.message}")
  end

  def broadcast(task_id, payload)
    ActionCable.server.broadcast("isolated_compliance_#{task_id}", payload)
  end

  def write_status(task_id, payload)
    IsolatedComplianceStatusStore.write(task_id, payload)
  end

  def cleanup_file(path)
    return if path.blank?
    FileUtils.rm_f(path) if File.exist?(path)
  rescue StandardError => e
    Rails.logger.warn("[IsolatedComplianceValidationJob] Could not cleanup temp file #{path}: #{e.message}")
  end
end
