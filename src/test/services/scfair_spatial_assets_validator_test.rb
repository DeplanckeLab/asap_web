# frozen_string_literal: true

require_relative 'test_base_without_fixtures'
require_relative 'spatial_test_helpers'

class ScfairSpatialAssetsValidatorTest < TestBaseWithoutFixtures
  include SpatialTestHelpers

  test 'passes for valid visium hires image and obsm spatial embedding' do
    result = Scfair::SpatialAssetsValidator.new(
      field_values: visium_spatial_field_values(format: 'h5ad'),
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assets = result[:valid_checks].find { |check| check[:field] == 'extension.spatial.assets' }
    assert_equal 'passed', assets[:status]
  end

  test 'requires obsm spatial when is_single is true' do
    fields = visium_spatial_field_values(format: 'h5ad')
    fields.delete('obsm/spatial')
    fields.delete('obsm/spatial#shape')
    fields.delete('obsm/spatial#dtype')
    fields.delete('obsm/spatial#has_inf')
    fields.delete('obsm/spatial#has_nan')

    result = Scfair::SpatialAssetsValidator.new(field_values: fields, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:field] == 'extension.spatial.obsm' }
  end

  test 'rejects hires image with wrong max dimension for cytassist 11mm' do
    fields = visium_spatial_field_values(format: 'h5ad', assay: 'EFO:0022860', hires_dim: 2000)

    result = Scfair::SpatialAssetsValidator.new(field_values: fields, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:field] == 'extension.spatial.images.hires' }
  end

  test 'rejects hires image with invalid dtype' do
    fields = visium_spatial_field_values(format: 'h5ad')
    fields['uns/spatial/sample_library/images/hires#dtype'] = ['float32']

    result = Scfair::SpatialAssetsValidator.new(field_values: fields, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:message].include?('dtype must be uint8') }
  end

  test 'rejects obsm spatial embedding with nan values' do
    fields = visium_spatial_field_values(format: 'h5ad')
    fields['obsm/spatial#has_nan'] = ['true']

    result = Scfair::SpatialAssetsValidator.new(field_values: fields, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:message].include?('NaN') }
  end

  test 'validates loom spatial assets using col_attrs spatial path' do
    result = Scfair::SpatialAssetsValidator.new(
      field_values: visium_spatial_field_values(format: 'loom'),
      format: 'loom'
    ).call

    assert_empty result[:errors]
  end
end
