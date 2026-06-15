# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairUnsEnsemblValidatorTest < TestBaseWithoutFixtures
  test 'passes when release and database are valid' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        'uns/ensembl_release' => ['115'],
        'uns/ensembl_database' => ['Ensembl']
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    release = result[:valid_checks].find { |entry| entry[:field] == 'uns.ensembl.release' }
    database = result[:valid_checks].find { |entry| entry[:field] == 'uns.ensembl.database' }
    assert_equal 'passed', release[:status]
    assert_equal 'passed', database[:status]
  end

  test 'fails on metadata path when ensembl_release is missing' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        'metadata/uns/columns' => %w[title schema_version ensembl_release ensembl_database],
        'uns/ensembl_release' => []
      },
      format: 'h5ad'
    ).call

    check = result[:valid_checks].find { |entry| entry[:field] == 'uns/ensembl_release' }
    assert_equal 'failed', check[:status]
    assert_equal 'Missing uns/ensembl_release metadata (required by schema)', check[:message]
    refute result[:valid_checks].any? { |entry| entry[:field] == 'uns.ensembl.release' }
  end

  test 'defers missing ensembl_release to base validator when column absent' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        'metadata/uns/columns' => %w[title schema_version]
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    refute result[:valid_checks].any? { |entry| entry[:field] == 'uns/ensembl_release' }
  end

  test 'fails when ensembl_release is not an integer' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        'uns/ensembl_release' => ['r115'],
        'uns/ensembl_database' => ['Ensembl']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('integer') }
    assert_equal 'failed', result[:valid_checks].find { |entry| entry[:field] == 'uns.ensembl.release' }[:status]
  end

  test 'fails when ensembl_database is not allowed' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        'uns/ensembl_release' => ['110'],
        'uns/ensembl_database' => ['OtherDB']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('ensembl_database') }
  end

  test 'skips assembly when not present' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        'uns/ensembl_release' => ['110'],
        'uns/ensembl_database' => ['EnsemblMetazoa']
      },
      format: 'h5ad'
    ).call

    assembly = result[:valid_checks].find { |entry| entry[:field] == 'uns/ensembl_assembly' }
    assert_equal 'skipped', assembly[:status]
  end

  test 'fails when ensembl_assembly is present but empty' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        'metadata/uns/columns' => %w[ensembl_assembly ensembl_release ensembl_database],
        'uns/ensembl_release' => ['110'],
        'uns/ensembl_database' => ['Ensembl'],
        'uns/ensembl_assembly' => []
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('ensembl_assembly') }
  end

  test 'uses loom field paths' do
    result = Scfair::UnsEnsemblValidator.new(
      field_values: {
        '/attrs/ensembl_release' => ['99'],
        '/attrs/ensembl_database' => ['EnsemblCOVID-19']
      },
      format: 'loom'
    ).call

    assert_empty result[:errors]
    assert_equal 'passed', result[:valid_checks].find { |entry| entry[:field] == 'uns.ensembl.database' }[:status]
  end
end
