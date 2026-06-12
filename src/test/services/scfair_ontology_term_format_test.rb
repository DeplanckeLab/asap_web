# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairOntologyTermFormatTest < TestBaseWithoutFixtures
  test 'rules.yaml defines obo and cellosaurus ontology term formats' do
    cfg = Scfair::Rules.ontology_term_format_config

    assert_equal 'CL:0000540', cfg[:obo_example]
    assert Scfair::Rules.obo_ontology_term_format?('EFO:0009899')
    refute Scfair::Rules.obo_ontology_term_format?('EFO-0009899')
    assert Scfair::Rules.cellosaurus_ontology_term?('CVCL_1P02')
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
    assert_includes assay_error, 'CL:0000540'

    tissue_error = Scfair::Rules.ontology_format_error_message('CVCL_1P02', 'assay_ontology_term_id')
    assert_includes tissue_error, 'Cellosaurus'
  end
end
