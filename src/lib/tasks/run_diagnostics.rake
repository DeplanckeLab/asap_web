namespace :run do
  desc "Diagnose and fix a stuck run"
  task :diagnose, [:run_id] => :environment do |t, args|
    run_id = args[:run_id]&.to_i
    unless run_id
      puts "Usage: rails run:diagnose[RUN_ID]"
      puts "Example: rails run:diagnose[12345]"
      exit 1
    end

    run = Run.find_by(id: run_id)
    unless run
      puts "Error: Run##{run_id} not found"
      exit 1
    end

    project = run.project
    step = run.step

    puts "=" * 80
    puts "Run Diagnostics for Run##{run_id}"
    puts "=" * 80
    puts "Project: #{project.name} (#{project.key})"
    puts "Step: #{step.name} (ID: #{step.id})"
    puts "Status ID: #{run.status_id} (#{Status.find_by(id: run.status_id)&.name || 'Unknown'})"
    puts "SLURM Job ID: #{run.slurm_job_id || 'N/A'}"
    puts "PID: #{run.pid || 'N/A'}"
    puts "Created: #{run.created_at}"
    puts "Start Time: #{run.start_time || 'N/A'}"
    puts "Error: #{run.error || 'None'}"
    puts ""

    # Check output directory
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name
    output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    output_json_file = output_dir + 'output.json'

    puts "Output Directory: #{output_dir}"
    puts "Output JSON exists: #{File.exist?(output_json_file)}"
    puts ""

    if File.exist?(output_json_file)
      begin
        h_results = Basic.safe_parse_json(File.read(output_json_file), {})
        puts "Output JSON valid: Yes"
        puts "Output JSON keys: #{h_results.keys.join(', ')}"
        if h_results['displayed_error']
          puts "WARNING: Output contains displayed_error: #{h_results['displayed_error']}"
        end
      rescue => e
        puts "Output JSON valid: No - #{e.message}"
      end
      puts ""
    end

    # Check SLURM status
    if run.slurm_job_id
      puts "Checking SLURM job status..."
      slurm_service = SlurmService.new(logger: Rails.logger)
      status = slurm_service.get_job_status(run.slurm_job_id, run)
      puts "SLURM Status: #{status || 'nil (job history may be purged)'}"
      puts ""

      if status == :completed || (status.nil? && File.exist?(output_json_file))
        puts "=" * 80
        puts "ACTION: Run appears to be complete but not marked as such"
        puts "Attempting to finish run..."
        puts "=" * 80

        begin
          # Use the same logic as SlurmJobMonitorJob
          if File.exist?(output_json_file)
            h_results = Basic.safe_parse_json(File.read(output_json_file), {})
            
            if h_results.is_a?(Hash) && h_results.keys.size > 0
              if h_results['displayed_error'].present?
                error_msg = if h_results['displayed_error'].is_a?(Array)
                  h_results['displayed_error'].join('; ')
                else
                  h_results['displayed_error'].to_s
                end
                puts "ERROR: Output contains displayed_error: #{error_msg}"
                puts "Marking run as failed..."
                run.update(status_id: 4, error: error_msg)
                project_step = ProjectStep.where(project_id: project.id, step_id: step.id).first
                project_step&.update(status_id: 4, error_message: error_msg)
              else
                puts "Finishing run successfully..."
                Basic.finish_run(Rails.logger, run, h_results)
                run.reload
                puts "Run status updated to: #{run.status_id} (#{Status.find_by(id: run.status_id)&.name})"
              end
            else
              puts "ERROR: Output JSON is empty or invalid"
            end
          end
        rescue => e
          puts "ERROR: Failed to finish run: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
        end
      elsif status == :running || status == :pending
        puts "INFO: Job is still #{status} in SLURM"
        puts "This is normal - the monitoring job should handle completion"
      elsif status == :failed || status == :timeout || status == :node_fail || status == :cancelled
        puts "WARNING: SLURM reports job as #{status}"
        puts "The monitoring job should mark this as failed"
      end
    else
      puts "WARNING: No SLURM job ID found for this run"
    end

    puts ""
    puts "=" * 80
    puts "Diagnostics complete"
    puts "=" * 80
    
    # Check if run is waiting and suggest action
    if run.status_id == 1 && !run.slurm_job_id
      puts ""
      puts "=" * 80
      puts "ACTION REQUIRED: Run is waiting but has no SLURM job ID"
      puts "=" * 80
      puts "This means RunExecutionJob was never executed or failed silently."
      puts ""
      puts "To fix this, run:"
      puts "  rails run:trigger_execution[#{run_id}]"
      puts ""
      puts "Or process all waiting runs:"
      puts "  rails slurm:process_waiting_runs"
      puts ""
    end
  end

  desc "Find runs by project key and step name"
  task :find, [:project_key, :step_name, :run_num] => :environment do |t, args|
    project_key = args[:project_key]
    step_name = args[:step_name]
    run_num = args[:run_num]&.to_i

    unless project_key && step_name
      puts "Usage: rails run:find[PROJECT_KEY,STEP_NAME,RUN_NUM]"
      puts "Example: rails run:find[abc123,gene_filtering,2]"
      puts "Run number is optional - if not provided, shows all runs for that step"
      exit 1
    end

    project = Project.find_by(key: project_key)
    unless project
      puts "Error: Project with key '#{project_key}' not found"
      exit 1
    end

    asap_docker_image = Basic.get_asap_docker(project.version)
    unless asap_docker_image
      puts "Error: Could not find docker image for project version #{project.version}"
      exit 1
    end

    step = Step.where(name: step_name, docker_image_id: asap_docker_image.id).first
    unless step
      puts "Error: Step '#{step_name}' not found for project version #{project.version}"
      exit 1
    end

    runs = Run.where(project_id: project.id, step_id: step.id).order(created_at: :desc)
    
    if run_num
      runs = runs.select { |r| (r.num || r.id) == run_num }
    end

    if runs.empty?
      puts "No runs found for project '#{project_key}', step '#{step_name}'"
      if run_num
        puts "(with run number #{run_num})"
      end
      exit 0
    end

    puts "=" * 80
    puts "Runs for Project: #{project.name} (#{project.key}), Step: #{step_name}"
    puts "=" * 80
    runs.each do |run|
      status_name = Status.find_by(id: run.status_id)&.name || 'Unknown'
      puts "Run##{run.id} (num: #{run.num || 'N/A'}) - Status: #{status_name} (#{run.status_id})"
      puts "  Created: #{run.created_at}"
      puts "  SLURM Job ID: #{run.slurm_job_id || 'N/A'}"
      puts "  Error: #{run.error || 'None'}"
      puts ""
    end
    puts "To diagnose a specific run, use: rails run:diagnose[RUN_ID]"
  end

  desc "Manually trigger execution of a waiting run"
  task :trigger_execution, [:run_id] => :environment do |t, args|
    run_id = args[:run_id]&.to_i
    unless run_id
      puts "Usage: rails run:trigger_execution[RUN_ID]"
      puts "Example: rails run:trigger_execution[771827]"
      exit 1
    end

    run = Run.find_by(id: run_id)
    unless run
      puts "Error: Run##{run_id} not found"
      exit 1
    end

    project = run.project
    step = run.step

    puts "=" * 80
    puts "Triggering Execution for Run##{run_id}"
    puts "=" * 80
    puts "Project: #{project.name} (#{project.key})"
    puts "Step: #{step.name} (ID: #{step.id})"
    status_name = Status.find_by(id: run.status_id)&.name || 'Unknown'
    puts "Status ID: #{run.status_id} (#{status_name})"
    puts "Async: #{run.async}"
    puts "Command JSON: #{run.command_json.present? ? 'Present' : 'Missing'}"
    puts ""

    # Status_id 6 is used when runs are initially created (before set_run is called)
    # Status_id 1 is waiting (after set_run is called, ready for execution)
    if run.status_id != 1 && run.status_id != 6
      puts "ERROR: Run is not in a processable status"
      puts "Expected status_id 1 (waiting) or 6 (preparing), got: #{run.status_id} (#{status_name})"
      exit 1
    end

    if run.command_json.blank?
      puts "=" * 80
      puts "ERROR: Run has no command_json. Cannot execute."
      puts "=" * 80
      puts ""
      puts "The run was created but Basic.set_run() was never called or failed."
      puts "This should normally happen automatically when a Req is created."
      puts ""
      puts "Possible causes:"
      puts "  1. The Req#set_runs method was never called"
      puts "  2. Basic.set_run() failed silently"
      puts "  3. The run creation process was interrupted"
      puts ""
      puts "To fix this manually, you would need to:"
      puts "  1. Find the associated Req (if it exists)"
      puts "  2. Reconstruct the h_p hash from the run's data"
      puts "  3. Call Basic.set_run(logger, h_p) to populate command_json"
      puts "  4. Then call Basic.exec_run(logger, run) to execute"
      puts ""
      puts "This is complex and requires access to the original request data."
      puts "Consider deleting this run and recreating it through the normal form flow."
      exit 1
    end

    # If status_id is 6 but command_json exists, update to status_id 1
    if run.status_id == 6
      puts "INFO: Run has status_id 6 (preparing) but command_json is present."
      puts "Updating status to 1 (waiting) before execution..."
      run.update(status_id: 1)
      run.reload
    end

    puts "Triggering RunExecutionJob..."
    begin
      # Try to execute the job directly first to see if there are any immediate errors
      RunExecutionJob.perform_now(run.id)
      puts "SUCCESS: RunExecutionJob completed successfully"
      run.reload
      puts "Run status updated to: #{run.status_id} (#{Status.find_by(id: run.status_id)&.name})"
      if run.slurm_job_id
        puts "SLURM Job ID: #{run.slurm_job_id}"
      end
    rescue => e
      puts "ERROR: RunExecutionJob failed: #{e.class} - #{e.message}"
      puts e.backtrace.first(10).join("\n")
      exit 1
    end

    puts ""
    puts "=" * 80
    puts "Execution triggered"
    puts "=" * 80
  end

  desc "Check all stuck runs (running but output.json exists)"
  task check_stuck: :environment do
    puts "Checking for stuck runs..."
    puts ""

    stuck_runs = Run.where(status_id: 2).select do |run|
      project = run.project
      step = run.step
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      step_dir = project_dir + step.name
      output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
      output_json_file = output_dir + 'output.json'
      File.exist?(output_json_file)
    end

    if stuck_runs.empty?
      puts "No stuck runs found"
    else
      puts "Found #{stuck_runs.size} stuck run(s):"
      stuck_runs.each do |run|
        puts "  - Run##{run.id} (#{run.step.name}) - Project: #{run.project.key}"
      end
      puts ""
      puts "To fix a stuck run, use: rails run:diagnose[RUN_ID]"
    end
  end
end

