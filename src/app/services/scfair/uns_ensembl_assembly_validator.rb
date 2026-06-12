# frozen_string_literal: true

module Scfair
  # Validates optional uns/ensembl_assembly (Loom: /attrs/ensembl_assembly).
  class UnsEnsemblAssemblyValidator
    FIELD_NAME = 'ensembl_assembly'

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @field = Rules.field_path(@format, :uns, FIELD_NAME)
    end

    def call
      return skipped_result unless field_present?

      value = field_value
      if value.blank?
        message = 'ensembl_assembly is present but empty; optional uns fields must not be empty when annotated'
        return {
          errors: [{ field: @field, message: message }],
          warnings: [],
          valid_checks: [{ field: @field, status: 'failed', message: message }]
        }
      end

      {
        errors: [],
        warnings: [],
        valid_checks: [{
          field: @field,
          status: 'passed',
          message: "ensembl_assembly is present (#{value})"
        }]
      }
    end

    private

    def field_present?
      columns = Array(
        @field_values[Rules.metadata_column_list_key('uns')] ||
        @field_values[Rules.metadata_column_list_key('uns').to_sym]
      ).map(&:to_s)
      return columns.include?(FIELD_NAME) if columns.any?

      @field_values.key?(@field) || @field_values.key?(@field.to_sym)
    end

    def field_value
      Array(@field_values[@field] || @field_values[@field.to_sym]).first.to_s.strip
    end

    def skipped_result
      {
        errors: [],
        warnings: [],
        valid_checks: [{
          field: @field,
          status: 'skipped',
          message: 'ensembl_assembly not present (optional)'
        }]
      }
    end
  end
end
