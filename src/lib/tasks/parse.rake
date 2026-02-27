desc 'Parse project data (executed by SLURM)'
task :parse, [:project_key] => [:environment] do |t, args|
  puts 'Executing parse...'
  
  now = Time.now
  logger = Rails.logger
  profile_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  phase_starts = {}
  phase_start = lambda do |name|
    phase_starts[name] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    logger.info("[ParseRake][Profile] START #{name}")
  end
  phase_end = lambda do |name|
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    t0 = phase_starts[name]
    elapsed = t0 ? (t1 - t0) : 0.0
    total = t1 - profile_t0
    logger.info("[ParseRake][Profile] END #{name} elapsed=#{format('%.3f', elapsed)}s total=#{format('%.3f', total)}s")
  end
  puts args[:project_key]

  project_key = args[:project_key]
  project = Project.where(:key => project_key).first
  
  unless project
    logger.error("[ParseRake] Project with key #{project_key} not found")
    exit 1
  end
  
  version = project.version
  unless version
    logger.error("[ParseRake] Project #{project_key} has no version")
    exit 1
  end
  
  h_env = Basic.safe_parse_json(version.env_json, {})
  asap_docker_image = Basic.get_asap_docker(version)
  
  unless asap_docker_image
    logger.error("[ParseRake] Could not find ASAP docker image for version #{version.id}")
    exit 1
  end
  
  db_conn = "postgres:5434/asap2_data_v" + h_env['asap_data_db_version'].to_s
  
  project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
  tmp_dir = project_dir + 'parsing'
  # Create directory with world-writable permissions so Docker container (user 1006) can write to it
  FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
  # Ensure directory is writable by the Java command (runs as user 1006 in Docker container)
  # Use FileUtils.chmod with force option to ensure permissions are set even if directory already exists
  begin
    FileUtils.chmod(0777, tmp_dir)
    logger.info("[ParseRake] Set permissions on #{tmp_dir} to 0777")
  rescue => e
    logger.warn("[ParseRake] Could not set permissions on #{tmp_dir}: #{e.message}")
  end

  parsing_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'parsing').first
  unless parsing_step
    logger.error("[ParseRake] Could not find parsing step for docker image #{asap_docker_image.id}")
    exit 1
  end

  parsing_attrs = Basic.safe_parse_json(project.parsing_attrs_json, {})
  reset_mode = parsing_attrs['reset_mode'] == true || parsing_attrs['reset_mode'].to_s == 'true' || parsing_attrs['reset_mode'].to_s == '1'
  
  # Always use the latest parsing run for this project.
  run = Run.where(:project_id => project.id, :step_id => parsing_step.id).order(created_at: :desc, id: :desc).first
  unless run
    logger.error("[ParseRake] No run found for project #{project_key}")
    exit 1
  end

  if reset_mode
    phase_start.call('reset_cleanup')
    logger.info("[ParseRake] reset_mode enabled for project #{project_key}; full cleanup before parsing")
    logger.info("[ParseRake][Debug] pre-cleanup counts project=#{project.key} runs=#{project.runs.count} annots=#{Annot.where(project_id: project.id).count} ot_projects=#{OtProject.where(project_id: project.id).count} checkpoints=#{Checkpoint.where(project_id: project.id).count}")

    # Batch cleanup for performance:
    # delete run-linked records and annot-linked records with set-based SQL.
    runs_scope = project.runs.where.not(id: run.id)
    annots_scope = Annot.where(project_id: project.id)
    conn = ActiveRecord::Base.connection

    runs_scope.where.not(slurm_job_id: nil).pluck(:id, :slurm_job_id).each do |run_id, slurm_job_id|
      begin
        slurm_service = SlurmService.new(logger: Rails.logger)
        slurm_service.cancel_job(slurm_job_id)
      rescue => e
        logger.error("[ParseRake] Error cancelling SLURM job for run #{run_id}: #{e.message}")
      end
    end

    if conn.data_source_exists?('cla_votes')
      conn.execute(<<~SQL)
        DELETE FROM cla_votes
        WHERE cla_id IN (
          SELECT clas.id
          FROM clas
          INNER JOIN annots ON annots.id = clas.annot_id
          WHERE annots.project_id = #{project.id.to_i}
        )
      SQL
    end
    AnnotCellSet.where(annot_id: annots_scope.select(:id)).delete_all
    Cla.where(annot_id: annots_scope.select(:id)).delete_all
    OtProject.where(project_id: project.id, annot_id: annots_scope.select(:id)).delete_all
    annots_scope.delete_all

    ActiveRun.where(run_id: runs_scope.select(:id)).delete_all
    Fo.where(run_id: runs_scope.select(:id)).delete_all
    DelRun.where(project_id: project.id, run_id: runs_scope.select(:id)).delete_all
    if conn.data_source_exists?('tmp_fos')
      conn.execute("DELETE FROM tmp_fos WHERE run_id IN (SELECT id FROM runs WHERE project_id = #{project.id.to_i} AND id != #{run.id.to_i})")
    end
    runs_scope.delete_all

    # Delete checkpoints and their embedded comments for this project.
    Checkpoint.where(project_id: project.id).delete_all

    # Delete all sub-directories in project directory.
    if File.exist?(project_dir)
      Dir.children(project_dir).each do |entry|
        sub_path = project_dir + entry
        next unless File.directory?(sub_path)
        FileUtils.rm_rf(sub_path)
      end
    end

    # Reset project steps and deduplicate rows.
    ProjectStep.where(project_id: project.id).select(:step_id).distinct.pluck(:step_id).each do |step_id|
      rows = ProjectStep.where(project_id: project.id, step_id: step_id).order(:id).to_a
      if rows.size > 1
        duplicate_ids = rows[0..-2].map(&:id)
        ProjectStep.where(id: duplicate_ids).delete_all if duplicate_ids.any?
      end
      project_step = ProjectStep.where(project_id: project.id, step_id: step_id).order(:id).last
      project_step.update(status_id: nil, error_message: nil, nber_runs_json: '{}') if project_step
      Basic.upd_project_step(project, step_id)
    end
    logger.info("[ParseRake][Debug] post-cleanup counts project=#{project.key} runs=#{project.runs.count} annots=#{Annot.where(project_id: project.id).count} ot_projects=#{OtProject.where(project_id: project.id).count} checkpoints=#{Checkpoint.where(project_id: project.id).count}")

    parsing_attrs.delete('reset_mode')
    project.update(parsing_attrs_json: parsing_attrs.to_json)
    FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
    FileUtils.chmod(0777, tmp_dir) if File.exist?(tmp_dir)
    # Recreate flow can reuse the same Run row; clear timing fields so wait/elapsed
    # are computed for the current execution only.
    reset_timestamp = Time.current
    run.update(
      status_id: 1,
      error: nil,
      created_at: reset_timestamp,
      submitted_at: reset_timestamp,
      start_time: nil,
      waiting_duration: nil,
      duration: nil,
      process_duration: nil
    )
    logger.info("[ParseRake][Debug] reset_mode timing reset for run #{run.id}")
    project.reload
    phase_end.call('reset_cleanup')
  end
  
  project_step = ProjectStep.find_by(:project_id => project.id, :step_id => parsing_step.id)
  
  # Update run status to running and calculate waiting_duration
  # Set start_time and waiting_duration when parse.rake actually starts executing
  start_time = Time.now
  waiting_duration = run.submitted_at ? (start_time - run.submitted_at).to_f : nil
  
  # Update run status, start_time, and waiting_duration if not already set
  # (SlurmJobMonitorJob might have already set them, but if not, we set them here)
  if run.status_id == 1 || !run.start_time
    run.update(
      status_id: 2,
      start_time: start_time,
      waiting_duration: waiting_duration
    )
    logger.info("[ParseRake] Updated run #{run.id} to running, waiting_duration: #{waiting_duration}")
  end
  logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} entered execution block with run.status_id=#{run.status_id}, start_time=#{run.start_time}")
  
  # Recompute project_step run counters whenever run status changes.
  Basic.upd_project_step(project, parsing_step.id)
  project_step.reload if project_step
  # Keep project_step status in sync in case the aggregate did not set it yet.
  project_step.update(status_id: 2) if project_step && project_step.status_id != 2
  project.update(status_id: 2)
  project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
  logger.info("[ParseRake] Updated project status to running, broadcasting update")
  
  h_data_types = {}
  DataType.all.map{|dt| h_data_types[dt.name] = dt}
  
  h_data_classes = {}
  DataClass.all.map{|dt| h_data_classes[dt.name] = dt; h_data_classes[dt.id] = dt}

  if project
    puts "parse"
  
    p = Basic.safe_parse_json(project.parsing_attrs_json, {})

    output_json_file = project_dir + 'parsing' + "output.json"
    
    filepath = project_dir + ("input." + project.extension)
    
    ### write file from hca
    h_output_hca = nil
    if p['provider_project_id'] and p['provider_project_id'] != ''
      cmd = "rails get_loom_from_hca[#{project.key}] 2>&1 > #{tmp_dir + 'get_loom_from_hca.log'}"
      `#{cmd}`
      puts "CMDx: " + cmd
      hca_output_json_file = project_dir + 'parsing' + "get_loom_from_hca.json"
      if File.exist? hca_output_json_file
        h_output_hca = Basic.safe_parse_json(File.read(hca_output_json_file), {})
      else
        h_output_hca = {'status_id' => 4, 'error' => 'An error occured while getting Loom file from HCA'}
      end
    end

    puts h_output_hca.to_json

    if !h_output_hca or h_output_hca['status_id'] != 4

      ### update run with predictions
      # Try to find Fu by project.fu_id first, then fall back to project_id lookup
      fu = if project.fu_id
             Fu.find_by(id: project.fu_id)
           else
             Fu.where(:project_id => project.id, :upload_type => 1).first
           end
      
      if fu.nil?
        logger.warn("[ParseRake] No Fu record found for project #{project.key} (fu_id: #{project.fu_id}), skipping prediction update")
      else
        phase_start.call('load_preparsing_predictions')
        begin
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
            puts output_file
            h_preparsing = Basic.safe_parse_json(File.read(output_file), {})
            puts h_preparsing.to_json
            if list_group = h_preparsing['list_groups'][0]
              run.update({
                                      :pred_max_ram => (list_group['pred_max_ram'] != '') ? list_group['pred_max_ram'] : nil, 
                                      :pred_process_duration => (list_group['pred_process_duration']) ? list_group['pred_process_duration'] : nil
                                    })
            end
          else
            logger.warn("[ParseRake] Output file not found: #{output_file}")
          end
        rescue => e
          logger.error("[ParseRake] Error reading prediction file: #{e.class} - #{e.message}")
          logger.error(e.backtrace.join("\n")) if e.backtrace
        ensure
          phase_end.call('load_preparsing_predictions')
        end
      end

      ### get parameters (potentially updated by get_loom_from_hca)
      puts project.id

      project = Project.find(project.id)
      p = Basic.safe_parse_json(project.parsing_attrs_json, {})
      puts "h_params2: " + p.to_json

      opts = []
      p['sel_name'] = 'mtx' if p["file_type"] == 'MEX'
      opts.push({'opt' => "-sel", 'value' => p['sel_name']}) if p['sel_name'] 
      
      # Get file_type to determine if we need to add -col and -header defaults
      # Get file_type from parsing_attrs_json, or fall back to detected_format from preparsing
      file_type = p["file_type"]
      if file_type.blank?
        # Try to get detected_format from preparsing output
        begin
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
            h_preparsing = Basic.safe_parse_json(File.read(output_file), {})
            detected_format = h_preparsing['detected_format']
            if detected_format.present?
              file_type = detected_format
              logger.info("[ParseRake] Using detected_format from preparsing: #{detected_format}")
            end
          end
        rescue => e
          logger.warn("[ParseRake] Could not read preparsing output to get detected_format: #{e.message}")
        end
      end
      
      # Only add -col and -header for RAW_TEXT file type
      if file_type == 'RAW_TEXT'
        # -col parameter: gene name column (default: "first" if not specified)
        gene_name_col = p["gene_name_col"]
        if gene_name_col.blank? || gene_name_col == 'NA' || gene_name_col == 'none'
          gene_name_col = 'first'  # Default to first column
        end
        opts.push({'opt' => "-col", 'value' => gene_name_col})
        
        # -header parameter: whether file has header row (default: true if not specified)
        has_header = p['has_header']
        if has_header.nil? || has_header == ''
          has_header = '1'  # Default to true (has header)
        end
        header_value = (has_header.to_s == '1' || has_header.to_s == 'true') ? 'true' : 'false'
        opts.push({'opt' => "-header", 'value' => header_value})
      else
        # For non-RAW_TEXT types, only add if explicitly specified
        opts.push({'opt' => "-col", 'value' => p["gene_name_col"]}) if p["gene_name_col"].present?
        opts.push({'opt' => "-header", 'value' => ((p['has_header'] and p['has_header'].to_i == 1) ? 'true' : 'false')}) if p['has_header'].present?
      end
      
      opts.push({'opt' => "-d", 'value' => p["delimiter"]}) if p["delimiter"] and p['delimiter'] != ''
      
      opts.push({'opt' => '--row-names', 'value' => p['rowname_metadata']}) if p['rowname_metadata']
      opts.push({'opt' => '--col-names', 'value' => p['colname_metadata']}) if p['colname_metadata']

      h_types = {
        'MEX' => "H5_10x",
        'RDS' => "LOOM"
      }
      
      opts += [
               {'opt' => "-ncells", 'value' => p["nber_cols"]},
               {'opt' => "-ngenes", 'value' => p["nber_rows"]},
               {'opt' => '-T', 'value' => "Parsing"},
               {'opt' => "-organism", 'value' => project.organism_id},
               {'opt' => "-o", 'value' => tmp_dir},
               {'opt' => "-f", 'value' => filepath},
               {'opt' => '-h', 'value' => db_conn}
              ]
      
      # Add -type option - use detected_format if file_type is not set
      # Map common format names to Java command format names
      file_type_value = if file_type.present?
                          (h_types[file_type]) ? h_types[file_type] : file_type
                        else
                          # Default to RAW_TEXT if nothing is available
                          logger.warn("[ParseRake] No file_type found, defaulting to RAW_TEXT")
                          "RAW_TEXT"
                        end
      
      # -type is mandatory according to Java command, so always include it
      opts.push({'opt' => "-type", 'value' => file_type_value})

      if version.id >= 8


