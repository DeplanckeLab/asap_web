# frozen_string_literal: true

require 'open3'
require 'shellwords'

# Controller for scFAIR cell metadata compliance checking
# Provides endpoints to validate cell metadata in loom files
# and view validation results
class ComplianceController < ApplicationController
  include ScfairSchemaRules
  include ComplianceHelpers

  before_action :set_project, only: %i[validate_project show_project_result fix_project apply_project_fix project_metadata_fields project_status]
  before_action :authorize_project_compliance!, only: %i[validate_project show_project_result fix_project apply_project_fix project_metadata_fields project_status]
  around_action :with_project_compliance_rules_bundle, only: %i[fix_project apply_project_fix]
  skip_before_action :authenticate_user!, only: %i[index schema_docs], raise: false

  # GET /compliance
  # Main compliance page showing overview and documentation links
  def index
    @schema_versions = available_schema_versions
    @recent_validations = recent_project_validations if current_user
  end

  # GET /compliance/schema/:version
  # Show schema documentation for a specific version
  def schema_docs
    @version = params[:version] || '7.1.0'
    @doc_path = Rails.root.join('public', "cxg_#{@version.gsub('.', '_')}_loom_paths.html")
    
    unless File.exist?(@doc_path)
      redirect_to compliance_index_path, alert: "Schema documentation for version #{@version} not found"
      return
    end

    # Render the HTML file directly or embed it
    respond_to do |format|
      format.html { render :schema_docs }
    end
  end

  # POST /compliance/validate
  # Start validation for a file (uploaded or existing)
  def validate
    if params[:loom_file].present?
      # Handle uploaded file
      validate_uploaded_file
    elsif params[:project_id].present?
      # Validate existing project
      validate_existing_project
    elsif params[:file_path].present?
      # Validate specific file path
      validate_file_path
    else
      render json: { error: 'No file or project specified for validation' }, status: :unprocessable_entity
    end
  end

  # POST /compliance/projects/:id/validate
  # Trigger validation for a project's loom file
  # Runs synchronously if sidekiq is not available
  def validate_project
    unless @project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    # Resolve compliance schema config for this project
    schema_config = resolve_compliance_schema(@project)

    # Find the loom file
    loom_path = find_project_loom_path(@project)
    
    unless loom_path && File.exist?(loom_path)
      error_result = {
        valid: false,
        schema_version: schema_config['version'],
        schema_name: schema_config['name'],
        source_url: schema_config['source_url'],
        source_schema_name: schema_config['source_schema_name'],
        description: schema_config['description'],
        url: schema_config['url'],
        compliant_icon: schema_config['compliant_icon'],
        not_compliant_icon: schema_config['not_compliant_icon'],
        validated_at: Time.current.iso8601,
        error: 'No loom file found. Make sure the parsing step has completed.'
      }
      save_validation_result(@project, error_result)
      
      respond_to do |format|
        format.html { redirect_to project_path(@project, view: 'compliance'), alert: 'No loom file found' }
        format.json { render json: { status: 'error', message: 'No loom file found', project_id: @project.id } }
      end
      return
    end

    # Run validation synchronously
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run_project_compliance_validation(loom_path, @project, logger: Rails.logger)
    Rails.logger.info("[Compliance TIMING] Synchronous validation: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s")

    validation_data = project_validation_payload(@project, result, loom_path, schema_config)
    save_validation_result(@project, validation_data)

    respond_to do |format|
      format.html do
        if result.valid?
          redirect_to project_path(@project, view: 'compliance'), notice: 'Validation passed!'
        else
          redirect_to project_path(@project, view: 'compliance'), alert: "Validation found #{result.errors.count} #{result.errors.count == 1 ? 'error' : 'errors'}"
        end
      end
      format.json do
        render json: {
          status: 'completed',
          valid: result.valid?,
          errors_count: result.errors.count,
          warnings_count: result.warnings.count,
          valid_checks_count: result.valid_checks.count,
          project_id: @project.id
        }
      end
    end
  end

  # GET /compliance/projects/:id/result
  # Redirect to the project compliance view (moved to projects/:key?view=compliance)
  def show_project_result
    unless @project
      redirect_to compliance_index_path, alert: 'Project not found'
      return
    end

    redirect_to project_path(@project, view: 'compliance'), status: :moved_permanently
  end

  # GET /compliance/projects/:id/status
  # Get validation status (for AJAX polling)
  def project_status
    unless @project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    result = load_validation_result(@project)
    
    render json: {
      project_id: @project.id,
      has_result: result.present?,
      valid: result&.dig(:valid),
      validated_at: result&.dig(:validated_at),
      errors_count: result&.dig(:errors_count) || result&.dig(:errors)&.count || 0,
      warnings_count: result&.dig(:warnings_count) || result&.dig(:warnings)&.count || 0,
      schema_version: result&.dig(:schema_version)
    }
  end

  # POST /compliance/validate_file
  # Validate a file synchronously (for quick checks or API usage)
  def validate_file
    file_path = params[:file_path]
    
    unless file_path && File.exist?(file_path)
      render json: { error: 'File not found', path: file_path }, status: :not_found
      return
    end

    result = loom_compliance_result(file_path, logger: Rails.logger)

    render json: {
      valid: result.valid?,
      schema_version: result.schema_version,
      validated_at: result.validated_at,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info,
      valid_checks: result.valid_checks,
      summary: {
        errors_count: result.errors.count,
        warnings_count: result.warnings.count,
        info_count: result.info.count,
        valid_checks_count: result.valid_checks.count
      }
    }
  end

  # GET /compliance/projects/:id/fix
  # Show the fix compliance form with metadata mapping options
  def fix_project
    expires_now

    unless @project
      redirect_to compliance_index_path, alert: 'Project not found'
      return
    end

    @validation_result = load_validation_result(@project)
    unless @validation_result
      redirect_to project_path(@project, view: 'compliance'), alert: 'No validation result found. Please run validation first.'
      return
    end

    @loom_path = find_project_loom_path(@project)
    unless @loom_path && File.exist?(@loom_path)
      redirect_to project_path(@project, view: 'compliance'), alert: 'No loom file found.'
      return
    end

    # Get the list of existing metadata fields in the loom file
    @available_col_attrs = extract_available_metadata(@project, @loom_path, :col_attrs)
    @available_global_attrs = extract_available_metadata(@project, @loom_path, :global_attrs)
    @available_row_attrs = extract_available_metadata(@project, @loom_path, :row_attrs)

    # Parse validation errors to identify fixable field groups (paired term+label)
    @fixable_groups = build_fixable_field_groups(@validation_result)
    @schema_config = resolve_compliance_schema(@project)
    @organism_info = resolve_organism_info(@project)
    @ensembl_info = resolve_ensembl_info(@project)
    @project_title = @project.respond_to?(:name) ? @project.name : nil

    # Filter ontology prefixes per field group to only those applicable for
    # the project's organism (e.g. FBbt for Drosophila, not WBbt or ZFA).
    @fixable_groups.each do |fg|
      g = fg[:group]
      next unless g[:term_ontology_prefixes].present?
      g[:term_ontology_prefixes] = filter_prefixes_for_organism(g[:term_ontology_prefixes], @project)
    end

    # Cross-field constraints for the fix form (rules.yaml is the source of truth).
    @fix_form_cross_field = Scfair::FixFormCrossFieldConstraints.build(
      project: @project,
      fixable_groups: @fixable_groups
    )
    @schema_constraints = @fix_form_cross_field['static'].transform_values(&:symbolize_keys)

    # Load existing OtProject records for prefilling the form
    @prefill_data = build_prefill_data(@project)
    apply_var_legacy_prefill!(@prefill_data, @fixable_groups, @available_row_attrs)

    # When the target field already exists in the loom (e.g. from a previous fix),
    # switch the prefill source to the target field itself so the "Map from existing"
    # form shows current data rather than the original source annotation.
    @fixable_groups.each do |fg|
      g = fg[:group]
      fg_id = g[:id]
      next unless @prefill_data[fg_id]

      target_attr = g[:term_path]&.sub(%r{\A/col_attrs/}, '')
      if target_attr.present? && @available_col_attrs&.include?(target_attr)
        label_attr = g[:label_path]&.sub(%r{\A/col_attrs/}, '')
        source_is_target = @prefill_data[fg_id][:source_annot_name] == g[:term_path] ||
                           @prefill_data[fg_id][:source_annot_name] == g[:label_path]
        unless source_is_target
          preferred = if label_attr.present? && @available_col_attrs&.include?(label_attr)
                        g[:label_path]
                      else
                        g[:term_path]
                      end
          @prefill_data[fg_id][:source_annot_name] = preferred
        end
      end
    end

    # Pre-load current unique values from the LOOM for ALL field groups so that:
    # - Compliant fields show their current content with resolution badges
    # - Fields with errors also show current loom content (which may differ from
    #   the source annotation if a previous fix was partially applied)
    all_paths = []
    all_groups = []
    paired_paths = []
    @fixable_groups.each do |fg|
      g = fg[:group]
      next if g[:auto_from_project]
      all_paths << g[:term_path]
      all_paths << g[:label_path] if g[:label_path].present?
      all_groups << g
      if g[:label_path].present?
        paired_paths << [g[:term_path], g[:label_path]]
      end
    end
    raw_values = if all_paths.any?
                   fix_ui_values_from_validation_or_loom(
                     @validation_result,
                     @loom_path,
                     all_paths,
                     paired_paths: paired_paths
                   )
                 else
                   {}
                 end

    @compliant_field_values = raw_values
    @compliant_field_resolved = resolve_field_values(all_groups, raw_values)

    format = (@validation_result[:format] || @validation_result['format'] || 'loom').to_s
    field_values = (@validation_result[:field_values] || @validation_result['field_values'] || {}).deep_dup
    raw_values.each do |path, vals|
      field_values[path] = vals
      field_values[path.to_s] = vals
      field_values[path.to_sym] = vals
    end
    fix_resolutions = project_fix_field_resolutions(@project, field_values, format: format)
    merge_field_resolutions!(@compliant_field_resolved, fix_resolutions)

    # Extract current values of fields that have cross-field impact so the
    # frontend can evaluate constraints at page load (not only on change).
    @current_trigger_values = {}
    assay_vals = raw_values['/col_attrs/assay_ontology_term_id']
    if assay_vals.present?
      @current_trigger_values['assay_ontology_term_ids'] = assay_vals
      # Compute the union of allowed suspension types across ALL assay terms.
      # If the project has multiple assays, the user may need any of the
      # suspension types allowed by any of them.
      all_allowed = assay_vals.each_with_object(Set.new) do |assay_id, set|
        per_assay = resolve_suspension_type_for_assay(assay_id)
        set.merge(per_assay) if per_assay
      end
      @current_trigger_values['assay_allowed_suspension'] = all_allowed.to_a if all_allowed.any?
    end
    tissue_type_vals = raw_values['/col_attrs/tissue_type']
    if tissue_type_vals.present? && tissue_type_vals.size == 1
      @current_trigger_values['tissue_type'] = tissue_type_vals.first
    end

    # Read current unique values for ALL fields that could be targets of
    # cross-field constraints. The JS uses this to determine whether a
    # constrained field already has the correct value (=> skip) or needs
    # to be set (=> set_value + lock).  Merge with raw_values to avoid
    # a redundant LOOM read for fields already loaded above.
    constraint_target_paths = %w[
      /col_attrs/suspension_type
      /col_attrs/self_reported_ethnicity_ontology_term_id
      /col_attrs/self_reported_ethnicity
      /col_attrs/sex_ontology_term_id
      /col_attrs/sex
      /col_attrs/development_stage_ontology_term_id
      /col_attrs/development_stage
      /col_attrs/donor_id
      /col_attrs/tissue_ontology_term_id
    ]
    missing_paths = constraint_target_paths - raw_values.keys
    if missing_paths.any? && @loom_path.present?
      extra_values = fix_ui_values_from_validation_or_loom(@validation_result, @loom_path, missing_paths)
      raw_values.merge!(extra_values)
    end
    field_values = {}
    constraint_target_paths.each do |path|
      vals = raw_values[path]
      field_values[path] = vals if vals.present?
    end
    @current_trigger_values['field_values'] = field_values
  end

  # POST /compliance/projects/:id/apply_fix
  # Apply metadata fixes to the loom file
  def apply_project_fix
    unless @project
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'Project not found' }, status: :not_found }
        format.html { redirect_to root_path, alert: 'Project not found.' }
      end
      return
    end

    loom_path = find_project_loom_path(@project)
    unless loom_path && File.exist?(loom_path)
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'No loom file found.' }, status: :not_found }
        format.html { redirect_to compliance_project_fix_path(@project), alert: 'No loom file found.' }
      end
      return
    end

    fixes = params[:fixes] || {}
    applied = []
    errors = []
    t_total = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # ── Phase 1: Plan all LOOM operations and DB changes ──
    # Build a list of batched LOOM operations and corresponding DB change descriptors,
    # without executing any Python/Docker calls yet.
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loom_ops = []          # Array of hashes for execute_batch_loom_operations
    db_changes = []        # Array of { field_path:, action:, ... } describing DB work
    versioned_paths = {}   # { original_path => archive_path }

    fixes.each do |field_path, fix_data|
      next if fix_data[:action].blank? || fix_data[:action] == 'skip'

      action = fix_data[:action]
      field_path = field_path.to_s

      begin
        plan = plan_field_fix(@project, loom_path, field_path, action, fix_data, versioned_paths)
        next unless plan

        loom_ops.concat(plan[:loom_ops])
        db_changes << plan[:db_change]
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error planning #{field_path}: #{e.message}")
        errors << { field: field_path, message: e.message }
      end
    end
    Rails.logger.info("[Compliance Fix TIMING] Phase 1 (planning): #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s -- #{db_changes.size} fields planned, #{loom_ops.size} LOOM ops")

    result_url = project_path(@project, view: 'compliance')

    if loom_ops.blank?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'No changes were applied.', redirect_url: result_url } }
        format.html { redirect_to compliance_project_fix_path(@project), alert: 'No changes were applied.' }
      end
      return
    end

    # Append read_categories ops so we can read back freshly written data
    # in the same Docker call (saves a separate Python invocation).
    written_field_paths = db_changes.map { |c| c[:field_path] }.uniq
    cat_op_start = loom_ops.size
    written_field_paths.each do |fp|
      loom_ops << { op: 'read_categories', field: strip_leading_slash(fp), field_path: fp }
    end

    # ── Phase 2: Execute all LOOM operations in one batch ──
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Rails.logger.info("[Compliance Fix] Executing #{loom_ops.size} LOOM operations in a single batch (#{cat_op_start} writes + #{written_field_paths.size} category reads)")
    batch_results = execute_batch_loom_operations(loom_path, loom_ops)
    Rails.logger.info("[Compliance Fix TIMING] Phase 2 (LOOM batch Docker+Python): #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s")

    unless batch_results
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'LOOM batch operation failed.', redirect_url: result_url } }
        format.html { redirect_to compliance_project_fix_path(@project), alert: 'LOOM batch operation failed.' }
      end
      return
    end

    # Check for per-operation errors (write ops only)
    batch_results.each do |idx, result|
      next if idx >= cat_op_start
      if result['status'] == 'error'
        op = loom_ops[idx]
        Rails.logger.error("[Compliance Fix] Batch op ##{idx} (#{op[:op]}) failed: #{result['reason']}")
      end
    end

    # ── Phase 2b: Extract categories from batch results ──
    field_categories = {}
    written_field_paths.each_with_index do |fp, i|
      cat_result = batch_results[cat_op_start + i]
      next unless cat_result && cat_result['status'] == 'ok' && cat_result['categories']
      field_categories[fp] = {
        categories_json: cat_result['categories'].to_json,
        list_cat_json: cat_result['list_cats'].to_json,
        nber_cats: cat_result['nber_cats']
      }
    end

    # ── Phase 3: Apply DB changes ──
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    relative_path = loom_path.sub(%r{\A.*/#{@project.user_id}/#{@project.key}/}, '')

    db_changes.each do |change|
      begin
        apply_db_changes_for_field(@project, relative_path, change, field_categories)
        applied << change[:applied_entry]
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] DB error for #{change[:field_path]}: #{e.message}")
        errors << { field: change[:field_path], message: e.message }
      end
    end
    Rails.logger.info("[Compliance Fix TIMING] Phase 3 (DB changes): #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s -- #{applied.size} applied")

    # Record compliance mappings for tracking how metadata vectors are generated
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if applied.any?
      record_compliance_mappings(@project, applied, fixes)
    end
    Rails.logger.info("[Compliance Fix TIMING] Phase 4 (compliance mappings): #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s")

    unless applied.any?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'No changes were applied.', redirect_url: result_url } }
        format.html { redirect_to compliance_project_fix_path(@project), alert: 'No changes were applied.' }
      end
      return
    end

    # Apply fixes to all LOOM file variants (cell-filtered, gene-filtered).
    # Pass versioned_paths from the main pass so variants use the same archive paths.
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    apply_fixes_to_loom_variants(@project, loom_path, applied, fixes, versioned_paths)
    Rails.logger.info("[Compliance Fix TIMING] Phase 5 (LOOM variants): #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s")
    Rails.logger.info("[Compliance Fix TIMING] TOTAL (apply_project_fix): #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_total).round(2)}s")

    # Broadcast progress via websocket
    ActionCable.server.broadcast("compliance_#{@project.id}", {
      project_id: @project.id,
      status: 'applying',
      message: "Applied #{applied.count} #{applied.count == 1 ? 'fix' : 'fixes'} to #{count_loom_variants(@project, loom_path)} LOOM #{count_loom_variants(@project, loom_path) == 1 ? 'file' : 'files'}. Running validation...",
      timestamp: Time.current.iso8601
    })

    # Trigger async validation and respond immediately
    ScfairValidationJob.perform_later(@project.id)

    respond_to do |format|
      format.json do
        error_summary = errors.any? ? " (#{errors.count} #{errors.count == 1 ? 'error' : 'errors'}: #{errors.map { |e| e[:message] }.first(3).join(', ')})" : ''
        render json: {
          status: 'ok',
          message: "Applied #{applied.count} #{applied.count == 1 ? 'fix' : 'fixes'}#{error_summary}. Running validation...",
          applied_count: applied.count,
          errors_count: errors.count,
          validating: true,
          redirect_url: result_url
        }
      end
      format.html do
        flash[:notice] = "Applied #{applied.count} fix(es). Validation is running..."
        redirect_to result_url
      end
    end
  end

  # GET /compliance/ontology_autocomplete (JSON)
  # Search cell_ontology_terms for autocomplete in the fix form.
  # Params:
  #   term       - search query (matches identifier or name)
  #   prefixes   - comma-separated ontology prefixes (e.g., "CL,WBbt,ZFA,FBbt")
  #   project_id - optional project ID to restrict ontologies by organism
  def ontology_autocomplete
    query = params[:term].to_s.strip
    prefixes = params[:prefixes].to_s.split(',').map(&:strip).reject(&:blank?)

    if query.blank? || prefixes.blank?
      render json: { results: [], total_count: 0 }
      return
    end

    # Map ontology prefixes to cell_ontology_ids, filtered by organism
    ontology_ids = organism_scoped_ontology_ids(prefixes, params[:project_id])
    if ontology_ids.empty?
      render json: { results: [], total_count: 0 }
      return
    end

    scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)
    scope = apply_ontology_term_filters(scope)

    # Search by identifier or name
    search_pattern = "%#{query}%"
    matched_scope = scope.where('identifier ILIKE :q OR name ILIKE :q', q: search_pattern)

    # Count total matches before limiting
    total_count = matched_scope.count

    # Sort by relevance:
    #   0 = exact match on identifier (case-insensitive)
    #   1 = exact match on name (case-insensitive)
    #   2 = identifier starts with query
    #   3 = name starts with query
    #   4 = identifier contains query
    #   5 = name contains query
    #   Then alphabetically by name within each tier
    exact_q = ActiveRecord::Base.connection.quote(query)
    starts_q = ActiveRecord::Base.connection.quote("#{query}%")

    relevance_sql = <<~SQL.squish
      CASE
        WHEN identifier ILIKE #{exact_q} THEN 0
        WHEN name ILIKE #{exact_q} THEN 1
        WHEN identifier ILIKE #{starts_q} THEN 2
        WHEN name ILIKE #{starts_q} THEN 3
        WHEN identifier ILIKE #{ActiveRecord::Base.connection.quote("%#{query}%")} THEN 4
        ELSE 5
      END, name ASC
    SQL

    results = matched_scope
      .order(Arel.sql(relevance_sql))
      .limit(100)
      .pluck(:id, :identifier, :name)

    render json: {
      results: results.map { |id, identifier, name| { id: id, identifier: identifier, name: name, label: "#{identifier} - #{name}" } },
      total_count: total_count
    }
  end

  # POST /compliance/resolve_ontology_terms (JSON)
  # Given a list of values (identifiers or names), resolve them to their paired counterpart.
  # Params:
  #   values   - JSON array of strings to resolve
  #   prefixes - comma-separated ontology prefixes
  #   mode     - "by_identifier" (values are identifiers, return names)
  #              or "by_name" (values are names, return identifiers)
  def resolve_ontology_terms
    values = begin
      JSON.parse(params[:values] || '[]')
    rescue JSON::ParserError
      []
    end
    prefixes = params[:prefixes].to_s.split(',').map(&:strip).reject(&:blank?)
    mode = params[:mode].to_s

    if values.blank? || prefixes.blank? || !%w[by_identifier by_name].include?(mode)
      render json: { resolved: {}, multi_term_map: {} }
      return
    end

    ontology_ids = organism_scoped_ontology_ids(prefixes, params[:project_id])
    if ontology_ids.empty?
      render json: { resolved: {}, multi_term_map: {} }
      return
    end

    resolved = {}
    # Track which values are multi-term (array-formatted) so the frontend can
    # render them distinctly and the resolve_map uses || as separator.
    multi_term_map = {}
    # Track canonical names when source values don't match exactly
    canonical_names = {}
    scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)
    scope = apply_ontology_term_filters(scope)

    # Separate plain values from array-formatted values like "['FBbt:00003733', 'FBbt:00003737']"
    plain_values = []
    array_values = [] # Each entry: { original: "['a','b']", items: ["a","b"] }

    values.each do |val|
      parsed = parse_array_value(val)
      if parsed
        array_values << { original: val, items: parsed }
      else
        plain_values << val
      end
    end

    if mode == 'by_identifier'
      # Given identifiers, find names
      # First resolve all plain identifiers in one query
      all_identifiers = plain_values + array_values.flat_map { |av| av[:items] }
      terms_by_ident = {}
      scope.where(identifier: all_identifiers.uniq).pluck(:identifier, :name).each do |ident, name|
        terms_by_ident[ident] = name
      end

      plain_values.each do |ident|
        resolved[ident] = terms_by_ident[ident] if terms_by_ident[ident]
      end

      array_values.each do |av|
        resolved_items = av[:items].map { |ident| terms_by_ident[ident] }
        if resolved_items.all?
          # All items resolved: map original string to delimiter-joined identifiers and names
          resolved[av[:original]] = Scfair::Rules.join_multi_value(resolved_items)
          multi_term_map[av[:original]] = Scfair::Rules.join_multi_value(av[:items])
        end
        # If not all resolved, leave it unresolved so the user can fix it manually
      end
    else
      # Given names, find identifiers (case-insensitive)
      # Also return canonical_names so the frontend can detect when the source
      # value doesn't exactly match the ontology name (e.g. "fat_body" vs "fat body").
      canonical_names = {}

      # Batch-resolve all names in as few queries as possible
      all_names = plain_values.map(&:strip) + array_values.flat_map { |av| av[:items].map(&:strip) }
      name_to_term = batch_find_ontology_terms_by_name(scope, all_names.uniq)

      # Resolve plain names
      plain_values.each do |name|
        match = name_to_term[name.strip]
        if match
          resolved[name] = match[:identifier]
          canonical_names[name] = match[:name] if match[:name] != name
        end
      end

      array_values.each do |av|
        resolved_items = av[:items].map { |name| name_to_term[name.strip] }
        if resolved_items.all?
          resolved[av[:original]] = Scfair::Rules.join_multi_value(resolved_items.map { |m| m[:identifier] })
          multi_term_map[av[:original]] = Scfair::Rules.join_multi_value(av[:items])
          canonical = Scfair::Rules.join_multi_value(resolved_items.map { |m| m[:name] })
          original_joined = Scfair::Rules.join_multi_value(av[:items])
          canonical_names[av[:original]] = canonical if canonical != original_joined
        end
      end
    end

    render json: { resolved: resolved, multi_term_map: multi_term_map, canonical_names: canonical_names }
  end

  # GET /compliance/projects/:id/metadata_fields (JSON)
  # Returns available metadata fields and their sample values for the form
  def project_metadata_fields
    unless @project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    loom_path = find_project_loom_path(@project)
    unless loom_path
      render json: { error: 'No loom file found' }, status: :not_found
      return
    end

    field_path = params[:field_path].to_s
    return render(json: { error: 'Missing field_path' }, status: :bad_request) if field_path.blank?

    # Extract sample values for the requested metadata field
    values = H5DataService.get_metadata_values(loom_path, field_path)
    render json: { field: field_path, values: values }
  end

  def with_project_compliance_rules_bundle
    validation = @project ? load_validation_result(@project) : nil
    schema_id = if @project
                  resolve_project_schema_id(@project, validation_result: validation)
                else
                  Scfair::Rules::DEFAULT_SCHEMA_ID
                end
    Scfair::Rules.with_bundle(schema_id) { yield }
  end

  private

  def apply_ontology_term_filters(scope)
    filtered = scope
    if params[:allowed_terms].present?
      allowed_ids = params[:allowed_terms].to_s.split(',').map(&:strip).reject(&:blank?)
      filtered = filtered.where(identifier: allowed_ids) if allowed_ids.any?
    end
    if params[:excluded_terms].present?
      excluded_ids = params[:excluded_terms].to_s.split(',').map(&:strip).reject(&:blank?)
      filtered = filtered.where.not(identifier: excluded_ids) if excluded_ids.any?
    end
    filtered
  end

  # Batch-resolve many names at once using two queries (exact match + underscore-to-space).
  # Returns a hash { name => { identifier:, name: } } for found terms.
  def batch_find_ontology_terms_by_name(scope, names)
    return {} if names.blank?

    result = {}
    remaining = []

    # Step 1: batch exact match (case-insensitive) using LOWER()
    lower_map = {}
    names.each { |n| lower_map[n.downcase] = n }

    scope.where('LOWER(cell_ontology_terms.name) IN (?)', lower_map.keys)
         .pluck('cell_ontology_terms.name', :identifier).each do |db_name, identifier|
      original = lower_map[db_name.downcase]
      next unless original && !result.key?(original)
      result[original] = { identifier: identifier, name: db_name }
    end

    # Find which names are still unresolved
    remaining = names.select { |n| !result.key?(n) }

    # Step 2: for names with underscores, try replacing _ with space
    underscore_names = remaining.select { |n| n.include?('_') }
    if underscore_names.any?
      spaced_map = {}
      underscore_names.each { |n| spaced_map[n.tr('_', ' ').downcase] = n }

      scope.where('LOWER(cell_ontology_terms.name) IN (?)', spaced_map.keys)
           .pluck('cell_ontology_terms.name', :identifier).each do |db_name, identifier|
        original = spaced_map[db_name.downcase]
        next unless original && !result.key?(original)
        result[original] = { identifier: identifier, name: db_name }
      end
    end

    result
  end

  # Find an ontology term by name, case-insensitively.
  # First tries an exact case-insensitive match (with ILIKE wildcards escaped),
  # then tries replacing underscores with spaces (common in LOOM metadata).
  def find_ontology_term_by_name(scope, name)
    escaped = name.gsub('%', '\\%').gsub('_', '\\_')
    match = scope.where('name ILIKE ?', escaped).order(:id).first
    return match if match

    if name.include?('_')
      spaced = name.tr('_', ' ')
      escaped_spaced = spaced.gsub('%', '\\%').gsub('_', '\\_')
      scope.where('name ILIKE ?', escaped_spaced).order(:id).first
    end
  end

  # Parse a string like "['FBbt:00003733', 'FBbt:00003737']" into an array of individual values.
  # Returns nil if the string is not in array format.
  def parse_array_value(val)
    stripped = val.to_s.strip
    return nil unless stripped.start_with?('[') && stripped.end_with?(']')

    # Remove brackets and split on commas, then strip quotes and whitespace
    inner = stripped[1..-2]
    items = inner.split(',').map { |item| item.strip.gsub(/\A['"]|['"]\z/, '') }.reject(&:blank?)
    items.presence
  end

  # Apply the same fixes to all LOOM file variants (cell-filtered, gene-filtered).
  # The main loom_path has already been fixed; this replicates fixes to variants.
  # DB updates (Annot records, Run JSON) were already done for the main file,
  # so only LOOM operations are performed here -- one batch per variant file.
  def apply_fixes_to_loom_variants(project, main_loom_path, applied, fixes, main_versioned_paths)
    all_loom_files = find_project_loom_files(project)
    variant_files = all_loom_files.reject { |f| File.realpath(f) == File.realpath(main_loom_path) }

    return if variant_files.empty?

    Rails.logger.info("[Compliance Fix] Applying fixes to #{variant_files.size} LOOM #{variant_files.size == 1 ? 'variant' : 'variants'} in a single batch")

    # Build operations list for each variant (identical ops, different files)
    file_ops = {}
    variant_files.each do |variant_path|
      variant_versioned = {}
      ops = []

      applied.each do |entry|
        field_path = entry[:field]
        action = entry[:action]
        fix_data = fixes[field_path] || {}
        field_hdf5 = strip_leading_slash(field_path)

        archive_path = main_versioned_paths[field_path]
        if archive_path && !variant_versioned[field_path]
          ops << { op: 'rename', from: field_hdf5, to: strip_leading_slash(archive_path) }
          variant_versioned[field_path] = archive_path
        end

        if action == 'mapped'
          source_path = entry[:source] || fix_data[:source].to_s.strip
          next if source_path.blank?
          actual_source = adjust_source_if_versioned(source_path, variant_versioned)
          ops << { op: 'copy', source: strip_leading_slash(actual_source), target: field_hdf5 }

        elsif action == 'resolve_paired'
          source_path = entry[:source] || fix_data[:source].to_s.strip
          resolve_map_json = fix_data[:resolve_map].to_s.strip
          next if source_path.blank? || resolve_map_json.blank?
          actual_source = adjust_source_if_versioned(source_path, variant_versioned)
          resolve_map = begin
            JSON.parse(resolve_map_json)
          rescue JSON::ParserError
            {}
          end
          ops << { op: 'resolve_paired', source: strip_leading_slash(actual_source), target: field_hdf5, map: resolve_map }

        elsif action == 'set_value'
          value = entry[:value] || fix_data[:value].to_s.strip
          next if value.blank?
          if field_path.start_with?('/attrs/')
            attr_name = field_path.sub(%r{\A/attrs/}, '')
            ops << { op: 'set_global_attr', attr_name: attr_name, value: value }
          else
            ops << { op: 'set_value', target: field_hdf5, value: value }
          end
        end
      end

      file_ops[variant_path] = ops if ops.any?
    end

    return if file_ops.empty?

    # Execute all variant files in a single Docker+Python call
    results = execute_multi_file_loom_operations(file_ops)
    if results
      results.each do |path, file_results|
        file_results.each do |idx, result|
          if result['status'] == 'error'
            Rails.logger.error("[Compliance Fix] Variant op ##{idx} failed on #{path}: #{result['reason']}")
          end
        end
      end
    else
      Rails.logger.error("[Compliance Fix] Multi-file batch failed entirely")
    end
  end

  # Count total LOOM files (main + variants) for the progress message
  def count_loom_variants(project, main_loom_path)
    all_loom_files = find_project_loom_files(project)
    all_loom_files.size
  end

  def set_project
    identifier = params[:id] || params[:project_id]

    if identifier.present? && identifier.to_s.match?(/^\d+$/)
      @project = Project.find_by(id: identifier.to_i)
    end

    @project ||= Project.find_by(key: identifier) if identifier.present?

    if @project.nil? && identifier.to_s.match?(/^ASAP\d+$/i)
      numeric_part = identifier.match(/\d+$/).to_s.to_i
      @project = Project.find_by(public_id: numeric_part)
    end
  end

  def validate_uploaded_file
    uploaded = params[:loom_file]
    
    unless uploaded.original_filename.end_with?('.loom')
      render json: { error: 'File must be a .loom file' }, status: :unprocessable_entity
      return
    end

    # Save temporarily
    temp_path = Rails.root.join('tmp', 'uploads', "validation_#{SecureRandom.hex(8)}.loom")
    FileUtils.mkdir_p(File.dirname(temp_path))
    
    begin
      File.open(temp_path, 'wb') { |f| f.write(uploaded.read) }
      
      result = loom_compliance_result(temp_path.to_s, logger: Rails.logger)

      render json: {
        valid: result.valid?,
        filename: uploaded.original_filename,
        schema_version: result.schema_version,
        validated_at: result.validated_at,
        errors: result.errors,
        warnings: result.warnings,
        info: result.info
      }
    ensure
      FileUtils.rm_f(temp_path) if File.exist?(temp_path)
    end
  end

  def validate_existing_project
    identifier = params[:project_id]
    project = if identifier.to_s.match?(/^\d+$/)
                Project.find_by(id: identifier.to_i)
              else
                Project.find_by(key: identifier)
              end

    unless project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    # Check permissions if user is logged in
    if current_user && !can_access_project?(project)
      render json: { error: 'Not authorized to validate this project' }, status: :forbidden
      return
    end

    ScfairValidationJob.perform_later(project.id)
    render json: { status: 'queued', project_id: project.id }
  end

  def validate_file_path
    file_path = params[:file_path]
    
    # Security check - only allow certain directories
    allowed_dirs = [
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus')
    ]

    unless allowed_dirs.any? { |dir| file_path.start_with?(dir) }
      render json: { error: 'File path not allowed' }, status: :forbidden
      return
    end

    unless File.exist?(file_path)
      render json: { error: 'File not found' }, status: :not_found
      return
    end

    result = loom_compliance_result(file_path, logger: Rails.logger)

    render json: {
      valid: result.valid?,
      file_path: file_path,
      schema_version: result.schema_version,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info
    }
  end

  # load_validation_result is provided by ComplianceHelpers concern

  def find_project_loom_files(project)
    loom_files = []

    # Use Fo records to find LOOM files that belong to this project.
    # This avoids picking up source files (input.loom, fus/ uploads)
    # that must not be modified by compliance fixes.
    user_data_dir = ENV.fetch('USER_DATA_DIR', '/data/asap2/projects')
    project_dir = File.join(user_data_dir, project.user_id.to_s, project.key)

    Fo.where(project_id: project.id, ext: 'loom').pluck(:filepath).each do |rel_path|
      full_path = File.join(project_dir, rel_path)
      loom_files << full_path if File.exist?(full_path)
    end

    loom_files.uniq
  end

  # Find the primary loom file for validation (parsing/output.loom)
  def find_project_loom_path(project)
    return nil unless project.respond_to?(:key) && project.respond_to?(:user_id)
    return nil unless project.key.present? && project.user_id.present?

    user_data_dir = ENV.fetch('USER_DATA_DIR', '/data/asap2/projects')
    
    # Primary location: parsing/output.loom
    parsing_output = File.join(user_data_dir, project.user_id.to_s, project.key, 'parsing', 'output.loom')
    return parsing_output if File.exist?(parsing_output)
    
    # Find any loom file in the project directory
    project_dir = File.join(user_data_dir, project.user_id.to_s, project.key)
    if File.directory?(project_dir)
      loom_files = Dir.glob(File.join(project_dir, '**', '*.loom'))
      return loom_files.first if loom_files.any?
    end
    
    nil
  end

  # Save validation result to project directory and record in DB.
  # Each distinct result is stored as cxg_validation_result_<id>.json;
  # the latest is also written to cxg_validation_result.json for backward compat.
  def save_validation_result(project, validation_data)
    return unless project.respond_to?(:key) && project.respond_to?(:user_id)
    return unless project.key.present? && project.user_id.present?

    project_dir = File.join(
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      project.user_id.to_s,
      project.key
    )
    latest_path = File.join(project_dir, 'cxg_validation_result.json')
    json_content = JSON.pretty_generate(validation_data)

    # Record in compliance_validations history (skip if result unchanged)
    begin
      cs = project.compliance_schemas.first
      digest = Digest::MD5.hexdigest(json_content)
      latest = ComplianceValidation.for_project(project.id).first

      if latest.nil? || latest.result_digest != digest
        cv = ComplianceValidation.create!(
          project_id: project.id,
          compliance_schema_id: cs&.id,
          passed: validation_data[:valid] || false,
          errors_count: validation_data[:errors_count] || 0,
          warnings_count: validation_data[:warnings_count] || 0,
          valid_checks_count: validation_data[:valid_checks_count] || 0,
          result_digest: digest,
          validated_at: validation_data[:validated_at] || Time.current
        )

        FileUtils.mkdir_p(project_dir)
        File.write(cv.result_file_path, json_content)
        Rails.logger.info("[Compliance] Saved validation result to: #{cv.result_file_path}")
      else
        Rails.logger.info("[Compliance] Validation result unchanged (digest: #{digest}), skipping history entry")
      end
    rescue StandardError => e
      Rails.logger.error("[Compliance] Could not record validation history: #{e.message}")
    end

    # Always overwrite the latest result file for backward compat
    begin
      FileUtils.mkdir_p(project_dir)
      File.write(latest_path, json_content)
    rescue StandardError => e
      Rails.logger.error("[Compliance] Could not save latest validation result: #{e.message}")
    end
  end

  # Resolve the first active ComplianceSchema for a project's type.
  # Returns a hash with all schema fields (same shape as the old env_json config).
  def resolve_compliance_schema(project)
    cs = project.compliance_schemas.first
    cs ? cs.to_config_hash : {}
  end

  def can_access_project?(project)
    return true if admin?
    return false unless current_user
    
    project.user_id == current_user.id || project.shares.exists?(user_id: current_user.id)
  end

  def authorize_project_compliance!
    return if admin?

    respond_to do |format|
      format.html { redirect_to unauthorized_path }
      format.json { render json: { error: 'Not authorized' }, status: :forbidden }
      format.any { render plain: 'Not authorized', status: :forbidden }
    end
  end

  def available_schema_versions
    # List available schema documentation versions
    schema_files = Dir.glob(Rails.root.join('public', 'cxg_*_loom_paths.html'))
    schema_files.map do |path|
      filename = File.basename(path, '.html')
      match = filename.match(/cxg_(\d+)_(\d+)_(\d+)_loom_paths/)
      match ? "#{match[1]}.#{match[2]}.#{match[3]}" : nil
    end.compact.sort.reverse
  end

  def recent_project_validations
    # Get recent validation results for current user's projects
    return [] unless current_user

    projects = Project.where(user_id: current_user.id).order(updated_at: :desc).limit(10)
    projects.map do |project|
      result = load_validation_result(project)
      {
        project: project,
        validation: result
      } if result
    end.compact
  end

  # Extract available metadata fields from the loom file
  # type: :col_attrs, :global_attrs, or :row_attrs
  def extract_available_metadata(project, loom_path, type)
    # Try from Annot records first (fast)
    prefix = case type
             when :col_attrs then '/col_attrs/'
             when :row_attrs then '/row_attrs/'
             else '/attrs/'
             end
    annot_names = project.annots.pluck(:name).compact
    fields = annot_names.select { |n| n.start_with?(prefix) }.map { |n| n.sub(prefix, '') }.sort

    return fields if fields.any?

    # Fall back to ListMetadata from loom file
    output_file = "/tmp/compliance_meta_#{SecureRandom.hex(8)}.json"
    cmd = H5DataService.asap_command('-T', 'ListMetadata', '-f', loom_path, '-o', output_file)
    _stdout, _stderr, status = Open3.capture3(*cmd)

    return [] unless status.success? && File.exist?(output_file)

    begin
      raw = JSON.parse(File.read(output_file))
      entries = raw['metadata'] || []
      entries.select { |e| e['name'].to_s.start_with?(prefix) }
             .map { |e| e['name'].sub(prefix, '') }
             .sort
    rescue JSON::ParserError
      []
    ensure
      FileUtils.rm_f(output_file)
    end
  end

  # Read category counts for a list of field paths from a LOOM file.
  # Returns { field_path => { categories_json:, list_cat_json:, nber_cats: } }
  # matching the format expected by Annot records.
  def read_field_categories(loom_path, field_paths)
    return {} if field_paths.blank? || loom_path.blank?

    container = ENV.fetch('ASAP_RUN_CONTAINER')
    fields_json = field_paths.to_json

    script = <<~PY
      import h5py, sys, json
      from collections import Counter

      def decode(v):
          return v.decode() if hasattr(v, 'decode') else str(v)

      f = h5py.File(sys.argv[1], 'r')
      fields = json.loads(sys.argv[2])
      result = {}

      for fp in fields:
          parts = fp.lstrip('/').split('/')
          try:
              ds = f
              for p in parts:
                  ds = ds[p]
              vals = ds[:]
              counts = Counter(decode(v) for v in vals)
              categories = {k: int(c) for k, c in counts.items()}
              keys = list(categories.keys())
              nber_int = sum(1 for k in keys if k.lstrip('-').isdigit())
              nber_float = 0
              if nber_int != len(keys):
                  for k in keys:
                      try:
                          float(k)
                          nber_float += 1
                      except ValueError:
                          pass
              if nber_int == len(keys):
                  list_cats = sorted(keys, key=lambda x: int(x))
              elif nber_float == len(keys):
                  list_cats = sorted(keys, key=lambda x: float(x))
              else:
                  list_cats = sorted(keys)
              result[fp] = {
                  'categories': categories,
                  'list_cats': list_cats,
                  'nber_cats': len(categories)
              }
          except Exception:
              pass

      f.close()
      print(json.dumps(result))
    PY

    stdout, _stderr, status = Open3.capture3(
      'docker', 'exec', container, 'python3', '-c', script, loom_path, fields_json
    )
    return {} unless status.success?

    raw = JSON.parse(stdout) rescue {}
    raw.transform_values do |v|
      {
        categories_json: v['categories']&.to_json,
        list_cat_json: v['list_cats']&.to_json,
        nber_cats: v['nber_cats']
      }
    end
  end

  # Load compliance field group definitions from rules.yaml (fix_form.field_groups).
  # Joins ontology_term_type_id from OntologyTermType for paired ontology fields only.
  def load_field_groups
    ott_id_map = OntologyTermType.where(field_group_id: ontology_pair_field_group_ids)
                                 .pluck(:field_group_id, :id)
                                 .to_h
    Scfair::FixFormFieldGroupsBuilder.call(ontology_term_type_id_map: ott_id_map)
  end

  def ontology_pair_field_group_ids
    Scfair::Rules.fix_form_field_group_definitions
                 .select { |entry| entry[:field_kind] == :ontology_pair }
                 .map { |entry| entry[:id].to_s }
  end

  # Build fixable field groups from validation errors.
  # Returns ALL field groups (not just those with errors) so that previously-fixed
  # fields can still be overridden. Groups without errors are included with
  # term_has_error / label_has_error set to false.
  def build_fixable_field_groups(validation_result)
    error_fields = (validation_result[:errors] || []).map { |e| e[:field].to_s }
    error_map = {}
    (validation_result[:errors] || []).each { |e| error_map[e[:field].to_s] = e[:message].to_s }

    groups = []
    load_field_groups.each do |group|
      term_paths = Scfair::Rules.compliance_field_message_paths(group[:term_path])
      label_paths = group[:label_path].present? ? Scfair::Rules.compliance_field_message_paths(group[:label_path]) : []

      term_has_error = term_paths.any? { |path| error_fields.include?(path) }
      label_has_error = label_paths.any? { |path| error_fields.include?(path) }

      term_error = term_paths.lazy.map { |path| error_map[path] }.find(&:present?)
      label_error = label_paths.lazy.map { |path| error_map[path] }.find(&:present?)

      groups << {
        group: group,
        term_has_error: term_has_error,
        label_has_error: label_has_error,
        term_error: term_error,
        label_error: label_error
      }
    end
    groups
  end

  # Resolve organism info from the project for auto-fill
  def resolve_organism_info(project)
    organism = project.organism
    return nil unless organism

    {
      name: organism.name,
      short_name: organism.short_name,
      tax_id: organism.tax_id,
      ontology_term_id: "NCBITaxon:#{organism.tax_id}"
    }
  end

  def resolve_ensembl_info(project)
    Scfair::ProjectEnsemblMetadataResolver.call(project)
  end

  # Suggest legacy ASAP row_attrs sources when scFAIR var columns are missing.
  def apply_var_legacy_prefill!(prefill_data, fixable_groups, available_row_attrs)
    return if available_row_attrs.blank?

    fixable_groups.each do |fg|
      g = fg[:group]
      next unless g[:type] == :row_attr

      fg_id = g[:id].to_s
      prefill_data[fg_id] ||= {}
      next if prefill_data[fg_id][:source_annot_name].present?

      term_field = Scfair::Rules.obs_field_name_from_path(g[:term_path])
      legacy = Scfair::VarLegacySourceMatcher.suggest(term_field, available_row_attrs)
      next unless legacy

      prefill_data[fg_id][:source_annot_name] = "/row_attrs/#{legacy}"
    end
  end

  # ASSAY_SUSPENSION_TYPE_MAP, ASSAY_ANCESTOR_TERMS, and
  # resolve_suspension_type_for_assay are provided by ScfairSchemaRules.

  # Filter ontology prefixes to only those applicable for the project's organism.
  # An ontology is applicable if its tax_ids is blank (universal) or contains
  # the organism's tax_id.
  def filter_prefixes_for_organism(prefixes, project)
    return prefixes if prefixes.blank?
    organism = project.organism
    return prefixes unless organism&.tax_id.present?

    tax_id = organism.tax_id.to_s
    applicable_tags = CellOntology.where(tag: prefixes).select { |co|
      co.tax_ids.blank? || co.tax_id_list.map(&:to_s).include?(tax_id)
    }.map(&:tag)
    applicable_tags
  end

  # Filter CellOntology IDs from the given prefix tags by organism applicability.
  # Returns ontology IDs that are either universal or match the given tax_id.
  def organism_scoped_ontology_ids(prefixes, project_identifier)
    ontology_ids = CellOntology.where(tag: prefixes).pluck(:id, :tag, :tax_ids)
    return ontology_ids.map(&:first) unless project_identifier.present?

    project = if project_identifier.to_s.match?(/^\d+$/)
                Project.find_by(id: project_identifier.to_i)
              else
                Project.find_by(key: project_identifier)
              end
    return ontology_ids.map(&:first) unless project&.organism&.tax_id.present?

    tax_id_str = project.organism.tax_id.to_s
    ontology_ids.select { |_id, _tag, tax_ids|
      tax_ids.blank? || tax_ids.to_s.split(',').map(&:strip).include?(tax_id_str)
    }.map(&:first)
  end

  # Build prefill data from existing OtProject records and recent ComplianceMappings.
  # Returns a hash keyed by field_group_id with source annot info and term assignments.
  def build_prefill_data(project)
    prefill = {}

    # Load OntologyTermType records for paired ontology field groups (OtProject prefill).
    otts = OntologyTermType.where(field_group_id: ontology_pair_field_group_ids).to_a

    # Load OtProject records with eager-loaded associations
    ot_projects = OtProject.where(project_id: project.id)
      .includes(:cell_ontology_term, :annot)
      .to_a

    # Group OtProject records by ontology_term_type_id
    by_ott = ot_projects.group_by(&:ontology_term_type_id)

    otts.each do |ott|
      field_group_id = ott.field_group_id
      next unless field_group_id.present?

      records = by_ott[ott.id] || []
      next if records.empty?

      # Determine the source annot (most common annot_id across records)
      annot_ids = records.map(&:annot_id).compact
      source_annot_id = annot_ids.tally.max_by { |_, count| count }&.first
      source_annot = source_annot_id ? Annot.find_by(id: source_annot_id) : nil

      # Collect term assignments: identifier -> name from cell_ontology_term
      terms = records.filter_map do |otp|
        if otp.cell_ontology_term
          {
            identifier: otp.cell_ontology_term.identifier,
            name: otp.cell_ontology_term.name,
            cell_ontology_term_id: otp.cell_ontology_term_id
          }
        elsif otp.free_text.present?
          { identifier: nil, name: otp.free_text, cell_ontology_term_id: nil }
        end
      end.uniq { |t| t[:identifier] || t[:name] }

      prefill[field_group_id] = {
        source_annot_id: source_annot_id,
        source_annot_name: source_annot&.name,
        terms: terms
      }
    end

    # Also load most recent ComplianceMapping records to show resolve_map history.
    # Group by ontology_term_type_id (integer FK) and resolve to field_group_id
    # for the prefill hash key.
    ott_id_to_fg = otts.each_with_object({}) { |ott, h| h[ott.id] = ott.field_group_id }

    recent_mappings = ComplianceMapping.where(project_id: project.id)
      .order(applied_at: :desc)
      .to_a

    grouped = if recent_mappings.any? { |cm| cm.ontology_term_type_id.present? }
      by_ott_id = recent_mappings.group_by(&:ontology_term_type_id)
      by_ott_id.each_with_object({}) do |(ott_id, cms), h|
        fg_id = ott_id_to_fg[ott_id] || cms.first.field_group_id
        h[fg_id] = cms
      end
    else
      recent_mappings.group_by(&:field_group_id)
    end

    grouped.each do |fg_id, mappings|
      latest = mappings.first
      prefill[fg_id] ||= { source_annot_id: nil, source_annot_name: nil, terms: [] }
      prefill[fg_id][:last_mapping] = {
        action_type: latest.action_type,
        source_path: latest.source_path,
        resolve_map: latest.resolve_map,
        applied_at: latest.applied_at
      }
    end

    prefill
  end

  # Write a constant value to all cells of a col_attr field using Python/h5py
  def write_constant_to_loom(loom_path, field_path, value)
    field_name = field_path.sub(%r{\A/col_attrs/}, '')
    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import sys

      loom_path = sys.argv[1]
      field_name = sys.argv[2]
      value = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          n_cells = f['matrix'].shape[1]
          path = 'col_attrs/' + field_name
          if path in f:
              del f[path]
          f.create_dataset(path, data=np.array([value] * n_cells, dtype=h5py.special_dtype(vlen=str)))

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, field_name, value)
  end

  # Write a global attribute to the loom file using Python/h5py
  def write_global_attr_to_loom(loom_path, field_path, value)
    attr_name = field_path.sub(%r{\A/attrs/}, '')
    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import sys

      loom_path = sys.argv[1]
      attr_name = sys.argv[2]
      value = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          # Store as file-level attribute (LOOM spec)
          f.attrs[attr_name] = value
          # Also store as dataset under attrs/ group (ASAP convention)
          attrs_path = 'attrs/' + attr_name
          if attrs_path in f:
              del f[attrs_path]
          f.create_dataset(attrs_path, data=np.array([value], dtype=h5py.special_dtype(vlen=str)))

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, attr_name, value)
  end

  # Resolve paired values: read source data, apply a JSON mapping, write to target
  # The mapping translates each source value to a resolved counterpart
  # (e.g., cell type name -> ontology term ID, or vice versa)
  def resolve_paired_in_loom(loom_path, source_path, target_path, resolve_map_json)
    source_field = source_path.start_with?('/') ? source_path[1..] : source_path
    target_field = target_path.start_with?('/') ? target_path[1..] : target_path

    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import json
      import sys

      loom_path = sys.argv[1]
      source = sys.argv[2]
      target = sys.argv[3]
      resolve_map = json.loads(sys.argv[4])

      with h5py.File(loom_path, 'r+') as f:
          if source not in f:
              print('ERROR: Source path not found: ' + source, file=sys.stderr)
              sys.exit(1)
          src_data = f[source][:]
          # Decode bytes to strings if needed
          if src_data.dtype.kind in ('S', 'O'):
              src_data = np.array([v.decode('utf-8') if isinstance(v, bytes) else str(v) for v in src_data])
          else:
              src_data = np.array([str(v) for v in src_data])
          # Apply the mapping: for each source value, look up the resolved value
          resolved = []
          for val in src_data:
              mapped = resolve_map.get(val, val)
              resolved.append(mapped)
          resolved_arr = np.array(resolved, dtype=h5py.special_dtype(vlen=str))
          if target in f:
              del f[target]
          f.create_dataset(target, data=resolved_arr)

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, source_field, target_field, resolve_map_json)
  end

  # Plan LOOM operations and DB changes for a single field fix.
  # Returns { loom_ops: [...], db_change: { ... } } or nil if nothing to do.
  # Does NOT execute any Python calls -- only builds the operations list.
  #
  # If the existing Annot is not referenced by any process (Cla, AnnotCellSet,
  # OtProject, Run JSON), the field is overwritten in place without creating
  # a .vX backup -- there is nothing that depends on the old data.
  def plan_field_fix(project, loom_path, field_path, action, fix_data, versioned_paths)
    ops = []

    # -- Determine versioning / archiving needs --
    current_annot = project.annots.find_by(name: field_path, latest_version: true)
    field_hdf5 = strip_leading_slash(field_path)

    archive_path = nil
    next_version = 1
    skip_versioning = false

    if current_annot
      needs_backup = annot_referenced_by_processes?(current_annot, project)

      if needs_backup
        current_version = current_annot.version_nber || 0
        next_version = current_version + 1
        archive_path = "#{field_path}.v#{current_version}"

        unless versioned_paths[field_path]
          ops << { op: 'rename', from: field_hdf5, to: strip_leading_slash(archive_path) }
          versioned_paths[field_path] = archive_path
        else
          archive_path = versioned_paths[field_path]
        end
      else
        # Not referenced: overwrite in place, no .vX backup needed
        skip_versioning = true
        next_version = current_annot.version_nber || 1
        Rails.logger.info("[Compliance Fix] #{field_path} not referenced by any process, overwriting in place")
      end
    end

    # -- Build the write operation --
    if action == 'map_from'
      source_path = fix_data[:source].to_s.strip
      return nil if source_path.blank?
      actual_source = adjust_source_if_versioned(source_path, versioned_paths)
      ops << { op: 'copy', source: strip_leading_slash(actual_source), target: field_hdf5 }

      # Store the actual source path (which may be .vX after versioning) so the
      # recorded mapping points to where the original data really lives.
      applied_entry = { field: field_path, action: 'mapped', source: actual_source }

    elsif action == 'resolve_paired'
      source_path = fix_data[:source].to_s.strip
      resolve_map_json = fix_data[:resolve_map].to_s.strip
      return nil if source_path.blank? || resolve_map_json.blank?
      actual_source = adjust_source_if_versioned(source_path, versioned_paths)
      resolve_map = begin
        JSON.parse(resolve_map_json)
      rescue JSON::ParserError
        {}
      end
      ops << { op: 'resolve_paired', source: strip_leading_slash(actual_source), target: field_hdf5, map: resolve_map }

      applied_entry = { field: field_path, action: 'resolve_paired', source: actual_source }

    elsif action == 'set_value'
      value = fix_data[:value].to_s.strip
      return nil if value.blank?

      if field_path.start_with?('/attrs/')
        attr_name = field_path.sub(%r{\A/attrs/}, '')
        ops << { op: 'set_global_attr', attr_name: attr_name, value: value }
      else
        ops << { op: 'set_value', target: field_hdf5, value: value }
      end

      applied_entry = { field: field_path, action: 'set_value', value: value }

    else
      return nil
    end

    {
      loom_ops: ops,
      db_change: {
        field_path: field_path,
        action: action,
        current_annot: current_annot,
        archive_path: archive_path,
        next_version: next_version,
        skip_versioning: skip_versioning,
        applied_entry: applied_entry
      }
    }
  end

  # Check whether an Annot record is referenced by any process that would break
  # if the metadata were simply overwritten.  Returns true if the annot is used
  # by Cla, AnnotCellSet, OtProject, or appears in any Run's attrs_json/output_json.
  def annot_referenced_by_processes?(annot, project)
    return false unless annot

    # Direct foreign-key references
    return true if Cla.where(annot_id: annot.id).exists?
    return true if AnnotCellSet.where(annot_id: annot.id).exists?
    return true if OtProject.where(annot_id: annot.id).exists?

    # Path-based references in Run JSON columns.
    # Use quoted path to avoid false positives (e.g. /col_attrs/tissue matching
    # /col_attrs/tissue_type or /col_attrs/tissue_ontology_term_id).
    path = annot.name
    quoted_path = "\"#{path}\""
    return true if Run.where(project_id: project.id)
                      .where("attrs_json LIKE ?", "%#{quoted_path}%")
                      .exists?
    return true if Run.where(project_id: project.id)
                      .where("output_json LIKE ?", "%#{quoted_path}%")
                      .exists?

    false
  end

  # Apply the DB-side changes for a single field after the LOOM batch has succeeded.
  # This handles Annot archiving, Run JSON updates, and new Annot creation.
  # When skip_versioning is true the existing Annot is kept as-is (the LOOM data
  # was overwritten in place without a .vX backup).
  def apply_db_changes_for_field(project, relative_path, change, field_categories = {})
    field_path = change[:field_path]
    current_annot = change[:current_annot]
    archive_path = change[:archive_path]
    next_version = change[:next_version]
    cats = field_categories[field_path]

    if change[:skip_versioning]
      # Annot not referenced by anything: data was overwritten in place.
      # Update categories from the freshly written LOOM data.
      if current_annot
        update_attrs = {}
        if cats
          update_attrs[:categories_json] = cats[:categories_json]
          update_attrs[:list_cat_json] = cats[:list_cat_json]
          update_attrs[:nber_cats] = cats[:nber_cats]
        else
          update_attrs[:categories_json] = nil
          update_attrs[:list_cat_json] = nil
          update_attrs[:nber_cats] = nil
        end
        current_annot.update!(update_attrs)
        Rails.logger.info("[Compliance Fix] Overwritten #{field_path} in place (Annot ##{current_annot.id}, no backup needed)")
      else
        # No existing Annot -- create one
        create_annot_for_field(project, relative_path, field_path, next_version, cats)
      end
      return
    end

    # Archive old Annot record and update references
    if current_annot && archive_path
      current_annot.update!(
        name: archive_path,
        label: archive_path.split('/').last,
        latest_version: false
      )
      Rails.logger.info("[Compliance Fix] Archived Annot ##{current_annot.id}: #{field_path} -> #{archive_path}")

      update_run_attrs_json(project, field_path, archive_path)
      update_run_output_json(project, field_path, archive_path)
      update_project_json_files(project, field_path, archive_path)

      ComplianceMapping.where(project_id: project.id, source_path: field_path)
                       .update_all(source_path: archive_path)
    end

    # Create new Annot record for the replacement
    create_annot_for_field(project, relative_path, field_path, next_version, cats)
  end

  # Create a new Annot record for a compliance-fixed metadata field.
  # +cats+ is an optional hash with :categories_json, :list_cat_json, :nber_cats
  # read from the LOOM file after writing.
  def create_annot_for_field(project, relative_path, field_path, version_nber, cats = nil)
    dim = if field_path.start_with?('/col_attrs/')
            1
          elsif field_path.start_with?('/row_attrs/')
            2
          else
            4
          end
    data_type_id = (dim == 4) ? (DataType.find_by(name: 'STRING')&.id || 2) : (DataType.find_by(name: 'DISCRETE')&.id || 3)

    attrs = {
      name: field_path,
      filepath: relative_path,
      label: field_path.split('/').last,
      dim: dim,
      data_type_id: data_type_id,
      nber_cols: project.nber_cols,
      version_nber: version_nber,
      latest_version: true,
      user_id: project.user_id
    }

    if cats
      attrs[:categories_json] = cats[:categories_json]
      attrs[:list_cat_json] = cats[:list_cat_json]
      attrs[:nber_cats] = cats[:nber_cats]
    end

    annot = project.annots.create!(attrs)
    Rails.logger.info("[Compliance Fix] Created Annot for #{field_path} (v#{version_nber})")
    annot
  end

  # Strip leading slash for HDF5 path usage
  def strip_leading_slash(path)
    path.start_with?('/') ? path[1..] : path
  end

  # Adjust source_path if the source field was versioned earlier in the same batch.
  # Returns the versioned path if found, otherwise the original source_path.
  def adjust_source_if_versioned(source_path, versioned_paths)
    return source_path if source_path.blank?
    versioned_paths[source_path] || source_path
  end

  # Archive an existing metadata field under a versioned name (.v{N}), write new
  # data in its place, and create a proper Annot record for the replacement.
  #
  # This single function replaces the old backup_existing_metadata +
  # rename_annot_and_references + ensure_annot_record chain.  It is idempotent
  # within one batch thanks to the +versioned_paths+ hash that tracks which
  # fields have already been archived.
  #
  # Parameters:
  #   project          - the Project record
  #   loom_path        - absolute path to the LOOM file on disk
  #   field_path       - canonical HDF5 path (e.g. "/col_attrs/tissue")
  #   versioned_paths  - mutable Hash { original_path => archive_path } tracking
  #                      fields archived in this batch (updated in place)
  #   rename_annot     - when true (default), update Annot records and Run JSON
  #                      references; set to false for variant LOOM files where
  #                      the DB was already updated when the main file was processed
  #
  # Yields |loom_path, field_path| so the caller can write the new data.
  #
  # Returns the new Annot record, or nil if creation was skipped / failed.
  # +expected_archive_paths+ is an optional hash from the main-file pass that
  # maps { field_path => archive_path }.  When processing variant LOOMs
  # (rename_annot: false) we must use the same .v{N} archive names that the
  # main pass chose, because by the time variants are processed the DB already
  # reflects the new Annot (latest_version: true, version_nber: N+1).
  def version_and_replace_metadata(project, loom_path, field_path, versioned_paths, rename_annot: true, expected_archive_paths: {})
    relative_path = loom_path.sub(%r{\A.*/#{project.user_id}/#{project.key}/}, '')

    # -- Step A: determine version number and archive path --
    field_exists_in_loom = metadata_exists_in_loom?(loom_path, field_path)

    if expected_archive_paths[field_path]
      # Variant pass: reuse the archive path determined during main-file processing
      archive_path = expected_archive_paths[field_path]
      # Extract version from archive path (e.g. "/col_attrs/tissue.v1" -> 1)
      current_version = archive_path[/\.v(\d+)\z/, 1].to_i
      next_version = current_version + 1
    else
      # Main pass: look up current Annot to determine version
      current_annot = project.annots.find_by(name: field_path, latest_version: true)
    end

    if current_annot || field_exists_in_loom || expected_archive_paths[field_path]
      unless archive_path
        current_version = current_annot&.version_nber || 0
        next_version = current_version + 1
        archive_path = "#{field_path}.v#{current_version}"
      end

      # -- Step B: archive the old field in the LOOM --
      unless versioned_paths[field_path]
        if field_exists_in_loom
          rename_metadata_in_loom(loom_path, field_path, archive_path)
          Rails.logger.info("[Compliance Fix] Archived #{field_path} -> #{archive_path} in LOOM")
        end
        versioned_paths[field_path] = archive_path
      else
        archive_path = versioned_paths[field_path]
      end

      # -- Step C: update old Annot record and references (main file only) --
      if rename_annot && current_annot
        current_annot.update!(
          name: archive_path,
          label: archive_path.split('/').last,
          latest_version: false
        )
        Rails.logger.info("[Compliance Fix] Archived Annot ##{current_annot.id}: #{field_path} -> #{archive_path}")

        # Update Run DB columns that store annotation paths as strings
        update_run_attrs_json(project, field_path, archive_path)
        update_run_output_json(project, field_path, archive_path)

        # Update on-disk JSON files in the project directory that list metadata paths
        update_project_json_files(project, field_path, archive_path)

        # Update ComplianceMapping.source_path references if any point to old path
        ComplianceMapping.where(project_id: project.id, source_path: field_path)
                         .update_all(source_path: archive_path)
      end
    else
      # Brand new field (no existing Annot, not in LOOM)
      next_version = 1
    end

    # -- Step D: write new data to the LOOM --
    yield(loom_path, field_path) if block_given?

    # -- Step E: create the new Annot record (main file only) --
    if rename_annot
      dim = if field_path.start_with?('/col_attrs/')
              1
            elsif field_path.start_with?('/row_attrs/')
              2
            else
              4
            end
      data_type_id = (dim == 4) ? (DataType.find_by(name: 'STRING')&.id || 2) : (DataType.find_by(name: 'DISCRETE')&.id || 3)

      new_annot = project.annots.create!(
        name: field_path,
        filepath: relative_path,
        label: field_path.split('/').last,
        dim: dim,
        data_type_id: data_type_id,
        nber_cols: project.nber_cols,
        version_nber: next_version,
        latest_version: true,
        user_id: project.user_id
      )
      Rails.logger.info("[Compliance Fix] Created Annot ##{new_annot.id} for #{field_path} (v#{next_version})")
      return new_annot
    end

    nil
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error in version_and_replace_metadata for #{field_path}: #{e.message}")
    nil
  end

  # Rename (move) an existing metadata field in the loom file.
  # Used to back up existing data before overwriting (e.g., tissue -> tissue_original).
  def rename_metadata_in_loom(loom_path, old_path, new_path)
    old_field = old_path.start_with?('/') ? old_path[1..] : old_path
    new_field = new_path.start_with?('/') ? new_path[1..] : new_path

    python_script = <<~PYTHON
      import h5py
      import sys

      loom_path = sys.argv[1]
      old_name = sys.argv[2]
      new_name = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          if old_name not in f:
              print('SKIP: Source path not found: ' + old_name)
              sys.exit(0)
          if new_name in f:
              del f[new_name]
          f[new_name] = f[old_name][:]
          del f[old_name]

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, old_field, new_field)
  end

  # Check if a metadata field exists in the loom file
  def metadata_exists_in_loom?(loom_path, field_path)
    field = field_path.start_with?('/') ? field_path[1..] : field_path

    python_script = <<~PYTHON
      import h5py
      import sys

      loom_path = sys.argv[1]
      field = sys.argv[2]

      with h5py.File(loom_path, 'r') as f:
          if field in f:
              print('EXISTS')
          else:
              print('NOT_FOUND')
    PYTHON

    container = ENV.fetch('ASAP_RUN_CONTAINER')
    cmd_parts = ['docker', 'exec', '-i', container, 'python3', '-', loom_path, field]

    begin
      stdout, _stderr, status = Open3.capture3(*cmd_parts, stdin_data: python_script)
      status.success? && stdout.strip == 'EXISTS'
    rescue StandardError => e
      Rails.logger.error("[Compliance Fix] Error checking metadata existence: #{e.message}")
      false
    end
  end

  # Find runs for this project whose attrs_json contains the old annotation
  # name (stored in the output_dataset field) and replace it with new_name.
  def update_run_attrs_json(project, old_name, new_name)
    runs = Run.where(project_id: project.id)
              .where("attrs_json LIKE ?", "%#{old_name}%")

    runs.find_each do |run|
      begin
        attrs = JSON.parse(run.attrs_json)
        changed = replace_path_in_json(attrs, old_name, new_name)
        if changed
          run.update!(attrs_json: attrs.to_json)
          Rails.logger.info("[Compliance Fix] Updated attrs_json for Run ##{run.id}: #{old_name} -> #{new_name}")
        end
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error updating attrs_json for Run ##{run.id}: #{e.message}")
      end
    end
  end

  # Recursively replace exact string matches of old_path with new_path
  # in all values of a parsed JSON structure.  Returns true if any
  # replacement was made.
  def replace_path_in_json(obj, old_path, new_path)
    changed = false
    case obj
    when Hash
      obj.each do |k, v|
        if v.is_a?(String) && v == old_path
          obj[k] = new_path
          changed = true
        else
          changed = true if replace_path_in_json(v, old_path, new_path)
        end
      end
    when Array
      obj.each_with_index do |v, i|
        if v.is_a?(String) && v == old_path
          obj[i] = new_path
          changed = true
        else
          changed = true if replace_path_in_json(v, old_path, new_path)
        end
      end
    end
    changed
  end

  # Find runs for this project whose output_json contains the old annotation
  # name and replace all occurrences with new_name.
  def update_run_output_json(project, old_name, new_name)
    runs = Run.where(project_id: project.id)
              .where("output_json LIKE ?", "%#{old_name}%")

    runs.find_each do |run|
      begin
        raw = run.output_json
        if raw.include?(old_name)
          updated = raw.gsub(old_name, new_name)
          run.update!(output_json: updated)
          Rails.logger.info("[Compliance Fix] Updated output_json for Run ##{run.id}: #{old_name} -> #{new_name}")
        end
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error updating output_json for Run ##{run.id}: #{e.message}")
      end
    end
  end

  # Update on-disk JSON files in the project directory that reference the old
  # annotation path.  Three file types are handled:
  #
  # 1. output.json (in each step/run dir) -- "metadata" array where each entry
  #    has a "name" field (e.g. "/col_attrs/tissue").
  # 2. list_metadata_to_copy.json  -- { "meta": ["/col_attrs/tissue", ...] }
  # 3. list_metadata_to_copy2.json -- same structure as above
  def update_project_json_files(project, old_path, new_path)
    project_dir = File.join(
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      project.user_id.to_s,
      project.key
    )
    return unless File.directory?(project_dir)

    # -- output.json files: update "name" inside the "metadata" array --
    Dir.glob(File.join(project_dir, '**', 'output.json')).each do |json_path|
      update_metadata_name_in_json(json_path, old_path, new_path)
    end

    # -- list_metadata_to_copy*.json files: update path strings in the "meta" array --
    Dir.glob(File.join(project_dir, '**', 'list_metadata_to_copy*.json')).each do |json_path|
      update_meta_list_in_json(json_path, old_path, new_path)
    end
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error updating project JSON files: #{e.message}")
  end

  # Replace old_path with new_path in the "metadata" array entries of an output.json file.
  # Each entry is a hash with a "name" key holding the annotation path.
  def update_metadata_name_in_json(json_path, old_path, new_path)
    raw = File.read(json_path)
    return unless raw.include?(old_path)

    data = JSON.parse(raw)
    changed = false

    if data.is_a?(Hash) && data['metadata'].is_a?(Array)
      data['metadata'].each do |entry|
        next unless entry.is_a?(Hash) && entry['name'] == old_path
        entry['name'] = new_path
        changed = true
      end
    end

    if changed
      File.write(json_path, JSON.pretty_generate(data))
      Rails.logger.info("[Compliance Fix] Updated #{json_path}: #{old_path} -> #{new_path}")
    end
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error updating #{json_path}: #{e.message}")
  end

  # Replace old_path with new_path in the "meta" array of a list_metadata_to_copy*.json file.
  # The array contains bare path strings (e.g. "/col_attrs/tissue").
  def update_meta_list_in_json(json_path, old_path, new_path)
    raw = File.read(json_path)
    return unless raw.include?(old_path)

    data = JSON.parse(raw)
    changed = false

    if data.is_a?(Hash) && data['meta'].is_a?(Array)
      data['meta'] = data['meta'].map do |entry|
        if entry == old_path
          changed = true
          new_path
        else
          entry
        end
      end
    end

    if changed
      File.write(json_path, JSON.generate(data))
      Rails.logger.info("[Compliance Fix] Updated #{json_path}: #{old_path} -> #{new_path}")
    end
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error updating #{json_path}: #{e.message}")
  end

  # Copy metadata from one path to another within the same loom file
  def copy_metadata_in_loom(loom_path, source_path, target_path)
    source_field = source_path.start_with?('/') ? source_path[1..] : source_path
    target_field = target_path.start_with?('/') ? target_path[1..] : target_path

    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import sys

      loom_path = sys.argv[1]
      source = sys.argv[2]
      target = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          if source not in f:
              print('ERROR: Source path not found: ' + source, file=sys.stderr)
              sys.exit(1)
          data = f[source][:]
          if target in f:
              del f[target]
          f.create_dataset(target, data=data)

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, source_field, target_field)
  end

  # Execute a Python script inside the ASAP run container via stdin
  def run_python_in_container(script, *args)
    container = ENV.fetch('ASAP_RUN_CONTAINER')
    cmd_parts = ['docker', 'exec', '-i', container, 'python3', '-'] + args

    begin
      stdout, stderr, status = Open3.capture3(*cmd_parts, stdin_data: script)

      unless status.success?
        Rails.logger.error("[Compliance Fix] Python script failed: #{stderr}")
        return false
      end

      stdout.strip.start_with?('OK')
    rescue StandardError => e
      Rails.logger.error("[Compliance Fix] Error running Python: #{e.message}")
      false
    end
  end

  # Execute a batch of LOOM operations in a single Docker/Python invocation.
  # All operations share one h5py.File open, one Python startup, and one Docker exec.
  #
  # operations: array of hashes, each with an 'op' key and operation-specific fields:
  #   { op: 'check_exists', field: 'col_attrs/tissue' }
  #   { op: 'rename', from: 'col_attrs/tissue', to: 'col_attrs/tissue.v1' }
  #   { op: 'copy', source: 'col_attrs/tissue.v1', target: 'col_attrs/tissue' }
  #   { op: 'resolve_paired', source: 'col_attrs/X', target: 'col_attrs/Y', map: { ... } }
  #   { op: 'set_value', target: 'col_attrs/sex', value: 'female' }
  #   { op: 'set_global_attr', attr_name: 'title', value: 'My Dataset' }
  #
  # Returns a hash with results per operation index: { 0 => { "status" => "ok" }, ... }
  # On total failure returns nil.
  def execute_batch_loom_operations(loom_path, operations)
    return {} if operations.blank?

    # Embed the operations JSON as a base64-encoded string in the script
    # to avoid escaping issues with quotes, backslashes, etc.
    ops_b64 = Base64.strict_encode64(operations.to_json)

    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import json
      import sys
      import base64
      from collections import Counter

      def decode(v):
          return v.decode() if hasattr(v, 'decode') else str(v)

      loom_path = sys.argv[1]
      ops = json.loads(base64.b64decode(sys.argv[2]).decode('utf-8'))
      results = {}

      with h5py.File(loom_path, 'r+') as f:
          n_cells = f['matrix'].shape[1]
          for i, op in enumerate(ops):
              key = str(i)
              try:
                  kind = op['op']

                  if kind == 'check_exists':
                      field = op['field']
                      exists = field in f
                      results[key] = {'status': 'ok', 'exists': exists}

                  elif kind == 'rename':
                      old = op['from']
                      new = op['to']
                      if old not in f:
                          results[key] = {'status': 'skip', 'reason': 'source not found'}
                      else:
                          if new in f:
                              del f[new]
                          f[new] = f[old][:]
                          del f[old]
                          results[key] = {'status': 'ok'}

                  elif kind == 'copy':
                      source = op['source']
                      target = op['target']
                      if source not in f:
                          results[key] = {'status': 'error', 'reason': 'source not found: ' + source}
                      else:
                          data = f[source][:]
                          if target in f:
                              del f[target]
                          f.create_dataset(target, data=data)
                          results[key] = {'status': 'ok'}

                  elif kind == 'resolve_paired':
                      source = op['source']
                      target = op['target']
                      resolve_map = op['map']
                      if source not in f:
                          results[key] = {'status': 'error', 'reason': 'source not found: ' + source}
                      else:
                          src_data = f[source][:]
                          if src_data.dtype.kind in ('S', 'O'):
                              src_data = np.array([v.decode('utf-8') if isinstance(v, bytes) else str(v) for v in src_data])
                          else:
                              src_data = np.array([str(v) for v in src_data])
                          resolved = np.array([resolve_map.get(val, val) for val in src_data], dtype=h5py.special_dtype(vlen=str))
                          if target in f:
                              del f[target]
                          f.create_dataset(target, data=resolved)
                          results[key] = {'status': 'ok'}

                  elif kind == 'set_value':
                      target = op['target']
                      value = op['value']
                      if target.startswith('row_attrs/'):
                          n = f['matrix'].shape[0]
                      elif target.startswith('col_attrs/'):
                          n = f['matrix'].shape[1]
                      else:
                          n = f['matrix'].shape[1]
                      if target in f:
                          del f[target]
                      f.create_dataset(target, data=np.array([value] * n, dtype=h5py.special_dtype(vlen=str)))
                      results[key] = {'status': 'ok'}

                  elif kind == 'set_global_attr':
                      attr_name = op['attr_name']
                      value = op['value']
                      f.attrs[attr_name] = value
                      attrs_path = 'attrs/' + attr_name
                      if attrs_path in f:
                          del f[attrs_path]
                      f.create_dataset(attrs_path, data=np.array([value], dtype=h5py.special_dtype(vlen=str)))
                      results[key] = {'status': 'ok'}

                  elif kind == 'read_categories':
                      field = op['field']
                      if field not in f:
                          results[key] = {'status': 'skip', 'reason': 'field not found'}
                      else:
                          vals = f[field][:]
                          counts = Counter(decode(v) for v in vals)
                          categories = {k: int(c) for k, c in counts.items()}
                          keys = list(categories.keys())
                          nber_int = sum(1 for k in keys if k.lstrip('-').isdigit())
                          nber_float = 0
                          if nber_int != len(keys):
                              for k in keys:
                                  try:
                                      float(k)
                                      nber_float += 1
                                  except ValueError:
                                      pass
                          if nber_int == len(keys):
                              list_cats = sorted(keys, key=lambda x: int(x))
                          elif nber_float == len(keys):
                              list_cats = sorted(keys, key=lambda x: float(x))
                          else:
                              list_cats = sorted(keys)
                          results[key] = {
                              'status': 'ok',
                              'categories': categories,
                              'list_cats': list_cats,
                              'nber_cats': len(categories)
                          }

                  else:
                      results[key] = {'status': 'error', 'reason': 'unknown op: ' + kind}

              except Exception as e:
                  results[key] = {'status': 'error', 'reason': str(e)}

      print(json.dumps(results))
    PYTHON

    container = ENV.fetch('ASAP_RUN_CONTAINER')
    cmd_parts = ['docker', 'exec', '-i', container, 'python3', '-', loom_path, ops_b64]

    begin
      stdout, stderr, status = Open3.capture3(*cmd_parts, stdin_data: python_script)

      unless status.success?
        Rails.logger.error("[Compliance Fix] Batch Python failed: #{stderr}")
        return nil
      end

      results = JSON.parse(stdout.strip)
      results.transform_keys(&:to_i)
    rescue JSON::ParserError => e
      Rails.logger.error("[Compliance Fix] Batch result parse error: #{e.message} -- stdout: #{stdout}")
      nil
    rescue StandardError => e
      Rails.logger.error("[Compliance Fix] Batch execution error: #{e.message}")
      nil
    end
  end

  # Execute LOOM operations across multiple files in a single Docker+Python call.
  # file_ops is a hash: { "/path/to/variant1.loom" => [ops], "/path/to/variant2.loom" => [ops] }
  # Returns a hash: { "/path/to/variant1.loom" => { 0 => {status:...}, ... }, ... }
  def execute_multi_file_loom_operations(file_ops)
    return {} if file_ops.blank?

    payload_b64 = Base64.strict_encode64(file_ops.to_json)

    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import json
      import sys
      import base64

      def decode(v):
          return v.decode() if hasattr(v, 'decode') else str(v)

      payload = json.loads(base64.b64decode(sys.argv[1]).decode('utf-8'))
      all_results = {}

      for loom_path, ops in payload.items():
          file_results = {}
          try:
              with h5py.File(loom_path, 'r+') as f:
                  n_cells = f['matrix'].shape[1]
                  for i, op in enumerate(ops):
                      key = str(i)
                      try:
                          kind = op['op']

                          if kind == 'rename':
                              old = op['from']
                              new = op['to']
                              if old not in f:
                                  file_results[key] = {'status': 'skip', 'reason': 'source not found'}
                              else:
                                  if new in f:
                                      del f[new]
                                  f[new] = f[old][:]
                                  del f[old]
                                  file_results[key] = {'status': 'ok'}

                          elif kind == 'copy':
                              source = op['source']
                              target = op['target']
                              if source not in f:
                                  file_results[key] = {'status': 'error', 'reason': 'source not found: ' + source}
                              else:
                                  data = f[source][:]
                                  if target in f:
                                      del f[target]
                                  f.create_dataset(target, data=data)
                                  file_results[key] = {'status': 'ok'}

                          elif kind == 'resolve_paired':
                              source = op['source']
                              target = op['target']
                              resolve_map = op['map']
                              if source not in f:
                                  file_results[key] = {'status': 'error', 'reason': 'source not found: ' + source}
                              else:
                                  src_data = f[source][:]
                                  if src_data.dtype.kind in ('S', 'O'):
                                      src_data = np.array([v.decode('utf-8') if isinstance(v, bytes) else str(v) for v in src_data])
                                  else:
                                      src_data = np.array([str(v) for v in src_data])
                                  resolved = np.array([resolve_map.get(val, val) for val in src_data], dtype=h5py.special_dtype(vlen=str))
                                  if target in f:
                                      del f[target]
                                  f.create_dataset(target, data=resolved)
                                  file_results[key] = {'status': 'ok'}

                          elif kind == 'set_value':
                              target = op['target']
                              value = op['value']
                              if target.startswith('row_attrs/'):
                                  n = f['matrix'].shape[0]
                              elif target.startswith('col_attrs/'):
                                  n = f['matrix'].shape[1]
                              else:
                                  n = f['matrix'].shape[1]
                              if target in f:
                                  del f[target]
                              f.create_dataset(target, data=np.array([value] * n, dtype=h5py.special_dtype(vlen=str)))
                              file_results[key] = {'status': 'ok'}

                          elif kind == 'set_global_attr':
                              attr_name = op['attr_name']
                              value = op['value']
                              f.attrs[attr_name] = value
                              attrs_path = 'attrs/' + attr_name
                              if attrs_path in f:
                                  del f[attrs_path]
                              f.create_dataset(attrs_path, data=np.array([value], dtype=h5py.special_dtype(vlen=str)))
                              file_results[key] = {'status': 'ok'}

                          else:
                              file_results[key] = {'status': 'error', 'reason': 'unknown op: ' + kind}

                      except Exception as e:
                          file_results[key] = {'status': 'error', 'reason': str(e)}

          except Exception as e:
              file_results['_error'] = {'status': 'error', 'reason': str(e)}

          all_results[loom_path] = file_results

      print(json.dumps(all_results))
    PYTHON

    container = ENV.fetch('ASAP_RUN_CONTAINER')
    cmd_parts = ['docker', 'exec', '-i', container, 'python3', '-', payload_b64]

    total_ops = file_ops.values.sum(&:size)
    Rails.logger.info("[Compliance Fix] Multi-file batch: #{file_ops.size} files, #{total_ops} total ops")

    begin
      stdout, stderr, status = Open3.capture3(*cmd_parts, stdin_data: python_script)

      unless status.success?
        Rails.logger.error("[Compliance Fix] Multi-file batch Python failed: #{stderr}")
        return nil
      end

      results = JSON.parse(stdout.strip)
      # Convert inner keys to integers
      results.transform_values! { |file_res| file_res.transform_keys { |k| k == '_error' ? k : k.to_i } }
      results
    rescue JSON::ParserError => e
      Rails.logger.error("[Compliance Fix] Multi-file batch parse error: #{e.message}")
      nil
    rescue StandardError => e
      Rails.logger.error("[Compliance Fix] Multi-file batch execution error: #{e.message}")
      nil
    end
  end

  # Record compliance mappings for tracking how scFAIR metadata vectors were generated.
  # Each applied fix is recorded with its action type, source, and resolve map.
  def record_compliance_mappings(project, applied, fixes)
    now = Time.current

    # Identify which field_group (and its OntologyTermType PK) each applied field_path belongs to
    field_group_map = {}
    ott_id_map = {}
    load_field_groups.each do |fg|
      if fg[:term_path]
        field_group_map[fg[:term_path]] = fg[:id]
        ott_id_map[fg[:term_path]] = fg[:ontology_term_type_id]
      end
      if fg[:label_path]
        field_group_map[fg[:label_path]] = fg[:id]
        ott_id_map[fg[:label_path]] = fg[:ontology_term_type_id]
      end
    end

    # Pre-load source Annots in one batch query
    source_paths = applied.filter_map { |e| e[:source] || fixes[e[:field]]&.dig(:source).to_s.presence }.uniq
    source_annots = source_paths.any? ? Annot.where(project_id: project.id, name: source_paths).index_by(&:name) : {}

    # Pre-collect all replacement identifiers and names across all resolve maps
    # so we can batch-query CellOntologyTerm once instead of per-term.
    all_identifiers = Set.new
    all_names = Set.new
    applied.each do |entry|
      fix_data = fixes[entry[:field]] || {}
      next unless entry[:action] == 'resolve_paired' && fix_data[:resolve_map].present?
      is_term_id_path = entry[:field].include?('ontology_term_id')
      resolve_map = JSON.parse(fix_data[:resolve_map]) rescue next
      resolve_map.each_value do |replacement_value|
        parts = Scfair::Rules.multi_value?(replacement_value) ? Scfair::Rules.split_multi_value(replacement_value) : [replacement_value]
        parts.each { |p| is_term_id_path ? all_identifiers.add(p) : all_names.add(p) }
      end
    end

    # Batch queries: 1 for identifiers, 1 for names (instead of N individual queries)
    cot_by_identifier = all_identifiers.any? ?
      CellOntologyTerm.where(original: true, identifier: all_identifiers.to_a).index_by(&:identifier) : {}
    cot_by_name = {}
    if all_names.any?
      lower_map = all_names.each_with_object({}) { |n, h| h[n.downcase] = n }
      CellOntologyTerm.where(original: true).where('LOWER(cell_ontology_terms.name) IN (?)', lower_map.keys)
        .each { |cot| orig = lower_map[cot.name.downcase]; cot_by_name[orig] = cot if orig && !cot_by_name.key?(orig) }
    end

    applied.each do |entry|
      field_path = entry[:field]
      field_group_id = field_group_map[field_path]
      next unless field_group_id

      fix_data = fixes[field_path] || {}
      action_type = entry[:action]
      action_type = 'map_from' if action_type == 'mapped'

      source_path = entry[:source] || fix_data[:source].to_s
      source_annot = source_annots[source_path]

      mapping = ComplianceMapping.create!(
        project_id: project.id,
        compliance_schema_id: project.compliance_schemas.first&.id,
        field_group_id: field_group_id,
        ontology_term_type_id: ott_id_map[field_path],
        target_path: field_path,
        action_type: action_type,
        source_annot_id: source_annot&.id,
        source_path: source_path.presence,
        set_value: entry[:value],
        resolve_map_json: fix_data[:resolve_map].to_s.presence,
        applied_at: now
      )

      # Record individual term replacements from the resolve map
      if action_type == 'resolve_paired' && fix_data[:resolve_map].present?
        resolve_map = begin
          JSON.parse(fix_data[:resolve_map])
        rescue JSON::ParserError
          {}
        end

        is_term_id_path = field_path.include?('ontology_term_id')

        replacements_to_insert = []
        resolve_map.each do |original_value, replacement_value|
          replacement_parts = Scfair::Rules.multi_value?(replacement_value) ? Scfair::Rules.split_multi_value(replacement_value) : [replacement_value]

          replacement_parts.each do |part|
            cot = is_term_id_path ? cot_by_identifier[part] : cot_by_name[part]

            replacements_to_insert << {
              compliance_mapping_id: mapping.id,
              original_value: original_value,
              replacement_identifier: cot&.identifier || (is_term_id_path ? part : nil),
              replacement_name: cot&.name || (is_term_id_path ? nil : part),
              cell_ontology_term_id: cot&.id
            }
          end
        end

        # Bulk insert all replacements for this mapping
        ComplianceTermReplacement.insert_all!(replacements_to_insert) if replacements_to_insert.any?
      end
    rescue StandardError => e
      Rails.logger.error("[Compliance Mapping] Error recording mapping for #{entry[:field]}: #{e.message}")
    end
  end

  # Ensure an Annot record exists for a metadata field.
  # Always sets dim and data_type_id so the record is usable across the app.
  def ensure_annot_record(project, field_path, loom_path)
    relative_path = loom_path.sub(%r{\A.*/#{project.user_id}/#{project.key}/}, '')
    existing = project.annots.find_by(name: field_path, filepath: relative_path)
    return existing if existing

    dim = if field_path.start_with?('/col_attrs/')
            1
          elsif field_path.start_with?('/row_attrs/')
            2
          else
            4
          end
    data_type_id = (dim == 4) ? (DataType.find_by(name: 'STRING')&.id || 2) : (DataType.find_by(name: 'DISCRETE')&.id || 3)

    project.annots.create(
      name: field_path,
      filepath: relative_path,
      label: field_path.split('/').last,
      dim: dim,
      data_type_id: data_type_id,
      nber_cols: project.nber_cols,
      user_id: project.user_id
    )
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Could not create Annot record: #{e.message}")
  end
end
