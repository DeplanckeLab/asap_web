# frozen_string_literal: true

module Scfair
  # Runs compliance checks that operate on a minimal extract and its field_values view.
  class ExtractComplianceChecker
    Result = Struct.new(:valid?, :errors, :warnings, :info, :valid_checks, :field_values, keyword_init: true)

    def initialize(extract:, format:, progress_cb: nil)
      @extract = deep_stringify(extract || {})
      @format = format.to_s
      @progress_cb = progress_cb
    end

    def call
      tick('checks', 'Preparing compliance checks from extracted metadata', 20)

      field_values = FieldValuesFromExtract.call(@extract, format: @format)

      errors = []
      warnings = []
      valid_checks = []
      info = []

      tick('structure', 'Checking file structure', 30)
      structure = ExtractStructureValidator.new(extract: @extract, format: @format).call
      errors.concat(structure[:errors])
      warnings.concat(structure[:warnings])
      valid_checks.concat(structure[:valid_checks])

      tick('presence', 'Checking required metadata fields', 45)
      presence = ExtractPresenceValidator.new(field_values: field_values, format: @format).call
      errors.concat(presence[:errors])
      valid_checks.concat(presence[:valid_checks])

      tick('ontology', 'Checking ontology term formats', 55)
      ontology = ExtractOntologyFormatValidator.new(field_values: field_values, format: @format).call
      errors.concat(ontology[:errors])
      warnings.concat(ontology[:warnings])
      valid_checks.concat(ontology[:valid_checks])

      tick('embeddings', 'Checking embeddings', 65)
      embeddings = ExtractEmbeddingsValidator.new(extract: @extract, format: @format).call
      errors.concat(embeddings[:errors])
      warnings.concat(embeddings[:warnings])
      valid_checks.concat(embeddings[:valid_checks])

      Result.new(
        valid?: errors.empty?,
        errors: errors,
        warnings: warnings,
        info: info,
        valid_checks: valid_checks,
        field_values: field_values
      )
    end

    private

    def deep_stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array
        value.map { |v| deep_stringify(v) }
      else
        value
      end
    end

    def tick(stage, message, progress)
      return unless @progress_cb

      @progress_cb.call(stage: stage, message: message, progress: progress, format: @format)
    end
  end
end
