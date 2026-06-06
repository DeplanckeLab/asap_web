# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class ScfairSpatialAssayHelperTest < TestBaseWithoutFixtures
  test 'detects known visium assay terms' do
    assert Scfair::SpatialAssayHelper.visium_assay?('EFO:0022857')
    assert Scfair::SpatialAssayHelper.slide_seq_assay?('EFO:0030062')
    assert Scfair::SpatialAssayHelper.spatial_assay?('EFO:0030062')
  end

  test 'detects visium descendants via ontology lineage' do
    resolver = Minitest::Mock.new
    resolver.expect :descendant_of?, true, ['EFO:NEW_VISIUM', 'EFO:0010961']

    assert Scfair::SpatialAssayHelper.visium_assay?('EFO:NEW_VISIUM', resolver: resolver)
    resolver.verify
  end

  test 'spatial_is_single reads flattened metadata paths' do
    field_values = { 'uns/spatial/is_single' => ['true'] }

    assert Scfair::SpatialAssayHelper.spatial_is_single?(field_values, 'h5ad')
    assert Scfair::SpatialAssayHelper.spatial_metadata_present?(field_values, 'h5ad')
  end

  test 'visium obs fields required only when is_single is true' do
    field_values = {
      'obs/assay_ontology_term_id' => ['EFO:0022857'],
      'uns/spatial/is_single' => ['true']
    }

    assert Scfair::SpatialAssayHelper.visium_obs_fields_required?(field_values, 'h5ad')
  end
end
