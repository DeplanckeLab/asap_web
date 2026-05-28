# frozen_string_literal: true

module Scfair
  class CrossFieldConstraintEvaluator
    include CxgSchemaRules

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
    end

    def call
      prefix = @format == 'h5ad' ? 'obs/' : '/col_attrs/'
      organism_key = @format == 'h5ad' ? 'uns/organism_ontology_term_id' : '/attrs/organism_ontology_term_id'
      organism = first(@field_values[organism_key])
      tissue_type = first(@field_values["#{prefix}tissue_type"])
      assay = first(@field_values["#{prefix}assay_ontology_term_id"])
      suspension = first(@field_values["#{prefix}suspension_type"])
      ethnicity = first(@field_values["#{prefix}self_reported_ethnicity_ontology_term_id"])
      sex = first(@field_values["#{prefix}sex_ontology_term_id"])
      dev_stage = first(@field_values["#{prefix}development_stage_ontology_term_id"])
      donor = first(@field_values["#{prefix}donor_id"])
      tissue = first(@field_values["#{prefix}tissue_ontology_term_id"])

      violations = check_cross_field_constraints(
        organism_tax_id: organism,
        assay_term_id: assay,
        tissue_type: tissue_type,
        suspension_type: suspension,
        ethnicity_term_id: ethnicity,
        sex_term_id: sex,
        dev_stage_term_id: dev_stage,
        donor_id_val: donor,
        tissue_term_id: tissue
      )

      errors = []
      warnings = []
      rule_checks = []
      Array(violations).each do |v|
        item = { field: "cross-field.#{v[:field]}", message: v[:message] }
        v[:severity] == :error ? errors << item : warnings << item
      end

      violated_fields = (errors + warnings).map { |x| x[:field].to_s }.join(' ')
      add_cf1_ethnicity_organism_check(
        rule_checks, errors: errors, organism: organism, ethnicity: ethnicity, tissue_type: tissue_type,
        violated_fields: violated_fields
      )
      add_rule_check(rule_checks, 'CF-2-assay-suspension', violated_fields, '/suspension_type',
                     'Assay/suspension_type consistency')
      add_cf3_cell_line_checks(rule_checks, tissue_type: tissue_type, violated_fields: violated_fields)

      # CF-4 donor_id logic
      donor_bad = tissue_type != 'cell line' && donor == 'na'
      rule_checks << {
        field: 'cross-field.CF-4-donor-id',
        status: donor_bad ? 'failed' : 'passed',
        message: donor_bad ? 'donor_id must not be "na" unless tissue_type is "cell line"' : 'donor_id consistency OK'
      }

      # CF-5 organoid constraints
      organoid_bad = tissue_type == 'organoid' && tissue == 'UBERON:0000922'
      rule_checks << {
        field: 'cross-field.CF-5-organoid-tissue',
        status: organoid_bad ? 'failed' : (tissue_type == 'organoid' ? 'passed' : 'skipped'),
        message: tissue_type == 'organoid' ? (organoid_bad ? 'Organoid tissue must not be embryo (UBERON:0000922)' : 'Organoid tissue constraints OK') : 'Not applicable'
      }

      # CF-6 spatial assays should be homogeneous
      visium_terms = Scfair::SchemaConstants::VISIUM_ASSAY_TERMS + [Scfair::SchemaConstants::SLIDE_SEQ_ASSAY]
      assays = Array(@field_values["#{prefix}assay_ontology_term_id"]).flat_map { |v| v.to_s.split(' || ') }.map(&:strip).uniq
      spatial_assays = assays & visium_terms
      mixed_spatial = spatial_assays.any? && assays.size > 1
      rule_checks << {
        field: 'cross-field.CF-6-spatial-assay-uniformity',
        status: mixed_spatial ? 'failed' : (spatial_assays.any? ? 'passed' : 'skipped'),
        message: spatial_assays.any? ? (mixed_spatial ? 'Spatial assay datasets must use a single assay value' : 'Spatial assay uniformity OK') : 'Not applicable'
      }

      # CF-7 C. elegans sex constraint
      celegans = organism == 'NCBITaxon:6239'
      celegans_bad = celegans && !%w[PATO:0000384 PATO:0001340 unknown na].include?(sex)
      rule_checks << {
        field: 'cross-field.CF-7-celegans-sex',
        status: celegans ? (celegans_bad ? 'failed' : 'passed') : 'skipped',
        message: celegans ? (celegans_bad ? 'C. elegans sex must be male or hermaphrodite' : 'C. elegans sex constraint OK') : 'Not applicable'
      }

      # CF-8 spatial is_single implies is_primary_data false when false
      is_primary = first(@field_values["#{prefix}is_primary_data"])
      is_single = first(@field_values[@format == 'h5ad' ? 'uns/spatial/is_single' : '/attrs/spatial/is_single'])
      cf8_bad = is_single == 'false' && is_primary == 'true'
      rule_checks << {
        field: 'cross-field.CF-8-spatial-primary-data',
        status: is_single.present? ? (cf8_bad ? 'failed' : 'passed') : 'skipped',
        message: is_single.present? ? (cf8_bad ? 'is_primary_data must be false when spatial.is_single is false' : 'Spatial primary-data constraint OK') : 'Not applicable'
      }

      # CF-9 cell line allows na/unknown cell type
      cell_type = first(@field_values["#{prefix}cell_type_ontology_term_id"])
      cf9_bad = tissue_type == 'cell line' && !%w[na unknown].include?(cell_type) && cell_type.present?
      rule_checks << {
        field: 'cross-field.CF-9-cell-line-cell-type',
        status: tissue_type == 'cell line' ? (cf9_bad ? 'failed' : 'passed') : 'skipped',
        message: tissue_type == 'cell line' ? (cf9_bad ? 'cell_type_ontology_term_id should be na/unknown for cell lines' : 'Cell line cell_type constraint OK') : 'Not applicable'
      }

      # CF-11 label/id special pair consistency
      cf11 = cf11_label_id_checks(prefix)
      rule_checks.concat(cf11[:checks])
      errors.concat(cf11[:errors])

      # CF-12 Visium out-of-tissue spots should be unknown cell type
      in_tissue = first(@field_values["#{prefix}in_tissue"])
      visium = assays.any? { |a| Scfair::SchemaConstants::VISIUM_ASSAY_TERMS.include?(a) }
      cf12_bad = visium && in_tissue == '0' && cell_type != 'unknown'
      rule_checks << {
        field: 'cross-field.CF-12-visium-in-tissue',
        status: visium ? (cf12_bad ? 'failed' : 'passed') : 'skipped',
        message: visium ? (cf12_bad ? 'Visium spots with in_tissue=0 must use cell_type_ontology_term_id=unknown' : 'Visium in_tissue constraint OK') : 'Not applicable'
      }

      valid_checks = rule_checks
      valid_checks << { field: 'cross-field.constraints', status: 'passed', message: 'All cross-field schema constraints satisfied' } if errors.empty? && warnings.empty?

      { errors: errors, warnings: warnings, valid_checks: valid_checks }
    end

    private

    def first(v)
      Array(v).first.to_s
    end

    CF3_CELL_LINE_RULES = [
      {
        id: 'CF-3a-cell-line-ethnicity',
        token: 'self_reported_ethnicity_ontology_term_id',
        skip_detail: 'ethnicity must be "na" (cell lines have no donor ancestry)',
        pass_detail: 'self_reported_ethnicity_ontology_term_id is "na"',
        fail_detail: 'self_reported_ethnicity_ontology_term_id must be "na" for cell lines'
      },
      {
        id: 'CF-3b-cell-line-sex',
        token: 'sex_ontology_term_id',
        skip_detail: 'sex must be "na" (not applicable to a cultured line)',
        pass_detail: 'sex_ontology_term_id is "na"',
        fail_detail: 'sex_ontology_term_id must be "na" for cell lines'
      },
      {
        id: 'CF-3c-cell-line-development-stage',
        token: 'development_stage_ontology_term_id',
        skip_detail: 'development_stage must be "unknown" (no in vivo stage for a line)',
        pass_detail: 'development_stage_ontology_term_id is "unknown"',
        fail_detail: 'development_stage_ontology_term_id must be "unknown" for cell lines'
      },
      {
        id: 'CF-3d-cell-line-donor-id',
        token: 'donor_id',
        skip_detail: 'donor_id must be "na" (line identity is not a donor ID)',
        pass_detail: 'donor_id is "na"',
        fail_detail: 'donor_id must be "na" for cell lines'
      },
      {
        id: 'CF-3e-cell-line-suspension',
        token: 'suspension_type',
        skip_detail: 'suspension_type must be "na" (not used for cell line profiles)',
        pass_detail: 'suspension_type is "na"',
        fail_detail: 'suspension_type must be "na" for cell lines'
      },
      {
        id: 'CF-3f-cell-line-tissue-id',
        token: 'tissue_ontology_term_id',
        skip_detail: 'tissue_ontology_term_id should be a Cellosaurus ID (CVCL_*) naming the line',
        pass_detail: 'tissue_ontology_term_id is a Cellosaurus term (CVCL_*)',
        fail_detail: 'tissue_ontology_term_id should be a Cellosaurus term (CVCL_*) for cell lines'
      }
    ].freeze

    def human_organism?(organism)
      %w[NCBITaxon:9606 9606].include?(organism.to_s)
    end

    def add_cf3_cell_line_checks(rule_checks, tissue_type:, violated_fields:)
      cell_line = tissue_type == 'cell line'

      CF3_CELL_LINE_RULES.each do |rule|
        field = "cross-field.#{rule[:id]}"

        unless cell_line
          rule_checks << {
            field: field,
            status: 'skipped',
            message: "Not applicable (tissue_type is not \"cell line\"). For cell lines only: #{rule[:skip_detail]}"
          }
          next
        end

        failed = violated_fields.include?(rule[:token])
        rule_checks << {
          field: field,
          status: failed ? 'failed' : 'passed',
          message: failed ? rule[:fail_detail] : rule[:pass_detail]
        }
      end
    end

    # CF-1a / CF-1b: ethnicity vs organism (mutually exclusive; one is always N/A).
    def add_cf1_ethnicity_organism_check(rule_checks, errors:, organism:, ethnicity:, tissue_type:, violated_fields:)
      ethnicity_path = 'self_reported_ethnicity_ontology_term_id'
      cell_line_skip = 'Not applicable (tissue_type is "cell line"; ethnicity is validated under CF-3a)'
      organism_skip = 'Not applicable (organism not set)'

      if organism.blank?
        rule_checks << { field: 'cross-field.CF-1a-ethnicity-non-human', status: 'skipped', message: organism_skip }
        rule_checks << { field: 'cross-field.CF-1b-ethnicity-human', status: 'skipped', message: organism_skip }
        return
      end

      if tissue_type == 'cell line'
        rule_checks << { field: 'cross-field.CF-1a-ethnicity-non-human', status: 'skipped', message: cell_line_skip }
        rule_checks << { field: 'cross-field.CF-1b-ethnicity-human', status: 'skipped', message: cell_line_skip }
        return
      end

      human = human_organism?(organism)

      if human
        rule_checks << {
          field: 'cross-field.CF-1a-ethnicity-non-human',
          status: 'skipped',
          message: 'Not applicable (organism is Homo sapiens)'
        }
        failed = ethnicity == 'na'
        if failed
          errors << {
            field: 'cross-field.CF-1b-ethnicity-human',
            message: 'Homo sapiens dataset: self_reported_ethnicity_ontology_term_id must not be "na" (use HANCESTRO, "unknown", or "multiethnic")'
          }
        end
        rule_checks << {
          field: 'cross-field.CF-1b-ethnicity-human',
          status: failed ? 'failed' : 'passed',
          message: failed ? 'Human dataset must not use ethnicity "na"' : 'Human dataset: ethnicity is set (not "na")'
        }
      else
        failed = violated_fields.include?(ethnicity_path) || (ethnicity.present? && ethnicity != 'na')
        rule_checks << {
          field: 'cross-field.CF-1a-ethnicity-non-human',
          status: failed ? 'failed' : 'passed',
          message: failed ? 'Non-human dataset: self_reported_ethnicity_ontology_term_id must be "na"' : 'Non-human dataset: ethnicity is "na"'
        }
        rule_checks << {
          field: 'cross-field.CF-1b-ethnicity-human',
          status: 'skipped',
          message: 'Not applicable (organism is not Homo sapiens)'
        }
      end
    end

    def add_rule_check(out, id, violated_blob, token, message)
      failed = violated_blob.include?(token)
      out << {
        field: "cross-field.#{id}",
        status: failed ? 'failed' : 'passed',
        message: message
      }
    end

    def cf11_label_id_checks(prefix)
      pairs = [
        ['cell_type_ontology_term_id', 'cell_type'],
        ['development_stage_ontology_term_id', 'development_stage'],
        ['sex_ontology_term_id', 'sex']
      ]
      errors = []
      checks = []
      pairs.each do |id_field, label_field|
        id_val = first(@field_values["#{prefix}#{id_field}"])
        label_val = first(@field_values["#{prefix}#{label_field}"])
        specials = %w[na unknown]
        next unless specials.include?(id_val)
        ok = label_val == id_val
        errors << { field: "cross-field.CF-11-#{id_field}", message: "Label must match special ontology id value -- expected #{id_val}, got #{label_val}" } unless ok
        checks << {
          field: "cross-field.CF-11-#{id_field}",
          status: ok ? 'passed' : 'failed',
          message: ok ? 'Label must match special ontology id value -- Special label/id pairs OK' : "Label must match special ontology id value -- expected #{id_val}, got #{label_val}"
        }
      end
      { checks: checks, errors: errors }
    end
  end
end
