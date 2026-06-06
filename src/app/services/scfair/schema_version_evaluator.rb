# frozen_string_literal: true

module Scfair
  class SchemaVersionEvaluator
    def self.call(file_version:, reference_version:, format:)
      new(file_version: file_version, reference_version: reference_version, format: format).call
    end

    def initialize(file_version:, reference_version:, format:)
      @file_version = file_version.to_s.strip
      @reference_version = reference_version.to_s.strip
      @format = format.to_s
      @field = Rules.field_path(@format, :uns, 'schema_version')
    end

    def call
      return empty_result if @file_version.blank?

      file_parts = self.class.parse_semver(@file_version)
      ref_parts = self.class.parse_semver(@reference_version)

      unless file_parts && ref_parts
        message = "schema_version value #{@file_version.inspect} is not a valid semantic version"
        return {
          errors: [{ field: @field, message: message }],
          warnings: [],
          valid_checks: [{ field: @field, status: 'failed', message: message }]
        }
      end

      file_major, file_minor, file_patch = file_parts
      ref_major, ref_minor, ref_patch = ref_parts

      if file_major < ref_major
        return error_result(
          "schema_version major version #{file_major} #{file_version_label} is lower than required #{ref_major} (#{@reference_version})"
        )
      end

      if file_major == ref_major && file_minor < ref_minor
        return error_result(
          "schema_version minor version #{file_major}.#{file_minor} #{file_version_label} is lower than required #{ref_major}.#{ref_minor} (#{@reference_version})"
        )
      end

      if file_major == ref_major && file_minor == ref_minor && file_patch < ref_patch
        message = "schema_version patch #{file_major}.#{file_minor}.#{file_patch} #{file_version_label} is lower than reference #{ref_major}.#{ref_minor}.#{ref_patch} (#{@reference_version})"
        return {
          errors: [],
          warnings: [{ field: @field, message: message }],
          valid_checks: [{ field: @field, status: 'warning', message: message }]
        }
      end

      {
        errors: [],
        warnings: [],
        valid_checks: [{
          field: @field,
          status: 'passed',
          message: "schema_version #{file_version_label} is compatible with reference #{@reference_version}"
        }]
      }
    end

    def self.parse_semver(value)
      match = value.to_s.strip.match(/\A(\d+)\.(\d+)\.(\d+)/)
      return nil unless match

      [match[1].to_i, match[2].to_i, match[3].to_i]
    end

    private

    def empty_result
      { errors: [], warnings: [], valid_checks: [] }
    end

    def error_result(message)
      {
        errors: [{ field: @field, message: message }],
        warnings: [],
        valid_checks: [{ field: @field, status: 'failed', message: message }]
      }
    end

    def file_version_label
      "(#{@file_version})"
    end
  end
end
