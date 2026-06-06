# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairSchemaVersionEvaluatorTest < TestBaseWithoutFixtures
  test 'passes when file version matches reference' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: '7.1.0_scfair',
      reference_version: '7.1.0',
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert_equal 1, result[:valid_checks].size
    assert_match(/schema_version \(7\.1\.0_scfair\) is compatible with reference 7\.1\.0/, result[:valid_checks].first[:message])
  end

  test 'warns when major and minor match but patch is lower' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: '7.1.0',
      reference_version: '7.1.2',
      format: 'loom'
    )

    assert_empty result[:errors]
    assert_equal 1, result[:warnings].size
    assert_match(/patch 7\.1\.0 \(7\.1\.0\) is lower than reference 7\.1\.2 \(7\.1\.2\)/, result[:warnings].first[:message])
  end

  test 'errors when minor version is lower' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: '7.0.5',
      reference_version: '7.1.0',
      format: 'h5ad'
    )

    assert_equal 1, result[:errors].size
    assert_match(/minor version 7\.0 \(7\.0\.5\) is lower than required 7\.1 \(7\.1\.0\)/, result[:errors].first[:message])
    assert_empty result[:warnings]
  end

  test 'errors when major version is lower' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: '6.1.0',
      reference_version: '7.1.0',
      format: 'loom'
    )

    assert_equal 1, result[:errors].size
    assert_match(/major version 6 \(6\.1\.0\) is lower than required 7 \(7\.1\.0\)/, result[:errors].first[:message])
  end

  test 'returns nothing when schema_version is missing' do
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: nil,
      reference_version: '7.1.0',
      format: 'h5ad'
    )

    assert_empty result[:errors]
    assert_empty result[:warnings]
    assert_empty result[:valid_checks]
  end
end
