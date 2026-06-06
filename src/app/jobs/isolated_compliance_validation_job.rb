# frozen_string_literal: true

class IsolatedComplianceValidationJob < ApplicationJob
  queue_as :default

  def perform(task_id, file_path, schema_id, original_filename, fu_id: nil)
    started_payload = {
      status: 'started',
      task_id: task_id,
      message: 'Validation started',
      progress: 1,
      filename: original_filename
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
    completed_payload = {
      status: 'completed',
      task_id: task_id,
      progress: 100,
      message: result[:valid] ? 'Validation completed successfully' : 'Validation completed with issues',
      result: result
    }
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
    Rails.logger.error("[IsolatedComplianceValidationJob] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
  ensure
    cleanup_file(file_path)
  end

  private

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

