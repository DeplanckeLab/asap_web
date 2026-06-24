# frozen_string_literal: true

module Scfair
  # Applies rules.yaml constraints to compliance fix field groups so autocomplete
  # and fixed-value pickers only propose allowed ontology terms.
  class FixFieldGroupRulesEnricher
    def self.call(fixable_groups)
      new(fixable_groups).call
    end

    def initialize(fixable_groups)
      @fixable_groups = Array(fixable_groups)
    end

    def call
      @fixable_groups.each do |fg|
        group = fg[:group]
        next unless group.is_a?(Hash)

        field_name = Rules.obs_field_name_from_path(group[:term_path])
        next if field_name.blank?

        group[:multi_value] = Rules.multi_value_field?(field_name)
        group[:multi_value_sorted] = Rules.multi_value_sorted_field?(field_name) if group[:multi_value]

        valid_terms = Rules.ontology_valid_terms(field_name)
        if valid_terms.present?
          group[:allowed_terms] = valid_terms.map { |identifier, name| { identifier: identifier, name: name } }
        end

        banned = Rules.ontology_banned_terms(field_name)
        group[:banned_term_ids] = banned if banned.any?

        if field_name == 'ensembl_database'
          allowed = Rules.ensembl_database_values
          group[:term_valid_values] = allowed if allowed.any?
        end
      end

      @fixable_groups
    end
  end
end
