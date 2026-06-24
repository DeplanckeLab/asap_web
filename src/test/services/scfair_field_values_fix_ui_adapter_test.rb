# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairFieldValuesFixUiAdapterTest < TestBaseWithoutFixtures
  test 'maps field values and label pairs for fix UI' do
    field_values = {
      '/col_attrs/sex' => %w[female male],
      '/col_attrs/cell_type_ontology_term_id#label_pairs' => ['CL:0000540 || neuron']
    }

    result = Scfair::FieldValuesFixUiAdapter.call(
      field_values: field_values,
      field_paths: ['/col_attrs/sex'],
      paired_paths: [['/col_attrs/cell_type_ontology_term_id', '/col_attrs/cell_type']]
    )

    assert_equal %w[female male], result['/col_attrs/sex']
    assert_equal [['CL:0000540', 'neuron']], result['/col_attrs/cell_type_ontology_term_id||/col_attrs/cell_type']
  end
end
