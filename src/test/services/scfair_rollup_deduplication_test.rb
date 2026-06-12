# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRollupDeduplicationTest < TestBaseWithoutFixtures
  test 'reconcile removes metadata path errors when experimental condition rollup already failed' do
    service = ScfairComplianceService.allocate
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
    service = ScfairComplianceService.allocate
    errors = [{ field: 'var/feature_chromosome', message: 'Missing required variable metadata field' }]
    valid_checks = []

    mirrored = service.send(:mirror_metadata_field_checks, valid_checks, errors, [], 'h5ad')

    assert mirrored.any? { |entry| entry[:field] == 'var/feature_chromosome' && entry[:status] == 'failed' }
  end
end
