# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairExtractEmbeddingsValidatorTest < TestBaseWithoutFixtures
  test 'does not warn when no embeddings are present' do
    result = Scfair::ExtractEmbeddingsValidator.new(
      extract: {
        'file_inventory' => { 'matrix' => { 'n_obs' => 100 } },
        'obsm' => nil,
        'col_embeddings' => nil
      },
      format: 'loom'
    ).call

    assert_empty result[:warnings]
    skipped = result[:valid_checks].find { |entry| entry[:field] == 'loom.embeddings' }
    assert_equal 'skipped', skipped[:status]
    assert_includes skipped[:message], 'optional'
  end

  test 'passes when embeddings are present' do
    result = Scfair::ExtractEmbeddingsValidator.new(
      extract: {
        'file_inventory' => { 'matrix' => { 'n_obs' => 2 } },
        'col_embeddings' => {
          '/col_attrs/spatial' => { 'shape' => [2, 2], 'has_inf' => false }
        }
      },
      format: 'loom'
    ).call

    assert_empty result[:warnings]
    passed = result[:valid_checks].find { |entry| entry[:field] == 'loom.embeddings' }
    assert_equal 'passed', passed[:status]
  end
end
