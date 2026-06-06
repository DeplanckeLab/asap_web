class ScfairComplianceService
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
                    ScfairLoomFileValidatorService.new(@file_path, logger: @logger).validate
                  else
                    tick('h5ad', 'Starting H5AD validation checks', 15, format: format)
                    ScfairH5adValidatorService.new(
                      @file_path,
                      logger: @logger,
                      progress_cb: method(:relay_h5ad_progress)
                    ).validate
                  end

    if format == 'loom'
      errors = base_result.errors
      warnings = base_result.warnings
      cross_field = Scfair::CrossFieldConstraintEvaluator.new(
        field_values: base_result.field_values || {},
        format: format
      ).call
      valid_checks = reconcile_schema_version_checks(
        base_result.valid_checks + cross_field[:valid_checks],
        errors,
        warnings,
        format
      )
    else
      tick('ontology', 'Resolving ontology terms in ASAP database', 72, format: format)
      ontology = StandaloneOntologyComplianceChecker.new(
        field_values: base_result.field_values || {},
        format: format,
        organism_term_id: first_organism(base_result.field_values, format)
      ).run
      cross_field = Scfair::CrossFieldConstraintEvaluator.new(field_values: base_result.field_values || {}, format: format).call
      organism_specific = Scfair::OrganismSpecificConstraintEvaluator.new(field_values: base_result.field_values || {}, format: format).call
      extensions = Scfair::SchemaExtensionValidator.new(field_values: base_result.field_values || {}, format: format).call
      schema_version_check = schema_version_evaluation(base_result.field_values || {}, format)

      errors = (base_result.errors + ontology[:errors] + cross_field[:errors] + organism_specific[:errors] + extensions[:errors] + schema_version_check[:errors]).uniq
      warnings = (base_result.warnings + ontology[:warnings] + cross_field[:warnings] + organism_specific[:warnings] + extensions[:warnings] + schema_version_check[:warnings]).uniq
      valid_checks = (base_result.valid_checks + ontology[:valid_checks] + cross_field[:valid_checks] + organism_specific[:valid_checks] + extensions[:valid_checks] + schema_version_check[:valid_checks])
      valid_checks = reconcile_schema_version_checks(valid_checks, errors, warnings, format)
    end

    errors, warnings = promote_valid_check_issues(valid_checks, errors, warnings)
    valid_checks = mirror_metadata_field_checks(valid_checks, errors, warnings)
    check_groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: Scfair::CheckCatalog.checks_for(format),
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
      checks_catalog: Scfair::CheckCatalog.checks_for(format),
      summary: {
        errors_count: errors.count,
        warnings_count: warnings.count,
        info_count: base_result.info.count,
        valid_checks_count: valid_checks.count
      }
    )
  end

  private

  def enrich_with_details(result)
    format = result[:format]
    field_values = result[:field_values] || {}
    result[:errors] = enrich_items(result[:errors], format, field_values)
    result[:warnings] = enrich_items(result[:warnings], format, field_values)
    result[:check_groups] = Array(result[:check_groups]).map do |group|
      category_id = group[:id] || group['id']
      items = Array(group[:items] || group['items']).map do |item|
        item = Scfair::CheckDetailBuilder.enrich_item(item, format: format, category_id: category_id)
        attach_field_values(item, field_values, category_id)
      end
      group.merge(items: items)
    end
    result
  end

  PRESENCE_VALUE_CATEGORIES = %w[uns.required_presence obs.required_presence].freeze

  def enrich_items(items, format, field_values = {})
    Array(items).map do |item|
      enriched = Scfair::CheckDetailBuilder.enrich_item(item, format: format)
      attach_field_values(enriched, field_values, Scfair::ComplianceReportGrouper.category_for(
        field: enriched[:field] || enriched['field'],
        message: enriched[:message] || enriched['message'],
        format: format
      ))
    end
  end

  def attach_field_values(item, field_values, category_id)
    return item unless show_field_values?(item, category_id)

    field = (item[:field] || item['field']).to_s
    values = lookup_field_values(field_values, field)
    return item if values.blank?

    item.merge(values: values)
  end

  def show_field_values?(item, category_id)
    id = category_id.to_s
    return false unless PRESENCE_VALUE_CATEGORIES.include?(id) || dataset_metadata_loom_path?(item, id)

    status = (item[:status] || item['status']).to_s
    return false if status == 'failed'

    Scfair::CheckDetailBuilder.presence_check_message?(item[:message] || item['message'])
  end

  def dataset_metadata_loom_path?(item, category_id)
    return false unless category_id == 'loom.paths'

    field = (item[:field] || item['field']).to_s
    field.start_with?('/attrs/')
  end

  def lookup_field_values(field_values, field)
    raw = field_values[field] || field_values[field.to_sym]
    Array(raw).map(&:to_s).map(&:strip).reject(&:blank?).presence
  end

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
    file_organism(field_values, format)[:term_id]
  end

  def file_organism(field_values, format)
    return { term_id: nil, label: nil, present: false } if field_values.blank?

    term_key = Scfair::Rules.field_path(format, :uns, 'organism_ontology_term_id')
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
    file_version = Array(field_values[Scfair::Rules.field_path(format, :uns, 'schema_version')]).first
    Scfair::SchemaVersionEvaluator.call(
      file_version: file_version,
      reference_version: Scfair::Rules.schema_version,
      format: format
    )
  end

  def reconcile_schema_version_checks(valid_checks, errors, warnings, format)
    field = Scfair::Rules.field_path(format, :uns, 'schema_version')
    has_version_issue = errors.any? { |entry| entry[:field] == field || entry['field'] == field } ||
                        warnings.any? { |entry| entry[:field] == field || entry['field'] == field }

    cleaned = valid_checks.reject do |check|
      check_field = check[:field] || check['field']
      check_message = (check[:message] || check['message']).to_s
      next false unless check_field == field

      has_version_issue && check_message.match?(/Required field present|Found .* metadata/i)
    end

    cleaned.uniq
  end

  METADATA_FIELD_CHECK = /\A(uns\/|obs\/|\/attrs\/|\/col_attrs\/)/

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

  def mirror_metadata_field_checks(valid_checks, errors, warnings)
    checks = valid_checks.dup
    fields_with_checks = checks.map { |check| check[:field] || check['field'] }.compact.to_set

    errors.each do |entry|
      field = (entry[:field] || entry['field']).to_s
      next unless field.match?(METADATA_FIELD_CHECK)
      next if fields_with_checks.include?(field)

      checks << {
        field: field,
        status: 'failed',
        message: entry[:message] || entry['message']
      }
      fields_with_checks << field
    end

    warnings.each do |entry|
      field = (entry[:field] || entry['field']).to_s
      next unless field.match?(METADATA_FIELD_CHECK)
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
