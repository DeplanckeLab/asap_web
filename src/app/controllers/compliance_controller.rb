# frozen_string_literal: true

# Controller for scFAIR cell metadata compliance checking
# Provides endpoints to validate cell metadata in loom files
# and view validation results
class ComplianceController < ApplicationController
  before_action :set_project, only: %i[validate_project show_project_result]
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
end
