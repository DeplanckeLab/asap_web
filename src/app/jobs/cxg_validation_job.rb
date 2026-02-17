# frozen_string_literal: true

# Background job to validate a loom file against CELLxGENE schema
# Runs asynchronously after parsing is finished
class CxgValidationJob < ApplicationJob
  queue_as :default

  # Perform validation on a project's loom file
  # @param project_id [Integer] The project ID to validate
  # @param options [Hash] Additional options
  #   - :schema_version [String] Schema version to validate against (default: '7.1.0')
  #   - :loom_path [String] Override path to loom file (optional)
  def perform(project_id, options = {})
    Rails.logger.info("[CxgValidationJob] Starting validation for Project##{project_id}")
    
    project = Project.find_by(id: project_id)
    unless project
      Rails.logger.error("[CxgValidationJob] Project##{project_id} not found")
      return
    end

    broadcast(project_id, status: 'validating', message: 'Starting CELLxGENE schema validation...')

    # Find the loom file to validate
    loom_path = options[:loom_path] || find_project_loom_file(project)
    
    unless loom_path && File.exist?(loom_path)
      broadcast(project_id, status: 'failed', message: 'No loom file found for validation')
      save_validation_result(project, nil, 'No loom file found')
      return
    end

    Rails.logger.info("[CxgValidationJob] Validating loom file: #{loom_path}")
    broadcast(project_id, status: 'validating', message: "Validating #{File.basename(loom_path)}...")

    # Run validation
    validator = CxgLoomValidatorService.new(loom_path, project: project, logger: Rails.logger)
    result = validator.validate

    # Save results
    save_validation_result(project, result, loom_path)

    # Build redirect URL for the compliance view on the project page
    redirect_url = begin
      Rails.application.routes.url_helpers.project_path(project, view: 'compliance')
    rescue StandardError
      nil
    end

    # Broadcast completion
    if result.valid?
      broadcast(project_id,
        status: 'completed',
        valid: true,
        message: 'Validation passed! File is compliant with CELLxGENE schema 7.1.0',
        errors_count: 0,
        warnings_count: result.warnings.count,
        valid_checks_count: result.valid_checks.count,
        redirect_url: redirect_url
      )
    else
      broadcast(project_id,
        status: 'completed',
        valid: false,
        message: "Validation found #{result.errors.count} error(s)",
        errors_count: result.errors.count,
        warnings_count: result.warnings.count,
        valid_checks_count: result.valid_checks.count,
        errors: result.errors.first(5),
        redirect_url: redirect_url
      )
    end

    Rails.logger.info("[CxgValidationJob] Validation complete for Project##{project_id}. Valid: #{result.valid?}, Errors: #{result.errors.count}, Warnings: #{result.warnings.count}")
  rescue StandardError => e
    Rails.logger.error("[CxgValidationJob] Error: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace

    broadcast(project_id, status: 'failed', message: "Validation error: #{e.message}")
    
    if project
      save_validation_result(project, nil, e.message)
    end
  end

  private

  def find_project_loom_file(project)
    # If project has a specific loom path method, use that
    if project.respond_to?(:get_loom_path)
      path = project.get_loom_path
      return path if path && File.exist?(path)
    end

    # Primary location: USER_DATA_DIR/{user_id}/{project_key}/parsing/output.loom
    if project.respond_to?(:key) && project.respond_to?(:user_id) && project.key.present? && project.user_id.present?
      user_data_dir = ENV.fetch('USER_DATA_DIR', '/data/asap2/projects')
      parsing_output = File.join(user_data_dir, project.user_id.to_s, project.key, 'parsing', 'output.loom')
      
      if File.exist?(parsing_output)
        Rails.logger.info("[CxgValidationJob] Found loom file at: #{parsing_output}")
        return parsing_output
      end
      
      # Also check for any loom file in the project directory
      project_dir = File.join(user_data_dir, project.user_id.to_s, project.key)
      if File.directory?(project_dir)
        loom_files = Dir.glob(File.join(project_dir, '**', '*.loom'))
        if loom_files.any?
          Rails.logger.info("[CxgValidationJob] Found loom file at: #{loom_files.first}")
          return loom_files.first
        end
      end
    end

    # Try other project methods
    possible_paths = [
      project.respond_to?(:loom_file_path) ? project.loom_file_path : nil,
      project.respond_to?(:parsed_file_path) ? project.parsed_file_path : nil,
      project.respond_to?(:data_path) ? project.data_path : nil
    ].compact

    possible_paths.each do |path|
      return path if path && File.exist?(path) && path.end_with?('.loom')
    end

    # Check upload directory as last resort
    upload_dir = ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus')
    project_upload_dir = File.join(upload_dir, project.id.to_s)
    
    if File.directory?(project_upload_dir)
      loom_files = Dir.glob(File.join(project_upload_dir, '**', '*.loom'))
      return loom_files.first if loom_files.any?
    end

    nil
  end

  def save_validation_result(project, result, error_or_path)
    # Store validation result in project metadata or dedicated table
    validation_data = if result
      {
        valid: result.valid?,
        schema_version: result.schema_version,
        validated_at: result.validated_at,
        loom_path: error_or_path,
        errors: result.errors,
        warnings: result.warnings,
        info: result.info,
        valid_checks: result.valid_checks,
        errors_count: result.errors.count,
        warnings_count: result.warnings.count,
        valid_checks_count: result.valid_checks.count,
        field_resolutions: result.field_resolutions || {}
      }
    else
      {
        valid: false,
        schema_version: CxgLoomValidatorService::SCHEMA_VERSION,
        validated_at: Time.current.iso8601,
        error: error_or_path
      }
    end

    # Try to save to project metadata
    if project.respond_to?(:cxg_validation_result=)
      project.cxg_validation_result = validation_data.to_json
      project.save
    elsif project.respond_to?(:metadata)
      project.metadata ||= {}
      project.metadata['cxg_validation'] = validation_data
      project.save
    else
      # Store in a file - prefer project directory
      validation_path = nil
      
      if project.respond_to?(:key) && project.respond_to?(:user_id) && project.key.present? && project.user_id.present?
        validation_path = File.join(
          ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
          project.user_id.to_s,
          project.key,
          'cxg_validation_result.json'
        )
      end
      
      # Fall back to upload directory if project directory not available
      validation_path ||= File.join(
        ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus'),
        project.id.to_s,
        'cxg_validation_result.json'
      )
      
      begin
        FileUtils.mkdir_p(File.dirname(validation_path))
        File.write(validation_path, JSON.pretty_generate(validation_data))
        Rails.logger.info("[CxgValidationJob] Saved validation result to: #{validation_path}")
      rescue StandardError => e
        Rails.logger.error("[CxgValidationJob] Could not save validation result: #{e.message}")
      end
    end
  end

  def broadcast(project_id, payload)
    message = payload.merge(
      project_id: project_id, 
      stage: 'cxg_validation',
      timestamp: Time.current.iso8601
    )
    
    # Broadcast to compliance channel for the compliance page
    ActionCable.server.broadcast("compliance_#{project_id}", message)
    
    # Also broadcast to project channel for project page updates
    ActionCable.server.broadcast("project_#{project_id}", message)
  end
end
