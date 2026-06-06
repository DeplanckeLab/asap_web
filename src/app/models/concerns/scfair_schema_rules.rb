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

  # ── Assay -> suspension_type mapping ──────────────────────────────────
  #
  # Maps EFO assay terms to their allowed suspension_type values.
  # When a single value is allowed, suspension_type is fully determined.
  # When multiple values are allowed, the user must pick one.
  # Source: scFAIR schema 7.1.0, suspension_type table (config/scfair/7.1.0/rules.yaml).
  ASSAY_SUSPENSION_TYPE_MAP = Scfair::Rules.assay_suspension_type_map
  ASSAY_ANCESTOR_TERMS = Scfair::Rules.assay_ancestor_terms
  VALID_SEX_TERMS = Scfair::Rules.valid_sex_terms
  CELL_LINE_FORCED_FIELDS = Scfair::Rules.cell_line_forced_fields

  # ── Shared resolution method ──────────────────────────────────────────

  # Resolve the allowed suspension_type values for a given assay EFO term.
  # Uses exact match first, then falls back to ancestor-based matching
  # using the DB lineage data.
  def resolve_suspension_type_for_assay(assay_term_id)
    return nil if assay_term_id.blank?

    # 1. Exact match
    allowed = ASSAY_SUSPENSION_TYPE_MAP[assay_term_id]
    return allowed if allowed

    # 2. Ancestor-based: look up the term's lineage in the DB and check
    #    if any ancestor is in ASSAY_ANCESTOR_TERMS
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

  # ── Cross-field constraint checker ────────────────────────────────────
  #
  # Checks all cross-field constraints and returns a list of violations.
  # Each violation: { field:, severity: (:error or :warning), message: }
  #
  # Parameters are the *actual* values currently in the dataset (strings).
  # Pass nil for fields that are absent from the dataset.
  def check_cross_field_constraints(
    organism_tax_id: nil,
    assay_term_id: nil,
    tissue_type: nil,
    suspension_type: nil,
    ethnicity_term_id: nil,
    sex_term_id: nil,
    dev_stage_term_id: nil,
    donor_id_val: nil,
    tissue_term_id: nil
  )
    violations = []

    # Rule 1: Non-human organism -> ethnicity MUST be "na"
    if organism_tax_id.present? && organism_tax_id != '9606' && organism_tax_id != 'NCBITaxon:9606'
      if ethnicity_term_id.present? && ethnicity_term_id != 'na'
        violations << {
          field: '/col_attrs/self_reported_ethnicity_ontology_term_id',
          severity: :error,
          message: "Organism is not Homo sapiens -- self_reported_ethnicity_ontology_term_id MUST be \"na\", got \"#{ethnicity_term_id}\"."
        }
      end
    end

    # Rule 2: assay -> suspension_type consistency
    if assay_term_id.present? && suspension_type.present?
      allowed = resolve_suspension_type_for_assay(assay_term_id)
      if allowed && !allowed.include?(suspension_type)
        violations << {
          field: '/col_attrs/suspension_type',
          severity: :error,
          message: "For assay #{assay_term_id}, suspension_type MUST be one of: #{allowed.join(', ')}. Got \"#{suspension_type}\"."
        }
      end
    end

    # Rule 3: tissue_type = "cell line" cascade
    if tissue_type == 'cell line'
      # 3a. ethnicity must be "na"
      if ethnicity_term_id.present? && ethnicity_term_id != 'na'
        violations << {
          field: '/col_attrs/self_reported_ethnicity_ontology_term_id',
          severity: :error,
          message: "tissue_type is \"cell line\" -- self_reported_ethnicity_ontology_term_id MUST be \"na\", got \"#{ethnicity_term_id}\"."
        }
      end

      # 3b. sex must be "na"
      if sex_term_id.present? && sex_term_id != 'na'
        violations << {
          field: '/col_attrs/sex_ontology_term_id',
          severity: :error,
          message: "tissue_type is \"cell line\" -- sex_ontology_term_id MUST be \"na\", got \"#{sex_term_id}\"."
        }
      end

      # 3c. development_stage must be "unknown"
      if dev_stage_term_id.present? && dev_stage_term_id != 'unknown'
        violations << {
          field: '/col_attrs/development_stage_ontology_term_id',
          severity: :error,
          message: "tissue_type is \"cell line\" -- development_stage_ontology_term_id MUST be \"unknown\", got \"#{dev_stage_term_id}\"."
        }
      end

      # 3d. donor_id must be "na"
      if donor_id_val.present? && donor_id_val != 'na'
        violations << {
          field: '/col_attrs/donor_id',
          severity: :error,
          message: "tissue_type is \"cell line\" -- donor_id MUST be \"na\", got \"#{donor_id_val}\"."
        }
      end

      # 3e. suspension_type must be "na"
      if suspension_type.present? && suspension_type != 'na'
        violations << {
          field: '/col_attrs/suspension_type',
          severity: :error,
          message: "tissue_type is \"cell line\" -- suspension_type MUST be \"na\", got \"#{suspension_type}\"."
        }
      end

      # 3f. tissue_ontology_term_id should be a Cellosaurus (CVCL_) term
      if tissue_term_id.present? && !tissue_term_id.start_with?('CVCL_')
        violations << {
          field: '/col_attrs/tissue_ontology_term_id',
          severity: :warning,
          message: "tissue_type is \"cell line\" -- tissue_ontology_term_id SHOULD be a Cellosaurus term (CVCL_*), got \"#{tissue_term_id}\"."
        }
      end
    end

    violations
  end
end
