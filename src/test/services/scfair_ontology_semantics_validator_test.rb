# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairOntologySemanticsValidatorTest < TestBaseWithoutFixtures
  test 'emits semantic subchecks without aggregate field checks' do
    field_values = { 'obs/cell_type_ontology_term_id' => ['CL:0000001'] }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['CL:0000001']
    resolver.expect :descendant_of?, true, ['CL:0000001', 'CL:0000000']

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
      fields = result[:valid_checks].map { |check| check[:field] }

      refute_includes fields, 'ontology.semantics'
      refute_includes fields, 'ontology.semantics.cell_type_ontology_term_id'
      assert_includes fields, 'ontology.semantics.cell_type_ontology_term_id.allowed_terms'
      assert_includes fields, 'ontology.semantics.cell_type_ontology_term_id.banned_terms'
      assert_includes fields, 'ontology.semantics.cell_type_ontology_term_id.descendants'
      assert_includes fields, 'ontology.semantics.cell_type_ontology_term_id.special_values'
    end

    resolver.verify
  end

  test 'skips banned and descendant subchecks when rules do not define them' do
    field_values = { 'obs/disease_ontology_term_id' => ['MONDO:0000001'] }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['MONDO:0000001']
    resolver.expect :descendant_of?, true, ['MONDO:0000001', 'MONDO:0000001']
    resolver.expect :descendant_of?, true, ['MONDO:0000001', 'MONDO:0021178']

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
      fields = result[:valid_checks].map { |check| check[:field] }

      assert_includes fields, 'ontology.semantics.disease_ontology_term_id.allowed_terms'
      assert_includes fields, 'ontology.semantics.disease_ontology_term_id.descendants'
      refute fields.any? { |field| field.end_with?('.banned_terms') && field.include?('disease_ontology_term_id') }
    end

    resolver.verify
  end

  test 'skips descendant checks for cellosaurus tissue terms' do
    field_values = { 'obs/tissue_ontology_term_id' => ['CVCL_0123'] }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['CVCL_0123']

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
      refute result[:errors].any? { |entry| entry[:message].to_s.include?('must be under') }
      descendants = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.tissue_ontology_term_id.descendants' }
      assert_equal 'passed', descendants[:status]
    end

    resolver.verify
  end
end
