# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairExtractOntologyFormatValidatorTest < TestBaseWithoutFixtures
  test 'reports unexpected ontology prefix as error for loom tissue field' do
    result = Scfair::ExtractOntologyFormatValidator.new(
      field_values: {
        '/col_attrs/tissue_ontology_term_id' => ['AEO:0000001']
      },
      format: 'loom'
    ).call

    assert_empty result[:warnings]
    assert result[:errors].any? { |entry| entry[:code] == 'unexpected_prefix' }
    assert result[:errors].any? { |entry| entry[:message].include?("Unexpected ontology prefix 'AEO'") }
  end

  test 'reports unexpected ontology prefix as error for h5ad tissue field' do
    result = Scfair::ExtractOntologyFormatValidator.new(
      field_values: {
        'obs/tissue_ontology_term_id' => ['AEO:0000001']
      },
      format: 'h5ad'
    ).call

    assert_empty result[:warnings]
    assert result[:errors].any? { |entry| entry[:code] == 'unexpected_prefix' }
  end

  test 'passes allowed tissue ontology prefix' do
    result = Scfair::ExtractOntologyFormatValidator.new(
      field_values: {
        'obs/tissue_ontology_term_id' => ['UBERON:0002048']
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert result[:valid_checks].any? { |entry| entry[:status] == 'passed' }
  end

  test 'passes Cellosaurus tissue ontology term for loom' do
    result = Scfair::ExtractOntologyFormatValidator.new(
      field_values: {
        '/col_attrs/tissue_ontology_term_id' => ['CVCL_0031']
      },
      format: 'loom'
    ).call

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert result[:valid_checks].any? { |entry| entry[:status] == 'passed' }
  end

  test 'passes CL tissue ontology term when tissue_type is primary cell culture' do
    result = Scfair::ExtractOntologyFormatValidator.new(
      field_values: {
        'obs/tissue_type' => ['primary cell culture'],
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'obs/tissue_ontology_term_id' => ['CL:0000084']
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert result[:valid_checks].any? { |entry| entry[:field] == 'obs/tissue_ontology_term_id' && entry[:status] == 'passed' }
  end

  test 'cell line tissue_type only allows Cellosaurus prefix' do
    result = Scfair::ExtractOntologyFormatValidator.new(
      field_values: {
        'obs/tissue_type' => ['cell line'],
        'obs/tissue_ontology_term_id' => ['UBERON:0002048']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:code] == 'unexpected_prefix' }
  end
end
