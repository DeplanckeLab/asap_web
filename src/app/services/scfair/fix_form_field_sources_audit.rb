# frozen_string_literal: true

module Scfair
  # Phase 0 audit: compare compliance fix-form field definitions in
  # ontology_term_types against rules.yaml (the intended source of truth).
  #
  # Classifies each OTT compliance row and reports divergences so we can migrate
  # fix-form generation to rules.yaml without silent drift.
  class FixFormFieldSourcesAudit
    CLASSIFICATIONS = {
      paired_ontology: 'A',
      enum_obs: 'B',
      free_text_obs: 'B',
      global_auto_fill: 'C',
      global_enum: 'C',
      global_free_text: 'C'
    }.freeze

    MISPLACED_IN_OTT = %i[enum_obs free_text_obs global_auto_fill global_enum global_free_text].freeze

    Result = Struct.new(
      :schema_id,
      :ott_rows,
      :expected_rows,
      :classifications,
      :divergences,
      :misplaced_in_ott,
      :missing_from_ott,
      :unexpected_in_ott,
      keyword_init: true
    ) do
      def divergences?
        divergences.any? || misplaced_in_ott.any? || missing_from_ott.any? || unexpected_in_ott.any?
      end
    end

    def self.call(schema_id: nil, ott_records: nil)
      new(schema_id: schema_id, ott_records: ott_records).call
    end

    def initialize(schema_id: nil, ott_records: nil)
      @schema_id = schema_id
      @ott_records = ott_records
    end

    def self.format_report(result)
      Report.new(result).to_s
    end

    def call
      rules = resolve_rules
      co_id_to_tag = CellOntology.pluck(:id, :tag).to_h
      ott_rows = load_ott_rows(co_id_to_tag)
      expected_rows = build_expected_rows(rules)
      expected_by_term_path = expected_rows.index_by { |row| row[:term_path] }
      ott_by_term_path = ott_rows.index_by { |row| row[:term_path] }

      classifications = ott_rows.map { |row| classify_row(row) }
      ott_required = ott_required_rows(expected_rows)
      divergences = compare_rows(ott_rows, expected_by_term_path, rules)
      misplaced_in_ott = classifications.select { |c| MISPLACED_IN_OTT.include?(c[:classification]) }
      missing_from_ott = ott_required.reject { |row| ott_by_term_path.key?(row[:term_path]) }
      required_group_ids = ott_required.map { |row| row[:id].to_s }.to_set
      unexpected_in_ott = ott_rows.reject { |row| required_group_ids.include?(row[:field_group_id]) }

      Result.new(
        schema_id: rules.schema_id,
        ott_rows: ott_rows,
        expected_rows: expected_rows,
        classifications: classifications,
        divergences: divergences,
        misplaced_in_ott: misplaced_in_ott,
        missing_from_ott: missing_from_ott,
        unexpected_in_ott: unexpected_in_ott
      )
    end

    private

    def resolve_rules
      if @schema_id.present?
        Scfair::Rules.for(@schema_id)
      else
        Scfair::Rules.for(Scfair::Rules::DEFAULT_SCHEMA_ID)
      end
    end

    def load_ott_rows(co_id_to_tag)
      records = @ott_records || OntologyTermType.compliance_field_groups.to_a
      records.map do |ott|
        fg = ott.to_field_group(co_id_to_tag)
        {
          ott_id: ott.id,
          ott_name: ott.name.to_s,
          field_group_id: fg[:id].to_s,
          term_path: fg[:term_path].to_s,
          label_path: fg[:label_path].to_s.presence,
          layer: fg[:type] == :global_attr ? :uns : :obs,
          ontology_prefixes: Array(fg[:term_ontology_prefixes]).map(&:to_s).sort,
          enum_values: Array(fg[:term_valid_values]).map(&:to_s).sort,
          multi_value: !!fg[:multi_value],
          auto_fill: fg[:auto_from_project],
          has_cell_ontology_ids: ott.cell_ontology_ids_list.any?
        }
      end
    end

    def build_expected_rows(rules)
      if rules.fix_form_field_group_definitions.any?
        return build_expected_rows_from_fix_form(rules)
      end

      build_expected_rows_legacy(rules)
    end

    def build_expected_rows_from_fix_form(rules)
      rules.fix_form_field_group_definitions.map do |entry|
        term_field = entry[:term_field]
        layer = entry[:layer]
        label_field = entry[:label_field]

        {
          id: entry[:id],
          term_field: term_field,
          label_field: label_field,
          layer: layer,
          term_path: rules.field_path('loom', layer, term_field),
          label_path: label_field.present? ? rules.field_path('loom', layer, label_field) : nil,
          classification: classification_from_field_kind(entry[:field_kind], layer),
          ontology_prefixes: rules.ontology_prefixes(term_field).sort,
          enum_values: expected_enum_for_entry(rules, entry).sort,
          multi_value: rules.multi_value_field?(term_field),
          auto_fill: normalize_auto_fill_key(entry[:auto_fill])
        }
      end
    end

    def ott_required_rows(expected_rows)
      expected_rows.select { |row| ott_link_required?(row) }
    end

    def ott_link_required?(row)
      row[:classification] == :paired_ontology && row[:auto_fill].blank?
    end

    def build_expected_rows_legacy(rules)
      rows = []
      label_only_fields = rules.label_pairs.values.to_set

      rules.label_pairs.each do |id_field, label_field|
        layer = field_layer(rules, id_field)
        next unless required_field?(rules, layer, id_field)

        rows << build_row(
          rules: rules,
          id: group_id_for(id_field),
          term_field: id_field,
          label_field: label_field,
          layer: layer,
          kind: :paired_ontology
        )
      end

      rules.required_obs_fields.each do |field|
        next if rules.label_pairs.key?(field)
        next if label_only_fields.include?(field)

        rows << build_row(
          rules: rules,
          id: field,
          term_field: field,
          label_field: nil,
          layer: :obs,
          kind: enum_kind(rules, field, :obs)
        )
      end

      rules.required_uns_fields.each do |field|
        next if rules.label_pairs.key?(field)
        next if label_only_fields.include?(field)

        rows << build_row(
          rules: rules,
          id: field,
          term_field: field,
          label_field: nil,
          layer: :uns,
          kind: uns_standalone_kind(rules, field)
        )
      end

      rows
    end

    def classification_from_field_kind(field_kind, layer)
      layer_sym = layer.to_sym
      case field_kind.to_sym
      when :ontology_pair then :paired_ontology
      when :enum
        case layer_sym
        when :uns then :global_enum
        when :var then :enum_var
        else :enum_obs
        end
      when :boolean
        layer_sym == :var ? :enum_var : :enum_obs
      when :free_text
        case layer_sym
        when :uns then :global_free_text
        when :var then :free_text_var
        else :free_text_obs
        end
      when :auto_fill
        :global_auto_fill
      else
        layer_sym == :var ? :free_text_var : :free_text_obs
      end
    end

    def expected_enum_for_entry(rules, entry)
      if entry[:allowed_values].present?
        return Array(entry[:allowed_values]).map(&:to_s)
      end

      expected_enum_values(rules, entry[:term_field])
    end

    def normalize_auto_fill_key(value)
      case value.to_s
      when 'organism' then :organism
      when 'title' then :title
      when 'schema_version' then :schema_version
      when 'schema_reference' then :schema_reference
      when 'ensembl_release' then :ensembl_release
      when 'ensembl_database' then :ensembl_database
      when 'ensembl_assembly' then :ensembl_assembly
      else value.presence
      end
    end

    def build_row(rules:, id:, term_field:, label_field:, layer:, kind:)
      term_path = rules.field_path('loom', layer, term_field)
      label_path = label_field.present? ? rules.field_path('loom', layer, label_field) : nil

      {
        id: id,
        term_field: term_field,
        label_field: label_field,
        layer: layer,
        term_path: term_path,
        label_path: label_path,
        classification: kind,
        ontology_prefixes: rules.ontology_prefixes(term_field).sort,
        enum_values: expected_enum_values(rules, term_field).sort,
        multi_value: rules.multi_value_field?(term_field),
        auto_fill: auto_fill_kind(term_field)
      }
    end

    def field_layer(rules, id_field)
      layer = rules.ontology_field(id_field)[:layer]
      return layer.to_sym if layer.present?

      rules.required_uns_fields.include?(id_field) ? :uns : :obs
    end

    def required_field?(rules, layer, field)
      case layer
      when :uns then rules.required_uns_fields.include?(field)
      when :obs then rules.required_obs_fields.include?(field)
      else false
      end
    end

    def group_id_for(term_field)
      if term_field.end_with?('_ontology_term_id')
        term_field.sub(/_ontology_term_id\z/, '')
      else
        term_field
      end
    end

    def enum_kind(rules, field, layer)
      expected_enum_values(rules, field).any? ? :"enum_#{layer}" : :"free_text_#{layer}"
    end

    def uns_standalone_kind(rules, field)
      return :global_auto_fill if auto_fill_kind(field)
      return :global_enum if expected_enum_values(rules, field).any?

      :global_free_text
    end

    def auto_fill_kind(term_field)
      case term_field
      when 'organism_ontology_term_id' then :organism
      when 'title' then :title
      when 'schema_version' then :schema_version
      when 'schema_reference' then :schema_reference
      when 'ensembl_release' then :ensembl_release
      when 'ensembl_database' then :ensembl_database
      when 'ensembl_assembly' then :ensembl_assembly
      end
    end

    def expected_enum_values(rules, term_field)
      values = rules.enum_field_values(term_field)
      return values if values.any?
      return rules.ensembl_database_values if term_field == 'ensembl_database'

      []
    end

    def classify_row(row)
      classification =
        if row[:auto_fill].present?
          :global_auto_fill
        elsif row[:ontology_prefixes].any? || row[:has_cell_ontology_ids]
          row[:label_path].present? ? :paired_ontology : :paired_ontology
        elsif row[:enum_values].any?
          row[:layer] == :uns ? :global_enum : :enum_obs
        elsif row[:layer] == :uns
          :global_free_text
        else
          :free_text_obs
        end

      row.merge(
        classification: classification,
        classification_code: CLASSIFICATIONS[classification]
      )
    end

    def compare_rows(ott_rows, expected_by_term_path, rules)
      divergences = []

      ott_rows.each do |ott|
        expected = expected_by_term_path[ott[:term_path]]
        unless expected
          next
        end

        compare_value(divergences, ott, expected, :label_path, 'label_path')
        compare_prefixes(divergences, ott, expected)
        compare_enum_values(divergences, ott, expected, rules)
        compare_value(divergences, ott, expected, :multi_value, 'multi_value')
        compare_auto_fill(divergences, ott, expected)
      end

      divergences
    end

    def compare_value(divergences, ott, expected, key, label)
      ott_val = ott[key]
      exp_val = expected[key]
      return if ott_val == exp_val

      divergences << divergence(
        ott,
        check: label,
        ott_value: ott_val,
        rules_value: exp_val,
        rules_path: rules_path_for(expected, label)
      )
    end

    def compare_prefixes(divergences, ott, expected)
      return if ott[:ontology_prefixes] == expected[:ontology_prefixes]

      divergences << divergence(
        ott,
        check: 'ontology_prefixes',
        ott_value: ott[:ontology_prefixes],
        rules_value: expected[:ontology_prefixes],
        rules_path: "ontology_fields.#{expected[:term_field]}.prefixes"
      )
    end

    def compare_enum_values(divergences, ott, expected, rules)
      return if ott[:enum_values] == expected[:enum_values]

      divergences << divergence(
        ott,
        check: 'enum_values',
        ott_value: ott[:enum_values],
        rules_value: expected[:enum_values],
        rules_path: enum_rules_path(rules, expected[:term_field])
      )
    end

    def compare_auto_fill(divergences, ott, expected)
      ott_auto = normalize_auto_fill(ott[:auto_fill])
      exp_auto = expected[:auto_fill]
      return if ott_auto == exp_auto

      divergences << divergence(
        ott,
        check: 'auto_fill',
        ott_value: ott_auto,
        rules_value: exp_auto,
        rules_path: 'fix_form (planned) / field metadata'
      )
    end

    def normalize_auto_fill(value)
      case value
      when true then :organism
      when :title, :schema_version, :schema_reference, :organism then value
      else value.presence
      end
    end

    def enum_rules_path(rules, term_field)
      if term_field == 'ensembl_database'
        'constants.ensembl_database_values'
      elsif rules.enum_field_values(term_field).any?
        "enum_fields.#{term_field}.values"
      else
        nil
      end
    end

    def rules_path_for(expected, check)
      case check
      when 'label_path'
        "label_pairs.#{expected[:term_field]}"
      when 'multi_value'
        "multi_value_fields.fields.#{expected[:term_field]}"
      else
        nil
      end
    end

    def divergence(ott, check:, ott_value:, rules_value:, rules_path:)
      {
        ott_id: ott[:ott_id],
        ott_name: ott[:ott_name],
        field_group_id: ott[:field_group_id],
        term_path: ott[:term_path],
        check: check,
        ott_value: ott_value,
        rules_value: rules_value,
        rules_path: rules_path
      }
    end

    # Human-readable audit output for rake / CI.
    class Report
      def initialize(result)
        @result = result
      end

      def to_s
        lines = []
        lines << "Fix form field sources audit (schema: #{@result.schema_id})"
        lines << '=' * 72
        lines << ''
        lines << classification_summary
        lines << ''
        lines << misplaced_section
        lines << ''
        lines << divergences_section
        lines << ''
        lines << missing_section
        lines << ''
        lines << unexpected_section
        lines << ''
        lines << footer
        lines.join("\n")
      end

      private

      def classification_summary
        counts = @result.classifications.group_by { |c| c[:classification] }
                         .transform_values(&:size)
        lines = ['OTT compliance field group classifications:']
        Scfair::FixFormFieldSourcesAudit::CLASSIFICATIONS.each do |key, code|
          label = key.to_s.tr('_', ' ')
          count = counts[key] || 0
          lines << "  [#{code}] #{label}: #{count}"
        end
        lines << "  Total OTT rows: #{@result.ott_rows.size}"
        lines << "  Expected fix_form field groups (rules.yaml): #{@result.expected_rows.size}"
        lines << "  OTT rows required (paired ontology, non-auto-fill): #{ott_required_count}"
        lines.join("\n")
      end

      def ott_required_count
        @result.expected_rows.count do |row|
          row[:classification] == :paired_ontology && row[:auto_fill].blank?
        end
      end

      def misplaced_section
        rows = @result.misplaced_in_ott
        return 'Misplaced in ontology_term_types (should be rules.yaml only): none' if rows.empty?

        lines = [
          "Misplaced in ontology_term_types (#{rows.size} row(s); should be rules.yaml only):"
        ]
        rows.each do |row|
          lines << "  - #{row[:ott_name]} (id=#{row[:ott_id]}, field_group=#{row[:field_group_id]}, " \
                   "path=#{row[:term_path]}, class=#{row[:classification]})"
        end
        lines.join("\n")
      end

      def divergences_section
        rows = @result.divergences
        return 'Value divergences (OTT vs rules.yaml): none' if rows.empty?

        lines = ["Value divergences (#{rows.size}):"]
        rows.each do |d|
          lines << "  - #{d[:ott_name]} / #{d[:check]}:"
          lines << "      OTT:   #{format_value(d[:ott_value])}"
          lines << "      Rules: #{format_value(d[:rules_value])} (#{d[:rules_path]})"
        end
        lines.join("\n")
      end

      def missing_section
        rows = @result.missing_from_ott
        return 'Missing from ontology_term_types (paired ontology OTT expected): none' if rows.empty?

        lines = ["Missing from ontology_term_types (#{rows.size} paired ontology row(s) expected):"]
        rows.each do |row|
          lines << "  - #{row[:term_path]} (#{row[:classification]}, id=#{row[:id]})"
        end
        lines.join("\n")
      end

      def unexpected_section
        rows = @result.unexpected_in_ott
        return 'Unexpected in ontology_term_types (not a required paired ontology OTT): none' if rows.empty?

        lines = ["Unexpected in ontology_term_types (#{rows.size}):"]
        rows.each do |row|
          lines << "  - #{row[:ott_name]} (path=#{row[:term_path]})"
        end
        lines.join("\n")
      end

      def footer
        if @result.divergences?
          'RESULT: issues found -- fix-form field sources are out of sync.'
        else
          'RESULT: OK -- OTT rows align with rules.yaml (misplaced rows may still need migration).'
        end
      end

      def format_value(value)
        case value
        when Array then value.inspect
        when nil then 'nil'
        else value.inspect
        end
      end
    end
  end
end
