# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairObsLabelPairConstraintEvaluatorTest < TestBaseWithoutFixtures
  test 'validates label pairs from row-aligned extraction without separate label column key' do
    field_values = {
      'obs/assay_ontology_term_id' => ['EFO:0009899'],
      'obs/assay_ontology_term_id#label_pairs' => ['EFO:0009899 || 10x 3 prime v3']
    }

    term = Struct.new(:name).new('10x 3 prime v3')
    CellOntologyTerm.stub(:active_original_by_identifier, ->(_identifier) { term }) do
      result = Scfair::ObsLabelPairConstraintEvaluator.new(field_values: field_values, format: 'h5ad').call
      label_pair = result[:valid_checks].find { |check| check[:field] == 'obs.label_pairs.assay_ontology_term_id' }

      assert_equal 'passed', label_pair[:status]
      refute result[:errors].any? { |entry| entry[:field] == 'obs.label_pairs.assay_ontology_term_id' }
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

    term1 = Struct.new(:name).new('hematopoietic stem cell')
    term2 = Struct.new(:name).new('GABAergic neuron')
    lookup = {
      'CL:0000037' => term1,
      'CL:0008065' => term2
    }

    CellOntologyTerm.stub(:active_original_by_identifier, ->(identifier) { lookup[identifier] }) do
      result = Scfair::ObsLabelPairConstraintEvaluator.new(field_values: field_values, format: 'h5ad').call
      label_pair = result[:valid_checks].find { |check| check[:field] == 'obs.label_pairs.cell_type_ontology_term_id' }

      assert_equal 'passed', label_pair[:status]
      refute result[:errors].any? { |entry| entry[:field].to_s.include?('label_pair') }
    end
  end

  test 'sorted unique id and label lists produce label_pair mismatch without pair extraction' do
    field_values = {
      'obs/cell_type_ontology_term_id' => %w[CL:0000037 CL:0008065],
      'obs/cell_type' => ['GABAergic neuron', 'hematopoietic stem cell']
    }

    term1 = Struct.new(:name).new('hematopoietic stem cell')
    term2 = Struct.new(:name).new('GABAergic neuron')
    lookup = {
      'CL:0000037' => term1,
      'CL:0008065' => term2
    }

    CellOntologyTerm.stub(:active_original_by_identifier, ->(identifier) { lookup[identifier] }) do
      result = Scfair::ObsLabelPairConstraintEvaluator.new(field_values: field_values, format: 'h5ad').call

      assert result[:errors].any? { |entry| entry[:message].to_s.include?('ID/label mismatch for CL:0000037') }
      label_pair = result[:valid_checks].find { |check| check[:field] == 'obs.label_pairs.cell_type_ontology_term_id' }
      assert_equal 'failed', label_pair[:status]
    end
  end

  test 'skips check when ontology id field is not present' do
    result = Scfair::ObsLabelPairConstraintEvaluator.new(field_values: {}, format: 'h5ad').call

    assay = result[:valid_checks].find { |check| check[:field] == 'obs.label_pairs.assay_ontology_term_id' }
    assert_equal 'skipped', assay[:status]
    assert_empty result[:errors]
  end

  test 'fails when paired label column is missing' do
    result = Scfair::ObsLabelPairConstraintEvaluator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0009899'] },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == 'obs.label_pairs.assay_ontology_term_id' }
    assert_match(/Paired label column obs\/assay is required when obs\/assay_ontology_term_id is present/, result[:errors].first[:message])
  end
end
