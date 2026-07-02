# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRollupDeduplicationTest < TestBaseWithoutFixtures
  test 'reconcile removes metadata path errors when experimental condition rollup already failed' do
    service = Scfair::ComplianceValidationCore.allocate
    message = 'experimental_condition is required when experimental_condition_ontology_term_id is present'
    errors = [
      { field: 'obs/experimental_condition', message: message },
      { field: 'obs.experimental_condition.label', message: message }
    ]
    valid_checks = [
      { field: 'obs.experimental_condition.label', status: 'failed', message: message }
    ]

    cleaned_errors, cleaned_checks, _warnings = service.send(
      :reconcile_rollup_metadata_checks,
      errors,
      valid_checks,
      [],
      'h5ad'
    )

    assert_equal 1, cleaned_errors.size
    assert_equal 'obs.experimental_condition.label', cleaned_errors.first[:field]
    refute cleaned_checks.any? { |entry| entry[:field] == 'obs/experimental_condition' }
    refute cleaned_errors.any? { |entry| entry[:field] == 'obs/experimental_condition' }
  end

  test 'mirror adds per-field var checks from errors when not already recorded' do
    service = Scfair::ComplianceValidationCore.allocate
    errors = [{ field: 'var/feature_chromosome', message: 'Missing var/feature_chromosome metadata (required by schema)' }]
    valid_checks = []

    mirrored = service.send(:mirror_metadata_field_checks, valid_checks, errors, [], 'h5ad')

    assert mirrored.any? { |entry| entry[:field] == 'var/feature_chromosome' && entry[:status] == 'failed' }
  end

  test 'suppresses spatial rollup summaries when specific child errors exist' do
    service = Scfair::ComplianceValidationCore.allocate
    errors = [
      {
        field: 'extension.spatial.images.hires',
        message: 'uns/spatial/sample/images/hires channel dimension must be one of 3 or 4, got 1820'
      },
      { field: 'extension.spatial', message: 'Spatial schema checks failed' },
      { field: 'extension.spatial.assets', message: 'Spatial image and embedding checks failed' }
    ]
    warnings = []
    valid_checks = [
      { field: 'extension.spatial', status: 'failed', message: 'Spatial schema checks failed' },
      { field: 'extension.spatial.assets', status: 'failed', message: 'Spatial image and embedding checks failed' }
    ]

    cleaned_errors, cleaned_warnings, cleaned_checks = service.send(
      :suppress_rollup_summary_issues,
      errors,
      warnings,
      valid_checks
    )

    assert_equal 1, cleaned_errors.size
    assert_equal 'extension.spatial.images.hires', cleaned_errors.first[:field]
    refute cleaned_errors.any? { |entry| entry[:field] == 'extension.spatial' }
    refute cleaned_errors.any? { |entry| entry[:field] == 'extension.spatial.assets' }
    refute cleaned_checks.any? { |entry| entry[:field] == 'extension.spatial' }
    refute cleaned_checks.any? { |entry| entry[:field] == 'extension.spatial.assets' }
    assert_empty cleaned_warnings
  end

  test 'keeps rollup summary when it is the only failure' do
    service = Scfair::ComplianceValidationCore.allocate
    errors = [{ field: 'extension.spatial.structure', message: 'Spatial uns structure checks failed' }]
    warnings = []
    valid_checks = [
      { field: 'extension.spatial.structure', status: 'failed', message: 'Spatial uns structure checks failed' }
    ]

    cleaned_errors, = service.send(:suppress_rollup_summary_issues, errors, warnings, valid_checks)

    assert_equal 1, cleaned_errors.size
    assert_equal 'extension.spatial.structure', cleaned_errors.first[:field]
  end

  test 'suppresses generic ontology semantics subcheck when specific sibling error exists' do
    service = Scfair::ComplianceValidationCore.allocate
    errors = [
      {
        field: 'ontology.semantics.cell_type_ontology_term_id.ordering',
        message: 'cell_type_ontology_term_id values must be unique and sorted lexically with \' || \' separator — "CL:0000540 || CL:0000136": not sorted lexically (expected CL:0000136 || CL:0000540)'
      },
      {
        field: 'ontology.semantics.cell_type_ontology_term_id.sorted_multi',
        message: 'Multi-value ordering/uniqueness failed — "CL:0000540 || CL:0000136": not sorted lexically (expected CL:0000136 || CL:0000540)'
      }
    ]

    cleaned_errors, = service.send(:suppress_rollup_summary_issues, errors, [], [])

    assert_equal 1, cleaned_errors.size
    assert_equal 'ontology.semantics.cell_type_ontology_term_id.ordering', cleaned_errors.first[:field]
  end
end
