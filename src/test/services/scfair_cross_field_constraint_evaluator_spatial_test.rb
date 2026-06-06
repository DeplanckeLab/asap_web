# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairCrossFieldConstraintEvaluatorSpatialTest < TestBaseWithoutFixtures
  test 'CF-6 fails when spatial is_single is false and is_primary_data is true' do
    result = Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['false'],
        'obs/is_primary_data' => ['true']
      },
      format: 'h5ad'
    ).call

    cf6 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-6-spatial-primary-data' }
    assert_equal 'failed', cf6[:status]
  end

  test 'CF-9 is skipped unless spatial is_single is true' do
    result = Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['false'],
        'obs/in_tissue' => ['0'],
        'obs/cell_type_ontology_term_id' => ['CL:0000540']
      },
      format: 'h5ad'
    ).call

    cf9 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-9-visium-in-tissue' }
    assert_equal 'skipped', cf9[:status]
    assert_match(/spatial\.is_single=true/, cf9[:message])
  end

  test 'CF-9 passes when all spots are out of tissue and cell type is unknown' do
    result = Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['true'],
        'obs/in_tissue' => ['0'],
        'obs/cell_type_ontology_term_id' => ['unknown']
      },
      format: 'h5ad'
    ).call

    cf9 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-9-visium-in-tissue' }
    assert_equal 'passed', cf9[:status]
  end

  test 'CF-5 fails when spatial and non-spatial assays are mixed' do
    result = Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857', 'EFO:0009899']
      },
      format: 'h5ad'
    ).call

    cf5 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-5-spatial-assay-uniformity' }
    assert_equal 'failed', cf5[:status]
  end
end
