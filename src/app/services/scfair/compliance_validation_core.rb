# frozen_string_literal: true

module Scfair
  # Shared extract-based compliance validation used by file-check and project compliance.
  class ComplianceValidationCore
    include ComplianceReportEnrichment

    def self.call(file_path:, schema_id:, logger: Rails.logger, progress_cb: nil, project_compliance: false)
      new(
        file_path: file_path,
        schema_id: schema_id,
        logger: logger,
        progress_cb: progress_cb,
        project_compliance: project_compliance
      ).call
    end

    def initialize(file_path:, schema_id:, logger: Rails.logger, progress_cb: nil, project_compliance: false)
      @file_path = file_path
      @schema_id = schema_id
      @logger = logger
      @progress_cb = progress_cb
      @project_compliance = project_compliance
    end

    def validate
      call
    end

    def call
      Rules.with_bundle(@schema_id) do
        call_with_rules_bundle
      end
    end

    def call_with_rules_bundle
      schema = CheckCatalog.schema!(@schema_id)
      format = detect_format(@file_path)
      raise ArgumentError, "Unsupported file extension for #{@file_path}" unless %w[loom h5ad].include?(format)

      tick('starting', 'Starting file validation', 5, format: format)
      tick('catalog', "Preparing checks for #{format.upcase}", 10, format: format)

      tick('extract', 'Extracting metadata from file', 15, format: format)
      extract = ScfairMinimalExtractService.new(file_path: @file_path, logger: @logger).extract

      base_result = ExtractComplianceChecker.new(
        extract: extract,
        format: format,
        progress_cb: method(:relay_extract_progress)
      ).call

      field_values = base_result.field_values || {}

      tick('ontology', 'Resolving ontology terms in ASAP database', 72, format: format)
      ontology = StandaloneOntologyComplianceChecker.new(
        field_values: field_values,
        format: format,
        organism_term_id: first_organism(field_values, format)
      ).run
      cross_field = CrossFieldConstraintEvaluator.new(field_values: field_values, format: format).call
      obs_label_pairs = ObsLabelPairConstraintEvaluator.new(field_values: field_values, format: format).call
      organism_specific = OrganismSpecificConstraintEvaluator.new(field_values: field_values, format: format).call
      extensions = SchemaExtensionValidator.new(
        field_values: field_values,
        format: format,
        project_compliance: @project_compliance
      ).call
      metadata_general = MetadataGeneralValidator.new(field_values: field_values, format: format).call
      schema_version_check = schema_version_evaluation(field_values, format)
      schema_reference_check = schema_reference_evaluation(field_values, format)
      uns_ensembl_check = uns_ensembl_evaluation(field_values, format)
      experimental_condition_check = experimental_condition_evaluation(field_values, format)
      var_metadata_check = var_metadata_evaluation(field_values, format)
      var_index_check = var_index_evaluation(field_values, format)
      var_cross_field_check = var_cross_field_evaluation(field_values, format)
      uns_ensembl_cross_field_check = uns_ensembl_cross_field_evaluation(field_values, format)
      organism_label_check = organism_label_pair_evaluation(field_values, format)

      errors = (
        base_result.errors +
        ontology[:errors] +
        cross_field[:errors] +
        obs_label_pairs[:errors] +
        organism_specific[:errors] +
        extensions[:errors] +
        metadata_general[:errors] +
        schema_version_check[:errors] +
        uns_ensembl_check[:errors] +
        experimental_condition_check[:errors] +
        var_metadata_check[:errors] +
        var_index_check[:errors] +
        var_cross_field_check[:errors] +
        uns_ensembl_cross_field_check[:errors] +
        organism_label_check[:errors]
      ).uniq
      warnings = (
        base_result.warnings +
        ontology[:warnings] +
        cross_field[:warnings] +
        organism_specific[:warnings] +
        extensions[:warnings] +
        schema_version_check[:warnings] +
        schema_reference_check[:warnings]
      ).uniq
      valid_checks = (
        base_result.valid_checks +
        ontology[:valid_checks] +
        cross_field[:valid_checks] +
        obs_label_pairs[:valid_checks] +
        organism_specific[:valid_checks] +
        extensions[:valid_checks] +
        metadata_general[:valid_checks] +
        schema_version_check[:valid_checks] +
        schema_reference_check[:valid_checks] +
        uns_ensembl_check[:valid_checks] +
        experimental_condition_check[:valid_checks] +
        var_metadata_check[:valid_checks] +
        var_index_check[:valid_checks] +
        var_cross_field_check[:valid_checks] +
        uns_ensembl_cross_field_check[:valid_checks] +
        organism_label_check[:valid_checks]
      )
      valid_checks = reconcile_schema_version_checks(valid_checks, errors, warnings, format)

      errors, valid_checks, warnings = reconcile_rollup_metadata_checks(errors, valid_checks, warnings, format)
      errors, warnings = promote_valid_check_issues(valid_checks, errors, warnings)
      errors, warnings, valid_checks = suppress_rollup_summary_issues(errors, warnings, valid_checks)
      valid_checks = mirror_metadata_field_checks(valid_checks, errors, warnings, format)
      check_groups = ComplianceReportGrouper.call(
        checks_catalog: CheckCatalog.checks_for(format),
        valid_checks: valid_checks,
        errors: errors,
        warnings: warnings,
        format: format
      )

      tick('finalizing', 'Finalizing compliance report', 95, format: format)

      enrich_with_details(
        valid: errors.empty?,
        format: format,
        schema_id: schema[:id],
        schema_version: schema[:schema_version],
        source_url: schema[:source_url],
        validated_at: Time.current.iso8601,
        field_values: base_result.field_values || {},
        errors: errors,
        warnings: warnings,
        info: base_result.info,
        valid_checks: valid_checks,
        check_groups: check_groups,
        checks_catalog: CheckCatalog.checks_for(format),
        summary: {
          errors_count: errors.count,
          warnings_count: warnings.count,
          info_count: base_result.info.count,
          valid_checks_count: valid_checks.count
        }
      )
    end

    private

    def detect_format(path)
      ext = File.extname(path).downcase
      return 'loom' if ext == '.loom'
      return 'h5ad' if ext == '.h5ad'

      nil
    end

    def tick(stage, message, progress, format:, current: nil, total: nil)
      return unless @progress_cb

      @progress_cb.call(
        stage: stage,
        message: message,
        progress: progress,
        format: format,
        current: current,
        total: total
      )
    end

    def relay_extract_progress(evt)
      tick(
        evt[:stage] || 'checks',
        evt[:message] || 'Running compliance checks',
        evt[:progress] || 20,
        format: evt[:format] || detect_format(@file_path)
      )
    end

    def first_organism(field_values, format)
      file_organism(field_values, format)[:term_id]
    end

    def file_organism(field_values, format)
      return { term_id: nil, label: nil, present: false } if field_values.blank?

      term_key = Rules.field_path(format, :uns, 'organism_ontology_term_id')
      label_key = format == 'h5ad' ? 'uns/organism' : '/attrs/organism'
      term_id = Array(field_values[term_key]).first.to_s.strip.presence
      label = Array(field_values[label_key]).first.to_s.strip.presence

      {
        term_id: term_id,
        label: label,
        present: term_id.present? || label.present?
      }
    end

    def schema_version_evaluation(field_values, format)
      file_version = Array(field_values[Rules.field_path(format, :uns, 'schema_version')]).first
      SchemaVersionEvaluator.call(
        file_version: file_version,
        reference_version: Rules.schema_version,
        format: format
      )
    end

    def schema_reference_evaluation(field_values, format)
      field = Rules.field_path(format, :uns, 'schema_reference')
      file_reference = Array(field_values[field] || field_values[field.to_sym]).first
      SchemaReferenceEvaluator.call(
        file_reference: file_reference,
        reference_url: Rules.schema_hash[:source_url],
        format: format
      )
    end

    def uns_ensembl_evaluation(field_values, format)
      UnsEnsemblValidator.new(field_values: field_values, format: format).call
    end

    def experimental_condition_evaluation(field_values, format)
      ExperimentalConditionValidator.new(field_values: field_values, format: format).call
    end

    def var_metadata_evaluation(field_values, format)
      VarMetadataValidator.new(field_values: field_values, format: format).call
    end

    def var_index_evaluation(field_values, format)
      VarIndexValidator.new(field_values: field_values, format: format).call
    end

    def organism_label_pair_evaluation(field_values, format)
      OrganismLabelPairValidator.new(field_values: field_values, format: format).call
    end

    def var_cross_field_evaluation(field_values, format)
      VarCrossFieldValidator.new(field_values: field_values, format: format).call
    end

    def uns_ensembl_cross_field_evaluation(field_values, format)
      UnsEnsemblCrossFieldValidator.new(field_values: field_values, format: format).call
    end

    def reconcile_rollup_metadata_checks(errors, valid_checks, warnings, format)
      errors = Array(errors).dup
      valid_checks = Array(valid_checks).dup
      warnings = Array(warnings).dup
      failed_rollups = failed_rollup_check_fields(errors, valid_checks)
      rollup_index = rollup_metadata_path_index(format)

      errors.reject! do |entry|
        rollup_field = rollup_index[entry_field(entry)]
        rollup_field.present? && failed_rollups.include?(rollup_field)
      end

      valid_checks.reject! do |entry|
        rollup_field = rollup_index[entry_field(entry)]
        rollup_field.present? && failed_rollups.include?(rollup_field)
      end

      warnings.reject! do |entry|
        rollup_field = rollup_index[entry_field(entry)]
        rollup_field.present? && failed_rollups.include?(rollup_field)
      end

      [errors, valid_checks, warnings]
    end

    def rollup_metadata_path_index(format)
      index = {}
      rules = Rules.experimental_condition_rules
      {
        rules[:id_field] => Rules.field_path(format, :obs, rules[:label_field]),
        rules[:label_field] => 'obs.experimental_condition.label',
        rules[:perturbation_types_field] => 'obs.experimental_condition.perturbation_types'
      }.each do |obs_name, check_id|
        index[Rules.field_path(format, :obs, obs_name)] = check_id
      end

      index
    end

    def failed_rollup_check_fields(errors, valid_checks)
      fields = Set.new
      errors.each { |entry| fields << entry_field(entry) }
      valid_checks.each do |entry|
        next unless entry_status(entry) == 'failed'

        fields << entry_field(entry)
      end
      fields
    end

    def entry_field(entry)
      (entry[:field] || entry['field']).to_s
    end

    def entry_status(entry)
      (entry[:status] || entry['status']).to_s.strip.downcase
    end

    def reconcile_schema_version_checks(valid_checks, errors, warnings, format)
      field = Rules.field_path(format, :uns, 'schema_version')
      has_version_issue = errors.any? { |entry| entry[:field] == field || entry['field'] == field } ||
                          warnings.any? { |entry| entry[:field] == field || entry['field'] == field }

      cleaned = valid_checks.reject do |check|
        check_field = check[:field] || check['field']
        check_message = (check[:message] || check['message']).to_s
        next false unless check_field == field

        has_version_issue && check_message.match?(/Found .* metadata/i)
      end

      cleaned.uniq
    end

    METADATA_FIELD_CHECK = /\A(uns\/|obs\/|var\/|\/attrs\/|\/col_attrs\/|\/row_attrs\/)/

    def suppress_rollup_summary_issues(errors, warnings, valid_checks)
      errors = Array(errors).dup
      warnings = Array(warnings).dup
      valid_checks = Array(valid_checks).dup
      other_issues = errors + warnings + valid_checks.select { |entry| entry_status(entry) == 'failed' }

      errors.reject! do |entry|
        Rules.redundant_rollup_summary?(entry_field(entry), entry[:message] || entry['message'], other_issues)
      end

      warnings.reject! do |entry|
        Rules.redundant_rollup_summary?(entry_field(entry), entry[:message] || entry['message'], other_issues)
      end

      valid_checks.reject! do |entry|
        next false unless entry_status(entry) == 'failed'

        Rules.redundant_rollup_summary?(entry_field(entry), entry[:message] || entry['message'], other_issues)
      end

      [errors, warnings, valid_checks]
    end

    def promote_valid_check_issues(valid_checks, errors, warnings)
      promoted_errors = Array(errors).dup
      promoted_warnings = Array(warnings).dup
      error_fields = promoted_errors.map { |entry| (entry[:field] || entry['field']).to_s }.to_set
      warning_fields = promoted_warnings.map { |entry| (entry[:field] || entry['field']).to_s }.to_set

      Array(valid_checks).each do |check|
        field = (check[:field] || check['field']).to_s
        message = (check[:message] || check['message']).to_s
        status = (check[:status] || check['status']).to_s.strip.downcase
        next if field.blank? || message.blank?

        case status
        when 'failed'
          next if error_fields.include?(field)

          promoted_errors << { field: field, message: message }
          error_fields << field
        when 'warning'
          next if warning_fields.include?(field)

          promoted_warnings << { field: field, message: message }
          warning_fields << field
        end
      end

      [promoted_errors, promoted_warnings]
    end

    def mirror_metadata_field_checks(valid_checks, errors, warnings, format)
      checks = valid_checks.dup
      fields_with_checks = checks.map { |check| check[:field] || check['field'] }.compact.to_set
      rollup_index = rollup_metadata_path_index(format)

      errors.each do |entry|
        field = entry_field(entry)
        next unless field.match?(METADATA_FIELD_CHECK)
        rollup_field = rollup_index[field]
        next if rollup_field.present? && fields_with_checks.include?(rollup_field)
        next if fields_with_checks.include?(field)

        checks << {
          field: field,
          status: 'failed',
          message: entry[:message] || entry['message']
        }
        fields_with_checks << field
      end

      warnings.each do |entry|
        field = entry_field(entry)
        next unless field.match?(METADATA_FIELD_CHECK)
        rollup_field = rollup_index[field]
        next if rollup_field.present? && fields_with_checks.include?(rollup_field)
        next if fields_with_checks.include?(field)

        checks << {
          field: field,
          status: 'warning',
          message: entry[:message] || entry['message']
        }
        fields_with_checks << field
      end

      checks
    end
  end
end
