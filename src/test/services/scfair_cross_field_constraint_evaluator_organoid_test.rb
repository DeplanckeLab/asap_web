# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairCrossFieldConstraintEvaluatorOrganoidTest < TestBaseWithoutFixtures
  include ScfairSchemaRules

  test 'check_cross_field_constraints flags organoid with embryo tissue term' do
    violations = check_cross_field_constraints(
      tissue_type: 'organoid',
      tissue_term_id: 'UBERON:0000922',
      format: 'h5ad'
    )

    assert_equal 1, violations.size
    assert_equal 'obs/tissue_ontology_term_id', violations.first[:field]
    assert_includes violations.first[:message], 'UBERON:0000922'
    assert_equal :error, violations.first[:severity]
  end

  test 'check_cross_field_constraints ignores embryo term when tissue_type is not organoid' do
    violations = check_cross_field_constraints(
      tissue_type: 'tissue',
      tissue_term_id: 'UBERON:0000922',
      format: 'h5ad'
    )

    assert_empty violations
  end

  test 'CF-4 fails when organoid tissue is embryo' do
    result = Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/tissue_type' => ['organoid'],
        'obs/tissue_ontology_term_id' => ['UBERON:0000922']
      },
      format: 'h5ad'
    ).call

    cf4 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-4-organoid-tissue' }
    assert_equal 'failed', cf4[:status]
    assert_includes cf4[:message], 'embryo'
    assert result[:errors].any? { |entry| entry[:message].include?('UBERON:0000922') }
  end

  test 'CF-4 passes when organoid tissue is not embryo' do
    result = Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/tissue_type' => ['organoid'],
        'obs/tissue_ontology_term_id' => ['UBERON:0002048']
      },
      format: 'h5ad'
    ).call

    cf4 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-4-organoid-tissue' }
    assert_equal 'passed', cf4[:status]
    assert_empty result[:errors]
  end

  test 'CF-4 is skipped when tissue_type is not organoid' do
    result = Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/tissue_type' => ['tissue'],
        'obs/tissue_ontology_term_id' => ['UBERON:0000922']
      },
      format: 'h5ad'
    ).call

    cf4 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-4-organoid-tissue' }
    assert_equal 'skipped', cf4[:status]
    assert_equal 'Not applicable', cf4[:message]
  end
end
