# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class ComplianceResultDownloadTest < ActionDispatch::IntegrationTest
  setup do
    @tmp_root = Dir.mktmpdir('compliance-result-download')
    @previous_user_data_dir = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = File.join(@tmp_root, 'projects')
    FileUtils.mkdir_p(ENV['USER_DATA_DIR'])

    @user = register_for_test_cleanup(
      User.create!(email: "crd_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
  end

  teardown do
    destroy_registered_test_records!
    ENV['USER_DATA_DIR'] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'public project compliance result is downloadable as JSON' do
    project = create_test_project!(
      user_id: @user.id,
      public: true,
      public_id: (Project.maximum(:public_id) || 0) + 1,
      input_filename: 'input_file.loom'
    )
    write_project_validation_result!(project, valid: true, schema_version: '7.1.0')

    get compliance_project_result_path(project.key, format: :json)
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal project.key, body['project_key']
    assert_equal project.public_id, body['public_id']
    assert_equal true, body['public']
    assert_equal true, body.dig('result', 'valid')
    assert_equal '7.1.0', body.dig('result', 'schema_version')
  end

  test 'private project compliance result JSON is forbidden' do
    project = create_test_project!(
      user_id: @user.id,
      public: false,
      input_filename: 'input_file.loom'
    )
    write_project_validation_result!(project, valid: false, schema_version: '7.1.0')

    get compliance_project_result_path(project.key, format: :json)
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_match(/public projects/i, body['error'])
  end

  test 'standalone check lookup by source_url returns latest result' do
    url = "https://example.com/datasets/#{SecureRandom.hex(4)}.h5ad"
    older = register_for_test_cleanup(
      StandaloneComplianceCheckRecorder.record_completed!(
        task_id: SecureRandom.uuid,
        result: {
          valid: false,
          format: 'h5ad',
          schema_id: 'scfair_7_1_0',
          schema_version: '7.1.0',
          validated_at: 2.days.ago.iso8601,
          errors: [{ field: 'obs/assay', message: 'missing' }],
          warnings: [],
          valid_checks: [],
          summary: { errors_count: 1 }
        },
        filename: 'dataset.h5ad',
        schema_id: 'scfair_7_1_0',
        source_url: url,
        admin_run: true
      )
    )
    newer = register_for_test_cleanup(
      StandaloneComplianceCheckRecorder.record_completed!(
        task_id: SecureRandom.uuid,
        result: {
          valid: true,
          format: 'h5ad',
          schema_id: 'scfair_7_1_0',
          schema_version: '7.1.0',
          validated_at: Time.current.iso8601,
          errors: [],
          warnings: [],
          valid_checks: [{ field: 'obs/assay', message: 'ok' }],
          summary: { errors_count: 0 }
        },
        filename: 'dataset.h5ad',
        schema_id: 'scfair_7_1_0',
        source_url: url,
        admin_run: true
      )
    )

    get compliance_checks_lookup_path, params: { source_url: url }
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal newer.id, body['id']
    assert_equal url, body['source_url']
    assert_equal 'dataset.h5ad', body['filename']
    assert_equal true, body['passed']
    assert_equal true, body.dig('result', 'valid')
    refute_equal older.id, body['id']
  end

  test 'API standalone check lookup by source_url returns latest result' do
    url = "https://example.com/datasets/#{SecureRandom.hex(4)}.h5ad"
    check = register_for_test_cleanup(
      StandaloneComplianceCheckRecorder.record_completed!(
        task_id: SecureRandom.uuid,
        result: {
          valid: true,
          format: 'h5ad',
          schema_id: 'scfair_7_1_0',
          schema_version: '7.1.0',
          validated_at: Time.current.iso8601,
          errors: [],
          warnings: [],
          valid_checks: [{ field: 'obs/assay', message: 'ok' }],
          summary: { errors_count: 0 }
        },
        filename: 'dataset.h5ad',
        schema_id: 'scfair_7_1_0',
        source_url: url,
        admin_run: true
      )
    )

    get '/api/compliance/checks', params: { source_url: url }
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal check.id, body['id']
    assert_equal url, body['source_url']
    assert_equal true, body['passed']
    assert_equal true, body.dig('result', 'valid')
  end

  test 'standalone check lookup by filename works' do
    filename = "unique_#{SecureRandom.hex(4)}.loom"
    check = register_for_test_cleanup(
      StandaloneComplianceCheckRecorder.record_completed!(
        task_id: SecureRandom.uuid,
        result: {
          valid: true,
          format: 'loom',
          schema_id: 'scfair_7_1_0',
          schema_version: '7.1.0',
          validated_at: Time.current.iso8601,
          errors: [],
          warnings: [],
          valid_checks: [],
          summary: { errors_count: 0 }
        },
        filename: filename,
        schema_id: 'scfair_7_1_0',
        source_url: "https://example.com/#{filename}",
        admin_run: false
      )
    )

    get compliance_checks_lookup_path, params: { filename: filename }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal check.id, body['id']
    assert_equal filename, body['filename']
  end

  test 'standalone check lookup requires source_url or filename' do
    get compliance_checks_lookup_path
    assert_response :unprocessable_entity
  end

  private

  def write_project_validation_result!(project, valid:, schema_version:)
    dir = File.join(ENV.fetch('USER_DATA_DIR'), project.user_id.to_s, project.key)
    FileUtils.mkdir_p(dir)
    payload = {
      valid: valid,
      schema_version: schema_version,
      schema_id: 'scfair_7_1_0',
      validated_at: Time.current.iso8601,
      errors: [],
      warnings: [],
      valid_checks: [],
      summary: { errors_count: 0, warnings_count: 0 }
    }
    File.write(File.join(dir, 'cxg_validation_result.json'), payload.to_json)
  end
end
