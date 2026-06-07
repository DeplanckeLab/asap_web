# frozen_string_literal: true

module Scfair
  module PerturbAssayHelper
    module_function

    def obs_prefix(format)
      format.to_s == 'h5ad' ? 'obs' : '/col_attrs'
    end

    def uns_prefix(format)
      format.to_s == 'h5ad' ? 'uns' : '/attrs'
    end

    def uns_root_key(format)
      root = Rules.perturb_extension_rules[:uns_root_key]
      "#{uns_prefix(format)}/#{root}"
    end

    def uns_root_prefix(format)
      "#{uns_root_key(format)}/"
    end

    def obs_field_path(format, field_name)
      "#{obs_prefix(format)}/#{field_name}"
    end

    def obs_field_paths(format)
      Rules.perturb_extension_rules[:obs_fields].map { |name| obs_field_path(format, name) }
    end

    def organism_key(format)
      format.to_s == 'h5ad' ? 'uns/organism_ontology_term_id' : '/attrs/organism_ontology_term_id'
    end

    def perturb_metadata_present?(field_values, format)
      fmt = format.to_s
      field_values.keys.any? { |key| key.start_with?(uns_root_prefix(fmt)) && !key.include?('#') } ||
        present_values?(field_values[uns_root_key(fmt)])
    end

    def perturb_obs_present?(field_values, format)
      obs_field_paths(format).any? { |path| present_values?(field_values[path]) }
    end

    def perturb_enabled?(field_values, format)
      perturb_metadata_present?(field_values, format) || perturb_obs_present?(field_values, format)
    end

    def present_values?(raw)
      Array(raw).any? { |v| v.to_s.strip != '' && v.to_s != '__array__' }
    end
  end
end
