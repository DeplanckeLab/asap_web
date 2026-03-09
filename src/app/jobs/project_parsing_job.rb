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

    # Update project/step status to waiting and clear stale errors from previous failed runs.
    # This ensures the UI does not keep showing a failed state while a rerun is being queued.
    project_step.update(status_id: 1, error_message: nil) # 1 = waiting
    project.update(status_id: 1, error_message: nil)

    begin
      # Build command hash for parsing (similar to how parse.rake builds it)
      # The rake task will be executed via SLURM through exec_run -> RunExecutionJob
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

      # Read preparsing results to get predictions
      pred_max_ram = nil
      pred_process_duration = nil
      
      begin
        # Try to find Fu by project.fu_id first, then fall back to project_id lookup
        fu = if project.fu_id
               Fu.find_by(id: project.fu_id)
             else
               Fu.where(:project_id => project.id, :upload_type => 1).first
             end
        
        if fu
          upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                            ENV["UPLOAD_DATA_DIR"]
                          elsif ENV["DATA_DIR"]
                            Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                          else
                            '/data/asap2/fus'
                          end
          upload_dir = Pathname.new(upload_base_dir) + fu.id.to_s
          output_file = upload_dir + "output.json"
          
          if File.exist?(output_file)
            # Read the file fresh to ensure we have the latest data
            file_content = File.read(output_file)
            Rails.logger.info("[ProjectParsingJob] Preparsing output file: #{output_file}")
            Rails.logger.info("[ProjectParsingJob] File size: #{file_content.length} bytes")
            Rails.logger.info("[ProjectParsingJob] File modified: #{File.mtime(output_file)}")
            
            h_preparsing = Basic.safe_parse_json(file_content, {})
            Rails.logger.info("[ProjectParsingJob] Preparsing output keys: #{h_preparsing.keys.inspect}")
            
            # Log full preparsing output for debugging (first 2000 chars)
            preparsing_json_str = h_preparsing.to_json
            Rails.logger.info("[ProjectParsingJob] Preparsing output preview: #{preparsing_json_str[0..2000]}")
            
            if h_preparsing && h_preparsing['list_groups'] && h_preparsing['list_groups'][0]
              list_group = h_preparsing['list_groups'][0]
              Rails.logger.info("[ProjectParsingJob] list_groups[0] keys: #{list_group.keys.inspect}")
              Rails.logger.info("[ProjectParsingJob] list_groups[0] full content: #{list_group.to_json}")
              Rails.logger.info("[ProjectParsingJob] list_groups[0] pred_max_ram value: #{list_group['pred_max_ram'].inspect} (class: #{list_group['pred_max_ram'].class})")
              Rails.logger.info("[ProjectParsingJob] list_groups[0] pred_process_duration value: #{list_group['pred_process_duration'].inspect} (class: #{list_group['pred_process_duration'].class})")
              
              # Also check for alternative key names
              Rails.logger.info("[ProjectParsingJob] Checking for alternative keys: predicted_ram=#{list_group['predicted_ram'].inspect}, predicted_duration=#{list_group['predicted_duration'].inspect}")
              
              # Check for pred_max_ram - handle empty string, nil, or numeric values
              if list_group['pred_max_ram'].present? && list_group['pred_max_ram'] != '' && list_group['pred_max_ram'] != 'NA'
                pred_max_ram = list_group['pred_max_ram'].to_i
                Rails.logger.info("[ProjectParsingJob] Extracted pred_max_ram: #{pred_max_ram}")
              else
                Rails.logger.warn("[ProjectParsingJob] pred_max_ram is missing or empty: #{list_group['pred_max_ram'].inspect}")
              end
              
              # Check for pred_process_duration - handle empty string, nil, or numeric values
              if list_group['pred_process_duration'].present? && list_group['pred_process_duration'] != '' && list_group['pred_process_duration'] != 'NA'
                pred_process_duration = list_group['pred_process_duration'].to_i
                Rails.logger.info("[ProjectParsingJob] Extracted pred_process_duration: #{pred_process_duration}")
              else
                Rails.logger.warn("[ProjectParsingJob] pred_process_duration is missing or empty: #{list_group['pred_process_duration'].inspect}")
              end
              
              Rails.logger.info("[ProjectParsingJob] Final predictions: pred_max_ram=#{pred_max_ram}, pred_process_duration=#{pred_process_duration}")
            else
              Rails.logger.warn("[ProjectParsingJob] Preparsing output.json exists but doesn't contain list_groups[0]")
              Rails.logger.warn("[ProjectParsingJob] list_groups present? #{h_preparsing['list_groups'].present?}")
              Rails.logger.warn("[ProjectParsingJob] list_groups size: #{h_preparsing['list_groups']&.size}")
            end
          else
            Rails.logger.warn("[ProjectParsingJob] Preparsing output file not found: #{output_file}")
          end
        else
          Rails.logger.warn("[ProjectParsingJob] No Fu record found for project #{project.id} (fu_id: #{project.fu_id})")
        end
      rescue => e
        Rails.logger.error("[ProjectParsingJob] Error reading preparsing predictions: #{e.class} - #{e.message}")
        Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      end

      # Build run hash
      # Use async: true to execute through SLURM via exec_run -> RunExecutionJob
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
        error: nil,
        slurm_job_id: nil,
        async: true # Execute through SLURM via exec_run
      }
      
      # Add predictions if available (always set, even if nil)
      # Convert to integer if present and valid, otherwise set to nil
      if pred_max_ram.present? && pred_max_ram != '' && pred_max_ram != 'NA'
        h_run[:pred_max_ram] = pred_max_ram.to_i
      else
        h_run[:pred_max_ram] = nil
      end
      
      if pred_process_duration.present? && pred_process_duration != '' && pred_process_duration != 'NA'
        h_run[:pred_process_duration] = pred_process_duration.to_i
      else
        h_run[:pred_process_duration] = nil
      end
      
      Rails.logger.info("[ProjectParsingJob] h_run hash before save: pred_max_ram=#{h_run[:pred_max_ram].inspect}, pred_process_duration=#{h_run[:pred_process_duration].inspect}")

      # Find or create/update run
      run = Run.where(project_id: project.id, step_id: parsing_step.id).first
      if run
        # Use update_columns to bypass validations and callbacks if needed
        result = run.update(h_run)
        run.reload
        Rails.logger.info("[ProjectParsingJob] Updated existing run #{run.id}, update result: #{result}")
        Rails.logger.info("[ProjectParsingJob] Run pred_max_ram after update: #{run.pred_max_ram.inspect}")
        Rails.logger.info("[ProjectParsingJob] Run pred_process_duration after update: #{run.pred_process_duration.inspect}")
      else
        run = Run.new(h_run)
        if run.save
          Rails.logger.info("[ProjectParsingJob] Created new run #{run.id}")
          Rails.logger.info("[ProjectParsingJob] Run pred_max_ram after create: #{run.pred_max_ram.inspect}")
          Rails.logger.info("[ProjectParsingJob] Run pred_process_duration after create: #{run.pred_process_duration.inspect}")
        else
          Rails.logger.error("[ProjectParsingJob] Failed to create run: #{run.errors.full_messages.join(', ')}")
          Rails.logger.error("[ProjectParsingJob] Run attributes: #{run.attributes.inspect}")
        end
      end

      # Update container_name in command_json with actual run ID
      h_cmd['container_name'] = asap_instance_name + "_" + run.id.to_s
      run.update(command_json: h_cmd.to_json)

      # Update project step details (this may set resource requirements from predictions)
      h_project_step = Basic.get_project_step_details(project, parsing_step.id)
      project_step.update(h_project_step)
      # Keep aggregated counts in sync immediately so header status icons update from failed -> waiting/running.
      Basic.upd_project_step(project, parsing_step.id)
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      
      # Reload run to get updated resource predictions if any
      run.reload
      
      # Execute run through SLURM using the standard exec_run flow
      # This will call exec_run_async -> RunExecutionJob -> SLURM
      Rails.logger.info("[ProjectParsingJob] Executing Run##{run.id} through SLURM via exec_run")
      Basic.exec_run(Rails.logger, run)
      
      Rails.logger.info("[ProjectParsingJob] Parsing Run##{run.id} queued for execution via SLURM")
      
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

