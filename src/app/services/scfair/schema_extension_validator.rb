# frozen_string_literal: true

module Scfair
  class SchemaExtensionValidator
    def initialize(field_values:, format:, project_compliance: false, fragment_assets_dir: nil)
      @field_values = field_values || {}
      @format = format
      @project_compliance = project_compliance
      @fragment_assets_dir = fragment_assets_dir
      @resolver = OntologyLineageResolver.new
    end

    def call
      errors = []
      warnings = []
      valid_checks = []

      spatial_result = validate_spatial_extension
      errors.concat(spatial_result[:errors])
      valid_checks.concat(spatial_result[:valid_checks])

      if perturb_enabled?
        perturb_result = PerturbExtensionValidator.new(
          field_values: @field_values,
          format: @format
        ).call
        errors.concat(perturb_result[:errors])
        valid_checks.concat(perturb_result[:valid_checks])
      else
        valid_checks << { field: 'extension.perturb', status: 'skipped', message: 'No perturb extension detected' }
      end

      if atac_enabled?
        if fragment_assets_present?
          valid_checks << {
            field: 'extension.atac',
            status: 'passed',
            message: 'ATAC fragment assets provided (dna_accessibility.tsv.bgz and dna_accessibility.tsv.bgz.tbi)'
          }
        else
          message = 'ATAC extension detected; fragment assets should be provided separately'
          warnings << { field: 'extension.atac', message: message }
          valid_checks << { field: 'extension.atac', status: 'warning', message: message }
        end
      elsif mixed_atac_with_other_assays?
        valid_checks << {
          field: 'extension.atac',
          status: 'skipped',
          message: 'ATAC/multiome mixed with other assays; fragment assets not required'
        }
      else
        valid_checks << { field: 'extension.atac', status: 'skipped', message: 'No ATAC extension detected' }
      end

      if analysis_json_enabled?
        valid_checks << { field: 'extension.analysis_json', status: 'passed', message: 'analysis_json metadata present' }
      else
        message = analysis_json_missing_message
        warnings << { field: 'extension.analysis_json', message: message }
        valid_checks << { field: 'extension.analysis_json', status: 'warning', message: message }
      end

      { errors: errors, warnings: warnings, valid_checks: valid_checks }
    end

    private

    def fragment_assets_present?
      return false unless @project_compliance

      DnaAccessibilityFinalizeService.assets_present?(@fragment_assets_dir)
    end

    def key(path)
      return path if @format == 'h5ad'

      "/#{path}"
    end

    def present?(k)
      SpatialAssayHelper.present_values?(@field_values[k])
    end

    def spatial_enabled?
      SpatialAssayHelper.spatial_enabled?(@field_values, @format, resolver: @resolver)
    end

    def validate_spatial_extension
      unless spatial_enabled?
        return {
          errors: [],
          valid_checks: [{ field: 'extension.spatial', status: 'skipped', message: 'No spatial extension detected' }]
        }
      end

      errors = []
      valid_checks = []

      structure_result = SpatialStructureValidator.new(
        field_values: @field_values,
        format: @format,
        resolver: @resolver
      ).call
      errors.concat(structure_result[:errors])
      valid_checks.concat(structure_result[:valid_checks])

      assets_result = SpatialAssetsValidator.new(
        field_values: @field_values,
        format: @format,
        resolver: @resolver,
        structure: structure_result[:structure]
      ).call
      errors.concat(assets_result[:errors])
      valid_checks.concat(assets_result[:valid_checks])

      obs_missing = spatial_obs_missing_fields
      if obs_missing.any?
        errors << {
          field: 'extension.spatial.obs',
          message: "Spatial extension missing required observation fields: #{obs_missing.join(', ')}"
        }
      end

      spatial_failed = errors.any?
      valid_checks << {
        field: 'extension.spatial',
        status: spatial_failed ? 'failed' : 'passed',
        message: spatial_failed ? 'Spatial schema checks failed' : 'Spatial schema checks passed'
      }

      { errors: errors, valid_checks: valid_checks }
    end

    def spatial_obs_missing_fields
      return [] unless SpatialAssayHelper.visium_obs_fields_required?(@field_values, @format, resolver: @resolver)

      SpatialAssayHelper.visium_obs_field_paths(@format).reject { |field_path| present?(field_path) }
    end

    def perturb_enabled?
      PerturbAssayHelper.perturb_enabled?(@field_values, @format)
    end

    # True only for multiome-only or ATAC-seq/scATAC-seq-only datasets (or ATAC attrs
    # when no assay terms are present). Mixed ATAC/multiome + other assays skip the
    # fragment-file warning.
    def self.atac_enabled?(field_values:, format: 'loom')
      new(field_values: field_values || {}, format: format).send(:atac_enabled?)
    end

    def atac_enabled?
      return false if mixed_atac_with_other_assays?
      return true if atac_like_assay_terms.any?

      assay_ontology_terms.empty? && atac_attrs_present?
    end

    def mixed_atac_with_other_assays?
      atac_like_assay_terms.any? && other_assay_terms.any?
    end

    def assay_ontology_terms
      SpatialAssayHelper.assay_terms(@field_values, @format)
    end

    def atac_like_assay_terms
      assay_ontology_terms.select { |term| atac_like_assay?(term) }
    end

    def other_assay_terms
      assay_ontology_terms - atac_like_assay_terms
    end

    def atac_like_assay?(term)
      AssayProjectTypeHelper.atac_like_term?(term, resolver: @resolver)
    end

    def atac_attrs_present?
      present?(key('uns/atac')) || present?(key('attrs/atac'))
    end

    def analysis_json_enabled?
      present?(key('uns/analysis_pipeline')) || present?(key('attrs/analysis_pipeline'))
    end

    def analysis_json_missing_message
      code = @project_compliance ? 'missing_project' : 'missing_file_check'
      Rules.check_message(
        'extension.analysis_json',
        code,
        format: @format,
        default: 'analysis_json metadata not found (recommended)'
      )
    end
  end
end
