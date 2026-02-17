# frozen_string_literal: true

# Shared CELLxGENE schema cross-field constraint rules.
#
# Used by both:
# - ComplianceController (to auto-fill / force values in the fix form)
# - CxgLoomValidatorService (to report errors/warnings during validation)
#
# Reference: https://github.com/chanzuckerberg/single-cell-curation/blob/main/schema/7.1.0/schema.md
module CxgSchemaRules
  extend ActiveSupport::Concern

  # ── Assay -> suspension_type mapping ──────────────────────────────────
  #
  # Maps EFO assay terms to their allowed suspension_type values.
  # When a single value is allowed, suspension_type is fully determined.
  # When multiple values are allowed, the user must pick one.
  # Source: CELLxGENE schema 7.1.0, suspension_type table.
  ASSAY_SUSPENSION_TYPE_MAP = {
    # Exact assay terms -> allowed suspension_type values
    'EFO:0700004' => ['cell'],                    # BD Rhapsody Targeted mRNA
    'EFO:0700003' => ['cell'],                    # BD Rhapsody Whole Transcriptome Analysis
    'EFO:0010010' => ['cell', 'nucleus'],          # CEL-seq2
    'EFO:0008720' => ['nucleus'],                  # DroNc-seq
    'EFO:0008722' => ['cell', 'nucleus'],          # Drop-seq
    'EFO:0700011' => ['cell', 'nucleus'],          # GEXSCOPE technology
    'EFO:0008780' => ['cell', 'nucleus'],          # inDrop
    'EFO:0008796' => ['cell'],                    # MARS-seq
    'EFO:0030060' => ['cell', 'nucleus'],          # mCT-seq
    'EFO:0008992' => ['na'],                      # MERFISH
    'EFO:0030002' => ['cell'],                    # microwell-seq
    'EFO:0008853' => ['cell'],                    # Patch-seq
    'EFO:0022490' => ['cell', 'nucleus'],          # ScaleBio single cell RNA sequencing
    'EFO:0030026' => ['nucleus'],                  # sci-Plex
    'EFO:0010550' => ['cell', 'nucleus'],          # sci-RNA-seq
    'EFO:0030028' => ['cell', 'nucleus'],          # sci-RNA-seq3
    'EFO:0008953' => ['cell'],                    # STRT-seq
    'EFO:0700010' => ['cell', 'nucleus'],          # TruDrop
    'EFO:0009919' => ['cell', 'nucleus'],          # SPLiT-seq
    # Common 10x assays (descendants of EFO:0030080)
    'EFO:0009899' => ['cell', 'nucleus'],          # 10x 3' v2
    'EFO:0009922' => ['cell', 'nucleus'],          # 10x 3' v3
    'EFO:0022604' => ['cell', 'nucleus'],          # 10x 3' v4
    'EFO:0011025' => ['cell', 'nucleus'],          # 10x 5' v1
    'EFO:0009900' => ['cell', 'nucleus'],          # 10x 5' v2
    'EFO:0022605' => ['cell', 'nucleus'],          # 10x 5' v3
    'EFO:0030059' => ['cell', 'nucleus'],          # 10x multiome
    # Smart-like descendants
    'EFO:0008931' => ['cell', 'nucleus'],          # Smart-seq2
    # ATAC-seq descendants
    'EFO:0010891' => ['nucleus'],                  # scATAC-seq
    # Spatial assays
    'EFO:0010961' => ['na'],                      # Visium Spatial Gene Expression
    'EFO:0022857' => ['na'],                      # Visium Spatial Gene Expression V1
    'EFO:0022859' => ['na'],                      # Visium CytAssist 6.5mm
    'EFO:0022860' => ['na'],                      # Visium CytAssist 11mm
    'EFO:0030062' => ['na'],                      # Slide-seqV2
    # Ancestor-based rules (used as fallback for unknown descendants):
    'EFO:0030080' => ['cell', 'nucleus'],          # 10x transcription profiling
    'EFO:0007045' => ['nucleus'],                  # ATAC-seq
    'EFO:0002761' => ['nucleus'],                  # methylation profiling by HTS
    'EFO:0008919' => ['cell'],                    # Seq-Well and descendants
    'EFO:0010184' => ['cell', 'nucleus'],          # Smart-like and descendants
    'EFO:0008994' => ['na'],                      # spatial transcriptomics and descendants
  }.freeze

  # Terms in ASSAY_SUSPENSION_TYPE_MAP that should match descendants too
  ASSAY_ANCESTOR_TERMS = %w[
    EFO:0030080 EFO:0007045 EFO:0002761 EFO:0008919 EFO:0010184 EFO:0008994
  ].freeze

  # ── tissue_type = "cell line" forced fields ───────────────────────────
  #
  # When tissue_type is "cell line", the following fields are forced.
  # Each entry: { field:, value:, label_field: (optional), label_value: (optional) }
  CELL_LINE_FORCED_FIELDS = [
    { field: 'self_reported_ethnicity_ontology_term_id', value: 'na',
      label_field: 'self_reported_ethnicity', label_value: 'na' },
    { field: 'sex_ontology_term_id', value: 'na',
      label_field: 'sex', label_value: 'na' },
    { field: 'development_stage_ontology_term_id', value: 'unknown',
      label_field: 'development_stage', label_value: 'unknown' },
    { field: 'donor_id', value: 'na' },
    { field: 'suspension_type', value: 'na' }
  ].freeze

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
