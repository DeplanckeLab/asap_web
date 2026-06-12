# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairUnsEnsemblAssemblyValidatorTest < TestBaseWithoutFixtures
  test 'skips when ensembl_assembly is not present' do
    result = Scfair::UnsEnsemblAssemblyValidator.new(
      field_values: { 'metadata/uns/columns' => %w[title schema_version] },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert_equal 'skipped', result[:valid_checks].first[:status]
  end

  test 'passes when ensembl_assembly has a non-empty value' do
    result = Scfair::UnsEnsemblAssemblyValidator.new(
      field_values: {
        'metadata/uns/columns' => %w[ensembl_assembly],
        'uns/ensembl_assembly' => ['GRCh38.p14']
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert_equal 'passed', result[:valid_checks].first[:status]
    assert_match(/GRCh38\.p14/, result[:valid_checks].first[:message])
  end

  test 'fails when ensembl_assembly key is present but empty' do
    result = Scfair::UnsEnsemblAssemblyValidator.new(
      field_values: {
        'metadata/uns/columns' => %w[ensembl_assembly],
        'uns/ensembl_assembly' => []
      },
      format: 'h5ad'
    ).call

    assert_equal 1, result[:errors].size
    assert_equal 'failed', result[:valid_checks].first[:status]
    assert_match(/must not be empty/, result[:errors].first[:message])
  end

  test 'uses loom field path' do
    result = Scfair::UnsEnsemblAssemblyValidator.new(
      field_values: {
        'metadata/uns/columns' => %w[ensembl_assembly],
        '/attrs/ensembl_assembly' => ['GRCz11']
      },
      format: 'loom'
    ).call

    assert_equal '/attrs/ensembl_assembly', result[:valid_checks].first[:field]
    assert_equal 'passed', result[:valid_checks].first[:status]
  end
end
