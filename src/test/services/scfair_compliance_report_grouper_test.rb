# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairComplianceReportGrouperTest < TestBaseWithoutFixtures
  test 'groups missing uns fields under uns.required_presence with failed status' do
    catalog = [{ id: 'uns.required_presence', label: 'Required dataset metadata fields' }]
    errors = [{ field: 'uns/ensembl_release', message: 'Missing required dataset metadata field' }]
    valid_checks = [
      { field: 'uns/title', message: 'Required field present', status: 'passed' },
      { field: 'uns/ensembl_release', message: 'Missing required dataset metadata field', status: 'failed' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: errors,
      warnings: [],
      format: 'h5ad'
    )

    items = groups.first[:items]
    ensembl = items.find { |item| item[:field] == 'uns/ensembl_release' }
    assert_equal 'failed', ensembl[:status]
    assert_equal 'passed', items.find { |item| item[:field] == 'uns/title' }[:status]
  end

  test 'routes schema version issues to schema.version category' do
    catalog = [{ id: 'schema.version', label: 'Schema version compatibility' }]
    errors = [{
      field: 'uns/schema_version',
      message: 'schema_version minor version 7.0 (7.0.0) is lower than required 7.1 (7.1.0)'
    }]
    valid_checks = [{
      field: 'uns/schema_version',
      status: 'failed',
      message: errors.first[:message]
    }]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: errors,
      warnings: [],
      format: 'h5ad'
    )

    assert_equal 1, groups.first[:items].size
    assert_equal 'failed', groups.first[:items].first[:status]
  end

  test 'omits catalog categories with no recorded checks' do
    catalog = [
      { id: 'obs.required_presence', label: 'Required observation metadata fields' },
      { id: 'ontology.format', label: 'Ontology identifier format checks' }
    ]
    valid_checks = [{ field: 'obs/tissue_type', message: 'Required field present', status: 'passed' }]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    assert_equal 1, groups.size
    assert_equal 'obs.required_presence', groups.first[:id]
  end

  test 'routes loom cross-field violation messages to cross-field.constraints' do
    catalog = [{ id: 'cross-field.constraints', label: 'Cross-field schema constraints' }]
    errors = [{
      field: '/col_attrs/suspension_type',
      message: 'For assay EFO:0008720, suspension_type MUST be one of: nucleus. Got "cell".'
    }]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: [],
      errors: errors,
      warnings: [],
      format: 'loom'
    )

    assert_equal 1, groups.size
    assert_equal 'failed', groups.first[:items].first[:status]
  end
end
