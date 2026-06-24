# frozen_string_literal: true

require 'yaml'

module Scfair
  # One loaded rules.yaml bundle (config/scfair/<version>/rules.yaml).
  class RulesBundle
    PRESENCE_CHECK_IDS = %w[obs.required_presence uns.required_presence var.required].freeze
    ONTOLOGY_FORMAT_CHECK_ID = 'ontology.format'
    DEFAULT_CHECK_FORMATS = %w[h5ad loom].freeze
    CF8_RULE_KEY = 'CF-8'
    CF9_RULE_KEY = 'CF-9'

    @bundle_caches = {}

    def self.clear_caches!
      @bundle_caches = {}
    end

    def initialize(schema_id)
      @registry_schema_id = RulesRegistry.normalize_schema_id(schema_id)
      entry = RulesRegistry.entry_for(@registry_schema_id)
      @rules_path = entry.path
      @rules_relative_path = @rules_path.relative_path_from(Rails.root).to_s
      @data = nil
      @_rules_file_mtime = nil
      @checks_registry = nil
    end

    attr_reader :registry_schema_id, :rules_path, :rules_relative_path

    def reload!
      @data = nil
      @_rules_file_mtime = nil
      @checks_registry = nil
      load!
    end

    def reload_if_stale!
      return unless defined?(Rails) && Rails.env.development?
      return unless File.exist?(rules_path)

      mtime = File.mtime(rules_path)
      return if defined?(@_rules_file_mtime) && @_rules_file_mtime == mtime

      @_rules_file_mtime = mtime
      @data = nil
    end

    def load!
      raw = YAML.safe_load_file(rules_path.to_s, aliases: true)
      raise "Missing scFAIR rules file: #{rules_path}" if raw.blank?

      @_rules_file_mtime = File.mtime(rules_path) if File.exist?(rules_path)
      @data = raw.deep_symbolize_keys
    end

    def data
      reload_if_stale!
      @data ||= load!
    end

    def obs_field_name_from_path(path)
      path.to_s.split('/').reject(&:blank?).last.to_s
    end

    # Paths used in validation messages for a compliance field group term_path.
    # Includes loom/h5ad metadata paths and stable check ids (e.g. uns.ensembl.release).
    def compliance_field_message_paths(term_path)
      path = term_path.to_s
      return [] if path.blank?

      paths = [path]
      field = obs_field_name_from_path(path)
      uns_path = field_path('h5ad', :uns, field)
      paths << uns_path unless paths.include?(uns_path)

      case field
      when 'ensembl_release'
        paths << 'uns.ensembl.release'
      when 'ensembl_database'
        paths << 'uns.ensembl.database'
      when 'ensembl_assembly'
        paths << 'uns.ensembl.assembly'
      end

      paths.uniq
    end

    def schema_id
      data.dig(:schema, :id).to_s
    end

    def schema_config
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

    def multi_value_delimiter
      data.fetch(:multi_value_delimiter).to_s
    end

    def split_multi_value(raw)
      raw.to_s.split(multi_value_delimiter).map(&:strip).reject(&:blank?)
    end

    def join_multi_value(values)
      Array(values).map(&:to_s).reject(&:blank?).join(multi_value_delimiter)
    end

    def multi_value?(value)
      value.to_s.include?(multi_value_delimiter)
    end

    def multi_value_fields_config
      raw = (data[:multi_value_fields] || {}).deep_symbolize_keys
      fields = (raw[:fields] || {}).each_with_object({}) do |(name, cfg), out|
        out[name.to_s] = cfg.deep_symbolize_keys.freeze
      end.freeze
      {
        requirement: raw[:requirement].to_s,
        schema_reference: raw[:schema_reference].to_s,
        fields: fields
      }.freeze
    end

    def multi_value_field_names
      multi_value_fields_config[:fields].keys.freeze
    end

    def multi_value_field?(field_name)
      multi_value_fields_config[:fields].key?(field_name.to_s)
    end

    def multi_value_sorted_field?(field_name)
      cfg = multi_value_fields_config[:fields][field_name.to_s]
      cfg.present? && cfg[:sorted] != false
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

    def required_obs_fields
      Array(data.dig(:required, :obs)).map(&:to_s).freeze
    end

    def required_uns_fields(_format = nil)
      Array(data.dig(:required, :uns)).map(&:to_s).freeze
    end

    def optional_uns_fields
      Array(data.dig(:optional, :uns)).map(&:to_s).freeze
    end

    def required_var_fields
      Array(data.dig(:required, :var)).map(&:to_s).freeze
    end

    def required_field_yaml_path(layer, field_name)
      fields = case layer.to_sym
               when :obs then required_obs_fields
               when :uns then required_uns_fields
               when :var then required_var_fields
               else return nil
               end
      idx = fields.index(field_name.to_s)
      idx ? "required.#{layer}.#{idx}" : nil
    end

    def presence_field_metadata_yaml_path(layer, field_name)
      meta = data.dig(:presence_field_metadata, layer.to_sym, field_name.to_sym)
      return nil if meta.blank?

      "presence_field_metadata.#{layer}.#{field_name}"
    end

    def field_declarative_yaml_paths(layer, field_name)
      layer = layer.to_sym
      field_name = field_name.to_s
      paths = []

      req_path = required_field_yaml_path(layer, field_name)
      paths << { label: 'Required field', value: field_name, path: req_path } if req_path

      lp = label_pairs[field_name]
      if lp.present?
        paths << { label: 'Paired label field', value: lp, path: "label_pairs.#{field_name}" }
      end

      if enum_field_values(field_name).any?
        paths << { label: 'Allowed values', value: enum_field_values(field_name).join(', '), path: "enum_fields.#{field_name}.values" }
      end

      if ontology_field(field_name).present?
        paths << { label: 'Ontology field config', value: field_name, path: "ontology_fields.#{field_name}" }
      end

      field_constraint_entries(layer, field_name).each_with_index do |entry, idx|
        paths << {
          label: entry[:label].presence || 'Requirement',
          value: field_constraint_display_value(entry),
          path: "field_constraints.#{layer}.#{field_name}.#{idx}"
        }
      end

      paths
    end

    def anndata_index(layer)
      raw = (data[:anndata_indices] || {})[layer.to_sym] || {}
      fmt_h5ad = raw[:h5ad] || {}
      fmt_loom = raw[:loom] || {}
      validation = raw[:validation] || {}
      {
        schema: raw[:schema].to_s,
        description: raw[:description].to_s,
        h5ad: {
          logical: fmt_h5ad[:logical].to_s.presence || fmt_h5ad[:path].to_s,
          path: fmt_h5ad[:path].to_s,
          storage_keys: Array(fmt_h5ad[:storage_keys]).map(&:to_s).freeze
        },
        loom: {
          logical: fmt_loom[:logical].to_s.presence || fmt_loom[:path].to_s,
          path: fmt_loom[:path].to_s,
          storage_keys: Array(fmt_loom[:storage_keys]).map(&:to_s).freeze,
          manifest_key: fmt_loom[:manifest_key].to_s
        },
        validation: validation.each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }.freeze
      }.freeze
    end

    def var_index_config
      anndata_index(:var)
    end

    def var_index_schema_field
      var_index_config[:schema].presence || 'var.index'
    end

    def var_index_logical_path(format)
      cfg = var_index_config
      fmt = format.to_s == 'loom' ? cfg[:loom] : cfg[:h5ad]
      fmt[:logical].presence || fmt[:path]
    end

    def var_index_file_path(format)
      cfg = var_index_config
      format.to_s == 'loom' ? cfg[:loom][:path] : cfg[:h5ad][:path]
    end

    def var_index_column_keys(format)
      cfg = var_index_config
      fmt = format.to_s == 'loom' ? cfg[:loom] : cfg[:h5ad]
      Array(fmt[:storage_keys]).map(&:to_s).freeze
    end

    def var_index_presence_path(format)
      cfg = var_index_config
      path = format.to_s == 'loom' ? cfg[:loom][:path] : cfg[:h5ad][:path]
      path.presence || field_path(format, :var, '_index')
    end

    def var_index_manifest_key
      var_index_config.dig(:loom, :manifest_key).to_s
    end

    def var_index_ensembl_prefix
      var_index_config.dig(:validation, 'ensembl_prefix').to_s.presence || 'ENS'
    end

    def var_index_covid_organism_term
      var_index_config.dig(:validation, 'covid_organism_term').to_s
    end

    def var_index_field?(field)
      field.to_s == var_index_schema_field ||
        field.to_s.start_with?('var.index') ||
        field.to_s.match?(/\A(var\/_index|var\/index|var@_index|\/row_attrs\/(_index|index|feature_id))\z/)
    end

    def ensembl_database_values
      Array(data.dig(:constants, :ensembl_database_values)).map(&:to_s).freeze
    end

    def feature_reference_taxa
      raw = data.dig(:constants, :feature_reference_taxa) || {}
      raw.each_with_object({}) { |(id, label), h| h[id.to_s] = label.to_s }.freeze
    end

    def experimental_condition_rules
      raw = data[:experimental_condition_rules] || {}
      {
        id_field: raw[:id_field].to_s,
        label_field: raw[:label_field].to_s,
        perturbation_types_field: raw[:perturbation_types_field].to_s,
        genetic_perturbation_id_field: raw[:genetic_perturbation_id_field].to_s,
        na_value: raw[:na_value].to_s,
        no_perturbations_value: raw[:no_perturbations_value].to_s,
        delimiter: raw[:delimiter].to_s
      }.freeze
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

    def ontology_term_format_config
      raw = data[:ontology_term_formats] || {}
      obo = raw[:obo] || {}
      cellosaurus = raw[:cellosaurus] || {}
      {
        obo_pattern: Regexp.new(obo[:pattern].to_s),
        obo_requirement: obo[:requirement].to_s,
        obo_example: obo[:example].to_s,
        obo_invalid_message: obo[:invalid_message].to_s,
        cellosaurus_prefix: cellosaurus[:identifier_prefix].to_s,
        cellosaurus_requirement: cellosaurus[:requirement].to_s,
        cellosaurus_example: cellosaurus[:example].to_s,
        cellosaurus_disallowed_message: cellosaurus[:disallowed_message].to_s,
        combined_requirement: raw[:combined_requirement].to_s
      }.freeze
    end

    def ontology_allows_cellosaurus_format?(field_name)
      ontology_prefixes(field_name).include?('CVCL')
    end

    def ontology_format_example(field_name)
      example = ontology_field(field_name)[:format_example]
      return example.to_s if example.present?

      ontology_term_format_config[:obo_example]
    end

    def ontology_format_requirement_text(field_name)
      cfg = ontology_term_format_config
      template = ontology_allows_cellosaurus_format?(field_name) ? cfg[:combined_requirement] : cfg[:obo_requirement]
      format(template, example: ontology_format_example(field_name))
    end

    def ontology_format_requirement_rules_path(field_name)
      ontology_allows_cellosaurus_format?(field_name) ? 'ontology_term_formats.combined_requirement' : 'ontology_term_formats.obo.requirement'
    end

    def cellosaurus_ontology_term?(term)
      term.to_s.start_with?(ontology_term_format_config[:cellosaurus_prefix])
    end

    def obo_ontology_term_format?(term)
      ontology_term_format_config[:obo_pattern].match?(term.to_s)
    end

    def valid_ontology_term_identifier_format?(term, field_name)
      term = term.to_s.strip
      return ontology_allows_cellosaurus_format?(field_name) if cellosaurus_ontology_term?(term)

      obo_ontology_term_format?(term)
    end

    def ontology_format_error_message(term, field_name)
      cfg = ontology_term_format_config
      term = term.to_s.strip
      if cellosaurus_ontology_term?(term)
        return format(cfg[:cellosaurus_disallowed_message], term: term) unless ontology_allows_cellosaurus_format?(field_name)

        return nil
      end

      return nil if obo_ontology_term_format?(term)

      format(cfg[:obo_invalid_message], term: term, example: ontology_format_example(field_name))
    end

    def ontology_prefixes(field_name)
      Array(ontology_field(field_name)[:prefixes]).map(&:to_s).freeze
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
      ontology_valid_terms('sex_ontology_term_id')
    end

    def valid_sex_term_ids
      valid_sex_terms.keys.freeze
    end

    def sex_special_values
      special_values_for_field('h5ad', 'sex_ontology_term_id')
    end

    def ontology_valid_terms(field_name)
      raw = ontology_field(field_name)[:valid_terms] || {}
      raw.each_with_object({}) { |(id, name), h| h[id.to_s] = name.to_s }.freeze
    end

    def banned_cell_type_terms
      ontology_banned_terms('cell_type_ontology_term_id')
    end

    def ontology_banned_terms(field_name)
      Array(ontology_field(field_name)[:banned_terms]).map(&:to_s).freeze
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
        scalefactors: symbolize_spatial_section(raw[:scalefactors]),
        obs: spatial_extension_obs_rules,
        display: spatial_extension_display_rules
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
      raw = cross_field_rule_by_key('CF-1')&.dig(:mapping, :suspension_by_assay_ontology_term_id)
      raw = data.dig(:cross_field, :assay_suspension_type_map) if raw.blank?
      raw ||= {}
      raw.each_with_object({}) do |(term, values), out|
        out[term.to_s] = Array(values).map(&:to_s)
      end.freeze
    end

    def assay_ancestor_terms
      terms = cross_field_rule_by_key('CF-1')&.dig(:mapping, :accept_descendants_of_assay_ontology_term_id)
      terms = data.dig(:cross_field, :assay_ancestor_terms) if terms.blank?
      Array(terms).map(&:to_s).freeze
    end

    def cell_line_forced_fields
      raw = Array(data.dig(:cross_field, :cell_line_forced_fields))
      raw.map do |entry|
        entry = entry.deep_symbolize_keys
        {
          field: entry[:field].to_s,
          value: entry[:value].to_s,
          label_field: entry[:label_field].to_s.presence,
          label_value: entry[:label_value].to_s.presence
        }.compact
      end.freeze
    end

    def tissue_type_cell_line_value
      enum_field_values('tissue_type').find { |v| v == 'cell line' } || 'cell line'
    end

    def fix_form_cross_field_messages
      raw = (data.dig(:cross_field, :fix_form) || {}).deep_symbolize_keys
      {
        assay_suspension_lock_reason: raw.fetch(:assay_suspension_lock_reason).to_s,
        assay_suspension_restrict_message: raw.fetch(:assay_suspension_restrict_message).to_s,
        assay_suspension_restrict_detail: raw.fetch(:assay_suspension_restrict_detail).to_s
      }.freeze
    end

    def cross_field_cell_line_forced_rule_keys
      %w[CF-2a CF-2b CF-2c CF-2d CF-2e].freeze
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

    def organism_specific_mappings_yaml_path(*parts)
      ['cross_field', *parts.map(&:to_s)].join('.')
    end

    def label_pairs
      raw = data[:label_pairs] || {}
      raw.each_with_object({}) { |(term, label), h| h[term.to_s] = label.to_s }.freeze
    end

    def label_pair_validation_config
      raw = data[:label_pair_validation] || {}
      {
        check_prefix: raw[:check_prefix].to_s,
        organism_id_field: raw[:organism_id_field].to_s,
        messages: (raw[:messages] || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_s }.freeze,
        display: (raw[:display] || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_s }.freeze
      }.freeze
    end

    def obs_label_pair_fields
      organism_field = label_pair_validation_config[:organism_id_field]
      label_pairs.reject { |id_field, _| id_field == organism_field }.freeze
    end

    def obs_label_pair_check_field(id_field)
      "#{label_pair_validation_config[:check_prefix]}.#{id_field}"
    end

    def label_pair_message(key, **kwargs)
      template = label_pair_validation_config.dig(:messages, key.to_s).to_s
      kwargs.empty? ? template : format(template, **kwargs)
    end

    def label_pair_pass_message(id_field, label_field, format: 'h5ad')
      label_pair_message(:pass, **label_pair_paths(id_field, label_field, format))
    end

    def label_pair_skip_message(id_field, format: 'h5ad')
      label_pair_message(:skipped, id_path: field_path(format, :obs, id_field))
    end

    def label_pair_missing_label_message(id_field, label_field, format: 'h5ad')
      label_pair_message(:fail_missing_label, **label_pair_paths(id_field, label_field, format))
    end

    def label_pair_count_mismatch_message(id_field, label_field, format: 'h5ad')
      label_pair_message(:fail_count_mismatch, **label_pair_paths(id_field, label_field, format))
    end

    def label_pair_paths(id_field, label_field, format)
      {
        id_path: field_path(format, :obs, id_field),
        label_path: field_path(format, :obs, label_field)
      }
    end

    def label_pair_special_mismatch_message(id_val, label_val)
      label_pair_message(:fail_special_mismatch, id_val: id_val, label_val: label_val)
    end

    def label_pair_mismatch_message(id_val, expected, label_val)
      label_pair_message(:fail_mismatch, id_val: id_val, expected: expected, label_val: label_val)
    end

    def label_pair_check_detail(id_field)
      label_field = label_pairs[id_field].to_s
      display = label_pair_validation_config[:display]
      {
        title: format(display['pair_title_template'], id_field: id_field, label_field: label_field),
        summary: format(display['pair_summary_template'], id_field: id_field, label_field: label_field)
      }.freeze
    end

    def semantic_rules_for(field_name)
      field_cfg = ontology_field(field_name)
      raw = (data[:semantic_rules] || {})[field_name.to_sym]
      resolved = raw ? raw.deep_dup : {}
      apply_ontology_field_semantic_defaults!(resolved, field_cfg)
      return nil if resolved.blank?

      resolved[:allowed_exact] = resolve_rule_ref(resolved[:allowed_exact]) if resolved.key?(:allowed_exact)
      resolved[:forbidden_exact] = resolve_rule_ref(resolved[:forbidden_exact]) if resolved.key?(:forbidden_exact)
      resolved[:allowed_special_values] = resolve_rule_ref(resolved[:allowed_special_values]) if resolved.key?(:allowed_special_values)
      resolved[:any_roots] = Array(resolved[:any_roots]).map(&:to_s) if resolved[:any_roots]
      resolved[:forbidden_branches] = Array(resolved[:forbidden_branches]).map(&:to_s) if resolved[:forbidden_branches]
      resolved
    end

    def semantic_field_names
      explicit = (data[:semantic_rules] || {}).keys.map(&:to_s)
      from_valid_terms = ontology_fields.select { |_, cfg| cfg[:valid_terms].present? }.keys.map(&:to_s)
      (explicit + from_valid_terms).uniq.freeze
    end

    def check_detail_for_field(field_id)
      label_pair = obs_label_pair_check_detail(field_id)
      return label_pair if label_pair.present?

      cross = cross_field_check_detail(field_id)
      return cross if cross.present?

      entry = check_entry(field_id.to_s)
      return nil unless entry&.dig(:kind) == 'check'

      {
        title: entry[:title].presence || entry[:label],
        summary: entry[:summary],
        checks: entry[:checks]
      }.freeze
    end

    def obs_label_pair_check_detail(field_id)
      prefix = label_pair_validation_config[:check_prefix]
      return nil unless field_id.to_s.start_with?("#{prefix}.")

      id_field = field_id.to_s.delete_prefix("#{prefix}.")
      return nil unless obs_label_pair_fields.key?(id_field)

      detail = label_pair_check_detail(id_field)
      {
        title: detail[:title],
        summary: detail[:summary],
        checks: category_checks_list(prefix)
      }.freeze
    end

    def cross_field_check_detail(field_id)
      field_id = field_id.to_s
      return nil unless field_id.start_with?('cross-field.')

      rule_id = field_id.delete_prefix('cross-field.')
      rule = cross_field_rule_by_id(rule_id)
      return nil if rule.blank?

      {
        title: rule[:title],
        summary: rule[:summary].presence || format(rule[:summary_template].to_s, id_field: rule.dig(:mapping, :id_field), label_field: rule.dig(:mapping, :label_field)),
        checks: rule[:checks]
      }.freeze
    end

    def category_summary(key)
      check_entry(key)&.dig(:summary).to_s.presence
    end

    def category_summary?(key)
      category_summary(key).present?
    end

    def category_checks_list(category_id)
      Array(check_entry(category_id)&.dig(:checks)).map(&:to_s).freeze
    end

    def checks_registry
      @checks_registry ||= build_checks_registry.freeze
    end

    def check_entry(check_id)
      checks_registry[check_id.to_s]
    end

    def check_message(check_id, code, format: 'h5ad', **kwargs)
      messages = check_entry(check_id)&.dig(:messages) || {}
      raw = messages[code.to_s]
      template = case raw
                 when Hash
                   raw[format.to_s].presence || raw['default'].to_s
                 else
                   raw.to_s
                 end
      return kwargs[:default].to_s if template.blank?

      kwargs.empty? ? template : format(template, **kwargs)
    rescue KeyError
      template.to_s
    end

    def presence_check_id_for_field(field, _format = 'h5ad')
      path = field.to_s
      return 'var.required' if path.start_with?('var/') || path.start_with?('/row_attrs/')
      return 'uns.required_presence' if path.start_with?('uns/') || path.start_with?('/attrs/')

      'obs.required_presence'
    end

    def presence_check_id?(check_id)
      PRESENCE_CHECK_IDS.include?(check_id.to_s)
    end

    def ontology_format_check_id?(check_id)
      check_id.to_s == ONTOLOGY_FORMAT_CHECK_ID
    end

    def build_checks_registry
      registry = {}
      raw = data[:checks] || {}
      category_ids = raw.each_key.map(&:to_s).reject { |k| k == 'catalog' }.to_set

      raw.each do |key, cfg|
        next if key.to_s.in?(%w[catalog _defaults])
        next unless cfg.is_a?(Hash)

        cat_id = key.to_s
        registry[cat_id] = normalize_category_entry(cat_id, cfg)

        child_checks = cfg[:checks]
        next unless child_checks.is_a?(Hash)

        child_checks.each do |check_key, check_cfg|
          next unless check_cfg.is_a?(Hash)

          nested_key = check_key.to_s
          full_id = flatten_child_check_id(cat_id, nested_key, check_cfg, category_ids)
          registry[full_id] = normalize_check_entry(full_id, check_cfg, category: cat_id, nested_key: nested_key)
        end
      end

      generate_presence_check_entries(registry, category_ids)

      registry
    end

    PRESENCE_LAYER_CATEGORIES = {
      obs: 'obs.required_presence',
      uns: 'uns.required_presence',
      var: 'var.required'
    }.freeze

    PRESENCE_BASE_CHECK_TEMPLATES = {
      obs: 'Verifies required observation column %{path} is present',
      uns: 'Field must be present in uns (H5AD) or /attrs (Loom)',
      var: 'Column must be present in var (H5AD) or row_attrs (Loom)'
    }.freeze

    def generate_presence_check_entries(registry, category_ids)
      PRESENCE_LAYER_CATEGORIES.each do |layer, category_id|
        fields = send("required_#{layer}_fields")
        field_metadata = data.dig(:presence_field_metadata, layer) || {}

        fields.each do |field_name|
          full_id = resolve_presence_entry_id(layer, field_name, category_ids)
          next if registry.key?(full_id)

          meta = field_metadata[field_name.to_sym] || {}
          checks = build_presence_checks_performed(layer, field_name, meta)
          summary = presence_field_summary(layer, field_name, meta)

          registry[full_id] = {
            id: full_id,
            kind: 'check',
            label: full_id.tr('.', ' '),
            title: '',
            category: category_id,
            nested_key: field_name,
            formats: [],
            summary: summary,
            checks: checks,
            messages: {},
            layer: layer.to_s,
            field: field_name,
            generated: true
          }
        end

        generate_presence_rollup(registry, category_id, layer, fields)
      end
    end

    def resolve_presence_entry_id(layer, field_name, category_ids)
      base = "#{layer}.#{field_name}"
      category_ids.include?(base) ? "#{base}.field" : base
    end

    def build_presence_checks_performed(layer, field_name, meta)
      req_path = required_field_yaml_path(layer, field_name)
      checks = [{
        text: PRESENCE_BASE_CHECK_TEMPLATES[layer],
        from_rules: true,
        rules_path: req_path
      }]

      extra = Array(meta[:extra_checks])
      meta_path = presence_field_metadata_yaml_path(layer, field_name)
      extra.each_with_index do |c, idx|
        checks << {
          text: c.to_s,
          from_rules: true,
          rules_path: meta_path ? "#{meta_path}.extra_checks.#{idx}" : nil
        }
      end

      label = label_pairs[field_name]
      if label.present? && extra.none? { |c| c.to_s.include?(label) }
        lp_path = "label_pairs.#{field_name}"
        checks << {
          text: "Paired label column %{label_path} is required for this ontology ID field",
          from_rules: true,
          rules_path: lp_path
        }
      end

      values = enum_field_values(field_name)
      if values.any? && extra.none? { |c| c.to_s.include?('must be one of') }
        enum_path = "enum_fields.#{field_name}"
        checks << {
          text: "Values must be one of: %{allowed_values}",
          from_rules: true,
          rules_path: enum_path
        }
      end

      checks
    end

    def presence_field_summary(layer, field_name, meta)
      raw = meta[:summary].to_s
      return raw if raw.present?

      default_key = { obs: :required_observation, uns: :required_uns, var: :required_var }[layer]
      default_summary_text(default_key) || ''
    end

    def generate_presence_rollup(registry, category_id, layer, fields)
      entry = registry[category_id]
      return unless entry && entry[:checks].blank?

      entry[:checks] = ["Each required #{layer} field is validated individually"] +
        fields.map { |f| "#{f} (#{layer})" }
    end

    def flatten_child_check_id(category_id, key, cfg, category_ids)
      layer = cfg[:layer].to_s
      field = cfg[:field].to_s
      if layer.present? && field.present?
        base = "#{layer}.#{field}"
        return "#{base}.field" if category_ids.include?(base)
        return base
      end

      "#{category_id}.#{key}"
    end

    def normalize_check_formats(formats)
      listed = Array(formats).map(&:to_s).reject(&:blank?)
      listed.presence || DEFAULT_CHECK_FORMATS
    end

    def normalize_category_entry(id, cfg)
      semantic = cfg[:semantic_labels] || {}
      {
        id: id,
        kind: 'category',
        label: cfg[:label].to_s.presence || id.tr('.', ' '),
        formats: normalize_check_formats(cfg[:formats]),
        summary: cfg[:summary].to_s,
        checks: Array(cfg[:rollup] || cfg[:checks_performed]).map(&:to_s),
        messages: normalize_messages(cfg[:messages] || {}),
        semantic_titles: (semantic[:titles] || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s },
        semantic_summaries: (semantic[:summaries] || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
      }
    end

    def normalize_check_entry(id, cfg, category:, nested_key: nil)
      {
        id: id,
        kind: 'check',
        label: cfg[:label].to_s.presence || cfg[:title].to_s.presence || id.tr('.', ' '),
        title: cfg[:title].to_s,
        category: category.to_s,
        nested_key: nested_key.to_s,
        formats: [],
        summary: cfg[:summary].to_s,
        checks: Array(cfg[:checks_performed]).map(&:to_s),
        messages: normalize_messages(cfg[:messages] || {}),
        layer: cfg[:layer].to_s,
        field: cfg[:field].to_s
      }
    end

    def check_yaml_path(check_id)
      entry = check_entry(check_id)
      return nil if entry.blank?

      if entry[:kind] == 'category'
        return "checks.#{check_id}.rollup" if entry[:checks].present?

        return nil
      end

      return nil if entry[:generated]

      cat = entry[:category]
      key = entry[:nested_key].presence || entry[:field].presence || check_id.to_s.delete_prefix("#{cat}.")
      "checks.#{cat}.checks.#{key}.checks_performed"
    end

    def normalize_messages(messages)
      messages.each_with_object({}) do |(code, template), out|
        out[code.to_s] = if template.is_a?(Hash)
                           template.each_with_object({}) { |(fmt, text), h| h[fmt.to_s] = text.to_s }
                         else
                           template.to_s
                         end
      end
    end

    def checks_for(format)
      fmt = format.to_s
      catalog = data.dig(:checks, :catalog) || {}
      ids = Array(catalog[:common]).map(&:to_s)
      ids.concat(Array(catalog[:loom_only]).map(&:to_s)) if fmt == 'loom'
      ids.concat(Array(catalog[:h5ad_only]).map(&:to_s)) if fmt == 'h5ad'

      ids.filter_map do |id|
        entry = check_entry(id)
        next unless entry&.dig(:kind) == 'category'

        { id: id, label: entry[:label] }
      end.freeze
    end

    def field_check_entry(layer, field_name)
      id = "#{layer}.#{field_name}"
      entry = check_entry(id)
      return entry if entry&.dig(:kind) == 'check'

      check_entry("#{id}.field")
    end

    def metadata_other_detail(field)
      field = field.to_s
      return nil unless field.start_with?('metadata.other.')

      entry = check_entry(field)
      return nil unless entry&.dig(:kind) == 'category'

      {
        title: entry[:label],
        summary: entry[:summary],
        checks: entry[:checks]
      }.freeze
    end

    def spatial_rollup_checks
      Array(check_entry('extension.spatial')&.dig(:checks)).map(&:to_s).freeze
    end

    def layer_field_checks(layer, field_name, format: 'h5ad')
      entry = field_check_entry(layer, field_name)
      return [] if entry.blank? || entry[:checks].blank?

      entry[:checks].map { |item| interpolate_layer_field_check(item, layer, field_name, format) }.freeze
    end

    def interpolate_layer_field_check(item, layer, field_name, format)
      if item.is_a?(Hash)
        text = item[:text].to_s
        interpolated = interpolate_check_text(text, layer, field_name, format)
        return item.merge(text: interpolated)
      end

      interpolate_check_text(item.to_s, layer, field_name, format)
    end

    def interpolate_check_text(text, layer, field_name, format)
      return text unless text.include?('%{')

      path = field_path(format, layer, field_name)
      label_field = label_pairs[field_name]
      label_path = label_field.present? ? field_path(format, layer, label_field) : ''
      allowed_values = enum_field_values(field_name).join(', ')
      format(text, path: path, label_path: label_path, allowed_values: allowed_values)
    end

    def extension_field_checks(field)
      entry = check_entry(field.to_s)
      return [] unless entry

      Array(entry[:checks]).map(&:to_s).freeze
    end

    def semantic_check_title(suffix)
      return nil if suffix.blank?

      check_entry('ontology.semantics')&.dig(:semantic_titles, suffix.to_s).to_s.presence
    end

    def semantic_check_summary(suffix)
      return nil if suffix.blank?

      check_entry('ontology.semantics')&.dig(:semantic_summaries, suffix.to_s).to_s.presence
    end

    def field_summary_text(layer, field_name)
      summary = field_check_entry(layer, field_name)&.dig(:summary).to_s
      return nil if summary.blank?

      summary.include?('%{') ? format(summary, schema_version: schema_version) : summary
    end

    def default_summary_text(key)
      template = data.dig(:checks, :_defaults, key.to_sym).to_s
      return nil if template.blank?

      format(template, schema_version: schema_version)
    end

    def cross_field_validation
      raw = data.dig(:cross_field, :validation) || {}
      rules = (raw[:rules] || {}).each_with_object({}) do |(key, cfg), out|
        out[key.to_s] = normalize_cross_field_rule(key.to_s, cfg.deep_symbolize_keys)
      end.freeze
      id_to_key = rules.each_with_object({}) { |(_key, rule), hash| hash[rule[:id]] = rule[:key] }.freeze

      {
        not_applicable: raw[:not_applicable].to_s,
        skip_not_cell_line_template: raw[:skip_not_cell_line_template].to_s,
        grouper_message_pattern: raw[:grouper_message_pattern].to_s,
        rules: rules,
        id_to_key: id_to_key
      }.freeze
    end

    def cross_field_rule_keys
      cross_field_validation[:rules].keys.freeze
    end

    def cross_field_rule_by_key(key)
      cross_field_validation[:rules][key.to_s]
    end

    def cross_field_rule_by_id(rule_id)
      key = cross_field_validation[:id_to_key][rule_id.to_s]
      key.present? ? cross_field_rule_by_key(key) : nil
    end

    def cross_field_rule_id(key)
      cross_field_rule_by_key(key)&.dig(:id).to_s
    end

    def cross_field_rule_field(key)
      cross_field_rule_by_key(key)&.dig(:field).to_s
    end

    def cross_field_rules_yaml_path(key, *parts)
      ['cross_field', 'validation', 'rules', key.to_s, *parts.map(&:to_s)].join('.')
    end

    def cross_field_cell_line_checks
      cross_field_validation[:rules].values
                                    .select { |rule| rule[:key].start_with?('CF-2') }
                                    .map do |rule|
        {
          key: rule[:key],
          id: rule[:id],
          token: rule[:token],
          skip_detail: rule[:messages]['skip_detail'],
          pass: rule[:messages]['pass'],
          fail: rule[:messages]['fail']
        }
      end.freeze
    end

    def cross_field_rule_check_messages(rule_id)
      rule = cross_field_rule_by_id(rule_id)
      return {} if rule.blank?

      rule[:messages].transform_keys(&:to_sym)
    end

    def cross_field_rule_message(rule_id, status, **kwargs)
      cross_field_rule_message_for_key(cross_field_validation[:id_to_key][rule_id.to_s], status, **kwargs)
    end

    def cross_field_rule_message_for_key(key, status, **kwargs)
      rule = cross_field_rule_by_key(key)
      template = rule&.dig(:messages, status.to_s).to_s
      kwargs.empty? ? template : format(template, **kwargs)
    end

    def cross_field_rule_config(rule_id)
      cross_field_rule_by_id(rule_id) || {}
    end

    def cross_field_cf8_message(key, **kwargs)
      cross_field_rule_message_for_key(CF8_RULE_KEY, key, **kwargs)
    end

    def cross_field_cf9_message(key, **kwargs)
      cross_field_rule_message_for_key(CF9_RULE_KEY, key, **kwargs)
    end

    def cross_field_not_applicable_message
      cross_field_validation[:not_applicable]
    end

    def cross_field_skip_not_cell_line_message(detail:)
      format(cross_field_validation[:skip_not_cell_line_template], detail: detail)
    end

    def cross_field_organoid_embryo_term
      cross_field_rule_by_key('CF-4')&.dig(:mapping, :forbidden_term).to_s
    end

    def cross_field_grouper_message_pattern
      Regexp.new(cross_field_validation[:grouper_message_pattern], Regexp::IGNORECASE)
    end

    def cross_field_violation_message(rule_key, format:, **kwargs)
      violation = cross_field_rule_by_key(rule_key)&.dig(:violation)
      return {} if violation.blank?

      template = violation[:template].to_s
      field_name = violation[:field].to_s
      obs_path = field_path(format, :obs, field_name)
      message = kwargs.empty? ? template : format(template, **kwargs)
      severity = violation[:severity].to_s == 'warning' ? :warning : :error
      { field: obs_path, severity: severity, message: message }
    end

    def organism_specific_validation_config
      raw = data[:organism_specific_validation] || {}
      {
        check_prefix: raw[:check_prefix].to_s,
        special_values: (raw[:special_values] || {}).each_with_object({}) do |(rule, values), out|
          out[rule.to_s] = Array(values).map(&:to_s).freeze
        end.freeze,
        skip_messages: (raw[:skip_messages] || {}).each_with_object({}) do |(rule, messages), out|
          out[rule.to_s] = messages.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value.to_s }.freeze
        end.freeze,
        pass_messages: (raw[:pass_messages] || {}).each_with_object({}) { |(key, value), out| out[key.to_s] = value.to_s }.freeze,
        fail_messages: (raw[:fail_messages] || {}).each_with_object({}) { |(key, value), out| out[key.to_s] = value.to_s }.freeze,
        prefix_list_entry: raw[:prefix_list_entry].to_s,
        prefix_list_joiner: raw[:prefix_list_joiner].to_s,
        special_note_template: raw[:special_note_template].to_s,
        cell_line_tissue_type: raw[:cell_line_tissue_type].to_s,
        primary_cell_culture_tissue_type: raw[:primary_cell_culture_tissue_type].to_s,
        cellosaurus_prefix: raw[:cellosaurus_prefix].to_s
      }.freeze
    end

    def organism_specific_skip_message(rule, reason)
      organism_specific_validation_config.dig(:skip_messages, rule.to_s, reason.to_s).to_s
    end

    def organism_specific_pass_message(key, **kwargs)
      template = organism_specific_validation_config.dig(:pass_messages, key.to_s).to_s
      kwargs.empty? ? template : format(template, **kwargs)
    end

    def organism_specific_fail_message(key, **kwargs)
      template = organism_specific_validation_config.dig(:fail_messages, key.to_s).to_s
      kwargs.empty? ? template : format(template, **kwargs)
    end

    def organism_specific_special_values(rule)
      Array(organism_specific_validation_config.dig(:special_values, rule.to_s)).map(&:to_s).freeze
    end

    def ontology_semantics_display_constraints(suffix)
      rows = Array(data.dig(:ontology_semantics_display, suffix.to_sym, :constraints))
      rows.each_with_index.map do |row, idx|
        {
          label: row[:label].to_s,
          value: row[:value].to_s,
          rules_path: "ontology_semantics_display.#{suffix}.constraints.#{idx}"
        }
      end.freeze
    end

    def ontology_semantics_organism_specific_check_key(field_name, check_suffix)
      base = data.dig(:ontology_semantics_display, :organism_specific, field_name.to_sym) || {}
      check_suffix = check_suffix.to_s
      return check_suffix if base.key?(check_suffix.to_sym)

      '_default'
    end

    def ontology_semantics_organism_specific_entries(field_name, check_suffix, variant:)
      base = data.dig(:ontology_semantics_display, :organism_specific, field_name.to_sym)
      return [] if base.blank?

      if variant == :missing_organism
        return Array(base[:_missing_organism])
      end

      check_key = ontology_semantics_organism_specific_check_key(field_name, check_suffix)
      check_block = base[check_key.to_sym] || base[:_default]
      return [] if check_block.blank?

      Array(check_block[variant.to_sym])
    end

    def field_constraint_entries(layer, field_name)
      Array(data.dig(:field_constraints, layer.to_sym, field_name.to_sym)).freeze
    end

    def field_constraint_display_value(entry)
      return Array(entry[:values]).map(&:to_s).join(', ') if entry[:values].present?

      entry[:value].to_s
    end

    def organism_specific_display_constraint(key)
      data.dig(:organism_specific_display, :constraints, key.to_sym).to_s
    end

    def organism_specific_file_organism_label
      data.dig(:organism_specific_display, :file_organism, :label).to_s.presence || 'File organism'
    end

    def organism_specific_file_organism_source
      data.dig(:organism_specific_display, :file_organism, :source).to_s
    end

    def organism_specific_context_text(key, **kwargs)
      template = data.dig(:organism_specific_display, :semantic_context, key.to_sym).to_s
      kwargs.empty? ? template : format(template, **kwargs)
    end

    def spatial_extension_obs_rules
      raw = data.dig(:spatial_extension, :obs) || {}
      {
        required_columns: Array(raw[:required_columns]).map(&:to_s).join(', '),
        condition: raw[:condition].to_s
      }.freeze
    end

    def spatial_extension_display_rules
      raw = data.dig(:spatial_extension, :display) || {}
      {
        rollup_sub_checks: raw[:rollup_sub_checks].to_s,
        hires_max_dimension_template: raw[:hires_max_dimension_template].to_s,
        cytassist_assay: 'EFO:0022860'
      }.freeze
    end

    def metadata_rules
      raw = data[:metadata_rules] || {}
      {
        forbidden_name_prefix: raw[:forbidden_name_prefix].to_s,
        skip_column_names: Array(raw[:skip_column_names]).map(&:to_s).freeze,
        unique_layers: Array(raw[:unique_layers]).map(&:to_s).freeze,
        unique_names_requirement: raw[:unique_names_requirement].to_s,
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
      experimental_obs = experimental_condition_obs_fields
      cross_field_obs = %w[tissue_type suspension_type donor_id is_primary_data] + spatial_obs + perturb_obs + experimental_obs
      var_fields = required_var_fields

      if fmt == 'loom'
        (
          required_uns_fields.map { |name| field_path('loom', :uns, name) } +
          optional_uns_fields.map { |name| field_path('loom', :uns, name) } +
          required_obs_fields.map { |name| field_path('loom', :obs, name) } +
          cross_field_obs.map { |name| field_path('loom', :obs, name) } +
          var_fields.map { |name| field_path('loom', :var, name) } +
          [field_path('loom', :uns, 'spatial/is_single')]
        ).uniq
      elsif fmt == 'h5ad'
        (
          cross_field_obs.map { |name| field_path('h5ad', :obs, name) } +
          var_fields.map { |name| field_path('h5ad', :var, name) } +
          [field_path('h5ad', :uns, 'spatial/is_single')]
        ).uniq
      else
        []
      end
    end

    def experimental_condition_obs_fields
      rules = experimental_condition_rules
      [
        rules[:id_field],
        rules[:label_field],
        rules[:perturbation_types_field]
      ].reject(&:blank?).freeze
    end

    def h5ad_validator_config
      fmt = 'h5ad'
      enum_fields = (data[:enum_fields] || {}).each_with_object({}) do |(field_name, cfg), out|
        layer = %w[feature_biotype].include?(field_name.to_s) ? :var : :obs
        out[field_path(fmt, layer, field_name.to_s)] = Array(cfg[:values]).map(&:to_s)
      end
      {
        'required_obs' => required_obs_fields,
        'required_uns' => required_uns_fields,
        'required_var' => required_var_fields,
        'experimental_obs' => experimental_condition_obs_fields,
        'ontology_fields' => ontology_paths(fmt),
        'special_values' => allowed_special_values(fmt),
        'enum_fields' => enum_fields,
        'label_pairs' => label_pairs,
        'optional_uns' => optional_uns_fields,
        'ontology_term_formats' => {
          'obo_pattern' => data.dig(:ontology_term_formats, :obo, :pattern).to_s,
          'cellosaurus_prefix' => ontology_term_format_config[:cellosaurus_prefix],
          'obo_invalid_message' => ontology_term_format_config[:obo_invalid_message],
          'cellosaurus_disallowed_message' => ontology_term_format_config[:cellosaurus_disallowed_message],
          'obo_example' => ontology_term_format_config[:obo_example]
        },
        'ontology_format_examples' => ontology_fields.each_with_object({}) do |(field_name, _cfg), out|
          out[field_name.to_s] = ontology_format_example(field_name.to_s)
        end,
        'check_messages' => validator_check_messages
      }
    end

    def validator_check_messages
      checks_registry.values.each_with_object({}) do |entry, out|
        next if entry[:messages].blank?

        out[entry[:id]] = entry[:messages]
      end
    end

    def resolve_constant_ref(value)
      case value
      when String
        Array(value)
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
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
      else
        Array(value)
      end
    end

    def apply_ontology_field_semantic_defaults!(resolved, field_cfg)
      if !resolved.key?(:allowed_exact) && field_cfg[:valid_terms].present?
        raw = field_cfg[:valid_terms]
        resolved[:allowed_exact] = raw.each_with_object({}) { |(id, name), h| h[id.to_s] = name.to_s }
      end
      if !resolved.key?(:forbidden_exact) && field_cfg[:banned_terms].present?
        resolved[:forbidden_exact] = Array(field_cfg[:banned_terms]).map(&:to_s)
      end
      return if resolved.key?(:allowed_special_values)
      return if field_cfg[:special_values].blank?

      resolved[:allowed_special_values] = Array(field_cfg[:special_values]).map(&:to_s)
    end

    def normalize_cross_field_rule(key, cfg)
      slug = cfg[:slug].to_s
      id = "#{key}-#{slug}"
      messages = (cfg[:messages] || {}).each_with_object({}) { |(msg_key, value), out| out[msg_key.to_s] = value.to_s }.freeze
      mapping = normalize_cross_field_mapping(cfg[:mapping])
      {
        key: key,
        id: id,
        field: "cross-field.#{id}",
        slug: slug,
        title: cfg[:title].to_s,
        summary: cfg[:summary].to_s,
        summary_template: cfg[:summary_template].to_s,
        checks: Array(cfg[:checks]).map(&:to_s).freeze,
        token: cfg[:token].to_s,
        per_field: cfg[:per_field] == true,
        mapping: mapping,
        messages: messages,
        violation: cfg[:violation]&.deep_symbolize_keys
      }.freeze
    end

    def normalize_cross_field_mapping(raw)
      raw = raw&.deep_symbolize_keys || {}
      normalized = {
        applies_when: (raw[:applies_when] || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_s }.freeze,
        field: raw[:field].to_s,
        id_field: raw[:id_field].to_s,
        label_field: raw[:label_field].to_s,
        required_value: raw[:required_value].to_s,
        label_value: raw[:label_value].to_s,
        forbidden_term: raw[:forbidden_term].to_s,
        required_prefix: raw[:required_prefix].to_s,
        allowed_values: Array(raw[:allowed_values]).map(&:to_s).freeze,
        special_id_values: Array(raw[:special_id_values]).map(&:to_s).freeze,
        pairs: Array(raw[:pairs]).map { |pair| Array(pair).map(&:to_s) }.freeze,
        suspension_by_assay_ontology_term_id: (raw[:suspension_by_assay_ontology_term_id] || {}).each_with_object({}) do |(term, values), out|
          out[term.to_s] = Array(values).map(&:to_s)
        end.freeze,
        accept_descendants_of_assay_ontology_term_id: Array(raw[:accept_descendants_of_assay_ontology_term_id]).map(&:to_s).freeze
      }
      normalized.each_with_object({}) { |(k, v), out| out[k] = v unless v.blank? && !v.is_a?(Hash) && !v.is_a?(Array) }.freeze
    end
    private :normalize_cross_field_rule, :normalize_cross_field_mapping

    def symbolize_spatial_section(section)
      section ||= {}
      {
        allowed_keys: Array(section[:allowed_keys]).map(&:to_s),
        required_when_visium_is_single: Array(section[:required_when_visium_is_single]).map(&:to_s)
      }
    end
    private :symbolize_spatial_section

    private :resolve_constant_ref, :resolve_rule_ref
  end
end
