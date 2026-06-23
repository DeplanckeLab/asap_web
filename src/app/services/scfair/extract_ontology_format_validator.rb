# frozen_string_literal: true

module Scfair
  # Ontology PREFIX:ID format checks from extracted field values.
  class ExtractOntologyFormatValidator
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
    end

    def call
      errors = []
      warnings = []
      valid_checks = []

      Rules.ontology_paths(@format).each do |path, prefixes|
        values = distinct_values(path)
        next if values.empty?

        issues = 0
        values.each do |value|
          value.split(' || ').map(&:strip).reject(&:blank?).each do |term|
            next if special_value?(path, term)

            unless Rules.valid_ontology_term_identifier_format?(term, field_name(path))
              errors << CheckResult.ontology_format(
                field: path,
                format: @format,
                status: 'failed',
                code: Rules.cellosaurus_ontology_term?(term) ? 'cellosaurus_disallowed' : 'invalid_obo',
                message: Rules.ontology_format_error_message(term, field_name(path))
              )
              issues += 1
              next
            end

            prefix = term.split(':').first
            next if prefixes.include?(prefix)

            warnings << CheckResult.ontology_format(
              field: path,
              format: @format,
              status: 'warning',
              code: 'unexpected_prefix',
              message: "Unexpected ontology prefix '#{prefix}' for #{path}"
            )
            issues += 1
          end
        end

        next unless issues.zero?

        valid_checks << CheckResult.ontology_format(
          field: path,
          format: @format,
          status: 'passed',
          code: 'valid'
        )
      end

      { errors: errors, warnings: warnings, valid_checks: valid_checks }
    end

    private

    def field_name(path)
      path.to_s.split('/').last
    end

    def distinct_values(path)
      Array(@field_values[path] || @field_values[path.to_sym]).map(&:to_s).reject(&:blank?)
    end

    def special_value?(path, term)
      specials = Rules.allowed_special_values(@format)[path] ||
                 Rules.allowed_special_values(@format)[path.to_sym] ||
                 []
      specials.include?(term)
    end
  end
end
