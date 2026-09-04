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
      assert_includes fields, 'ontology.semantics.cell_type_ontology_term_id.existence'
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

  test 'uses cell type lineage rules for primary cell culture tissue terms' do
    field_values = {
      'obs/tissue_type' => ['primary cell culture'],
      'obs/tissue_ontology_term_id' => ['CL:0000084'],
      'obs/tissue' => ['T cell']
    }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['CL:0000084']
    resolver.expect :descendant_of?, true, ['CL:0000084', 'CL:0000000']
    resolver.expect :descendant_of?, false, ['CL:0000084', 'WBbt:0006803']

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
      refute result[:errors].any? { |entry| entry[:message].to_s.include?('must be under UBERON:0001062') }
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

  test 'passes existence when non-special ontology terms were checked successfully' do
    field_values = { 'obs/cell_type_ontology_term_id' => ['CL:0000001', 'unknown'] }
    resolver = Minitest::Mock.new
    resolver.expect :exists?, true, ['CL:0000001']
    resolver.expect :descendant_of?, true, ['CL:0000001', 'CL:0000000']
    resolver.expect :descendant_of?, false, ['CL:0000001', 'WBbt:0006803']

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call
      existence = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.cell_type_ontology_term_id.existence' }

      assert_equal 'passed', existence[:status]
      assert_equal 'Ontology term existence checks passed', existence[:message]
    end

    resolver.verify
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

  test 'does not emit existence when only special values are present' do
    result = Scfair::OntologySemanticsValidator.new(
      field_values: { 'obs/cell_type_ontology_term_id' => %w[unknown na] },
      format: 'h5ad'
    ).call

    refute result[:valid_checks].any? { |check| check[:field] == 'ontology.semantics.cell_type_ontology_term_id.existence' }
    assert_empty result[:errors]
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

  test 'sorted multi-value ordering checks each distinct entry independently' do
    field_values = {
      'obs/cell_type_ontology_term_id' => %w[CL:0002214 CL:0002211 CL:0000136 CL:0002320 CL:0002212]
    }
    resolver = Object.new
    resolver.define_singleton_method(:exists?) { |_id| true }
    resolver.define_singleton_method(:descendant_of?) { |_id, _root| true }

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call

      refute result[:errors].any? { |entry| entry[:field].to_s.end_with?('.ordering') }
      ordering = result[:valid_checks].find { |check| check[:field] == 'ontology.semantics.cell_type_ontology_term_id.sorted_multi' }
      assert_equal 'passed', ordering[:status]
    end
  end

  test 'sorted multi-value ordering reports failing entry with expected order' do
    field_values = {
      'obs/cell_type_ontology_term_id' => ['CL:0000540 || CL:0000136', 'CL:0000001']
    }
    resolver = Object.new
    resolver.define_singleton_method(:exists?) { |_id| true }
    resolver.define_singleton_method(:descendant_of?) { |_id, _root| true }

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call

      ordering_error = result[:errors].find { |entry| entry[:field] == 'ontology.semantics.cell_type_ontology_term_id.ordering' }
      assert ordering_error, 'expected ordering error'
      assert_includes ordering_error[:message], 'CL:0000540 || CL:0000136'
      assert_includes ordering_error[:message], 'CL:0000136 || CL:0000540'
      assert_includes ordering_error[:message], 'not sorted lexically'
    end
  end

  test 'sorted multi-value ordering reports duplicate terms in an entry' do
    field_values = {
      'obs/tissue_ontology_term_id' => ['UBERON:0002048 || UBERON:0002048']
    }
    resolver = Object.new
    resolver.define_singleton_method(:exists?) { |_id| true }
    resolver.define_singleton_method(:descendant_of?) { |_id, _root| true }

    Scfair::OntologyLineageResolver.stub(:new, resolver) do
      result = Scfair::OntologySemanticsValidator.new(field_values: field_values, format: 'h5ad').call

      ordering_error = result[:errors].find { |entry| entry[:field] == 'ontology.semantics.tissue_ontology_term_id.ordering' }
      assert ordering_error, 'expected ordering error'
      assert_includes ordering_error[:message], 'UBERON:0002048 || UBERON:0002048'
      assert_includes ordering_error[:message], 'duplicate term UBERON:0002048'
    end
  end
end
