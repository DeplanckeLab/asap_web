# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairExperimentalConditionValidatorTest < TestBaseWithoutFixtures
  test 'passes when experimental condition columns are absent' do
    result = Scfair::ExperimentalConditionValidator.new(
      field_values: {
        'metadata/obs/columns' => %w[assay tissue_type donor_id]
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    presence = result[:valid_checks].find { |entry| entry[:field] == 'obs/experimental_condition' }
    assert_equal 'passed', presence[:status]
  end

  test 'fails when id column is present but all values are na' do
    result = Scfair::ExperimentalConditionValidator.new(
      field_values: {
        'metadata/obs/columns' => %w[experimental_condition_ontology_term_id],
        'obs/experimental_condition_ontology_term_id' => %w[na na]
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('MUST NOT be present') }
  end

  test 'requires label and perturbation_types when id column is present' do
    result = Scfair::ExperimentalConditionValidator.new(
      field_values: {
        'metadata/obs/columns' => %w[experimental_condition_ontology_term_id],
        'obs/experimental_condition_ontology_term_id' => ['CHEBI:16412']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('experimental_condition is required') }
    assert result[:errors].any? { |entry| entry[:message].include?('perturbation_types is required') }
  end

  test 'passes with id label and perturbation_types' do
    result = Scfair::ExperimentalConditionValidator.new(
      field_values: {
        'metadata/obs/columns' => %w[
          experimental_condition_ontology_term_id
          experimental_condition
          perturbation_types
        ],
        'obs/experimental_condition_ontology_term_id' => ['CHEBI:16412'],
        'obs/experimental_condition' => ['lipopolysaccharide'],
        'obs/perturbation_types' => ['chemical']
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert_equal 'passed', result[:valid_checks].find { |entry| entry[:field] == 'obs/experimental_condition' }[:status]
  end

  test 'requires perturbation_types when genetic_perturbation_id is present' do
    result = Scfair::ExperimentalConditionValidator.new(
      field_values: {
        'metadata/obs/columns' => %w[genetic_perturbation_id],
        'obs/genetic_perturbation_id' => ['perturb-1']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('perturbation_types is required') }
  end
end
