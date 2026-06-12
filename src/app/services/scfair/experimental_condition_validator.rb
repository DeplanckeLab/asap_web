# frozen_string_literal: true

module Scfair
  # Validates scFAIR experimental_condition_* and perturbation_types obs fields.
  class ExperimentalConditionValidator
    CHECK_PREFIX = 'obs.experimental_condition'

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @rules = Rules.experimental_condition_rules
      @delimiter = @rules[:delimiter]
      @na_value = @rules[:na_value]
      @no_perturbations = @rules[:no_perturbations_value]
      @perturbation_types = Rules.enum_field_values('perturbation_types')
    end

    def call
      errors = []
      valid_checks = []

      obs_columns = column_names_for('obs')
      if obs_columns.empty?
        valid_checks << skip_check(obs_path(@rules[:label_field]), 'Observation column list not available; check skipped')
        valid_checks << skip_check(obs_path(@rules[:perturbation_types_field]), 'Observation column list not available; check skipped')
        return { errors: errors, valid_checks: valid_checks }
      end

      id_field = @rules[:id_field]
      label_field = @rules[:label_field]
      perturb_field = @rules[:perturbation_types_field]
      genetic_field = @rules[:genetic_perturbation_id_field]

      id_present = obs_columns.include?(id_field)
      label_present = obs_columns.include?(label_field)
      perturb_present = obs_columns.include?(perturb_field)
      genetic_present = obs_columns.include?(genetic_field)

      id_values = values_for_obs(id_field)
      all_na = id_values.empty? || id_values.all? { |value| value == @na_value }

      validate_id_presence(errors, valid_checks, id_present:, all_na:)
      validate_label_presence(errors, valid_checks, id_present:, label_present:)
      validate_perturbation_types_presence(
        errors,
        valid_checks,
        id_present:,
        perturb_present:,
        genetic_present:
      )

      if id_present
        validate_id_values(errors, valid_checks, id_values)
        validate_label_values(errors, valid_checks, label_present:) if label_present
      end

      if perturb_present
        validate_perturbation_type_values(errors, valid_checks)
      end

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def validate_id_presence(errors, valid_checks, id_present:, all_na:)
      check_field = obs_path(@rules[:label_field])

      if id_present && all_na
        message = "#{@rules[:id_field]} is present but all values are \"#{@na_value}\"; the column MUST NOT be present when every observation has no experimental condition"
        record_failure(errors, valid_checks, check_field:, message:)
      elsif id_present
        valid_checks << {
          field: check_field,
          status: 'passed',
          message: "#{@rules[:id_field]} column present with experimental condition metadata"
        }
      else
        valid_checks << {
          field: check_field,
          status: 'passed',
          message: "No #{@rules[:id_field]} column (all observations have no experimental condition)"
        }
      end
    end

    def validate_label_presence(errors, valid_checks, id_present:, label_present:)
      check_field = "#{CHECK_PREFIX}.label"

      if id_present && !label_present
        message = "#{@rules[:label_field]} is required when #{@rules[:id_field]} is present"
        record_failure(errors, valid_checks, check_field:, message:)
      elsif id_present
        valid_checks << { field: check_field, status: 'passed', message: "#{@rules[:label_field]} is present" }
      else
        valid_checks << { field: check_field, status: 'skipped', message: "#{@rules[:label_field]} not required" }
      end
    end

    def validate_perturbation_types_presence(errors, valid_checks, id_present:, perturb_present:, genetic_present:)
      check_field = "#{CHECK_PREFIX}.perturbation_types"
      required = id_present || genetic_present

      if required && !perturb_present
        message = "#{@rules[:perturbation_types_field]} is required when #{@rules[:id_field]} or #{@rules[:genetic_perturbation_id_field]} is present"
        record_failure(errors, valid_checks, check_field:, message:)
      elsif required
        valid_checks << { field: check_field, status: 'passed', message: "#{@rules[:perturbation_types_field]} is present" }
      else
        valid_checks << { field: check_field, status: 'skipped', message: "#{@rules[:perturbation_types_field]} not required" }
      end
    end

    def validate_id_values(errors, valid_checks, id_values)
      check_field = "#{CHECK_PREFIX}.id_values"
      invalid = []

      id_values.each do |value|
        next if value == @na_value

        terms = split_multi(value)
        if terms != terms.sort.uniq
          invalid << value
        end
      end

      if invalid.any?
        sample = invalid.first(3).join('; ')
        message = "#{@rules[:id_field]} multi-values must be unique and in ascending lexical order separated by \"#{@delimiter.strip}\" (invalid: #{sample})"
        record_failure(errors, valid_checks, check_field:, message:)
      else
        valid_checks << {
          field: check_field,
          status: 'passed',
          message: "#{@rules[:id_field]} values use valid ordering for multi-value entries"
        }
      end
    end

    def validate_label_values(errors, valid_checks, label_present:)
      return unless label_present

      check_field = "#{CHECK_PREFIX}.label_values"
      id_values = values_for_obs(@rules[:id_field])
      label_values = values_for_obs(@rules[:label_field])

      mismatches = []
      id_values.zip(label_values).each do |id_value, label_value|
        next if id_value.blank?

        if id_value == @na_value && label_value != @na_value
          mismatches << "id=#{id_value} label=#{label_value.inspect}"
        end
      end

      if mismatches.any?
        sample = mismatches.first(3).join('; ')
        message = "#{@rules[:label_field]} MUST be \"#{@na_value}\" when #{@rules[:id_field]} is \"#{@na_value}\" (found: #{sample})"
        record_failure(errors, valid_checks, check_field:, message:)
      else
        valid_checks << {
          field: check_field,
          status: 'passed',
          message: "#{@rules[:label_field]} matches \"#{@na_value}\" where required"
        }
      end
    end

    def validate_perturbation_type_values(errors, valid_checks)
      check_field = "#{CHECK_PREFIX}.perturbation_type_values"
      values = values_for_obs(@rules[:perturbation_types_field])
      allowed = @perturbation_types + [@no_perturbations]
      invalid = []

      values.each do |value|
        if value == @no_perturbations
          next
        end

        types = split_multi(value)
        if types != types.sort.uniq || types.any? { |entry| !@perturbation_types.include?(entry) }
          invalid << value
        end
      end

      if invalid.any?
        sample = invalid.first(3).join('; ')
        message = "#{@rules[:perturbation_types_field]} must be \"#{@no_perturbations}\" or a sorted unique set of: #{@perturbation_types.join(', ')} (invalid: #{sample})"
        record_failure(errors, valid_checks, check_field:, message:)
      else
        valid_checks << {
          field: check_field,
          status: 'passed',
          message: "#{@rules[:perturbation_types_field]} values are valid"
        }
      end
    end

    def column_names_for(layer)
      raw = @field_values[Rules.metadata_column_list_key(layer)] ||
            @field_values[Rules.metadata_column_list_key(layer).to_sym]
      Array(raw).map(&:to_s).reject(&:blank?)
    end

    def values_for_obs(field_name)
      path = obs_path(field_name)
      Array(@field_values[path] || @field_values[path.to_sym]).map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def obs_path(field_name)
      Rules.field_path(@format, :obs, field_name)
    end

    def split_multi(value)
      value.split(@delimiter).map(&:strip).reject(&:blank?)
    end

    def skip_check(field, message)
      { field: field, status: 'skipped', message: message }
    end

    def record_failure(errors, valid_checks, check_field:, message:)
      errors << { field: check_field, message: message }
      valid_checks << { field: check_field, status: 'failed', message: message }
    end
  end
end
