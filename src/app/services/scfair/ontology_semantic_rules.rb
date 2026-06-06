# frozen_string_literal: true

module Scfair
  module OntologySemanticRules
    module_function

    def rules_for(field_name)
      Rules.semantic_rules_for(field_name)
    end

    def label_field_name(term_field_name)
      Rules.label_pairs[term_field_name.to_s]
    end

    def allowed_special_values_for(field_name)
      rules_for(field_name)&.dig(:allowed_special_values) || []
    end
  end
end
