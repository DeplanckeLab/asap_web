# frozen_string_literal: true

module Scfair
  class OrganismSpecificConstraintEvaluator
    MAPPING = {
      'NCBITaxon:9606' => 'HsapDv',
      'NCBITaxon:10090' => 'MmusDv',
      'NCBITaxon:6239' => 'WBls',
      'NCBITaxon:7955' => 'ZFS',
      'NCBITaxon:7227' => 'FBdv'
    }.freeze

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
    end

    def call
      organism_key = @format == 'h5ad' ? 'uns/organism_ontology_term_id' : '/attrs/organism_ontology_term_id'
      dev_key = @format == 'h5ad' ? 'obs/development_stage_ontology_term_id' : '/col_attrs/development_stage_ontology_term_id'
      organism = Array(@field_values[organism_key]).first.to_s
      expected_prefix = MAPPING[organism]
      return empty if expected_prefix.blank?

      invalid = Array(@field_values[dev_key]).flat_map { |v| v.to_s.split(' || ') }
                                           .map(&:strip)
                                           .reject(&:blank?)
                                           .reject { |v| %w[unknown na].include?(v) || v.start_with?("#{expected_prefix}:") }
      if invalid.any?
        {
          errors: [{ field: 'ontology.organism_dev_stage', message: "Expected #{expected_prefix}:* values for organism #{organism}; invalid: #{invalid.uniq.first(5).join(', ')}" }],
          warnings: [],
          valid_checks: [{ field: 'ontology.organism_dev_stage', status: 'failed', message: 'Organism-specific development_stage constraints failed' }]
        }
      else
        {
          errors: [],
          warnings: [],
          valid_checks: [{ field: 'ontology.organism_dev_stage', status: 'passed', message: 'Organism-specific development_stage constraints satisfied' }]
        }
      end
    end

    private

    def empty
      { errors: [], warnings: [], valid_checks: [] }
    end
  end
end
