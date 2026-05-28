class IsolatedFileComplianceService
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
    tick('catalog', "Preparing checks for #{format.upcase}", 10, format: format)

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
    ontology = StandaloneOntologyComplianceChecker.new(
      field_values: base_result.field_values || {},
      format: format,
      organism_term_id: first_organism(base_result.field_values, format)
    ).run
    cross_field = Scfair::CrossFieldConstraintEvaluator.new(field_values: base_result.field_values || {}, format: format).call
    organism_specific = Scfair::OrganismSpecificConstraintEvaluator.new(field_values: base_result.field_values || {}, format: format).call
    extensions = Scfair::SchemaExtensionValidator.new(field_values: base_result.field_values || {}, format: format).call

    errors = (base_result.errors + ontology[:errors] + cross_field[:errors] + organism_specific[:errors] + extensions[:errors]).uniq
    warnings = (base_result.warnings + ontology[:warnings] + cross_field[:warnings] + organism_specific[:warnings] + extensions[:warnings]).uniq
    valid_checks = (base_result.valid_checks + ontology[:valid_checks] + cross_field[:valid_checks] + organism_specific[:valid_checks] + extensions[:valid_checks]).uniq

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

  def first_organism(field_values, format)
    return nil if field_values.blank?
    key = format == 'h5ad' ? 'uns/organism_ontology_term_id' : '/attrs/organism_ontology_term_id'
    Array(field_values[key]).first
  end
end

