# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'minitest/mock'

class IsolatedComplianceValidationJobTest < TestBaseWithoutFixtures
  class FakeComplianceService
    def initialize(**)
    end

    def validate
      {
        valid: true,
        format: 'loom',
        schema_id: 'scfair_7_1_0',
        validated_at: Time.zone.parse('2026-08-05T13:00:00Z').iso8601,
        field_values: { 'x' => [1] },
        checks_catalog: [],
        errors: [],
        warnings: [],
        valid_checks: [{ field: 'obs/title', message: 'ok' }],
        summary: { errors_count: 0, warnings_count: 0, valid_checks_count: 1 }
      }
    end
  end

  test 'perform persists a standalone compliance check on success' do
    upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if upload_type_id.blank?

    user = register_for_test_cleanup(
      User.create!(email: "job_scc_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    fu = register_for_test_cleanup(
      Fu.create!(
        name: 'demo.loom',
        upload_file_name: 'demo.loom',
        upload_file_size: 10,
        status: 'validating',
        upload_type: upload_type_id,
        user_id: user.id,
        url: 'https://example.com/demo.loom',
        admin_run: true,
        creator_ip: '203.0.113.50'
      )
    )

    path = File.join(Dir.tmpdir, "isolated-compliance-#{SecureRandom.hex(4)}.loom")
    File.write(path, 'x')

    ScfairComplianceService.stub(:new, ->(**kwargs) { FakeComplianceService.new(**kwargs) }) do
      IsolatedComplianceStatusStore.stub(:write, true) do
        ActionCable.server.stub(:broadcast, true) do
          IsolatedComplianceValidationJob.perform_now(
            SecureRandom.uuid,
            path,
            'scfair_7_1_0',
            'demo.loom',
            fu_id: fu.id
          )
        end
      end
    end

    record = StandaloneComplianceCheck.where(fu_id: fu.id).order(id: :desc).first
    assert record, 'Expected standalone compliance check row'
    register_for_test_cleanup(record)

    assert_equal user.id, record.user_id
    assert_equal 'demo.loom', record.filename
    assert_equal 'https://example.com/demo.loom', record.source_url
    assert_equal 'loom', record.format
    assert_equal true, record.passed
    assert_equal 'completed', record.status
    assert_equal true, record.admin_run
    assert_equal '203.0.113.50', record.creator_ip
    assert_equal 'validated', fu.reload.status
  ensure
    FileUtils.rm_f(path) if path
  end
end
