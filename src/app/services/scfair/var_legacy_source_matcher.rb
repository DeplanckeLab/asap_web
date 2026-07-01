# frozen_string_literal: true

module Scfair
  # Suggests legacy ASAP row_attrs column names that can be mapped to scFAIR var fields.
  class VarLegacySourceMatcher
    def self.suggest(term_field, available_row_attrs)
      new(term_field, available_row_attrs).suggest
    end

    def initialize(term_field, available_row_attrs)
      @term_field = term_field.to_s
      @available = Array(available_row_attrs).map(&:to_s)
    end

    def suggest
      candidates = Rules.fix_form_var_legacy_sources[@term_field] || []
      candidates.find { |name| @available.include?(name) }
    end
  end
end
