# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class CompliancePipelineTest < TestBaseWithoutFixtures
  test 'use_extract_pipeline defaults to true' do
    with_env('COMPLIANCE_USE_EXTRACT_PIPELINE' => nil) do
      assert CompliancePipeline.use_extract_pipeline?
    end
  end

  test 'use_extract_pipeline respects false' do
    with_env('COMPLIANCE_USE_EXTRACT_PIPELINE' => 'false') do
      refute CompliancePipeline.use_extract_pipeline?
    end
  end

  test 'displayable_valid_checks omits failed and warning mirrored entries' do
    checks = [
      { field: '/attrs/title', status: 'passed', message: 'Found title' },
      { field: '/attrs/organism_ontology_term_id', status: 'failed', message: 'Missing metadata' },
      { field: '/attrs/organism', status: 'warning', message: 'Check label' }
    ]

    visible = CompliancePipeline.displayable_valid_checks(checks)

    assert_equal 1, visible.size
    assert_equal '/attrs/title', visible.first[:field]
  end

  test 'wrap_file_check_result maps file-check hash to pipeline result' do
    core = {
      valid: true,
      errors: [],
      warnings: [{ field: 'obs/tissue', message: 'warn' }],
      info: [],
      valid_checks: [{ field: '/attrs/title', status: 'passed', message: 'ok' }],
      schema_version: '7.1.0',
      validated_at: '2026-01-01T00:00:00Z',
      field_values: { '/attrs/title' => ['x'] },
      check_groups: [{ id: 'uns.required_presence', label: 'Presence', items: [] }],
      format: 'loom'
    }

    result = CompliancePipeline.wrap_file_check_result(core)

    assert result.valid?
    assert_equal 'loom', result.format
    assert_equal 1, result.check_groups.size
    assert_equal ['x'], result.field_values[:'/attrs/title']
  end

  test 'validate_project_loom delegates to file-check service' do
    loom_path = '/tmp/test_compliance_pipeline.loom'
    fake_core = {
      valid: false,
      errors: [{ field: 'validation', message: 'boom' }],
      warnings: [],
      info: [],
      valid_checks: [],
      schema_version: '7.1.0',
      validated_at: '2026-01-01T00:00:00Z',
      field_values: {},
      check_groups: [],
      format: 'loom'
    }

    service = Minitest::Mock.new
    service.expect(:validate, fake_core)

    ScfairComplianceService.stub(:new, service) do
      result = CompliancePipeline.validate_project_loom(loom_path, nil)
      refute result.valid?
      assert_equal 1, result.errors.size
    end

    service.verify
  end

  private

  def with_env(overrides)
    previous = {}
    overrides.each do |key, value|
      previous[key] = ENV.key?(key) ? ENV[key] : :missing
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    previous.each do |key, value|
      if value == :missing
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
