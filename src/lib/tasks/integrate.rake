desc 'Integrate multiple projects (executed by SLURM)'
task :integrate, [:project_key] => [:environment] do |t, args|
  puts 'Executing integrate...'

  now = Time.now
  logger = Rails.logger
  puts args[:project_key]

  project_key = args[:project_key]
  project = Project.where(key: project_key).first

  unless project
    logger.error("[IntegrateRake] Project with key #{project_key} not found")
    exit 1
  end

  version = project.version
  unless version
    logger.error("[IntegrateRake] Project #{project_key} has no version")
    exit 1
  end

  h_env = Basic.safe_parse_json(version.env_json, {})
  asap_docker_image = Basic.get_asap_docker(version)

  unless asap_docker_image
    logger.error("[IntegrateRake] Could not find ASAP docker image for version #{version.id}")
    exit 1
  end

  h_env_docker_image = h_env['docker_images']['asap_run']
  image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']

  db_conn = "postgres:5434/asap2_data_v" + h_env['asap_data_db_version'].to_s

  project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
  tmp_dir = project_dir + 'parsing'
  FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
  begin
    FileUtils.chmod(0777, tmp_dir)
  rescue => e
    logger.warn("[IntegrateRake] Could not set permissions on #{tmp_dir}: #{e.message}")
  end

  parsing_step = Step.where(docker_image_id: asap_docker_image.id, name: 'parsing').first
  unless parsing_step
    logger.error("[IntegrateRake] Could not find parsing step for docker image #{asap_docker_image.id}")
    exit 1
  end

  run = Run.where(project_id: project.id, step_id: parsing_step.id).first
  unless run
    logger.error("[IntegrateRake] No run found for project #{project_key}")
    exit 1
  end

  project_step = ProjectStep.find_by(project_id: project.id, step_id: parsing_step.id)

  # Update run status to running
  start_time = Time.now
  waiting_duration = run.submitted_at ? (start_time - run.submitted_at).to_f : nil

  if run.status_id == 1 || !run.start_time
    run.update(
      status_id: 2,
      start_time: start_time,
      waiting_duration: waiting_duration
    )
    logger.info("[IntegrateRake] Updated run #{run.id} to running, waiting_duration: #{waiting_duration}")
  end

  # Update project_step nber_runs_json + status, and project nber_runs_json
  Basic.upd_project_step(project, parsing_step.id)
  project.update(status_id: 2)
  project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
  logger.info("[IntegrateRake] Updated project status to running")

  h_data_types = {}
  DataType.all.map { |dt| h_data_types[dt.name] = dt }

  h_data_classes = {}
  DataClass.all.map { |dt| h_data_classes[dt.name] = dt; h_data_classes[dt.id] = dt }

  begin
    h_attrs = Basic.safe_parse_json(run.attrs_json, {})
    puts h_attrs.to_json

    project_keys = h_attrs['integrate_batch_paths'].keys
    projects = Project.where(key: project_keys).all

    file_paths = projects.map { |p|
      p_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      p_dir + 'parsing' + 'output.loom'
    }.join(",")

    batch_paths = projects.map { |p|
      h_attrs['integrate_batch_paths'][p.key]
    }.join(",")

    rds_file = project_dir + 'parsing' + "output.rds"

    # Step 1: Run R integration script
    h_cmd_r = {
      'host_name' => "localhost",
      'time_call' => h_env["time_call"]&.gsub(/\#output_dir/, tmp_dir.to_s),
      'container_name' => ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev') + "_" + run.id.to_s,
      'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
      'program' => "Rscript integration.R",
      'opts' => {},
      'args' => [
        { "param_key" => 'input_loom_path_list', "value" => file_paths },
        { "param_key" => 'input_batch_path_list', "value" => batch_paths },
        { "param_key" => 'input_n_pcs', "value" => h_attrs['integrate_n_pcs'] },
        { "param_key" => 'output_rds_path', "value" => rds_file.to_s },
        { "param_key" => 'output_convergence_plot', "value" => (project_dir + 'parsing' + "convergence_plot.png").to_s }
      ]
    }

    cmd = Basic.build_cmd(h_cmd_r)
    puts "CMD_R: #{cmd}"
    `#{cmd}`

    # Step 2: Convert RDS to Loom
    input_loom_file = project_dir + 'input.loom'
    docker_call_convert = h_env_docker_image['call'].gsub(/\#image_name/, image_name)
    # Use the same docker image but with entrypoint override for conversion
    convert_docker_call = docker_call_convert.gsub(/--entrypoint\s+'[^']*'/, "--entrypoint '/bin/sh'")
    if convert_docker_call == docker_call_convert
      # If no --entrypoint was in the original call, just use sh -c
      convert_docker_call = docker_call_convert.sub(image_name, "--entrypoint '/bin/sh' #{image_name}")
    end
    cmd = "#{convert_docker_call} -c 'Rscript --vanilla /srv/convert_seurat.R #{rds_file} #{input_loom_file}'"
    puts "CMD_CONVERT: #{cmd}"
    `#{cmd}`

    # Step 3: Preparse the integrated loom file
    output_dir = project_dir + 'parsing'
    asap_run_dir = ENV.fetch('LOCAL_ASAP_RUN_DIR', '/srv/asap_run')
    cmd = "java -jar #{asap_run_dir}/ASAP.jar -T Preparsing -organism #{project.organism_id} -f \"#{input_loom_file}\" -o #{output_dir} -h #{db_conn} 2> #{output_dir + 'preparsing_output.err'}"
    puts "CMD_PREPARSE: #{cmd}"
    `#{cmd}`

    output_json = output_dir + 'output.json'
    if File.exist?(output_json)
      h_preparsing = Basic.safe_parse_json(File.read(output_json), {})
      puts "h_preparsing: #{h_preparsing.to_json}"

      parsing_attrs = Basic.safe_parse_json(project.parsing_attrs_json, {})
      if h_preparsing['list_groups'] && h_preparsing['list_groups'][0]
        ['nber_cols', 'nber_rows', 'file_type'].each do |e|
          parsing_attrs[e] = h_preparsing['list_groups'][0][e]
        end
      end
      project.update_column(:parsing_attrs_json, parsing_attrs.to_json)
    else
      logger.error("[IntegrateRake] Preparsing output.json not found at #{output_json}")
    end

    # Step 4: Parse the integrated file
    opts = [
      { 'opt' => "-ncells", 'value' => (Basic.safe_parse_json(project.reload.parsing_attrs_json, {})["nber_cols"] || 0).to_s },
      { 'opt' => "-ngenes", 'value' => (Basic.safe_parse_json(project.parsing_attrs_json, {})["nber_rows"] || 0).to_s },
      { 'opt' => "-type", 'value' => 'LOOM' },
      { 'opt' => '-T', 'value' => "Parsing" },
      { 'opt' => "-organism", 'value' => project.organism_id.to_s },
      { 'opt' => "-o", 'value' => tmp_dir.to_s },
      { 'opt' => "-f", 'value' => input_loom_file.to_s },
      { 'opt' => '-h', 'value' => db_conn }
    ]

    h_cmd_parse = {
      'host_name' => "localhost",
      'time_call' => h_env["time_call"]&.gsub(/\#output_dir/, tmp_dir.to_s),
      'container_name' => ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev') + "_" + run.id.to_s,
      'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
      'program' => "java -jar ASAP.jar",
      'opts' => opts,
      'args' => []
    }

    cmd_parse = Basic.build_cmd(h_cmd_parse)
    puts "CMD_JAVA: #{cmd_parse}"
    `#{cmd_parse}`

    # Update project with parsing results
    output_json_parse = tmp_dir + "output.json"
    if File.exist?(output_json_parse)
      h_parsing = Basic.safe_parse_json(File.read(output_json_parse), {})
      project.update_columns(
        nber_cols: h_parsing["nber_cols"],
        nber_rows: h_parsing["nber_rows"],
        extension: 'loom'
      )
    else
      logger.error("[IntegrateRake] Parsing output.json not found at #{output_json_parse}")
    end

    # Update run and project status to completed
    end_time = Time.now
    process_duration = (end_time - start_time).to_f

    run.update(
      status_id: 3,
      process_duration: process_duration
    )

    # Update project_step nber_runs_json + status, and project nber_runs_json
    Basic.upd_project_step(project, parsing_step.id)
    project.update(status_id: 3)

    project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
    logger.info("[IntegrateRake] Integration completed for project #{project_key} in #{process_duration}s")

  rescue => e
    logger.error("[IntegrateRake] Error during integration for project #{project_key}: #{e.class} - #{e.message}")
    logger.error(e.backtrace.join("\n")) if e.backtrace

    # Update status to failed
    run.update(status_id: 4) if run
    Basic.upd_project_step(project, parsing_step.id)
    project.update(status_id: 4)
    project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)

    raise e
  end
end
