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
  end

  # POST /compliance/projects/:id/apply_fix
  # Apply metadata fixes to the loom file
  def apply_project_fix
    unless @project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    loom_path = find_project_loom_path(@project)
    unless loom_path && File.exist?(loom_path)
      redirect_to compliance_project_fix_path(@project), alert: 'No loom file found.'
      return
    end

    fixes = params[:fixes] || {}
    applied = []
    errors = []

    fixes.each do |field_path, fix_data|
      next if fix_data[:action].blank? || fix_data[:action] == 'skip'

      action = fix_data[:action]
      field_path = field_path.to_s

      begin
        if action == 'map_from'
          source_path = fix_data[:source].to_s.strip
          next if source_path.blank?

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

    if errors.any?
      flash[:alert] = "Applied #{applied.count} fix(es) with #{errors.count} error(s): #{errors.map { |e| e[:message] }.join(', ')}"
    elsif applied.any?
      flash[:notice] = "Applied #{applied.count} fix(es) to the loom file. Re-running validation..."
    else
      flash[:alert] = 'No changes were applied.'
      redirect_to compliance_project_fix_path(@project)
      return
    end

    # Re-run validation after applying fixes
    if applied.any?
      schema_config = resolve_compliance_schema(@project)
      validator = CxgLoomValidatorService.new(loom_path, project: @project, logger: Rails.logger)
      result = validator.validate

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

      if result.valid?
        redirect_to compliance_project_result_path(@project), notice: "Applied #{applied.count} fix(es). Validation now passes."
      else
        redirect_to compliance_project_result_path(@project), alert: "Applied #{applied.count} fix(es). Validation still has #{result.errors.count} error(s)."
      end
    else
      redirect_to compliance_project_fix_path(@project)
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
      render json: { resolved: {} }
      return
    end

    ontology_ids = CellOntology.where(tag: prefixes).pluck(:id)
    if ontology_ids.empty?
      render json: { resolved: {} }
      return
    end

    resolved = {}
    scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)

    if mode == 'by_identifier'
      # Given identifiers, find names
      terms = scope.where(identifier: values).pluck(:identifier, :name)
      terms.each { |ident, name| resolved[ident] = name }
    else
      # Given names, find identifiers (case-insensitive)
      # Use ILIKE for each name to handle case differences
      values.each do |name|
        match = scope.where('name ILIKE ?', name.strip).order(:id).first
        resolved[name] = match.identifier if match
      end
    end

    render json: { resolved: resolved }
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
  # Returns only groups where at least one of the two paths (term/label) has an error.
  def build_fixable_field_groups(validation_result)
    error_fields = (validation_result[:errors] || []).map { |e| e[:field].to_s }
    error_map = {}
    (validation_result[:errors] || []).each { |e| error_map[e[:field].to_s] = e[:message].to_s }

    groups = []
    FIELD_GROUPS.each do |group|
      term_has_error = error_fields.include?(group[:term_path])
      label_has_error = group[:label_path].present? && error_fields.include?(group[:label_path])

      next unless term_has_error || label_has_error

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
          resolved_arr = np.array(resolved, dtype='S')
          if target in f:
              del f[target]
          f.create_dataset(target, data=resolved_arr)

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, source_field, target_field, resolve_map_json)
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
