# frozen_string_literal: true

require 'net/http'

class IsolatedComplianceUrlDownloadJob < ApplicationJob
  queue_as :default

  PROGRESS_MIN_INTERVAL = 0.5

  def perform(fu_id)
    fu = Fu.find_by(id: fu_id)
    unless fu
      Rails.logger.error("[IsolatedComplianceUrlDownloadJob] Fu##{fu_id} not found")
      return
    end

    task_id = fu.compliance_task_id
    raise ArgumentError, "Fu##{fu.id} has no compliance_task_id" if task_id.blank?
    raise ArgumentError, "Fu##{fu.id} has no url" if fu.url.blank?
    raise ArgumentError, "Fu##{fu.id} has no compliance_schema_id" if fu.compliance_schema_id.blank?

    tmp_path = download_remote_file!(task_id, fu.url)
    detected_format = ComplianceFileCheckQueueService.validate_downloaded_file!(tmp_path)
    final_path = rename_downloaded_file!(tmp_path, task_id, detected_format)
    finalize_downloaded_fu!(fu, final_path, detected_format)

    queued_payload = {
      status: 'queued',
      task_id: task_id,
      progress: 5,
      message: 'Validation queued',
      fu_id: fu.id
    }
    write_and_broadcast(task_id, queued_payload)

    IsolatedComplianceValidationJob.perform_later(
      task_id,
      fu.file_path.to_s,
      fu.compliance_schema_id,
      fu.name,
      fu_id: fu.id
    )
  rescue ComplianceFileCheckQueueService::UnsupportedFormatError => e
    fail_task(fu, e.message, error_code: ComplianceFileCheckQueueService::UNSUPPORTED_FORMAT_ERROR_CODE)
  rescue StandardError => e
    fail_task(fu, e.message)
    Rails.logger.error("[IsolatedComplianceUrlDownloadJob] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
  end

  def finalize_downloaded_fu!(fu, current_path, detected_format)
    parsed_url = URI.parse(fu.url.to_s.strip)
    original_filename = fu.name.presence || File.basename(parsed_url.path).presence || File.basename(current_path)
    extension = detected_format == 'loom' ? '.loom' : '.h5ad'
    input_filename = "input_file#{extension}"

    fu.update!(
      upload_file_name: input_filename,
      upload_file_size: File.size(current_path),
      name: original_filename,
      status: 'validating'
    )

    fu_dir = fu.upload_dir.to_s
    FileUtils.mkdir_p(fu_dir)
    dest = File.join(fu_dir, fu.upload_file_name)
    FileUtils.mv(current_path, dest)
    fu
  end

  private

  def temp_dir
    shared_root = ENV['UPLOAD_DATA_DIR'].presence || ENV['USER_DATA_DIR'].presence || '/data/asap2/fus'
    dir = File.join(shared_root, 'isolated_compliance_uploads')
    FileUtils.mkdir_p(dir)
    dir
  end

  def download_remote_file!(task_id, url)
    uri = URI.parse(url.to_s.strip)
    raise ArgumentError, 'Only HTTP/HTTPS URLs are supported' unless uri.is_a?(URI::HTTP)

    path = File.join(temp_dir, "#{task_id}.download")
    downloaded = 0
    total = nil
    last_report_at = 0.0

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      http.request(request) do |response|
        raise ArgumentError, "Download failed (HTTP #{response.code})" unless response.code.to_i.between?(200, 299)

        total = response['Content-Length'].to_i
        total = nil if total <= 0
        report_download_progress(task_id, downloaded, total)

        File.open(path, 'wb') do |file|
          response.read_body do |chunk|
            downloaded += chunk.bytesize
            max_size = ComplianceFileCheckQueueService::MAX_UPLOAD_SIZE
            raise ArgumentError, 'Remote file is too large' if downloaded > max_size

            file.write(chunk)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            next unless now - last_report_at >= PROGRESS_MIN_INTERVAL

            last_report_at = now
            report_download_progress(task_id, downloaded, total)
          end
        end
      end
    end

    report_download_progress(task_id, downloaded, total)
    path
  rescue URI::InvalidURIError
    raise ArgumentError, 'Invalid URL'
  end

  def rename_downloaded_file!(path, task_id, detected_format)
    extension = detected_format == 'loom' ? '.loom' : '.h5ad'
    final_path = File.join(temp_dir, "#{task_id}#{extension}")
    FileUtils.mv(path, final_path)
    final_path
  end

  def report_download_progress(task_id, downloaded, total)
    transfer_progress = if total.to_i.positive?
                          ((downloaded.to_f / total) * 100).round
                        end

    payload = {
      status: 'downloading',
      task_id: task_id,
      progress: 0,
      transfer_progress: transfer_progress,
      transfer_downloaded: downloaded,
      transfer_total: total,
      message: 'Downloading file...'
    }.compact

    write_and_broadcast(task_id, payload)
  end

  def write_and_broadcast(task_id, payload)
    IsolatedComplianceStatusStore.write(task_id, payload)
    ActionCable.server.broadcast("isolated_compliance_#{task_id}", payload)
  end

  def fail_task(fu, message, error_code: nil)
    task_id = fu&.compliance_task_id
    fu&.update(status: 'download_failed')
    return if task_id.blank?

    payload = {
      status: 'failed',
      task_id: task_id,
      message: message,
      error: message
    }
    payload[:error_code] = error_code if error_code.present?
    write_and_broadcast(task_id, payload)
  end
end
