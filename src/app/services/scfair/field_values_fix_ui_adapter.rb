# frozen_string_literal: true

module Scfair
  # Adapts cached compliance field_values into the shape expected by the fix UI.
  class FieldValuesFixUiAdapter
    def self.call(field_values:, field_paths:, paired_paths: [])
      new(field_values: field_values, field_paths: field_paths, paired_paths: paired_paths).call
    end

    def initialize(field_values:, field_paths:, paired_paths: [])
      @field_values = field_values || {}
      @field_paths = Array(field_paths)
      @paired_paths = Array(paired_paths)
    end

    def call
      result = {}

      @field_paths.each do |fp|
        vals = Array(@field_values[fp] || @field_values[fp.to_sym]).map(&:to_s).reject(&:blank?)
        result[fp] = vals.sort
      end

      @paired_paths.each do |term_fp, label_fp|
        pair_key = "#{term_fp}#label_pairs"
        tokens = Array(@field_values[pair_key] || @field_values[pair_key.to_sym])
        ordered_pairs = tokens.filter_map do |token|
          parts = token.to_s.split(Scfair::Rules.multi_value_delimiter, 2).map(&:strip)
          next if parts.size < 2 || parts[0].blank? || parts[1].blank?

          [parts[0], parts[1]]
        end
        ordered_pairs.sort_by! { |pair| pair[1] }
        result["#{term_fp}||#{label_fp}"] = ordered_pairs if ordered_pairs.any?
      end

      result
    end
  end
end
