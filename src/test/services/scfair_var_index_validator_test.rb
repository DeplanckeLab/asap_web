# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairVarIndexValidatorTest < TestBaseWithoutFixtures
  SCHEMA_FIELD = Scfair::Rules.var_index_schema_field
  LOGICAL_PATH = Scfair::Rules.var_index_logical_path('h5ad')

  def validate(field_values, format: 'h5ad')
    Scfair::VarIndexValidator.new(field_values: field_values, format: format).call
  end

  test 'fails when var index series is missing' do
    result = validate({})

    assert_equal 1, result[:errors].size
    assert_equal SCHEMA_FIELD, result[:errors].first[:field]
    assert_match(/missing/i, result[:errors].first[:message])
    assert_match(/var@_index/, result[:errors].first[:message])
    assert_match(/var\/_index/, result[:errors].first[:message])
  end

  test 'resolves var@_index logical path' do
    result = validate({
      "#{LOGICAL_PATH}#series" => %w[ENSG00000186092 ERCC-0003],
      'var/feature_biotype#series' => %w[gene spike-in]
    })

    assert_empty result[:errors]
    assert result[:valid_checks].any? { |c| c[:field] == SCHEMA_FIELD && c[:status] == 'passed' }
  end

  test 'resolves legacy var/_index storage path' do
    result = validate({
      'var/_index#series' => %w[ENSG00000186092 ERCC-0003]
    })

    assert_empty result[:errors]
    assert result[:valid_checks].any? { |c| c[:field] == SCHEMA_FIELD && c[:status] == 'passed' }
  end

  test 'fails on duplicate identifiers' do
    result = validate({
      "#{LOGICAL_PATH}#series" => %w[ENSG00000186092 ENSG00000186092 ERCC-0001]
    })

    dup_check = result[:valid_checks].find { |c| c[:field] == 'var.index.uniqueness' }
    assert_equal 'failed', dup_check[:status]
  end

  test 'resolves loom feature_id column as var index' do
    loom_logical = Scfair::Rules.var_index_logical_path('loom')
    result = validate(
      {
        "#{loom_logical}#series" => %w[ENSG00000186092 ERCC-0001],
        '/row_attrs/feature_biotype#series' => %w[gene spike-in]
      },
      format: 'loom'
    )

    assert_empty result[:errors]
    assert result[:valid_checks].any? { |c| c[:field] == SCHEMA_FIELD && c[:status] == 'passed' }
  end
end
