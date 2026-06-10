# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairSchemaReferenceEvaluatorTest < TestBaseWithoutFixtures
  REFERENCE_URL = 'https://github.com/scFAIR/scFAIR/blob/main/schema/7.1.0/schema.md'

  test 'passes when schema_reference matches the reference schema URL' do
    result = Scfair::SchemaReferenceEvaluator.call(
      file_reference: REFERENCE_URL,
      reference_url: REFERENCE_URL,
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert_equal 'passed', result[:valid_checks].first[:status]
    assert_equal 'uns/schema_reference', result[:valid_checks].first[:field]
  end

  test 'warns when schema_reference does not match the reference schema URL' do
    wrong_url = 'https://github.com/scFAIR/scFAIR/edit/main/schema/7.1.0/schema.md'
    result = Scfair::SchemaReferenceEvaluator.call(
      file_reference: wrong_url,
      reference_url: REFERENCE_URL,
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_equal 1, result[:warnings].size
    assert_equal 'warning', result[:valid_checks].first[:status]
    assert_match(/does not match the reference schema URL/, result[:warnings].first[:message])
  end

  test 'uses loom field path for loom format' do
    result = Scfair::SchemaReferenceEvaluator.call(
      file_reference: REFERENCE_URL,
      reference_url: REFERENCE_URL,
      format: 'loom'
    )

    assert_equal '/attrs/schema_reference', result[:valid_checks].first[:field]
  end

  test 'returns nothing when schema_reference is missing' do
    result = Scfair::SchemaReferenceEvaluator.call(
      file_reference: nil,
      reference_url: REFERENCE_URL,
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert_empty result[:valid_checks]
  end
end
