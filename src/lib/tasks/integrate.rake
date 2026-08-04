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
  docker_build = DockerBuild.find_or_create_for_image_ref!(image_name)

  asap_data_db_name = Basic.asap_data_db_name_from_env!(h_env)
  db_conn = Basic.asap_data_db_url(h_env)

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
      waiting_duration: waiting_duration,
      docker_build_id: docker_build.id
    )
    logger.info("[IntegrateRake] Updated run #{run.id} to running, waiting_duration: #{waiting_duration}")
  end

  # Update project_step nber_runs_json + status, and project nber_runs_json
  Basic.upd_project_step(project, parsing_step.id)
  project.update(status_id: 2)
  project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
  Basic.broadcast_integration_status(project, 'queued')
  logger.info("[IntegrateRake] Updated project status to running")

  h_data_types = {}
  DataType.all.map { |dt| h_data_types[dt.name] = dt }

  h_data_classes = {}
  DataClass.all.map { |dt| h_data_classes[dt.name] = dt; h_data_classes[dt.id] = dt }

  begin
    h_attrs = Basic.safe_parse_json(run.attrs_json, {})
    puts h_attrs.to_json

    project_keys = Basic.integration_source_keys(h_attrs)
    unless project_keys.any?
      raise "[IntegrateRake] No integration source project keys found in run attrs"
    end
    source_projects_by_key = Project.where(key: project_keys).index_by(&:key)
    source_projects = project_keys.filter_map { |key| source_projects_by_key[key] }
    if source_projects.size != project_keys.size
      missing = project_keys - source_projects.map(&:key)
      raise "[IntegrateRake] Source project(s) not found: #{missing.join(', ')}"
    end

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

    source_projects.each do |src|
      next if src.filesystem_project_data_present?

      if src.archive_restore_expected?
        Basic.broadcast_integration_status(project, 'unarchiving', source_key: src.key)
        unless Basic.unarchive(src.key)
          raise "[IntegrateRake] Failed to restore archived source project #{src.key}"
        end
      else
        raise "[IntegrateRake] Source project #{src.key} data is not available locally"
      end
    end

    file_paths = source_projects.map { |p|
      p_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      p_dir + 'parsing' + 'output.loom'
    }.join(",")

    integrate_method = h_attrs['integrate_method'].presence
    unless integrate_method.present? && Basic::INTEGRATION_METHODS.include?(integrate_method.to_s)
      integrate_method = 'harmony'
    end

    loom_file = project_dir + 'parsing' + "output.loom"

    batch_paths_hash = h_attrs['integrate_batch_paths']
    batch_paths_hash = {} unless batch_paths_hash.is_a?(Hash)
    batch_paths_list = project_keys.map do |key|
      val = batch_paths_hash.is_a?(Hash) ? (batch_paths_hash[key] || batch_paths_hash[key.to_sym]) : nil
      val.present? && val.to_s != 'null' ? val.to_s : 'null'
    end
    batch_paths = batch_paths_list.join(',')

    r_opts = [
      { 'opt' => '--input_looms', 'value' => file_paths },
      { 'opt' => '--output_path', 'value' => loom_file.to_s },
      { 'opt' => '--method', 'value' => integrate_method.to_s }
    ]
    r_opts << { 'opt' => '--batch_paths', 'value' => batch_paths } if batch_paths_hash.any?
    unless integrate_method.to_s == 'uncorrected'
      n_pcs = h_attrs['integrate_n_pcs'].presence&.to_i
      n_pcs = 50 if n_pcs.nil? || n_pcs < 1
      r_opts << { 'opt' => '--n_pcs', 'value' => n_pcs.to_s }
    end

    Basic.broadcast_integration_status(project, 'integrating')

    # Step 1: Run R integration script
    h_cmd_r = {
      'host_name' => "localhost",
      'time_call' => h_env["time_call"]&.gsub(/\#output_dir/, tmp_dir.to_s),
      'container_name' => ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev') + "_" + run.id.to_s,
      'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
      'program' => "Rscript integration.v8.R",
      'opts' => r_opts,
      'args' => []
    }

    cmd = Basic.build_cmd(h_cmd_r)
    puts "CMD_R: #{cmd}"
    r_output = `#{cmd} 2>&1`
    r_exitstatus = $?.exitstatus
    puts "R_OUTPUT: #{r_output}"
    puts "R_EXITSTATUS: #{r_exitstatus}"

    r_result = Basic.integration_r_result_from_output(r_output)
    if r_result && r_result['displayed_error'].present?
      err = r_result['displayed_error']
      err = err.is_a?(Array) ? err.join(' ') : err.to_s
      raise "[IntegrateRake] R integration failed: #{err}"
    end
    unless r_exitstatus == 0
      friendly = Basic.integration_command_error_message(r_output, context: 'R integration')
      raise "[IntegrateRake] #{friendly}"
    end
    unless File.exist?(loom_file)
      raise "[IntegrateRake] R integration failed: output loom file not found at #{loom_file}. #{r_output.to_s.strip.split("\n").last(5).join(' ')}"
    end
    unless Basic.loom_has_main_matrix?(loom_file, image_name: image_name)
      raise "[IntegrateRake] R integration produced an invalid loom (missing /matrix) at #{loom_file} (#{File.size(loom_file)} bytes)"
    end
    logger.info("[IntegrateRake] R integration produced #{loom_file} (#{File.size(loom_file)} bytes, matrix present)")

    Basic.broadcast_integration_status(project, 'parsing')

    # Step 2: Parse the integrated file (copy first so parse cannot destroy the R output)
    parse_input_loom = tmp_dir + 'integrated_input.loom'
    FileUtils.cp(loom_file, parse_input_loom)

    opts = [
      {'opt' => "--organism", 'value' => project.organism_id.to_s},
      {'opt' => "--filetype", 'value' => 'LOOM'},
      {'opt' => "-o", 'value' => tmp_dir.to_s},
      {'opt' => "-f", 'value' => parse_input_loom.to_s},
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

    # Persist the real parse command used inside the container (after R integration).
    run.update_columns(command_json: h_cmd_parse.to_json)

    cmd_parse = Basic.build_cmd(h_cmd_parse)
    puts "CMD_PARSE: #{cmd_parse}"
    parse_output = `#{cmd_parse} 2>&1`
    parse_exitstatus = $?.exitstatus
    puts "PARSE_OUTPUT: #{parse_output}"
    puts "PARSE_EXITSTATUS: #{parse_exitstatus}"

    output_json_parse = tmp_dir + "output.json"
    h_parsing = {}
    if File.exist?(output_json_parse)
      h_parsing = Basic.safe_parse_json(File.read(output_json_parse), {})
    end

    stdout_parse = Basic.parse_result_from_command_output(parse_output)
    if stdout_parse && stdout_parse['displayed_error'].present?
      err = stdout_parse['displayed_error']
      err = err.is_a?(Array) ? err.join(' ') : err.to_s
      h_parsing['displayed_error'] = [err]
      File.open(output_json_parse.to_s, 'w') { |f| f.write(h_parsing.to_json) } rescue nil
    end

    parse_error = h_parsing["displayed_error"]
    if parse_error.present?
      message = parse_error.is_a?(Array) ? parse_error.join(' ') : parse_error.to_s
      raise "[IntegrateRake] Parsing failed: #{message}"
    end
    unless parse_exitstatus == 0
      tail = parse_output.to_s.strip.split("\n").last(5).join(' ')
      raise "[IntegrateRake] Parsing exited with status #{parse_exitstatus}. #{tail}"
    end
    unless h_parsing["nber_cols"] && h_parsing["nber_rows"]
      raise "[IntegrateRake] Parsing output.json missing nber_cols/nber_rows at #{output_json_parse}"
    end

    project.update_columns(
      nber_cols: h_parsing["nber_cols"],
      nber_rows: h_parsing["nber_rows"],
      extension: 'loom'
    )
    logger.info("[IntegrateRake] Set counts from parsing: #{h_parsing["nber_cols"]} cells, #{h_parsing["nber_rows"]} genes")

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
    Basic.broadcast_integration_status(project, 'completed')
    logger.info("[IntegrateRake] Integration completed for project #{project_key}")

  rescue => e
    user_error = Basic.integration_user_error_message(e.message)
    Basic.broadcast_integration_status(project, 'failed', error: user_error) if project
    logger.error("[IntegrateRake] Error during integration for project #{project_key}: #{e.class} - #{e.message}")
    logger.error(e.backtrace.join("\n")) if e.backtrace

    Basic.write_parsing_output_json_displayed_error(project_dir, logger, user_error) if project_dir

    run.update(status_id: 4, error: user_error) if run
    Basic.upd_project_step(project, parsing_step.id) if project_step
    project.update(status_id: 4)
    project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)

    raise e
  end
end
