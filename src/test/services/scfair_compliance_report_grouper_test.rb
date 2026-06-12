# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairComplianceReportGrouperTest < TestBaseWithoutFixtures
  test 'groups missing uns fields under uns.required_presence with failed status' do
    catalog = [{ id: 'uns.required_presence', label: 'Required dataset metadata fields' }]
    errors = [{ field: 'uns/title', message: 'Missing required dataset metadata field' }]
    valid_checks = [
      { field: 'uns/organism_ontology_term_id', message: 'Required field present', status: 'passed' },
      { field: 'uns/title', message: 'Missing required dataset metadata field', status: 'failed' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: errors,
      warnings: [],
      format: 'h5ad'
    )

    items = groups.first[:items]
    assert_equal 'failed', items.find { |item| item[:field] == 'uns/title' }[:status]
    assert_equal 'passed', items.find { |item| item[:field] == 'uns/organism_ontology_term_id' }[:status]
  end

  test 'routes ensembl uns fields to uns.ensembl category' do
    catalog = [{ id: 'uns.ensembl', label: 'Ensembl gene annotation metadata' }]
    valid_checks = [
      { field: 'uns/ensembl_release', status: 'failed', message: 'Missing required dataset metadata field' },
      { field: 'uns.ensembl.database', status: 'failed', message: 'ensembl_database must be one of: Ensembl' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    assert_equal 1, groups.size
    assert_equal 'uns.ensembl', groups.first[:id]
    assert_equal 2, groups.first[:items].size
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

  test 'catalog id matches grouper category for cross-field rule checks' do
    catalog = Scfair::Rules.checks_for('h5ad')
    cross_field_entry = catalog.find { |entry| entry[:id] == 'cross-field.constraints' }
    assert_not_nil cross_field_entry
    assert_equal 'cross-field.constraints', cross_field_entry[:id]

    valid_checks = [
      { field: 'cross-field.CF-1-assay-suspension', status: 'passed', message: 'Assay/suspension_type consistency' },
      { field: 'cross-field.CF-3-donor-id', status: 'passed', message: 'donor_id consistency OK' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    cross_field_group = groups.find { |group| group[:id] == 'cross-field.constraints' }
    assert_not_nil cross_field_group
    assert_equal 2, cross_field_group[:items].size
  end

  test 'orders cross-field rule checks numerically so CF-9 follows CF-8' do
    catalog = [{ id: 'cross-field.constraints', label: 'Cross-field schema constraints' }]
    valid_checks = [
      { field: 'cross-field.CF-9-spatial-metadata-presence', status: 'passed', message: 'Spatial metadata presence consistent with assay' },
      { field: 'cross-field.CF-1-assay-suspension', status: 'passed', message: 'Assay/suspension_type consistency' },
      { field: 'cross-field.CF-8-visium-in-tissue', status: 'passed', message: 'Visium in_tissue constraint OK' },
      { field: 'cross-field.CF-2a-cell-line-ethnicity', status: 'skipped', message: 'Not applicable' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    fields = groups.first[:items].map { |item| item[:field] }
    assert_equal [
      'cross-field.CF-1-assay-suspension',
      'cross-field.CF-2a-cell-line-ethnicity',
      'cross-field.CF-8-visium-in-tissue',
      'cross-field.CF-9-spatial-metadata-presence'
    ], fields
  end

  test 'routes obs label pair checks to obs.label_pairs category' do
    catalog = [{ id: 'obs.label_pairs', label: 'Observation label / ontology ID pairs' }]
    valid_checks = [
      { field: 'obs.label_pairs.assay_ontology_term_id', status: 'passed', message: 'assay pair OK' },
      { field: 'obs.label_pairs.cell_type_ontology_term_id', status: 'failed', message: 'cell type mismatch' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    assert_equal 'obs.label_pairs', groups.first[:id]
    assert_equal 2, groups.first[:items].size
  end

  test 'routes var cross-field checks to var.cross_field category' do
    catalog = [{ id: 'var.cross_field', label: 'Var metadata cross-field consistency' }]
    valid_checks = [
      { field: 'var.cross_field.feature_reference', status: 'passed', message: 'feature_reference OK' },
      { field: 'var.cross_field.feature_name.index', status: 'failed', message: 'feature_name mismatch' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    assert_equal 'var.cross_field', groups.first[:id]
    assert_equal 2, groups.first[:items].size
  end

  test 'routes var index checks to var.index category' do
    catalog = [{ id: 'var.index', label: 'Var index (feature identifiers)' }]
    valid_checks = [
      { field: 'var.index', status: 'passed', message: 'Var index present' },
      { field: 'var.index.uniqueness', status: 'passed', message: 'Unique' },
      { field: '/row_attrs/feature_id', status: 'passed', message: 'Loom feature_id present' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    assert_equal 'var.index', groups.first[:id]
    assert_equal 3, groups.first[:items].size
  end

  test 'routes uns ensembl cross-field checks to cross-field.uns_ensembl category' do
    catalog = [{ id: 'cross-field.uns_ensembl', label: 'Ensembl release and assembly consistency' }]
    valid_checks = [
      { field: 'cross-field.uns_ensembl.release', status: 'passed', message: 'Release supported' },
      { field: 'cross-field.uns_ensembl.assembly', status: 'skipped', message: 'Assembly absent' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    assert_equal 'cross-field.uns_ensembl', groups.first[:id]
  end
end
