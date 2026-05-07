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

  version = project.version_for_catalog
  unless version
    logger.error("[IntegrateRake] Project #{project_key} has no version for catalog")
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

  asap_data_db_name = h_env['asap_data_db_name'].to_s
  if asap_data_db_name.blank?
    logger.error("[IntegrateRake] Missing asap_data_db_name in version env_json for version #{version.id}")
    exit 1
  end
  db_conn = "postgres:5434/#{asap_data_db_name}"

  project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
  tmp_dir = project_dir + 'parsing'
  FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
  begin
    FileUtils.chmod(0777, tmp_dir)
  rescue => e
    logger.warn("[IntegrateRake] Could not set permissions on #{tmp_dir}: #{e.message}")
  end

  parsing_step = Step.where(version_id: version.id, docker_image_id: asap_docker_image.id, name: 'parsing').first
  unless parsing_step
    logger.error("[IntegrateRake] Could not find parsing step for version_id=#{version.id} docker_image_id=#{asap_docker_image.id}")
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
    source_projects = Project.where(key: project_keys).all

    # Carry over references (articles) and accessions (exp_entries) from source projects
    source_projects.each do |src|
      src.articles.each do |article|
        ArticlesProject.find_or_create_by(article_id: article.id, project_id: project.id)
      end
      src.exp_entries.each do |exp_entry|
        ExpEntriesProject.find_or_create_by(exp_entry_id: exp_entry.id, project_id: project.id)
      end
    end

    # Aggregate PMIDs and DOIs from source projects
    source_pmids = source_projects.filter_map(&:pmid).uniq
    source_dois = source_projects.filter_map(&:doi).flat_map { |d| d.split(",").map(&:strip) }.reject(&:empty?).uniq
    project.update_columns(
      pmid: source_pmids.first,
      doi: source_dois.any? ? source_dois.join(", ") : nil
    ) if project.pmid.nil? && project.doi.nil?
    logger.info("[IntegrateRake] Carried over #{project.articles.count} article(s) and #{project.exp_entries.count} accession(s) from source projects")

    file_paths = source_projects.map { |p|
      p_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      p_dir + 'parsing' + 'output.loom'
    }.join(",")

    batch_paths = source_projects.map { |p|
      h_attrs['integrate_batch_paths'][p.key]
    }.join(",")

    rds_file = project_dir + 'parsing' + "output.rds"

    # Step 1: Run R integration script
    h_cmd_r = {
      'host_name' => "localhost",
      'time_call' => h_env["time_call"]&.gsub(/\#output_dir/, tmp_dir.to_s),
      'container_name' => ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev') + "_" + run.id.to_s,
      'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
      'program' => "Rscript integration.v8.R",
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

    unless File.exist?(rds_file)
      raise "[IntegrateRake] R integration failed: output RDS file not found at #{rds_file}"
    end
    logger.info("[IntegrateRake] R integration produced #{rds_file} (#{File.size(rds_file)} bytes)")

    # Step 2: Parse the integrated file
    opts = [
      #{ 'opt' => "-type", 'value' => 'RDS' },
      #{ 'opt' => '-T', 'value' => "Parsing" },
      #{ 'opt' => "-organism", 'value' => project.organism_id.to_s },
      #{ 'opt' => "-o", 'value' => tmp_dir.to_s },
      #{ 'opt' => "-f", 'value' => rds_file.to_s },
      #{ 'opt' => '-h', 'value' => db_conn }
      {'opt' => "--organism", 'value' => project.organism_id.to_s},
      {'opt' => "--filetype", 'value' => 'RDS'},
      {'opt' => "-o", 'value' => tmp_dir.to_s},
      {'opt' => "-f", 'value' => rds_file.to_s},
      {'opt' => '--dburl', 'value' => db_conn}
    ]

    h_cmd_parse = {
      'host_name' => "localhost",
      'time_call' => h_env["time_call"]&.gsub(/\#output_dir/, tmp_dir.to_s),
      'container_name' => ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev') + "_" + run.id.to_s,
      'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
      'program' => "python3 parse.v8.py",
      'opts' => opts,
      'args' => []
    }

    cmd_parse = Basic.build_cmd(h_cmd_parse)
    puts "CMD_PARSE: #{cmd_parse}"
    parse_output = `#{cmd_parse} 2>&1`
    puts "PARSE_OUTPUT: #{parse_output}"

    # Update project with parsing results
    output_json_parse = tmp_dir + "output.json"
    h_parsing = {}
    if File.exist?(output_json_parse)
      h_parsing = Basic.safe_parse_json(File.read(output_json_parse), {})
      if h_parsing["nber_cols"] && h_parsing["nber_rows"]
        project.update_columns(
          nber_cols: h_parsing["nber_cols"],
          nber_rows: h_parsing["nber_rows"],
          extension: 'loom'
        )
        logger.info("[IntegrateRake] Set counts from parsing: #{h_parsing["nber_cols"]} cells, #{h_parsing["nber_rows"]} genes")
      else
        logger.warn("[IntegrateRake] Parsing output.json missing nber_cols/nber_rows, computing from source projects")
        total_cols = source_projects.sum { |p| p.nber_cols.to_i }
        total_rows = source_projects.map { |p| p.nber_rows.to_i }.max || 0
        project.update_columns(nber_cols: total_cols, nber_rows: total_rows, extension: 'loom')
        logger.info("[IntegrateRake] Set counts from source projects: #{total_cols} cells, #{total_rows} genes")
      end
    else
      logger.error("[IntegrateRake] Parsing output.json not found at #{output_json_parse}, computing from source projects")
      total_cols = source_projects.sum { |p| p.nber_cols.to_i }
      total_rows = source_projects.map { |p| p.nber_rows.to_i }.max || 0
      project.update_columns(nber_cols: total_cols, nber_rows: total_rows, extension: 'loom')
      logger.info("[IntegrateRake] Set counts from source projects: #{total_cols} cells, #{total_rows} genes")
    end

    # Call finish_run to create annotations, set run status, and update project step.
    # skip_broadcast: true because finish_run broadcasts before we update project.status_id,
    # so we do a single broadcast below with the correct project status.
    logger.info("[IntegrateRake] Calling Basic.finish_run to create annotations for run #{run.id}")
    Basic.finish_run(logger, run, h_parsing, skip_broadcast: true)

    # Reload run to get updated status from finish_run
    run.reload
    logger.info("[IntegrateRake] finish_run completed for run #{run.id}, status_id=#{run.status_id}, annotations: #{Annot.where(run_id: run.id).count}")

    # finish_run already called upd_project_step via upd_run, so only set project status here
    project.update(status_id: 3)

    project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
    logger.info("[IntegrateRake] Integration completed for project #{project_key}")

  rescue => e
    logger.error("[IntegrateRake] Error during integration for project #{project_key}: #{e.class} - #{e.message}")
    logger.error(e.backtrace.join("\n")) if e.backtrace

    # Update status to failed
    run.update(status_id: 4) if run
    Basic.upd_project_step(project, parsing_step.id) if project_step
    project.update(status_id: 4)
    project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)

    raise e
  end
end
