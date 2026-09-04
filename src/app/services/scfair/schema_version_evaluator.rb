# frozen_string_literal: true

module Scfair
  # Exact-match check for uns/attrs schema_version (same severity model as
  # SchemaReferenceEvaluator: mismatch is a warning, not an error).
  class SchemaVersionEvaluator
    def self.call(file_version:, expected_identifier:, format:)
      new(
        file_version: file_version,
        expected_identifier: expected_identifier,
        format: format
      ).call
    end

    def initialize(file_version:, expected_identifier:, format:)
      @file_version = file_version.to_s.strip
      @expected_identifier = expected_identifier.to_s.strip
      @format = format.to_s
      @field = Rules.field_path(@format, :uns, 'schema_version')
    end

    def call
      return empty_result if @file_version.blank?
      return empty_result if @expected_identifier.blank?

      if identifiers_match?
        return {
          errors: [],
          warnings: [],
          valid_checks: [{
            field: @field,
            status: 'passed',
            message: "schema_version matches the required identifier (#{@expected_identifier})"
          }]
        }
      end

      message = "schema_version #{@file_version.inspect} does not match the required identifier #{@expected_identifier.inspect}"
      {
        errors: [],
        warnings: [{ field: @field, message: message }],
        valid_checks: [{ field: @field, status: 'warning', message: message }]
      }
    end

    private

    def identifiers_match?
      @file_version == @expected_identifier
    end

    def empty_result
      { errors: [], warnings: [], valid_checks: [] }
    end
  end
end
