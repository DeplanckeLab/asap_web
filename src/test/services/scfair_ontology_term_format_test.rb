# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairOntologyTermFormatTest < TestBaseWithoutFixtures
  test 'rules.yaml defines obo and cellosaurus ontology term formats' do
    cfg = Scfair::Rules.ontology_term_format_config

    assert_equal 'CL:0000540', cfg[:obo_example]
    assert Scfair::Rules.obo_ontology_term_format?('EFO:0009899')
    refute Scfair::Rules.obo_ontology_term_format?('EFO-0009899')
    assert Scfair::Rules.cellosaurus_ontology_term?('CVCL_1P02')
    assert_equal 'CVCL', Scfair::Rules.cellosaurus_ontology_tag
    assert_equal 'CVCL', Scfair::Rules.ontology_term_prefix('CVCL_0031')
    assert Scfair::Rules.ontology_term_matches_prefixes?('CVCL_0031', %w[UBERON CVCL WBbt])
    refute Scfair::Rules.ontology_term_matches_prefixes?('CVCL_0031', %w[UBERON])
  end

  test 'assay requires obo format only' do
    assert Scfair::Rules.valid_ontology_term_identifier_format?('EFO:0009899', 'assay_ontology_term_id')
    refute Scfair::Rules.valid_ontology_term_identifier_format?('CVCL_1P02', 'assay_ontology_term_id')
    assert_includes Scfair::Rules.ontology_format_requirement_text('assay_ontology_term_id'), 'PREFIX:ID'
    assert_equal 'ontology_term_formats.obo.requirement', Scfair::Rules.ontology_format_requirement_rules_path('assay_ontology_term_id')
  end

  test 'tissue allows cellosaurus when cvcl prefix is configured' do
    assert Scfair::Rules.ontology_allows_cellosaurus_format?('tissue_ontology_term_id')
    assert Scfair::Rules.valid_ontology_term_identifier_format?('CVCL_1P02', 'tissue_ontology_term_id')
    assert_equal 'ontology_term_formats.combined_requirement', Scfair::Rules.ontology_format_requirement_rules_path('tissue_ontology_term_id')
  end

  test 'ontology_format_error_message uses rules.yaml templates' do
    assay_error = Scfair::Rules.ontology_format_error_message('not-a-term', 'assay_ontology_term_id')
    assert_includes assay_error, 'not-a-term'
    assert_includes assay_error, 'EFO:0009899'
    refute_includes assay_error, 'CL:'

    organism_error = Scfair::Rules.ontology_format_error_message('not-a-term', 'organism_ontology_term_id')
    assert_includes organism_error, 'not-a-term'
    assert_includes organism_error, 'NCBITaxon:9606'
    refute_includes organism_error, 'CL:'

    tissue_error = Scfair::Rules.ontology_format_error_message('CVCL_1P02', 'assay_ontology_term_id')
    assert_includes tissue_error, 'Cellosaurus'
  end

  test 'ontology_format_requirement_text uses field-specific examples' do
    assert_includes Scfair::Rules.ontology_format_requirement_text('assay_ontology_term_id'), 'EFO:0009899'
    assert_includes Scfair::Rules.ontology_format_requirement_text('cell_type_ontology_term_id'), 'CL:0000540'
    assert_includes Scfair::Rules.ontology_format_requirement_text('development_stage_ontology_term_id'), 'HsapDv:0000095'
    assert_includes Scfair::Rules.ontology_format_requirement_text('disease_ontology_term_id'), 'MONDO:0000001'
    assert_includes Scfair::Rules.ontology_format_requirement_text('sex_ontology_term_id'), 'PATO:0000384'
    assert_includes Scfair::Rules.ontology_format_requirement_text('tissue_ontology_term_id'), 'UBERON:0002048'
    assert_includes Scfair::Rules.ontology_format_requirement_text('self_reported_ethnicity_ontology_term_id'), 'HANCESTRO:0005'
    assert_includes Scfair::Rules.ontology_format_requirement_text('organism_ontology_term_id'), 'NCBITaxon:9606'
  end
end
