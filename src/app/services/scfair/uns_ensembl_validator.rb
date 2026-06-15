# frozen_string_literal: true

module Scfair
  # Validates required uns Ensembl metadata: ensembl_release (int), ensembl_database (enum),
  # and optional ensembl_assembly (non-empty when present).
  #
  # Check naming: metadata paths (uns/ensembl_release) for presence; dot ids (uns.ensembl.release)
  # for value-specific validation.
  class UnsEnsemblValidator
    CHECK_PREFIX = 'uns.ensembl'

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @allowed_databases = Rules.ensembl_database_values
    end

    def call
      errors = []
      valid_checks = []

      validate_release(errors, valid_checks)
      validate_database(errors, valid_checks)
      validate_assembly(errors, valid_checks)

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def validate_release(errors, valid_checks)
      field = uns_path('ensembl_release')
      value_check = value_check_id('release')
      raw = first_value(field)

      if raw.blank?
        return if defer_presence_to_base_validator?('ensembl_release')

        record_presence_failure(errors, valid_checks, field:)
        return
      end

      unless raw.match?(/\A\d+\z/)
        message = "ensembl_release must be an integer (found #{raw.inspect})"
        record_value_failure(errors, valid_checks, value_check:, message:)
        return
      end

      release = raw.to_i
      if release <= 0
        message = "ensembl_release must be a positive integer (found #{release})"
        record_value_failure(errors, valid_checks, value_check:, message:)
        return
      end

      valid_checks << {
        field: value_check,
        status: 'passed',
        message: "ensembl_release is a valid integer (#{release})"
      }
    end

    def validate_database(errors, valid_checks)
      field = uns_path('ensembl_database')
      value_check = value_check_id('database')
      raw = first_value(field)

      if raw.blank?
        return if defer_presence_to_base_validator?('ensembl_database')

        record_presence_failure(errors, valid_checks, field:)
        return
      end

      unless @allowed_databases.include?(raw)
        message = "ensembl_database must be one of: #{@allowed_databases.join(', ')} (found #{raw.inspect})"
        record_value_failure(errors, valid_checks, value_check:, message:)
        return
      end

      valid_checks << {
        field: value_check,
        status: 'passed',
        message: "ensembl_database is valid (#{raw})"
      }
    end

    def validate_assembly(errors, valid_checks)
      field = uns_path('ensembl_assembly')
      value_check = value_check_id('assembly')

      unless optional_field_present?('ensembl_assembly')
        valid_checks << {
          field: field,
          status: 'skipped',
          message: 'ensembl_assembly not present (optional)'
        }
        return
      end

      value = first_value(field)
      if value.blank?
        message = 'ensembl_assembly is present but empty; optional uns fields must not be empty when annotated'
        record_value_failure(errors, valid_checks, value_check:, message:)
        return
      end

      valid_checks << {
        field: value_check,
        status: 'passed',
        message: "ensembl_assembly is present (#{value})"
      }
    end

    def defer_presence_to_base_validator?(name)
      columns = uns_column_names
      columns.any? && !columns.include?(name)
    end

    def presence_message(_name)
      nil
    end

    def uns_path(name)
      Rules.field_path(@format, :uns, name)
    end

    def value_check_id(suffix)
      "#{CHECK_PREFIX}.#{suffix}"
    end

    def uns_column_names
      Array(
        @field_values[Rules.metadata_column_list_key('uns')] ||
        @field_values[Rules.metadata_column_list_key('uns').to_sym]
      ).map(&:to_s)
    end

    def optional_field_present?(name)
      columns = uns_column_names
      return columns.include?(name) if columns.any?

      field = uns_path(name)
      @field_values.key?(field) || @field_values.key?(field.to_sym)
    end

    def first_value(field)
      Array(@field_values[field] || @field_values[field.to_sym]).first.to_s.strip
    end

    def record_presence_failure(errors, valid_checks, field:, message: nil)
      entry = Scfair::CheckResult.presence(
        field: field,
        format: @format,
        status: 'failed',
        code: 'missing',
        message: message
      )
      errors << entry
      valid_checks << entry.merge(status: 'failed')
    end

    def record_value_failure(errors, valid_checks, value_check:, message:)
      errors << { field: value_check, message: message }
      valid_checks << { field: value_check, status: 'failed', message: message }
    end
  end
end
