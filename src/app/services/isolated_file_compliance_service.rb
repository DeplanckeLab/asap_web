# frozen_string_literal: true

class IsolatedFileComplianceService
  include CxgSchemaRules

  def initialize(file_path:, schema_id:, logger: Rails.logger, &progress_cb)
    @file_path = file_path
    @schema_id = schema_id
    @logger = logger
    @progress_cb = progress_cb
  end

  def validate
    schema = Scfair::CheckCatalog.schema!(@schema_id)
    format = detect_format(@file_path)
    raise ArgumentError, "Unsupported file extension for #{@file_path}" unless %w[loom h5ad].include?(format)

    tick('starting', 'Starting file validation', 5, format: format)
    tick('catalog', "Preparing #{Scfair::CheckCatalog.checks_for(format).size} checks for #{format.upcase}", 10, format: format)

    base_result = if format == 'loom'
                    tick('loom', 'Running Loom validation checks', 30, format: format)
                    StandaloneLoomValidatorService.new(@file_path, logger: @logger).validate
                  else
                    tick('h5ad', 'Starting H5AD validation checks', 15, format: format)
                    StandaloneH5adValidatorService.new(
                      @file_path,
                      logger: @logger,
                      progress_cb: method(:relay_h5ad_progress)
                    ).validate
                  end

    tick('ontology', 'Resolving ontology terms in ASAP database', 72, format: format)
    organism_path = format == 'loom' ? '/attrs/organism_ontology_term_id' : 'uns/organism_ontology_term_id'
    organism_term_id = base_result.field_values[organism_path]&.first

    ontology = StandaloneOntologyComplianceChecker.new(
      field_values: base_result.field_values,
      format: format,
      organism_term_id: organism_term_id
    ).run

    cross_field = evaluate_cross_field_constraints(base_result.field_values, format)

    errors = (base_result.errors + ontology[:errors] + cross_field[:errors]).uniq
    warnings = (base_result.warnings + ontology[:warnings] + cross_field[:warnings]).uniq
    valid_checks = (base_result.valid_checks + ontology[:valid_checks] + cross_field[:valid_checks]).uniq

    tick('finalizing', 'Finalizing compliance report', 95, format: format)

    {
      valid: errors.empty?,
      format: format,
      schema_id: schema[:id],
      schema_version: schema[:schema_version],
      source_url: schema[:source_url],
      validated_at: Time.current.iso8601,
      errors: errors,
      warnings: warnings,
      info: base_result.info,
      valid_checks: valid_checks,
      checks_catalog: Scfair::CheckCatalog.checks_for(format),
      summary: {
        errors_count: errors.count,
        warnings_count: warnings.count,
        info_count: base_result.info.count,
        valid_checks_count: valid_checks.count
      }
    }
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

  def relay_h5ad_progress(evt)
    tick(
      evt[:stage] || 'h5ad',
      evt[:message] || 'Running H5AD checks',
      evt[:progress] || 15,
      format: 'h5ad',
      current: evt[:current],
      total: evt[:total]
    )
  end

  def evaluate_cross_field_constraints(field_values, format)
    values = field_values || {}
    prefix = format == 'h5ad' ? 'obs/' : '/col_attrs/'
    organism_key = format == 'h5ad' ? 'uns/organism_ontology_term_id' : '/attrs/organism_ontology_term_id'

    organism = first_value(values[organism_key])
    assay_values = values_for(values, "#{prefix}assay_ontology_term_id")
    tissue_type = first_value(values["#{prefix}tissue_type"])
    suspension_values = values_for(values, "#{prefix}suspension_type")
    ethnicity_values = values_for(values, "#{prefix}self_reported_ethnicity_ontology_term_id")
    sex_values = values_for(values, "#{prefix}sex_ontology_term_id")
    dev_stage_values = values_for(values, "#{prefix}development_stage_ontology_term_id")
    donor_values = values_for(values, "#{prefix}donor_id")
    tissue_values = values_for(values, "#{prefix}tissue_ontology_term_id")

    errors = []
    warnings = []
    before_count = errors.size + warnings.size

    assay_id = assay_values.first
    suspension_values.each do |susp|
      collect_violations!(
        check_cross_field_constraints(
          organism_tax_id: organism,
          assay_term_id: assay_id,
          tissue_type: tissue_type,
          suspension_type: susp
        ),
        errors,
        warnings
      )
    end

    ethnicity_values.each do |eth|
      sex_values.each do |sx|
        dev_stage_values.each do |ds|
          donor_values.each do |dn|
            tissue_values.each do |ts|
              collect_violations!(
                check_cross_field_constraints(
                  organism_tax_id: organism,
                  tissue_type: tissue_type,
                  ethnicity_term_id: eth,
                  sex_term_id: sx,
                  dev_stage_term_id: ds,
                  donor_id_val: dn,
                  tissue_term_id: ts
                ),
                errors,
                warnings
              )
            end
          end
        end
      end
    end

    errors.uniq!
    warnings.uniq!
    valid_checks = []
    valid_checks << { field: 'cross-field', message: 'All cross-field schema constraints satisfied' } if (errors.size + warnings.size) == before_count
    { errors: errors, warnings: warnings, valid_checks: valid_checks }
  end

  def values_for(values, key)
    Array(values[key]).compact.map(&:to_s).reject(&:empty?).uniq
  end

  def first_value(values)
    values_for({ v: values }, :v).first
  end

  def collect_violations!(violations, errors, warnings)
    Array(violations).each do |violation|
      item = { field: violation[:field], message: violation[:message] }
      if violation[:severity] == :error
        errors << item
      else
        warnings << item
      end
    end
  end
end

