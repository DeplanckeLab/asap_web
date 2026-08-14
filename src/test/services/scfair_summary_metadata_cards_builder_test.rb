# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairSummaryMetadataCardsBuilderTest < TestBaseWithoutFixtures
  test 'builds cards from rules.yaml ontology pairs using field_values labels' do
    validation_result = {
      'valid' => true,
      'field_values' => {
        '/attrs/organism' => ['Homo sapiens'],
        '/attrs/organism_ontology_term_id' => ['NCBITaxon:9606'],
        '/col_attrs/cell_type' => ['T cell || B cell || NK cell'],
        '/col_attrs/cell_type_ontology_term_id' => ['CL:0000084 || CL:0000236 || CL:0000623'],
        '/col_attrs/tissue' => ['lung'],
        '/col_attrs/tissue_ontology_term_id' => ['UBERON:0002048'],
        '/col_attrs/suspension_type' => ['cell']
      }
    }

    cards = Scfair::SummaryMetadataCardsBuilder.call(validation_result: validation_result)
    by_id = cards.index_by { |card| card[:id] }

    assert by_id.key?('organism')
    assert_equal 'Homo sapiens', by_id['organism'][:examples].first
    assert_equal 1, by_id['organism'][:term_count]

    assert by_id.key?('cell_type')
    assert_equal 3, by_id['cell_type'][:term_count]
    assert_equal ['T cell', 'B cell', 'NK cell'], by_id['cell_type'][:examples]
    assert_equal '#2563EB', by_id['cell_type'][:color]

    assert by_id.key?('suspension_type')
    assert_equal ['cell'], by_id['suspension_type'][:terms]

    refute by_id.key?('title')
    refute by_id.key?('schema_version')
  end

  test 'returns empty list when field_values are blank' do
    cards = Scfair::SummaryMetadataCardsBuilder.call(validation_result: { 'valid' => true })
    assert_equal [], cards
  end
end
