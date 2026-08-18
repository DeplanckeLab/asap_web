# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class UrlDownloadServiceTest < ActiveSupport::TestCase
  setup do
    @tmp_root = Dir.mktmpdir('url-download-service')
    @previous_upload_data_dir = ENV['UPLOAD_DATA_DIR']
    ENV['UPLOAD_DATA_DIR'] = File.join(@tmp_root, 'fus')
    FileUtils.mkdir_p(ENV['UPLOAD_DATA_DIR'])
  end

  teardown do
    ENV['UPLOAD_DATA_DIR'] = @previous_upload_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'live_pid returns the pid when the process is running' do
    Dir.mktmpdir do |dir|
      pid_path = File.join(dir, UrlDownloadService::PID_FILENAME)
      File.write(pid_path, Process.pid.to_s)
      assert_equal Process.pid, UrlDownloadService.live_pid(pid_path)
    end
  end

  test 'live_pid returns nil when the pid is not running' do
    Dir.mktmpdir do |dir|
      pid_path = File.join(dir, UrlDownloadService::PID_FILENAME)
      File.write(pid_path, '99999999')
      assert_nil UrlDownloadService.live_pid(pid_path)
    end
  end

  test 'raises when downloaded size is below Content-Length' do
    fu = register_for_test_cleanup(
      Fu.create!(
        name: 'remote.h5ad',
        upload_file_name: 'input_file.h5ad',
        upload_file_size: 0,
        status: 'downloading',
        url: 'https://example.com/remote.h5ad'
      )
    )
    dest = File.join(fu.global_upload_dir.to_s, fu.upload_file_name)
    FileUtils.mkdir_p(File.dirname(dest))
    service = UrlDownloadService.new(fu: fu, url: fu.url, dest_path: dest)
    service.define_singleton_method(:fetch_remote_size) { 100 }
    service.define_singleton_method(:download_with_curl!) { |_pid_path| File.write(dest, 'x' * 10) }

    error = assert_raises(UrlDownloadService::Error) { service.call }
    assert_match(/Download incomplete/, error.message)
    assert_match(/got 10 bytes/, error.message)
    assert_match(/expected 100 bytes/, error.message)
  end
end
