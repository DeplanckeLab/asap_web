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

  test 'does not split extracted label pair tokens on the pair separator' do
    field_values = {
      'obs/cell_type_ontology_term_id' => %w[CL:0000037 CL:0008065],
      'obs/cell_type' => ['GABAergic neuron', 'hematopoietic stem cell'],
      'obs/cell_type_ontology_term_id#label_pairs' => [
        'CL:0000037 || hematopoietic stem cell',
        'CL:0008065 || GABAergic neuron'
      ]
    }
    resolver = Object.new
    resolver.define_singleton_method(:exists?) { |_id| true }
    resolver.define_singleton_method(:descendant_of?) { |_id, _root| true }

    term1 = Struct.new(:name).new('hematopoietic stem cell')
    term2 = Struct.new(:name).new('GABAergic neuron')
    lookup = {
      'CL:0000037' => term1,
      'CL:0008065' => term2
    }

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      CellOntologyTerm.stub(:find_by, ->(identifier:, original:) { lookup[identifier] }) do
        result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call

        refute result[:errors].any? { |entry| entry[:field].to_s.include?('label_pair') }
      end
    end
  end

  test 'validates label pairs from row-aligned extraction not sorted unique lists' do
    field_values = {
      'obs/cell_type_ontology_term_id' => %w[CL:0000037 CL:0008065],
      'obs/cell_type' => ['GABAergic neuron', 'hematopoietic stem cell'],
      'obs/cell_type_ontology_term_id#label_pairs' => [
        'CL:0000037 || hematopoietic stem cell',
        'CL:0008065 || GABAergic neuron'
      ]
    }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['CL:0000037']
    resolver.expect :exists?, true, ['CL:0008065']
    resolver.expect :descendant_of?, true, ['CL:0000037', 'CL:0000000']
    resolver.expect :descendant_of?, true, ['CL:0008065', 'CL:0000000']

    term1 = Struct.new(:name).new('hematopoietic stem cell')
    term2 = Struct.new(:name).new('GABAergic neuron')
    lookup = {
      'CL:0000037' => term1,
      'CL:0008065' => term2
    }

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      CellOntologyTerm.stub(:find_by, ->(identifier:, original:) { lookup[identifier] }) do
        result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
        label_pair = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.cell_type_ontology_term_id.label_pair' }

        assert_equal 'passed', label_pair[:status]
        refute result[:errors].any? { |entry| entry[:field].to_s.include?('label_pair') }
      end
    end

    resolver.verify
  end

  test 'sorted unique id and label lists produce artifactual label_pair mismatch without pair extraction' do
    field_values = {
      'obs/cell_type_ontology_term_id' => %w[CL:0000037 CL:0008065],
      'obs/cell_type' => ['GABAergic neuron', 'hematopoietic stem cell']
    }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['CL:0000037']
    resolver.expect :exists?, true, ['CL:0008065']
    resolver.expect :descendant_of?, true, ['CL:0000037', 'CL:0000000']
    resolver.expect :descendant_of?, true, ['CL:0008065', 'CL:0000000']

    term1 = Struct.new(:name).new('hematopoietic stem cell')
    term2 = Struct.new(:name).new('GABAergic neuron')
    lookup = {
      'CL:0000037' => term1,
      'CL:0008065' => term2
    }

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      CellOntologyTerm.stub(:find_by, ->(identifier:, original:) { lookup[identifier] }) do
        result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call

        assert result[:errors].any? { |entry| entry[:message].to_s.include?("ID/label mismatch for CL:0000037") }
      end
    end

    resolver.verify
  end
end
