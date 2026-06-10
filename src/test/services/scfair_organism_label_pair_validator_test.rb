# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairOrganismLabelPairValidatorTest < TestBaseWithoutFixtures
  setup do
    @human = Organism.find_by(tax_id: 9606) || Organism.create!(name: 'Homo sapiens', tax_id: 9606)
    @mouse = Organism.find_by(tax_id: 10090) || Organism.create!(name: 'Mus musculus', tax_id: 10090)
  end

  test 'passes when organism label matches organisms table for term id' do
    result = Scfair::OrganismLabelPairValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/organism' => [@human.name]
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert_equal 'passed', result[:valid_checks].first[:status]
  end

  test 'fails when organism label does not match organisms table' do
    result = Scfair::OrganismLabelPairValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/organism' => [@mouse.name]
      },
      format: 'h5ad'
    ).call

    assert_equal 1, result[:errors].size
    assert_match(/must match the name/, result[:errors].first[:message])
    assert_equal 'failed', result[:valid_checks].first[:status]
  end

  test 'fails when term id is unknown in organisms table' do
    result = Scfair::OrganismLabelPairValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:999999'],
        'uns/organism' => ['Unknown species']
      },
      format: 'h5ad'
    ).call

    assert_match(/not a known organism/, result[:errors].first[:message])
  end

  test 'uses extracted label pairs when present' do
    result = Scfair::OrganismLabelPairValidator.new(
      field_values: {
        'uns/organism_ontology_term_id#label_pairs' => ["NCBITaxon:10090 || #{@mouse.name}"]
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert_equal 'passed', result[:valid_checks].first[:status]
  end

  test 'uses loom attrs paths' do
    result = Scfair::OrganismLabelPairValidator.new(
      field_values: {
        '/attrs/organism_ontology_term_id' => ['NCBITaxon:10090'],
        '/attrs/organism' => [@mouse.name]
      },
      format: 'loom'
    ).call

    assert_empty result[:errors]
  end

  test 'skips when organism metadata is absent' do
    result = Scfair::OrganismLabelPairValidator.new(
      field_values: {},
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert_equal 'skipped', result[:valid_checks].first[:status]
  end
end
