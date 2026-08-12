# frozen_string_literal: true

module AsapData
  # Helpers for parsing OBO term stanzas into content_json hashes.
  module OntologyOboParsing
    module_function

    IDENTIFIER_FIELDS = %w[
      xref is_a alt_id equivalent_to consider replaced_by part_of disjoint_from
    ].freeze

    # Strip trailing OBO qualifiers such as ` ! label` remnants and `{sssom:...}`.
    def normalize_multi_value(field, raw)
      value = raw.to_s.gsub(/ \!$/, '').strip
      return value if value.empty?

      if IDENTIFIER_FIELDS.include?(field)
        value = value.sub(/\s*\{.*\}\s*$/, '').strip
      end
      value
    end
  end
end
