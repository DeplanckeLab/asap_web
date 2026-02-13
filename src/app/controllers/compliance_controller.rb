# frozen_string_literal: true

require 'open3'
require 'shellwords'

# Controller for scFAIR cell metadata compliance checking
# Provides endpoints to validate cell metadata in loom files
# and view validation results
class ComplianceController < ApplicationController
  before_action :set_project, only: %i[validate_project show_project_result fix_project apply_project_fix project_metadata_fields]
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
        format.html { redirect_to compliance_project_result_path(@project), alert: 'No loom file found' }
        format.json { render json: { status: 'error', message: 'No loom file found', project_id: @project.id } }
      end
      return
    end

    # Run validation synchronously
    validator = CxgLoomValidatorService.new(loom_path, project: @project, logger: Rails.logger)
    result = validator.validate
    
    # Save result with schema metadata from compliance config
    validation_data = {
      valid: result.valid?,
      schema_version: result.schema_version,
      schema_name: schema_config['name'],
      source_url: schema_config['source_url'],
      source_schema_name: schema_config['source_schema_name'],
      description: schema_config['description'],
      url: schema_config['url'],
      compliant_icon: schema_config['compliant_icon'],
      not_compliant_icon: schema_config['not_compliant_icon'],
      validated_at: result.validated_at,
      loom_path: loom_path,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info,
      errors_count: result.errors.count,
      warnings_count: result.warnings.count,
      info_count: result.info.count
    }
    save_validation_result(@project, validation_data)

    respond_to do |format|
      format.html do
        if result.valid?
          redirect_to compliance_project_result_path(@project), notice: 'Validation passed!'
        else
          redirect_to compliance_project_result_path(@project), alert: "Validation found #{result.errors.count} error(s)"
        end
      end
      format.json do
        render json: { 
          status: 'completed',
          valid: result.valid?,
          errors_count: result.errors.count,
          warnings_count: result.warnings.count,
          info_count: result.info.count,
          project_id: @project.id 
        }
      end
    end
  end

  # GET /compliance/projects/:id/result
  # Show validation result for a specific project
  def show_project_result
    unless @project
      redirect_to compliance_index_path, alert: 'Project not found'
      return
    end

    @validation_result = load_validation_result(@project)
    @loom_files = find_project_loom_files(@project)
  end

  # GET /compliance/projects/:id/status
  # Get validation status (for AJAX polling)
  def project_status
    project = Project.find_by(id: params[:id])
    
    unless project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    result = load_validation_result(project)
    
    render json: {
      project_id: project.id,
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

    validator = CxgLoomValidatorService.new(file_path, logger: Rails.logger)
    result = validator.validate

    render json: {
      valid: result.valid?,
      schema_version: result.schema_version,
      validated_at: result.validated_at,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info,
      summary: {
        errors_count: result.errors.count,
        warnings_count: result.warnings.count,
        info_count: result.info.count
      }
    }
  end

  # GET /compliance/projects/:id/fix
  # Show the fix compliance form with metadata mapping options
  def fix_project
    unless @project
      redirect_to compliance_index_path, alert: 'Project not found'
      return
    end

    @validation_result = load_validation_result(@project)
    unless @validation_result
      redirect_to compliance_project_result_path(@project), alert: 'No validation result found. Please run validation first.'
      return
    end

    @loom_path = find_project_loom_path(@project)
    unless @loom_path && File.exist?(@loom_path)
      redirect_to compliance_project_result_path(@project), alert: 'No loom file found.'
      return
    end

    # Get the list of existing metadata fields in the loom file
    @available_col_attrs = extract_available_metadata(@project, @loom_path, :col_attrs)
    @available_global_attrs = extract_available_metadata(@project, @loom_path, :global_attrs)

    # Parse validation errors to identify fixable field groups (paired term+label)
    @fixable_groups = build_fixable_field_groups(@validation_result)
    @schema_config = resolve_compliance_schema(@project)
    @organism_info = resolve_organism_info(@project)
    @project_title = @project.respond_to?(:name) ? @project.name : nil

    # Load existing OtProject records for prefilling the form
    @prefill_data = build_prefill_data(@project)
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

    # Track which paths have been backed up in this batch to avoid double-renames
    backed_up = {} # { original_path => backup_path }

    fixes.each do |field_path, fix_data|
      next if fix_data[:action].blank? || fix_data[:action] == 'skip'

      action = fix_data[:action]
      field_path = field_path.to_s

      begin
        if action == 'map_from'
          source_path = fix_data[:source].to_s.strip
          next if source_path.blank?

          # If the target already exists, back it up first
          # Also adjust source_path if it points to the same field being backed up
          source_path, backed_up = handle_backup_if_needed(loom_path, field_path, source_path, backed_up)

          # Copy data from existing metadata to the required field using Python/h5py
          success = copy_metadata_in_loom(loom_path, source_path, field_path)
          if success
            applied << { field: field_path, action: 'mapped', source: source_path }
            # Create Annot record for the new field
            ensure_annot_record(@project, field_path, loom_path)
          else
            errors << { field: field_path, message: "Failed to copy from #{source_path}" }
          end

        elsif action == 'resolve_paired'
          # Resolve per-cell values using a mapping from the source field
          source_path = fix_data[:source].to_s.strip
          resolve_map_json = fix_data[:resolve_map].to_s.strip
          next if source_path.blank? || resolve_map_json.blank?

          # If the target already exists, back it up first
          source_path, backed_up = handle_backup_if_needed(loom_path, field_path, source_path, backed_up)

          success = resolve_paired_in_loom(loom_path, source_path, field_path, resolve_map_json)
          if success
            applied << { field: field_path, action: 'resolve_paired', source: source_path }
            ensure_annot_record(@project, field_path, loom_path)
          else
            errors << { field: field_path, message: "Failed to resolve paired values from #{source_path}" }
          end

        elsif action == 'set_value'
          value = fix_data[:value].to_s.strip
          next if value.blank?

          # If the target already exists, back it up first
          _, backed_up = handle_backup_if_needed(loom_path, field_path, nil, backed_up)

          if field_path.start_with?('/attrs/')
            # Write global attribute
            success = write_global_attr_to_loom(loom_path, field_path, value)
          else
            # Write constant value to all cells
            success = write_constant_to_loom(loom_path, field_path, value)
          end

          if success
            applied << { field: field_path, action: 'set_value', value: value }
            ensure_annot_record(@project, field_path, loom_path)
          else
            errors << { field: field_path, message: "Failed to write value '#{value}'" }
          end
        end
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error fixing #{field_path}: #{e.message}")
        errors << { field: field_path, message: e.message }
      end
    end

    # Record compliance mappings for tracking how metadata vectors are generated
    if applied.any?
      record_compliance_mappings(@project, applied, fixes)
    end

    result_url = compliance_project_result_path(@project)

    unless applied.any?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'No changes were applied.', redirect_url: result_url } }
        format.html { redirect_to compliance_project_fix_path(@project), alert: 'No changes were applied.' }
      end
      return
    end

    # Apply fixes to all LOOM file variants (cell-filtered, gene-filtered)
    apply_fixes_to_loom_variants(@project, loom_path, applied, fixes, backed_up)

    # Broadcast progress via websocket
    ActionCable.server.broadcast("compliance_#{@project.id}", {
      project_id: @project.id,
      status: 'applying',
      message: "Applied #{applied.count} fix(es) to #{count_loom_variants(@project, loom_path)} LOOM file(s). Running validation...",
      timestamp: Time.current.iso8601
    })

    # Trigger async validation and respond immediately
    CxgValidationJob.perform_later(@project.id)

    respond_to do |format|
      format.json do
        error_summary = errors.any? ? " (#{errors.count} error(s): #{errors.map { |e| e[:message] }.first(3).join(', ')})" : ''
        render json: {
          status: 'ok',
          message: "Applied #{applied.count} fix(es)#{error_summary}. Running validation...",
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
  #   organism_id - optional organism ID to filter by tax_id
  def ontology_autocomplete
    query = params[:term].to_s.strip
    prefixes = params[:prefixes].to_s.split(',').map(&:strip).reject(&:blank?)

    if query.blank? || prefixes.blank?
      render json: { results: [], total_count: 0 }
      return
    end

    # Map ontology prefixes to cell_ontology_ids
    ontology_ids = CellOntology.where(tag: prefixes).pluck(:id)
    if ontology_ids.empty?
      render json: { results: [], total_count: 0 }
      return
    end

    scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)

    # Filter by organism tax_id if provided
    if params[:organism_id].present?
      organism = Organism.find_by(id: params[:organism_id])
      if organism&.tax_id.present?
        scope = scope.where(tax_id: [organism.tax_id, nil, 0])
      end
    end

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
      .limit(25)
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

    ontology_ids = CellOntology.where(tag: prefixes).pluck(:id)
    if ontology_ids.empty?
      render json: { resolved: {}, multi_term_map: {} }
      return
    end

    resolved = {}
    # Track which values are multi-term (array-formatted) so the frontend can
    # render them distinctly and the resolve_map uses || as separator.
    multi_term_map = {}
    scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)

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
          # All items resolved: map original string to ||-joined identifiers and names
          resolved[av[:original]] = resolved_items.join(' || ')
          multi_term_map[av[:original]] = av[:items].join(' || ')
        end
        # If not all resolved, leave it unresolved so the user can fix it manually
      end
    else
      # Given names, find identifiers (case-insensitive)
      # Resolve plain names
      plain_values.each do |name|
        match = scope.where('name ILIKE ?', name.strip).order(:id).first
        resolved[name] = match.identifier if match
      end

      array_values.each do |av|
        resolved_items = av[:items].map do |name|
          match = scope.where('name ILIKE ?', name.strip).order(:id).first
          match&.identifier
        end
        if resolved_items.all?
          resolved[av[:original]] = resolved_items.join(' || ')
          multi_term_map[av[:original]] = av[:items].join(' || ')
        end
      end
    end

    render json: { resolved: resolved, multi_term_map: multi_term_map }
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

  private

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
  def apply_fixes_to_loom_variants(project, main_loom_path, applied, fixes, backed_up)
    all_loom_files = find_project_loom_files(project)
    variant_files = all_loom_files.reject { |f| File.realpath(f) == File.realpath(main_loom_path) }

    return if variant_files.empty?

    Rails.logger.info("[Compliance Fix] Applying fixes to #{variant_files.size} LOOM variant(s)")

    variant_files.each do |variant_path|
      Rails.logger.info("[Compliance Fix] Processing variant: #{variant_path}")
      variant_backed_up = {}

      applied.each do |entry|
        field_path = entry[:field]
        action = entry[:action]

        begin
          fix_data = fixes[field_path] || {}

          # Variant files only rename in the LOOM file; Annot/Run updates were
          # already done when the main file was processed (rename_annot: false).
          if action == 'mapped'
            source_path = entry[:source] || fix_data[:source].to_s.strip
            next if source_path.blank?
            source_path, variant_backed_up = handle_backup_if_needed(variant_path, field_path, source_path, variant_backed_up, rename_annot: false)
            copy_metadata_in_loom(variant_path, source_path, field_path)

          elsif action == 'resolve_paired'
            source_path = entry[:source] || fix_data[:source].to_s.strip
            resolve_map_json = fix_data[:resolve_map].to_s.strip
            next if source_path.blank? || resolve_map_json.blank?
            source_path, variant_backed_up = handle_backup_if_needed(variant_path, field_path, source_path, variant_backed_up, rename_annot: false)
            resolve_paired_in_loom(variant_path, source_path, field_path, resolve_map_json)

          elsif action == 'set_value'
            value = entry[:value] || fix_data[:value].to_s.strip
            next if value.blank?
            _, variant_backed_up = handle_backup_if_needed(variant_path, field_path, nil, variant_backed_up, rename_annot: false)

            if field_path.start_with?('/attrs/')
              write_global_attr_to_loom(variant_path, field_path, value)
            else
              write_constant_to_loom(variant_path, field_path, value)
            end
          end
        rescue StandardError => e
          Rails.logger.error("[Compliance Fix] Error applying #{action} to variant #{variant_path} field #{field_path}: #{e.message}")
        end
      end
    end
  end

  # Count total LOOM files (main + variants) for the progress message
  def count_loom_variants(project, main_loom_path)
    all_loom_files = find_project_loom_files(project)
    all_loom_files.size
  end

  def set_project
    @project = Project.find_by(id: params[:id] || params[:project_id])
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
      
      validator = CxgLoomValidatorService.new(temp_path.to_s, logger: Rails.logger)
      result = validator.validate

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
    project = Project.find_by(id: params[:project_id])
    
    unless project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    # Check permissions if user is logged in
    if current_user && !can_access_project?(project)
      render json: { error: 'Not authorized to validate this project' }, status: :forbidden
      return
    end

    CxgValidationJob.perform_later(project.id)
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

    validator = CxgLoomValidatorService.new(file_path, logger: Rails.logger)
    result = validator.validate

    render json: {
      valid: result.valid?,
      file_path: file_path,
      schema_version: result.schema_version,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info
    }
  end

  def load_validation_result(project)
    # Try loading from project.cxg_validation_result method
    # This method returns a Hash (already parsed), so we just need to symbolize keys
    if project.respond_to?(:cxg_validation_result)
      result = project.cxg_validation_result
      if result.present?
        # The model method returns a Hash with string keys, convert to symbol keys
        return result.deep_symbolize_keys
      end
    end

    if project.respond_to?(:metadata) && project.metadata&.dig('cxg_validation')
      return project.metadata['cxg_validation'].deep_symbolize_keys
    end

    # Try loading from project directory first (primary location)
    if project.respond_to?(:key) && project.respond_to?(:user_id) && project.key.present? && project.user_id.present?
      project_validation_path = File.join(
        ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
        project.user_id.to_s,
        project.key,
        'cxg_validation_result.json'
      )
      
      if File.exist?(project_validation_path)
        begin
          return JSON.parse(File.read(project_validation_path), symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      end
    end

    # Fall back to upload directory
    validation_path = File.join(
      ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus'),
      project.id.to_s,
      'cxg_validation_result.json'
    )

    if File.exist?(validation_path)
      begin
        return JSON.parse(File.read(validation_path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
    end

    nil
  end

  def find_project_loom_files(project)
    loom_files = []

    # Check project directory
    if project.respond_to?(:key) && project.respond_to?(:user_id)
      project_dir = File.join(
        ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
        project.user_id.to_s,
        project.key
      )
      
      if File.directory?(project_dir)
        loom_files += Dir.glob(File.join(project_dir, '**', '*.loom'))
      end
    end

    # Check upload directory
    upload_dir = File.join(
      ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus'),
      project.id.to_s
    )
    
    if File.directory?(upload_dir)
      loom_files += Dir.glob(File.join(upload_dir, '**', '*.loom'))
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

  # Save validation result to project directory
  def save_validation_result(project, validation_data)
    return unless project.respond_to?(:key) && project.respond_to?(:user_id)
    return unless project.key.present? && project.user_id.present?

    validation_path = File.join(
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      project.user_id.to_s,
      project.key,
      'cxg_validation_result.json'
    )
    
    begin
      FileUtils.mkdir_p(File.dirname(validation_path))
      File.write(validation_path, JSON.pretty_generate(validation_data))
      Rails.logger.info("[Compliance] Saved validation result to: #{validation_path}")
    rescue StandardError => e
      Rails.logger.error("[Compliance] Could not save validation result: #{e.message}")
    end
  end

  # Resolve the first compliance schema config for a project's type from its version
  # Returns a hash with all schema fields, with sensible defaults
  def resolve_compliance_schema(project)
    schemas = project.version&.compliance_schemas_for(project.project_type_id) || []
    schema = schemas.first || {}
    {
      'name' => schema['name'],
      'version' => schema['version'],
      'source_url' => schema['source_url'],
      'source_schema_name' => schema['source_schema_name'],
      'description' => schema['description'],
      'url' => schema['url'],
      'compliant_icon' => schema['compliant_icon'],
      'not_compliant_icon' => schema['not_compliant_icon']
    }.compact
  end

  def can_access_project?(project)
    return true if admin?
    return false unless current_user
    
    project.user_id == current_user.id || project.shares.exists?(user_id: current_user.id)
  end

  def admin?
    current_user&.respond_to?(:admin?) && current_user.admin?
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
  # type: :col_attrs or :global_attrs
  def extract_available_metadata(project, loom_path, type)
    # Try from Annot records first (fast)
    prefix = type == :col_attrs ? '/col_attrs/' : '/attrs/'
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

  # Paired field groups: each entry defines an ontology_term_id field and its label counterpart.
  # Standalone fields (no pair) have pair_label_path: nil.
  # Order matters: groups are displayed in this order.
  FIELD_GROUPS = [
    {
      id: 'organism',
      label: 'Organism',
      description: 'Organism taxonomy -- auto-filled from the project organism',
      type: :global_attr,
      auto_from_project: true,
      term_path: '/attrs/organism_ontology_term_id',
      term_ontology_prefixes: ['NCBITaxon'],
      term_format_hint: 'NCBITaxon:9606 (Human), NCBITaxon:10090 (Mouse)',
      label_path: '/attrs/organism',
      multi_value: false
    },
    {
      id: 'title',
      label: 'Title',
      description: 'Dataset title -- auto-filled from the project name',
      type: :global_attr,
      auto_from_project: :title,
      term_path: '/attrs/title',
      label_path: nil,
      multi_value: false
    },
    {
      id: 'assay',
      label: 'Assay',
      description: 'Experimental technique used (e.g., 10x 3\' v3)',
      type: :col_attr,
      term_path: '/col_attrs/assay_ontology_term_id',
      term_ontology_prefixes: ['EFO'],
      term_format_hint: 'EFO:XXXXXXX',
      label_path: '/col_attrs/assay',
      multi_value: false
    },
    {
      id: 'cell_type',
      label: 'Cell Type',
      description: 'Cell type annotation',
      type: :col_attr,
      term_path: '/col_attrs/cell_type_ontology_term_id',
      term_ontology_prefixes: ['CL', 'WBbt', 'ZFA', 'FBbt'],
      term_format_hint: 'CL:XXXXXXX',
      label_path: '/col_attrs/cell_type',
      multi_value: false
    },
    {
      id: 'development_stage',
      label: 'Development Stage',
      description: 'Developmental stage of the organism',
      type: :col_attr,
      term_path: '/col_attrs/development_stage_ontology_term_id',
      term_ontology_prefixes: ['HsapDv', 'MmusDv', 'WBls', 'ZFS', 'FBdv', 'UBERON'],
      term_format_hint: 'HsapDv:XXXXXXX or "unknown"',
      label_path: '/col_attrs/development_stage',
      multi_value: false
    },
    {
      id: 'disease',
      label: 'Disease',
      description: 'Disease condition or PATO:0000461 for normal/healthy',
      type: :col_attr,
      term_path: '/col_attrs/disease_ontology_term_id',
      term_ontology_prefixes: ['MONDO', 'PATO'],
      term_format_hint: 'MONDO:XXXXXXX or PATO:0000461 (normal)',
      label_path: '/col_attrs/disease',
      multi_value: true
    },
    {
      id: 'self_reported_ethnicity',
      label: 'Self-Reported Ethnicity',
      description: 'Self-reported ethnicity or "unknown" / "na"',
      type: :col_attr,
      term_path: '/col_attrs/self_reported_ethnicity_ontology_term_id',
      term_ontology_prefixes: ['HANCESTRO', 'AfPO'],
      term_format_hint: 'HANCESTRO:XXXX or "unknown" or "na"',
      label_path: '/col_attrs/self_reported_ethnicity',
      multi_value: true
    },
    {
      id: 'sex',
      label: 'Sex',
      description: 'Biological sex or "unknown" / "na"',
      type: :col_attr,
      term_path: '/col_attrs/sex_ontology_term_id',
      term_ontology_prefixes: ['PATO'],
      term_format_hint: 'PATO:0000384 (male), PATO:0000383 (female), or "unknown"',
      label_path: '/col_attrs/sex',
      multi_value: false
    },
    {
      id: 'tissue',
      label: 'Tissue',
      description: 'Tissue of origin',
      type: :col_attr,
      term_path: '/col_attrs/tissue_ontology_term_id',
      term_ontology_prefixes: ['UBERON', 'CVCL', 'WBbt', 'ZFA', 'FBbt'],
      term_format_hint: 'UBERON:XXXXXXX',
      label_path: '/col_attrs/tissue',
      multi_value: false
    },
    {
      id: 'tissue_type',
      label: 'Tissue Type',
      description: 'Type of tissue sample',
      type: :col_attr,
      term_path: '/col_attrs/tissue_type',
      term_valid_values: ['tissue', 'organoid', 'cell line', 'primary cell culture'],
      label_path: nil,
      multi_value: false
    },
    {
      id: 'suspension_type',
      label: 'Suspension Type',
      description: 'Type of cell suspension',
      type: :col_attr,
      term_path: '/col_attrs/suspension_type',
      term_valid_values: ['cell', 'nucleus', 'na'],
      label_path: nil,
      multi_value: false
    },
    {
      id: 'donor_id',
      label: 'Donor ID',
      description: 'Unique donor identifier',
      type: :col_attr,
      term_path: '/col_attrs/donor_id',
      label_path: nil,
      multi_value: false
    },
    {
      id: 'is_primary_data',
      label: 'Is Primary Data',
      description: 'Whether this is the canonical instance of this data (True/False)',
      type: :col_attr,
      term_path: '/col_attrs/is_primary_data',
      term_valid_values: ['True', 'False'],
      label_path: nil,
      multi_value: false
    }
  ].freeze

  # Build fixable field groups from validation errors.
  # Returns ALL field groups (not just those with errors) so that previously-fixed
  # fields can still be overridden. Groups without errors are included with
  # term_has_error / label_has_error set to false.
  def build_fixable_field_groups(validation_result)
    error_fields = (validation_result[:errors] || []).map { |e| e[:field].to_s }
    error_map = {}
    (validation_result[:errors] || []).each { |e| error_map[e[:field].to_s] = e[:message].to_s }

    groups = []
    FIELD_GROUPS.each do |group|
      term_has_error = error_fields.include?(group[:term_path])
      label_has_error = group[:label_path].present? && error_fields.include?(group[:label_path])

      groups << {
        group: group,
        term_has_error: term_has_error,
        label_has_error: label_has_error,
        term_error: error_map[group[:term_path]],
        label_error: error_map[group[:label_path]]
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

  # Build prefill data from existing OtProject records and recent ComplianceMappings.
  # Returns a hash keyed by field_group_id with source annot info and term assignments.
  def build_prefill_data(project)
    prefill = {}

    # Load OntologyTermType records that have a field_group_id mapping
    otts = OntologyTermType.where.not(field_group_id: [nil, '']).to_a

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

    # Also load most recent ComplianceMapping records to show resolve_map history
    recent_mappings = ComplianceMapping.where(project_id: project.id)
      .order(applied_at: :desc)
      .to_a
      .group_by(&:field_group_id)

    recent_mappings.each do |fg_id, mappings|
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

  # Handle backing up an existing field before overwriting it.
  # If source_path points to a field that was (or is being) backed up, adjusts the source.
  # Returns [adjusted_source_path, updated_backed_up_hash].
  def handle_backup_if_needed(loom_path, field_path, source_path, backed_up, rename_annot: true)
    # Check if this field was already backed up in this batch
    unless backed_up[field_path]
      # Check if the target field already exists in the LOOM file
      if metadata_exists_in_loom?(loom_path, field_path)
        backup_path = backup_existing_metadata(loom_path, field_path, @project, rename_annot: rename_annot)
        backed_up[field_path] = backup_path if backup_path
      end
    end

    # If the source path points to a field that has been backed up, redirect it
    if source_path.present? && backed_up[source_path]
      source_path = backed_up[source_path]
    end

    [source_path, backed_up]
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

    container = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run')
    cmd_parts = ['docker', 'exec', '-i', container, 'python3', '-', loom_path, field]

    begin
      stdout, _stderr, status = Open3.capture3(*cmd_parts, stdin_data: python_script)
      status.success? && stdout.strip == 'EXISTS'
    rescue StandardError => e
      Rails.logger.error("[Compliance Fix] Error checking metadata existence: #{e.message}")
      false
    end
  end

  # Back up an existing metadata field by renaming it to {name}_original.
  # Returns the backup path if renamed, or nil if the rename failed.
  # When rename_annot is true (default for the main LOOM file), the existing
  # Annot record and Run JSON references are updated in-place so that FK-based
  # associations (Cla, AnnotCellSet, OtProject) automatically follow.
  def backup_existing_metadata(loom_path, field_path, project, rename_annot: true)
    field_name = field_path.split('/').last
    parent = field_path.sub(/#{Regexp.escape(field_name)}\z/, '')
    backup_path = "#{parent}#{field_name}_original"

    if metadata_exists_in_loom?(loom_path, field_path)
      success = rename_metadata_in_loom(loom_path, field_path, backup_path)
      if success
        if rename_annot
          # Rename the existing Annot record(s) in-place and update Run JSON refs
          rename_annot_and_references(project, field_path, backup_path, loom_path)
        end
        Rails.logger.info("[Compliance Fix] Backed up #{field_path} -> #{backup_path}")
        return backup_path
      else
        Rails.logger.error("[Compliance Fix] Failed to back up #{field_path}")
      end
    end
    nil
  end

  # Rename existing Annot records from old_path to new_path and propagate
  # the name change into Run attrs_json / output_json so that downstream
  # processing keeps working with the renamed field.
  # FK-based associations (Cla, AnnotCellSet, OtProject) need no changes
  # because they reference the Annot by id, which stays the same.
  def rename_annot_and_references(project, old_path, new_path, loom_path)
    annots = project.annots.where(name: old_path)

    if annots.exists?
      new_label = new_path.split('/').last

      annots.find_each do |annot|
        annot.update!(name: new_path, label: new_label)
        Rails.logger.info("[Compliance Fix] Renamed Annot ##{annot.id} from #{old_path} to #{new_path}")
      end

      # Update Run JSON blobs that reference this annotation name
      update_run_attrs_json(project, old_path, new_path)
      update_run_output_json(project, old_path, new_path)
    else
      # No existing Annot found -- create one for the backup path
      ensure_annot_record(project, new_path, loom_path)
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
        changed = false
        attrs.each do |_key, val|
          next unless val.is_a?(Hash) && val['output_dataset'] == old_name
          val['output_dataset'] = new_name
          changed = true
        end
        if changed
          run.update!(attrs_json: attrs.to_json)
          Rails.logger.info("[Compliance Fix] Updated attrs_json for Run ##{run.id}: #{old_name} -> #{new_name}")
        end
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error updating attrs_json for Run ##{run.id}: #{e.message}")
      end
    end
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
    container = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run')
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

  # Record compliance mappings for tracking how scFAIR/CELLxGENE metadata vectors were generated.
  # Each applied fix is recorded with its action type, source, and resolve map.
  def record_compliance_mappings(project, applied, fixes)
    now = Time.current

    # Identify which field_group each applied field_path belongs to
    field_group_map = {}
    FIELD_GROUPS.each do |fg|
      field_group_map[fg[:term_path]] = fg[:id] if fg[:term_path]
      field_group_map[fg[:label_path]] = fg[:id] if fg[:label_path]
    end

    applied.each do |entry|
      field_path = entry[:field]
      field_group_id = field_group_map[field_path]
      next unless field_group_id

      fix_data = fixes[field_path] || {}
      action_type = entry[:action]
      action_type = 'map_from' if action_type == 'mapped'

      # Find the source annot if available
      source_path = entry[:source] || fix_data[:source].to_s
      source_annot = source_path.present? ? Annot.find_by(project_id: project.id, name: source_path) : nil

      mapping = ComplianceMapping.create!(
        project_id: project.id,
        field_group_id: field_group_id,
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

        resolve_map.each do |original_value, replacement_value|
          # Determine if the replacement is an identifier or a name based on the target path
          is_term_id_path = field_path.include?('ontology_term_id')

          # Handle multi-term values (|| separated) by recording each sub-term individually
          replacement_parts = replacement_value.to_s.include?(' || ') ? replacement_value.split(' || ').map(&:strip) : [replacement_value]

          replacement_parts.each do |part|
            replacement_identifier = is_term_id_path ? part : nil
            replacement_name = is_term_id_path ? nil : part

            # Try to find the cell_ontology_term record
            cot = nil
            if replacement_identifier
              cot = CellOntologyTerm.find_by(identifier: replacement_identifier, original: true)
            elsif replacement_name
              cot = CellOntologyTerm.where(original: true).where('name ILIKE ?', replacement_name).first
            end

            ComplianceTermReplacement.create!(
              compliance_mapping_id: mapping.id,
              original_value: original_value,
              replacement_identifier: cot&.identifier || replacement_identifier,
              replacement_name: cot&.name || replacement_name,
              cell_ontology_term_id: cot&.id
            )
          end
        end
      end
    rescue StandardError => e
      Rails.logger.error("[Compliance Mapping] Error recording mapping for #{entry[:field]}: #{e.message}")
    end
  end

  # Ensure an Annot record exists for a metadata field
  def ensure_annot_record(project, field_path, loom_path)
    relative_path = loom_path.sub(%r{\A.*/#{project.user_id}/#{project.key}/}, '')
    existing = project.annots.find_by(name: field_path, filepath: relative_path)
    return if existing

    project.annots.create(
      name: field_path,
      filepath: relative_path,
      label: field_path.split('/').last,
      nber_cols: project.nber_cols
    )
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Could not create Annot record: #{e.message}")
  end
end
