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
    memory_mb = (run.pred_max_ram || run.max_ram || options[:memory_mb] || 4096).to_i
    time_limit = (run.pred_process_duration || options[:time_limit] || 3600).to_i
    
    @logger.info("[SlurmService] Resource requirements for Run##{run_id}:")
    @logger.info("  - CPUs: #{cores} (from nber_cores: #{run.nber_cores})")
    @logger.info("  - Memory: #{memory_mb}MB (predicted: #{run.pred_max_ram}, actual: #{run.max_ram})")
    @logger.info("  - Time limit: #{time_limit}s (#{time_limit / 60}min) (predicted: #{run.pred_process_duration})")
    
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
    output_file = output_dir + "slurm_#{run_id}.out"
    error_file = output_dir + "slurm_#{run_id}.err"
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
    @logger.debug("[SlurmService] Script: #{script_file}")
    @logger.debug("[SlurmService] Command: #{command}")
    
    # Run sbatch directly (SLURM client tools are installed in this container)
    # The script file path is accessible via shared volumes
    # SLURM_CONF_FILE environment variable points to mounted slurm.conf
    # Explicitly pass --account to ensure it's used for fair-share scheduling
    account_name = user_id ? "user_#{user_id}" : nil
    account_flag = account_name ? "--account=#{account_name} " : ""
    result = `sbatch #{account_flag}--parsable #{script_file} 2>&1`
    
    if $?.success?
      slurm_job_id = result.strip
      @logger.info("[SlurmService] Job submitted successfully: SLURM Job ID #{slurm_job_id} for Run##{run_id}")
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
    
    if $?.success? && !result.strip.empty?
      status = result.strip
      return normalize_status(status)
    else
      # Try sacct if squeue doesn't return results
      result = `sacct -j #{slurm_job_id} -n -o State --parsable2 --noheader 2>&1`
      if $?.success? && !result.strip.empty?
        status = result.strip.split.first
        return normalize_status(status)
      end
      
      # If sacct fails (e.g., munge auth issues), check output files as fallback
      if run
        project = run.project
        step = run.step
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
        step_dir = project_dir + step.name
        output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
        
        output_file = output_dir + "slurm_#{run.id}.out"
        error_file = output_dir + "slurm_#{run.id}.err"
        
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
        
        if cpu_available >= cores && mem_available >= memory_mb && time_ok
          available_partitions << partition
        end
      end
      
      if available_partitions.empty?
        return {
          available: false,
          message: "No partitions have sufficient resources (need #{cores} CPUs, #{memory_mb}MB RAM, #{time_limit}s)"
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
    # Escape the command for use in bash script
    escaped_command = options[:command].gsub("'", "'\"'\"'")
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
      escaped_command
    else
      # Command needs Rails - execute in website container
      "docker exec asap2_test-website-1 bash -c '#{escaped_command}'"
    end
    
    <<~SCRIPT
      #!/bin/bash
      #SBATCH --job-name=#{options[:job_name]}
      #{account_line}#SBATCH --output=#{options[:output_file]}
      #SBATCH --error=#{options[:error_file]}
      #SBATCH --ntasks=1
      #SBATCH --cpus-per-task=#{options[:cores]}
      #SBATCH --mem=#{options[:memory_mb]}M
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

