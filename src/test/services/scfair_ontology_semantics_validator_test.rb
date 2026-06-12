# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class ScfairOntologySemanticsValidatorTest < TestBaseWithoutFixtures
  test 'emits semantic subchecks without aggregate field checks' do
    field_values = { 'obs/cell_type_ontology_term_id' => ['CL:0000001'] }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['CL:0000001']
    resolver.expect :descendant_of?, true, ['CL:0000001', 'CL:0000000']
    resolver.expect :descendant_of?, false, ['CL:0000001', 'WBbt:0006803']

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
      CellOntologyTerm.stub(:active_original_by_identifier, ->(identifier) { lookup[identifier] }) do
        result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call

        refute result[:errors].any? { |entry| entry[:field].to_s.include?('label_pair') }
      end
    end
  end

  test 'ontology semantics skips obs label pair validation for fields in label_pairs' do
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

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
      refute result[:valid_checks].any? { |check| check[:field].to_s.include?('label_pair') }
      refute result[:errors].any? { |entry| entry[:field].to_s.include?('label_pair') }
    end
  end

  test 'fails allowed_terms when term is obsolete in ontology DB' do
    obsolete_term = CellOntologyTerm.find_by(identifier: 'EFO:0009310', original: true)
    skip 'EFO:0009310 obsolete term not loaded; run load_ontologies' unless obsolete_term&.obsolete?
    skip 'active lookup still resolves obsolete term' if CellOntologyTerm.active_original_by_identifier('EFO:0009310')

    result = Scfair::OntologySemanticsValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0009310'] },
      format: 'h5ad'
    ).call
    allowed = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.assay_ontology_term_id.allowed_terms' }

    assert_equal 'failed', allowed[:status]
    assert result[:errors].any? { |entry| entry[:field] == 'ontology.semantics.assay_ontology_term_id.existence' }
    assert result[:errors].any? { |entry| entry[:message].include?('EFO:0009310') && entry[:message].include?('term not found in ontology DB') }
  end

  test 'passes allowed_terms for active replacement of obsolete assay term' do
    skip 'EFO:0009899 not loaded; run load_ontologies' unless CellOntologyTerm.active_original_by_identifier('EFO:0009899')

    result = Scfair::OntologySemanticsValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0009899'] },
      format: 'h5ad'
    ).call
    allowed = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.assay_ontology_term_id.allowed_terms' }

    assert_equal 'passed', allowed[:status]
    refute result[:errors].any? { |entry| entry[:field].to_s.include?('existence') }
  end

  test 'ontology semantics does not validate obs label pairs from sorted unique lists' do
    field_values = {
      'obs/cell_type_ontology_term_id' => %w[CL:0000037 CL:0008065],
      'obs/cell_type' => ['GABAergic neuron', 'hematopoietic stem cell']
    }
    resolver = Object.new
    resolver.define_singleton_method(:exists?) { |_id| true }
    resolver.define_singleton_method(:descendant_of?) { |_id, _root| true }

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
      refute result[:errors].any? { |entry| entry[:message].to_s.include?('ID/label mismatch') }
    end
  end

  test 'sex allowed_terms rejects PATO terms outside valid_terms whitelist' do
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['PATO:0002301']

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(
        field_values: { 'obs/sex_ontology_term_id' => ['PATO:0002301'] },
        format: 'h5ad'
      ).call

      allowed = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.sex_ontology_term_id.allowed_terms' }
      assert_equal 'failed', allowed[:status]
      assert result[:errors].any? { |entry| entry[:field] == 'ontology.semantics.sex_ontology_term_id.allowed_terms' }
    end

    resolver.verify
  end

  test 'sex allowed_terms passes for valid_terms and special values' do
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['PATO:0000384']

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(
        field_values: { 'obs/sex_ontology_term_id' => ['PATO:0000384', 'unknown'] },
        format: 'h5ad'
      ).call

      allowed = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.sex_ontology_term_id.allowed_terms' }
      assert_equal 'passed', allowed[:status]
      assert_empty result[:errors]
    end

    resolver.verify
  end
end
