# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairComplianceServiceOrganismTest < TestBaseWithoutFixtures
  test 'file_organism reads h5ad organism term and label' do
    service = ScfairComplianceService.allocate
    field_values = {
      'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
      'uns/organism' => ['Homo sapiens']
    }

    organism = service.send(:file_organism, field_values, 'h5ad')

    assert_equal 'NCBITaxon:9606', organism[:term_id]
    assert_equal 'Homo sapiens', organism[:label]
    assert organism[:present]
  end

  test 'file_organism reads loom organism term and label' do
    service = ScfairComplianceService.allocate
    field_values = {
      '/attrs/organism_ontology_term_id' => ['NCBITaxon:10090'],
      '/attrs/organism' => ['Mus musculus']
    }

    organism = service.send(:file_organism, field_values, 'loom')

    assert_equal 'NCBITaxon:10090', organism[:term_id]
    assert_equal 'Mus musculus', organism[:label]
    assert organism[:present]
  end

  test 'file_organism marks missing organism' do
    service = ScfairComplianceService.allocate

    organism = service.send(:file_organism, {}, 'h5ad')

    refute organism[:present]
    assert_nil organism[:term_id]
    assert_nil organism[:label]
  end
end
