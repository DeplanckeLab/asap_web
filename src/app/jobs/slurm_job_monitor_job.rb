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
      status = slurm_service.get_job_status(slurm_job_id)
      
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
        finish_run_with_error(run, "SLURM job finished with status: #{status}")

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

  def finish_run_successfully(run, slurm_service, slurm_job_id)
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
      Basic.finish_run(Rails.logger, run, h_results)
    else
      Rails.logger.warn("[SlurmJobMonitorJob] No valid results found for Run##{run.id}, marking as failed")
      finish_run_with_error(run, "No output.json found or invalid output")
    end
  end

  def finish_run_with_error(run, error_message)
    project = run.project
    step = run.step
    
    run.update(
      status_id: 4,
      error: error_message
    )
    
    project_step = ProjectStep.where(project_id: project.id, step_id: step.id).first
    if project_step
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

