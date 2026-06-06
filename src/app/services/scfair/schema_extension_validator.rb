# frozen_string_literal: true

module Scfair
  class SchemaExtensionValidator
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
    end

    def call
      errors = []
      warnings = []
      valid_checks = []

      if spatial_enabled?
        required = spatial_required_fields
        missing = required.reject { |k| present?(k) }
        if missing.any?
          errors << { field: 'extension.spatial.required', message: "Spatial extension missing required fields: #{missing.join(', ')}" }
          valid_checks << { field: 'extension.spatial', status: 'failed', message: 'Spatial schema checks failed' }
        else
          valid_checks << { field: 'extension.spatial', status: 'passed', message: 'Spatial schema checks passed' }
        end
      else
        valid_checks << { field: 'extension.spatial', status: 'skipped', message: 'No spatial extension detected' }
      end

      if perturb_enabled?
        if present?(key('obs/genetic_perturbation_id')) && !present?(key('obs/genetic_perturbation_strategy'))
          errors << { field: 'extension.perturb.strategy', message: 'genetic_perturbation_strategy is required when genetic_perturbation_id is present' }
          valid_checks << { field: 'extension.perturb', status: 'failed', message: 'Perturb schema checks failed' }
        else
          valid_checks << { field: 'extension.perturb', status: 'passed', message: 'Perturb schema checks passed' }
        end
      else
        valid_checks << { field: 'extension.perturb', status: 'skipped', message: 'No perturb extension detected' }
      end

      if atac_enabled?
        valid_checks << { field: 'extension.atac', status: 'warning', message: 'ATAC extension detected; fragment assets should be provided separately' }
      else
        valid_checks << { field: 'extension.atac', status: 'skipped', message: 'No ATAC extension detected' }
      end

      if analysis_json_enabled?
        valid_checks << { field: 'extension.analysis_json', status: 'passed', message: 'analysis_json metadata present' }
      else
        valid_checks << { field: 'extension.analysis_json', status: 'warning', message: 'analysis_json metadata not found (recommended)' }
      end

      { errors: errors, warnings: warnings, valid_checks: valid_checks }
    end

    private

    def key(path)
      return path if @format == 'h5ad'
      "/#{path}"
    end

    def present?(k)
      vals = @field_values[k]
      vals.present? && Array(vals).any? { |v| v.to_s.strip != '' }
    end

    def spatial_enabled?
      present?(key('uns/spatial')) || present?(key('attrs/spatial'))
    end

    def spatial_required_fields
      if @format == 'h5ad'
        %w[obs/array_row obs/array_col obs/in_tissue]
      else
        %w[/col_attrs/array_row /col_attrs/array_col /col_attrs/in_tissue]
      end
    end

    def perturb_enabled?
      present?(key('uns/genetic_perturbations')) || present?(key('obs/genetic_perturbation_id'))
    end

    def atac_enabled?
      assay_key = @format == 'h5ad' ? 'obs/assay_ontology_term_id' : '/col_attrs/assay_ontology_term_id'
      vals = Array(@field_values[assay_key]).flat_map { |v| v.to_s.split(' || ') }.map(&:strip)
      return true if vals.include?('EFO:0030059') # 10x multiome

      resolver = Scfair::OntologyLineageResolver.new
      vals.any? do |v|
        next false if v.blank?
        resolver.descendant_of?(v, 'EFO:0010891') # scATAC-seq root and descendants
      end || present?(key('uns/atac')) || present?(key('attrs/atac'))
    end

    def analysis_json_enabled?
      present?(key('uns/analysis_pipeline')) || present?(key('attrs/analysis_pipeline'))
    end
  end
end
