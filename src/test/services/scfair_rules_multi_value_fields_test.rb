# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRulesMultiValueFieldsTest < TestBaseWithoutFixtures
  test 'lists schema fields that allow delimiter-separated multi-values' do
    names = Scfair::Rules.multi_value_field_names

    assert_includes names, 'disease_ontology_term_id'
    assert_includes names, 'disease'
    assert_includes names, 'experimental_condition_ontology_term_id'
    assert_includes names, 'experimental_condition'
    assert_includes names, 'self_reported_ethnicity_ontology_term_id'
    assert_includes names, 'self_reported_ethnicity'
    assert_includes names, 'genetic_perturbation_id'
    assert_includes names, 'perturbation_types'
    assert_includes names, 'cell_type_ontology_term_id'
    assert_includes names, 'cell_type'
    assert_includes names, 'tissue_ontology_term_id'
    assert_includes names, 'tissue'

    refute_includes names, 'assay_ontology_term_id'
  end

  test 'cell_type ontology semantics require sorted multi-value ordering' do
    rules = Scfair::OntologySemanticRules.rules_for('cell_type_ontology_term_id')

    assert rules[:sorted_multi]
  end

  test 'tissue ontology semantics require sorted multi-value ordering' do
    rules = Scfair::OntologySemanticRules.rules_for('tissue_ontology_term_id')

    assert rules[:sorted_multi]
  end

  test 'disease ontology semantics require sorted multi-value ordering' do
    rules = Scfair::OntologySemanticRules.rules_for('disease_ontology_term_id')

    assert rules[:sorted_multi]
  end

  test 'obs_field_name_from_path extracts obs column from loom paths' do
    assert_equal 'cell_type_ontology_term_id', Scfair::Rules.obs_field_name_from_path('/col_attrs/cell_type_ontology_term_id')
    assert_equal 'cell_type_ontology_term_id', Scfair::Rules.obs_field_name_from_path('col_attrs/cell_type_ontology_term_id')
    assert_equal 'organism_ontology_term_id', Scfair::Rules.obs_field_name_from_path('/attrs/organism_ontology_term_id')
  end

  test 'compliance_field_message_paths includes h5ad and ensembl check ids' do
    paths = Scfair::Rules.compliance_field_message_paths('/attrs/ensembl_release')

    assert_includes paths, '/attrs/ensembl_release'
    assert_includes paths, 'uns/ensembl_release'
    assert_includes paths, 'uns.ensembl.release'
  end
end
