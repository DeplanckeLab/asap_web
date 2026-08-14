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
    assert_equal 'NCBITaxon:9606', by_id['organism'][:terms].first[:identifier]

    assert by_id.key?('cell_type')
    assert_equal 3, by_id['cell_type'][:term_count]
    assert_equal ['B cell', 'NK cell', 'T cell'], by_id['cell_type'][:examples]
    assert_equal '#22C55E', by_id['cell_type'][:color]
    assert_equal '#3B82F6', by_id['organism'][:color]

    assert by_id.key?('suspension_type')
    assert_equal ['cell'], by_id['suspension_type'][:terms].map { |term| term[:label] }

    refute by_id.key?('title')
    refute by_id.key?('schema_version')
  end

  test 'returns empty list when field_values are blank' do
    cards = Scfair::SummaryMetadataCardsBuilder.call(validation_result: { 'valid' => true })
    assert_equal [], cards
  end

  test 'sorts terms with leading numbers first then alphanumerically' do
    validation_result = {
      'valid' => true,
      'field_values' => {
        '/col_attrs/development_stage' => ['adult || 10-cell stage || 2-cell stage || unknown'],
        '/col_attrs/development_stage_ontology_term_id' => [
          'UBERON:0007023 || HsapDv:0000001 || HsapDv:0000002 || unknown'
        ]
      }
    }

    cards = Scfair::SummaryMetadataCardsBuilder.call(validation_result: validation_result)
    card = cards.find { |entry| entry[:id] == 'development_stage' }
    assert card
    assert_equal ['2-cell stage', '10-cell stage', 'adult', 'unknown'], card[:terms].map { |term| term[:label] }
  end

  test 'omits identifier for non-ontology special and enum values' do
    validation_result = {
      'valid' => true,
      'field_values' => {
        '/col_attrs/development_stage' => ['adult || unknown'],
        '/col_attrs/development_stage_ontology_term_id' => ['UBERON:0007023 || unknown'],
        '/col_attrs/suspension_type' => ['cell']
      }
    }

    cards = Scfair::SummaryMetadataCardsBuilder.call(validation_result: validation_result)
    by_id = cards.index_by { |card| card[:id] }

    stages = by_id.fetch('development_stage')[:terms].index_by { |term| term[:label] }
    assert_equal 'UBERON:0007023', stages.fetch('adult')[:identifier]
    assert_nil stages.fetch('unknown')[:identifier]
    assert_nil stages.fetch('unknown')[:url]

    suspension = by_id.fetch('suspension_type')[:terms].first
    assert_equal 'cell', suspension[:label]
    assert_nil suspension[:identifier]
    assert_nil suspension[:url]
  end

  test 'uses label_pairs and attaches ontology urls when available' do
    desired_mask = 'https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=#{ID_VAL}'
    ontology = CellOntology.where('LOWER(tag) = ?', 'ncbitaxon').order(:id).first
    previous_mask = nil

    if ontology
      previous_mask = ontology.url_mask
      ontology.update!(url_mask: desired_mask, obsolete: false)
    else
      register_for_test_cleanup(
        CellOntology.create!(
          name: 'NCBI Taxonomy',
          tag: 'NCBITaxon',
          url_mask: desired_mask,
          obsolete: false
        )
      )
    end

    begin
      validation_result = {
        'valid' => true,
        'field_values' => {
          '/attrs/organism_ontology_term_id#label_pairs' => ['NCBITaxon:9606 || Homo sapiens']
        }
      }

      cards = Scfair::SummaryMetadataCardsBuilder.call(validation_result: validation_result)
      organism = cards.find { |card| card[:id] == 'organism' }
      assert organism
      term = organism[:terms].first
      assert_equal 'Homo sapiens', term[:label]
      assert_equal 'NCBITaxon:9606', term[:identifier]
      assert_equal 'https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=9606', term[:url]
    ensure
      if ontology&.persisted? && previous_mask && ontology.url_mask != previous_mask
        ontology.update!(url_mask: previous_mask)
      end
    end
  end
end
