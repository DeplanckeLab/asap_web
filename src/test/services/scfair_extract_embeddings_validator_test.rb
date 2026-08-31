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

  test 'allows one-column non-X_obsm arrays per general obsm rule' do
    result = Scfair::ExtractEmbeddingsValidator.new(
      extract: {
        'file_inventory' => { 'matrix' => { 'n_obs' => 7348 } },
        'obsm' => {
          'X_umap' => { 'shape' => [7348, 2], 'has_inf' => false },
          'cluster_memberships' => { 'shape' => [7348, 1], 'has_inf' => false }
        }
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    passed = result[:valid_checks].find { |entry| entry[:field] == 'obsm' }
    assert_equal 'passed', passed[:status]
  end

  test 'still requires at least two columns for X_ embeddings' do
    result = Scfair::ExtractEmbeddingsValidator.new(
      extract: {
        'file_inventory' => { 'matrix' => { 'n_obs' => 10 } },
        'obsm' => {
          'X_umap' => { 'shape' => [10, 1], 'has_inf' => false }
        }
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == 'obsm/X_umap' }
    assert_includes result[:errors].first[:message], 'X_* embedding'
    assert_includes result[:errors].first[:message], '2 columns'
  end
end
