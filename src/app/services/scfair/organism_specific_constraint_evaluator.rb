# frozen_string_literal: true

module Scfair
  class OrganismSpecificConstraintEvaluator
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
      @cfg = Rules.organism_specific_validation_config
      @check_prefix = @cfg[:check_prefix]
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
      expected_prefix = Rules.organism_dev_stage_mapping[organism]
      if expected_prefix.blank?
        return skipped_check('development_stage', :no_mapping)
      end

      dev_key = obs_path('development_stage_ontology_term_id')
      return skipped_check('development_stage', :field_missing) if split_values(@field_values[dev_key]).empty?

      special_values = Rules.organism_specific_special_values('development_stage')
      invalid = invalid_prefix_values(
        @field_values[dev_key],
        allowed_prefixes: [expected_prefix],
        special_values: special_values
      )
      build_prefix_result(
        rule: 'development_stage',
        label: 'development_stage_ontology_term_id',
        organism: organism,
        allowed_prefixes: [expected_prefix],
        invalid: invalid,
        special_values: special_values
      )
    end

    def evaluate_cell_type
      organism = organism_term_id
      return skipped_check('cell_type', :organism_missing) if organism.blank?

      cell_key = obs_path('cell_type_ontology_term_id')
      return skipped_check('cell_type', :field_missing) if split_values(@field_values[cell_key]).empty?

      special_values = Rules.organism_specific_special_values('cell_type')
      allowed_prefixes = Rules.organism_cell_type_prefixes_for(organism)
      invalid = invalid_prefix_values(
        @field_values[cell_key],
        allowed_prefixes: allowed_prefixes,
        special_values: special_values
      )
      build_prefix_result(
        rule: 'cell_type',
        label: 'cell_type_ontology_term_id',
        organism: organism,
        allowed_prefixes: allowed_prefixes,
        invalid: invalid,
        special_values: special_values
      )
    end

    def evaluate_tissue
      organism = organism_term_id
      tissue_type = first_value('tissue_type')
      tissue_key = obs_path('tissue_ontology_term_id')
      tissue_values = split_values(@field_values[tissue_key])
      return skipped_check('tissue', :field_missing) if tissue_values.empty?

      if tissue_type == @cfg[:cell_line_tissue_type]
        invalid = tissue_values.reject { |value| Rules.cellosaurus_ontology_term?(value) }
        return build_custom_result(
          rule: 'tissue',
          label: 'tissue_ontology_term_id',
          passed: invalid.empty?,
          pass_message: Rules.organism_specific_pass_message('cell_line_tissue'),
          fail_message: Rules.organism_specific_fail_message('cell_line_tissue_template', invalid: invalid.join(', ')),
          invalid: invalid
        )
      end

      if tissue_type == @cfg[:primary_cell_culture_tissue_type]
        return skipped_check('tissue', :primary_cell_culture) if organism.blank?

        special_values = Rules.organism_specific_special_values('cell_type')
        allowed_prefixes = Rules.organism_cell_type_prefixes_for(organism)
        invalid = invalid_prefix_values(
          tissue_values,
          allowed_prefixes: allowed_prefixes,
          special_values: special_values
        )
        return build_prefix_result(
          rule: 'tissue',
          label: 'tissue_ontology_term_id (primary cell culture)',
          organism: organism,
          allowed_prefixes: allowed_prefixes,
          invalid: invalid,
          special_values: special_values
        )
      end

      return skipped_check('tissue', :organism_missing) if organism.blank?

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

      return skipped_check('ethnicity', :field_missing) if ethnicity_values.empty?
      return skipped_check('ethnicity', :cell_line) if tissue_type == @cfg[:cell_line_tissue_type]
      return skipped_check('ethnicity', :organism_missing) if organism.blank?

      if human_organism?(organism)
        if ethnicity_values == ['na']
          return build_custom_result(
            rule: 'ethnicity',
            label: 'self_reported_ethnicity_ontology_term_id',
            passed: false,
            pass_message: Rules.organism_specific_pass_message('human_ethnicity'),
            fail_message: Rules.organism_specific_fail_message('human_ethnicity_na'),
            invalid: ['na']
          )
        end

        invalid = ethnicity_values.reject do |value|
          Rules.organism_ethnicity_special_values.include?(value) ||
            Rules.ontology_term_matches_prefixes?(value, Rules.organism_ethnicity_prefixes)
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
          pass_message: Rules.organism_specific_pass_message('non_human_ethnicity'),
          fail_message: Rules.organism_specific_fail_message('non_human_ethnicity_template', invalid: invalid.join(', ')),
          invalid: invalid
        )
      end
    end

    def evaluate_sex
      organism = organism_term_id
      return skipped_check('sex', :organism_missing) if organism.blank?
      return skipped_check('sex', :not_celegans) unless organism == Rules.organism_celegans_sex_organism

      sex_key = obs_path('sex_ontology_term_id')
      sex_values = split_values(@field_values[sex_key])
      return skipped_check('sex', :field_missing) if sex_values.empty?

      special_values = Rules.organism_specific_special_values('sex')
      allowed = Rules.organism_celegans_sex_terms + special_values
      invalid = sex_values.reject { |value| allowed.include?(value) }
      build_custom_result(
        rule: 'sex',
        label: 'sex_ontology_term_id',
        passed: invalid.empty?,
        pass_message: Rules.organism_specific_pass_message('celegans_sex'),
        fail_message: Rules.organism_specific_fail_message('celegans_sex_template', invalid: invalid.join(', ')),
        invalid: invalid
      )
    end

    def build_prefix_result(rule:, label:, organism:, allowed_prefixes:, invalid:, special_values:)
      prefix_list = allowed_prefixes.map do |prefix|
        format(@cfg[:prefix_list_entry], prefix: prefix)
      end.join(@cfg[:prefix_list_joiner])
      special_note = if special_values.any?
                       format(@cfg[:special_note_template], values: special_values.join(', '))
                     else
                       ''
                     end
      build_custom_result(
        rule: rule,
        label: label,
        passed: invalid.empty?,
        pass_message: Rules.organism_specific_pass_message('prefix_satisfied', label: label),
        fail_message: Rules.organism_specific_fail_message(
          'prefix_invalid_template',
          prefix_list: prefix_list,
          organism: organism,
          special_note: special_note,
          invalid: invalid.join(', ')
        ),
        invalid: invalid
      )
    end

    def build_custom_result(rule:, label:, passed:, pass_message:, fail_message:, invalid:)
      field = "#{@check_prefix}.#{rule}"
      if passed
        {
          errors: [],
          valid_checks: [{ field: field, status: 'passed', message: pass_message }]
        }
      else
        {
          errors: [{ field: field, message: fail_message }],
          valid_checks: [{ field: field, status: 'failed', message: Rules.organism_specific_fail_message('check_failed', label: label) }]
        }
      end
    end

    def skipped_check(rule, reason)
      {
        errors: [],
        valid_checks: [{ field: "#{@check_prefix}.#{rule}", status: 'skipped', message: Rules.organism_specific_skip_message(rule, reason) }]
      }
    end

    def human_organism?(organism)
      organism.to_s == Rules.organism_ethnicity_human
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
        special_values.include?(value) || Rules.ontology_term_matches_prefixes?(value, allowed_prefixes)
      end.uniq.first(5)
    end

    def split_values(raw)
      Array(raw).flat_map { |value| value.to_s.split(' || ') }.map(&:strip).reject(&:blank?)
    end
  end
end
