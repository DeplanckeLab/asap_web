# frozen_string_literal: true

# Shared scFAIR schema cross-field constraint rules.
#
# Used by both:
# - ComplianceController (to auto-fill / force values in the fix form)
# - ScfairLoomValidatorService (to report errors/warnings during validation)
#
# Reference: https://github.com/scFAIR/scFAIR/blob/main/schema/7.1.0/README.md
module ScfairSchemaRules
  extend ActiveSupport::Concern

  ASSAY_SUSPENSION_TYPE_MAP = Scfair::Rules.assay_suspension_type_map
  ASSAY_ANCESTOR_TERMS = Scfair::Rules.assay_ancestor_terms
  VALID_SEX_TERMS = Scfair::Rules.valid_sex_terms
  CELL_LINE_FORCED_FIELDS = Scfair::Rules.cell_line_forced_fields

  def cell_line_forced_value_for(field)
    entry = CELL_LINE_FORCED_FIELDS.find { |forced| forced[:field] == field.to_s }
    entry && entry[:value]
  end

  def resolve_suspension_type_for_assay(assay_term_id)
    return nil if assay_term_id.blank?

    allowed = ASSAY_SUSPENSION_TYPE_MAP[assay_term_id]
    return allowed if allowed

    cot = CellOntologyTerm.where(identifier: assay_term_id, original: true).first
    cot ||= CellOntologyTerm.where(identifier: assay_term_id).first
    return nil unless cot && cot.lineage.present?

    lineage_ids = cot.lineage.split(',').map(&:to_i).to_set

    ASSAY_ANCESTOR_TERMS.each do |ancestor_identifier|
      ancestor_cot = CellOntologyTerm.where(identifier: ancestor_identifier, original: true).first
      next unless ancestor_cot && lineage_ids.include?(ancestor_cot.id)
      return ASSAY_SUSPENSION_TYPE_MAP[ancestor_identifier]
    end

    nil
  end

  def check_cross_field_constraints(
    organism_tax_id: nil,
    assay_term_id: nil,
    tissue_type: nil,
    suspension_type: nil,
    ethnicity_term_id: nil,
    sex_term_id: nil,
    dev_stage_term_id: nil,
    donor_id_val: nil,
    tissue_term_id: nil,
    cell_type_term_id: nil,
    format: 'loom'
  )
    violations = []

    if assay_term_id.present? && suspension_type.present?
      allowed = resolve_suspension_type_for_assay(assay_term_id)
      if allowed && !allowed.include?(suspension_type)
        violations << Scfair::Rules.cross_field_violation_message(
          'CF-1',
          format: format,
          assay: assay_term_id,
          allowed: allowed.join(', '),
          value: suspension_type
        )
      end
    end

    if tissue_type == 'cell line'
      {
        'CF-2a' => ['self_reported_ethnicity_ontology_term_id', ethnicity_term_id],
        'CF-2b' => ['sex_ontology_term_id', sex_term_id],
        'CF-2c' => ['development_stage_ontology_term_id', dev_stage_term_id],
        'CF-2d' => ['donor_id', donor_id_val],
        'CF-2e' => ['suspension_type', suspension_type]
      }.each do |rule_key, (field, actual)|
        expected = cell_line_forced_value_for(field)
        next if actual.blank? || actual == expected

        violations << Scfair::Rules.cross_field_violation_message(
          rule_key,
          format: format,
          value: actual
        )
      end

      if tissue_term_id.present? && !Scfair::Rules.cellosaurus_ontology_term?(tissue_term_id)
        violations << Scfair::Rules.cross_field_violation_message(
          'CF-2f',
          format: format,
          value: tissue_term_id
        )
      end

      if cell_type_term_id.present? && !%w[na unknown].include?(cell_type_term_id)
        violations << Scfair::Rules.cross_field_violation_message(
          'CF-7',
          format: format,
          value: cell_type_term_id
        )
      end
    end

    if tissue_type == 'organoid' && tissue_term_id.present?
      forbidden = Scfair::Rules.cross_field_organoid_embryo_term
      if forbidden.present? && tissue_term_id == forbidden
        violations << Scfair::Rules.cross_field_violation_message(
          'CF-4',
          format: format,
          forbidden_term: forbidden,
          value: tissue_term_id
        )
      end
    end

    violations
  end
end