#      usage: parse.v8.py -f File to parse [-o Output folder] --filetype File type [--header [RAW_TEXT] Is there a header] [--col [RAW_TEXT] Which column contains row names]                 
#                   [--sel In case of multiple matrices, which one to use] [--delim [RAW_TEXT] Delimiter to parse columns] --organism Organism --dburl Host URL for DB                        
#                   (format HOST:PORT/DB)                                                                                                                                                     
#parse.v8.py: error: the following arguments are required: -f, --filetype, --organism, --dburl                                                                                                

        opts = []
        sel_name = p['sel_name'] || p[:sel_name] || p['sel'] || p[:sel]
        if file_type == 'H5AD' && sel_name.present? && !sel_name.start_with?('/')
          sel_name = (sel_name == 'X') ? '/X' : "/layers/#{sel_name}"
        end
        opts.push({'opt' => "--sel", 'value' => sel_name}) if sel_name.present?
        if file_type == 'RAW_TEXT'
          gene_name_col = p['gene_name_col'] || p[:gene_name_col] || 'first'
          has_header = p['has_header'] || p[:has_header]
          header_value = (has_header == '1' || has_header == true || has_header == 'true') ? 'true' : 'false'
          opts.push({'opt' => "--col", 'value' => gene_name_col}) if gene_name_col
          opts.push({'opt' => "--header", 'value' => header_value})
        end

        opts.push({'opt' => "--delim", 'value' => p["delimiter"]}) if p["delimiter"] and p['delimiter'] != ''

        #opts.push({'opt' => '--row-names', 'value' => p['rowname_metadata']}) if p['rowname_metadata']                                                                                       
        #opts.push({'opt' => '--col-names', 'value' => p['colname_metadata']}) if p['colname_metadata']                                                                                       

        opts += [
          #          {'opt' => "-ncells", 'value' => p["nber_cols"]},                                                                                                                         
          #          {'opt' => "-ngenes", 'value' => p["nber_rows"]},                                                                                                                         
          {'opt' => "--organism", 'value' => project.organism_id},
          {'opt' => "--filetype", 'value' => file_type},
          {'opt' => "-o", 'value' => tmp_dir},
          {'opt' => "-f", 'value' => filepath},
          {'opt' => '--dburl', 'value' => db_conn}
        ]


        h_env_docker_image = h_env['docker_images']['asap_run']
        image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']

        asap_instance_name = ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev')
        h_cmd_parse = {
          'host_name' => "localhost",
          'time_call' => h_env["time_call"].gsub(/\#output_dir/, tmp_dir.to_s),
          'container_name' => asap_instance_name + "_" + run.id.to_s,
          'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
          'program' => "python3 parse.v8.py",
          'opts' => opts,
          'args' => []
        }

#        output_file = tmp_dir + "output.loom"                                                                                                                                                
#        output_json = tmp_dir + "output.json"                                                                                                                                                

        puts h_cmd_parse
        cmd_parse = Basic.build_cmd(h_cmd_parse)
        puts "CMD_PYTHON:" + cmd_parse
        `#{cmd_parse}`
        exit 0
      end

      
      mem = p["nber_cols"].to_i * p["nber_rows"].to_i * 128 / (31053 * 1474560)
      h_env_docker_image = h_env['docker_images']['asap_run']
      image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']
            
      asap_instance_name = ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev')
      h_cmd_parse = {
        'host_name' => "localhost",
        'time_call' => h_env["time_call"].gsub(/\#output_dir/, tmp_dir.to_s),
        'container_name' => asap_instance_name + "_" + run.id.to_s,
        'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
        'program' => "java -jar ASAP.jar",
        'opts' => opts,
        'args' => []
      }

      output_file = tmp_dir + "output.loom"
      output_json = tmp_dir + "output.json"

      puts h_cmd_parse
      cmd_parse = Basic.build_cmd(h_cmd_parse)
      puts "CMD_JAVA:" + cmd_parse
      phase_start.call('parse_java_command')
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} executing parse command")
      `#{cmd_parse}`
      cmd_exitstatus = $?.exitstatus
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} parse command finished with exitstatus=#{cmd_exitstatus}")
      unless File.exist?(output_json)
        logger.error("[ParseRake][Debug] project=#{project.key} run=#{run.id} expected output_json missing at #{output_json}")
      end
      if File.exist?(output_json)
        logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} output_json size=#{File.size(output_json)} mtime=#{File.mtime(output_json)}")
      end
      h_parsing = Basic.safe_parse_json(File.read(output_json), {})
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} parsed output_json keys=#{h_parsing.keys.sort.join(',')}")
      phase_end.call('parse_java_command')
      if  p["file_type"] == 'MEX'
        h_parsing['detected_format'] = 'MEX'
        File.open(output_json, 'w') do |fw|
          fw.write(h_parsing.to_json)
        end
      end

      # Parse exec_run_details.log to extract max_ram and process_duration
      exec_run_details_file = tmp_dir + 'exec_run_details.log'
      max_ram_mb = nil
      process_duration_seconds = nil
      
      if File.exist?(exec_run_details_file)
        logger.info("[ParseRake] Reading exec_run_details.log from #{exec_run_details_file}")
        h_time_info = {}
        
        File.readlines(exec_run_details_file).each do |line|
          t = line.split(",")
          if t.size > 1
            t.each do |e|
              if m = e.match(/^([A-Za-z])=([\d\:.]+)$/)
                h_time_info[m[1]] = m[2]
              end
            end
          end
        end
        
        logger.info("[ParseRake] Parsed time info: #{h_time_info.to_json}")
        
        # Extract max_ram from M= (in KB, convert to MB)
        if h_time_info['M']
          max_ram_kb = h_time_info['M'].to_f
          max_ram_mb = (max_ram_kb / 1024.0).round(2)
          logger.info("[ParseRake] Extracted max_ram: #{max_ram_kb} KB = #{max_ram_mb} MB")
        end
        
        # Extract process_duration from E= (elapsed time)
        if h_time_info['E']
          process_duration_seconds = 0.0
          t = h_time_info['E'].split(":")
          if t.size == 1
            # Case of docker-compose context (e.g., "1h 2m 3.45s")
            t_str = h_time_info['E']
            t_str.scan(/([\d.]+)s/) { |match| process_duration_seconds += match[0].to_f }
            t_str.scan(/([\d]+)m/) { |match| process_duration_seconds += match[0].to_f * 60 }
            t_str.scan(/([\d]+)h/) { |match| process_duration_seconds += match[0].to_f * 3600 }
            t_str.scan(/([\d]+)d/) { |match| process_duration_seconds += match[0].to_f * 3600 * 24 }
          else
            # Standard format HH:MM:SS or MM:SS
            if t.size == 3
              process_duration_seconds += t[0].to_f * 3600
            end
            if t.size >= 2
              process_duration_seconds += t[t.size - 2].to_f * 60
              process_duration_seconds += t[t.size - 1].to_f
            end
          end
          process_duration_seconds = process_duration_seconds.round(2)
          logger.info("[ParseRake] Extracted process_duration: #{h_time_info['E']} = #{process_duration_seconds} seconds")
        end
      else
        logger.warn("[ParseRake] exec_run_details.log not found at #{exec_run_details_file}")
      end
      
      # Calculate duration from start_time if available
      duration_seconds = nil
      if run.start_time
        duration_seconds = (Time.now - run.start_time).to_f
        logger.info("[ParseRake] Calculated duration from start_time: #{duration_seconds} seconds")
      end
      
      # Parsing is complete - call finish_run to create annotations (including matrix annotation)
      # finish_run will set status_id = 3 and create all necessary annotations
      # finish_run builds h_output_files from step.output_json (expected_outputs) and files in output_dir
      # It uses h_results['nber_rows'] and h_results['nber_cols'] for matrix dimensions
      logger.info("[ParseRake] Calling Basic.finish_run to create annotations for run #{run.id}")
      logger.info("[ParseRake] h_parsing has nber_rows=#{h_parsing['nber_rows']}, nber_cols=#{h_parsing['nber_cols']}")
      
      # Call finish_run with h_parsing as h_results.
      # skip_broadcast: true because finish_run broadcasts before we update project.status_id,
      # so we do a single broadcast below with the correct project status.
      phase_start.call('finish_run')
      begin
        logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} calling Basic.finish_run")
        Basic.finish_run(logger, run, h_parsing, skip_broadcast: true)
        logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} Basic.finish_run returned")
      rescue => e
        logger.error("[ParseRake][Debug] project=#{project.key} run=#{run.id} Basic.finish_run raised #{e.class}: #{e.message}")
        logger.error("[ParseRake][Debug] project=#{project.key} run=#{run.id} finish_run backtrace: #{e.backtrace.first(10).join("\n")}") if e.backtrace
        raise
      ensure
        phase_end.call('finish_run')
      end
      
      # Reload run to get updated status and metrics from finish_run
      run.reload
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} after finish_run reload status_id=#{run.status_id}, duration=#{run.duration}, process_duration=#{run.process_duration}")
      
      # Update metrics that finish_run doesn't handle (max_ram, process_duration from exec_run_details.log)
      run_updates = {}
      run_updates[:max_ram] = max_ram_mb if max_ram_mb && run.max_ram != max_ram_mb
      run_updates[:process_duration] = process_duration_seconds if process_duration_seconds && run.process_duration != process_duration_seconds
      run.update(run_updates) if run_updates.any?
      
      annot_count = Annot.where(run_id: run.id).count
      logger.info("[ParseRake] finish_run completed for run #{run.id}, status_id=#{run.status_id}, annotations created: #{annot_count}")
      
      # finish_run already called upd_project_step via upd_run, so only set project status here
      project.update(status_id: 3)
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      logger.info("[ParseRake] Parsing completed, broadcasting update")

      ## 
      puts "Define project cell set"
      phase_start.call('update_project_cell_set')
      Basic.upd_project_cell_set(project)
      project.reload
      phase_end.call('update_project_cell_set')
      if project.project_cell_set
        puts "=> " + project.project_cell_set.key
      else
        logger.warn("[ParseRake] Project cell set not created for project #{project.key}")
      end

      h_parsing_metadata = {}
      puts h_parsing.to_json
      if h_parsing['metadata']
        h_parsing['metadata'].each do |meta|
          h_parsing_metadata[meta['name']] = 1
        end
      end
      # Try to find Fu by project.fu_id first, then fall back to project_id lookup
      fu = if project.fu_id
             Fu.find_by(id: project.fu_id)
           else
             Fu.where(:project_id => project.id, :upload_type => 1).first
           end
      
      if fu.nil?
        logger.warn("[ParseRake] No Fu record found for project #{project.key} (fu_id: #{project.fu_id}), cannot proceed with metadata copying")
      else
        phase_start.call('metadata_copying')
        upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                            ENV["UPLOAD_DATA_DIR"]
                          elsif ENV["DATA_DIR"]
                            Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                          else
                            '/data/asap2/fus'
                          end
        upload_dir = Pathname.new(upload_base_dir) + fu.id.to_s
        output_file = upload_dir + "output.json"
        output_path = project_dir + "parsing" + "output.loom"
        upload_data_dir = if ENV["UPLOAD_DATA_DIR"]
                            ENV["UPLOAD_DATA_DIR"]
                          elsif ENV["DATA_DIR"]
                            Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                          else
                            '/data/asap2/fus'
                          end
        ori_fu_path = Pathname.new(upload_data_dir) + fu.id.to_s + fu.upload_file_name
        puts ori_fu_path
        h_preparsing = Basic.safe_parse_json(File.read(output_file), {})
        puts h_preparsing.to_json
        puts "bla"
        
        # Check if metadata copying is needed and broadcast start
        needs_metadata_copying = false
        if h_preparsing && h_preparsing["detected_format"]
          if (["RDS", "LOOM"].include?(h_preparsing["detected_format"]) && 
              h_preparsing["list_groups"] && h_preparsing["list_groups"][0] && 
              h_preparsing["list_groups"][0]["existing_metadata"]) ||
             (["H5AD"].include?(h_preparsing["detected_format"]) && 
              h_parsing["existing_metadata"])
            needs_metadata_copying = true
          end
        end
        
        # Broadcast metadata copying start if needed, or mark as complete if not needed
        if needs_metadata_copying
          ActionCable.server.broadcast "project_#{project.id}", {
            project_id: project.id,
            step_id: parsing_step.id,
            stage: 'creation',
            parsing_status: 'complete',
            parsing_complete: true,
            metadata_status: 'running',
            metadata_complete: false,
            project_key: project.key
          }
          logger.info("[ParseRake] Metadata copying starting, broadcasting update")
        else
          # No metadata copying needed - mark as complete immediately
          ActionCable.server.broadcast "project_#{project.id}", {
            project_id: project.id,
            step_id: parsing_step.id,
            stage: 'creation',
            parsing_status: 'complete',
            parsing_complete: true,
            metadata_status: 'complete',
            metadata_complete: true,
            all_complete: true,
            redirect_url: Rails.application.routes.url_helpers.project_path(project),
            project_key: project.key
          }
          logger.info("[ParseRake] No metadata copying needed, marking as complete")
        end

        if ["H5AD"].include? h_preparsing["detected_format"]
          phase_start.call('metadata_copy_h5ad')
          list_metadata = h_parsing["existing_metadata"].select{|e| !h_parsing_metadata[e]}
          if list_metadata
            relative_filepath = Basic.relative_path(project, output_path)
            list_metadata.each do |meta|
              meta['imported'] = true
              puts "add annot #{meta.to_json}"
              Basic.load_annot(run, meta, relative_filepath, h_data_types, h_data_classes, logger)
            end
          end
          phase_end.call('metadata_copy_h5ad')
        elsif ["RDS"].include? h_preparsing["detected_format"]  and h_preparsing["list_groups"][0]["existing_metadata"]
          phase_start.call('metadata_copy_rds')
          h_meta = {:meta => h_preparsing["list_groups"][0]["existing_metadata"].select{|e| !h_parsing_metadata[e]}}
          metadata_list_file = tmp_dir + 'list_metadata_to_copy.json'
          File.open(metadata_list_file, 'w') do |f|
            f.write(h_meta.to_json)
          end
          cmd = "java -jar lib/ASAP.jar -T CopyMetaData -loomFrom \"#{filepath}\" -loomTo #{output_path} -metaJSON #{metadata_list_file}"
          puts cmd
          output = `#{cmd}`
          metadata_list_file2 = tmp_dir + 'list_metadata_to_copy2.json'
          File.open(metadata_list_file2, 'w') do |f|
            f.write(output)
          end
          cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -no-values -loom #{output_path} -metaJSON #{metadata_list_file2}"
          puts cmd
          output = `#{cmd}`
          h_res = Basic.safe_parse_json(output, {})
          puts output
          puts h_res.to_json
          
          if list_metadata = h_res["list_meta"]
            relative_filepath = Basic.relative_path(project, output_path)
            list_metadata.each do |meta|
              meta['imported'] = true
              puts "add annot #{meta.to_json}"
              Basic.load_annot(run, meta, relative_filepath, h_data_types, h_data_classes, logger)
            end
          end
          phase_end.call('metadata_copy_rds')
        elsif ["LOOM"].include? h_preparsing["detected_format"]  and h_preparsing["list_groups"][0]["existing_metadata"]
          phase_start.call('metadata_copy_loom')
          puts "bou"
          h_meta = {:meta => h_preparsing["list_groups"][0]["existing_metadata"].select{|e| !h_parsing_metadata[e]}}
          metadata_list_file = tmp_dir + 'list_metadata_to_copy.json'
          File.open(metadata_list_file, 'w') do |f|
            f.write(h_meta.to_json)
          end
          cmd = "java -jar lib/ASAP.jar -T CopyMetaData -loomFrom \"#{ori_fu_path}\" -loomTo #{output_path} -metaJSON #{metadata_list_file}"
          puts cmd
          output = `#{cmd}`
          metadata_list_file2 = tmp_dir + 'list_metadata_to_copy2.json'
          File.open(metadata_list_file2, 'w') do |f|
            f.write(output)
          end
          cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -no-values -loom #{output_path} -metaJSON #{metadata_list_file2}"
          puts cmd
          output = `#{cmd}`
          h_res = Basic.safe_parse_json(output, {})
          puts output 
          puts h_res.to_json
          if list_metadata = h_res['list_meta']
            relative_filepath = Basic.relative_path(project, output_path)
            list_metadata.each do |meta|
              meta['imported'] = true
              puts "add annot #{meta.to_json}" 
              Basic.load_annot(run, meta, relative_filepath, h_data_types, h_data_classes, logger)
            end
          end
          phase_end.call('metadata_copy_loom')
        end

        # Broadcast completion after metadata copying (or if no metadata copying was needed)
        # If metadata copying was needed, it's now complete; if not needed, mark as complete
        ActionCable.server.broadcast "project_#{project.id}", {
          project_id: project.id,
          step_id: parsing_step.id,
          stage: 'creation',
          parsing_status: 'complete',
          parsing_complete: true,
          metadata_status: 'complete',
          metadata_complete: true,
          all_complete: true,
          redirect_url: Rails.application.routes.url_helpers.project_path(project),
          project_key: project.key
        }
        project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
        logger.info("[ParseRake] Parse and metadata copying completed, broadcasting final update")
        phase_end.call('metadata_copying')
      end

    else
      h_output = {"displayed_error" => ["Error retrieving data from HCA", h_output_hca["error"]]}
            
      ##write HCA error in output.json
      File.open(output_json_file, 'w') do |f|
        f.write h_output.to_json
      end
      
      # Broadcast error
      project_step.update(status_id: 4) if project_step
      Basic.upd_project_step(project, parsing_step.id)
      project.update(status_id: 4)
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      logger.error("[ParseRake] HCA error occurred, broadcasting failure")
    end
    
  end
end
