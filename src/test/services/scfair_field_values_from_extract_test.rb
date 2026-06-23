# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairFieldValuesFromExtractTest < TestBaseWithoutFixtures
  EXTRACT = {
    'format' => 'h5ad',
    'file_inventory' => {
      'matrix' => { 'n_obs' => 100, 'n_vars' => 50 },
      'obs' => { 'column_names' => %w[donor_id assay assay_ontology_term_id] },
      'var' => { 'column_names' => %w[feature_name] },
      'uns' => { 'top_level_keys' => %w[title organism organism_ontology_term_id] }
    },
    'uns' => {
      'title' => { 'type' => 'string', 'value' => 'Example dataset' },
      'organism' => { 'type' => 'string', 'value' => 'Homo sapiens' },
      'organism_ontology_term_id' => { 'type' => 'string', 'value' => 'NCBITaxon:9606' }
    },
    'paired_fields' => {
      'obs' => {
        'assay_ontology_term_id' => {
          'label_field' => 'assay',
          'pairs' => [{ 'id' => 'EFO:0009899', 'label' => '10x 3 prime v3' }]
        }
      },
      'uns' => {
        'organism_ontology_term_id' => {
          'label_field' => 'organism',
          'pairs' => [{ 'id' => 'NCBITaxon:9606', 'label' => 'Homo sapiens' }]
        }
      }
    },
    'obs' => {
      'columns' => {
        'donor_id' => { 'distinct_values' => %w[donor1 donor2] }
      }
    },
    'var' => {
      'index' => { 'per_feature_values' => %w[ENSG1 ENSG2] },
      'columns' => {
        'feature_name' => { 'per_feature_values' => %w[GENE1 GENE2] }
      }
    },
    'obsm' => {
      'X_umap' => {
        'type' => 'array',
        'shape' => [100, 2],
        'dtype' => 'float64',
        'has_inf' => false,
        'has_nan' => false
      }
    },
    'extensions' => {
      'spatial' => {
        'type' => 'nested',
        'scalars' => {
          'is_single' => { 'type' => 'boolean', 'value' => true }
        }
      }
    }
  }.freeze

  test 'maps minimal extract into compliance field_values for h5ad' do
    field_values = Scfair::FieldValuesFromExtract.call(EXTRACT, format: 'h5ad')

    assert_equal ['Example dataset'], field_values['uns/title']
    assert_equal ['donor1', 'donor2'], field_values['obs/donor_id']
    assert_equal ['EFO:0009899 || 10x 3 prime v3'], field_values['obs/assay_ontology_term_id#label_pairs']
    assert_equal ['EFO:0009899'], field_values['obs/assay_ontology_term_id']
    assert_equal ['NCBITaxon:9606'], field_values['uns/organism_ontology_term_id']
    assert_equal %w[ENSG1 ENSG2], field_values['var/_index#series']
    assert_equal ['__array__'], field_values['obsm/X_umap']
    assert_equal ['100,2'], field_values['obsm/X_umap#shape']
    assert_equal ['true'], field_values['uns/spatial/is_single']
    assert_equal %w[donor_id assay assay_ontology_term_id], field_values['metadata/obs/columns']
  end
end
