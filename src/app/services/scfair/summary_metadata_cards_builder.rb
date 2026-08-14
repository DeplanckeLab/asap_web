# frozen_string_literal: true

module Scfair
  # Builds summary-view metadata cards for scFAIR-compliant projects.
  # Categories come from fix_form.field_groups in rules.yaml; colors/icons from
  # OntologyTermType rows matched by field_group_id.
  class SummaryMetadataCardsBuilder
    EXAMPLE_LIMIT = 3
    # Explore-facing enum fields (also listed on sc-fair.org/explore).
    EXPLORE_ENUM_IDS = %w[tissue_type suspension_type].freeze

    def self.call(validation_result:, ontology_term_types_by_field_group_id: nil, rules: nil)
      new(
        validation_result: validation_result,
        ontology_term_types_by_field_group_id: ontology_term_types_by_field_group_id,
        rules: rules
      ).call
    end

    def initialize(validation_result:, ontology_term_types_by_field_group_id: nil, rules: nil)
      @validation_result = validation_result || {}
      @ontology_term_types_by_field_group_id = ontology_term_types_by_field_group_id || {}
      @rules = rules || Rules.current_bundle
    end

    def call
      field_values = extract_field_values
      format = detect_format(field_values)

      relevant_definitions.filter_map do |entry|
        build_card(entry, field_values, format)
      end
    end

    private

    def relevant_definitions
      @rules.fix_form_field_group_definitions.select do |entry|
        kind = entry[:field_kind].to_s
        id = entry[:id].to_s
        kind == 'ontology_pair' || EXPLORE_ENUM_IDS.include?(id)
      end.sort_by { |entry| entry[:display_order].to_i }
    end

    def build_card(entry, field_values, format)
      id = entry[:id].to_s
      layer = entry[:layer].to_sym
      term_field = entry[:term_field].to_s
      label_field = entry[:label_field].to_s.presence

      term_path = @rules.field_path(format, layer, term_field)
      label_path = label_field.present? ? @rules.field_path(format, layer, label_field) : nil

      labels = unique_values(field_values, label_path)
      ids = unique_values(field_values, term_path)
      terms = labels.presence || ids
      return if terms.empty?

      ott = @ontology_term_types_by_field_group_id[id]
      style = OntologyTermType.explore_style_for(id)
      {
        id: id,
        label: entry[:label].to_s.presence || id.humanize,
        description: entry[:description].to_s,
        color: ott&.explore_color || style[:color],
        icon: ott&.explore_icon || style[:icon],
        term_count: terms.size,
        examples: terms.first(EXAMPLE_LIMIT),
        terms: terms
      }
    end

    def extract_field_values
      raw = @validation_result[:field_values] || @validation_result['field_values'] || {}
      raw.each_with_object({}) do |(key, value), hash|
        hash[key.to_s] = Array(value)
      end
    end

    def detect_format(field_values)
      keys = field_values.keys
      return 'h5ad' if keys.any? { |key| key.start_with?('obs/', 'uns/', 'var/') }
      return 'loom' if keys.any? { |key| key.start_with?('/col_attrs/', '/attrs/', '/row_attrs/') }

      'loom'
    end

    def unique_values(field_values, path)
      return [] if path.blank?

      candidates = [path, path.to_s]
      # Also try the alternate format path for the same logical field.
      if path.start_with?('/col_attrs/')
        candidates << path.sub(%r{\A/col_attrs/}, 'obs/')
      elsif path.start_with?('/attrs/')
        candidates << path.sub(%r{\A/attrs/}, 'uns/')
      elsif path.start_with?('/row_attrs/')
        candidates << path.sub(%r{\A/row_attrs/}, 'var/')
      elsif path.start_with?('obs/')
        candidates << path.sub(%r{\Aobs/}, '/col_attrs/')
      elsif path.start_with?('uns/')
        candidates << path.sub(%r{\Auns/}, '/attrs/')
      elsif path.start_with?('var/')
        candidates << path.sub(%r{\Avar/}, '/row_attrs/')
      end

      values = candidates.flat_map { |candidate| Array(field_values[candidate]) }
      delimiter = @rules.multi_value_delimiter.to_s
      values
        .flat_map { |value| delimiter.present? ? value.to_s.split(delimiter) : [value.to_s] }
        .map { |value| value.to_s.strip }
        .reject(&:blank?)
        .uniq
    end
  end
end
