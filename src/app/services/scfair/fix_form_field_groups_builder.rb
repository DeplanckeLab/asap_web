# frozen_string_literal: true

module Scfair
  # Builds compliance fix-form field group hashes from fix_form.field_groups in rules.yaml.
  class FixFormFieldGroupsBuilder
    def self.call(rules: nil, format: 'loom', ontology_term_type_id_map: nil)
      new(rules: rules, format: format, ontology_term_type_id_map: ontology_term_type_id_map).call
    end

    def initialize(rules: nil, format: 'loom', ontology_term_type_id_map: nil)
      @rules = rules || Rules.current_bundle
      @format = format.to_s
      @ontology_term_type_id_map = ontology_term_type_id_map || {}
    end

    def call
      @rules.fix_form_field_group_definitions.sort_by { |entry| entry[:display_order] }.map do |entry|
        build_group(entry)
      end
    end

    private

    def build_group(entry)
      term_field = entry[:term_field].to_s
      layer = entry[:layer].to_sym
      term_path = @rules.field_path(@format, layer, term_field)
      label_field = entry[:label_field].to_s.presence
      label_path = label_field.present? ? @rules.field_path(@format, layer, label_field) : nil

      group = {
        id: entry[:id].to_s,
        label: entry[:label].to_s,
        description: entry[:description].to_s,
        type: group_type_for_layer(layer),
        term_path: term_path,
        label_path: label_path,
        multi_value: @rules.multi_value_field?(term_field),
        field_kind: entry[:field_kind].to_sym
      }

      ott_id = @ontology_term_type_id_map[entry[:id].to_s]
      group[:ontology_term_type_id] = ott_id if ott_id.present? && entry[:field_kind] == :ontology_pair

      auto_fill = entry[:auto_fill]
      if auto_fill.present?
        group[:auto_from_project] = normalize_auto_fill(auto_fill)
      end

      prefixes = @rules.ontology_prefixes(term_field)
      group[:term_ontology_prefixes] = prefixes if prefixes.any?

      format_hint = entry[:term_format_hint].to_s.presence || @rules.ontology_format_example(term_field).presence
      group[:term_format_hint] = format_hint if format_hint.present?

      enum_values = enum_values_for(entry, term_field)
      group[:term_valid_values] = enum_values if enum_values.any?

      default_fix_value = entry[:default_fix_value].to_s.presence
      group[:default_fix_value] = default_fix_value if default_fix_value.present?

      enrich_constraints!(group, term_field)
      group
    end

    def enum_values_for(entry, term_field)
      return [] if entry[:field_kind].to_sym == :auto_fill

      if entry[:allowed_values].present?
        return Array(entry[:allowed_values]).map(&:to_s)
      end

      values = @rules.enum_field_values(term_field)
      return values if values.any?
      return @rules.ensembl_database_values if term_field == 'ensembl_database'

      []
    end

    def enrich_constraints!(group, term_field)
      group[:multi_value] = @rules.multi_value_field?(term_field)
      group[:multi_value_sorted] = @rules.multi_value_sorted_field?(term_field) if group[:multi_value]

      valid_terms = @rules.ontology_valid_terms(term_field)
      if valid_terms.present?
        allowed_terms = valid_terms.map { |identifier, name| { identifier: identifier, name: name } }
        # Free-choice specials for restricted dropdowns. Values forced by CF-2
        # when tissue_type is "cell line" (e.g. sex -> na) stay out of the menu;
        # the cell-line constraint applies them automatically.
        cell_line_forced = @rules.cell_line_forced_fields
          .select { |entry| entry[:field].to_s == term_field }
          .map { |entry| entry[:value].to_s }
        @rules.special_values_for_field(@format, term_field).each do |value|
          next if cell_line_forced.include?(value)
          next if allowed_terms.any? { |term| term[:identifier] == value }

          allowed_terms << { identifier: value, name: value }
        end
        group[:allowed_terms] = allowed_terms
      end

      banned = @rules.ontology_banned_terms(term_field)
      group[:banned_term_ids] = banned if banned.any?
    end

    def normalize_auto_fill(value)
      case value.to_s
      when 'title' then :title
      when 'schema_version' then :schema_version
      when 'schema_reference' then :schema_reference
      when 'organism' then true
      else value.to_sym
      end
    end

    def group_type_for_layer(layer)
      case layer
      when :uns then :global_attr
      when :var then :row_attr
      else :col_attr
      end
    end
  end
end
