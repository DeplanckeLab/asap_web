# frozen_string_literal: true

module Scfair
  class CheckDetailBuilder
    PRESENCE_CHECK = /
      \AFound\ .+\ metadata\z |
      Missing\ .+\ metadata\ \(required\ by\ schema\) |
      Missing\ .+\ metadata\ \(unique\ cell\ identifiers\ required\) |
      Missing\ .+\ metadata\ \(required\ for\ Visium\ spatial\ data\ with\ is_single=true\) |
      Skipped\ \(pre-analysis\ dataset\)
    /x

    ONTOLOGY_FORMAT_CHECK = /
      Ontology\ terms\ in\ .+\ have\ valid\ format |
      Invalid\ ontology\ term\ format |
      Invalid\ ontology\ format |
      Unexpected\ ontology\ prefix |
      Ontology\ prefix\ .+\ may\ not\ be\ valid
    /x

    def self.presence_check_message?(message)
      message.to_s.match?(PRESENCE_CHECK)
    end

    def self.ontology_format_check_message?(message)
      message.to_s.match?(ONTOLOGY_FORMAT_CHECK)
    end

    def self.enrich_item(item, format:, category_id: nil, field_values: nil)
      field = (item[:field] || item['field']).to_s
      message = (item[:message] || item['message']).to_s
      check_id = (item[:check_id] || item['check_id']).to_s.presence
      detail = call(field: field, message: message, format: format, category_id: category_id, field_values: field_values, check_id: check_id)
      status = (item[:status] || item['status']).to_s.strip.downcase.presence
      detail[:status] = status if status.present?
      item.merge(detail: detail)
    end

    def self.call(field:, message:, format:, category_id: nil, field_values: nil, check_id: nil)
      new(field: field, message: message, format: format, category_id: category_id, field_values: field_values, check_id: check_id).call
    end

    def initialize(field:, message:, format:, category_id: nil, field_values: nil, check_id: nil)
      @field = field.to_s
      @message = message.to_s
      @format = format.to_s
      @category_id = category_id.to_s.presence
      @field_values = field_values || {}
      @check_id = check_id.to_s.presence
    end

    def call
      category_id = @category_id.presence || @check_id.presence || Scfair::ComplianceReportGrouper.category_for(
        field: @field,
        message: @message,
        format: @format,
        check_id: @check_id
      )

      category_label = catalog_label(category_id)
      field_name = extract_field_name(@field)

      detail = {
        field: @field,
        category_id: category_id,
        category_label: category_label,
        title: detail_title(field_name, category_id),
        summary: detail_summary(field_name, category_id),
        result_message: @message,
        checks_performed: checks_performed(category_id),
        constraints: build_constraints(field_name, category_id),
        schema_url: Rules.schema_hash[:source_url],
        schema_version: Rules.schema_version
      }

      detail_rule = yaml_check_detail_for_field
      if detail_rule
        detail[:title] = detail_rule[:title]
        detail[:summary] = detail_rule[:summary]
        detail[:checks_performed] = yaml_checks_with_paths(
          detail_rule[:checks],
          Rules.check_yaml_path(yaml_check_detail_field_key) || "checks.#{yaml_check_detail_field_key}.checks_performed"
        )
      end

      rule = Rules.cross_field_rule_by_id(@field.delete_prefix('cross-field.'))
      if rule.present? && @field.start_with?('cross-field.')
        detail[:title] ||= rule[:title]
        detail[:summary] ||= rule[:summary]
      end

      metadata_other = Rules.metadata_other_detail(@field)
      if metadata_other
        detail[:title] = metadata_other[:title]
        detail[:summary] = metadata_other[:summary]
        if metadata_other[:checks].present?
          detail[:checks_performed] = yaml_checks_with_paths(
            metadata_other[:checks],
            Rules.check_yaml_path(@field) || "checks.#{@field}.rollup"
          )
        end
      end

      detail[:checks_performed] = attach_rules_paths_to_checks(
        detail[:checks_performed],
        checks_rules_path_prefix(category_id)
      )

      detail
    end

    private

    def checks_performed(category_id)
      return Rules.spatial_rollup_checks if @field == 'extension.spatial'

      metadata_other = Rules.metadata_other_detail(@field)
      return metadata_other[:checks] if metadata_other&.dig(:checks)&.present?

      extension_checks = Rules.extension_field_checks(@field)
      return extension_checks if extension_checks.any?

      uns_field = uns_metadata_field_name(@field)
      if uns_field.present?
        uns_checks = Rules.layer_field_checks(:uns, uns_field, format: @format)
        return uns_checks if uns_checks.any?
      end

      obs_field = obs_metadata_field_name(@field)
      if obs_field.present? && obs_presence_check?(category_id)
        obs_checks = Rules.layer_field_checks(:obs, obs_field, format: @format)
        return obs_checks if obs_checks.any?
      end

      var_field = var_metadata_field_name(@field)
      if var_field.present?
        var_checks = Rules.layer_field_checks(:var, var_field, format: @format)
        return var_checks if var_checks.any?
      end

      if var_index_storage_path?(@field)
        presence_checks = Rules.check_detail_for_field('var.index.presence')&.dig(:checks)
        return presence_checks if presence_checks.present?
      end

      field_detail = Rules.check_detail_for_field(@field)
      if @field.start_with?('cross-field.') && field_detail
        return Array(field_detail[:checks]).map(&:to_s)
      end

      if @field.start_with?('obs.label_pairs.') && field_detail&.dig(:checks)&.present?
        return field_detail[:checks]
      end

      if @field.start_with?('ontology.organism_specific.') && field_detail&.dig(:checks)&.present?
        return field_detail[:checks]
      end

      ontology_field = ontology_term_field_name_from_path
      if ontology_field.present? && (ontology_format_check? || category_id == 'ontology.format')
        performed = ontology_format_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if ontology_field.present? && category_id == 'ontology.database_resolution'
        performed = ontology_database_resolution_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if presence_check?
        performed = presence_checks_performed(extract_field_name(@field), category_id)
        return performed if performed.any?
      end

      organism_checks = Rules.check_detail_for_field(@field)&.dig(:checks)
      return organism_checks if @field.start_with?('ontology.organism_specific.') && organism_checks.present?

      ontology_field = ontology_term_field_name_from_path
      if ontology_field.present? && (ontology_format_check? || category_id == 'ontology.format')
        performed = ontology_format_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if ontology_field.present? && category_id == 'ontology.database_resolution'
        performed = ontology_database_resolution_checks_performed(ontology_field)
        return performed if performed.any?
      end

      if presence_check?
        performed = presence_checks_performed(extract_field_name(@field), category_id)
        return performed if performed.any?
      end

      field_name = semantic_ontology_field_name(@field)
      suffix = semantic_rule_suffix(@field)
      if suffix.present? && semantic_ontology_field?(field_name)
        performed = semantic_checks_performed(field_name, suffix)
        return performed if performed.any?
      end

      Rules.category_checks_list(category_id)
    end

    def catalog_label(category_id)
      return nil if category_id.blank?

      Scfair::CheckCatalog.checks_for(@format).find { |entry| entry[:id] == category_id }&.dig(:label)
    end

    def extract_field_name(field)
      return field.sub(/\Across-field\.[^.]+\z/, '') if field.start_with?('cross-field.')
      return semantic_ontology_field_name(field) if field.start_with?('ontology.semantics.')

      segment = field.split('/').last.to_s
      segment.presence || field
    end

    def semantic_ontology_field_name(field)
      field.sub(/\Aontology\.semantics\./, '').split('.').first.to_s
    end

    def semantic_rule_suffix(field)
      return nil unless field.start_with?('ontology.semantics.')

      parts = field.sub(/\Aontology\.semantics\./, '').split('.')
      parts[1].presence
    end

    def detail_title(field_name, category_id)
      suffix = semantic_rule_suffix(@field)
      if suffix && semantic_ontology_field?(field_name)
        check_title = Rules.semantic_check_title(suffix) || suffix.tr('_', ' ')
        return "#{field_name} — #{check_title}"
      end

      return field_name if field_name.present? && !generic_field?(field_name)

      Rules.category_summary?(category_id) ? catalog_label(category_id) : field_name
    end

    def generic_field?(field_name)
      field_name.in?(%w[file dimensions obs X validation loom file_info cross-field])
    end

    def detail_summary(field_name, category_id)
      suffix = semantic_rule_suffix(@field)
      return Rules.semantic_check_summary(suffix) if suffix && Rules.semantic_check_summary(suffix).present?

      if required_var_field?(field_name)
        summary = var_field_summary(field_name)
        return summary if summary.present?
      end

      uns_field = uns_metadata_field_name(@field)
      if uns_field.present?
        summary = uns_field_summary(uns_field)
        return summary if summary.present?
      end

      summary = Rules.category_summary(@field).presence || Rules.category_summary(category_id).presence
      return summary if summary.present?

      if required_observation_field?(field_name)
        return Rules.default_summary_text(:required_observation) ||
               "Required observation metadata field per scFAIR #{Rules.schema_version}."
      end

      if required_uns_field?(field_name)
        return Rules.default_summary_text(:required_uns) ||
               "Required dataset metadata field per scFAIR #{Rules.schema_version}."
      end

      if enum_field?(field_name)
        return Rules.default_summary_text(:enum_field) ||
               'Categorical field with a fixed set of allowed values.'
      end

      if ontology_term_field?(field_name)
        return Rules.default_summary_text(:ontology_term_field) ||
               'Ontology term identifier field validated for format, semantics, and database resolution.'
      end

      Rules.default_summary_text(:compliance_fallback) ||
        'Compliance check against the scFAIR schema.'
    end

    def yaml_check_detail_field_key
      return 'var.index.presence' if var_index_storage_path?(@field)

      @field
    end

    def yaml_checks_with_paths(checks, prefix)
      Array(checks).each_with_index.map do |check, idx|
        {
          text: check.to_s,
          from_rules: true,
          rules_path: "#{prefix}.checks.#{idx}"
        }
      end
    end

    def attach_rules_paths_to_checks(checks, prefix)
      return checks if prefix.blank?
      return checks if Array(checks).all? { |check| check.is_a?(Hash) && check[:rules_path].present? }

      Array(checks).map.with_index do |check, idx|
        next check if check.is_a?(Hash) && check[:rules_path].present?

        text = check.is_a?(Hash) ? check[:text].to_s : check.to_s
        {
          text: text,
          from_rules: true,
          rules_path: "#{prefix}.#{idx}"
        }
      end
    end

    def checks_rules_path_prefix(category_id)
      return 'checks.extension.spatial.rollup' if @field == 'extension.spatial'

      yaml_path = Rules.check_yaml_path(@field)
      return yaml_path if yaml_path.present?

      %i[uns obs var].each do |layer|
        field_name = send("#{layer}_metadata_field_name", @field)
        next if field_name.blank?

        entry = Rules.field_check_entry(layer, field_name)
        next if entry.blank?

        path = Rules.check_yaml_path(entry[:id])
        return path if path.present?
      end

      if Rules.extension_field_checks(@field).any?
        return Rules.check_yaml_path(@field) || "checks.#{@field}.rollup"
      end

      if category_id.present? && Rules.category_checks_list(category_id).any?
        return "checks.#{category_id}.rollup"
      end

      nil
    end

    def yaml_check_detail_for_field
      if var_index_storage_path?(@field)
        Rules.check_detail_for_field('var.index.presence')
      else
        Rules.check_detail_for_field(@field)
      end
    end

    def append_field_constraint_rows(rows, layer, field_name)
      Rules.field_constraint_entries(layer, field_name).each_with_index do |entry, idx|
        rows << constraint_row(
          entry[:label],
          Rules.field_constraint_display_value(entry),
          from_rules: true,
          rules_path: "field_constraints.#{layer}.#{field_name}.#{idx}"
        )
      end
    end

    def append_ontology_semantics_constraint_rows(rows, suffix)
      Rules.ontology_semantics_display_constraints(suffix).each do |entry|
        rows << constraint_row(entry[:label], entry[:value], from_rules: true, rules_path: entry[:rules_path])
      end
    end

    def constraint_row(label, value, from_rules: false, from_file: false, rules_path: nil)
      row = { label: label.to_s, value: value.to_s }
      if from_rules
        row[:from_rules] = true
        row[:rules_path] = rules_path.to_s if rules_path.present?
      elsif from_file
        row[:from_file] = true
        row[:rules_path] = (rules_path.presence || 'organism_specific_display.file_organism').to_s
      end
      row
    end

    def file_organism_row(organism)
      constraint_row(
        Rules.organism_specific_file_organism_label,
        organism_display_name(organism),
        from_file: true
      )
    end

    def build_constraints(field_name, category_id)
      return [] if presence_check?
      return format_check_constraints(field_name) if ontology_format_check?

      suffix = semantic_rule_suffix(@field)
      return semantic_subcheck_constraints(field_name, suffix) if suffix.present? && semantic_ontology_field?(field_name)

      rows = []

      if Rules.var_index_field?(@field) || category_id == 'var.index'
        cfg = Rules.var_index_config
        rows << { label: 'AnnData schema', value: cfg[:schema] }
        rows << { label: 'H5AD logical path', value: "#{cfg[:h5ad][:logical]} (file: #{cfg[:h5ad][:path]})" }
        rows << { label: 'Loom logical path', value: "#{cfg[:loom][:logical]} (file: #{cfg[:loom][:path]} or anndata_mapping #{cfg[:loom][:manifest_key]})" }
      end

      if category_id == 'schema.version'
        rows << constraint_row('Reference version', Rules.schema_version, from_rules: true, rules_path: 'schema.version')
        rows << constraint_row('Required identifier', Rules.schema_hash[:schema_version].to_s, from_rules: true, rules_path: 'schema.schema_version')
      end

      if category_id == 'schema.reference'
        rows << constraint_row('Reference schema URL', Rules.schema_hash[:source_url].to_s, from_rules: true, rules_path: 'schema.source_url')
      end

      append_ensembl_uns_constraints(rows, field_name) if category_id == 'uns.ensembl' || ensembl_uns_field?(field_name)
      append_uns_field_constraints(rows, field_name) if uns_metadata_field_name(@field).present?

      append_var_field_constraints(rows, field_name) if required_var_field?(field_name)

      if enum_field?(field_name) && !required_var_field?(field_name)
        rows << constraint_row(
          'Allowed values',
          Rules.enum_field_values(field_name).join(', '),
          from_rules: true,
          rules_path: "enum_fields.#{field_name}.values"
        )
      end

      ontology_cfg = Rules.ontology_field(field_name)
      if ontology_cfg.present?
        append_prefix_rows(rows, ontology_cfg, field_name: field_name)
        append_ontology_field_special_rows(rows, ontology_cfg, field_name: field_name)
      end

      semantic = Rules.semantic_rules_for(field_name)
      if semantic.present?
        append_root_rows(rows, semantic, field_name: field_name)
        banned_rule = semantic_rule_suffix(@field).in?(%w[banned_terms forbidden])
        append_forbidden_rows(rows, semantic, field_name: field_name, as_banned: banned_rule)
        append_allowed_exact_rows(rows, semantic, field_name: field_name)
        append_special_value_rows(rows, semantic, field_name: field_name)
      end

      if category_id == 'ontology.organism_specific'
        rule = @field.sub(/\Aontology\.organism_specific\./, '')
        append_organism_specific_check_constraints(rows, rule)
      end

      if category_id == 'cross-field.constraints' && field_name == 'suspension_type'
        rows << constraint_row(
          'Assay map entries',
          "#{Rules.assay_suspension_type_map.size} assay terms defined in schema",
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path('CF-1', 'mapping', 'suspension_by_assay_ontology_term_id')
        )
      end

      append_spatial_extension_constraints(rows, category_id) if category_id.to_s.start_with?('extension.spatial')
      append_metadata_other_constraints(rows) if @field.start_with?('metadata.other.')
      append_var_index_translation_constraints(rows) if var_index_storage_path?(@field)
      append_obs_label_pair_constraints(rows)
      append_cross_field_rule_constraints(rows)

      label_field = Rules.label_pairs[field_name]
      if label_field.present?
        rows << constraint_row('Paired label field', label_field, from_rules: true, rules_path: "label_pairs.#{field_name}")
      end

      rows
    end

    def semantic_subcheck_constraints(field_name, suffix)
      semantic = Rules.semantic_rules_for(field_name)
      return [] if semantic.blank?

      rows = []
      ontology_cfg = Rules.ontology_field(field_name)

      case suffix
      when 'allowed_terms', 'existence'
        append_ontology_semantics_constraint_rows(rows, 'allowed_terms')
        append_allowed_exact_rows(rows, semantic, field_name: field_name)
        append_prefix_rows(rows, ontology_cfg, field_name: field_name)
      when 'banned_terms', 'forbidden'
        append_forbidden_rows(rows, semantic, field_name: field_name, as_banned: true)
      when 'descendants'
        append_root_rows(rows, semantic, field_name: field_name)
      when 'lineage'
        if @message.match?(/must not be under/i)
          append_forbidden_rows(rows, semantic, field_name: field_name, as_banned: true)
        else
          append_root_rows(rows, semantic, field_name: field_name)
        end
      when 'sorted_multi', 'ordering'
        append_ontology_semantics_constraint_rows(rows, 'sorted_multi')
      when 'special_values', 'special_label_pair'
        append_ontology_semantics_constraint_rows(rows, 'special_values')
        append_special_value_rows(rows, semantic, field_name: field_name)
      when 'label_pair'
        label_field = Rules.label_pairs[field_name]
        if label_field.present?
          rows << constraint_row('Paired label field', label_field, from_rules: true, rules_path: "label_pairs.#{field_name}")
        end
        append_ontology_semantics_constraint_rows(rows, 'label_pair')
      end

      append_organism_specific_semantic_context(rows, field_name, suffix)

      rows
    end

    def ontology_term_field_name_from_path
      name = @field.split('/').last.to_s
      return name if semantic_ontology_field?(name) && Rules.ontology_field(name).present?

      nil
    end

    def ontology_format_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      return [] if cfg.blank?

      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      special = Array(cfg[:special_values]).map(&:to_s)
      checks = [
        Rules.ontology_format_requirement_text(field_name),
        "Allowed ontology prefixes: #{prefixes.join(', ')}"
      ]

      if prefixes.include?('CVCL')
        checks << 'Accepts Cellosaurus CVCL_* identifiers (underscore format) in addition to PREFIX:ID terms'
      end

      if special.any?
        checks << "Allows special placeholder values: #{special.join(', ')}"
      end

      checks
    end

    def ontology_database_resolution_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      label_field = Rules.label_pairs[field_name]
      checks = [
        "Each #{field_name} value is looked up in the ASAP ontology database",
        'Obsolete ontology terms are excluded from resolution (treated as not found)'
      ]
      checks << "Term must be valid for authorised ontologies: #{prefixes.join(', ')}" if prefixes.any?
      if label_field.present?
        label_path = Rules.field_path(@format, :obs, label_field)
        checks << "Paired label column #{label_path} is checked against authorised ontology names when present"
      end
      checks
    end

    def presence_checks_performed(field_name, category_id)
      return [] if field_name.blank?

      case category_id
      when 'obs.required_presence'
        obs_checks = Rules.layer_field_checks(:obs, field_name, format: @format)
        return obs_checks if obs_checks.any?

        path = Rules.field_path(@format, :obs, field_name)
        ["Verifies required observation column #{path} is present"]
      when 'uns.required_presence'
        uns_checks = Rules.layer_field_checks(:uns, field_name, format: @format)
        return uns_checks if uns_checks.any?

        path = Rules.field_path(@format, :uns, field_name)
        ["Verifies required dataset metadata field #{path} is present"]
      when 'var.required'
        path = Rules.field_path(@format, :var, field_name)
        ["Verifies required gene metadata column #{path} is present"]
      else
        []
      end
    end

    def ontology_term_field_name_from_path
      name = @field.split('/').last.to_s
      return name if semantic_ontology_field?(name) && Rules.ontology_field(name).present?

      nil
    end

    def ontology_format_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      return [] if cfg.blank?

      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      special = Array(cfg[:special_values]).map(&:to_s)
      checks = [
        Rules.ontology_format_requirement_text(field_name),
        "Allowed ontology prefixes: #{prefixes.join(', ')}"
      ]

      if prefixes.include?('CVCL')
        checks << 'Accepts Cellosaurus CVCL_* identifiers (underscore format) in addition to PREFIX:ID terms'
      end

      if special.any?
        checks << "Allows special placeholder values: #{special.join(', ')}"
      end

      checks
    end

    def ontology_database_resolution_checks_performed(field_name)
      cfg = Rules.ontology_field(field_name)
      prefixes = Array(cfg[:prefixes]).map(&:to_s)
      label_field = Rules.label_pairs[field_name]
      checks = [
        "Each #{field_name} value is looked up in the ASAP ontology database",
        'Obsolete ontology terms are excluded from resolution (treated as not found)'
      ]
      checks << "Term must be valid for authorised ontologies: #{prefixes.join(', ')}" if prefixes.any?
      if label_field.present?
        label_path = Rules.field_path(@format, :obs, label_field)
        checks << "Paired label column #{label_path} is checked against authorised ontology names when present"
      end
      checks
    end

    def presence_checks_performed(field_name, category_id)
      return [] if field_name.blank?

      case category_id
      when 'obs.required_presence'
        path = Rules.field_path(@format, :obs, field_name)
        checks = ["Verifies required observation column #{path} is present"]
        label_field = Rules.label_pairs[field_name]
        if label_field.present?
          checks << "Paired label column #{Rules.field_path(@format, :obs, label_field)} is required for this ontology ID field"
        elsif Rules.enum_field_values(field_name).any?
          checks << "Values must be one of: #{Rules.enum_field_values(field_name).join(', ')}"
        end
        checks
      when 'uns.required_presence'
        path = Rules.field_path(@format, :uns, field_name)
        ["Verifies required dataset metadata field #{path} is present"]
      when 'var.required'
        path = Rules.field_path(@format, :var, field_name)
        ["Verifies required gene metadata column #{path} is present"]
      else
        []
      end
    end

    def semantic_checks_performed(field_name, suffix)
      semantic = Rules.semantic_rules_for(field_name) || {}

      case suffix
      when 'allowed_terms', 'existence'
        checks = [
          'Term must resolve as an active (non-obsolete) entry in the ontology database',
          'Obsolete ontology terms are treated as not found'
        ]
        checks << 'Terms in the allowed exact list satisfy this check without further lineage validation' if semantic[:allowed_exact].present?
        checks
      when 'banned_terms', 'forbidden'
        checks = []
        checks << 'Term must not match a forbidden exact identifier' if semantic[:forbidden_exact].present?
        checks << 'Term must not fall under a forbidden ontology branch' if semantic[:forbidden_branches].present?
        checks
      when 'descendants'
        roots = Array(semantic[:any_roots]).map(&:to_s)
        roots.any? ? ["Each term must descend from: #{roots.join(' or ')}"] : []
      when 'lineage'
        @message.match?(/must not be under/i) ? semantic_checks_performed(field_name, 'banned_terms') : semantic_checks_performed(field_name, 'descendants')
      when 'sorted_multi', 'ordering'
        ['Multiple values must be unique and sorted lexically with " || " separator']
      when 'special_values', 'special_label_pair'
        special = Array(semantic[:allowed_special_values]).map(&:to_s)
        special.any? ? ["Placeholder values allowed: #{special.join(', ')}"] : []
      when 'label_pair'
        label_field = Rules.label_pairs[field_name]
        checks = ['Each label must match the canonical name of its ontology term ID']
        checks << "Compared against paired field #{label_field}" if label_field.present?
        checks
      else
        []
      end
    end

    def append_root_rows(rows, semantic, field_name:)
      roots = Array(semantic[:any_roots]).map(&:to_s)
      return unless roots.any?

      rows << constraint_row(
        'Must descend from',
        roots.join(', '),
        from_rules: true,
        rules_path: "semantic_rules.#{field_name}.any_roots"
      )
    end

    def append_forbidden_rows(rows, semantic, field_name:, as_banned: false)
      branches = Array(semantic[:forbidden_branches]).map(&:to_s)
      if branches.any?
        label = as_banned ? 'Banned branches' : 'Forbidden branches'
        rows << constraint_row(
          label,
          branches.join(', '),
          from_rules: true,
          rules_path: "semantic_rules.#{field_name}.forbidden_branches"
        )
      end

      exact = Array(semantic[:forbidden_exact]).map(&:to_s)
      return unless exact.any?

      label = as_banned ? 'Banned terms' : 'Forbidden terms'
      rows << constraint_row(
        label,
        exact.join(', '),
        from_rules: true,
        rules_path: "semantic_rules.#{field_name}.forbidden_exact"
      )
    end

    def append_allowed_exact_rows(rows, semantic, field_name:)
      allowed_exact = semantic[:allowed_exact]
      rules_path = allowed_exact_rules_path(field_name)
      if allowed_exact.is_a?(Hash)
        rows << constraint_row(
          'Allowed terms',
          allowed_exact.map { |id, name| "#{id} (#{name})" }.join(', '),
          from_rules: true,
          rules_path: rules_path
        )
      elsif allowed_exact.is_a?(Array) && allowed_exact.any?
        rows << constraint_row(
          'Allowed terms',
          allowed_exact.join(', '),
          from_rules: true,
          rules_path: rules_path
        )
      end
    end

    def allowed_exact_rules_path(field_name)
      if Rules.ontology_field(field_name)[:valid_terms].present?
        "ontology_fields.#{field_name}.valid_terms"
      else
        "semantic_rules.#{field_name}.allowed_exact"
      end
    end

    def append_special_value_rows(rows, semantic, field_name:)
      special = Array(semantic[:allowed_special_values]).map(&:to_s)
      return unless special.any?

      rows << constraint_row(
        'Allowed special values',
        special.join(', '),
        from_rules: true,
        rules_path: "semantic_rules.#{field_name}.allowed_special_values"
      )
    end

    def append_ontology_field_special_rows(rows, ontology_cfg, field_name:)
      special = Array(ontology_cfg[:special_values]).map(&:to_s)
      return unless special.any?

      rows << constraint_row(
        'Special values',
        special.join(', '),
        from_rules: true,
        rules_path: "ontology_fields.#{field_name}.special_values"
      )
    end

    def append_prefix_rows(rows, ontology_cfg, field_name:)
      return if ontology_cfg.blank?

      prefixes = Array(ontology_cfg[:prefixes]).map(&:to_s)
      return unless prefixes.any?

      rows << constraint_row(
        'Allowed prefixes',
        prefixes.join(', '),
        from_rules: true,
        rules_path: "ontology_fields.#{field_name}.prefixes"
      )
    end

    def append_metadata_other_constraints(rows)
      rules = Rules.metadata_rules

      case @field
      when 'metadata.other.reserved_prefix'
        rows << constraint_row(
          'Forbidden name prefix',
          rules[:forbidden_name_prefix],
          from_rules: true,
          rules_path: 'metadata_rules.forbidden_name_prefix'
        )
        layers = %w[obs var].map { |layer| Rules.path_prefix(@format, layer.to_sym) }.join(', ')
        rows << constraint_row('Checked layers', layers, from_rules: true, rules_path: 'metadata_rules.unique_layers')
      when 'metadata.other.unique_names.obs'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :obs), from_rules: true, rules_path: 'paths.obs')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.unique_names.var'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :var), from_rules: true, rules_path: 'paths.var')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.deprecated'
        deprecated = rules[:deprecated_names].map do |entry|
          "#{Rules.path_prefix(@format, entry[:layer].to_sym)}/#{entry[:name]} (deprecated in #{entry[:deprecated_in]})"
        end
        rows << constraint_row(
          'Deprecated reserved names',
          deprecated.join('; '),
          from_rules: true,
          rules_path: 'metadata_rules.deprecated_names'
        )
      end
    end

    def append_metadata_other_constraints(rows)
      rules = Rules.metadata_rules

      case @field
      when 'metadata.other.reserved_prefix'
        rows << constraint_row(
          'Forbidden name prefix',
          rules[:forbidden_name_prefix],
          from_rules: true,
          rules_path: 'metadata_rules.forbidden_name_prefix'
        )
        layers = %w[obs var].map { |layer| Rules.path_prefix(@format, layer.to_sym) }.join(', ')
        rows << constraint_row('Checked layers', layers, from_rules: true, rules_path: 'metadata_rules.unique_layers')
      when 'metadata.other.unique_names.obs'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :obs), from_rules: true, rules_path: 'paths.obs')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.unique_names.var'
        rows << constraint_row('Layer', Rules.path_prefix(@format, :var), from_rules: true, rules_path: 'paths.var')
        rows << constraint_row('Requirement', Rules.metadata_rules[:unique_names_requirement], from_rules: true, rules_path: 'metadata_rules.unique_names_requirement')
      when 'metadata.other.deprecated'
        deprecated = rules[:deprecated_names].map do |entry|
          "#{Rules.path_prefix(@format, entry[:layer].to_sym)}/#{entry[:name]} (deprecated in #{entry[:deprecated_in]})"
        end
        rows << constraint_row(
          'Deprecated reserved names',
          deprecated.join('; '),
          from_rules: true,
          rules_path: 'metadata_rules.deprecated_names'
        )
      end
    end

    def append_var_index_translation_constraints(rows)
      cfg = Rules.var_index_config
      rows << constraint_row(
        'AnnData schema',
        cfg[:schema],
        from_rules: true,
        rules_path: 'anndata_indices.var.schema'
      )
      rows << constraint_row(
        'H5AD file path',
        cfg[:h5ad][:path],
        from_rules: true,
        rules_path: 'anndata_indices.var.h5ad.path'
      )
      rows << constraint_row(
        'Loom file path',
        "#{cfg[:loom][:path]} (or anndata_mapping #{cfg[:loom][:manifest_key]})",
        from_rules: true,
        rules_path: 'anndata_indices.var.loom.path'
      )
    end

    def append_obs_label_pair_constraints(rows)
      prefix = Rules.label_pair_validation_config[:check_prefix]
      return unless @field.start_with?("#{prefix}.")

      id_field = @field.delete_prefix("#{prefix}.")
      label_field = Rules.label_pairs[id_field]
      return if label_field.blank?

      rows << constraint_row(
        'Paired label field',
        label_field,
        from_rules: true,
        rules_path: "label_pairs.#{id_field}"
      )
      allowed = OntologySemanticRules.allowed_special_values_for(id_field)
      if allowed.any?
        rows << constraint_row(
          'Special ID values',
          allowed.join(', '),
          from_rules: true,
          rules_path: "semantic_rules.#{id_field}.allowed_special_values"
        )
      end
    end

    def append_cross_field_rule_constraints(rows)
      return unless @field.start_with?('cross-field.CF-')

      rule_id = @field.delete_prefix('cross-field.')
      rule = Rules.cross_field_rule_by_id(rule_id)
      cell_line_rule = Rules.cross_field_cell_line_checks.find { |entry| entry[:id] == rule_id }
      if cell_line_rule
        rows << constraint_row(
          'Applies when',
          'tissue_type is "cell line"',
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(cell_line_rule[:key], 'summary')
        )
        rows << constraint_row(
          'Requirement',
          cell_line_rule[:fail].to_s,
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(cell_line_rule[:key], 'messages', 'fail')
        )
        return
      end

      if rule&.dig(:messages, 'fail').present?
        rows << constraint_row(
          'Requirement',
          rule[:messages]['fail'].to_s,
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(rule[:key], 'messages', 'fail')
        )
      end

      append_cf_rule_constraints(rows, rule)
    end

    def append_cf_rule_constraints(rows, rule)
      return if rule.blank?

      case rule[:key]
      when Rules::CF8_RULE_KEY
        rows << constraint_row(
          'Requires',
          Rules.cross_field_cf8_message('skipped_not_single'),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF8_RULE_KEY, 'messages', 'skipped_not_single')
        )
        rows << constraint_row(
          'Fail condition',
          Rules.cross_field_cf8_message('fail'),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF8_RULE_KEY, 'messages', 'fail')
        )
      when Rules::CF9_RULE_KEY
        spatial_root = @format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
        rows << constraint_row(
          'Missing metadata',
          Rules.cross_field_cf9_message('fail_missing_metadata', spatial_root: spatial_root),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF9_RULE_KEY, 'messages', 'fail_missing_metadata')
        )
        rows << constraint_row(
          'Unexpected metadata',
          Rules.cross_field_cf9_message('fail_metadata_without_spatial_assay', spatial_root: spatial_root),
          from_rules: true,
          rules_path: Rules.cross_field_rules_yaml_path(Rules::CF9_RULE_KEY, 'messages', 'fail_metadata_without_spatial_assay')
        )
      end
    end

    def append_spatial_extension_constraints(rows, category_id)
      rules = Rules.spatial_extension_rules
      spatial_root = @format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
      obsm_key = @format == 'h5ad' ? rules.dig(:obsm_spatial, :h5ad_key) : rules.dig(:obsm_spatial, :loom_key)
      image_rules = rules.dig(:images, :array) || {}
      hires_dims = rules.dig(:images, :hires_max_dimension) || {}
      spatial_category = spatial_detail_category(category_id)

      case spatial_category
      when 'extension.spatial'
        rows << constraint_row('Spatial metadata root', spatial_root)
        rows << constraint_row(
          'Sub-checks',
          rules[:display][:rollup_sub_checks],
          from_rules: true,
          rules_path: 'spatial_extension.display.rollup_sub_checks'
        )
      when 'extension.spatial.structure', 'extension.spatial.library'
        rows << constraint_row('Spatial metadata root', spatial_root)
        rows << constraint_row(
          'Library sections',
          Array(rules.dig(:library, :allowed_keys)).join(', '),
          from_rules: true,
          rules_path: 'spatial_extension.library.allowed_keys'
        )
        rows << constraint_row(
          'Required when Visium is_single',
          Array(rules.dig(:library, :required_when_visium_is_single)).join(', '),
          from_rules: true,
          rules_path: 'spatial_extension.library.required_when_visium_is_single'
        )
      when 'extension.spatial.images.hires', 'extension.spatial.images.fullres', 'extension.spatial.assets'
        append_spatial_image_constraints(rows, image_rules, hires_dims, spatial_category)
        append_spatial_obsm_constraints(rows, rules, obsm_key) if spatial_category == 'extension.spatial.assets'
      when 'extension.spatial.obsm'
        rows << constraint_row('Spatial embedding path', obsm_key, from_rules: true, rules_path: 'spatial_extension.obsm_spatial')
        append_spatial_obsm_constraints(rows, rules, obsm_key)
        rows << constraint_row(
          'Required when is_single',
          rules.dig(:obsm_spatial, :required_when_is_single) ? 'yes' : 'no',
          from_rules: true,
          rules_path: 'spatial_extension.obsm_spatial.required_when_is_single'
        )
      when 'extension.spatial.obs'
        rows << constraint_row(
          'Required columns',
          rules[:obs][:required_columns],
          from_rules: true,
          rules_path: 'spatial_extension.obs.required_columns'
        )
        rows << constraint_row(
          'Condition',
          rules[:obs][:condition],
          from_rules: true,
          rules_path: 'spatial_extension.obs.condition'
        )
      end
    end

    def append_spatial_image_constraints(rows, image_rules, hires_dims, spatial_category)
      if image_rules[:dtype].present?
        rows << constraint_row('Image dtype', image_rules[:dtype].to_s, from_rules: true, rules_path: 'spatial_extension.images.array.dtype')
      end
      if image_rules[:ndim].present?
        rows << constraint_row('Image dimensions', "#{image_rules[:ndim]}D array", from_rules: true, rules_path: 'spatial_extension.images.array.ndim')
      end
      if image_rules[:channel_sizes].present?
        rows << constraint_row(
          'Channel sizes',
          Array(image_rules[:channel_sizes]).join(' or '),
          from_rules: true,
          rules_path: 'spatial_extension.images.array.channel_sizes'
        )
      end
      return unless spatial_category.include?('hires') || spatial_category == 'extension.spatial.assets'

      default_dim = hires_dims[:default]
      display = Rules.spatial_extension_display_rules
      cytassist_assay = display[:cytassist_assay]
      cytassist_dim = hires_dims.dig(:by_assay, cytassist_assay)
      rows << constraint_row(
        'Hires max dimension',
        format(
          display[:hires_max_dimension_template],
          default: default_dim,
          assay: cytassist_assay,
          cytassist: cytassist_dim
        ),
        from_rules: true,
        rules_path: 'spatial_extension.display.hires_max_dimension_template'
      )
    end

    def append_spatial_obsm_constraints(rows, rules, obsm_key)
      rows << constraint_row('Spatial embedding path', obsm_key, from_rules: true, rules_path: 'spatial_extension.obsm_spatial')
      rows << constraint_row(
        'Minimum embedding columns',
        rules.dig(:obsm_spatial, :min_columns).to_s,
        from_rules: true,
        rules_path: 'spatial_extension.obsm_spatial.min_columns'
      )
      rows << constraint_row(
        'Embedding dtype kinds',
        Array(rules.dig(:obsm_spatial, :dtype_kinds)).join(', '),
        from_rules: true,
        rules_path: 'spatial_extension.obsm_spatial.dtype_kinds'
      )
    end

    def spatial_detail_category(category_id)
      return @field if @field.start_with?('extension.spatial.') && @field != 'extension.spatial'

      category_id
    end

    def append_organism_specific_semantic_context(rows, field_name, check_suffix)
      case field_name
      when 'self_reported_ethnicity_ontology_term_id'
        append_organism_specific_yaml_constraints(rows, field_name, check_suffix)
      when 'development_stage_ontology_term_id'
        append_organism_dev_stage_semantic_context(rows)
      when 'cell_type_ontology_term_id'
        append_organism_cell_type_semantic_context(rows)
      when 'tissue_ontology_term_id'
        append_organism_tissue_semantic_context(rows)
      when 'disease_ontology_term_id'
        rows << constraint_row(
          'Organism-specific rules',
          Rules.organism_specific_context_text(:disease_not_applicable),
          from_rules: true,
          rules_path: 'organism_specific_display.semantic_context.disease_not_applicable'
        )
      end
    end

    def append_organism_specific_yaml_constraints(rows, field_name, check_suffix)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        append_organism_specific_yaml_entries(rows, field_name, check_suffix, :missing_organism, organism)
        return
      end

      variant = organism_specific_yaml_variant(field_name, term_id)
      return if variant.blank?

      append_organism_specific_yaml_entries(rows, field_name, check_suffix, variant, organism)
    end

    def organism_specific_yaml_variant(field_name, term_id)
      case field_name
      when 'self_reported_ethnicity_ontology_term_id'
        term_id == Rules.organism_ethnicity_human ? :human : :non_human
      end
    end

    def append_organism_specific_yaml_entries(rows, field_name, check_suffix, variant, organism)
      entries = Rules.ontology_semantics_organism_specific_entries(field_name, check_suffix, variant: variant)

      entries.each_with_index do |entry, idx|
        rules_path = organism_specific_yaml_rules_path(field_name, check_suffix, variant, idx)
        append_organism_specific_yaml_entry(rows, entry, organism, rules_path)
      end
    end

    def organism_specific_yaml_rules_path(field_name, check_suffix, variant, idx)
      base = "ontology_semantics_display.organism_specific.#{field_name}"
      if variant == :missing_organism
        "#{base}._missing_organism.#{idx}"
      else
        check_key = Rules.ontology_semantics_organism_specific_check_key(field_name, check_suffix)
        "#{base}.#{check_key}.#{variant}.#{idx}"
      end
    end

    def append_organism_specific_yaml_entry(rows, entry, organism, rules_path)
      entry = entry.deep_symbolize_keys
      return rows << file_organism_row(organism) if entry[:from_file]

      label = entry[:label].to_s
      value = if entry[:context].present?
                Rules.organism_specific_context_text(entry[:context].to_sym)
              else
                entry[:value].to_s
              end
      return if label.blank? || value.blank?

      rows << constraint_row(label, value, from_rules: true, rules_path: rules_path)
    end

    def append_organism_dev_stage_semantic_context(rows)
      organism = organism_from_field_values
      mapping = Rules.organism_dev_stage_mapping
      term_id = organism[:term_id]

      if term_id.blank?
        rows << organism_context_row('Organism-specific prefix rules', :not_applicable_no_organism)
        return
      end

      expected_prefix = mapping[term_id]
      organism_display = organism_display_name(organism)

      if expected_prefix.blank?
        rows << organism_context_row(
          'Organism-specific prefix rules',
          :not_applicable_no_dev_stage_mapping,
          organism: organism_display,
          schema_version: Rules.schema_version
        )
        return
      end

      rows << organism_context_row('Organism-specific prefix rules', :applicable_under_category)
      rows << file_organism_row(organism)
      rows << organism_context_row(
        'Required development stage prefix',
        :required_dev_stage_prefix_template,
        prefix: expected_prefix
      )
      rows << organism_context_row('Interaction with semantic rules', :interaction_semantic_dev_stage)

      prefix_status = organism_dev_stage_prefix_status(expected_prefix)
      rows << prefix_status if prefix_status
    end

    def append_organism_cell_type_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        rows << organism_context_row('Organism-specific prefix rules', :not_applicable_no_organism)
        return
      end

      allowed_prefixes = Rules.organism_cell_type_prefixes_for(term_id)
      mapped = Rules.organism_cell_type_mapping.key?(term_id)
      prefix_list = allowed_prefixes.map { |prefix| "#{prefix}:*" }.join(' or ')

      rows << organism_context_row('Organism-specific prefix rules', :applicable_under_category)
      rows << file_organism_row(organism)
      rows << organism_context_row('Allowed cell type prefixes', :allowed_prefixes_template, prefixes: prefix_list)
      unless mapped
        rows << organism_context_row('Schema note', :schema_note_cell_type)
      end
      rows << organism_context_row('Interaction with semantic rules', :interaction_semantic_cell_type)

      prefix_status = organism_cell_type_prefix_status(allowed_prefixes)
      rows << prefix_status if prefix_status
    end

    def append_organism_tissue_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]
      tissue_type = first_obs_value('tissue_type')

      if term_id.blank?
        rows << organism_context_row('Organism-specific prefix rules', :not_applicable_no_organism)
        return
      end

      if tissue_type == 'cell line'
        rows << organism_context_row('Organism-specific prefix rules', :applicable_cell_line_tissue)
        rows << file_organism_row(organism)
        rows << constraint_row(
          'Required tissue format',
          Rules.organism_specific_display_constraint(:required_tissue_format),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.required_tissue_format'
        )
        return
      end

      allowed_prefixes = tissue_type == 'primary cell culture' ? Rules.organism_cell_type_prefixes_for(term_id) : Rules.organism_tissue_prefixes_for(term_id)
      prefix_list = allowed_prefixes.map { |prefix| "#{prefix}:*" }.join(' or ')
      suffix = tissue_type == 'primary cell culture' ? Rules.organism_specific_context_text(:allowed_tissue_prefixes_primary_cell_suffix) : ''
      rows << organism_context_row('Organism-specific prefix rules', :applicable_under_category)
      rows << file_organism_row(organism)
      rows << constraint_row(
        'Allowed tissue prefixes',
        Rules.organism_specific_context_text(:allowed_prefixes_template, prefixes: prefix_list) + suffix,
        from_rules: true,
        rules_path: 'organism_specific_display.semantic_context.allowed_prefixes_template'
      )
      prefix_status = organism_tissue_prefix_status(allowed_prefixes, tissue_type)
      rows << prefix_status if prefix_status
    end

    def append_organism_ethnicity_semantic_context(rows)
      organism = organism_from_field_values
      term_id = organism[:term_id]

      if term_id.blank?
        rows << organism_context_row('Organism-specific rules', :not_applicable_no_organism)
        return
      end

      if term_id == Rules.organism_ethnicity_human
        rows << organism_context_row('Organism-specific rules', :applicable_human_ethnicity)
        rows << file_organism_row(organism)
        rows << constraint_row(
          'Requirement',
          Rules.organism_specific_display_constraint(:human_ethnicity_requirement),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.human_ethnicity_requirement'
        )
        human_specials = Rules.organism_ethnicity_human_allowed_special_values
        if human_specials.any?
          rows << constraint_row(
            'Allowed special values',
            human_specials.join(', '),
            from_rules: true,
            rules_path: Rules.organism_specific_human_ethnicity_special_values_path
          )
        end
      else
        rows << organism_context_row('Organism-specific rules', :applicable_non_human_ethnicity)
        rows << file_organism_row(organism)
        rows << constraint_row(
          'Requirement',
          Rules.organism_specific_display_constraint(:non_human_ethnicity),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.non_human_ethnicity'
        )
      end
    end

    def organism_context_row(label, key, **kwargs)
      constraint_row(
        label,
        Rules.organism_specific_context_text(key, **kwargs),
        from_rules: true,
        rules_path: "organism_specific_display.semantic_context.#{key}"
      )
    end

    def append_organism_specific_check_constraints(rows, rule)
      case rule
      when 'development_stage'
        mapping = Rules.organism_dev_stage_mapping
        rows << constraint_row(
          'Organism to stage prefix',
          mapping.map { |org, prefix| "#{org} -> #{prefix}" }.join('; '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('development_stage', 'by_organism')
        )
        rows << constraint_row('Special values', 'unknown, na', from_rules: true, rules_path: 'ontology_fields.development_stage_ontology_term_id.special_values')
      when 'cell_type'
        rows << constraint_row(
          'Default prefixes',
          Rules.organism_cell_type_default_prefixes.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('cell_type', 'default_prefixes')
        )
        mapped = Rules.organism_cell_type_mapping.map { |org, prefixes| "#{org} -> #{prefixes.join('/')}" }.join('; ')
        if mapped.present?
          rows << constraint_row('Model organism prefixes', mapped, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('cell_type', 'by_organism'))
        end
        rows << constraint_row('Special values', 'unknown, na', from_rules: true, rules_path: 'ontology_fields.cell_type_ontology_term_id.special_values')
      when 'tissue'
        rows << constraint_row(
          'Default prefixes',
          Rules.organism_tissue_default_prefixes.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('tissue', 'default_prefixes')
        )
        mapped = Rules.organism_tissue_mapping.map { |org, prefixes| "#{org} -> #{prefixes.join('/')}" }.join('; ')
        if mapped.present?
          rows << constraint_row('Model organism prefixes', mapped, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('tissue', 'by_organism'))
        end
        rows << constraint_row(
          'Cell line tissue',
          Rules.organism_specific_display_constraint(:cell_line_tissue),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.cell_line_tissue'
        )
        rows << constraint_row(
          'Primary cell culture',
          Rules.organism_specific_display_constraint(:primary_cell_culture),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.primary_cell_culture'
        )
      when 'ethnicity'
        rows << constraint_row('Human organism', Rules.organism_ethnicity_human, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('ethnicity', 'human_organism'))
        rows << constraint_row(
          'Human allowed prefixes',
          Rules.organism_ethnicity_prefixes.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('ethnicity', 'prefixes')
        )
        rows << constraint_row(
          'Human special values',
          Rules.organism_ethnicity_special_values.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('ethnicity', 'special_values')
        )
        rows << constraint_row(
          'Non-human requirement',
          Rules.organism_specific_display_constraint(:non_human_ethnicity),
          from_rules: true,
          rules_path: 'organism_specific_display.constraints.non_human_ethnicity'
        )
      when 'sex'
        rows << constraint_row('Organism', Rules.organism_celegans_sex_organism, from_rules: true, rules_path: Rules.organism_specific_mappings_yaml_path('sex', 'celegans_organism'))
        rows << constraint_row(
          'Allowed sex terms',
          Rules.organism_celegans_sex_terms.join(', '),
          from_rules: true,
          rules_path: Rules.organism_specific_mappings_yaml_path('sex', 'celegans_terms')
        )
        rows << constraint_row('Special values', 'unknown, na', from_rules: true, rules_path: 'ontology_fields.sex_ontology_term_id.special_values')
      end
    end

    def organism_from_field_values
      term_key = Rules.field_path(@format, :uns, 'organism_ontology_term_id')
      label_key = @format == 'h5ad' ? 'uns/organism' : '/attrs/organism'
      term_id = Array(@field_values[term_key]).first.to_s.strip.presence
      label = Array(@field_values[label_key]).first.to_s.strip.presence
      { term_id: term_id, label: label }
    end

    def organism_display_name(organism)
      organism[:label].present? ? "#{organism[:label]} (#{organism[:term_id]})" : organism[:term_id].to_s
    end

    def organism_dev_stage_prefix_status(expected_prefix)
      dev_key = Rules.field_path(@format, :obs, 'development_stage_ontology_term_id')
      dev_values = split_field_values(@field_values[dev_key])
      return nil if dev_values.empty?

      invalid = dev_values.reject do |value|
        %w[unknown na].include?(value) || value.start_with?("#{expected_prefix}:")
      end

      organism_prefix_status_row(
        invalid.any? ? :prefix_status_dev_stage_unexpected : :prefix_status_dev_stage_satisfied,
        terms: invalid.uniq.first(5).join(', ')
      )
    end

    def organism_cell_type_prefix_status(allowed_prefixes)
      cell_key = Rules.field_path(@format, :obs, 'cell_type_ontology_term_id')
      cell_values = split_field_values(@field_values[cell_key])
      return nil if cell_values.empty?

      invalid = cell_values.reject do |value|
        %w[unknown na].include?(value) || allowed_prefixes.any? { |prefix| value.start_with?("#{prefix}:") }
      end

      organism_prefix_status_row(
        invalid.any? ? :prefix_status_cell_type_unexpected : :prefix_status_cell_type_satisfied,
        terms: invalid.uniq.first(5).join(', ')
      )
    end

    def organism_tissue_prefix_status(allowed_prefixes, tissue_type)
      tissue_key = Rules.field_path(@format, :obs, 'tissue_ontology_term_id')
      tissue_values = split_field_values(@field_values[tissue_key])
      return nil if tissue_values.empty?

      invalid = if tissue_type == 'cell line'
                  tissue_values.reject { |value| value.start_with?('CVCL_') }
                else
                  special = tissue_type == 'primary cell culture' ? %w[unknown na] : []
                  tissue_values.reject do |value|
                    special.include?(value) || allowed_prefixes.any? { |prefix| value.start_with?("#{prefix}:") }
                  end
                end

      organism_prefix_status_row(
        invalid.any? ? :prefix_status_tissue_unexpected : :prefix_status_tissue_satisfied,
        terms: invalid.uniq.first(5).join(', ')
      )
    end

    def organism_prefix_status_row(key, terms: '')
      value = if key.to_s.include?('unexpected')
                Rules.organism_specific_context_text(key, terms: terms)
              else
                Rules.organism_specific_context_text(key)
              end
      constraint_row('Organism-specific prefix status', value, from_rules: true, rules_path: "organism_specific_display.semantic_context.#{key}")
    end

    def first_obs_value(field_name)
      Array(@field_values[Rules.field_path(@format, :obs, field_name)]).first.to_s.strip.presence
    end

    def split_field_values(raw)
      Array(raw).flat_map { |value| value.to_s.split(' || ') }.map(&:strip).reject(&:blank?)
    end

    def presence_check?
      return true if Rules.presence_check_id?(@check_id)

      self.class.presence_check_message?(@message)
    end

    def obs_presence_check?(category_id)
      presence_check? || category_id.to_s == 'obs.required_presence'
    end

    def ontology_format_check?
      return true if Rules.ontology_format_check_id?(@check_id)

      self.class.ontology_format_check_message?(@message)
    end

    def format_check_constraints(field_name)
      ontology_cfg = Rules.ontology_field(field_name)
      cfg = Rules.ontology_term_format_config
      rows = []

      rows << constraint_row(
        'Requirement',
        Rules.ontology_format_requirement_text(field_name),
        from_rules: true,
        rules_path: Rules.ontology_format_requirement_rules_path(field_name)
      )

      if Rules.ontology_allows_cellosaurus_format?(field_name)
        rows << constraint_row(
          'Cellosaurus format',
          cfg[:cellosaurus_requirement],
          from_rules: true,
          rules_path: 'ontology_term_formats.cellosaurus.requirement'
        )
      end

      append_prefix_rows(rows, ontology_cfg, field_name: field_name)
      append_ontology_field_special_rows(rows, ontology_cfg, field_name: field_name)
      rows
    end

    def semantic_ontology_field?(field_name)
      field_name.end_with?('_ontology_term_id')
    end

    def required_observation_field?(field_name)
      Rules.required_obs_fields.include?(field_name)
    end

    def required_uns_field?(field_name)
      Rules.required_uns_fields.include?(field_name)
    end

    def ensembl_uns_field?(field_name)
      %w[ensembl_release ensembl_database ensembl_assembly].include?(field_name)
    end

    def uns_metadata_field_name(field)
      return nil unless field.match?(/\A(uns\/|\/attrs\/)/)

      name = field.split('/').last.to_s
      return name if required_uns_field?(name) || ensembl_uns_field?(name)

      nil
    end

    def obs_metadata_field_name(field)
      return nil unless field.match?(/\A(obs\/|\/col_attrs\/)/)

      name = field.split('/').last.to_s
      required_observation_field?(name) ? name : nil
    end

    def uns_field_summary(field_name)
      Rules.field_summary_text(:uns, field_name) || Rules.default_summary_text(:required_uns)
    end

    def append_uns_field_constraints(rows, field_name)
      case field_name
      when 'organism_ontology_term_id'
        ontology_cfg = Rules.ontology_field(field_name)
        append_prefix_rows(rows, ontology_cfg, field_name: field_name)
      when 'organism'
        rows << constraint_row('Paired term field', 'organism_ontology_term_id', from_rules: true, rules_path: 'label_pairs.organism_ontology_term_id')
        append_field_constraint_rows(rows, :uns, field_name)
      when 'schema_version'
        rows << constraint_row('Reference version', Rules.schema_version, from_rules: true, rules_path: 'schema.version')
        rows << constraint_row('Required identifier', Rules.schema_hash[:schema_version].to_s, from_rules: true, rules_path: 'schema.schema_version')
      when 'schema_reference'
        rows << constraint_row('Reference schema URL', Rules.schema_hash[:source_url].to_s, from_rules: true, rules_path: 'schema.source_url')
      end
    end

    def append_ensembl_uns_constraints(rows, field_name)
      case field_name
      when 'ensembl_database'
        rows << constraint_row(
          'Allowed values',
          Rules.ensembl_database_values.join(', '),
          from_rules: true,
          rules_path: 'constants.ensembl_database_values'
        )
      else
        append_field_constraint_rows(rows, :uns, field_name) if Rules.field_constraint_entries(:uns, field_name).any?
      end
    end

    def required_var_field?(field_name)
      Rules.required_var_fields.include?(field_name)
    end

    def var_metadata_field_name(field)
      return nil if Rules.var_index_field?(field)
      return nil unless field.match?(/\A(var\/|\/row_attrs\/)/)

      name = field.split('/').last.to_s
      required_var_field?(name) ? name : nil
    end

    def var_index_storage_path?(field)
      field.to_s == Rules.var_index_schema_field ||
        field.to_s.match?(/\A(var\/_index|var\/index|\/row_attrs\/(_index|index|feature_id))\z/)
    end

    def var_field_summary(field_name)
      Rules.field_summary_text(:var, field_name) || Rules.default_summary_text(:required_var)
    end

    def append_var_field_constraints(rows, field_name)
      append_field_constraint_rows(rows, :var, field_name)
      case field_name
      when 'feature_biotype'
        rows << constraint_row(
          'Allowed values',
          Rules.enum_field_values('feature_biotype').join(', '),
          from_rules: true,
          rules_path: 'enum_fields.feature_biotype.values'
        )
      when 'feature_reference'
        rows << constraint_row(
          'Allowed values',
          Rules.feature_reference_taxa.keys.join(', '),
          from_rules: true,
          rules_path: 'constants.feature_reference_taxa'
        )
      end
    end

    def enum_field?(field_name)
      Rules.enum_field_values(field_name).present?
    end

    def ontology_term_field?(field_name)
      field_name.end_with?('_ontology_term_id') || field_name == 'organism'
    end
  end
end
