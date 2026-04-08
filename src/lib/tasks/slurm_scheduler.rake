namespace :slurm do
  # Helper method to resubmit parsing runs
  def resubmit_parsing_run(run, logger)
    project = run.project
    step = run.step
    
    logger.info("[SlurmResubmit] Resubmitting parsing Run##{run.id} for Project##{project.id}")
    
    # Build command to run in Rails environment (same as ProjectParsingJob)
    rails_root = Rails.root.to_s
    rails_env = Rails.env
    parse_cmd = "cd #{rails_root} && RAILS_ENV=#{rails_env} bundle exec rails parse[#{project.key}]"
    
    logger.info("[SlurmResubmit] Command: #{parse_cmd}")
    
    # Submit to SLURM
    slurm_service = SlurmService.new(logger: logger)
    slurm_job_id = slurm_service.submit_job(
      run,
      parse_cmd,
      cores: run.nber_cores || 1,
      memory_mb: (run.pred_max_ram.present? ? (run.pred_max_ram.to_f / 1024.0).ceil : (run.max_ram || 4096)),
      time_limit: run.pred_process_duration || 3600
    )
    
    # Set submitted_at NOW - when the job is actually submitted to SLURM queue
    submitted_at = Time.now
    
    logger.info("[SlurmResubmit] Job resubmitted to SLURM queue:")
    logger.info("[SlurmResubmit]   Run ID: #{run.id}")
    logger.info("[SlurmResubmit]   SLURM Job ID: #{slurm_job_id}")
    logger.info("[SlurmResubmit]   Submitted at: #{submitted_at.strftime('%Y-%m-%d %H:%M:%S.%3N')}")
    
    # Update run with SLURM job ID and submitted_at
    run.update(
      status_id: 1, # 1 = waiting (job is queued, not running yet)
      submitted_at: submitted_at,
      pid: slurm_job_id.to_i,
      slurm_job_id: slurm_job_id.to_i
    )
    
    # Recompute project step counters/status after transitioning run to waiting.
    Basic.upd_project_step(project, step.id)
    project_step = ProjectStep.find_by(project_id: project.id, step_id: step.id)
    if project_step && project_step.status_id != 1
      project_step.update(status_id: 1)
    end
    
    # Update project status to waiting if needed
    if project.status_id != 1
      project.update(status_id: 1)
    end
    
    # Broadcast update to show job is queued
    project.broadcast(step.id) if project.respond_to?(:broadcast)
    
    # Start monitoring the SLURM job
    SlurmJobMonitorJob.set(wait: 30.seconds).perform_later(run.id, slurm_job_id)
    
    logger.info("[SlurmResubmit] Parsing Run##{run.id} resubmitted successfully with SLURM Job ID: #{slurm_job_id}")
  end

  desc "Process waiting runs and submit them to SLURM"
  task process_waiting_runs: :environment do
    logger = Rails.logger
    logger.info("[SlurmScheduler] Starting to process waiting runs")
    
    waiting_runs = Run.where(status_id: 1).order(:created_at).limit(10)
    
    if waiting_runs.empty?
      logger.debug("[SlurmScheduler] No waiting runs found")
      exit 0
    end
    
    logger.info("[SlurmScheduler] Found #{waiting_runs.count} waiting runs")
    
    waiting_runs.each do |run|
      begin
        logger.info("[SlurmScheduler] Processing Run##{run.id}")
        RunExecutionJob.perform_later(run.id)
      rescue StandardError => e
        logger.error("[SlurmScheduler] Error processing Run##{run.id}: #{e.class} - #{e.message}")
        logger.error(e.backtrace.join("\n")) if e.backtrace
      end
    end
    
    logger.info("[SlurmScheduler] Finished processing waiting runs")
  end

  desc "Monitor SLURM jobs and update run statuses (async handoff to SlurmJobMonitorJob)"
  task monitor_jobs: :environment do
    logger = Rails.logger
    logger.info("[SlurmMonitor] Starting to monitor SLURM jobs")
    puts "[slurm:monitor_jobs] Starting"

    running_runs = Run.where(status_id: 2)

    if running_runs.empty?
      msg = "[SlurmMonitor] No runs with status_id=2 (running)"
      logger.info(msg)
      puts msg
      exit 0
    end

    logger.info("[SlurmMonitor] Found #{running_runs.count} runs in running state")
    puts "[slurm:monitor_jobs] Checking #{running_runs.count} run(s) with status_id=2"

    slurm_service = SlurmService.new(logger: logger)

    running_runs.each do |run|
      begin
        slurm_job_id = (run.slurm_job_id || run.pid).to_s
        if slurm_job_id.blank? || slurm_job_id == '0'
          warn_msg = "[SlurmMonitor] Run##{run.id} has no slurm_job_id/pid; cannot query SLURM. Fix manually or set id from logs."
          logger.warn(warn_msg)
          puts warn_msg
          next
        end

        status = slurm_service.get_job_status(slurm_job_id, run)
        logger.info("[SlurmMonitor] Run##{run.id} SLURM job #{slurm_job_id} status=#{status.inspect}")

        if status.nil?
          # Lost job id / purged history / ambiguous: full logic lives in SlurmJobMonitorJob (output.json, exec.out, fail after max attempts).
          logger.warn("[SlurmMonitor] Run##{run.id} ambiguous SLURM status (nil); handing off to SlurmJobMonitorJob")
          puts "[slurm:monitor_jobs] Run #{run.id} job #{slurm_job_id}: status unknown (nil) -> SlurmJobMonitorJob"
          SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
          next
        end

        case status
        when :pending, :running
          logger.debug("[SlurmMonitor] Run##{run.id} still #{status}")
          puts "[slurm:monitor_jobs] Run #{run.id}: still #{status} in SLURM"
        when :completed
          logger.info("[SlurmMonitor] Run##{run.id} completed, triggering finish")
          puts "[slurm:monitor_jobs] Run #{run.id}: completed -> SlurmJobMonitorJob"
          SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
        when :failed, :timeout, :node_fail, :cancelled
          logger.warn("[SlurmMonitor] Run##{run.id} finished with status: #{status}")
          puts "[slurm:monitor_jobs] Run #{run.id}: #{status} -> SlurmJobMonitorJob"
          SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
        when :invalid_job, :accounting_unavailable
          logger.warn("[SlurmMonitor] Run##{run.id} SLURM job #{slurm_job_id} status=#{status}, reconciling via SlurmJobMonitorJob")
          puts "[slurm:monitor_jobs] Run #{run.id}: #{status} -> SlurmJobMonitorJob"
          SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
        else
          logger.warn("[SlurmMonitor] Run##{run.id} has unknown status: #{status}, handing off")
          puts "[slurm:monitor_jobs] Run #{run.id}: unknown #{status} -> SlurmJobMonitorJob"
          SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
        end
      rescue StandardError => e
        logger.error("[SlurmMonitor] Error checking Run##{run.id}: #{e.class} - #{e.message}")
        logger.error(e.backtrace.join("\n")) if e.backtrace
        puts "[slurm:monitor_jobs] ERROR Run #{run.id}: #{e.class} #{e.message}"
      end
    end

    done = "[SlurmMonitor] Finished monitoring SLURM jobs"
    logger.info(done)
    puts done
  end

  desc "Reconcile runs stuck in running state when SLURM lost the job (e.g. slurmctld restart). Runs SlurmJobMonitorJob synchronously per run."
  task reconcile_stale_running: :environment do
    logger = Rails.logger
    puts "[slurm:reconcile_stale_running] Starting (perform_now per run)"

    scope = Run.where(status_id: 2)
    ids = ENV['RUN_IDS'].to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
    scope = scope.where(id: ids) if ids.any?

    runs = scope.order(:id)
    if runs.empty?
      puts "[slurm:reconcile_stale_running] No runs with status_id=2#{ids.any? ? " for RUN_IDS=#{ids.join(',')}" : ''}"
      exit 0
    end

    puts "[slurm:reconcile_stale_running] Processing #{runs.size} run(s)"

    runs.each do |run|
      slurm_job_id = (run.slurm_job_id || run.pid).to_s
      if slurm_job_id.blank? || slurm_job_id == '0'
        puts "[slurm:reconcile_stale_running] SKIP Run #{run.id}: missing slurm_job_id and pid"
        next
      end

      begin
        puts "[slurm:reconcile_stale_running] Run #{run.id} SLURM job #{slurm_job_id} perform_now ..."
        SlurmJobMonitorJob.perform_now(run.id, slurm_job_id)
        run.reload
        puts "[slurm:reconcile_stale_running] Run #{run.id} -> status_id=#{run.status_id}"
      rescue StandardError => e
        puts "[slurm:reconcile_stale_running] ERROR Run #{run.id}: #{e.class} #{e.message}"
        logger.error("[reconcile_stale_running] Run##{run.id}: #{e.class} #{e.message}\n#{e.backtrace&.join("\n")}")
      end
    end

    puts "[slurm:reconcile_stale_running] Done"
  end

  desc "Resubmit runs that failed to submit to SLURM (no slurm_job_id)"
  task resubmit_failed: :environment do
    logger = Rails.logger
    logger.info("[SlurmResubmit] Starting to resubmit failed runs")
    
    # Find runs that are waiting but don't have a slurm_job_id
    # These are runs that were created but failed to submit to SLURM
    failed_runs = Run.where(status_id: 1)
                     .where("slurm_job_id IS NULL OR slurm_job_id = 0")
                     .order(:created_at)
    
    if failed_runs.empty?
      logger.info("[SlurmResubmit] No failed runs found")
      exit 0
    end
    
    logger.info("[SlurmResubmit] Found #{failed_runs.count} runs that failed to submit to SLURM")
    
    failed_runs.each do |run|
      begin
        logger.info("[SlurmResubmit] Processing Run##{run.id} (step: #{run.step&.name || 'unknown'})")
        
        # Check if this is a parsing run
        if run.step&.name == 'parsing'
          # For parsing runs, resubmit using the same logic as ProjectParsingJob
          resubmit_parsing_run(run, logger)
        else
          # For other runs, use RunExecutionJob
          logger.info("[SlurmResubmit] Resubmitting Run##{run.id} via RunExecutionJob")
          RunExecutionJob.perform_later(run.id)
        end
      rescue StandardError => e
        logger.error("[SlurmResubmit] Error resubmitting Run##{run.id}: #{e.class} - #{e.message}")
        logger.error(e.backtrace.join("\n")) if e.backtrace
      end
    end
    
    logger.info("[SlurmResubmit] Finished resubmitting failed runs")
  end

  desc "Start continuous scheduler (runs every 30 seconds)"
  task start_scheduler: :environment do
    logger = Rails.logger
    logger.info("[SlurmScheduler] Starting continuous scheduler")
    
    loop do
      begin
        Rake::Task["slurm:process_waiting_runs"].invoke
        Rake::Task["slurm:monitor_jobs"].invoke
        Rake::Task["slurm:process_waiting_runs"].reenable
        Rake::Task["slurm:monitor_jobs"].reenable
      rescue StandardError => e
        logger.error("[SlurmScheduler] Error in scheduler loop: #{e.class} - #{e.message}")
        logger.error(e.backtrace.join("\n")) if e.backtrace
      end
      
      sleep 30
    end
  end
end

