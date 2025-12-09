class RunExecutionJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    Rails.logger.info("[RunExecutionJob] Starting execution for Run##{run_id}")
    
    run = Run.find_by(id: run_id)
    unless run
      Rails.logger.error("[RunExecutionJob] Run with ID #{run_id} not found")
      return
    end

    if run.status_id != 1
      Rails.logger.warn("[RunExecutionJob] Run##{run_id} is not in waiting status (current: #{run.status_id})")
      return
    end

    begin
      slurm_service = SlurmService.new(logger: Rails.logger)
      
      project = run.project
      version = project.version
      step = run.step
      
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      step_dir = project_dir + step.name
      FileUtils.mkdir_p(step_dir) unless File.exist?(step_dir)
      output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
      FileUtils.mkdir_p(output_dir) unless File.exist?(output_dir)
      
      h_cmd = Basic.safe_parse_json(run.command_json, {})
      if h_cmd.empty?
        raise StandardError, "Invalid command_json for Run##{run_id}"
      end
      
      core_cmd = build_core_command(h_cmd)
      docker_cmd = Basic.build_docker_cmd(h_cmd, core_cmd)
      
      Rails.logger.info("[RunExecutionJob] Submitting Run##{run_id} to SLURM")
      Rails.logger.debug("[RunExecutionJob] Command: #{docker_cmd}")
      
      slurm_job_id = slurm_service.submit_job(
        run,
        docker_cmd,
        cores: run.nber_cores,
        memory_mb: run.pred_max_ram || run.max_ram,
        time_limit: run.pred_process_duration
      )
      
      start_time = Time.now
      
      run.update(
        status_id: 2,
        start_time: start_time,
        waiting_duration: start_time - (run.submitted_at || run.created_at),
        pid: slurm_job_id.to_i,
        slurm_job_id: slurm_job_id.to_i
      )
      
      project.broadcast(step.id) if project.respond_to?(:broadcast)
      
      Rails.logger.info("[RunExecutionJob] Run##{run_id} submitted to SLURM with job ID: #{slurm_job_id}")
      
      SlurmJobMonitorJob.set(wait: 30.seconds).perform_later(run_id, slurm_job_id)
      
    rescue StandardError => e
      Rails.logger.error("[RunExecutionJob] Error executing Run##{run_id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      
      run.update(
        status_id: 4,
        error: e.message
      )
      
      project_step = ProjectStep.where(project_id: project.id, step_id: step.id).first
      if project_step
        project_step.update(
          status_id: 4,
          error_message: e.message
        )
      end
      
      project.update(status_id: 4) if project
      project.broadcast(step.id) if project.respond_to?(:broadcast)
      
      raise e
    end
  end

  private

  def build_core_command(h_cmd)
    h_cmd['opts'] ||= []
    h_cmd['args'] ||= []
    
    cmd_parts = [
      h_cmd['program'],
      h_cmd['opts'].map { |e| "#{e['opt']} #{Basic.safe_cmdline_param(e['value'])}" }.join(" "),
      h_cmd['args'].map { |e| Basic.safe_cmdline_param(e['value']) }.join(" "),
      (h_cmd['exec_stdout']) ? "1> #{h_cmd['exec_stdout']}" : nil,
      (h_cmd['exec_stderr']) ? "2> #{h_cmd['exec_stderr']}" : nil
    ]
    
    cmd = "sh -c '" + cmd_parts.compact.join(" ") + "'"
    
    if h_cmd['time_call']
      cmd = [h_cmd['time_call'], cmd].join(" ")
    end
    
    cmd
  end
end

