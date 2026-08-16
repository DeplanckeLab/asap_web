# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'

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

    result = CompliancePipeline.wrap_file_check_result(fake_core)
    refute result.valid?
    assert_equal 1, result.errors.size
  end

  test 'ensure_anndata_mapping_before_project_validation refreshes loom under project' do
    user_data = Dir.mktmpdir('compliance_pipeline_user_data')
    project_dir = File.join(user_data, '9', 'ABCD')
    FileUtils.mkdir_p(File.join(project_dir, 'parsing'))
    loom_rel = 'parsing/output.loom'
    loom_path = File.join(project_dir, loom_rel)
    File.write(loom_path, 'loom')

    project = Struct.new(:user_id, :key).new(9, 'ABCD')
    refreshed = []

    with_env('USER_DATA_DIR' => user_data) do
      with_replaced_singleton(Basic, :refresh_anndata_mapping_for_loom, lambda { |_logger, proj, rel|
        refreshed << [proj.key, rel]
        { ok: true, loom_filepath: rel }
      }) do
        CompliancePipeline.ensure_anndata_mapping_before_project_validation!(loom_path, project, nil)
      end
    end

    assert_equal [['ABCD', loom_rel]], refreshed
  ensure
    FileUtils.remove_entry(user_data) if user_data && File.directory?(user_data)
  end

  test 'ensure_anndata_mapping_before_project_validation skips loom outside project' do
    project = Struct.new(:user_id, :key).new(9, 'ABCD')
    refreshed = []

    with_replaced_singleton(Basic, :refresh_anndata_mapping_for_loom, lambda { |*|
      refreshed << true
      { ok: true }
    }) do
      CompliancePipeline.ensure_anndata_mapping_before_project_validation!('/tmp/other.loom', project, nil)
      CompliancePipeline.ensure_anndata_mapping_before_project_validation!('/tmp/x.loom', nil, nil)
    end

    assert_empty refreshed
  end

  test 'loom_rel_under_project returns relative path inside project dir' do
    user_data = Dir.mktmpdir('compliance_pipeline_rel')
    project = Struct.new(:user_id, :key).new(3, 'KEY1')
    loom_path = File.join(user_data, '3', 'KEY1', 'parsing', 'output.loom')

    with_env('USER_DATA_DIR' => user_data) do
      assert_equal 'parsing/output.loom', CompliancePipeline.loom_rel_under_project(project, loom_path)
      assert_nil CompliancePipeline.loom_rel_under_project(project, '/tmp/other.loom')
      assert_nil CompliancePipeline.loom_rel_under_project(nil, loom_path)
    end
  ensure
    FileUtils.remove_entry(user_data) if user_data && File.directory?(user_data)
  end

  test 'asap_data_db_name_for_project reads version env_json' do
    version = Struct.new(:env_data).new(
      { 'asap_data_db_name' => 'asap_data_v8', 'asap_data_db_version' => 8 }
    )
    project = Struct.new(:version_for_catalog).new(version)

    assert_equal 'asap_data_v8', CompliancePipeline.asap_data_db_name_for_project(project)
    assert_nil CompliancePipeline.asap_data_db_name_for_project(nil)
  end

  private

  def with_replaced_singleton(mod, method_name, impl)
    original = mod.method(method_name)
    mod.define_singleton_method(method_name, &impl)
    yield
  ensure
    mod.define_singleton_method(method_name, original)
  end

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
