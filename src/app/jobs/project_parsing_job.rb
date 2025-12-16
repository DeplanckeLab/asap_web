class ProjectParsingJob < ApplicationJob
  queue_as :default

  def perform(project_id, h_data = {})
    Rails.logger.info("[ProjectParsingJob] Starting parsing job for Project##{project_id}")
    
    project = Project.find_by(id: project_id)
    unless project
      Rails.logger.error("[ProjectParsingJob] Project with ID #{project_id} not found")
      return
    end

    start_time = Time.now

    # Get version and docker image info
    version = project.version
    unless version
      Rails.logger.error("[ProjectParsingJob] Project #{project_id} has no version")
      return
    end

    h_env = Basic.safe_parse_json(version.env_json, {})
    asap_docker_image = Basic.get_asap_docker(version)
    
    unless asap_docker_image
      Rails.logger.error("[ProjectParsingJob] Could not find ASAP docker image for version #{version.id}")
      return
    end

    # Find parsing step and std_method
    parsing_step = Step.where(docker_image_id: asap_docker_image.id, name: 'parsing').first
    unless parsing_step
      Rails.logger.error("[ProjectParsingJob] Could not find parsing step for docker image #{asap_docker_image.id}")
      return
    end

    parsing_std_method = StdMethod.where(docker_image_id: asap_docker_image.id, name: 'parsing').first
    unless parsing_std_method
      Rails.logger.error("[ProjectParsingJob] Could not find parsing std_method for docker image #{asap_docker_image.id}")
      return
    end

    # Get or create project step
    project_step = ProjectStep.find_or_create_by(
      project_id: project.id,
      step_id: parsing_step.id
    )
    
    # Create project directory and parsing subdirectory
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key
    tmp_dir = project_dir + 'parsing'
    # Create directory with world-writable permissions so Docker container (user 1006) can write to it
    FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
    # Ensure directory is writable by the Java command (runs as user 1006 in Docker container)
    begin
      FileUtils.chmod(0777, tmp_dir)
      Rails.logger.info("[ProjectParsingJob] Set permissions on #{tmp_dir} to 0777")
    rescue => e
      Rails.logger.warn("[ProjectParsingJob] Could not set permissions on #{tmp_dir}: #{e.message}")
    end
    # The Java command in the Docker container runs as HOST_USER_ID (1006), so make it world-writable
    FileUtils.chmod(0777, tmp_dir) if File.exist?(tmp_dir)

    # Update project step status to waiting (will be set to running when SLURM job starts)
    project_step.update(status_id: 1) # 1 = waiting
    project.update(status_id: 1)

    begin
      # Build command hash for parsing (similar to how parse.rake builds it)
      # The rake task will be executed directly in a background job, not via SLURM
      asap_instance_name = ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev')
      h_env_docker_image = h_env['docker_images']['asap_run']
      image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']
      
      h_cmd = {
        'host_name' => 'localhost',
        'container_name' => asap_instance_name + "_temp_#{project.id}",
        'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
        'program' => "rails parse[#{project.key}]",
        'opts' => [],
        'args' => []
      }

      # Define output files
      output_file = tmp_dir + "output.loom"
      output_json = tmp_dir + "output.json"

      # Define outputs structure
      h_outputs = {
        output_matrix: { "parsing/output.loom" => { types: ["num_matrix"], dataset: "matrix", row_filter: nil, col_filter: nil } },
        output_json: { "parsing/output.json" => { types: ["json_file"] } }
      }

      # Build run hash
      h_run = {
        project_id: project.id,
        step_id: parsing_step.id,
        std_method_id: parsing_std_method.id,
        status_id: 1, # waiting
        num: 1,
        user_id: project.user_id,
        command_json: h_cmd.to_json,
        attrs_json: project.parsing_attrs_json,
        output_json: h_outputs.to_json,
        submitted_at: start_time,
        async: false # Run synchronously in background job (not via SLURM)
      }

      # Find or create/update run
      run = Run.where(project_id: project.id, step_id: parsing_step.id).first
      if run
        run.update(h_run)
        Rails.logger.info("[ProjectParsingJob] Updated existing run #{run.id}")
      else
        run = Run.new(h_run)
        run.save
        Rails.logger.info("[ProjectParsingJob] Created new run #{run.id}")
      end

      # Update container_name in command_json with actual run ID
      h_cmd['container_name'] = asap_instance_name + "_" + run.id.to_s
      run.update(command_json: h_cmd.to_json)

      # Update project step details (this may set resource requirements from predictions)
      h_project_step = Basic.get_project_step_details(project, parsing_step.id)
      project_step.update(h_project_step)
      
      # Reload run to get updated resource predictions if any
      run.reload
      
      # Build command to run in Rails environment
      # The rake task will be executed via SLURM
      rails_root = Rails.root.to_s
      rails_env = Rails.env
      parse_cmd = "cd #{rails_root} && RAILS_ENV=#{rails_env} bundle exec rails parse[#{project.key}]"
      
      Rails.logger.info("[ProjectParsingJob] Submitting parsing task to SLURM for Run##{run.id}")
      Rails.logger.debug("[ProjectParsingJob] Command: #{parse_cmd}")
      
      # Submit to SLURM
      slurm_service = SlurmService.new(logger: Rails.logger)
      slurm_job_id = slurm_service.submit_job(
        run,
        parse_cmd,
        cores: run.nber_cores || 1,
        memory_mb: run.pred_max_ram || run.max_ram || 4096,
        time_limit: run.pred_process_duration || 3600
      )
      
      # Update run with SLURM job ID and set status to running
      run.update(
        status_id: 2, # 2 = running
        start_time: Time.now,
        waiting_duration: Time.now - start_time,
        pid: slurm_job_id.to_i,
        slurm_job_id: slurm_job_id.to_i
      )
      
      # Update project step status to running
      project_step.update(status_id: 2) # 2 = running
      project.update(status_id: 2)
      
      # Broadcast update
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      
      # Start monitoring the SLURM job
      SlurmJobMonitorJob.set(wait: 30.seconds).perform_later(run.id, slurm_job_id)
      
      Rails.logger.info("[ProjectParsingJob] Parsing task submitted to SLURM for Project##{project_id}, Run##{run.id}, SLURM Job ID: #{slurm_job_id}")
      
    rescue StandardError => e
      Rails.logger.error("[ProjectParsingJob] Error setting up parsing for project #{project_id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      
      # Update status to failed
      error_message = e.message
      project_step.update(
        status_id: 4, # 4 = failed
        error_message: error_message
      )
      project.update(
        status_id: 4,
        error_message: error_message
      )
      
      # Broadcast update
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      
      raise e
    end
  end

end

