namespace :slurm do
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

  desc "Monitor SLURM jobs and update run statuses"
  task monitor_jobs: :environment do
    logger = Rails.logger
    logger.info("[SlurmMonitor] Starting to monitor SLURM jobs")
    
    running_runs = Run.where(status_id: 2).where.not(pid: nil)
    
    if running_runs.empty?
      logger.debug("[SlurmMonitor] No running runs found")
      exit 0
    end
    
    logger.info("[SlurmMonitor] Found #{running_runs.count} running runs to check")
    
    slurm_service = SlurmService.new(logger: logger)
    
    running_runs.each do |run|
      begin
        slurm_job_id = (run.slurm_job_id || run.pid).to_s
        next if slurm_job_id.blank? || slurm_job_id == '0'
        
        status = slurm_service.get_job_status(slurm_job_id)
        
        if status.nil?
          logger.warn("[SlurmMonitor] Could not get status for Run##{run.id}, SLURM Job##{slurm_job_id}")
          next
        end
        
        case status
        when :pending, :running
          logger.debug("[SlurmMonitor] Run##{run.id} still #{status}")
        when :completed
          logger.info("[SlurmMonitor] Run##{run.id} completed, triggering finish")
          SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
        when :failed, :timeout, :node_fail, :cancelled
          logger.warn("[SlurmMonitor] Run##{run.id} finished with status: #{status}")
          SlurmJobMonitorJob.perform_later(run.id, slurm_job_id)
        else
          logger.warn("[SlurmMonitor] Run##{run.id} has unknown status: #{status}")
        end
      rescue StandardError => e
        logger.error("[SlurmMonitor] Error checking Run##{run.id}: #{e.class} - #{e.message}")
        logger.error(e.backtrace.join("\n")) if e.backtrace
      end
    end
    
    logger.info("[SlurmMonitor] Finished monitoring SLURM jobs")
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

