# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairOntologyValueResolverTest < TestBaseWithoutFixtures
  test 'resolves enum fields' do
    groups = [{
      id: 'tissue_type',
      term_path: '/col_attrs/tissue_type',
      term_valid_values: %w[tissue organoid cell_line],
      term_ontology_prefixes: []
    }]

    result = Scfair::OntologyValueResolver.call(
      groups: groups,
      field_values: { '/col_attrs/tissue_type' => %w[tissue invalid] },
      format: 'loom'
    )

    assert_equal true, result['/col_attrs/tissue_type']['tissue']
    assert_equal false, result['/col_attrs/tissue_type']['invalid']
  end
end
