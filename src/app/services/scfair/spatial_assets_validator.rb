# frozen_string_literal: true

module Scfair
  class SpatialAssetsValidator
    def initialize(field_values:, format:, resolver: nil, structure: nil)
      @field_values = field_values || {}
      @format = format.to_s
      @resolver = resolver || OntologyLineageResolver.new
      @rules = Rules.spatial_extension_rules
      @structure = structure || SpatialStructureParser.new(field_values: @field_values, format: @format).parse
      @spatial_prefix = SpatialAssayHelper.spatial_prefix(@format)
    end

    def call
      errors = []
      valid_checks = []

      spatial_assay = SpatialAssayHelper.any_spatial_assay?(@field_values, @format, resolver: @resolver)
      visium = SpatialAssayHelper.any_visium_assay?(@field_values, @format, resolver: @resolver)
      is_single = @structure[:is_single]

      unless spatial_assay
        return {
          errors: errors,
          valid_checks: [{
            field: 'extension.spatial.assets',
            status: 'skipped',
            message: 'No spatial assay detected for asset checks'
          }],
          structure: @structure
        }
      end

      if visium && is_single
        validate_visium_images(errors)
      end

      validate_obsm_spatial(errors, spatial_assay, is_single)

      status = errors.empty? ? 'passed' : 'failed'
      message = errors.empty? ? 'Spatial image and embedding checks passed' : 'Spatial image and embedding checks failed'
      valid_checks << { field: 'extension.spatial.assets', status: status, message: message }

      { errors: errors, valid_checks: valid_checks, structure: @structure }
    end

    private

    def validate_visium_images(errors)
      image_rules = @rules.dig(:images, :array) || {}
      @structure[:library_ids].each do |library_id|
        @rules.dig(:images, :required_when_visium_is_single).each do |image_key|
          path = "#{@spatial_prefix}#{library_id}/images/#{image_key}"
          validate_image_array(errors, path, image_key, image_rules, required: true)
        end

        optional_images = @rules.dig(:images, :allowed_keys) - @rules.dig(:images, :required_when_visium_is_single)
        optional_images.each do |image_key|
          path = "#{@spatial_prefix}#{library_id}/images/#{image_key}"
          next unless SpatialArrayMetadata.read(@field_values, path)[:present]

          validate_image_array(errors, path, image_key, image_rules, required: false)
        end
      end
    end

    def validate_image_array(errors, path, image_key, image_rules, required:)
      meta = SpatialArrayMetadata.read(@field_values, path)
      if !meta[:present]
        return errors << missing_asset_error(path, image_key) if required

        return
      end

      unless SpatialArrayMetadata.complete?(meta)
        errors << {
          field: "extension.spatial.images.#{image_key}",
          message: "Could not read array metadata for #{path} (shape and dtype required)"
        }
        return
      end

      expected_dtype = image_rules[:dtype].to_s
      if meta[:dtype] != expected_dtype
        errors << {
          field: "extension.spatial.images.#{image_key}",
          message: "#{path} dtype must be #{expected_dtype}, got #{meta[:dtype]}"
        }
      end

      if meta[:shape].length != image_rules[:ndim]
        errors << {
          field: "extension.spatial.images.#{image_key}",
          message: "#{path} must be #{image_rules[:ndim]}-dimensional, got shape #{meta[:shape].join('x')}"
        }
        return
      end

      channels = meta[:shape][2]
      unless image_rules[:channel_sizes].include?(channels)
        errors << {
          field: "extension.spatial.images.#{image_key}",
          message: "#{path} channel dimension must be one of #{image_rules[:channel_sizes].join(' or ')}, got #{channels}"
        }
      end

      return unless image_key == 'hires'

      expected_max = expected_hires_max_dimension
      actual_max = meta[:shape].first(2).max
      return if expected_max.nil?

      unless actual_max == expected_max
        errors << {
          field: 'extension.spatial.images.hires',
          message: "#{path} largest spatial dimension must be #{expected_max} pixels for this assay, got #{actual_max}"
        }
      end
    end

    def expected_hires_max_dimension
      dims = @rules.dig(:images, :hires_max_dimension) || {}
      assay = primary_assay_term
      dims.dig(:by_assay, assay) || dims[:default]
    end

    def primary_assay_term
      SpatialAssayHelper.assay_terms(@field_values, @format).first
    end

    def validate_obsm_spatial(errors, spatial_assay, is_single)
      path = obsm_spatial_key
      meta = SpatialArrayMetadata.read(@field_values, path)
      obsm_rules = @rules[:obsm_spatial] || {}

      if spatial_assay && is_single && obsm_rules[:required_when_is_single] && !meta[:present]
        errors << {
          field: 'extension.spatial.obsm',
          message: "Missing required spatial embedding at #{path}"
        }
        return
      end

      if !spatial_assay && meta[:present]
        errors << {
          field: 'extension.spatial.obsm',
          message: "#{path} must not be present unless spatial metadata applies"
        }
        return
      end

      return unless meta[:present]

      unless SpatialArrayMetadata.complete?(meta)
        errors << {
          field: 'extension.spatial.obsm',
          message: "Could not read array metadata for #{path} (shape and dtype required)"
        }
        return
      end

      n_obs = matrix_n_obs
      if n_obs && meta[:shape].first != n_obs
        errors << {
          field: 'extension.spatial.obsm',
          message: "#{path} row count #{meta[:shape].first} does not match n_obs #{n_obs}"
        }
      end

      if meta[:shape].length != 2 || meta[:shape][1] < obsm_rules[:min_columns]
        errors << {
          field: 'extension.spatial.obsm',
          message: "#{path} must be 2D with at least #{obsm_rules[:min_columns]} columns"
        }
      end

      dtype_kind = SpatialArrayMetadata.dtype_kind(meta[:dtype])
      unless obsm_rules[:dtype_kinds].include?(dtype_kind)
        errors << {
          field: 'extension.spatial.obsm',
          message: "#{path} dtype kind must be one of #{obsm_rules[:dtype_kinds].join(', ')}, got #{meta[:dtype]}"
        }
      end

      if meta[:has_inf]
        errors << { field: 'extension.spatial.obsm', message: "#{path} must not contain infinity values" }
      end

      if meta[:has_nan]
        errors << { field: 'extension.spatial.obsm', message: "#{path} must not contain NaN values" }
      end
    end

    def obsm_spatial_key
      @format == 'h5ad' ? @rules.dig(:obsm_spatial, :h5ad_key) : @rules.dig(:obsm_spatial, :loom_key)
    end

    def matrix_n_obs
      raw = Array(@field_values['matrix/n_obs']).first
      return nil if raw.blank?

      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def missing_asset_error(path, image_key)
      {
        field: "extension.spatial.images.#{image_key}",
        message: "Missing #{path}"
      }
    end
  end
end
