# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairSpatialStructureValidatorTest < TestBaseWithoutFixtures
  def visium_spatial_fields(format:, library_id: 'sample_library', is_single: 'true', extra: {})
    prefix = format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
    assay_key = format == 'h5ad' ? 'obs/assay_ontology_term_id' : '/col_attrs/assay_ontology_term_id'

    {
      assay_key => ['EFO:0022857'],
      "#{prefix}/is_single" => [is_single],
      "#{prefix}/#{library_id}/images/hires" => ['__array__'],
      "#{prefix}/#{library_id}/scalefactors/spot_diameter_fullres" => ['1.5'],
      "#{prefix}/#{library_id}/scalefactors/tissue_hires_scalef" => ['0.1']
    }.merge(extra)
  end

  test 'passes for complete visium spatial uns structure' do
    result = Scfair::SpatialStructureValidator.new(
      field_values: visium_spatial_fields(format: 'h5ad'),
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    structure = result[:valid_checks].find { |check| check[:field] == 'extension.spatial.structure' }
    assert_equal 'passed', structure[:status]
  end

  test 'requires visium library metadata when is_single is true' do
    result = Scfair::SpatialStructureValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['true']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == 'extension.spatial.library' }
  end

  test 'rejects library metadata when is_single is false' do
    result = Scfair::SpatialStructureValidator.new(
      field_values: visium_spatial_fields(format: 'h5ad', is_single: 'false'),
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == 'extension.spatial.library' }
  end

  test 'rejects unexpected spatial root keys' do
    result = Scfair::SpatialStructureValidator.new(
      field_values: visium_spatial_fields(format: 'h5ad').merge('uns/spatial/metadata' => ['x']),
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:message].include?('Unexpected key') }
  end

  test 'rejects missing hires image and scalefactors' do
    result = Scfair::SpatialStructureValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['true'],
        'uns/spatial/sample_library/images' => ['__group__']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field] == 'extension.spatial.images.hires' }
    assert result[:errors].any? { |entry| entry[:field] == 'extension.spatial.scalefactors.spot_diameter_fullres' }
  end

  test 'skips structure checks when spatial metadata is present for a non-spatial assay' do
    result = Scfair::SpatialStructureValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0009899'],
        'uns/spatial/is_single' => ['true']
      },
      format: 'h5ad'
    ).call

    structure = result[:valid_checks].find { |check| check[:field] == 'extension.spatial.structure' }
    assert_equal 'skipped', structure[:status]
    assert_match(/CF-10/, structure[:message])
    assert_empty result[:errors]
  end

  test 'slide-seq requires is_single but not visium library metadata' do
    result = Scfair::SpatialStructureValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0030062'],
        'uns/spatial/is_single' => ['true']
      },
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
  end
end
