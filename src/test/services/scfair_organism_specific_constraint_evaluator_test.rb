# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairOrganismSpecificConstraintEvaluatorTest < TestBaseWithoutFixtures
  CHECK = 'ontology.organism_specific'

  test 'requires HsapDv development stage prefix for human' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'obs/development_stage_ontology_term_id' => ['HsapDv:0000095'],
        'obs/cell_type_ontology_term_id' => ['CL:0000540'],
        'obs/tissue_ontology_term_id' => ['UBERON:0002048'],
        'obs/self_reported_ethnicity_ontology_term_id' => ['HANCESTRO:0005']
      },
      format: 'h5ad'
    ).call

    dev = result[:valid_checks].find { |check| check[:field] == "#{CHECK}.development_stage" }
    assert_equal 'passed', dev[:status]
  end

  test 'rejects wrong development stage prefix for human' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'obs/development_stage_ontology_term_id' => ['MmusDv:0000001']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == "#{CHECK}.development_stage" }
  end

  test 'requires CL or FBbt cell type prefixes for drosophila' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:7227'],
        'obs/cell_type_ontology_term_id' => ['FBbt:00007002']
      },
      format: 'h5ad'
    ).call

    cell = result[:valid_checks].find { |check| check[:field] == "#{CHECK}.cell_type" }
    assert_equal 'passed', cell[:status]
  end

  test 'requires UBERON or FBbt tissue prefixes for drosophila tissue' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:7227'],
        'obs/tissue_type' => ['tissue'],
        'obs/tissue_ontology_term_id' => ['FBbt:10000000']
      },
      format: 'h5ad'
    ).call

    tissue = result[:valid_checks].find { |check| check[:field] == "#{CHECK}.tissue" }
    assert_equal 'passed', tissue[:status]
  end

  test 'requires ethnicity na for non-human organism' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:10090'],
        'obs/tissue_type' => ['tissue'],
        'obs/self_reported_ethnicity_ontology_term_id' => ['na']
      },
      format: 'h5ad'
    ).call

    ethnicity = result[:valid_checks].find { |check| check[:field] == "#{CHECK}.ethnicity" }
    assert_equal 'passed', ethnicity[:status]
  end

  test 'rejects ethnicity terms for non-human organism' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:10090'],
        'obs/tissue_type' => ['tissue'],
        'obs/self_reported_ethnicity_ontology_term_id' => ['HANCESTRO:0005']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == "#{CHECK}.ethnicity" }
  end

  test 'rejects ethnicity na for human organism' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'obs/tissue_type' => ['tissue'],
        'obs/self_reported_ethnicity_ontology_term_id' => ['na']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == "#{CHECK}.ethnicity" }
  end

  test 'accepts Cellosaurus CVCL terms for cell line tissue' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'obs/tissue_type' => ['cell line'],
        'obs/tissue_ontology_term_id' => ['CVCL_0031']
      },
      format: 'h5ad'
    ).call

    tissue = result[:valid_checks].find { |check| check[:field] == "#{CHECK}.tissue" }
    assert_equal 'passed', tissue[:status]
    assert result[:errors].none? { |entry| entry[:field] == "#{CHECK}.tissue" }
  end

  test 'validates celegans sex terms' do
    result = Scfair::OrganismSpecificConstraintEvaluator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:6239'],
        'obs/sex_ontology_term_id' => ['PATO:0001340']
      },
      format: 'h5ad'
    ).call

    sex = result[:valid_checks].find { |check| check[:field] == "#{CHECK}.sex" }
    assert_equal 'passed', sex[:status]
  end
end
