class SlurmJobMonitorJob < ApplicationJob
  queue_as :default

  MAX_MONITOR_ATTEMPTS = 480
  MONITOR_INTERVAL = 30.seconds
  ACCOUNTING_UNAVAILABLE_GRACE_ATTEMPTS = 6

  # While a SLURM job is still pending in the queue (just submitted by sbatch),
  # poll aggressively so the UI reflects the waiting -> running transition
  # within a few seconds instead of up to 30s. Once the job is running or the
  # pending phase drags on, fall back to MONITOR_INTERVAL.
  PENDING_POLL_INTERVALS = [2.seconds, 4.seconds, 8.seconds, 15.seconds, MONITOR_INTERVAL].freeze

  def perform(run_id, slurm_job_id, attempt = 1)
    Rails.logger.debug("[SlurmJobMonitorJob] Checking Run##{run_id}, SLURM Job##{slurm_job_id}, attempt #{attempt}")
    
    run = Run.find_by(id: run_id)
    unless run
      Rails.logger.error("[SlurmJobMonitorJob] Run##{run_id} not found")
      return
    end

    # Stop monitoring if run is already complete or failed
    # BUT: if complete and has no annotations, we need to call finish_run to create them
    if run.status_id == 3
      annot_count = Annot.where(run_id: run.id).count
      if annot_count == 0
        Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} is complete (status_id=3) but has NO annotations (#{annot_count}). Calling finish_run_successfully to create annotations.")
        slurm_service = SlurmService.new(logger: Rails.logger)
        finish_run_successfully(run, slurm_service, slurm_job_id)
      elsif output_json_fresh_for_run?(run) && Basic.sync_run_annots_from_output_json!(Rails.logger, run)
        Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} synced annot dimensions from fresh output.json")
      else
        Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} already marked as complete with #{annot_count} annotations, stopping monitoring")
      end
      return
    end

    if run.status_id == 4
      Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} already marked as failed, stopping monitoring")
      return
    end

    # A run can be resubmitted while old monitor jobs are still queued.
    # Always follow the current SLURM job id stored on the run to avoid
    # polling a stale job id and leaving the run "running" indefinitely.
    current_slurm_job_id = run.slurm_job_id.presence
    if current_slurm_job_id && slurm_job_id.to_s != current_slurm_job_id.to_s
      Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} monitor job id mismatch: queued=#{slurm_job_id} current=#{current_slurm_job_id}. Switching to current job id.")
      slurm_job_id = current_slurm_job_id.to_s
    end

    begin
      slurm_service = SlurmService.new(logger: Rails.logger)
      status = slurm_service.get_job_status(slurm_job_id, run)
      
      if status.nil?
        # If we can't get status from SLURM, check if the run has completed successfully
        # by checking for output.json (this handles cases where SLURM job history is purged)
        project = run.project
        step = run.step
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
        step_dir = project_dir + step.name
        output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
        output_json_filename = output_dir + 'output.json'
        
        if output_json_fresh_for_run?(run, output_json_filename)
          # Output.json exists for this run - check if run is already complete or needs to be finished
          annot_count = Annot.where(run_id: run.id).count
          if run.status_id != 3
            Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} has fresh output.json but not marked complete, finishing run")
            finish_run_successfully(run, slurm_service, slurm_job_id)
          elsif annot_count == 0
            Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} already complete but has NO annotations (#{annot_count}). Will call finish_run_successfully to create annotations.")
            finish_run_successfully(run, slurm_service, slurm_job_id)
          else
            Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} already complete with output.json and #{annot_count} annotations, stopping monitoring")
          end
          return
        end
        
        # No output.json - check exec.out for displayed_error (indicates job failed)
        exec_out = output_dir + 'exec.out'
        exec_run_details = output_dir + 'exec_run_details.log'
        # When SLURM history is gone (restart, purged id), status is nil; logs may be older than 1 hour.
        exec_mtime_cutoff = attempt >= 2 ? 365.days.ago : 30.days.ago
        
        if File.exist?(exec_out) && File.mtime(exec_out) > exec_mtime_cutoff
          begin
            exec_content = File.read(exec_out)
            exec_json = JSON.parse(exec_content)
            if exec_json.is_a?(Hash) && exec_json['displayed_error'].present?
              error_msg = if exec_json['displayed_error'].is_a?(Array)
                exec_json['displayed_error'].join('; ')
              else
                exec_json['displayed_error'].to_s
              end
              Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} has displayed_error in exec.out: #{error_msg}")
              
              # Create output.json with the error so it's available for the UI
              unless File.exist?(output_json_filename)
                Rails.logger.info("[SlurmJobMonitorJob] Creating output.json with displayed_error for Run##{run_id}")
                File.open(output_json_filename, 'w') do |f|
                  f.write(exec_json.to_json)
                end
              end
              
              # Mark run as failed - no need to run full finish_run processing for early failures
              finish_run_with_error(run, error_msg)
              return
            end
          rescue JSON::ParserError
            # Not JSON, continue checking
          end
        end
        
        # Check exec_run_details.log for exit code
        if File.exist?(exec_run_details) && File.mtime(exec_run_details) > exec_mtime_cutoff
          details_content = File.read(exec_run_details)
          if details_content.include?('Command exited with non-zero status')
            error_msg = extract_error_message(run) || "Job exited with non-zero status (see exec.err or exec.out for details)"
            Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} exited with non-zero status")
            
            # Create output.json with displayed_error if it doesn't exist
            unless File.exist?(output_json_filename)
              # Try to get error from exec.out first (might have displayed_error JSON)
              if File.exist?(exec_out) && File.mtime(exec_out) > exec_mtime_cutoff
                begin
                  exec_content = File.read(exec_out)
                  exec_json = JSON.parse(exec_content)
                  if exec_json.is_a?(Hash) && exec_json['displayed_error'].present?
                    Rails.logger.info("[SlurmJobMonitorJob] Creating output.json with displayed_error from exec.out for Run##{run_id}")
                    error_msg = if exec_json['displayed_error'].is_a?(Array)
                      exec_json['displayed_error'].join('; ')
                    else
                      exec_json['displayed_error'].to_s
                    end
                    File.open(output_json_filename, 'w') do |f|
                      f.write(exec_json.to_json)
                    end
                    # Mark run as failed - no need to run full finish_run processing for early failures
                    finish_run_with_error(run, error_msg)
                    return
                  end
                rescue JSON::ParserError
                  # Not JSON, create output.json with generic error
                end
              end
              
              # Create output.json with error message
              Rails.logger.info("[SlurmJobMonitorJob] Creating output.json with error message for Run##{run_id}")
              h_error = { 'displayed_error' => error_msg }
              File.open(output_json_filename, 'w') do |f|
                f.write(h_error.to_json)
              end
              
              # Mark run as failed - no need to run full finish_run processing for early failures
              finish_run_with_error(run, error_msg)
            else
              # output.json already exists, just mark as failed directly
              finish_run_with_error(run, error_msg)
            end
            return
          end
        end
        
        # No output.json - job might still be running or failed
        Rails.logger.warn("[SlurmJobMonitorJob] Could not get status for SLURM job #{slurm_job_id}, will retry")
        if attempt < MAX_MONITOR_ATTEMPTS
          SlurmJobMonitorJob.set(wait: MONITOR_INTERVAL).perform_later(run_id, slurm_job_id, attempt + 1)
        else
          # Before marking as failed, double-check if output.json exists (might have been created between attempts)
          if output_json_fresh_for_run?(run, output_json_filename)
            Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} has fresh output.json after max attempts, finishing run successfully")
            finish_run_successfully(run, slurm_service, slurm_job_id)
          else
            # Also check ProjectStep status - if it's already complete, don't mark as failed
            project_step = ProjectStep.where(project_id: project.id, step_id: step.id).first
            if project_step && project_step.status_id == 3
              Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} ProjectStep already complete, stopping monitoring without marking run as failed")
              return
            end
            Rails.logger.error("[SlurmJobMonitorJob] Max attempts reached for Run##{run_id}, marking as failed")
            finish_run_with_error(run, "SLURM job status could not be determined after #{MAX_MONITOR_ATTEMPTS} attempts")
          end
        end
        return
      end

      case status
      when :pending, :running
        project = run.project
        step = run.step
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
        step_dir = project_dir + step.name
        output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
        output_json_filename = output_dir + 'output.json'
        
        # First, update status to running if SLURM reports running and run is still waiting or scheduler-submitted (6).
        # This ensures the running status is set before checking for output.json
        if status == :running && [1, 6].include?(run.status_id)
          Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} SLURM reports running, updating status from waiting/submitted to running")
          broadcast_queue_position_cleared(run)

          # Calculate waiting_duration from submitted_at to now
          start_time = Time.now
          waiting_duration = run.submitted_at ? (start_time - run.submitted_at).to_f : nil

          update_hash = { status_id: 2, start_time: start_time }
          update_hash[:waiting_duration] = waiting_duration if waiting_duration

          run.update(update_hash) unless run.start_time

          Basic.upd_project_step(project, step.id)
          project_step = ProjectStep.where(project_id: project.id, step_id: step.id).first
          project_step.update(status_id: 2) if project_step && project_step.status_id != 2

          project.update(status_id: 2) if project.status_id != 2

          run.reload.broadcast_status_change
          broadcast_markers_run_status_changed_from_monitor(project, step, run)
        end

        # DB said "running" but SLURM still has the job in the queue (pending). Typical after slurmctld
        # restart or if status was advanced too early. Align DB with SLURM so the UI shows queued, not running.
        if status == :pending && run.status_id == 2
          Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} was running in DB but SLURM job #{slurm_job_id} is pending; correcting run to waiting (queued)")
          run.update(status_id: 1, start_time: nil)
          broadcast_queue_position_cleared(run)
          Basic.upd_project_step(project, step.id)
          project.reload
          run.reload.broadcast_status_change
        end

        # While waiting in queue, push queue position updates via websocket.
        if status == :pending && [1, 6].include?(run.status_id)
          broadcast_queue_position_if_changed(run, slurm_service)
        end
        
        # Then check if output.json was written for this run (shared step dirs keep stale files from prior runs)
        if output_json_fresh_for_run?(run, output_json_filename)
          annot_count = Annot.where(run_id: run.id).count
          if run.status_id != 3
            Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} has fresh output.json but run status is #{run.status_id}, finishing run")
            finish_run_successfully(run, slurm_service, slurm_job_id)
          elsif annot_count == 0
            Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} already marked as complete but has NO annotations (#{annot_count}). Will call finish_run_successfully to create annotations.")
            finish_run_successfully(run, slurm_service, slurm_job_id)
          else
            Rails.logger.info("[SlurmJobMonitorJob] Run##{run_id} already marked as complete by parse.rake with #{annot_count} annotations, skipping")
          end
          return
        end
        
        Rails.logger.debug("[SlurmJobMonitorJob] Run##{run_id} still #{status}, will check again")

        if attempt < MAX_MONITOR_ATTEMPTS
          wait = next_poll_wait(status, attempt)
          SlurmJobMonitorJob.set(wait: wait).perform_later(run_id, slurm_job_id, attempt + 1)
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

      when :accounting_unavailable
        if attempt < ACCOUNTING_UNAVAILABLE_GRACE_ATTEMPTS
          Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} accounting temporarily unavailable (attempt #{attempt}/#{ACCOUNTING_UNAVAILABLE_GRACE_ATTEMPTS}), retrying")
          SlurmJobMonitorJob.set(wait: MONITOR_INTERVAL).perform_later(run_id, slurm_job_id, attempt + 1)
        else
          Rails.logger.error("[SlurmJobMonitorJob] Run##{run_id} cannot be monitored: SLURM accounting still unavailable after #{attempt} attempts")
          finish_run_with_error(
            run,
            "SLURM accounting is currently unavailable (sacct database unreachable), so job status cannot be tracked. Please retry when SLURM accounting is healthy."
          )
        end

      when :invalid_job
        Rails.logger.warn("[SlurmJobMonitorJob] Run##{run_id} has invalid SLURM job id: #{slurm_job_id}")
        project = run.project
        step = run.step
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
        step_dir = project_dir + step.name
        output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
        output_json_filename = output_dir + 'output.json'

        if File.exist?(output_json_filename)
          finish_run_successfully(run, slurm_service, slurm_job_id)
        else
          error_message = extract_error_message(run) || "SLURM job #{slurm_job_id} is no longer available and no output was produced"
          finish_run_with_error(run, error_message)
        end

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

  # Choose the next poll delay. While the SLURM job is still :pending (queued),
  # use a short exponential backoff so the waiting -> running UI transition
  # happens within a few seconds of SLURM actually starting the job. Once the
  # job is running (or in any other monitored state), fall back to the regular
  # MONITOR_INTERVAL.
  def next_poll_wait(status, attempt)
    return MONITOR_INTERVAL unless status == :pending

    idx = [attempt, PENDING_POLL_INTERVALS.size].min - 1
    PENDING_POLL_INTERVALS[idx]
  end

  def broadcast_markers_run_status_changed_from_monitor(project, step, run)
    return unless step&.name == 'markers'

    ActionCable.server.broadcast(
      "project_#{project.id}",
      {
        event: 'markers_run_status_changed',
        project_id: project.id,
        run_id: run.id,
        annot_id: run.marker_metadata_annot_id
      }
    )
  rescue StandardError => e
    Rails.logger.warn("[SlurmJobMonitorJob] markers_run_status_changed: #{e.class} #{e.message}")
  end

  def queue_position_cache_key(run_id)
    "queue_position:last:run:#{run_id}"
  end

  def broadcast_queue_position_if_changed(run, slurm_service)
    return unless run&.project_id && run&.slurm_job_id

    queue_position = slurm_service.get_job_queue_position(run.slurm_job_id, run.status_id)
    snap = slurm_service.pending_job_queue_snapshot(run.slurm_job_id)
    blocker = MarkerQueueText.blocker_message(snap: snap)
    signature = [queue_position, snap&.dig(:pending_count), snap&.dig(:partition)&.to_s, snap&.dig(:reason), blocker]
    previous = Rails.cache.read(queue_position_cache_key(run.id))
    return if previous == signature

    Rails.cache.write(queue_position_cache_key(run.id), signature, expires_in: 12.hours)

    payload = {
      event: 'queue_position_changed',
      project_id: run.project_id,
      step_id: run.step_id,
      run_id: run.id,
      slurm_job_id: run.slurm_job_id,
      queue_position: queue_position,
      show_slurm_queue: true,
      queue_pending_total: snap&.dig(:pending_count),
      queue_partition: snap&.dig(:partition)&.to_s
    }
    if run.step&.name == 'markers'
      aid = run.marker_metadata_annot_id
      payload[:annot_id] = aid if aid.present?
      note = MarkerQueueText.partition_pending_explanation(snap)
      payload[:markers_queue_note] = note if note.present?
    end
    hover = MarkerQueueText.hover_summary(snap, queue_position)
    payload[:slurm_queue_hover] = hover if hover.present?
    payload[:slurm_blocker_message] = blocker if blocker.present?

    ActionCable.server.broadcast("project_#{run.project_id}", payload)
  rescue StandardError => e
    Rails.logger.warn("[SlurmJobMonitorJob] queue position broadcast failed for run #{run&.id}: #{e.class} - #{e.message}")
  end

  def broadcast_queue_position_cleared(run)
    return unless run&.project_id

    key = queue_position_cache_key(run.id)
    Rails.cache.delete(key)

    payload = {
      event: 'queue_position_changed',
      project_id: run.project_id,
      step_id: run.step_id,
      run_id: run.id,
      slurm_job_id: run.slurm_job_id,
      queue_position: nil,
      show_slurm_queue: false
    }
    if run.step&.name == 'markers'
      aid = run.marker_metadata_annot_id
      payload[:annot_id] = aid if aid.present?
    end
    payload[:slurm_queue_hover] = "Slurm queue position: job left the pending queue or started."

    ActionCable.server.broadcast("project_#{run.project_id}", payload)
  rescue StandardError => e
    Rails.logger.warn("[SlurmJobMonitorJob] queue position clear broadcast failed for run #{run&.id}: #{e.class} - #{e.message}")
  end

  def extract_error_message(run)
    return nil unless run
    
    project = run.project
    step = run.step
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name
    output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    
    # First check exec.out for displayed_error (application-level errors)
    exec_out = output_dir + "exec.out"
    if File.exist?(exec_out)
      begin
        exec_content = File.read(exec_out)
        exec_json = JSON.parse(exec_content)
        if exec_json.is_a?(Hash) && exec_json['displayed_error'].present?
          if exec_json['displayed_error'].is_a?(Array)
            return exec_json['displayed_error'].join('; ')
          else
            return exec_json['displayed_error'].to_s
          end
        end
      rescue JSON::ParserError
        # Not JSON, continue checking other files
      end
    end
    
    # Check exec.err for errors
    exec_err = output_dir + "exec.err"
    if File.exist?(exec_err)
      exec_err_content = File.read(exec_err)
      if exec_err_content.strip.present?
        # Filter out Elasticsearch responses
        if !exec_err_content.match?(/\{"_index":|"_id":|"_version":|"result":"updated"/)
          return exec_err_content.strip
        end
      end
    end
    
    error_file = output_dir + "exec.err"
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
    Rails.cache.delete(queue_position_cache_key(run.id))

    # Reload run to get latest status
    run.reload
    
    # finish_run is the only place that should set status_id = 3
    # If a run is already complete but has no annotations, something went wrong
    # We should still call finish_run to create annotations
    if run.status_id == 3
      annot_count = Annot.where(run_id: run.id).count
      if annot_count == 0
        Rails.logger.warn("[SlurmJobMonitorJob] Run##{run.id} is complete (status_id=3) but has NO annotations. This should not happen - finish_run should have created them. Calling finish_run again to create annotations.")
      elsif Basic.sync_run_annots_from_output_json!(Rails.logger, run)
        Rails.logger.info("[SlurmJobMonitorJob] Run##{run.id} synced annot dimensions from output.json")
        return
      else
        Rails.logger.info("[SlurmJobMonitorJob] Run##{run.id} already marked as complete with #{annot_count} annotations. finish_run should have been called already, skipping.")
        return
      end
    end
    
    project = run.project
    step = run.step
    
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name
    output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    
    output_json_filename = output_dir + 'output.json'

    unless output_json_fresh_for_run?(run, output_json_filename)
      unless wait_for_fresh_output_json(run, output_json_filename)
        Rails.logger.warn(
          "[SlurmJobMonitorJob] Run##{run.id} output.json is missing or stale " \
          "(submitted_at=#{run.submitted_at}, mtime=#{File.exist?(output_json_filename) ? File.mtime(output_json_filename) : 'missing'}); " \
          "skipping finish_run"
        )
        return
      end
    end
    
    h_results = {}
    if run.return_stdout == true
      output_file = output_dir + "exec.out"
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
      
      # For parsing step, verify that output.loom exists (required output file)
      if step.name == 'parsing'
        output_loom_file = output_dir + 'output.loom'
        unless File.exist?(output_loom_file)
          error_msg = "Parsing completed but required output.loom file not found at #{output_loom_file}"
          Rails.logger.error("[SlurmJobMonitorJob] Run##{run.id}: #{error_msg}")
          finish_run_with_error(run, error_msg)
          return
        end
      end
      
      # If no displayed_error and required files exist, proceed with successful completion
      Rails.logger.info("[SlurmJobMonitorJob] Calling Basic.finish_run for Run##{run.id}")
      Rails.logger.debug("[SlurmJobMonitorJob] h_results keys: #{h_results.keys.inspect}")
      Rails.logger.debug("[SlurmJobMonitorJob] h_results has output_files: #{h_results.key?('output_files')}")
      Rails.logger.debug("[SlurmJobMonitorJob] h_results has nber_rows: #{h_results.key?('nber_rows')}, nber_cols: #{h_results.key?('nber_cols')}")
      Basic.finish_run(Rails.logger, run, h_results)
      # Check if annotations were created
      annot_count_after = Annot.where(run_id: run.id).count
      Rails.logger.info("[SlurmJobMonitorJob] After finish_run, Run##{run.id} has #{annot_count_after} annotations")
    else
      Rails.logger.warn("[SlurmJobMonitorJob] No valid results found for Run##{run.id}, marking as failed")
      finish_run_with_error(run, "No output.json found or invalid output")
    end
  end

  def finish_run_with_error(run, error_message)
    Rails.cache.delete(queue_position_cache_key(run.id))

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
    
    # Update project_step run counts so UI can display failed status correctly
    Basic.upd_project_step(project, step.id) if project_step

    project.update(status_id: 4) if project
    run.reload.broadcast_status_change
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

  def run_output_dir(run)
    Basic.run_output_dir(run)
  end

  def output_json_path_for_run(run)
    run_output_dir(run) + 'output.json'
  end

  # Steps with multiple_runs=false reuse step/output.json; only treat the file as belonging
  # to this run when it was modified after the run was submitted.
  def output_json_fresh_for_run?(run, output_json_path = nil)
    path = output_json_path || output_json_path_for_run(run)
    return false unless path && File.exist?(path.to_s)

    submitted = run.submitted_at || run.created_at
    return false unless submitted

    File.mtime(path.to_s) >= submitted
  end

  def wait_for_fresh_output_json(run, output_json_path = nil, max_wait_seconds: 120)
    path = output_json_path || output_json_path_for_run(run)
    deadline = Time.now + max_wait_seconds
    while Time.now < deadline
      return true if output_json_fresh_for_run?(run, path)
      sleep 2
    end
    false
  end
end

