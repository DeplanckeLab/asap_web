# frozen_string_literal: true

require 'open3'

# Streams a remote URL to disk with curl so a long CELLxGENE download can resume
# after a worker prune instead of truncating the dest file with a second curl.
class UrlDownloadService
  PID_FILENAME = 'download.pid'
  HEARTBEAT_SEC = 15
  PROGRESS_INTERVAL_SEC = 1
  # HuBMAP assets CDN rejects requests with no / default curl User-Agent (HTTP 403).
  USER_AGENT = 'ASAP-external-catalog (https://asap.epfl.ch)'.freeze

  class Error < StandardError; end

  def self.pid_path_for_fu(fu)
    File.join(fu.global_upload_dir.to_s, PID_FILENAME)
  end

  def self.live_pid(pid_path)
    return nil unless pid_path && File.exist?(pid_path)

    pid = File.read(pid_path).to_i
    return nil if pid <= 0

    Process.kill(0, pid)
    pid
  rescue Errno::ESRCH
    nil
  rescue Errno::EPERM
    pid
  end

  # progress_callback receives (downloaded_bytes, total_bytes_or_nil) while curl runs.
  def initialize(fu:, url:, dest_path:, logger: Rails.logger, progress_callback: nil)
    @fu = fu
    @url = url.to_s
    @dest_path = dest_path.to_s
    @logger = logger
    @progress_callback = progress_callback
    @expected_size = nil
  end

  def call
    FileUtils.mkdir_p(File.dirname(@dest_path))
    FileUtils.mkdir_p(@fu.global_upload_dir.to_s)
    @expected_size = fetch_remote_size
    @fu.update_column(:upload_file_size, @expected_size) if @expected_size.to_i.positive?
    report_progress!

    pid_path = self.class.pid_path_for_fu(@fu)
    existing_pid = self.class.live_pid(pid_path)
    if existing_pid
      @logger.info("[UrlDownloadService] Fu##{@fu.id} waiting for in-flight curl pid=#{existing_pid}")
      wait_for_pid(existing_pid)
    else
      download_with_curl!(pid_path)
    end

    verify_complete!(@expected_size)
    size = File.size(@dest_path)
    report_progress!(downloaded: size)
    size
  end

  private

  def download_with_curl!(pid_path)
    cmd = [
      'curl',
      '-L',
      '--fail',
      '--silent',
      '--show-error',
      '--connect-timeout', '30',
      '--retry', '5',
      '--retry-delay', '2',
      '-C', '-',
      '-o', @dest_path
    ]
    cmd += ['-A', USER_AGENT]
    auth = authorization_header
    cmd += ['-H', "Authorization: #{auth}"] if auth
    cmd << @url

    Open3.popen3(*cmd) do |stdin, _stdout, stderr, wait_thr|
      stdin.close
      File.write(pid_path, wait_thr.pid.to_s)
      heartbeat_until(wait_thr)
      err = stderr.read.to_s
      status = wait_thr.value
      unless status.success?
        raise Error, "curl download failed (exit #{status.exitstatus}): #{err}"
      end
    end
  ensure
    FileUtils.rm_f(pid_path) unless self.class.live_pid(pid_path)
  end

  def authorization_header
    ExternalCatalog::BroadScpCatalog.authorization_header_for!(@url)
  rescue ExternalCatalog::BroadScpCatalog::MissingAccessToken => e
    raise Error, e.message
  end

  def heartbeat_until(wait_thr)
    last_touch = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    interval = @progress_callback ? PROGRESS_INTERVAL_SEC : HEARTBEAT_SEC
    while wait_thr.alive?
      report_progress!
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now - last_touch >= HEARTBEAT_SEC
        @fu.touch
        last_touch = now
      end
      wait_thr.join(interval)
    end
  end

  def wait_for_pid(pid)
    loop do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        break
      rescue Errno::EPERM
        # Process exists.
      end
      report_progress!
      @fu.touch
      sleep(@progress_callback ? PROGRESS_INTERVAL_SEC : HEARTBEAT_SEC)
    end
  end

  def report_progress!(downloaded: nil)
    return unless @progress_callback

    bytes =
      if downloaded
        downloaded.to_i
      elsif File.exist?(@dest_path)
        File.size(@dest_path)
      else
        0
      end
    @progress_callback.call(bytes, @expected_size)
  rescue StandardError => e
    @logger.warn("[UrlDownloadService] progress callback failed: #{e.class}: #{e.message}")
  end

  def verify_complete!(expected)
    unless File.exist?(@dest_path) && File.size(@dest_path).positive?
      raise Error, 'Downloaded file is missing or empty'
    end

    actual = File.size(@dest_path)
    return if expected.to_i <= 0
    return if actual >= expected

    raise Error,
          "Download incomplete: got #{actual} bytes, expected #{expected} bytes from Content-Length"
  end

  def fetch_remote_size
    cmd = ['curl', '-sIL', '--connect-timeout', '20', '-A', USER_AGENT]
    auth = authorization_header
    cmd += ['-H', "Authorization: #{auth}"] if auth
    cmd << @url
    output, _err, status = Open3.capture3(*cmd)
    return nil unless status.success?

    header_line = output.to_s.lines.reverse.find { |line| line =~ /^content-length:\s*\d+/i }
    return nil unless header_line

    header_line.split(':', 2).last.to_s.strip.to_i
  rescue StandardError
    nil
  end
end
