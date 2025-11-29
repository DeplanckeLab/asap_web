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
    FileUtils.mkdir_p(tmp_dir) unless File.exist?(tmp_dir)

    # Update project step status to running
    project_step.update_attributes(status_id: 2) # 2 = running
    project.update_attributes(status_id: 2)

    begin
      # Build command hash
      h_cmd = {
        host_name: "localhost",
        program: "rails parse[#{project.key}]",
        opts: [],
        args: []
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
        submitted_at: start_time
      }

      # Find or create/update run
      run = Run.where(project_id: project.id, step_id: parsing_step.id).first
      if run
        run.update_attributes(h_run)
        Rails.logger.info("[ProjectParsingJob] Updated existing run #{run.id}")
      else
        run = Run.new(h_run)
        run.save
        Rails.logger.info("[ProjectParsingJob] Created new run #{run.id}")
      end

      # Update container_name in command_json
      h_cmd['container_name'] = 'asap_dev_' + run.id.to_s
      run.update_attributes(command_json: h_cmd.to_json)

      # Update project step details
      h_project_step = Basic.get_project_step_details(project, parsing_step.id)
      project_step.update_attributes(h_project_step)
      
      # Broadcast update
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      
      Rails.logger.info("[ProjectParsingJob] Parsing setup completed for Project##{project_id}, Run##{run.id}")
      
    rescue StandardError => e
      Rails.logger.error("[ProjectParsingJob] Error setting up parsing for project #{project_id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      
      # Update status to failed
      error_message = e.message
      project_step.update_attributes(
        status_id: 4, # 4 = failed
        error_message: error_message
      )
      project.update_attributes(
        status_id: 4,
        error_message: error_message
      )
      
      # Broadcast update
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      
      raise e
    end
  end
end

