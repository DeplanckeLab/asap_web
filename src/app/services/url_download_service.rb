# frozen_string_literal: true

require 'open3'

# Streams a remote URL to disk with curl so a long CELLxGENE download can resume
# after a worker prune instead of truncating the dest file with a second curl.
class UrlDownloadService
  PID_FILENAME = 'download.pid'
  HEARTBEAT_SEC = 15

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

  def initialize(fu:, url:, dest_path:, logger: Rails.logger)
    @fu = fu
    @url = url.to_s
    @dest_path = dest_path.to_s
    @logger = logger
  end

  def call
    FileUtils.mkdir_p(File.dirname(@dest_path))
    FileUtils.mkdir_p(@fu.global_upload_dir.to_s)
    expected = fetch_remote_size
    @fu.update_column(:upload_file_size, expected) if expected.to_i.positive?

    pid_path = self.class.pid_path_for_fu(@fu)
    existing_pid = self.class.live_pid(pid_path)
    if existing_pid
      @logger.info("[UrlDownloadService] Fu##{@fu.id} waiting for in-flight curl pid=#{existing_pid}")
      wait_for_pid(existing_pid)
    else
      download_with_curl!(pid_path)
    end

    verify_complete!(expected)
    File.size(@dest_path)
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
      '-o', @dest_path,
      @url
    ]

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

  def heartbeat_until(wait_thr)
    while wait_thr.alive?
      @fu.touch
      wait_thr.join(HEARTBEAT_SEC)
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
      @fu.touch
      sleep HEARTBEAT_SEC
    end
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
    output, _err, status = Open3.capture3(
      'curl', '-sIL', '--connect-timeout', '20', @url
    )
    return nil unless status.success?

    header_line = output.to_s.lines.reverse.find { |line| line =~ /^content-length:\s*\d+/i }
    return nil unless header_line

    header_line.split(':', 2).last.to_s.strip.to_i
  rescue StandardError
    nil
  end
end
