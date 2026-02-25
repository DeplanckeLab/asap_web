require 'open-uri'
require 'uri'
require 'open3'

class FuDownloadFromUrlJob < ApplicationJob
  queue_as :default

  def perform(fu_id, url, organism_id: nil, version_id: nil)
    fu = Fu.find_by(id: fu_id)
    return unless fu

    upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                        ENV["UPLOAD_DATA_DIR"]
                      elsif ENV["DATA_DIR"]
                        Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                      else
                        '/data/asap2/fus'
                      end

    upload_base_path = Pathname.new(upload_base_dir)
    FileUtils.mkdir_p(upload_base_path) unless upload_base_path.exist?

    upload_dir = upload_base_path.join(fu.id.to_s)
    FileUtils.mkdir_p(upload_dir)
    upload_file_path = upload_dir.join(fu.upload_file_name)

    remote_total_size = fetch_remote_size(url)
    fu.update_column(:upload_file_size, remote_total_size) if remote_total_size.to_i > 0

    # Stream download with curl so bytes are flushed progressively to disk.
    curl_cmd = [
      'curl',
      '-L',
      '--fail',
      '--connect-timeout', '30',
      '--retry', '2',
      '--retry-delay', '2',
      '--output', upload_file_path.to_s,
      url.to_s
    ]

    combined_output = +''
    Open3.popen2e(*curl_cmd) do |stdin, stdout_and_stderr, wait_thr|
      stdin.close
      combined_output = stdout_and_stderr.read.to_s
      exit_status = wait_thr.value.exitstatus
      raise "curl download failed (exit #{exit_status}): #{combined_output}" unless exit_status == 0
    end

    downloaded_size = File.size(upload_file_path)
    raise "Downloaded file is missing or empty" unless File.exist?(upload_file_path) && downloaded_size > 0

    options = {}
    options[:organism_id] = organism_id if organism_id.present?
    options[:version_id] = version_id if version_id.present?

    fu.update!(
      upload_file_size: downloaded_size,
      status: 'preparsing'
    )
    broadcast(fu.id, status: 'started')

    result = FuPreparsingService.new(fu, options).call
    fu.update!(status: 'preparsed')

    broadcast(
      fu.id,
      status: 'completed',
      summary: result[:summary],
      warnings: result[:warnings],
      raw_output: result[:raw_output],
      prediction_debug: result[:summary][:prediction_debug]
    )
  rescue URI::InvalidURIError, OpenURI::HTTPError => e
    Rails.logger.error("[FuDownloadFromUrlJob] Download failed for Fu##{fu_id}: #{e.class} - #{e.message}")
    fu&.update(status: 'download_failed')
  rescue StandardError => e
    Rails.logger.error("[FuDownloadFromUrlJob] Preparsing failed for Fu##{fu_id}: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    fu&.update(status: 'preparsing_failed')
    broadcast(fu.id, status: 'failed', error: e.message) if fu
  end

  private

  def fetch_remote_size(url)
    head_cmd = ['curl', '-sIL', '--connect-timeout', '20', url.to_s]
    output, _err, status = Open3.capture3(*head_cmd)
    return nil unless status.success?

    header_line = output.to_s.lines.reverse.find { |line| line =~ /^content-length:\s*\d+/i }
    return nil unless header_line

    header_line.split(':', 2).last.to_s.strip.to_i
  rescue StandardError
    nil
  end

  def broadcast(fu_id, payload)
    ActionCable.server.broadcast("fu_#{fu_id}", payload.merge(fu_id: fu_id, stage: 'preparsing'))
  end
end
