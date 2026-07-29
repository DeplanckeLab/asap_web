require 'shellwords'

class SlurmService
  class SlurmError < StandardError; end

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def submit_job(run, command, options = {})
    run_id = run.id
    project = run.project
    step = run.step
    user_id = project.user_id
    
    cores = run.nber_cores || options[:cores] || 1
    # pred_max_ram is stored in KB (prediction output), while max_ram is stored in MB.
    # nil means no --mem directive: SLURM imposes no memory cap on the job.
    memory_mb = if run.pred_max_ram.present?
      (run.pred_max_ram.to_f / 1024.0).ceil
    elsif run.max_ram.present?
      run.max_ram.to_f.ceil
    else
      options[:memory_mb].presence&.to_i
    end

    time_limit = (run.pred_process_duration || options[:time_limit] || 3600).to_i

    # Add 5 minutes (300 seconds) buffer to predicted time to account for variability
    time_limit = time_limit + 300

    # Prediction is often too low for long-running steps (e.g. FindMarkers). Slurm kills the job at --time.
    min_walltime = 2.hours.to_i
    time_limit = [time_limit, min_walltime].max

    @logger.info("[SlurmService] Resource requirements for Run##{run_id}:")
    @logger.info("  - CPUs: #{cores} (from nber_cores: #{run.nber_cores})")
    @logger.info("  - Memory: #{memory_mb ? "#{memory_mb}MB" : "uncapped (no prediction)"} (predicted_kb: #{run.pred_max_ram}, actual_mb: #{run.max_ram})")
    @logger.info("  - Time limit: #{time_limit}s (#{time_limit / 60}min) (predicted: #{run.pred_process_duration}, min #{min_walltime}s)")
    
    if options[:check_resources] != false
      resource_check = check_resource_availability(cores: cores, memory_mb: memory_mb, time_limit: time_limit)
      if resource_check[:available] == false
        @logger.warn("[SlurmService] Resource availability warning: #{resource_check[:message]}")
        @logger.warn("[SlurmService] Job will be queued by SLURM until resources become available")
      end
    end
    
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name
    output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    FileUtils.mkdir_p(output_dir) unless File.exist?(output_dir)
    
    job_name = "asap_run_#{run_id}"
    output_file = output_dir + "exec.out"
    error_file = output_dir + "exec.err"
    script_file = output_dir + "slurm_#{run_id}.sh"
    
    # Ensure SLURM account exists for fair-share scheduling
    ensure_slurm_account(user_id)
    
    script_content = build_slurm_script(
      command: command,
      job_name: job_name,
      cores: cores,
      memory_mb: memory_mb,
      time_limit: time_limit,
      output_file: output_file,
      error_file: error_file,
      run_id: run_id,
      user_id: user_id,
      workdir: output_dir.to_s  # Use output directory as working directory on host
    )
    
    File.write(script_file, script_content)
    File.chmod(0755, script_file)
    
    @logger.info("[SlurmService] Submitting job for Run##{run_id}: #{job_name}")
    @logger.info("[SlurmService] Script path for Run##{run_id}: #{script_file}")
    @logger.info("[SlurmService] Output path for Run##{run_id}: #{output_file}")
    @logger.info("[SlurmService] Error path for Run##{run_id}: #{error_file}")
    @logger.info("[SlurmService] Command for Run##{run_id}: #{command}")
    @logger.info("[SlurmService] Script content for Run##{run_id}:\n#{script_content}")
    
    # Run sbatch directly (SLURM client tools are installed in this container)
    # The script file path is accessible via shared volumes
    # SLURM_CONF_FILE environment variable points to mounted slurm.conf
    # Explicitly pass --account to ensure it's used for fair-share scheduling
    account_name = user_id ? "user_#{user_id}" : nil
    account_flag = account_name ? "--account=#{account_name} " : ""
    result = `sbatch #{account_flag}--parsable #{script_file} 2>&1`
    @logger.info("[SlurmService] sbatch exit_code=#{$?.exitstatus} output=#{result.to_s.strip.inspect} for Run##{run_id}")
    
    if $?.success?
      slurm_job_id = result.strip
      @logger.info("[SlurmService] Job submitted successfully: SLURM Job ID #{slurm_job_id} for Run##{run_id}")
      begin
        squeue_snapshot = `squeue -j #{slurm_job_id} -h -o "%i|%T|%R" 2>&1`
        @logger.info("[SlurmService] post-submit squeue job=#{slurm_job_id} exit_code=#{$?.exitstatus} output=#{squeue_snapshot.to_s.strip.inspect}")
        scontrol_snapshot = `scontrol show job #{slurm_job_id} 2>&1`
        @logger.info("[SlurmService] post-submit scontrol job=#{slurm_job_id} exit_code=#{$?.exitstatus} output=#{scontrol_snapshot.to_s.strip.inspect}")
      rescue => e
        @logger.warn("[SlurmService] Could not capture post-submit SLURM snapshots for job #{slurm_job_id}: #{e.message}")
      end
      return slurm_job_id
    else
      error_msg = "Failed to submit SLURM job: #{result}"
      @logger.error("[SlurmService] #{error_msg}")
      raise SlurmError, error_msg
    end
  end

  def get_job_status(slurm_job_id, run = nil)
    return nil if slurm_job_id.blank?
    
    # Run squeue directly (SLURM client tools are installed in this container)
    result = `squeue -j #{slurm_job_id} -h -o "%T" 2>&1`
    @logger.info("[SlurmService#get_job_status] squeue job=#{slurm_job_id} exit_code=#{$?.exitstatus} output=#{result.to_s.strip.inspect}")
    if result.match?(/Invalid job id specified/i)
      return :invalid_job
    end
    
    if $?.success? && !result.strip.empty?
      status = result.strip
      return normalize_status(status)
    else
      # Try sacct if squeue doesn't return results
      result = `sacct -j #{slurm_job_id} -n -o State --parsable2 --noheader 2>&1`
      @logger.info("[SlurmService#get_job_status] sacct job=#{slurm_job_id} exit_code=#{$?.exitstatus} output=#{result.to_s.strip.inspect}")
      if result.match?(/Invalid job id specified/i)
        return :invalid_job
      end
      if $?.success? && !result.strip.empty?
        status = result.strip.split.first
        return normalize_status(status)
      end

      sacct_accounting_unavailable = result.match?(/Unable to connect to database|Problem talking to the database|Connection refused/i)
      
      # If sacct fails, check output files as fallback before surfacing infra errors.
      if run
        project = run.project
        step = run.step
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
        step_dir = project_dir + step.name
        output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
        
        output_file = output_dir + "exec.out"
        error_file = output_dir + "exec.err"
        @logger.info("[SlurmService#get_job_status] fallback run=#{run.id} output_dir=#{output_dir} exec_out_exists=#{File.exist?(output_file)} exec_err_exists=#{File.exist?(error_file)}")
        
        # If output files exist and are recent (modified within last hour), job likely completed
        if File.exist?(output_file) && File.mtime(output_file) > 1.hour.ago
          # Check error file for exit code or error messages
          if File.exist?(error_file)
            error_content = File.read(error_file)
            # Check for common error patterns
            if error_content.include?('NameError') || 
               error_content.include?('NoMethodError') ||
               error_content.include?('Errno::ENOENT') ||
               error_content.include?('No such file') ||
               error_content.include?('Error:') || 
               error_content.include?('aborted!') ||
               error_content.match(/exit code:?\s*[1-9]/i)
              return :failed
            end
          end
          
          # Check if output.json exists (indicates successful completion for parsing)
          output_json = output_dir + 'output.json'
          if File.exist?(output_json)
            return :completed
          elsif File.exist?(output_file)
            # Output file exists but no output.json - check if it contains completion message
            output_content = File.read(output_file)
            if output_content.include?('Job completed') || output_content.include?('Exit code: 0')
              return :completed
            elsif output_content.include?('Exit code:') && !output_content.match(/Exit code:\s*0/)
              return :failed
            end
          end
        end
      end

      # Explicitly surface SLURM accounting outages only after we fail to infer
      # state from run artifacts.
      if sacct_accounting_unavailable
        return :accounting_unavailable
      end

    end
    
    nil
  end

  def cancel_job(slurm_job_id)
    return false if slurm_job_id.blank?
    
    result = `scancel #{slurm_job_id} 2>&1`
    $?.success?
  end

  def get_job_info(slurm_job_id)
    return nil if slurm_job_id.blank?
    
    result = `sacct -j #{slurm_job_id} -n -o JobID,State,ExitCode,Elapsed,MaxRSS,AllocCPUS --parsable2 --noheader 2>&1`
    
    if $?.success? && !result.strip.empty?
      fields = result.strip.split('|')
      return {
        job_id: fields[0],
        state: normalize_status(fields[1]),
        exit_code: fields[2],
        elapsed: fields[3],
        max_rss: fields[4],
        alloc_cpus: fields[5]
      }
    end
    
    nil
  end

  # Pending jobs in the job partition, ordered by higher priority first then job id (ties).
  # Returns { position: Integer, pending_count: Integer, partition: String } or nil if not pending or query failed.
  def pending_job_queue_snapshot(slurm_job_id)
    id = slurm_job_id.to_i
    return nil if id <= 0

    meta = `squeue -h -j #{id} -o '%t|%P|%i|%p' 2>&1`.strip
    return nil unless $?.success?
    return nil if meta.blank? || meta.downcase.include?('invalid')

    st, partition, full_id, prio_s = meta.split('|', 4)
    return nil if st.blank? || partition.blank? || full_id.blank? || prio_s.nil?

    st = st.strip
    partition = partition.strip
    full_id = full_id.strip
    return nil unless st == 'PD'

    reason = pending_job_slurm_reason(id)

    escaped_part = Shellwords.escape(partition)
    raw = `squeue -h -t PD -p #{escaped_part} -o '%i %p' 2>&1`
    return nil unless $?.success?

    rows = []
    raw.each_line do |line|
      line = line.strip
      next if line.blank?

      jid_str, pr = line.split(/\s+/, 2)
      next if jid_str.blank? || pr.blank?

      rows << { full_id: jid_str.strip, prio: pr.strip.to_f }
    end
    return nil if rows.empty?
    return nil unless rows.any? { |r| r[:full_id] == full_id }

    rows.sort_by! { |r| [-r[:prio], full_id_sort_tuple(r[:full_id])] }
    idx = rows.index { |r| r[:full_id] == full_id }
    return nil if idx.nil?

    cluster = cluster_compute_summary
    {
      position: idx + 1,
      pending_count: rows.size,
      partition: partition,
      reason: reason,
      cluster: cluster
    }
  rescue StandardError => e
    @logger.warn("[SlurmService] pending_job_queue_snapshot failed for #{slurm_job_id.inspect}: #{e.class} #{e.message}")
    nil
  end

  # Slurm REASON field for a pending job (e.g. ReqNodeNotAvail, Resources).
  def pending_job_slurm_reason(slurm_job_id)
    id = slurm_job_id.to_i
    return nil if id <= 0

    raw = `squeue -h -j #{id} -o '%r' 2>&1`.strip
    return nil unless $?.success?
    return nil if raw.blank? || raw.downcase.include?('invalid')

    raw
  rescue StandardError => e
    @logger.warn("[SlurmService] pending_job_slurm_reason failed for #{slurm_job_id.inspect}: #{e.class} #{e.message}")
    nil
  end

  # Node states from sinfo (-Nel): used to explain jobs stuck pending with no RUN jobs.
  def cluster_compute_summary
    raw = `sinfo -Ne -h -o '%N|%T|%E' 2>&1`
    return nil unless $?.success?

    nodes = []
    raw.each_line do |line|
      line = line.strip
      next if line.blank?

      name, state, reason = line.split('|', 3)
      next if name.blank?

      nodes << {
        name: name.strip,
        state: state.to_s.strip,
        reason: reason.to_s.strip
      }
    end
    return nil if nodes.empty?

    down = nodes.select { |n| n[:state].match?(/down|drain|fail/i) }
    {
      nodes: nodes,
      all_down: down.size == nodes.size,
      any_down: down.any?,
      down_names: down.map { |n| n[:name] }
    }
  rescue StandardError => e
    @logger.warn("[SlurmService] cluster_compute_summary failed: #{e.class} #{e.message}")
    nil
  end

  # True when the UI should show the Slurm queue line (job is pending in Slurm).
  def show_slurm_queue_line?(slurm_job_id, job_status)
    return false if slurm_job_id.blank?

    return true if job_status == :pending
    return false if job_status == :running
    return false if [:completed, :failed, :cancelled, :timeout, :node_fail, :invalid_job].include?(job_status)

    pending_job_queue_snapshot(slurm_job_id).present?
  end

  # Numeric queue index when the job is still pending; nil when the job is running or finished.
  # Pass job_status when already known to avoid duplicate squeue.
  def get_job_queue_position(slurm_job_id, run_status_id = nil, job_status: nil, run: nil)
    return nil if slurm_job_id.blank?

    @logger.info("[SlurmService] get_job_queue_position called: slurm_job_id=#{slurm_job_id}, run_status_id=#{run_status_id.inspect}")

    waiting_like = [1, 6].include?(run_status_id.to_i)
    job_status = get_job_status(slurm_job_id, run) if job_status.nil?
    @logger.info("[SlurmService] Job #{slurm_job_id} SLURM status: #{job_status.inspect}")

    if job_status == :running
      @logger.info("[SlurmService] Job #{slurm_job_id} is running; no queue position")
      return nil
    end

    if [:completed, :failed, :cancelled, :timeout, :node_fail, :invalid_job].include?(job_status)
      @logger.info("[SlurmService] Job #{slurm_job_id} is #{job_status}; no queue position")
      return nil
    end

    snap = pending_job_queue_snapshot(slurm_job_id)
    if snap
      @logger.info("[SlurmService] pending_job_queue_snapshot for #{slurm_job_id}: #{snap.inspect}")
      return snap[:position]
    end

    @logger.info("[SlurmService] pending snapshot nil; job_status=#{job_status.inspect}, waiting_like=#{waiting_like}")

    if job_status == :pending
      @logger.info("[SlurmService] Fallback queue position 0 (pending, snapshot unavailable)")
      return 0
    end

    if waiting_like && job_status.nil?
      @logger.info("[SlurmService] Fallback queue position 0 (waiting run, Slurm status unknown)")
      return 0
    end

    if waiting_like && [:unknown, :accounting_unavailable].include?(job_status)
      @logger.info("[SlurmService] Fallback queue position 0 (waiting run, job_status=#{job_status})")
      return 0
    end

    nil
  end

  # Returns true if at least 10% of total node memory is still free.
  # Used as the submission gate when no RAM prediction is available.
  def node_has_free_memory_headroom?
    free_result  = `sinfo -h -o "%e" 2>&1`
    total_result = `sinfo -h -o "%m" 2>&1`
    return true unless $?.success?
    free_mb  = free_result.strip.split("\n").map(&:to_i).max.to_i
    total_mb = total_result.strip.split("\n").map(&:to_i).max.to_i
    return true if total_mb == 0
    free_mb.to_f / total_mb >= 0.10
  rescue StandardError
    true
  end

  def check_resource_availability(cores:, memory_mb:, time_limit:)
    begin
      result = `sinfo -h -o "%P|%C|%m|%l" 2>&1`
      
      if !$?.success?
        return {
          available: true,
          message: "Could not check resource availability (sinfo failed), assuming available"
        }
      end
      
      available_partitions = []
      result.strip.split("\n").each do |line|
        parts = line.split('|')
        next if parts.size < 4
        
        partition = parts[0]
        cpu_info = parts[1]
        mem_info = parts[2]
        time_info = parts[3]
        
        cpu_available = parse_cpu_availability(cpu_info)
        mem_available = parse_memory_availability(mem_info)
        time_ok = check_time_limit(time_info, time_limit)
        
        mem_ok = memory_mb ? mem_available >= memory_mb : node_has_free_memory_headroom?
        if cpu_available >= cores && mem_ok && time_ok
          available_partitions << partition
        end
      end
      
      if available_partitions.empty?
        return {
          available: false,
          message: "No partitions have sufficient resources (need #{cores} CPUs, #{memory_mb ? "#{memory_mb}MB" : "free headroom"} RAM, #{time_limit}s)"
        }
      else
        return {
          available: true,
          message: "Resources available in partitions: #{available_partitions.join(', ')}"
        }
      end
    rescue StandardError => e
      @logger.warn("[SlurmService] Error checking resource availability: #{e.message}")
      return {
        available: true,
        message: "Could not check resource availability, assuming available"
      }
    end
  end

  def get_cluster_info
    begin
      result = `sinfo -h -o "%P|%C|%m|%l|%D" 2>&1`
      
      if !$?.success?
        return nil
      end
      
      partitions = []
      result.strip.split("\n").each do |line|
        parts = line.split('|')
        next if parts.size < 5
        
        partitions << {
          partition: parts[0],
          cpu_info: parts[1],
          memory_info: parts[2],
          time_limit: parts[3],
          nodes: parts[4].to_i
        }
      end
      
      return partitions
    rescue StandardError => e
      @logger.warn("[SlurmService] Error getting cluster info: #{e.message}")
      return nil
    end
  end

  private

  def full_id_sort_tuple(full_id)
    full_id.to_s.split('_').map(&:to_i)
  end

  def parse_cpu_availability(cpu_info)
    return 0 if cpu_info.blank?
    
    if cpu_info.match(/(\d+)\/(\d+)\/(\d+)\/(\d+)/)
      allocated, idle, other, total = $1.to_i, $2.to_i, $3.to_i, $4.to_i
      return idle
    elsif cpu_info.match(/(\d+)\/(\d+)/)
      allocated, total = $1.to_i, $2.to_i
      return total - allocated
    end
    
    0
  end

  def parse_memory_availability(mem_info)
    return 0 if mem_info.blank?
    
    if mem_info.match(/(\d+)([KMGT]?)/i)
      value = $1.to_i
      unit = $2.upcase
      
      case unit
      when 'K'
        return value / 1024
      when 'M', ''
        return value
      when 'G'
        return value * 1024
      when 'T'
        return value * 1024 * 1024
      end
    end
    
    0
  end

  def check_time_limit(partition_time_limit, required_time)
    return true if partition_time_limit.blank? || partition_time_limit == 'infinite'
    return true if required_time <= 0
    
    partition_seconds = parse_time_limit(partition_time_limit)
    return true if partition_seconds == 0
    
    required_time <= partition_seconds
  end

  def parse_time_limit(time_string)
    return 0 if time_string.blank? || time_string == 'infinite'
    
    if time_string.match(/(\d+):(\d+):(\d+)/)
      hours, minutes, seconds = $1.to_i, $2.to_i, $3.to_i
      return hours * 3600 + minutes * 60 + seconds
    elsif time_string.match(/(\d+)-(\d+):(\d+):(\d+)/)
      days, hours, minutes, seconds = $1.to_i, $2.to_i, $3.to_i, $4.to_i
      return days * 86400 + hours * 3600 + minutes * 60 + seconds
    elsif time_string.match(/(\d+):(\d+)/)
      minutes, seconds = $1.to_i, $2.to_i
      return minutes * 60 + seconds
    end
    
    0
  end

  def ensure_slurm_account(user_id)
    account_name = "user_#{user_id}"
    
    # Check if account exists in database
    unless SlurmAccountService.account_exists?(user_id)
      @logger.error("[SlurmService] SLURM account #{account_name} does not exist. Please run 'rails slurm:create_account[#{user_id}]' to create it.")
    end
  rescue => e
    @logger.error("[SlurmService] Error checking SLURM account: #{e.message}")
  end

  def build_slurm_script(options)
    # The command will be executed in the website container via docker exec
    # since slurmd doesn't have Rails installed
    account_name = options[:user_id] ? "user_#{options[:user_id]}" : nil
    account_line = account_name ? "#SBATCH --account=#{account_name}\n" : ""
    
    # Set working directory to a safe location on the host (output directory or /tmp)
    # This prevents SLURM from trying to chdir to container-only paths like /app
    workdir = options[:workdir] || '/tmp'
    
    # Check if command is already a docker run command - if so, execute directly on host
    # Otherwise, wrap in docker exec to run in website container
    is_docker_run = options[:command].strip.start_with?('docker run')
    execution_line = if is_docker_run
      # Command is already a docker run - execute directly on SLURM node (host)
      # Don't escape it since it's executed directly (not wrapped in quotes)
      options[:command]
    else
      compose = ENV['COMPOSE_PROJECT_NAME'].to_s.strip
      if compose.empty?
        raise SlurmError,
              'COMPOSE_PROJECT_NAME must be set to the docker-compose project name so batch scripts can run docker exec <project>-website-1 (see .env / compose docs). Without it, Slurm jobs fail at launch with launch_failed_requeued_held.'
      end
      # Command needs Rails - execute in website container
      # Escape single quotes for use in bash -c '...'
      escaped_command = options[:command].gsub("'", "'\"'\"'")
      "docker exec #{compose}-website-1 bash -c '#{escaped_command}'"
    end
    
    <<~SCRIPT
      #!/bin/bash
      #SBATCH --job-name=#{options[:job_name]}
      #{account_line}#SBATCH --output=#{options[:output_file]}
      #SBATCH --error=#{options[:error_file]}
      #SBATCH --ntasks=1
      #SBATCH --cpus-per-task=#{options[:cores]}
      #{options[:memory_mb] ? "#SBATCH --mem=#{options[:memory_mb]}M" : ""}
      #SBATCH --time=#{format_time_limit(options[:time_limit])}
      #SBATCH --signal=B:USR1@60
      #SBATCH --chdir=#{workdir}

      set -e

      # Change to working directory (explicitly set to avoid SLURM trying /app)
      cd #{workdir} || cd /tmp

      RUN_ID=#{options[:run_id]}
      echo "Starting SLURM job for Run ID: $RUN_ID"
      echo "Job ID: $SLURM_JOB_ID"
      echo "Node: $SLURM_NODELIST"
      echo "Working directory: $(pwd)"
      echo "Start time: $(date)"

      trap 'echo "Job interrupted at $(date)"; exit 130' USR1

      # Execute command
      #{execution_line}

      EXIT_CODE=$?
      echo "Job completed at $(date)"
      echo "Exit code: $EXIT_CODE"
      exit $EXIT_CODE
    SCRIPT
  end

  def format_time_limit(seconds)
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60
    format("%02d:%02d:%02d", hours, minutes, secs)
  end

  def normalize_status(status)
    return nil if status.blank?
    
    status = status.strip.upcase
    
    case status
    when 'PENDING', 'PD'
      :pending
    when 'RUNNING', 'R'
      :running
    when 'COMPLETED', 'COMPLETING', 'CD'
      :completed
    when 'FAILED', 'F'
      :failed
    when 'CANCELLED', 'CA', 'CANCELLED+'
      :cancelled
    when 'TIMEOUT', 'TO'
      :timeout
    when 'NODE_FAIL', 'NF'
      :node_fail
    else
      :unknown
    end
  end
end

