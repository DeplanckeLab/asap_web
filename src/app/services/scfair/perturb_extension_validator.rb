# frozen_string_literal: true

module Scfair
  class PerturbExtensionValidator
    ID_FORBIDDEN_CHARS = /[\s\/",]/.freeze
    PROTOSPACER_SEQUENCE = /\A[ACGT]+\z/.freeze
    PAM_VALUE = /\A3' [ABCDGHKMNRSTVWY]+\z/.freeze
    DERIVED_REGION = /\A[^:]+:\d+-\d+\([+-]\)\z/.freeze

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @rules = Rules.perturb_extension_rules
      @parser = PerturbStructureParser.new(field_values: @field_values, format: @format)
      @structure = @parser.parse
    end

    def call
      unless PerturbAssayHelper.perturb_enabled?(@field_values, @format)
        return {
          errors: [],
          valid_checks: [{
            field: 'extension.perturb',
            status: 'skipped',
            message: 'No perturb extension detected'
          }]
        }
      end

      errors = []
      valid_checks = []

      validate_presence(errors, valid_checks)
      validate_organism(errors)
      validate_genetic_perturbation_id(errors, valid_checks)
      validate_genetic_perturbation_strategy(errors, valid_checks)
      validate_uns_structure(errors, valid_checks)

      status = errors.empty? ? 'passed' : 'failed'
      valid_checks << {
        field: 'extension.perturb',
        status: status,
        message: status == 'passed' ? 'Perturb schema checks passed' : 'Perturb schema checks failed'
      }

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def validate_presence(errors, valid_checks)
      has_uns = @structure[:present]
      has_id = field_present?('genetic_perturbation_id')
      has_strategy = field_present?('genetic_perturbation_strategy')

      if has_uns && !has_id
        errors << {
          field: 'extension.perturb.obs.id',
          message: 'genetic_perturbation_id is required when uns genetic_perturbations is present'
        }
      end

      if has_id && !has_uns
        errors << {
          field: 'extension.perturb.uns',
          message: 'uns genetic_perturbations is required when genetic_perturbation_id is present'
        }
      end

      if has_id && !has_strategy
        errors << {
          field: 'extension.perturb.strategy',
          message: 'genetic_perturbation_strategy is required when genetic_perturbation_id is present'
        }
      end

      if has_strategy && !has_id
        errors << {
          field: 'extension.perturb.obs.id',
          message: 'genetic_perturbation_id is required when genetic_perturbation_strategy is present'
        }
      end

      if has_uns && @structure[:perturbation_ids].empty?
        errors << {
          field: 'extension.perturb.uns',
          message: 'uns genetic_perturbations must contain at least one perturbation entry'
        }
      end

      presence_failed = errors.any? { |entry| entry[:field].start_with?('extension.perturb.') }
      valid_checks << {
        field: 'extension.perturb.presence',
        status: presence_failed ? 'failed' : 'passed',
        message: presence_failed ? 'Perturbation presence checks failed' : 'Perturbation presence checks passed'
      }
    end

    def validate_organism(errors)
      organism = Array(@field_values[PerturbAssayHelper.organism_key(@format)]).first.to_s.strip
      return if organism.blank?

      return if @rules[:allowed_organisms].include?(organism)

      errors << {
        field: 'extension.perturb.organism',
        message: "organism_ontology_term_id must be one of #{@rules[:allowed_organisms].join(', ')} for perturbation datasets (found #{organism})"
      }
    end

    def validate_genetic_perturbation_id(errors, valid_checks)
      return unless field_present?('genetic_perturbation_id')

      before = errors.length
      path = PerturbAssayHelper.obs_field_path(@format, 'genetic_perturbation_id')
      values = Array(@field_values[path]).map(&:to_s).reject(&:blank?)

      if values.include?('na')
        errors << {
          field: 'extension.perturb.obs.id',
          message: 'genetic_perturbation_id must not contain "na" in any observation'
        }
      end

      known_ids = @structure[:perturbation_ids].to_set
      values.each do |value|
        ids = split_ids(value)
        if ids.empty?
          errors << { field: 'extension.perturb.obs.id', message: 'genetic_perturbation_id value must not be empty' }
          next
        end

        if ids.uniq.length != ids.length
          errors << {
            field: 'extension.perturb.obs.id',
            message: "genetic_perturbation_id contains duplicate identifiers: #{value}"
          }
        end

        if ids != ids.sort
          errors << {
            field: 'extension.perturb.obs.id',
            message: "genetic_perturbation_id identifiers must be in ascending lexical order: #{value}"
          }
        end

        ids.each do |id|
          next if known_ids.include?(id)

          errors << {
            field: 'extension.perturb.obs.id',
            message: "genetic_perturbation_id references unknown perturbation identifier #{id}"
          }
        end
      end

      validate_control_role_consistency(errors, values)

      id_issues = errors.length - before
      valid_checks << {
        field: 'extension.perturb.obs.id',
        status: id_issues.positive? ? 'failed' : 'passed',
        message: id_issues.positive? ? 'genetic_perturbation_id value checks failed' : 'genetic_perturbation_id value checks passed'
      }
    end

    def validate_control_role_consistency(errors, id_values)
      strategy_values = Array(@field_values[PerturbAssayHelper.obs_field_path(@format, 'genetic_perturbation_strategy')])
                        .map(&:to_s)
                        .reject(&:blank?)
      return unless strategy_values.include?('control')

      id_values.each do |value|
        split_ids(value).each do |id|
          role = entry_scalar(id, 'role').first.to_s
          next if role == 'control'

          errors << {
            field: 'extension.perturb.obs.id',
            message: "genetic_perturbations[#{id}]/role must be control when genetic_perturbation_strategy is control"
          }
        end
      end
    end

    def validate_genetic_perturbation_strategy(errors, valid_checks)
      return unless field_present?('genetic_perturbation_strategy')

      path = PerturbAssayHelper.obs_field_path(@format, 'genetic_perturbation_strategy')
      id_path = PerturbAssayHelper.obs_field_path(@format, 'genetic_perturbation_id')
      strategy_values = Array(@field_values[path]).map(&:to_s).reject(&:blank?)
      id_values = Array(@field_values[id_path]).map(&:to_s).reject(&:blank?)
      strategy_issues = 0

      allowed = @rules[:strategy_values] + [@rules[:strategy_no_perturbations]]

      strategy_values.each do |strategy|
        unless allowed.include?(strategy)
          errors << {
            field: 'extension.perturb.strategy',
            message: "Invalid genetic_perturbation_strategy value: #{strategy}"
          }
          strategy_issues += 1
        end
      end

      if id_values.include?('na') && strategy_values.any? { |v| v != @rules[:strategy_no_perturbations] }
        errors << {
          field: 'extension.perturb.strategy',
          message: 'genetic_perturbation_strategy must be "no perturbations" when genetic_perturbation_id is "na"'
        }
        strategy_issues += 1
      end

      valid_checks << {
        field: 'extension.perturb.strategy',
        status: strategy_issues.positive? ? 'failed' : 'passed',
        message: strategy_issues.positive? ? 'genetic_perturbation_strategy value checks failed' : 'genetic_perturbation_strategy value checks passed'
      }
    end

    def validate_uns_structure(errors, valid_checks)
      return unless @structure[:present]

      before = errors.length
      allowed_entry_keys = (@rules[:curator_required_keys] + @rules[:optional_keys]).to_set

      @structure[:perturbation_ids].each do |id|
        unless valid_perturbation_id?(id)
          errors << {
            field: 'extension.perturb.uns',
            message: "Invalid genetic perturbation identifier key: #{id}"
          }
        end

        entry = @structure[:entries][id]
        present_keys = entry[:scalar_keys].to_set
        @rules[:curator_required_keys].each do |key|
          next if present_keys.include?(key) || entry[:scalar_values][key].present?

          errors << {
            field: 'extension.perturb.uns',
            message: "genetic_perturbations[#{id}] missing required key #{key}"
          }
        end

        unexpected = present_keys - allowed_entry_keys
        unexpected.each do |key|
          errors << {
            field: 'extension.perturb.uns',
            message: "genetic_perturbations[#{id}] contains unexpected key #{key}"
          }
        end

        validate_entry_values(errors, id, entry)
      end

      structure_issues = errors.length - before
      valid_checks << {
        field: 'extension.perturb.uns',
        status: structure_issues.positive? ? 'failed' : 'passed',
        message: structure_issues.positive? ? 'genetic_perturbations structure checks failed' : 'genetic_perturbations structure checks passed'
      }
    end

    def validate_entry_values(errors, id, entry)
      role = entry_scalar(id, 'role').first.to_s
      if role.present? && !@rules[:role_values].include?(role)
        errors << {
          field: 'extension.perturb.uns',
          message: "genetic_perturbations[#{id}]/role must be control or targeting (found #{role})"
        }
      end

      sequence = entry_scalar(id, 'protospacer_sequence').first.to_s
      if sequence.present?
        unless sequence.match?(PROTOSPACER_SEQUENCE) && sequence.length.between?(14, 22)
          errors << {
            field: 'extension.perturb.uns',
            message: "genetic_perturbations[#{id}]/protospacer_sequence must be 14-22 ACGT characters"
          }
        end
      end

      pam = entry_scalar(id, 'protospacer_adjacent_motif').first.to_s
      if pam.present?
        unless pam.match?(PAM_VALUE)
          errors << {
            field: 'extension.perturb.uns',
            message: "genetic_perturbations[#{id}]/protospacer_adjacent_motif must be formatted as \"3' MOTIF\""
          }
        end
      end

      validate_derived_genomic_regions(errors, id, entry)
      validate_derived_features(errors, id, entry)
    end

    def validate_derived_genomic_regions(errors, id, entry)
      regions = entry_scalar(id, 'derived_genomic_regions')
      return if regions.empty?

      regions.each do |region|
        next if region.match?(DERIVED_REGION)

        errors << {
          field: 'extension.perturb.uns',
          message: "genetic_perturbations[#{id}]/derived_genomic_regions contains invalid region format: #{region}"
        }
      end
    end

    def validate_derived_features(errors, id, entry)
      has_regions = entry_scalar(id, 'derived_genomic_regions').any?
      feature_ids = entry[:derived_feature_ids]
      return if feature_ids.empty?

      unless has_regions
        errors << {
          field: 'extension.perturb.uns',
          message: "genetic_perturbations[#{id}]/derived_features must not be present without derived_genomic_regions"
        }
      end

      feature_ids.each do |feature_id|
        next if feature_id.present?

        errors << {
          field: 'extension.perturb.uns',
          message: "genetic_perturbations[#{id}]/derived_features contains blank feature_id key"
        }
      end
    end

    def valid_perturbation_id?(id)
      return false if id.blank? || id == 'na'
      return false if id.match?(ID_FORBIDDEN_CHARS)

      id.ascii_only?
    end

    def entry_scalar(id, key)
      entry = @structure[:entries][id]
      return [] unless entry

      values = entry[:scalar_values][key]
      return values if values.present?

      path = "#{PerturbAssayHelper.uns_root_prefix(@format)}#{id}/#{key}"
      Array(@field_values[path]).map(&:to_s).reject(&:blank?)
    end

    def split_ids(value)
      value.to_s.split(@rules[:id_delimiter]).map(&:strip).reject(&:blank?)
    end

    def field_present?(field_name)
      PerturbAssayHelper.present_values?(@field_values[PerturbAssayHelper.obs_field_path(@format, field_name)])
    end
  end
end
