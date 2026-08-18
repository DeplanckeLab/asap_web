# frozen_string_literal: true

module Scfair
  class CrossFieldConstraintEvaluator
    include ScfairSchemaRules

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
      @validation = Rules.cross_field_validation
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
        format: @format,
        organism_tax_id: organism,
        assay_term_id: assay,
        tissue_type: tissue_type,
        suspension_type: suspension,
        ethnicity_term_id: ethnicity,
        sex_term_id: sex,
        dev_stage_term_id: dev_stage,
        donor_id_val: donor,
        tissue_term_id: tissue,
        cell_type_term_id: first(@field_values["#{prefix}cell_type_ontology_term_id"])
      )

      errors = []
      warnings = []
      rule_checks = []
      Array(violations).each do |v|
        rule = Rules.cross_field_rule_by_key(v[:rule_key])
        field = rule ? rule[:field] : "cross-field.#{v[:field]}"
        item = { field: field, message: v[:message] }
        v[:severity] == :error ? errors << item : warnings << item
      end

      violated_keys = Array(violations).map { |v| v[:rule_key].to_s }
      cf1 = Rules.cross_field_rule_by_key('CF-1')
      add_rule_check(
        rule_checks,
        cf1[:id],
        violated_keys.include?('CF-1'),
        Rules.cross_field_rule_message_for_key('CF-1', :pass)
      )
      add_cell_line_checks(rule_checks, tissue_type: tissue_type, violated_keys: violated_keys)

      donor_bad = tissue_type != 'cell line' && donor == 'na'
      rule_checks << {
        field: Rules.cross_field_rule_field('CF-3'),
        status: donor_bad ? 'failed' : 'passed',
        message: Rules.cross_field_rule_message_for_key('CF-3', donor_bad ? :fail : :pass)
      }

      cf4 = Rules.cross_field_rule_by_key('CF-4')
      organoid_bad = violated_keys.include?('CF-4')
      rule_checks << {
        field: Rules.cross_field_rule_field('CF-4'),
        status: tissue_type == 'organoid' ? (organoid_bad ? 'failed' : 'passed') : 'skipped',
        message: tissue_type == 'organoid' ? Rules.cross_field_rule_message_for_key('CF-4', organoid_bad ? :fail : :pass) : Rules.cross_field_not_applicable_message
      }

      assays = SpatialAssayHelper.assay_terms(@field_values, @format)
      spatial_assays = assays.select { |term| SpatialAssayHelper.spatial_assay?(term, resolver: @resolver) }
      mixed_spatial = spatial_assays.any? && assays.size > 1
      rule_checks << {
        field: Rules.cross_field_rule_field('CF-5'),
        status: mixed_spatial ? 'failed' : (spatial_assays.any? ? 'passed' : 'skipped'),
        message: spatial_assays.any? ? Rules.cross_field_rule_message_for_key('CF-5', mixed_spatial ? :fail : :pass) : Rules.cross_field_not_applicable_message
      }

      is_primary = first(@field_values["#{prefix}is_primary_data"])
      is_single_present = SpatialAssayHelper.present_values?(
        @field_values[SpatialAssayHelper.spatial_is_single_key(@format)]
      )
      is_single_false = is_single_present && !SpatialAssayHelper.spatial_is_single?(@field_values, @format)
      cf6_bad = is_single_false && is_primary == 'true'
      rule_checks << {
        field: Rules.cross_field_rule_field('CF-6'),
        status: is_single_present ? (cf6_bad ? 'failed' : 'passed') : 'skipped',
        message: is_single_present ? Rules.cross_field_rule_message_for_key('CF-6', cf6_bad ? :fail : :pass) : Rules.cross_field_not_applicable_message
      }

      cf7_bad = violated_keys.include?('CF-7')
      rule_checks << {
        field: Rules.cross_field_rule_field('CF-7'),
        status: tissue_type == 'cell line' ? (cf7_bad ? 'failed' : 'passed') : 'skipped',
        message: tissue_type == 'cell line' ? Rules.cross_field_rule_message_for_key('CF-7', cf7_bad ? :fail : :pass) : Rules.cross_field_not_applicable_message
      }

      rule_checks << cf8_visium_in_tissue_check(prefix, assays)
      rule_checks << cf9_spatial_metadata_presence_check

      { errors: errors, warnings: warnings, valid_checks: rule_checks }
    end

    private

    def first(v)
      Array(v).first.to_s
    end

    def add_cell_line_checks(rule_checks, tissue_type:, violated_keys:)
      cell_line = tissue_type == 'cell line'

      Rules.cross_field_cell_line_checks.each do |rule|
        field = Rules.cross_field_rule_field(rule[:key])

        unless cell_line
          rule_checks << {
            field: field,
            status: 'skipped',
            message: Rules.cross_field_skip_not_cell_line_message(detail: rule[:skip_detail])
          }
          next
        end

        failed = violated_keys.include?(rule[:key].to_s)
        rule_checks << {
          field: field,
          status: failed ? 'failed' : 'passed',
          message: failed ? rule[:fail].to_s : rule[:pass].to_s
        }
      end
    end

    def add_rule_check(out, id, failed, message)
      out << {
        field: "cross-field.#{id}",
        status: failed ? 'failed' : 'passed',
        message: message
      }
    end

    def cf9_spatial_metadata_presence_check
      spatial_assay = SpatialAssayHelper.any_spatial_assay?(@field_values, @format, resolver: @resolver)
      metadata_present = SpatialAssayHelper.spatial_metadata_present?(@field_values, @format)
      spatial_root = @format == 'h5ad' ? 'uns/spatial' : '/attrs/spatial'
      field = Rules.cross_field_rule_field(Rules::CF9_RULE_KEY)

      unless spatial_assay || metadata_present
        return { field: field, status: 'skipped', message: Rules.cross_field_not_applicable_message }
      end

      if metadata_present && !spatial_assay
        return {
          field: field,
          status: 'failed',
          message: Rules.cross_field_cf9_message('fail_metadata_without_spatial_assay', spatial_root: spatial_root)
        }
      end

      if spatial_assay && !metadata_present
        return {
          field: field,
          status: 'failed',
          message: Rules.cross_field_cf9_message('fail_missing_metadata', spatial_root: spatial_root)
        }
      end

      {
        field: field,
        status: 'passed',
        message: Rules.cross_field_cf9_message('pass')
      }
    end

    def cf8_visium_in_tissue_check(prefix, assays)
      field = Rules.cross_field_rule_field(Rules::CF8_RULE_KEY)
      visium = assays.any? { |term| SpatialAssayHelper.visium_assay?(term, resolver: @resolver) }
      unless visium
        return {
          field: field,
          status: 'skipped',
          message: Rules.cross_field_cf8_message('skipped_not_visium')
        }
      end

      unless SpatialAssayHelper.spatial_is_single?(@field_values, @format)
        return {
          field: field,
          status: 'skipped',
          message: Rules.cross_field_cf8_message('skipped_not_single')
        }
      end

      in_tissue_vals = Array(@field_values["#{prefix}in_tissue"]).map(&:to_s).uniq
      cell_type_vals = Array(@field_values["#{prefix}cell_type_ontology_term_id"]).map(&:to_s).uniq

      if in_tissue_vals.blank?
        return {
          field: field,
          status: 'skipped',
          message: Rules.cross_field_cf8_message('skipped_no_in_tissue')
        }
      end

      unless in_tissue_vals.include?('0')
        return {
          field: field,
          status: 'passed',
          message: Rules.cross_field_cf8_message('pass')
        }
      end

      if in_tissue_vals != ['0']
        return {
          field: field,
          status: 'skipped',
          message: Rules.cross_field_cf8_message('skipped_mixed_in_tissue')
        }
      end

      cf8_bad = cell_type_vals.any? { |value| value != 'unknown' }
      {
        field: field,
        status: cf8_bad ? 'failed' : 'passed',
        message: Rules.cross_field_cf8_message(cf8_bad ? 'fail' : 'pass')
      }
    end
  end
end
