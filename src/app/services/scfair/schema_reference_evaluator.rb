# frozen_string_literal: true

module Scfair
  class SchemaReferenceEvaluator
    def self.call(file_reference:, reference_url:, format:)
      new(file_reference: file_reference, reference_url: reference_url, format: format).call
    end

    def initialize(file_reference:, reference_url:, format:)
      @file_reference = file_reference.to_s.strip
      @reference_url = reference_url.to_s.strip
      @format = format.to_s
      @field = Rules.field_path(@format, :uns, 'schema_reference')
    end

    def call
      return empty_result if @file_reference.blank?
      return empty_result if @reference_url.blank?

      if references_match?
        return {
          errors: [],
          warnings: [],
          valid_checks: [{
            field: @field,
            status: 'passed',
            message: "schema_reference matches the reference schema URL (#{@reference_url})"
          }]
        }
      end

      message = "schema_reference #{@file_reference.inspect} does not match the reference schema URL #{@reference_url.inspect}"
      {
        errors: [],
        warnings: [{ field: @field, message: message }],
        valid_checks: [{ field: @field, status: 'warning', message: message }]
      }
    end

    private

    def references_match?
      normalize_url(@file_reference) == normalize_url(@reference_url)
    end

    def normalize_url(url)
      url.to_s.strip.chomp('/')
    end

    def empty_result
      { errors: [], warnings: [], valid_checks: [] }
    end
  end
end
