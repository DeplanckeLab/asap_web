desc 'Parse project data (executed by SLURM)'
task :parse, [:project_key] => [:environment] do |t, args|
  puts 'Executing parse...'
  
  now = Time.now
  logger = Rails.logger
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
  Dir.mkdir(tmp_dir) if !File.exist?(tmp_dir)

  parsing_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'parsing').first
  unless parsing_step
    logger.error("[ParseRake] Could not find parsing step for docker image #{asap_docker_image.id}")
    exit 1
  end
  
  run = Run.where(:project_id => project.id, :step_id => parsing_step.id).first
  unless run
    logger.error("[ParseRake] No run found for project #{project_key}")
    exit 1
  end
  
  project_step = ProjectStep.find_by(:project_id => project.id, :step_id => parsing_step.id)
  
  # Update status to running and broadcast
  project_step.update(status_id: 2) if project_step
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
      fu = Fu.where(:project_id => project.id, :upload_type => 1).first
      upload_base_dir = ENV["UPLOAD_DATA_DIR"] || ENV["DATA_DIR"]
      upload_dir = Pathname.new(upload_base_dir) + 'fus' + fu.id.to_s
      output_file = upload_dir + "output.json"
      puts output_file
      h_preparsing = Basic.safe_parse_json(File.read(output_file), {})
      puts h_preparsing.to_json
      if list_group = h_preparsing['list_groups'][0]
        run.update({
                                :pred_max_ram => (list_group['pred_max_ram'] != '') ? list_group['pred_max_ram'] : nil, 
                                :pred_process_duration => (list_group['pred_process_duration']) ? list_group['pred_process_duration'] : nil
                              })
      end

      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)

      ### get parameters (potentially updated by get_loom_from_hca)
      puts project.id

      project = Project.find(project.id)
      p = Basic.safe_parse_json(project.parsing_attrs_json, {})
      puts "h_params2: " + p.to_json

      opts = []
      p['sel_name'] = 'mtx' if p["file_type"] == 'MEX'
      opts.push({'opt' => "-sel", 'value' => p['sel_name']}) if p['sel_name'] 
      opts.push({'opt' => "-col", 'value' => p["gene_name_col"]}) if p["gene_name_col"]
      opts.push({'opt' => "-d", 'value' => p["delimiter"]}) if p["delimiter"] and p['delimiter'] != ''
      opts.push({'opt' => "-header", 'value' => ((p['has_header'] and p['has_header'].to_i == 1) ? 'true' : 'false')}) if  p['has_header']
      opts.push({'opt' => '--row-names', 'value' => p['rowname_metadata']}) if p['rowname_metadata']
      opts.push({'opt' => '--col-names', 'value' => p['colname_metadata']}) if p['colname_metadata']

      h_types = {
        'MEX' => "H5_10x",
        'RDS' => "LOOM"
      }
      
      opts += [
               {'opt' => "-ncells", 'value' => p["nber_cols"]},
               {'opt' => "-ngenes", 'value' => p["nber_rows"]},
               {'opt' => "-type", 'value' => (h_types[p["file_type"]]) ? h_types[p["file_type"]] : p["file_type"]},
               {'opt' => '-T', 'value' => "Parsing"},
               {'opt' => "-organism", 'value' => project.organism_id},
               {'opt' => "-o", 'value' => tmp_dir},
               {'opt' => "-f", 'value' => filepath},
               {'opt' => '-h', 'value' => db_conn}
              ]
      
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
      `#{cmd_parse}`
      h_parsing = Basic.safe_parse_json(File.read(output_json), {})
      if  p["file_type"] == 'MEX'
        h_parsing['detected_format'] = 'MEX'
        File.open(output_json, 'w') do |fw|
          fw.write(h_parsing.to_json)
        end
      end

      # Parsing is complete - update status and broadcast
      project_step.update(status_id: 3) if project_step
      project.update(status_id: 3)
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      logger.info("[ParseRake] Parsing completed, broadcasting update")

      ## 
      puts "Define project cell set"
      Basic.upd_project_cell_set(project)
      puts "=> " + project.project_cell_set.key

      h_parsing_metadata = {}
      puts h_parsing.to_json
      if h_parsing['metadata']
        h_parsing['metadata'].each do |meta|
          h_parsing_metadata[meta['name']] = 1
        end
      end
      fu = Fu.where(:project_id => project.id, :upload_type => 1).first
      upload_base_dir = ENV["UPLOAD_DATA_DIR"] || ENV["DATA_DIR"]
      upload_dir = Pathname.new(upload_base_dir) + 'fus' + fu.id.to_s
      output_file = upload_dir + "output.json"
      output_path = project_dir + "parsing" + "output.loom"
      upload_data_dir = ENV["UPLOAD_DATA_DIR"] || ENV["DATA_DIR"]
      ori_fu_path = Pathname.new(upload_data_dir) + 'fus' + fu.id.to_s + fu.upload_file_name
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
        list_metadata = h_parsing["existing_metadata"].select{|e| !h_parsing_metadata[e]}
        if list_metadata
          relative_filepath = Basic.relative_path(project, output_path)
          list_metadata.each do |meta|
            meta['imported'] = true
            puts "add annot #{meta.to_json}"
            Basic.load_annot(run, meta, relative_filepath, h_data_types, h_data_classes, logger)
          end
        end
     elsif ["RDS"].include? h_preparsing["detected_format"]  and h_preparsing["list_groups"][0]["existing_metadata"]
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
     elsif ["LOOM"].include? h_preparsing["detected_format"]  and h_preparsing["list_groups"][0]["existing_metadata"]
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

    else
      h_output = {"displayed_error" => ["Error retrieving data from HCA", h_output_hca["error"]]}
            
      ##write HCA error in output.json
      File.open(output_json_file, 'w') do |f|
        f.write h_output.to_json
      end
      
      # Broadcast error
      project_step.update(status_id: 4) if project_step
      project.update(status_id: 4)
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      logger.error("[ParseRake] HCA error occurred, broadcasting failure")
    end
    
  end
end
