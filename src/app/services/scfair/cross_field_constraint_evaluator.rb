# frozen_string_literal: true

module Scfair
  class CrossFieldConstraintEvaluator
    include ScfairSchemaRules

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
    end

    def call
      @resolver = OntologyLineageResolver.new
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
      add_rule_check(rule_checks, 'CF-1-assay-suspension', violated_fields, '/suspension_type',
                     'Assay/suspension_type consistency')
      add_cell_line_checks(rule_checks, tissue_type: tissue_type, violated_fields: violated_fields)

      donor_bad = tissue_type != 'cell line' && donor == 'na'
      rule_checks << {
        field: 'cross-field.CF-3-donor-id',
        status: donor_bad ? 'failed' : 'passed',
        message: donor_bad ? 'donor_id must not be "na" unless tissue_type is "cell line"' : 'donor_id consistency OK'
      }

      organoid_bad = tissue_type == 'organoid' && tissue == 'UBERON:0000922'
      rule_checks << {
        field: 'cross-field.CF-4-organoid-tissue',
        status: organoid_bad ? 'failed' : (tissue_type == 'organoid' ? 'passed' : 'skipped'),
        message: tissue_type == 'organoid' ? (organoid_bad ? 'Organoid tissue must not be embryo (UBERON:0000922)' : 'Organoid tissue constraints OK') : 'Not applicable'
      }

      assays = SpatialAssayHelper.assay_terms(@field_values, @format)
      spatial_assays = assays.select { |term| SpatialAssayHelper.spatial_assay?(term, resolver: @resolver) }
      mixed_spatial = spatial_assays.any? && assays.size > 1
      rule_checks << {
        field: 'cross-field.CF-5-spatial-assay-uniformity',
        status: mixed_spatial ? 'failed' : (spatial_assays.any? ? 'passed' : 'skipped'),
        message: spatial_assays.any? ? (mixed_spatial ? 'Spatial assay datasets must use a single assay value' : 'Spatial assay uniformity OK') : 'Not applicable'
      }

      is_primary = first(@field_values["#{prefix}is_primary_data"])
      is_single_present = SpatialAssayHelper.present_values?(
        @field_values[SpatialAssayHelper.spatial_is_single_key(@format)]
      )
      is_single_false = is_single_present && !SpatialAssayHelper.spatial_is_single?(@field_values, @format)
      cf6_bad = is_single_false && is_primary == 'true'
      rule_checks << {
        field: 'cross-field.CF-6-spatial-primary-data',
        status: is_single_present ? (cf6_bad ? 'failed' : 'passed') : 'skipped',
        message: is_single_present ? (cf6_bad ? 'is_primary_data must be false when spatial.is_single is false' : 'Spatial primary-data constraint OK') : 'Not applicable'
      }

      cell_type = first(@field_values["#{prefix}cell_type_ontology_term_id"])
      cf7_bad = tissue_type == 'cell line' && !%w[na unknown].include?(cell_type) && cell_type.present?
      rule_checks << {
        field: 'cross-field.CF-7-cell-line-cell-type',
        status: tissue_type == 'cell line' ? (cf7_bad ? 'failed' : 'passed') : 'skipped',
        message: tissue_type == 'cell line' ? (cf7_bad ? 'cell_type_ontology_term_id should be na/unknown for cell lines' : 'Cell line cell_type constraint OK') : 'Not applicable'
      }

      cf8 = cf8_label_id_checks(prefix)
      rule_checks.concat(cf8[:checks])
      errors.concat(cf8[:errors])

      rule_checks << cf9_visium_in_tissue_check(prefix, assays)
      rule_checks << cf10_spatial_metadata_presence_check

      { errors: errors, warnings: warnings, valid_checks: rule_checks }
    end

    private

    def first(v)
      Array(v).first.to_s
    end

    CELL_LINE_RULES = [
      {
        id: 'CF-2a-cell-line-ethnicity',
        token: 'self_reported_ethnicity_ontology_term_id',
        skip_detail: 'ethnicity must be "na" (cell lines have no donor ancestry)',
        pass_detail: 'self_reported_ethnicity_ontology_term_id is "na"',
        fail_detail: 'self_reported_ethnicity_ontology_term_id must be "na" for cell lines'
      },
      {
        id: 'CF-2b-cell-line-sex',
        token: 'sex_ontology_term_id',
        skip_detail: 'sex must be "na" (not applicable to a cultured line)',
        pass_detail: 'sex_ontology_term_id is "na"',
        fail_detail: 'sex_ontology_term_id must be "na" for cell lines'
      },
      {
        id: 'CF-2c-cell-line-development-stage',
        token: 'development_stage_ontology_term_id',
        skip_detail: 'development_stage must be "unknown" (no in vivo stage for a line)',
        pass_detail: 'development_stage_ontology_term_id is "unknown"',
        fail_detail: 'development_stage_ontology_term_id must be "unknown" for cell lines'
      },
      {
        id: 'CF-2d-cell-line-donor-id',
        token: 'donor_id',
        skip_detail: 'donor_id must be "na" (line identity is not a donor ID)',
        pass_detail: 'donor_id is "na"',
        fail_detail: 'donor_id must be "na" for cell lines'
      },
      {
        id: 'CF-2e-cell-line-suspension',
        token: 'suspension_type',
        skip_detail: 'suspension_type must be "na" (not used for cell line profiles)',
        pass_detail: 'suspension_type is "na"',
        fail_detail: 'suspension_type must be "na" for cell lines'
      },
      {
        id: 'CF-2f-cell-line-tissue-id',
        token: 'tissue_ontology_term_id',
        skip_detail: 'tissue_ontology_term_id should be a Cellosaurus ID (CVCL_*) naming the line',
        pass_detail: 'tissue_ontology_term_id is a Cellosaurus term (CVCL_*)',
        fail_detail: 'tissue_ontology_term_id should be a Cellosaurus term (CVCL_*) for cell lines'
      }
    ].freeze

    def add_cell_line_checks(rule_checks, tissue_type:, violated_fields:)
      cell_line = tissue_type == 'cell line'

      CELL_LINE_RULES.each do |rule|
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

    def add_rule_check(out, id, violated_blob, token, message)
      failed = violated_blob.include?(token)
      out << {
        field: "cross-field.#{id}",
        status: failed ? 'failed' : 'passed',
        message: message
      }
    end

    def cf10_spatial_metadata_presence_check
      spatial_assay = SpatialAssayHelper.any_spatial_assay?(@field_values, @format, resolver: @resolver)
      metadata_present = SpatialAssayHelper.spatial_metadata_present?(@field_values, @format)
      spatial_root = @format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
      field = 'cross-field.CF-10-spatial-metadata-presence'

      unless spatial_assay || metadata_present
        return { field: field, status: 'skipped', message: 'Not applicable' }
      end

      if metadata_present && !spatial_assay
        return {
          field: field,
          status: 'failed',
          message: "#{spatial_root} must not be present unless assay is Visium or Slide-seqV2"
        }
      end

      if spatial_assay && !metadata_present
        return {
          field: field,
          status: 'failed',
          message: "Missing #{spatial_root} metadata (required for spatial assays)"
        }
      end

      {
        field: field,
        status: 'passed',
        message: 'Spatial metadata presence consistent with assay'
      }
    end

    def cf9_visium_in_tissue_check(prefix, assays)
      visium = assays.any? { |term| SpatialAssayHelper.visium_assay?(term, resolver: @resolver) }
      unless visium
        return {
          field: 'cross-field.CF-9-visium-in-tissue',
          status: 'skipped',
          message: 'Not applicable'
        }
      end

      unless SpatialAssayHelper.spatial_is_single?(@field_values, @format)
        return {
          field: 'cross-field.CF-9-visium-in-tissue',
          status: 'skipped',
          message: 'Not applicable (requires spatial.is_single=true)'
        }
      end

      in_tissue_vals = Array(@field_values["#{prefix}in_tissue"]).map(&:to_s).uniq
      cell_type_vals = Array(@field_values["#{prefix}cell_type_ontology_term_id"]).map(&:to_s).uniq

      if in_tissue_vals.blank?
        return {
          field: 'cross-field.CF-9-visium-in-tissue',
          status: 'skipped',
          message: 'Not applicable (in_tissue not present)'
        }
      end

      unless in_tissue_vals.include?('0')
        return {
          field: 'cross-field.CF-9-visium-in-tissue',
          status: 'passed',
          message: 'Visium in_tissue constraint OK'
        }
      end

      if in_tissue_vals != ['0']
        return {
          field: 'cross-field.CF-9-visium-in-tissue',
          status: 'skipped',
          message: 'Per-spot in_tissue/cell_type pairing not available in metadata summary'
        }
      end

      cf9_bad = cell_type_vals.any? { |value| value != 'unknown' }
      {
        field: 'cross-field.CF-9-visium-in-tissue',
        status: cf9_bad ? 'failed' : 'passed',
        message: cf9_bad ? 'Visium spots with in_tissue=0 must use cell_type_ontology_term_id=unknown' : 'Visium in_tissue constraint OK'
      }
    end

    def cf8_label_id_checks(prefix)
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
        unless ok
          errors << {
            field: "cross-field.CF-8-#{id_field}",
            message: "Label must match special ontology id value -- expected #{id_val}, got #{label_val}"
          }
        end
        checks << {
          field: "cross-field.CF-8-#{id_field}",
          status: ok ? 'passed' : 'failed',
          message: ok ? 'Label must match special ontology id value -- Special label/id pairs OK' : "Label must match special ontology id value -- expected #{id_val}, got #{label_val}"
        }
      end
      { checks: checks, errors: errors }
    end
  end
end
