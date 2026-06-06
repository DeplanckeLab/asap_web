# frozen_string_literal: true

module Scfair
  module SpatialAssayHelper
    VISIUM_ROOT = SchemaConstants::VISIUM_ASSAY_ROOT
    SLIDE_SEQ = SchemaConstants::SLIDE_SEQ_ASSAY

    module_function

    def assay_terms(field_values, format)
      key = format.to_s == 'h5ad' ? 'obs/assay_ontology_term_id' : '/col_attrs/assay_ontology_term_id'
      Array(field_values[key]).flat_map { |v| v.to_s.split(' || ') }.map(&:strip).reject(&:blank?).uniq
    end

    def visium_assay?(term, resolver: nil)
      return false if term.blank?

      term = term.to_s
      return true if SchemaConstants::VISIUM_ASSAY_TERMS.include?(term)

      (resolver || OntologyLineageResolver.new).descendant_of?(term, VISIUM_ROOT)
    end

    def slide_seq_assay?(term)
      term.to_s == SLIDE_SEQ
    end

    def spatial_assay?(term, resolver: nil)
      visium_assay?(term, resolver: resolver) || slide_seq_assay?(term)
    end

    def any_spatial_assay?(field_values, format, resolver: nil)
      resolver ||= OntologyLineageResolver.new
      assay_terms(field_values, format).any? { |term| spatial_assay?(term, resolver: resolver) }
    end

    def any_visium_assay?(field_values, format, resolver: nil)
      resolver ||= OntologyLineageResolver.new
      assay_terms(field_values, format).any? { |term| visium_assay?(term, resolver: resolver) }
    end

    def spatial_prefix(format)
      format.to_s == 'h5ad' ? 'uns/spatial/' : '/attrs/spatial/'
    end

    def spatial_is_single_key(format)
      "#{spatial_prefix(format)}is_single"
    end

    def falsy?(value)
      %w[false 0 f no].include?(value.to_s.strip.downcase)
    end

    def parse_bool(value)
      return true if truthy?(value)
      return false if falsy?(value)

      nil
    end

    def spatial_is_single?(field_values, format)
      parse_bool(Array(field_values[spatial_is_single_key(format)]).first) == true
    end

    def spatial_metadata_present?(field_values, format)
      fmt = format.to_s
      prefix = spatial_prefix(fmt)
      field_values.keys.any? { |key| key.start_with?(prefix) }
    end

    def spatial_enabled?(field_values, format, resolver: nil)
      spatial_metadata_present?(field_values, format) ||
        any_spatial_assay?(field_values, format, resolver: resolver)
    end

    def visium_obs_fields_required?(field_values, format, resolver: nil)
      any_visium_assay?(field_values, format, resolver: resolver) &&
        spatial_is_single?(field_values, format)
    end

    def visium_obs_field_paths(format)
      if format.to_s == 'h5ad'
        %w[obs/array_row obs/array_col obs/in_tissue]
      else
        %w[/col_attrs/array_row /col_attrs/array_col /col_attrs/in_tissue]
      end
    end

    def truthy?(value)
      %w[true 1 t yes].include?(value.to_s.strip.downcase)
    end

    def present_values?(raw)
      Array(raw).any? { |v| v.to_s.strip != '' }
    end
  end
end
