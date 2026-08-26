# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class ComplianceGuestCreatorIpTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs

    @tmp_root = Dir.mktmpdir('compliance-guest-creator-ip')
    @previous_upload_data_dir = ENV['UPLOAD_DATA_DIR']
    ENV['UPLOAD_DATA_DIR'] = File.join(@tmp_root, 'fus')
    FileUtils.mkdir_p(ENV['UPLOAD_DATA_DIR'])

    @upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if @upload_type_id.blank?
  end

  teardown do
    destroy_registered_test_records!
    ENV['UPLOAD_DATA_DIR'] = @previous_upload_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test 'guest URL validation stores X-Real-IP on Fu and failed check' do
    get compliance_file_check_path
    assert_response :success
    assert session[:sandbox].present?

    assert_enqueued_with(job: IsolatedComplianceUrlDownloadJob) do
      post compliance_file_check_create_path,
           params: {
             source: 'url',
             data_url: 'https://example.com/guest-creator-ip.h5ad',
             schema_id: 'scfair_7_1_0'
           },
           headers: { 'HTTP_X_REAL_IP' => '203.0.113.40', 'HTTP_ACCEPT' => 'application/json' }
    end
    assert_response :success

    payload = JSON.parse(response.body)
    fu = register_for_test_cleanup(Fu.find(payload['fu_id']))
    assert_nil fu.user_id
    assert_equal '203.0.113.40', fu.creator_ip
    assert_equal false, fu.admin_run

    perform_enqueued_jobs only: IsolatedComplianceUrlDownloadJob

    check = StandaloneComplianceCheck.where(fu_id: fu.id).order(id: :desc).first
    assert check, 'Expected a standalone compliance check row'
    register_for_test_cleanup(check)
    assert check.guest?
    assert_equal '203.0.113.40', check.creator_ip
  end

  test 'guest upload resume stamps X-Real-IP onto an existing Fu without creator_ip' do
    get compliance_file_check_path
    assert_response :success
    sandbox = session[:sandbox]

    fu = register_for_test_cleanup(
      Fu.create!(
        user_id: nil,
        project_key: sandbox,
        upload_file_name: 'input_file.loom',
        upload_file_size: 0,
        name: 'resume-guest.loom',
        status: 'uploading',
        upload_type: @upload_type_id,
        admin_run: false,
        creator_ip: nil
      )
    )

    content = 'loom-bytes-for-guest-ip'
    file = Tempfile.new(['resume-guest', '.loom'])
    file.write(content)
    file.rewind

    post upload_chunk_fus_path,
         params: {
           filename: 'resume-guest.loom',
           chunk: Rack::Test::UploadedFile.new(file.path, 'application/octet-stream'),
           chunk_index: 0,
           total_chunks: 1,
           file_size: content.bytesize,
           fu_id: fu.id,
           upload_type_name: 'compliance_file_check',
           schema_id: 'scfair_7_1_0'
         },
         headers: { 'HTTP_X_REAL_IP' => '198.51.100.77' }

    assert_response :success
    fu.reload
    assert_equal '198.51.100.77', fu.creator_ip
    assert_equal false, fu.admin_run
  ensure
    file&.close!
  end
end
