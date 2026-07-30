# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairVarIndexValidatorTest < TestBaseWithoutFixtures
  SCHEMA_FIELD = Scfair::Rules.var_index_schema_field

  def validate(field_values, format: 'h5ad')
    Scfair::VarIndexValidator.new(field_values: field_values, format: format).call
  end

  test 'fails when var index series is missing' do
    result = validate({})

    assert_equal 1, result[:errors].size
    assert_equal SCHEMA_FIELD, result[:errors].first[:field]
    assert_match(/missing/i, result[:errors].first[:message])
    assert_match(%r{H5AD file: var/_index}, result[:errors].first[:message])
    refute_match(/var@_index/, result[:errors].first[:message])
  end

  test 'resolves var/_index storage path as var index' do
    result = validate({
      'var/_index#series' => %w[ENSG00000186092 ERCC-0003],
      'var/feature_biotype#series' => %w[gene spike-in]
    })

    assert_empty result[:errors]
    assert result[:valid_checks].any? { |c| c[:field] == SCHEMA_FIELD && c[:status] == 'passed' }
  end

  test 'fails on duplicate identifiers' do
    result = validate({
      'var/_index#series' => %w[ENSG00000186092 ENSG00000186092 ERCC-0001]
    })

    dup_check = result[:valid_checks].find { |c| c[:field] == 'var.index.uniqueness' }
    assert_equal 'failed', dup_check[:status]
  end

  test 'missing presence message points at loom Accession file path without logical @ path' do
    result = validate({}, format: 'loom')

    message = result[:errors].first[:message]
    assert_match(%r{Loom file: /row_attrs/Accession}, message)
    assert_match(/anndata_mapping var_index_key/, message)
    refute_match(%r{row_attrs@Accession}, message)
    refute_match(/see /, message)
  end

  test 'resolves loom Accession column as var index' do
    loom_path = Scfair::Rules.var_index_file_path('loom')
    result = validate(
      {
        "#{loom_path}#series" => %w[ENSG00000186092 ERCC-0001],
        '/row_attrs/feature_biotype#series' => %w[gene spike-in]
      },
      format: 'loom'
    )

    assert_equal '/row_attrs/Accession', loom_path
    assert_empty result[:errors]
    assert result[:valid_checks].any? { |c| c[:field] == SCHEMA_FIELD && c[:status] == 'passed' }
  end
end
