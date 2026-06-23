# frozen_string_literal: true

module Scfair
  # Required-field presence and enum validation from extracted field values.
  class ExtractPresenceValidator
    ENSEMBL_UNS_FIELDS = %w[ensembl_release ensembl_database ensembl_assembly].freeze
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
    end

    def call
      errors = []
      valid_checks = []

      Rules.required_obs_fields.each do |field|
        path = Rules.field_path(@format, :obs, field)
        check_presence(path, errors, valid_checks)
        check_enum(path, errors) if present?(path)
      end

      Rules.required_uns_fields.each do |field|
        next if ENSEMBL_UNS_FIELDS.include?(field)

        path = Rules.field_path(@format, :uns, field)
        check_presence(path, errors, valid_checks)
      end

      Rules.required_var_fields.each do |field|
        path = Rules.field_path(@format, :var, field)
        check_presence(path, errors, valid_checks)
      end

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def present?(path)
      Array(@field_values[path] || @field_values[path.to_sym]).any?(&:present?)
    end

    def values_for(path)
      Array(@field_values[path] || @field_values[path.to_sym]).map(&:to_s).reject(&:blank?)
    end

    def check_presence(path, errors, valid_checks)
      field_name = path.to_s.split('/').last
      if present?(path)
        unless field_name == 'schema_version'
          valid_checks << CheckResult.presence(field: path, format: @format, status: 'passed', code: 'found')
        end
      else
        errors << CheckResult.presence(field: path, format: @format, status: 'failed', code: 'missing')
      end
    end

    def check_enum(path, errors)
      field_name = path.to_s.split('/').last
      allowed = Rules.enum_field_values(field_name)
      return if allowed.empty?

      invalid = values_for(path).reject { |v| allowed.any? { |a| a.casecmp?(v) } }
      return if invalid.empty?

      errors << {
        field: path,
        message: "Invalid value(s): #{invalid.first(5).join(', ')}. Allowed: #{allowed.join(', ')}"
      }
    end
  end
end
