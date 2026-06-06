# frozen_string_literal: true

module Scfair
  class SpatialStructureValidator
    def initialize(field_values:, format:, resolver: nil)
      @field_values = field_values || {}
      @format = format.to_s
      @resolver = resolver || OntologyLineageResolver.new
      @rules = Rules.spatial_extension_rules
      @parser = SpatialStructureParser.new(field_values: @field_values, format: @format)
      @structure = @parser.parse
      @spatial_prefix = SpatialAssayHelper.spatial_prefix(@format)
    end

    def call
      errors = []
      valid_checks = []

      spatial_assay = SpatialAssayHelper.any_spatial_assay?(@field_values, @format, resolver: @resolver)
      visium = SpatialAssayHelper.any_visium_assay?(@field_values, @format, resolver: @resolver)

      unless spatial_assay || @structure[:present]
        return {
          errors: errors,
          valid_checks: [{
            field: 'extension.spatial.structure',
            status: 'skipped',
            message: 'No spatial metadata present'
          }],
          structure: @structure
        }
      end

      if @structure[:present] && !spatial_assay
        errors << {
          field: 'extension.spatial.structure',
          message: "#{@spatial_prefix.chomp('/')} must not be present unless assay is Visium or Slide-seqV2"
        }
      end

      if spatial_assay && !@structure[:present]
        errors << {
          field: 'extension.spatial.structure',
          message: "Missing #{@spatial_prefix.chomp('/')} metadata (required for spatial assays)"
        }
      end

      if spatial_assay && @structure[:is_single].nil?
        errors << {
          field: 'extension.spatial.is_single',
          message: "Missing or invalid #{@spatial_prefix}#{root_scalar_key} (must be boolean)"
        }
      end

      validate_root_keys(errors, visium)
      validate_visium_library_structure(errors, visium) if visium

      status = errors.empty? ? 'passed' : 'failed'
      message = errors.empty? ? 'Spatial uns structure checks passed' : 'Spatial uns structure checks failed'
      valid_checks << { field: 'extension.spatial.structure', status: status, message: message }

      { errors: errors, valid_checks: valid_checks, structure: @structure }
    end

    private

    def root_scalar_key
      @rules[:root_scalar_key]
    end

    def validate_root_keys(errors, visium)
      allowed_top_level = [root_scalar_key]
      allowed_top_level.concat(@structure[:library_ids]) if visium && @structure[:is_single]

      unexpected = @structure[:top_level_keys] - allowed_top_level
      unexpected.each do |key|
        errors << {
          field: 'extension.spatial.structure',
          message: "Unexpected key #{@spatial_prefix}#{key} at spatial root (only #{root_scalar_key} and library identifiers are allowed)"
        }
      end

      return unless visium && @structure[:is_single] == false

      @structure[:library_ids].each do |library_id|
        errors << {
          field: 'extension.spatial.library',
          message: "Library metadata #{@spatial_prefix}#{library_id} must not be present when #{root_scalar_key} is false"
        }
      end
    end

    def validate_visium_library_structure(errors, visium)
      return unless visium && @structure[:is_single]

      library_ids = @structure[:library_ids]
      if library_ids.empty?
        errors << {
          field: 'extension.spatial.library',
          message: "Missing Visium library metadata under #{@spatial_prefix} (expected exactly one library identifier)"
        }
        return
      end

      if library_ids.size > 1
        errors << {
          field: 'extension.spatial.library',
          message: "Multiple Visium library identifiers found under #{@spatial_prefix}: #{library_ids.join(', ')} (expected exactly one)"
        }
      end

      library_ids.each do |library_id|
        validate_library_node(errors, library_id)
      end
    end

    def validate_library_node(errors, library_id)
      library_rules = @rules[:library]
      library_children = @parser.child_keys(@structure, library_id)

      missing_library_children = library_rules[:required_when_visium_is_single] - library_children
      missing_library_children.each do |child|
        errors << {
          field: "extension.spatial.library.#{child}",
          message: "Missing #{@spatial_prefix}#{library_id}/#{child}"
        }
      end

      unexpected_library_children = library_children - library_rules[:allowed_keys]
      unexpected_library_children.each do |child|
        errors << {
          field: 'extension.spatial.library',
          message: "Unexpected key #{@spatial_prefix}#{library_id}/#{child} (allowed: #{library_rules[:allowed_keys].join(', ')})"
        }
      end

      validate_nested_section(errors, library_id, 'images', @rules[:images])
      validate_nested_section(errors, library_id, 'scalefactors', @rules[:scalefactors])
    end

    def validate_nested_section(errors, library_id, section_name, section_rules)
      section_children = @parser.child_keys(@structure, library_id, section_name)
      return if section_children.empty? && section_rules[:required_when_visium_is_single].empty?

      missing = section_rules[:required_when_visium_is_single] - section_children
      missing.each do |child|
        errors << {
          field: "extension.spatial.#{section_name}.#{child}",
          message: "Missing #{@spatial_prefix}#{library_id}/#{section_name}/#{child}"
        }
      end

      unexpected = section_children - section_rules[:allowed_keys]
      unexpected.each do |child|
        errors << {
          field: "extension.spatial.#{section_name}",
          message: "Unexpected key #{@spatial_prefix}#{library_id}/#{section_name}/#{child} (allowed: #{section_rules[:allowed_keys].join(', ')})"
        }
      end

      validate_scalefactor_values(errors, library_id, section_name, section_children)
    end

    def validate_scalefactor_values(errors, library_id, section_name, section_children)
      return unless section_name == 'scalefactors'

      section_children.each do |child|
        key = "#{@spatial_prefix}#{library_id}/#{section_name}/#{child}"
        raw = Array(@field_values[key]).first
        next if raw.blank? || raw == '__array__'

        Float(raw)
      rescue ArgumentError, TypeError
        errors << {
          field: "extension.spatial.scalefactors.#{child}",
          message: "#{key} must be a float, got #{raw.inspect}"
        }
      end
    end
  end
end
