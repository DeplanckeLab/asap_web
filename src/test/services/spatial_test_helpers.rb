# frozen_string_literal: true

module SpatialTestHelpers
  def visium_spatial_field_values(format:, library_id: 'sample_library', is_single: 'true', include_obs: true,
                                  assay: 'EFO:0022857', hires_dim: 2000, n_obs: '100')
    prefix = format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
    obs_prefix = format == 'h5ad' ? 'obs' : '/col_attrs'
    obsm_prefix = format == 'h5ad' ? 'obsm/spatial' : '/col_attrs/spatial'
    assay_key = format == 'h5ad' ? 'obs/assay_ontology_term_id' : '/col_attrs/assay_ontology_term_id'

    fields = {
      assay_key => [assay],
      "#{prefix}/is_single" => [is_single],
      "#{prefix}/#{library_id}/images/hires" => ['__array__'],
      "#{prefix}/#{library_id}/images/hires#shape" => ["#{hires_dim},#{hires_dim},3"],
      "#{prefix}/#{library_id}/images/hires#dtype" => ['uint8'],
      "#{prefix}/#{library_id}/scalefactors/spot_diameter_fullres" => ['1.5'],
      "#{prefix}/#{library_id}/scalefactors/tissue_hires_scalef" => ['0.1'],
      obsm_prefix => ['__array__'],
      "#{obsm_prefix}#shape" => ["#{n_obs},2"],
      "#{obsm_prefix}#dtype" => ['float64'],
      "#{obsm_prefix}#has_inf" => ['false'],
      "#{obsm_prefix}#has_nan" => ['false'],
      'matrix/n_obs' => [n_obs]
    }

    if include_obs && is_single == 'true'
      fields["#{obs_prefix}/array_row"] = ['1']
      fields["#{obs_prefix}/array_col"] = ['2']
      fields["#{obs_prefix}/in_tissue"] = ['1']
    end

    fields
  end
end
