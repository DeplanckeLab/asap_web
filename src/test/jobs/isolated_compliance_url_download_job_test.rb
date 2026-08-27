# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'tmpdir'
require 'fileutils'
require 'minitest/mock'

class IsolatedComplianceUrlDownloadJobTest < TestBaseWithoutFixtures
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
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
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test 'finalize_downloaded_fu stores a guest-scoped canonical input file' do
    source_path = File.join(@tmp_root, 'downloaded.h5ad')
    File.write(source_path, 'h5ad-bytes')
    fu = register_for_test_cleanup(
      Fu.create!(
        upload_file_name: 'pending.download',
        upload_file_size: 0,
        name: 'demo.h5ad',
        status: 'downloading',
        upload_type: @upload_type_id,
        user_id: nil,
        project_key: 'abc123',
        url: 'https://example.com/path/demo.h5ad',
        compliance_schema_id: 'scfair_7_1_0',
        compliance_task_id: SecureRandom.uuid
      )
    )
    job = IsolatedComplianceUrlDownloadJob.new

    job.finalize_downloaded_fu!(fu, source_path, 'h5ad')

    fu.reload
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

  test 'perform validates inline after download instead of enqueueing a separate job' do
    task_id = SecureRandom.uuid
    fu = register_for_test_cleanup(
      Fu.create!(
        upload_file_name: 'pending.download',
        upload_file_size: 0,
        name: 'inline.h5ad',
        status: 'downloading',
        upload_type: @upload_type_id,
        user_id: nil,
        url: 'https://example.com/inline.h5ad',
        compliance_schema_id: 'scfair_7_1_0',
        compliance_task_id: task_id,
        admin_run: true
      )
    )
    fu_id = fu.id

    downloaded = File.join(@tmp_root, "#{task_id}.download")
    File.write(downloaded, 'h5ad-bytes')

    job = IsolatedComplianceUrlDownloadJob.new
    job.define_singleton_method(:download_remote_file!) { |_tid, _url, **_opts| downloaded }
    job.define_singleton_method(:rename_downloaded_file!) do |path, tid, _fmt|
      final_path = File.join(@tmp_root, "#{tid}.h5ad")
      FileUtils.mv(path, final_path)
      final_path
    end
    job.define_singleton_method(:write_and_broadcast) { |*_args| true }

    fake_service = Object.new
    fake_service.define_singleton_method(:validate) do
      {
        valid: false,
        format: 'h5ad',
        schema_id: 'scfair_7_1_0',
        validated_at: Time.current.iso8601,
        field_values: {},
        checks_catalog: [],
        errors: [{ field: 'obs', message: 'missing' }],
        warnings: [],
        valid_checks: [],
        summary: { errors_count: 1, warnings_count: 0, valid_checks_count: 0 }
      }
    end

    ComplianceFileCheckQueueService.stub(:validate_downloaded_file!, 'h5ad') do
      ScfairComplianceService.stub(:new, ->(**_kwargs) { fake_service }) do
        IsolatedComplianceStatusStore.stub(:write, true) do
          ActionCable.server.stub(:broadcast, true) do
            job.perform(fu_id)
          end
        end
      end
    end

    assert_empty enqueued_jobs.select { |j| j[:job] == IsolatedComplianceValidationJob }
    check = StandaloneComplianceCheck.where(task_id: task_id).order(id: :desc).first
    assert check, 'Expected standalone compliance check from inline validation'
    register_for_test_cleanup(check)
    assert_equal false, check.passed
    assert_nil Fu.find_by(id: fu_id), 'Expected remote-download Fu to be deleted after inline validation'
  end
end
