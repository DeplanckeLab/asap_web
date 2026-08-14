# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'tmpdir'
require 'fileutils'

class IsolatedComplianceUrlDownloadJobTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir('isolated-compliance-url')
    @previous_upload_data_dir = ENV['UPLOAD_DATA_DIR']
    ENV['UPLOAD_DATA_DIR'] = File.join(@tmp_root, 'fus')
    FileUtils.mkdir_p(ENV['UPLOAD_DATA_DIR'])
    @upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if @upload_type_id.blank?
  end

  teardown do
    ENV['UPLOAD_DATA_DIR'] = @previous_upload_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'create_fu_for_downloaded_file stores a guest-scoped canonical input file' do
    source_path = File.join(@tmp_root, 'downloaded.h5ad')
    File.write(source_path, 'h5ad-bytes')
    job = IsolatedComplianceUrlDownloadJob.new

    fu = job.send(
      :create_fu_for_downloaded_file!,
      source_path,
      'https://example.com/path/demo.h5ad',
      detected_format: 'h5ad',
      user_id: nil,
      project_key: 'abc123'
    )
    register_for_test_cleanup(fu)

    assert_equal 'input_file.h5ad', fu.upload_file_name
    assert_equal 'demo.h5ad', fu.name
    assert_equal 'abc123', fu.project_key
    assert_nil fu.user_id
    assert_equal 'https://example.com/path/demo.h5ad', fu.url
    assert_equal 'validating', fu.status
    assert_equal @upload_type_id, fu.upload_type
    assert File.exist?(fu.file_path.to_s)
    assert_equal 'h5ad-bytes', File.read(fu.file_path)
    assert_equal false, File.exist?(source_path)
  end
end
