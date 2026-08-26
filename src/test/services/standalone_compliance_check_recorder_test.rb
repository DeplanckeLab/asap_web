# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class StandaloneComplianceCheckRecorderTest < TestBaseWithoutFixtures
  test 'record_completed! stores outcome metadata and omits heavy result keys' do
    user = register_for_test_cleanup(
      User.create!(email: "scc_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    validated_at = Time.zone.parse('2026-08-05T12:00:00Z')
    result = {
      valid: false,
      format: 'h5ad',
      schema_id: 'scfair_7_1_0',
      schema_version: '7.1.0',
      validated_at: validated_at.iso8601,
      field_values: { 'obs/assay' => ['huge'] * 100 },
      checks_catalog: [{ id: 'catalog_only' }],
      errors: [{ field: 'obs/assay', message: 'missing' }],
      warnings: [],
      valid_checks: [{ field: 'obs/title', message: 'ok' }],
      summary: { errors_count: 1, warnings_count: 0, valid_checks_count: 1 }
    }

    record = register_for_test_cleanup(
      StandaloneComplianceCheckRecorder.record_completed!(
        task_id: SecureRandom.uuid,
        result: result,
        filename: 'sample.h5ad',
        schema_id: 'scfair_7_1_0',
        user_id: user.id,
        source_url: 'https://example.com/sample.h5ad',
        fu_id: nil,
        admin_run: true,
        creator_ip: '203.0.113.10'
      )
    )

    assert_equal user.id, record.user_id
    assert_equal 'sample.h5ad', record.filename
    assert_equal 'https://example.com/sample.h5ad', record.source_url
    assert_equal 'h5ad', record.format
    assert_equal 'scfair_7_1_0', record.schema_id
    assert_equal false, record.passed
    assert_equal 'completed', record.status
    assert_equal true, record.admin_run
    assert_equal '203.0.113.10', record.creator_ip
    assert_in_delta validated_at, record.checked_at, 1
    assert record.result_json.key?('errors')
    assert record.result_json.key?('summary')
    refute record.result_json.key?('field_values')
    refute record.result_json.key?('checks_catalog')
  end

  test 'record_failed! stores failure outcome' do
    record = register_for_test_cleanup(
      StandaloneComplianceCheckRecorder.record_failed!(
        task_id: SecureRandom.uuid,
        error_message: 'boom',
        filename: 'broken.loom',
        schema_id: 'scfair_7_1_0',
        format: 'loom',
        admin_run: false,
        creator_ip: '198.51.100.7'
      )
    )

    assert_equal false, record.passed
    assert_equal 'failed', record.status
    assert_equal 'broken.loom', record.filename
    assert_equal 'loom', record.format
    assert_equal false, record.admin_run
    assert_equal '198.51.100.7', record.creator_ip
    assert_equal 'boom', record.result_json['error']
  end
end
