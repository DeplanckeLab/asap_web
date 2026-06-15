# frozen_string_literal: true

module Scfair
  # Validates required var (gene) metadata columns and basic value constraints.
  class VarMetadataValidator
    CHECK_PREFIX = 'var.required'

    BOOL_VALUES = %w[true false True False].freeze

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @required_fields = Rules.required_var_fields
      @biotype_values = Rules.enum_field_values('feature_biotype')
      @reference_taxa = Rules.feature_reference_taxa.keys
    end

    def call
      errors = []
      valid_checks = []

      var_columns = column_names_for('var')
      if var_columns.empty?
        skip_message = 'Variable column list not available; check skipped'
        @required_fields.each do |field_name|
          valid_checks << { field: var_path(field_name), status: 'skipped', message: skip_message }
        end
        return { errors: errors, valid_checks: valid_checks }
      end

      validate_presence(errors, valid_checks, var_columns)
      validate_values(errors, valid_checks, var_columns)

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def validate_presence(errors, valid_checks, var_columns)
      @required_fields.each do |field_name|
        field = var_path(field_name)
        if var_columns.include?(field_name)
          valid_checks << Scfair::CheckResult.presence(field: field, format: @format, status: 'passed', code: 'found')
        else
          entry = Scfair::CheckResult.presence(field: field, format: @format, status: 'failed', code: 'missing')
          errors << entry
          valid_checks << entry.merge(status: 'failed')
        end
      end
    end

    def validate_values(errors, valid_checks, var_columns)
      validate_biotype_values(errors, valid_checks, var_columns)
      validate_bool_values(errors, valid_checks, 'feature_is_filtered', var_columns)
      validate_length_values(errors, valid_checks, var_columns)
      validate_reference_values(errors, valid_checks, var_columns)
      %w[feature_name feature_type feature_chromosome].each do |field_name|
        validate_non_empty_values(errors, valid_checks, field_name, var_columns)
      end
    end

    def validate_biotype_values(errors, valid_checks, var_columns)
      field_name = 'feature_biotype'
      return unless var_columns.include?(field_name)

      field = var_path(field_name)
      invalid = values_for_var(field_name).reject { |value| @biotype_values.include?(value) }
      if invalid.any?
        message = "feature_biotype must be one of: #{@biotype_values.join(', ')} (found: #{invalid.first(3).join(', ')})"
        record_value_failure(errors, valid_checks, field:, message:)
      else
        record_value_pass(valid_checks, field)
      end
    end

    def validate_bool_values(errors, valid_checks, field_name, var_columns)
      return unless var_columns.include?(field_name)

      field = var_path(field_name)
      invalid = values_for_var(field_name).reject { |value| BOOL_VALUES.include?(value) }
      if invalid.any?
        message = "feature_is_filtered must be boolean true or false (found: #{invalid.first(3).join(', ')})"
        record_value_failure(errors, valid_checks, field:, message:)
      else
        record_value_pass(valid_checks, field)
      end
    end

    def validate_length_values(errors, valid_checks, var_columns)
      field_name = 'feature_length'
      return unless var_columns.include?(field_name)

      field = var_path(field_name)
      invalid = values_for_var(field_name).reject { |value| value.match?(/\A\d+\z/) && value.to_i.positive? }
      if invalid.any?
        message = "feature_length must be a positive integer (found: #{invalid.first(3).join(', ')})"
        record_value_failure(errors, valid_checks, field:, message:)
      else
        record_value_pass(valid_checks, field)
      end
    end

    def validate_reference_values(errors, valid_checks, var_columns)
      field_name = 'feature_reference'
      return unless var_columns.include?(field_name)

      field = var_path(field_name)
      invalid = values_for_var(field_name).reject { |value| @reference_taxa.include?(value) }
      if invalid.any?
        message = "feature_reference must be a schema NCBITaxon identifier (found: #{invalid.first(3).join(', ')})"
        record_value_failure(errors, valid_checks, field:, message:)
      else
        record_value_pass(valid_checks, field)
      end
    end

    def validate_non_empty_values(errors, valid_checks, field_name, var_columns)
      return unless var_columns.include?(field_name)

      field = var_path(field_name)
      if values_for_var(field_name).any?
        record_value_pass(valid_checks, field)
      else
        message = "#{field_name} must not be empty"
        record_value_failure(errors, valid_checks, field:, message:)
      end
    end

    def record_value_failure(errors, valid_checks, field:, message:)
      errors << { field: field, message: message }
      valid_checks << { field: field, status: 'failed', message: message }
    end

    def record_value_pass(valid_checks, field)
      valid_checks << { field: field, status: 'passed', message: 'Value constraints satisfied' }
    end

    def column_names_for(layer)
      raw = @field_values[Rules.metadata_column_list_key(layer)] ||
            @field_values[Rules.metadata_column_list_key(layer).to_sym]
      Array(raw).map(&:to_s).reject(&:blank?)
    end

    def values_for_var(field_name)
      Array(@field_values[var_path(field_name)] || @field_values[var_path(field_name).to_sym])
        .map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def var_path(field_name)
      Rules.field_path(@format, :var, field_name)
    end

  end
end
