class SlurmJobMonitorJob < ApplicationJob
  queue_as :default

  MAX_MONITOR_ATTEMPTS = 480
  MONITOR_INTERVAL = 30.seconds

  def perform(run_id, slurm_job_id, attempt = 1)
    Rails.logger.debug("[SlurmJobMonitorJob] Checking Run##{run_id}, SLURM Job##{slurm_job_id}, attempt #{attempt}")
    
    run = Run.find_by(id: run_id)
    unless run
      Rails.logger.error("[SlurmJobMonitorJob] Run##{run_id} not found")
      return
    end

    if run.status_id == 4
      Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} already marked as failed, stopping monitoring")
      return
    end

    begin
      slurm_service = SlurmService.new(logger: Rails.logger)
      status = slurm_service.get_job_status(slurm_job_id, run)
      
      if status.nil?
        Rails.logger.warn("[SlurmJobMonitorJob] Could not get status for SLURM job #{slurm_job_id}, will retry")
        if attempt < MAX_MONITOR_ATTEMPTS
          SlurmJobMonitorJob.set(wait: MONITOR_INTERVAL).perform_later(run_id, slurm_job_id, attempt + 1)
        else
          Rails.logger.error("[SlurmJobMonitorJob] Max attempts reached for Run##{run_id}, marking as failed")
          finish_run_with_error(run, "SLURM job status could not be determined after #{MAX_MONITOR_ATTEMPTS} attempts")
        end
        return
      end

      case status
      when :pending, :running
        Rails.logger.debug("[SlurmJobMonitorJob] Run##{run_id} still #{status}, will check again")

        # If the job just transitioned to running, update status and broadcast
        if status == :running && run.status_id != 2
          project = run.project
          step = run.step

          run.update(status_id: 2)

          project_step = ProjectStep.where(project_id: project.id, step_id: step.id).first
          project_step.update(status_id: 2) if project_step

          project.broadcast(step.id) if project.respond_to?(:broadcast)
        end

        if attempt < MAX_MONITOR_ATTEMPTS
          SlurmJobMonitorJob.set(wait: MONITOR_INTERVAL).perform_later(run_id, slurm_job_id, attempt + 1)
        else
          Rails.logger.error("[SlurmJobMonitorJob] Max attempts reached for Run##{run_id}, marking as failed")
          finish_run_with_error(run, "SLURM job did not complete within expected time")
        end

      when :completed
        Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} completed successfully")
        finish_run_successfully(run, slurm_service, slurm_job_id)

      when :failed, :timeout, :node_fail, :cancelled
        Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} finished with status: #{status}")
        # Extract detailed error message from error file
        error_message = extract_error_message(run)
        finish_run_with_error(run, error_message || "SLURM job finished with status: #{status}")

      else
        Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} has unknown status: #{status}, will retry")
        if attempt < MAX_MONITOR_ATTEMPTS
          SlurmJobMonitorJob.set(wait: MONITOR_INTERVAL).perform_later(run_id, slurm_job_id, attempt + 1)
        else
          finish_run_with_error(run, "SLURM job has unknown status: #{status}")
        end
      end

    rescue StandardError => e
      Rails.logger.error("[SlurmJobMonitorJob] Error monitoring Run##{run_id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      
      if attempt < MAX_MONITOR_ATTEMPTS
        SlurmJobMonitorJob.set(wait: MONITOR_INTERVAL).perform_later(run_id, slurm_job_id, attempt + 1)
      else
        finish_run_with_error(run, "Error monitoring job: #{e.message}")
      end
    end
  end

  private

  def extract_error_message(run)
    return nil unless run
    
    project = run.project
    step = run.step
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name
    output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    
    error_file = output_dir + "slurm_#{run.id}.err"
    return nil unless File.exist?(error_file)
    
    error_content = File.read(error_file)
    
    # Filter out Elasticsearch responses - these are not errors
    # Elasticsearch responses have patterns like: {"_index":"...","_id":"...","_version":...,"result":"updated"...}
    if error_content.match?(/\{"_index":|"_id":|"_version":|"result":"updated"/)
      # This looks like an Elasticsearch response, filter it out
      # Remove Elasticsearch response lines
      lines = error_content.split("\n").reject do |line|
        line.match?(/\{"_index":|"_id":|"_version":|"result":"updated"|"_shards":|"_seq_no":|"_primary_term":/)
      end
      error_content = lines.join("\n")
    end
    
    # If after filtering we have no content, return nil
    return nil if error_content.strip.empty?
    
    # First, look for docker errors (common issue)
    if error_content.match?(/docker:.*no such file/i)
      if match = error_content.match(/docker:.*?([^:]+):\s*no such file[^\n]*/i)
        return "Docker error: #{match[1].strip}: no such file or directory"
      end
    end
    
    # Look for "bin/rails aborted!" followed by error message
    if error_content.include?('bin/rails aborted!')
      lines = error_content.split("\n")
      aborted_index = lines.index { |line| line.include?('bin/rails aborted!') }
      if aborted_index
        # Get the error message line (usually right after "aborted!")
        error_line = lines[aborted_index + 1]
        if error_line && error_line.strip.present?
          error_msg = error_line.strip
          # If it's an Errno::ENOENT, extract the file path
          if error_msg.match?(/Errno::ENOENT.*@ rb_sysopen - (.+)/)
            file_path = $1
            return "File not found: #{file_path}"
          end
          return error_msg.length > 500 ? error_msg[0..500] + "..." : error_msg
        end
      end
    end
    
    # Extract the most relevant error message
    # Look for lines with "Error:", "aborted!", or exception messages
    # But exclude Elasticsearch patterns
    error_lines = error_content.split("\n").select do |line|
      line.match?(/Error:|aborted!|NameError|NoMethodError|Errno::|No such file|failed|docker:/i) &&
      !line.match?(/warning:/i) && # Skip warnings
      !line.match?(/\{"_index":|"_id":|"_version":|"result":"updated"/) # Skip Elasticsearch responses
    end
    
    if error_lines.any?
      # Get the last meaningful error line (usually the actual error)
      error_line = error_lines.last
      # Clean up the error message
      error_line = error_line.strip
      # If it's very long, truncate it but keep the important part
      if error_line.length > 500
        error_line = error_line[0..500] + "..."
      end
      return error_line
    end
    
    # Fallback: return a summary if no specific error line found
    if error_content.include?('aborted!')
      # Try to extract the error type and message after "aborted!"
      if match = error_content.match(/aborted!\s*(.+?)(?:\n|$)/)
        return "Error: #{match[1].strip}"
      end
    end
    
    nil
  end

  def finish_run_successfully(run, slurm_service, slurm_job_id)
    # Don't re-process runs that are already marked as complete
    if run.status_id == 3
      Rails.logger.info("[SlurmJobMonitorJob] Run##{run.id} already marked as complete, skipping")
      return
    end
    
    project = run.project
    step = run.step
    
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name
    output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    
    output_json_filename = output_dir + 'output.json'
    
    h_results = {}
    if run.return_stdout == true
      output_file = output_dir + "slurm_#{run.id}.out"
      if File.exist?(output_file)
        output_content = File.read(output_file)
        h_results = Basic.safe_parse_json(output_content, {})
      end
    elsif File.exist?(output_json_filename)
      h_results = Basic.safe_parse_json(File.read(output_json_filename), {})
    end

    job_info = slurm_service.get_job_info(slurm_job_id)
    if job_info
      if job_info[:max_rss] && job_info[:max_rss] != 'N/A'
        max_rss_mb = parse_memory(job_info[:max_rss])
        run.update(max_ram: max_rss_mb) if max_rss_mb
      end
      
      if job_info[:elapsed] && job_info[:elapsed] != 'N/A'
        duration_seconds = parse_duration(job_info[:elapsed])
        run.update(duration: duration_seconds) if duration_seconds
      end
    end

    if h_results.is_a?(Hash) && h_results.keys.size > 0
      # Check if the results contain a displayed_error - this means parsing failed
      if h_results['displayed_error'].present?
        error_msg = if h_results['displayed_error'].is_a?(Array)
          h_results['displayed_error'].join('; ')
        else
          h_results['displayed_error'].to_s
        end
        Rails.logger.warn("[SlurmJobMonitorJob] Run##{run.id} has displayed_error in output.json: #{error_msg}")
        finish_run_with_error(run, error_msg)
        return
      end
      
      # If no displayed_error, proceed with successful completion
      Basic.finish_run(Rails.logger, run, h_results)
    else
      Rails.logger.warn("[SlurmJobMonitorJob] No valid results found for Run##{run.id}, marking as failed")
      finish_run_with_error(run, "No output.json found or invalid output")
    end
  end

  def finish_run_with_error(run, error_message)
    # Don't mark as failed if the run is already complete and has valid output
    if run.status_id == 3
      project = run.project
      step = run.step
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      step_dir = project_dir + step.name
      output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
      output_json_filename = output_dir + 'output.json'
      
      # If output.json exists, the run was successful - don't mark as failed
      if File.exist?(output_json_filename)
        Rails.logger.info("[SlurmJobMonitorJob] Run##{run.id} already complete with output.json, ignoring error message")
        return
      end
    end
    
    project = run.project
    step = run.step
    
    run.update(
      status_id: 4,
      error: error_message
    )
    
    project_step = ProjectStep.where(project_id: project.id, step_id: step.id).first
    if project_step
      # Don't overwrite a complete status with failed if output.json exists
      if project_step.status_id == 3
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
        step_dir = project_dir + step.name
        output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
        output_json_filename = output_dir + 'output.json'
        
        if File.exist?(output_json_filename)
          Rails.logger.info("[SlurmJobMonitorJob] ProjectStep already complete with output.json, not marking as failed")
          return
        end
      end
      
      project_step.update(
        status_id: 4,
        error_message: error_message
      )
    end
    
    project.update(status_id: 4) if project
    project.broadcast(step.id) if project.respond_to?(:broadcast)
  end

  def parse_memory(memory_string)
    return nil if memory_string.blank? || memory_string == 'N/A'
    
    if memory_string.match(/^(\d+(?:\.\d+)?)K$/i)
      $1.to_f / 1024.0
    elsif memory_string.match(/^(\d+(?:\.\d+)?)M$/i)
      $1.to_f
    elsif memory_string.match(/^(\d+(?:\.\d+)?)G$/i)
      $1.to_f * 1024.0
    elsif memory_string.match(/^(\d+(?:\.\d+)?)$/)
      $1.to_f / (1024.0 * 1024.0)
    else
      nil
    end
  end

  def parse_duration(duration_string)
    return nil if duration_string.blank? || duration_string == 'N/A'
    
    parts = duration_string.split(':')
    if parts.size == 3
      hours = parts[0].to_i
      minutes = parts[1].to_i
      seconds = parts[2].to_i
      hours * 3600 + minutes * 60 + seconds
    else
      nil
    end
  end
end

