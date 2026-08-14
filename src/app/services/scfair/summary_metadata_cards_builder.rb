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
      ontology_by_tag = AsapData::OntologyIdentifierUrl.ontology_by_tag_index

      relevant_definitions.filter_map do |entry|
        build_card(entry, field_values, format, ontology_by_tag)
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

    def build_card(entry, field_values, format, ontology_by_tag)
      id = entry[:id].to_s
      terms = build_term_entries(entry, field_values, format, ontology_by_tag)
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
        examples: terms.first(EXAMPLE_LIMIT).map { |term| term[:label] },
        terms: terms
      }
    end

    def build_term_entries(entry, field_values, format, ontology_by_tag)
      layer = entry[:layer].to_sym
      term_field = entry[:term_field].to_s
      label_field = entry[:label_field].to_s.presence
      term_path = @rules.field_path(format, layer, term_field)
      label_path = label_field.present? ? @rules.field_path(format, layer, label_field) : nil

      pairs = label_pairs_for(field_values, term_path)
      entries =
        if pairs.any?
          pairs.map { |identifier, label| term_entry(label: label, identifier: identifier, ontology_by_tag: ontology_by_tag) }
        else
          labels = unique_values(field_values, label_path)
          ids = unique_values(field_values, term_path)
          if labels.any? && ids.any? && labels.size == ids.size
            labels.zip(ids).map do |label, identifier|
              term_entry(label: label, identifier: identifier, ontology_by_tag: ontology_by_tag)
            end
          elsif labels.any?
            labels.map { |label| term_entry(label: label, identifier: nil, ontology_by_tag: ontology_by_tag) }
          else
            ids.map { |identifier| term_entry(label: identifier, identifier: identifier, ontology_by_tag: ontology_by_tag) }
          end
        end

      sort_term_entries(entries)
    end

    def label_pairs_for(field_values, term_path)
      return [] if term_path.blank?

      delimiter = @rules.multi_value_delimiter.to_s
      delimiter = ' || ' if delimiter.blank?

      pair_keys = ["#{term_path}#label_pairs"]
      if term_path.start_with?('/col_attrs/')
        pair_keys << "#{term_path.sub(%r{\A/col_attrs/}, 'obs/')}#label_pairs"
      elsif term_path.start_with?('/attrs/')
        pair_keys << "#{term_path.sub(%r{\A/attrs/}, 'uns/')}#label_pairs"
      elsif term_path.start_with?('obs/')
        pair_keys << "#{term_path.sub(%r{\Aobs/}, '/col_attrs/')}#label_pairs"
      elsif term_path.start_with?('uns/')
        pair_keys << "#{term_path.sub(%r{\Auns/}, '/attrs/')}#label_pairs"
      end

      tokens = pair_keys.flat_map { |key| Array(field_values[key]) }
      tokens.filter_map do |token|
        parts = token.to_s.split(delimiter, 2).map(&:strip)
        next if parts.size < 2 || parts[0].blank? || parts[1].blank?

        [parts[0], parts[1]]
      end.uniq
    end

    def term_entry(label:, identifier:, ontology_by_tag:)
      label_s = label.to_s.strip
      identifier_s = identifier.to_s.strip.presence
      display = label_s.presence || identifier_s
      return nil if display.blank?

      # Special / enum values (unknown, na, cell, ...) are not ontology terms: no id on the right.
      ontology_identifier =
        if identifier_s.present? && AsapData::OntologyIdentifierUrl.prefix_for(identifier_s).present?
          identifier_s
        end
      {
        label: display,
        identifier: ontology_identifier,
        url: ontology_identifier.present? ? AsapData::OntologyIdentifierUrl.url_for(ontology_identifier, ontology_by_tag: ontology_by_tag) : nil
      }
    end

    # Terms that start with a number come first (by that number), then the rest A-Z.
    def sort_term_entries(entries)
      Array(entries).compact.sort_by { |entry| term_sort_key(entry[:label]) }
    end

    def term_sort_key(term)
      text = term.to_s
      if (match = text.match(/\A(\d+)/))
        [0, match[1].to_i, text.downcase]
      else
        [1, 0, text.downcase]
      end
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
