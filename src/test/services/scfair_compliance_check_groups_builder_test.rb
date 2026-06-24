# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairComplianceCheckGroupsBuilderTest < TestBaseWithoutFixtures
  test 'groups ensembl release checks under uns.ensembl category' do
    groups = Scfair::ComplianceCheckGroupsBuilder.call(
      errors: [{ field: 'uns.ensembl.release', message: 'Missing uns/ensembl_release metadata (required by schema)' }],
      warnings: [],
      valid_checks: [],
      field_values: {},
      format: 'loom'
    )

    ensembl = groups.find { |g| g[:id] == 'uns.ensembl' }
    assert ensembl.present?, 'expected uns.ensembl category'
    assert_equal 'uns.ensembl', ensembl[:items].first[:field]
  end

  test 'rebuilds category labels from rules.yaml catalog' do
    groups = Scfair::ComplianceCheckGroupsBuilder.call(
      errors: [],
      warnings: [],
      valid_checks: [{ field: '/attrs/title', message: 'Found /attrs/title metadata', status: 'passed' }],
      field_values: { '/attrs/title' => ['My dataset'] },
      format: 'loom'
    )

    title_group = groups.find { |g| g[:id] == 'uns.required_presence' }
    assert title_group.present?
    assert_equal Scfair::Rules.check_entry('uns.required_presence')[:label], title_group[:label]
  end
end
