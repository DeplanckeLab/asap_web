# frozen_string_literal: true

require_relative 'test_base_without_fixtures'
require_relative 'spatial_test_helpers'

class ScfairSchemaExtensionValidatorTest < TestBaseWithoutFixtures
  include SpatialTestHelpers

  test 'records extension warnings in warnings list and valid_checks' do
    field_values = {
      'obs/assay_ontology_term_id' => ['EFO:0030059']
    }

    result = Scfair::SchemaExtensionValidator.new(field_values: field_values, format: 'h5ad').call

    assert_equal 2, result[:warnings].size
    assert result[:warnings].any? { |entry| entry[:field] == 'extension.atac' }
    assert result[:warnings].any? { |entry| entry[:field] == 'extension.analysis_json' }
    assert_equal 2, result[:valid_checks].count { |entry| entry[:status] == 'warning' }
  end

  test 'skips spatial extension when no spatial metadata or assay is present' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0009899'] },
      format: 'h5ad'
    ).call

    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'skipped', spatial[:status]
  end

  test 'requires spatial is_single for spatial assays' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0022857'] },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field].start_with?('extension.spatial') }
    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'failed', spatial[:status]
  end

  test 'requires visium obs fields only when spatial is_single is true' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['true']
      },
      format: 'h5ad'
    ).call

    message = result[:errors].find { |entry| entry[:field] == 'extension.spatial.obs' }[:message]
    assert_includes message, 'obs/array_row'
    assert_includes message, 'obs/array_col'
    assert_includes message, 'obs/in_tissue'
  end

  test 'does not require visium obs fields when spatial is_single is false' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['false']
      },
      format: 'h5ad'
    ).call

    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'passed', spatial[:status]
  end

  test 'detects spatial extension from flattened loom metadata' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: visium_spatial_field_values(format: 'loom'),
      format: 'loom'
    ).call

    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'passed', spatial[:status]
  end
end
