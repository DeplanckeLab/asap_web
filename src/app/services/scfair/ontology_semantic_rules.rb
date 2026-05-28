# frozen_string_literal: true

module Scfair
  module OntologySemanticRules
    RULES_BY_FIELD = {
      'assay_ontology_term_id' => {
        any_roots: %w[EFO:0002772 EFO:0010183],
        forbidden_exact: %w[EFO:0010961]
      },
      'cell_type_ontology_term_id' => {
        any_roots: %w[CL:0000000],
        forbidden_branches: %w[WBbt:0006803],
        forbidden_exact: SchemaConstants::BANNED_CELL_TYPE_TERMS,
        allowed_special_values: %w[na unknown]
      },
      'development_stage_ontology_term_id' => {
        any_roots: %w[UBERON:0000105],
        forbidden_branches: %w[UBERON:0000071],
        allowed_special_values: %w[na unknown]
      },
      'tissue_ontology_term_id' => {
        any_roots: %w[UBERON:0001062]
      },
      'disease_ontology_term_id' => {
        any_roots: %w[MONDO:0000001 MONDO:0021178],
        allowed_exact: %w[PATO:0000461]
      },
      'self_reported_ethnicity_ontology_term_id' => {
        any_roots: %w[HANCESTRO:0601 HANCESTRO:0602],
        sorted_multi: true,
        allowed_special_values: %w[na unknown multiethnic]
      },
      'sex_ontology_term_id' => {
        allowed_exact: SchemaConstants::VALID_SEX_TERM_IDS.keys,
        allowed_special_values: SchemaConstants::SEX_SPECIAL_VALUES
      }
    }.freeze

    LABEL_PAIRS = {
      'assay_ontology_term_id' => 'assay',
      'cell_type_ontology_term_id' => 'cell_type',
      'development_stage_ontology_term_id' => 'development_stage',
      'disease_ontology_term_id' => 'disease',
      'self_reported_ethnicity_ontology_term_id' => 'self_reported_ethnicity',
      'sex_ontology_term_id' => 'sex',
      'tissue_ontology_term_id' => 'tissue',
      'organism_ontology_term_id' => 'organism'
    }.freeze

    module_function

    def rules_for(field_name)
      RULES_BY_FIELD[field_name.to_s]
    end

    def label_field_name(term_field_name)
      LABEL_PAIRS[term_field_name.to_s]
    end

    def allowed_special_values_for(field_name)
      rules_for(field_name)&.dig(:allowed_special_values) || []
    end
  end
end
