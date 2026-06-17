# frozen_string_literal: true

module Scfair
  # Validates required uns/ensembl_assembly (Loom: /attrs/ensembl_assembly).
  class UnsEnsemblAssemblyValidator
    FIELD_NAME = 'ensembl_assembly'

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @field = Rules.field_path(@format, :uns, FIELD_NAME)
    end

    def call
      unless field_present?
        return {
          errors: [presence_error],
          warnings: [],
          valid_checks: [presence_error.merge(status: 'failed')]
        }
      end

      value = field_value
      if value.blank?
        entry = Scfair::CheckResult.presence(
          field: @field,
          format: @format,
          status: 'failed',
          code: 'missing'
        )
        return {
          errors: [entry],
          warnings: [],
          valid_checks: [entry.merge(status: 'failed')]
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

    def presence_error
      Scfair::CheckResult.presence(
        field: @field,
        format: @format,
        status: 'failed',
        code: 'missing'
      )
    end
  end
end
