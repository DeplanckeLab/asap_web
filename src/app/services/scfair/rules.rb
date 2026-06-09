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

    def spatial_extension_rules
      raw = data[:spatial_extension] || {}
      images_raw = raw[:images] || {}
      array_raw = images_raw[:array] || {}
      hires_dims = images_raw[:hires_max_dimension] || {}
      obsm_raw = raw[:obsm_spatial] || {}
      {
        root_scalar_key: raw.dig(:root_scalar_key).to_s,
        library: symbolize_spatial_section(raw[:library]),
        images: symbolize_spatial_section(images_raw).merge(
          array: {
            dtype: array_raw[:dtype].to_s,
            ndim: array_raw[:ndim].to_i,
            channel_sizes: Array(array_raw[:channel_sizes]).map(&:to_i)
          },
          hires_max_dimension: {
            default: hires_dims[:default].to_i,
            by_assay: hires_dims.except(:default).each_with_object({}) { |(assay, dim), out| out[assay.to_s] = dim.to_i }
          }
        ),
        obsm_spatial: {
          h5ad_key: obsm_raw[:h5ad_key].to_s,
          loom_key: obsm_raw[:loom_key].to_s,
          min_columns: obsm_raw[:min_columns].to_i,
          dtype_kinds: Array(obsm_raw[:dtype_kinds]).map(&:to_s),
          required_when_is_single: obsm_raw[:required_when_is_single] == true
        },
        scalefactors: symbolize_spatial_section(raw[:scalefactors])
      }.freeze
    end

    def perturb_extension_rules
      raw = data[:perturb_extension] || {}
      entry_keys = raw[:perturbation_entry_keys] || {}
      {
        obs_fields: Array(raw[:obs_fields]).map(&:to_s).freeze,
        uns_root_key: raw[:uns_root_key].to_s,
        allowed_organisms: Array(raw[:allowed_organisms]).map(&:to_s).freeze,
        strategy_values: Array(raw[:strategy_values]).map(&:to_s).freeze,
        strategy_no_perturbations: raw[:strategy_no_perturbations].to_s,
        role_values: Array(raw[:role_values]).map(&:to_s).freeze,
        curator_required_keys: Array(entry_keys[:curator_required]).map(&:to_s).freeze,
        optional_keys: Array(entry_keys[:optional]).map(&:to_s).freeze,
        id_delimiter: raw[:id_delimiter].to_s
      }.freeze
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

    def metadata_rules
      raw = data[:metadata_rules] || {}
      {
        forbidden_name_prefix: raw[:forbidden_name_prefix].to_s,
        skip_column_names: Array(raw[:skip_column_names]).map(&:to_s).freeze,
        unique_layers: Array(raw[:unique_layers]).map(&:to_s).freeze,
        deprecated_names: Array(raw[:deprecated_names]).map do |entry|
          {
            name: entry[:name].to_s,
            layer: entry[:layer].to_s,
            deprecated_in: entry[:deprecated_in].to_s
          }
        end.freeze
      }.freeze
    end

    def metadata_column_list_key(layer)
      "metadata/#{layer}/columns"
    end

    def compliance_field_value_paths(format)
      fmt = format.to_s
      spatial_obs = %w[in_tissue array_row array_col]
      perturb_obs = perturb_extension_rules[:obs_fields]
      cross_field_obs = %w[tissue_type suspension_type donor_id is_primary_data] + spatial_obs + perturb_obs

      if fmt == 'loom'
        (
          required_uns_fields('loom').map { |name| field_path('loom', :uns, name) } +
          required_observation_fields.map { |name| field_path('loom', :obs, name) } +
          required_observation_labels.map { |name| field_path('loom', :obs, name) } +
          cross_field_obs.map { |name| field_path('loom', :obs, name) } +
          [field_path('loom', :uns, 'spatial/is_single')]
        ).uniq
      elsif fmt == 'h5ad'
        (
          cross_field_obs.map { |name| field_path('h5ad', :obs, name) } +
          [field_path('h5ad', :uns, 'spatial/is_single')]
        ).uniq
      else
        []
      end
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
          label: entry[:label]
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
        'enum_fields' => enum_fields,
        'label_pairs' => label_pairs
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
    def symbolize_spatial_section(section)
      section ||= {}
      {
        allowed_keys: Array(section[:allowed_keys]).map(&:to_s),
        required_when_visium_is_single: Array(section[:required_when_visium_is_single]).map(&:to_s)
      }
    end
    private_class_method :symbolize_spatial_section

    private_class_method :resolve_constant_ref, :resolve_rule_ref
  end
end
