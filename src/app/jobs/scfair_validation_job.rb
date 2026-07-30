# frozen_string_literal: true

# Background job to validate a loom file against the scFAIR schema
# Runs asynchronously after parsing is finished
class ScfairValidationJob < ApplicationJob
  queue_as :default

  # Perform validation on a project's loom file
  # @param project_id [Integer] The project ID to validate
  # @param options [Hash] Additional options
  #   - :schema_version [String] Schema version to validate against (default: '7.1.0')
  #   - :loom_path [String] Override path to loom file (optional)
  def perform(project_id, options = {})
    Rails.logger.info("[ScfairValidationJob] Starting validation for Project##{project_id}")
    
    project = Project.find_by(id: project_id)
    unless project
      Rails.logger.error("[ScfairValidationJob] Project##{project_id} not found")
      return
    end

    broadcast(project_id, status: 'validating', message: 'Starting scFAIR schema validation...')

    # Find the loom file to validate
    loom_path = options[:loom_path] || find_project_loom_file(project)
    
    unless loom_path && File.exist?(loom_path)
      broadcast(project_id, status: 'failed', message: 'No loom file found for validation')
      save_validation_result(project, nil, 'No loom file found')
      return
    end

    Rails.logger.info("[ScfairValidationJob] Validating loom file: #{loom_path}")
    broadcast(project_id, status: 'validating', message: "Validating #{File.basename(loom_path)}...", progress: 1)

    # Run validation
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = CompliancePipeline.validate_project_loom(loom_path, project, logger: Rails.logger) do |evt|
      broadcast(
        project_id,
        status: 'progress',
        message: evt[:message],
        progress: evt[:progress],
        stage: evt[:stage],
        format: evt[:format],
        current: evt[:current],
        total: evt[:total]
      )
    end
    Rails.logger.info("[ScfairValidationJob TIMING] Validation: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s")

    # Save results
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    save_validation_result(project, result, loom_path)
    Rails.logger.info("[ScfairValidationJob TIMING] Save result: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)}s")

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
        message: 'Validation passed! File is compliant with scFAIR schema 7.1.0',
        progress: 100,
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
        progress: 100,
        errors_count: result.errors.count,
        warnings_count: result.warnings.count,
        valid_checks_count: result.valid_checks.count,
        errors: result.errors.first(5),
        redirect_url: redirect_url
      )
    end

    Rails.logger.info("[ScfairValidationJob] Validation complete for Project##{project_id}. Valid: #{result.valid?}, Errors: #{result.errors.count}, Warnings: #{result.warnings.count}")
  rescue StandardError => e
    Rails.logger.error("[ScfairValidationJob] Error: #{e.class}: #{e.message}")
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
        Rails.logger.info("[ScfairValidationJob] Found loom file at: #{parsing_output}")
        return parsing_output
      end
      
      # Also check for any loom file in the project directory
      project_dir = File.join(user_data_dir, project.user_id.to_s, project.key)
      if File.directory?(project_dir)
        loom_files = Dir.glob(File.join(project_dir, '**', '*.loom'))
        if loom_files.any?
          Rails.logger.info("[ScfairValidationJob] Found loom file at: #{loom_files.first}")
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

    Fu.where(project_id: project.id).find_each do |fu|
      upload_dir = fu.upload_dir.to_s
      next unless File.directory?(upload_dir)

      loom_files = Dir.glob(File.join(upload_dir, '**', '*.loom'))
      return loom_files.first if loom_files.any?
    end

    nil
  end

  def save_validation_result(project, result, error_or_path)
    cs = project.compliance_schemas.first
    schema_meta = cs ? cs.to_config_hash.transform_keys(&:to_sym) : {}

    validation_data = if result
      data = {
        valid: result.valid?,
        schema_version: result.schema_version,
        schema_name: schema_meta[:name],
        source_url: schema_meta[:source_url],
        source_schema_name: schema_meta[:source_schema_name],
        description: schema_meta[:description],
        url: schema_meta[:url],
        compliant_icon: schema_meta[:compliant_icon],
        not_compliant_icon: schema_meta[:not_compliant_icon],
        validated_at: result.validated_at,
        loom_path: error_or_path,
        errors: result.errors,
        warnings: result.warnings,
        info: result.info,
        valid_checks: CompliancePipeline.displayable_valid_checks(result.valid_checks),
        errors_count: result.errors.count,
        warnings_count: result.warnings.count,
        valid_checks_count: CompliancePipeline.displayable_valid_checks(result.valid_checks).count,
        report_format: 'file_check',
        schema_id: result.respond_to?(:schema_id) ? result.schema_id : Scfair::Rules::DEFAULT_SCHEMA_ID
      }
      if result.respond_to?(:field_values) && result.field_values.present?
        data[:field_values] = result.field_values
      end
      if result.respond_to?(:check_groups) && result.check_groups.present?
        data[:check_groups] = result.check_groups
      end
      if result.respond_to?(:format) && result.format.present?
        data[:format] = result.format
      end
      data.compact
    else
      {
        valid: false,
        schema_version: Scfair::Rules.schema_version,
        schema_name: schema_meta[:name],
        validated_at: Time.current.iso8601,
        error: error_or_path
      }.compact
    end

    json_content = JSON.pretty_generate(validation_data)

    # Record in compliance_validations history (skip if result unchanged)
    begin
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
        if cv.result_file_path
          FileUtils.mkdir_p(File.dirname(cv.result_file_path))
          File.write(cv.result_file_path, json_content)
          Rails.logger.info("[ScfairValidationJob] Saved validation result to: #{cv.result_file_path}")
        end
      else
        Rails.logger.info("[ScfairValidationJob] Validation result unchanged (digest: #{digest}), skipping history entry")
      end
    rescue StandardError => e
      Rails.logger.error("[ScfairValidationJob] Could not record validation history: #{e.message}")
    end

    # Always overwrite the latest result file for backward compat
    if project.respond_to?(:cxg_validation_result=)
      project.cxg_validation_result = validation_data.to_json
      project.save
    elsif project.respond_to?(:metadata)
      project.metadata ||= {}
      project.metadata['cxg_validation'] = validation_data
      project.save
    else
      validation_path = nil
      if project.respond_to?(:key) && project.respond_to?(:user_id) && project.key.present? && project.user_id.present?
        validation_path = File.join(
          ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
          project.user_id.to_s,
          project.key,
          'cxg_validation_result.json'
        )
      end
      unless validation_path
        fu = project.fu_id.present? ? Fu.find_by(id: project.fu_id) : nil
        fu ||= Fu.where(project_id: project.id).order(id: :desc).first
        validation_path = File.join(fu.upload_dir.to_s, 'cxg_validation_result.json') if fu
      end
      if validation_path
        begin
          FileUtils.mkdir_p(File.dirname(validation_path))
          File.write(validation_path, json_content)
          Rails.logger.info("[ScfairValidationJob] Saved latest result to: #{validation_path}")
        rescue StandardError => e
          Rails.logger.error("[ScfairValidationJob] Could not save validation result: #{e.message}")
        end
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
