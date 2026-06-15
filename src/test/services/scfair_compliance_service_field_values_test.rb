# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairComplianceServiceFieldValuesTest < TestBaseWithoutFixtures
  test 'attach_field_values adds values for present uns metadata fields' do
    service = ScfairComplianceService.allocate
    item = {
      field: 'uns/organism_ontology_term_id',
      message: 'Found uns/organism_ontology_term_id metadata',
      status: 'passed'
    }
    field_values = {
      'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
      'uns/organism' => ['Homo sapiens']
    }

    enriched = service.send(:attach_field_values, item, field_values, 'uns.required_presence')

    assert_equal ['NCBITaxon:9606'], enriched[:values]
  end

  test 'attach_field_values skips missing fields' do
    service = ScfairComplianceService.allocate
    item = {
      field: 'uns/ensembl_release',
      message: 'Missing uns/ensembl_release metadata (required by schema)',
      status: 'failed'
    }

    enriched = service.send(:attach_field_values, item, {}, 'uns.required_presence')

    refute enriched.key?(:values)
  end

  test 'attach_field_values supports loom dataset metadata paths' do
    service = ScfairComplianceService.allocate
    item = {
      field: '/attrs/title',
      message: 'Found /attrs/title metadata',
      status: 'passed'
    }
    field_values = { '/attrs/title' => ['My dataset title'] }

    enriched = service.send(:attach_field_values, item, field_values, 'uns.required_presence')

    assert_equal ['My dataset title'], enriched[:values]
  end
end
