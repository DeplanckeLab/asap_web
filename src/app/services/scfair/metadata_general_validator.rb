# frozen_string_literal: true

module Scfair
  # Validates general metadata naming rules from the scFAIR schema:
  # - field names must not start with "__"
  # - obs and var column names must be unique
  # - deprecated reserved names from prior schema versions must not be present
  class MetadataGeneralValidator
    CHECK_PREFIX = 'metadata.other'

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @rules = Rules.metadata_rules
    end

    def call
      errors = []
      valid_checks = []
      columns_by_layer = resolve_columns_by_layer

      if columns_by_layer.values.all?(&:empty?)
        skip_subchecks(valid_checks)
        return { errors: errors, valid_checks: valid_checks }
      end

      prefix_result = check_forbidden_prefix(columns_by_layer)
      errors.concat(prefix_result[:errors])
      valid_checks.concat(prefix_result[:valid_checks])

      unique_result = check_unique_names(columns_by_layer)
      errors.concat(unique_result[:errors])
      valid_checks.concat(unique_result[:valid_checks])

      deprecated_result = check_deprecated_names(columns_by_layer)
      errors.concat(deprecated_result[:errors])
      valid_checks.concat(deprecated_result[:valid_checks])

      { errors: errors, valid_checks: valid_checks }
    end

    def skip_subchecks(valid_checks)
      message = 'Column lists not available; check skipped'
      valid_checks << { field: "#{CHECK_PREFIX}.reserved_prefix", status: 'skipped', message: message }
      Rules.metadata_rules[:unique_layers].each do |layer|
        valid_checks << { field: "#{CHECK_PREFIX}.unique_names.#{layer}", status: 'skipped', message: message }
      end
      valid_checks << { field: "#{CHECK_PREFIX}.deprecated", status: 'skipped', message: message }
    end

    private

    def resolve_columns_by_layer
      {
        'obs' => column_names_for('obs'),
        'var' => column_names_for('var'),
        'uns' => column_names_for('uns')
      }
    end

    def column_names_for(layer)
      raw = @field_values[Rules.metadata_column_list_key(layer)] ||
            @field_values[Rules.metadata_column_list_key(layer).to_sym]
      Array(raw).map(&:to_s).reject(&:blank?)
    end

    def metadata_columns(layer, names)
      skip = @rules[:skip_column_names].to_set
      names.reject { |name| skip.include?(name) }
    end

    def layer_label(layer)
      Rules.path_prefix(@format, layer.to_sym)
    end

    def check_forbidden_prefix(columns_by_layer)
      errors = []
      valid_checks = []
      prefix = @rules[:forbidden_name_prefix]
      violations = []

      %w[obs var].each do |layer|
        metadata_columns(layer, columns_by_layer[layer]).each do |name|
          next unless name.start_with?(prefix)

          violations << { layer: layer, name: name }
        end
      end

      if violations.any?
        sample = violations.first(5).map { |entry| "#{layer_label(entry[:layer])}/#{entry[:name]}" }.join(', ')
        suffix = violations.size > 5 ? " (+#{violations.size - 5} more)" : ''
        errors << {
          field: "#{CHECK_PREFIX}.reserved_prefix",
          message: "Metadata field names MUST NOT start with \"#{prefix}\" (found: #{sample}#{suffix})"
        }
        valid_checks << {
          field: "#{CHECK_PREFIX}.reserved_prefix",
          status: 'failed',
          message: "#{violations.size} field name(s) use forbidden \"#{prefix}\" prefix"
        }
      else
        valid_checks << {
          field: "#{CHECK_PREFIX}.reserved_prefix",
          status: 'passed',
          message: "No metadata field names start with \"#{prefix}\""
        }
      end

      { errors: errors, valid_checks: valid_checks }
    end

    def check_unique_names(columns_by_layer)
      errors = []
      valid_checks = []

      @rules[:unique_layers].each do |layer|
        names = metadata_columns(layer, columns_by_layer[layer])
        duplicates = names.group_by(&:itself).select { |_name, group| group.size > 1 }.keys

        if duplicates.any?
          sample = duplicates.first(5).join(', ')
          suffix = duplicates.size > 5 ? " (+#{duplicates.size - 5} more)" : ''
          errors << {
            field: "#{CHECK_PREFIX}.unique_names.#{layer}",
            message: "#{layer_label(layer)} metadata field names MUST be unique (duplicate: #{sample}#{suffix})"
          }
          valid_checks << {
            field: "#{CHECK_PREFIX}.unique_names.#{layer}",
            status: 'failed',
            message: "Duplicate #{layer} metadata field name(s): #{sample}#{suffix}"
          }
        else
          valid_checks << {
            field: "#{CHECK_PREFIX}.unique_names.#{layer}",
            status: 'passed',
            message: "#{layer_label(layer)} metadata field names are unique"
          }
        end
      end

      { errors: errors, valid_checks: valid_checks }
    end

    def check_deprecated_names(columns_by_layer)
      errors = []
      valid_checks = []
      found = []

      @rules[:deprecated_names].each do |entry|
        layer = entry[:layer]
        names = metadata_columns(layer, columns_by_layer[layer])
        next unless names.include?(entry[:name])

        found << entry
      end

      if found.any?
        sample = found.first(5).map do |entry|
          "#{layer_label(entry[:layer])}/#{entry[:name]} (deprecated in #{entry[:deprecated_in]})"
        end.join(', ')
        suffix = found.size > 5 ? " (+#{found.size - 5} more)" : ''
        errors << {
          field: "#{CHECK_PREFIX}.deprecated",
          message: "Deprecated reserved metadata field names MUST NOT be present (found: #{sample}#{suffix})"
        }
        valid_checks << {
          field: "#{CHECK_PREFIX}.deprecated",
          status: 'failed',
          message: "#{found.size} deprecated reserved name(s) present"
        }
      else
        valid_checks << {
          field: "#{CHECK_PREFIX}.deprecated",
          status: 'passed',
          message: 'No deprecated reserved metadata field names present'
        }
      end

      { errors: errors, valid_checks: valid_checks }
    end
  end
end
