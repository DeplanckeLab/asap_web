# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairCrossFieldConstraintEvaluatorCellLineTest < TestBaseWithoutFixtures
  def cell_line_result(overrides = {})
    Scfair::CrossFieldConstraintEvaluator.new(
      field_values: {
        'obs/tissue_type' => ['cell line'],
        'obs/assay_ontology_term_id' => ['EFO:0009899'],
        'obs/suspension_type' => ['nucleus'],
        'obs/development_stage_ontology_term_id' => ['na'],
        'obs/cell_type_ontology_term_id' => ['CL:0000540'],
        'obs/tissue_ontology_term_id' => ['CVCL_0031'],
        'obs/self_reported_ethnicity_ontology_term_id' => ['na'],
        'obs/sex_ontology_term_id' => ['na'],
        'obs/donor_id' => ['na']
      }.merge(overrides),
      format: 'h5ad'
    ).call
  end

  test 'reports each failed cell-line rule once with the detailed violation message' do
    result = cell_line_result(
      'obs/development_stage_ontology_term_id' => ['unknown'],
      'obs/cell_type_ontology_term_id' => ['CL:0000010']
    )
    error_fields = result[:errors].map { |entry| entry[:field] }

    assert_includes error_fields, 'cross-field.CF-2c-cell-line-development-stage'
    refute error_fields.any? { |field| field.include?('CF-2e') }
    refute error_fields.any? { |field| field.include?('CF-7') }
    refute error_fields.any? { |field| field.include?('obs/') }

    assert_equal 1, error_fields.count('cross-field.CF-2c-cell-line-development-stage')

    dev = result[:errors].find { |entry| entry[:field] == 'cross-field.CF-2c-cell-line-development-stage' }
    assert_includes dev[:message], 'MUST be "na"'
    assert_includes dev[:message], 'got "unknown"'
  end

  test 'accepts na for cell-line development_stage_ontology_term_id' do
    result = cell_line_result(
      'obs/development_stage_ontology_term_id' => ['na'],
      'obs/cell_type_ontology_term_id' => ['CL:0000010']
    )

    refute result[:errors].any? { |entry| entry[:field] == 'cross-field.CF-2c-cell-line-development-stage' }
    cf2c = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-2c-cell-line-development-stage' }
    assert_equal 'passed', cf2c[:status]
  end

  test 'does not force suspension_type to na for cell lines' do
    result = cell_line_result('obs/suspension_type' => ['nucleus'])

    refute result[:errors].any? { |entry| entry[:field].to_s.include?('CF-2e') }
    refute result[:valid_checks].any? { |check| check[:field].to_s.include?('CF-2e') }

    cf1 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-1-assay-suspension' }
    assert_equal 'passed', cf1[:status]
    refute result[:errors].any? { |entry| entry[:field] == 'cross-field.CF-1-assay-suspension' }
  end

  test 'does not force cell_type_ontology_term_id to na or unknown for cell lines' do
    result = cell_line_result('obs/cell_type_ontology_term_id' => ['CL:0000010'])

    refute result[:errors].any? { |entry| entry[:field].to_s.include?('CF-7') }
    refute result[:valid_checks].any? { |check| check[:field].to_s.include?('CF-7') }
  end

  test 'CF-1 still fails when the assay does not allow the suspension_type' do
    result = cell_line_result(
      'obs/assay_ontology_term_id' => ['EFO:0008992'],
      'obs/suspension_type' => ['nucleus']
    )

    cf1 = result[:valid_checks].find { |check| check[:field] == 'cross-field.CF-1-assay-suspension' }
    assert_equal 'failed', cf1[:status]
    cf1_error = result[:errors].find { |entry| entry[:field] == 'cross-field.CF-1-assay-suspension' }
    assert cf1_error
    assert_includes cf1_error[:message], 'EFO:0008992'
  end
end
