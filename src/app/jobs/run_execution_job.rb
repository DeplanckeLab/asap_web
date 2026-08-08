class RunExecutionJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    Rails.logger.info("[RunExecutionJob] Starting execution for Run##{run_id}")
    
    run = Run.find_by(id: run_id)
    unless run
      Rails.logger.error("[RunExecutionJob] Run with ID #{run_id} not found")
      return
    end

    unless [1, 6].include?(run.status_id.to_i)
      Rails.logger.warn("[RunExecutionJob] Run##{run_id} is not in schedulable status (current: #{run.status_id})")
      return
    end

    begin
      project = run.project
      version = project.version
      step = run.step
      
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      step_dir = project_dir + step.name
      FileUtils.mkdir_p(step_dir) unless File.exist?(step_dir)
      output_dir = Basic.run_output_dir(run)
      FileUtils.mkdir_p(output_dir) unless File.exist?(output_dir)
      Basic.clear_step_run_output_files!(run, logger: Rails.logger)
      
      h_cmd = Basic.safe_parse_json(run.command_json, {})
      if h_cmd.empty?
        raise StandardError, "Invalid command_json for Run##{run_id}"
      end
      
      core_cmd = build_core_command(h_cmd)
      docker_cmd = Basic.build_docker_cmd(h_cmd, core_cmd)
      Rails.logger.info("[RunExecutionJob] Resolved docker command for Run##{run.id}: #{docker_cmd}")
      
      if slurm_available?
        execute_via_slurm(run, project, step, docker_cmd)
      else
        raise StandardError, "SLURM controller unavailable for Run##{run_id}; run submission aborted."
      end
      
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

      # Update project_step run counts so UI can display failed status correctly
      Basic.upd_project_step(project, step.id) if project_step

      project.update(status_id: 4) if project
      run.reload.broadcast_status_change

      raise e
    end
  end

  private

  def slurm_available?
    # `scontrol ping` can report false DOWN in some container/client setups.
    # Use a controller-backed read query instead.
    result = `sinfo -h -o '%P' 2>&1`
    $?.success? && result.present? && !result.downcase.include?('error')
  rescue
    false
  end

  def execute_via_slurm(run, project, step, docker_cmd)
    slurm_service = SlurmService.new(logger: Rails.logger)

    Rails.logger.info("[RunExecutionJob] Submitting Run##{run.id} to SLURM")
    
    # Do not pass memory_mb here: SlurmService sets --mem only from pred_max_ram.
    # Passing max_ram would constrain jobs that have no prediction model yet.
    slurm_job_id = slurm_service.submit_job(
      run,
      docker_cmd,
      cores: run.nber_cores,
      time_limit: run.pred_process_duration
    )

    # After sbatch returns, the SLURM job is queued (pending), not running yet.
    # Keep the Run in waiting (status_id: 1) so the UI reflects reality; the
    # SlurmJobMonitorJob will flip it to running once SLURM actually starts it.
    # This avoids a running -> waiting -> running flicker in the left/right
    # panels and header.
    run.update(
      status_id: 1,
      start_time: nil,
      waiting_duration: nil,
      pid: slurm_job_id.to_i,
      slurm_job_id: slurm_job_id.to_i
    )

    # Update project_step run counts so header reflects the queued run.
    Basic.upd_project_step(project, step.id)
    # Do not bump project.status_id to running here: the run is merely queued
    # in SLURM at this point. SlurmJobMonitorJob will promote to running when
    # SLURM reports the job has actually started.
    run.reload.broadcast_status_change

    Rails.logger.info("[RunExecutionJob] Run##{run.id} submitted to SLURM with job ID: #{slurm_job_id} (status=waiting)")

    # Start monitoring immediately so failures are surfaced even if delayed
    # in-process jobs are dropped during app restarts.
    SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
  end

  def execute_directly(run, project, step, h_cmd)
    start_time = Time.now

    run.update(
      status_id: 2,
      start_time: start_time,
      waiting_duration: start_time - (run.submitted_at || run.created_at)
    )

    # Update project_step nber_runs_json so header shows correct running count
    Basic.upd_project_step(project, step.id)
    project.update(status_id: 2)
    run.reload.broadcast_status_change

    # Build the full command via Basic.build_cmd (handles rails prefix, docker wrapping, etc.)
    cmd = Basic.build_cmd(h_cmd)
    Rails.logger.info("[RunExecutionJob] Direct execution for Run##{run.id}: #{cmd}")

    pid = spawn(cmd)
    Rails.logger.info("[RunExecutionJob] Run##{run.id} started with PID #{pid}")

    run.update(pid: pid)

    # Wait for completion in a separate thread so this job can finish
    Thread.new do
      Rails.application.executor.wrap do
        begin
          _pid, status = Process.waitpid2(pid)
          end_time = Time.now
          process_duration = (end_time - start_time).to_f

          # Read output.json if available
          project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
          step_dir = project_dir + step.name
          output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
          output_json = output_dir + 'output.json'

          h_results = {}
          if File.exist?(output_json)
            h_results = Basic.safe_parse_json(File.read(output_json), {})
          end

          if status.success?
            Rails.logger.info("[RunExecutionJob] Run##{run.id} completed successfully in #{process_duration}s")
            Basic.finish_run(Rails.logger, run, h_results)
          else
            Rails.logger.error("[RunExecutionJob] Run##{run.id} failed with exit code #{status.exitstatus}")
            h_results['displayed_error'] ||= ["Process exited with code #{status.exitstatus}"]
            Basic.finish_run(Rails.logger, run, h_results)
          end
        rescue => e
          Rails.logger.error("[RunExecutionJob] Error monitoring Run##{run.id}: #{e.class} - #{e.message}")
          run.reload
          run.update(status_id: 4, error: e.message)
          Basic.upd_project_step(project, step.id)
          project.update(status_id: 4)
          run.reload.broadcast_status_change
        end
      end
    end
  end

  def build_core_command(h_cmd)
    Basic.build_run_core_command(h_cmd)
  end
end

