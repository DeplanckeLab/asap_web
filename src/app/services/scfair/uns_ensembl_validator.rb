# frozen_string_literal: true

module Scfair
  # Validates required uns Ensembl metadata: ensembl_release (int), ensembl_database (enum),
  # and ensembl_assembly (non-empty string).
  #
  # Each attribute is reported once under uns.ensembl using stable check ids
  # (uns.ensembl.release, uns.ensembl.database, uns.ensembl.assembly).
  class UnsEnsemblValidator
    CHECK_PREFIX = 'uns.ensembl'
    VALUE_CHECK_SUFFIXES = {
      'ensembl_release' => 'release',
      'ensembl_database' => 'database',
      'ensembl_assembly' => 'assembly'
    }.freeze

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
      metadata_name = 'ensembl_release'
      field = uns_path(metadata_name)
      value_check = value_check_id(metadata_name)
      raw = first_value(field)

      if raw.blank?
        record_presence_failure(errors, valid_checks, value_check:, metadata_path: field)
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

      record_pass(valid_checks, value_check:, message: "ensembl_release is a valid integer (#{release})")
    end

    def validate_database(errors, valid_checks)
      metadata_name = 'ensembl_database'
      field = uns_path(metadata_name)
      value_check = value_check_id(metadata_name)
      raw = first_value(field)

      if raw.blank?
        record_presence_failure(errors, valid_checks, value_check:, metadata_path: field)
        return
      end

      unless @allowed_databases.include?(raw)
        message = "ensembl_database must be one of: #{@allowed_databases.join(', ')} (found #{raw.inspect})"
        record_value_failure(errors, valid_checks, value_check:, message:)
        return
      end

      record_pass(valid_checks, value_check:, message: "ensembl_database is valid (#{raw})")
    end

    def validate_assembly(errors, valid_checks)
      metadata_name = 'ensembl_assembly'
      field = uns_path(metadata_name)
      value_check = value_check_id(metadata_name)
      raw = first_value(field)

      if raw.blank?
        record_presence_failure(errors, valid_checks, value_check:, metadata_path: field)
        return
      end

      record_pass(valid_checks, value_check:, message: "ensembl_assembly is present (#{raw})")
    end

    def uns_path(name)
      Rules.field_path(@format, :uns, name)
    end

    def value_check_id(metadata_name)
      "#{CHECK_PREFIX}.#{VALUE_CHECK_SUFFIXES.fetch(metadata_name)}"
    end

    def first_value(field)
      Array(@field_values[field] || @field_values[field.to_sym]).first.to_s.strip
    end

    def record_presence_failure(errors, valid_checks, value_check:, metadata_path:)
      message = Rules.check_message(
        'uns.required_presence',
        'missing',
        format: @format,
        field: metadata_path,
        path: metadata_path
      )
      errors << { field: metadata_path, message: message }
      valid_checks << { field: metadata_path, status: 'failed', code: 'missing', message: message }
    end

    def record_value_failure(errors, valid_checks, value_check:, message:)
      entry = check_entry(value_check:, status: 'failed', message: message)
      errors << { field: value_check, message: message }
      valid_checks << entry
    end

    def record_pass(valid_checks, value_check:, message:)
      valid_checks << check_entry(value_check:, status: 'passed', message: message)
    end

    def check_entry(value_check:, status:, message:, code: nil)
      entry = {
        field: value_check,
        check_id: CHECK_PREFIX,
        status: status.to_s,
        message: message
      }
      entry[:code] = code.to_s if code.present?
      entry
    end
  end
end
