# frozen_string_literal: true

module Scfair
  class OrganismSpecificConstraintEvaluator
    CHECK_PREFIX = 'ontology.organism_specific'
    DEV_STAGE_MAPPING = Rules.organism_dev_stage_mapping
    HUMAN_ORGANISM = Rules.organism_ethnicity_human
    CELL_TYPE_SPECIAL_VALUES = %w[unknown na].freeze
    DEV_STAGE_SPECIAL_VALUES = %w[unknown na].freeze
    SEX_SPECIAL_VALUES = %w[unknown na].freeze

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
    end

    def call
      checks = [
        evaluate_development_stage,
        evaluate_cell_type,
        evaluate_tissue,
        evaluate_ethnicity,
        evaluate_sex
      ].compact

      {
        errors: checks.flat_map { |result| result[:errors] },
        warnings: [],
        valid_checks: checks.flat_map { |result| result[:valid_checks] }
      }
    end

    private

    def evaluate_development_stage
      organism = organism_term_id
      expected_prefix = DEV_STAGE_MAPPING[organism]
      return skipped_check('development_stage', 'No mapped development stage prefix for this organism') if expected_prefix.blank?

      dev_key = obs_path('development_stage_ontology_term_id')
      return skipped_check('development_stage', 'development_stage_ontology_term_id not present') if split_values(@field_values[dev_key]).empty?

      invalid = invalid_prefix_values(
        @field_values[dev_key],
        allowed_prefixes: [expected_prefix],
        special_values: DEV_STAGE_SPECIAL_VALUES
      )
      build_prefix_result(
        rule: 'development_stage',
        label: 'development_stage_ontology_term_id',
        organism: organism,
        allowed_prefixes: [expected_prefix],
        invalid: invalid,
        special_values: DEV_STAGE_SPECIAL_VALUES
      )
    end

    def evaluate_cell_type
      organism = organism_term_id
      return skipped_check('cell_type', 'organism_ontology_term_id not set') if organism.blank?

      cell_key = obs_path('cell_type_ontology_term_id')
      return skipped_check('cell_type', 'cell_type_ontology_term_id not present') if split_values(@field_values[cell_key]).empty?

      allowed_prefixes = Rules.organism_cell_type_prefixes_for(organism)
      invalid = invalid_prefix_values(
        @field_values[cell_key],
        allowed_prefixes: allowed_prefixes,
        special_values: CELL_TYPE_SPECIAL_VALUES
      )
      build_prefix_result(
        rule: 'cell_type',
        label: 'cell_type_ontology_term_id',
        organism: organism,
        allowed_prefixes: allowed_prefixes,
        invalid: invalid,
        special_values: CELL_TYPE_SPECIAL_VALUES
      )
    end

    def evaluate_tissue
      organism = organism_term_id
      tissue_type = first_value('tissue_type')
      tissue_key = obs_path('tissue_ontology_term_id')
      tissue_values = split_values(@field_values[tissue_key])
      return skipped_check('tissue', 'tissue_ontology_term_id not present') if tissue_values.empty?

      if tissue_type == 'cell line'
        invalid = tissue_values.reject { |value| value.start_with?('CVCL_') }
        return build_custom_result(
          rule: 'tissue',
          label: 'tissue_ontology_term_id',
          passed: invalid.empty?,
          pass_message: 'Cell line tissue_ontology_term_id uses Cellosaurus (CVCL_*) terms',
          fail_message: "Cell line tissue_ontology_term_id must use Cellosaurus CVCL_* terms; invalid: #{invalid.join(', ')}",
          invalid: invalid
        )
      end

      if tissue_type == 'primary cell culture'
        return skipped_check('tissue', 'Uses cell_type_ontology_term_id rules for primary cell culture (see cell type check)') if organism.blank?

        allowed_prefixes = Rules.organism_cell_type_prefixes_for(organism)
        invalid = invalid_prefix_values(
          tissue_values,
          allowed_prefixes: allowed_prefixes,
          special_values: CELL_TYPE_SPECIAL_VALUES
        )
        return build_prefix_result(
          rule: 'tissue',
          label: 'tissue_ontology_term_id (primary cell culture)',
          organism: organism,
          allowed_prefixes: allowed_prefixes,
          invalid: invalid,
          special_values: CELL_TYPE_SPECIAL_VALUES
        )
      end

      return skipped_check('tissue', 'organism_ontology_term_id not set') if organism.blank?

      allowed_prefixes = Rules.organism_tissue_prefixes_for(organism)
      invalid = invalid_prefix_values(
        tissue_values,
        allowed_prefixes: allowed_prefixes,
        special_values: []
      )
      build_prefix_result(
        rule: 'tissue',
        label: 'tissue_ontology_term_id',
        organism: organism,
        allowed_prefixes: allowed_prefixes,
        invalid: invalid,
        special_values: []
      )
    end

    def evaluate_ethnicity
      organism = organism_term_id
      tissue_type = first_value('tissue_type')
      ethnicity_key = obs_path('self_reported_ethnicity_ontology_term_id')
      ethnicity_values = split_values(@field_values[ethnicity_key])

      return skipped_check('ethnicity', 'self_reported_ethnicity_ontology_term_id not present') if ethnicity_values.empty?
      return skipped_check('ethnicity', 'Cell line ethnicity is validated under cross-field rule CF-2a') if tissue_type == 'cell line'
      return skipped_check('ethnicity', 'organism_ontology_term_id not set') if organism.blank?

      if human_organism?(organism)
        if ethnicity_values == ['na']
          return build_custom_result(
            rule: 'ethnicity',
            label: 'self_reported_ethnicity_ontology_term_id',
            passed: false,
            pass_message: 'Human ethnicity constraints satisfied',
            fail_message: 'Homo sapiens dataset: self_reported_ethnicity_ontology_term_id must not be "na" (use HANCESTRO/AfPO, "unknown", or "multiethnic")',
            invalid: ['na']
          )
        end

        invalid = ethnicity_values.reject do |value|
          Rules.organism_ethnicity_special_values.include?(value) ||
            Rules.organism_ethnicity_prefixes.any? { |prefix| value.start_with?("#{prefix}:") }
        end
        build_prefix_result(
          rule: 'ethnicity',
          label: 'self_reported_ethnicity_ontology_term_id',
          organism: organism,
          allowed_prefixes: Rules.organism_ethnicity_prefixes,
          invalid: invalid,
          special_values: Rules.organism_ethnicity_special_values
        )
      else
        invalid = ethnicity_values.reject { |value| value == 'na' }
        build_custom_result(
          rule: 'ethnicity',
          label: 'self_reported_ethnicity_ontology_term_id',
          passed: invalid.empty?,
          pass_message: 'Non-human dataset: self_reported_ethnicity_ontology_term_id is "na"',
          fail_message: "Non-human dataset: self_reported_ethnicity_ontology_term_id must be \"na\"; invalid: #{invalid.join(', ')}",
          invalid: invalid
        )
      end
    end

    def evaluate_sex
      organism = organism_term_id
      return skipped_check('sex', 'organism_ontology_term_id not set') if organism.blank?
      return skipped_check('sex', 'Not applicable (C. elegans sex constraint only)') unless organism == Rules.organism_celegans_sex_organism

      sex_key = obs_path('sex_ontology_term_id')
      sex_values = split_values(@field_values[sex_key])
      return skipped_check('sex', 'sex_ontology_term_id not present') if sex_values.empty?

      allowed = Rules.organism_celegans_sex_terms + SEX_SPECIAL_VALUES
      invalid = sex_values.reject { |value| allowed.include?(value) }
      build_custom_result(
        rule: 'sex',
        label: 'sex_ontology_term_id',
        passed: invalid.empty?,
        pass_message: 'C. elegans sex constraints satisfied',
        fail_message: "C. elegans sex_ontology_term_id must be PATO:0000384 (male), PATO:0001340 (hermaphrodite), unknown, or na; invalid: #{invalid.join(', ')}",
        invalid: invalid
      )
    end

    def build_prefix_result(rule:, label:, organism:, allowed_prefixes:, invalid:, special_values:)
      prefix_list = allowed_prefixes.map { |prefix| "#{prefix}:*" }.join(' or ')
      special_note = special_values.any? ? " (special values #{special_values.join(', ')} also allowed)" : ''
      build_custom_result(
        rule: rule,
        label: label,
        passed: invalid.empty?,
        pass_message: "#{label} organism-specific constraints satisfied",
        fail_message: "Expected #{prefix_list} for organism #{organism}#{special_note}; invalid: #{invalid.join(', ')}",
        invalid: invalid
      )
    end

    def build_custom_result(rule:, label:, passed:, pass_message:, fail_message:, invalid:)
      field = "#{CHECK_PREFIX}.#{rule}"
      if passed
        {
          errors: [],
          valid_checks: [{ field: field, status: 'passed', message: pass_message }]
        }
      else
        {
          errors: [{ field: field, message: fail_message }],
          valid_checks: [{ field: field, status: 'failed', message: "#{label} organism-specific constraints failed" }]
        }
      end
    end

    def skipped_check(rule, message)
      {
        errors: [],
        valid_checks: [{ field: "#{CHECK_PREFIX}.#{rule}", status: 'skipped', message: message }]
      }
    end

    def human_organism?(organism)
      organism.to_s == HUMAN_ORGANISM
    end

    def organism_term_id
      key = Rules.field_path(@format, :uns, 'organism_ontology_term_id')
      Array(@field_values[key]).first.to_s.strip.presence
    end

    def obs_path(field_name)
      Rules.field_path(@format, :obs, field_name)
    end

    def first_value(field_name)
      Array(@field_values[obs_path(field_name)]).first.to_s.strip.presence
    end

    def invalid_prefix_values(raw_values, allowed_prefixes:, special_values:)
      split_values(raw_values).reject do |value|
        special_values.include?(value) || allowed_prefixes.any? { |prefix| value.start_with?("#{prefix}:") }
      end.uniq.first(5)
    end

    def split_values(raw)
      Array(raw).flat_map { |value| value.to_s.split(' || ') }.map(&:strip).reject(&:blank?)
    end
  end
end
