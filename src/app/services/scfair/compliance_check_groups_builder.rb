# frozen_string_literal: true

module Scfair
  # Builds enriched check_groups for compliance report UIs (file-check and project).
  class ComplianceCheckGroupsBuilder
    include ComplianceReportEnrichment

    def self.call(errors:, warnings:, valid_checks:, field_values: {}, format: 'loom')
      new(
        errors: errors,
        warnings: warnings,
        valid_checks: valid_checks,
        field_values: field_values,
        format: format
      ).call
    end

    def initialize(errors:, warnings:, valid_checks:, field_values:, format:)
      @errors = Array(errors)
      @warnings = Array(warnings)
      @valid_checks = Array(valid_checks)
      @field_values = field_values || {}
      @format = format.to_s
    end

    def call
      groups = ComplianceReportGrouper.call(
        checks_catalog: CheckCatalog.checks_for(@format),
        valid_checks: @valid_checks,
        errors: @errors,
        warnings: @warnings,
        format: @format
      )

      enrich_with_details(
        format: @format,
        field_values: @field_values,
        errors: @errors,
        warnings: @warnings,
        check_groups: groups
      )[:check_groups]
    end
  end
end
