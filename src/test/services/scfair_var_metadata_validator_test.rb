# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairVarMetadataValidatorTest < TestBaseWithoutFixtures
  REQUIRED_COLUMNS = %w[
    feature_is_filtered
    feature_biotype
    feature_length
    feature_name
    feature_reference
    feature_type
    feature_chromosome
  ].freeze

  test 'fails when required var columns are missing' do
    result = Scfair::VarMetadataValidator.new(
      field_values: {
        'metadata/var/columns' => %w[feature_name]
      },
      format: 'h5ad'
    ).call

    chromosome = result[:valid_checks].find { |entry| entry[:field] == 'var/feature_chromosome' }
    assert_equal 'failed', chromosome[:status]
    assert_equal 'Missing var/feature_chromosome metadata (required by schema)', chromosome[:message]

    feature_name = result[:valid_checks].find { |entry| entry[:field] == 'var/feature_name' }
    assert_equal 'passed', feature_name[:status]
    refute result[:valid_checks].any? { |entry| entry[:field] == 'var.required.presence' }
  end

  test 'passes when all required columns are present with valid values' do
    result = Scfair::VarMetadataValidator.new(
      field_values: {
        'metadata/var/columns' => REQUIRED_COLUMNS,
        'var/feature_is_filtered' => %w[false],
        'var/feature_biotype' => %w[gene],
        'var/feature_length' => %w[1200],
        'var/feature_name' => %w[GENE1],
        'var/feature_reference' => %w[NCBITaxon:9606],
        'var/feature_type' => %w[protein_coding],
        'var/feature_chromosome' => %w[1]
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    REQUIRED_COLUMNS.each do |column|
      check = result[:valid_checks].find { |entry| entry[:field] == "var/#{column}" }
      assert_equal 'passed', check[:status], "expected var/#{column} to pass"
    end
  end

  test 'fails on invalid feature_biotype' do
    result = Scfair::VarMetadataValidator.new(
      field_values: {
        'metadata/var/columns' => REQUIRED_COLUMNS,
        'var/feature_biotype' => %w[unknown]
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('feature_biotype') }
  end

  test 'uses loom row_attrs paths' do
    result = Scfair::VarMetadataValidator.new(
      field_values: {
        'metadata/var/columns' => REQUIRED_COLUMNS,
        '/row_attrs/feature_biotype' => %w[spike-in],
        '/row_attrs/feature_is_filtered' => %w[false],
        '/row_attrs/feature_length' => %w[500],
        '/row_attrs/feature_name' => %w[ERCC-00003 (spike-in control)],
        '/row_attrs/feature_reference' => %w[NCBITaxon:32630],
        '/row_attrs/feature_type' => %w[synthetic],
        '/row_attrs/feature_chromosome' => %w[na]
      },
      format: 'loom'
    ).call

    assert_empty result[:errors]
  end
end
