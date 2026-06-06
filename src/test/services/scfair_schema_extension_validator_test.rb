# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairSchemaExtensionValidatorTest < TestBaseWithoutFixtures
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
end
