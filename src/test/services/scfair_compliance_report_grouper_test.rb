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
      { field: 'uns.ensembl.release', check_id: 'uns.ensembl', status: 'failed', message: 'Missing uns/ensembl_release metadata (required by schema)' },
      { field: 'uns.ensembl.database', check_id: 'uns.ensembl', status: 'failed', message: 'ensembl_database must be one of: Ensembl' }
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

  test 'ensembl fields are not duplicated across uns.required_presence and uns.ensembl' do
    field_values = {
      'uns/ensembl_release' => ['115'],
      'uns/ensembl_database' => ['Ensembl'],
      'uns/ensembl_assembly' => ['GRCh38.p14']
    }
    presence = Scfair::ExtractPresenceValidator.new(field_values: field_values, format: 'h5ad').call
    ensembl = Scfair::UnsEnsemblValidator.new(field_values: field_values, format: 'h5ad').call
    catalog = Scfair::CheckCatalog.checks_for('h5ad')
    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: presence[:valid_checks] + ensembl[:valid_checks],
      errors: presence[:errors] + ensembl[:errors],
      warnings: [],
      format: 'h5ad'
    )

    required = groups.find { |group| group[:id] == 'uns.required_presence' }
    ensembl_group = groups.find { |group| group[:id] == 'uns.ensembl' }
    required_fields = Array(required&.dig(:items)).map { |item| item[:field] }
    ensembl_fields = Array(ensembl_group&.dig(:items)).map { |item| item[:field] }

    refute required_fields.any? { |field| field.match?(/ensembl/) }
    assert_equal %w[uns.ensembl.assembly uns.ensembl.database uns.ensembl.release], ensembl_fields.sort
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
      { field: '/row_attrs/Accession', status: 'passed', message: 'Loom Accession present' }
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

  test 'routes loom obs metadata paths to obs.required_presence' do
    catalog = [{ id: 'obs.required_presence', label: 'Required observation metadata fields' }]
    valid_checks = [{ field: '/col_attrs/assay', message: 'Found /col_attrs/assay metadata', status: 'passed' }]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'loom'
    )

    assert_equal 'obs.required_presence', groups.first[:id]
  end

  test 'routes loom uns metadata paths to uns.required_presence' do
    catalog = [{ id: 'uns.required_presence', label: 'Required dataset metadata fields' }]
    valid_checks = [{ field: '/attrs/title', message: 'Found /attrs/title metadata', status: 'passed' }]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'loom'
    )

    assert_equal 'uns.required_presence', groups.first[:id]
  end

  test 'routes loom file and cell id checks to loom.structure' do
    catalog = [{ id: 'loom.structure', label: 'Loom structural integrity' }]
    valid_checks = [
      { field: 'file', message: 'File readable', status: 'passed' },
      { field: '/col_attrs/CellID', message: 'Found /col_attrs/CellID metadata', status: 'passed' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'loom'
    )

    assert_equal 'loom.structure', groups.first[:id]
    assert_equal 2, groups.first[:items].size
  end

  test 'routes loom matrix dimension checks to loom.matrix_encoding' do
    catalog = [{ id: 'loom.matrix_encoding', label: 'Matrix encoding and dimension checks' }]
    valid_checks = [
      { field: 'dimensions', message: 'Matrix dimensions: 10 cells x 5 genes', status: 'passed' }
    ]
    errors = [
      { field: 'loom', message: 'Loom file missing /matrix dataset' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: errors,
      warnings: [],
      format: 'loom'
    )

    assert_equal 'loom.matrix_encoding', groups.first[:id]
    assert_equal 2, groups.first[:items].size
    assert_equal 'failed', groups.first[:items].find { |item| item[:field] == 'loom' }[:status]
  end

  test 'routes loom spatial embedding col_attrs to loom.embeddings' do
    catalog = [{ id: 'loom.embeddings', label: 'Loom embedding / coordinate checks' }]
    valid_checks = [
      { field: '/col_attrs/spatial', message: 'Spatial embedding present', status: 'passed' },
      { field: '/col_attrs/spatial#shape', message: '2D shape', status: 'passed' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'loom'
    )

    assert_equal 'loom.embeddings', groups.first[:id]
    assert_equal 2, groups.first[:items].size
  end

  test 'summarize_items counts grouped statuses like the report banner' do
    groups = [
      {
        id: 'obs.required_presence',
        items: [
          { field: 'obs/title', status: 'passed' },
          { field: 'obs/assay', status: 'skipped' },
          { field: 'obs/tissue', status: 'failed' }
        ]
      },
      {
        id: 'ontology.format',
        items: [
          { field: 'obs/organism', status: 'warning' },
          { field: 'obs/donor', status: 'passed' }
        ]
      }
    ]

    counts = Scfair::ComplianceReportGrouper.summarize_items(groups)

    assert_equal({ passed: 2, skipped: 1, failed: 1, warning: 1 }, counts)
  end
end
