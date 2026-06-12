# frozen_string_literal: true

module Scfair
  class ObsLabelPairConstraintEvaluator
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
    end

    def call
      errors = []
      checks = []

      Rules.obs_label_pair_fields.each do |id_field, label_field|
        allowed = OntologySemanticRules.allowed_special_values_for(id_field)
        result = LabelIdPairValidator.new(
          field_values: @field_values,
          format: @format,
          id_field: id_field,
          label_field: label_field,
          check_field: Rules.obs_label_pair_check_field(id_field),
          allowed_special_values: allowed
        ).call

        errors.concat(result[:errors])
        checks << result[:check] if result[:check].present?
      end

      { errors: errors, warnings: [], valid_checks: checks }
    end
  end
end
