# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairSchemaVersionEvaluatorTest < TestBaseWithoutFixtures
  EXPECTED = '7.1.0+scfair1.0'

  test 'passes when file version matches required identifier' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: EXPECTED,
      expected_identifier: EXPECTED,
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert_equal 1, result[:valid_checks].size
    assert_equal 'passed', result[:valid_checks].first[:status]
    assert_match(/schema_version matches the required identifier \(7\.1\.0\+scfair1\.0\)/, result[:valid_checks].first[:message])
  end

  test 'warns when file version is CELLxGENE numeric schema version' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: '7.1.0',
      expected_identifier: EXPECTED,
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_equal 1, result[:warnings].size
    assert_equal 'warning', result[:valid_checks].first[:status]
    assert_match(/schema_version "7\.1\.0" does not match the required identifier "7\.1\.0\+scfair1\.0"/, result[:warnings].first[:message])
  end

  test 'warns when file version uses legacy underscore identifier' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: '7.1.0_scfair',
      expected_identifier: EXPECTED,
      format: 'loom'
    )

    assert_empty result[:errors]
    assert_equal 1, result[:warnings].size
    assert_match(/schema_version "7\.1\.0_scfair" does not match the required identifier "7\.1\.0\+scfair1\.0"/, result[:warnings].first[:message])
  end

  test 'warns when major version is lower' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: '5.2.0',
      expected_identifier: EXPECTED,
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_equal 1, result[:warnings].size
    assert_equal 'warning', result[:valid_checks].first[:status]
  end

  test 'returns nothing when schema_version is missing' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: nil,
      expected_identifier: EXPECTED,
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert_empty result[:valid_checks]
  end
end
