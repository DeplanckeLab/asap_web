# frozen_string_literal: true

require 'yaml'

module Scfair
  # Loads scFAIR compliance rules from config/scfair/7.1.0/rules.yaml.
  module Rules
    RULES_PATH = Rails.root.join('config/scfair/7.1.0/rules.yaml').freeze
    DEFAULT_SCHEMA_ID = 'scfair_7_1_0'

    module_function

    def reload!
      @data = nil
      load!
    end

    def load!
      raw = YAML.safe_load_file(RULES_PATH, aliases: true)
      raise "Missing scFAIR rules file: #{RULES_PATH}" if raw.blank?

      @data = raw.deep_symbolize_keys
    end

    def data
      @data ||= load!
    end

    def schema_id
      data.dig(:schema, :id).to_s
    end

    def schema_config(schema_id = DEFAULT_SCHEMA_ID)
      raise ArgumentError, "Unknown schema '#{schema_id}'" unless schema_id == DEFAULT_SCHEMA_ID

      schema_hash
    end

    def schema_hash
      s = data[:schema]
      {
        id: s[:id],
        label: s[:label],
        schema_version: s[:schema_version],
        source_url: s[:source_url]
      }
    end

    def schema_version
      data.dig(:schema, :version).to_s
    end

    def path_prefix(format, layer)
      fmt = format.to_sym
      data.dig(:paths, layer.to_sym, fmt).to_s
    end

    def field_path(format, layer, field_name)
      prefix = path_prefix(format, layer)
      if format.to_s == 'loom'
        "#{prefix}/#{field_name}"
      else
        "#{prefix}/#{field_name}"
      end
    end

    def required_observation_fields
      Array(data.dig(:required, :observation_fields)).map(&:to_s).freeze
    end

    def required_observation_labels
      Array(data.dig(:required, :observation_labels)).map(&:to_s).freeze
    end

    def required_uns_fields(format)
      common = Array(data.dig(:required, :uns, :common)).map(&:to_s)
      labels = Array(data.dig(:required, :uns, :labels)).map(&:to_s)
      extra = format.to_s == 'h5ad' ? Array(data.dig(:required, :uns, :h5ad_only)).map(&:to_s) : []
      (common + labels + extra).freeze
    end

    def required_uns_term_fields(format)
      common = Array(data.dig(:required, :uns, :common)).map(&:to_s)
      extra = format.to_s == 'h5ad' ? Array(data.dig(:required, :uns, :h5ad_only)).map(&:to_s) : []
      (common + extra).freeze
    end

    def required_uns_labels
      Array(data.dig(:required, :uns, :labels)).map(&:to_s).freeze
    end

    def enum_field_values(field_name)
      Array(data.dig(:enum_fields, field_name.to_sym, :values)).map(&:to_s).freeze
    end

    def ontology_fields
      data[:ontology_fields] || {}
    end

    def ontology_field(field_name)
      ontology_fields[field_name.to_sym] || {}
    end

    def ontology_prefixes(field_name)
      Array(ontology_field(field_name)[:prefixes]).map(&:to_s).freeze
    end

    def ontology_prefixes_legacy_hash
      ontology_fields.each_with_object({}) do |(field_name, cfg), out|
        key = (cfg[:legacy_key] || field_name.to_s.sub(/_ontology_term_id\z/, '')).to_sym
        out[key] = Array(cfg[:prefixes]).map(&:to_s)
      end.freeze
    end

    def special_values_for_field(format, field_name)
      Array(ontology_field(field_name)[:special_values]).map(&:to_s).freeze
    end

    def allowed_special_values(format)
      fmt = format.to_s
      ontology_fields.each_with_object({}) do |(field_name, cfg), out|
        layer = (cfg[:layer] || :obs).to_sym
        path = field_path(fmt, layer, field_name.to_s)
        out[path] = Array(cfg[:special_values]).map(&:to_s)
      end.freeze
    end

    def ontology_paths(format)
      fmt = format.to_s
      ontology_fields.each_with_object({}) do |(field_name, cfg), out|
        layer = (cfg[:layer] || :obs).to_sym
        path = field_path(fmt, layer, field_name.to_s)
        out[path] = Array(cfg[:prefixes]).map(&:to_s)
      end.freeze
    end

    def valid_sex_terms
      raw = data.dig(:constants, :valid_sex_terms) || {}
      raw.each_with_object({}) { |(id, name), h| h[id.to_s] = name.to_s }.freeze
    end

    def valid_sex_term_ids
      valid_sex_terms.keys.freeze
    end

    def sex_special_values
      Array(data.dig(:constants, :sex_special_values)).map(&:to_s).freeze
    end

    def banned_cell_type_terms
      resolve_constant_ref(data.dig(:constants, :banned_cell_type_terms)).freeze
    end

    def visium_assay_terms
      Array(data.dig(:constants, :visium_assay_terms)).map(&:to_s).freeze
    end

    def slide_seq_assay
      data.dig(:constants, :slide_seq_assay).to_s
    end

    def assay_suspension_type_map
      raw = data.dig(:cross_field, :assay_suspension_type_map) || {}
      raw.each_with_object({}) do |(term, values), out|
        out[term.to_s] = Array(values).map(&:to_s)
      end.freeze
    end

    def assay_ancestor_terms
      Array(data.dig(:cross_field, :assay_ancestor_terms)).map(&:to_s).freeze
    end

    def cell_line_forced_fields
      Array(data.dig(:cross_field, :cell_line_forced_fields)).map do |entry|
        entry.deep_symbolize_keys
      end.freeze
    end

    def organism_dev_stage_mapping
      raw = data.dig(:cross_field, :organism_dev_stage_mapping) || {}
      raw.each_with_object({}) { |(org, prefix), h| h[org.to_s] = prefix.to_s }.freeze
    end

    def organism_cell_type_mapping
      raw = data.dig(:cross_field, :organism_cell_type_prefixes) || {}
      raw.each_with_object({}) do |(org, prefixes), hash|
        hash[org.to_s] = Array(prefixes).map(&:to_s)
      end.freeze
    end

    def organism_cell_type_default_prefixes
      Array(data.dig(:cross_field, :organism_cell_type_default_prefixes) || %w[CL]).map(&:to_s).freeze
    end

    def organism_cell_type_prefixes_for(organism)
      organism_cell_type_mapping[organism.to_s] || organism_cell_type_default_prefixes
    end

    def organism_tissue_mapping
      raw = data.dig(:cross_field, :organism_tissue_prefixes) || {}
      raw.each_with_object({}) do |(org, prefixes), hash|
        hash[org.to_s] = Array(prefixes).map(&:to_s)
      end.freeze
    end

    def organism_tissue_default_prefixes
      Array(data.dig(:cross_field, :organism_tissue_default_prefixes) || %w[UBERON]).map(&:to_s).freeze
    end

    def organism_tissue_prefixes_for(organism)
      organism_tissue_mapping[organism.to_s] || organism_tissue_default_prefixes
    end

    def organism_ethnicity_human
      data.dig(:cross_field, :organism_ethnicity_human).to_s
    end

    def organism_ethnicity_prefixes
      Array(data.dig(:cross_field, :organism_ethnicity_prefixes) || %w[HANCESTRO AfPO]).map(&:to_s).freeze
    end

    def organism_ethnicity_special_values
      Array(data.dig(:cross_field, :organism_ethnicity_special_values) || %w[unknown na multiethnic]).map(&:to_s).freeze
    end

    def organism_celegans_sex_organism
      data.dig(:cross_field, :organism_celegans_sex_organism).to_s
    end

    def organism_celegans_sex_terms
      Array(data.dig(:cross_field, :organism_celegans_sex_terms) || %w[PATO:0000384 PATO:0001340]).map(&:to_s).freeze
    end

    def label_pairs
      raw = data[:label_pairs] || {}
      raw.each_with_object({}) { |(term, label), h| h[term.to_s] = label.to_s }.freeze
    end

    def semantic_rules_for(field_name)
      raw = (data[:semantic_rules] || {})[field_name.to_sym]
      return nil if raw.blank?

      resolved = raw.deep_dup
      resolved[:allowed_exact] = resolve_rule_ref(resolved[:allowed_exact]) if resolved.key?(:allowed_exact)
      resolved[:forbidden_exact] = resolve_rule_ref(resolved[:forbidden_exact]) if resolved.key?(:forbidden_exact)
      resolved[:allowed_special_values] = resolve_rule_ref(resolved[:allowed_special_values]) if resolved.key?(:allowed_special_values)
      resolved[:any_roots] = Array(resolved[:any_roots]).map(&:to_s) if resolved[:any_roots]
      resolved[:forbidden_branches] = Array(resolved[:forbidden_branches]).map(&:to_s) if resolved[:forbidden_branches]
      resolved
    end

    def semantic_field_names
      (data[:semantic_rules] || {}).keys.map(&:to_s).freeze
    end

    def checks_for(format)
      checks = checks_catalog(:common).dup
      checks.concat(checks_catalog(:loom_only)) if format.to_s == 'loom'
      checks.concat(checks_catalog(:h5ad_only)) if format.to_s == 'h5ad'
      checks
    end

    def checks_catalog(section)
      Array(data.dig(:checks_catalog, section)).map do |entry|
        {
          id: entry[:id],
          label: entry[:label],
          applies_to: Array(entry[:applies_to]).map(&:to_s)
        }
      end.freeze
    end

    def h5ad_validator_config
      fmt = 'h5ad'
      enum_fields = (data[:enum_fields] || {}).each_with_object({}) do |(field_name, cfg), out|
        out[field_path(fmt, :obs, field_name.to_s)] = Array(cfg[:values]).map(&:to_s)
      end
      {
        'required_obs' => (required_observation_fields + required_observation_labels),
        'required_uns' => required_uns_fields(fmt),
        'ontology_fields' => ontology_paths(fmt),
        'special_values' => allowed_special_values(fmt),
        'enum_fields' => enum_fields
      }
    end

    def resolve_constant_ref(value)
      case value
      when String
        case value
        when 'valid_sex_terms' then valid_sex_term_ids
        when 'sex_special_values' then sex_special_values
        when 'banned_cell_type_terms' then banned_cell_type_terms
        else Array(value)
        end
      when Array
        value.flat_map { |item| resolve_constant_ref(item) }
      else
        Array(value)
      end
    end

    def resolve_rule_ref(value)
      case value
      when String
        resolve_constant_ref(value)
      when Array
        value.flat_map { |item| resolve_rule_ref(item) }
      else
        Array(value)
      end
    end
    private_class_method :resolve_constant_ref, :resolve_rule_ref
  end
end
