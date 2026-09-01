# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairTissueOntologyValidationTest < TestBaseWithoutFixtures
  test 'format_prefixes uses CL for primary cell culture' do
    prefixes = Scfair::TissueOntologyValidation.format_prefixes(
      tissue_type: 'primary cell culture',
      organism: 'NCBITaxon:9606',
      default_prefixes: %w[UBERON CVCL]
    )

    assert_includes prefixes, 'CL'
    refute_includes prefixes, 'UBERON'
  end

  test 'semantic_rules uses cell type rules for primary cell culture' do
    rules = Scfair::TissueOntologyValidation.semantic_rules(tissue_type: 'primary cell culture')

    assert_equal Scfair::OntologySemanticRules.rules_for('cell_type_ontology_term_id'), rules
  end
end
