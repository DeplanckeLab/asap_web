require 'fileutils'
require 'open3'
require 'shellwords'

class FuPreparsingService
  def initialize(fu, options = {})
    @fu = fu
    @options = options || {}
    @logger = Rails.logger
  end

  def call
    service_started_at = Time.current
    @logger.info("[FuPreparsingService] Starting preparsing for Fu##{@fu.id}")
    @logger.info("[FuPreparsingService] Upload complete? #{@fu.complete?}")
    @logger.info("[FuPreparsingService] Upload status: #{@fu.status}")
    @logger.info("[FuPreparsingService] Upload file name: #{@fu.upload_file_name}")
    @logger.info("[FuPreparsingService] Upload file size: #{@fu.upload_file_size}")
    @logger.info("[FuPreparsingService] Options received: #{@options.inspect}")
    @logger.info("[FuPreparsingService] version_id in options: #{@options[:version_id].inspect}")
    @logger.info("[FuPreparsingService] organism_id in options: #{@options[:organism_id].inspect}")
    
    raise ArgumentError, 'Upload is not complete yet' unless @fu.complete?

    working_file = prepare_input_file
    @logger.info("[FuPreparsingService] Working file: #{working_file}")
    run_preparsing(working_file)

    output = load_output_json
    summary = build_summary(output)
    
    # Write predictions back to output.json so they're available when reading the file later
    # IMPORTANT: Pass the modified output hash, not the original one
    write_predictions_to_output(output, summary)
    
    # Reload output after writing to ensure we have the latest data
    output = load_output_json

    result_payload = {
      summary: summary,
      warnings: collect_warnings(output),
      raw_output: output,  # Include raw Python script output (now with predictions)
      prediction_debug: summary[:prediction_debug]  # Include prediction debug data
    }
    service_elapsed_ms = ((Time.current - service_started_at) * 1000).round
    @logger.info("[FuPreparsingService] Completed preparsing for Fu##{@fu.id} service_elapsed_ms=#{service_elapsed_ms}")
    result_payload
  end

  private

  def prepare_input_file
    path = @fu.file_path
    @logger.info("[FuPreparsingService] Fu##{@fu.id} file_path: #{path}")
    @logger.info("[FuPreparsingService] File exists? #{File.exist?(path)}")
    @logger.info("[FuPreparsingService] File size: #{File.size(path) if path && File.exist?(path)}")
    raise "Uploaded file missing for Fu ##{@fu.id}" unless path && File.exist?(path)

    # Python preparsing script handles all file formats (RDS, compressed files, etc.) internally
    # so we pass the original file directly
    path
  rescue StandardError => e
    raise "Input preparation failed: #{e.message}"
  end

  def run_preparsing(file_path)
    output_file = upload_dir + 'output.json'
    error_file = upload_dir + 'output.err'
    FileUtils.rm_f(output_file)
    FileUtils.rm_f(error_file)

    cmd = build_command(file_path)
    @command = cmd  # Store command for JSON output
    @logger.info("[FuPreparsingService] Running preparsing: #{cmd}")
    
    command_started_at = Time.current
    stdout_str, stderr_str, status = Open3.capture3(cmd)
    command_elapsed_ms = ((Time.current - command_started_at) * 1000).round

    @logger.info("[FuPreparsingService] Command exit status: #{status.exitstatus}")
    @logger.info("[FuPreparsingService] Command elapsed_ms: #{command_elapsed_ms}")
    @logger.info("[FuPreparsingService] STDOUT: #{stdout_str}") unless stdout_str.blank?
    @logger.info("[FuPreparsingService] STDERR: #{stderr_str}") unless stderr_str.blank?
    File.write(error_file, stderr_str.to_s) unless stderr_str.blank?

    # Python preparsing script may return non-zero exit code but still generate output.json with error info
    # Check if output file exists - if it does, we can process it even if command "failed"
    unless output_file.exist?
      error_msg = if error_file.exist? && !error_file.read.empty?
                    error_file.read
                  else
                    stderr_str.presence || stdout_str.presence || "Unknown error"
                  end
      # Persist the best-available failure detail so UI/support can inspect it later,
      # even when the script reports errors only on stdout and does not create output.json.
      if !error_file.exist? || error_file.read.empty?
        File.write(error_file, error_msg.to_s)
      end
      raise "Preparsing command failed (exit #{status.exitstatus}): #{error_msg}"
    end
    
    # Ensure output file is readable and writable by the Rails process
    # Since we run the command as root, the output file might be owned by root
    # We need to change ownership so Rails can write to it later
    if output_file.exist?
      begin
        # Get the current Rails process user/group
        rails_uid = Process.uid
        rails_gid = Process.gid
        
        # Change ownership to match Rails process
        File.chown(rails_uid, rails_gid, output_file.to_s)
        FileUtils.chmod(0664, output_file)
        @logger.info("[FuPreparsingService] Changed ownership of output.json to #{rails_uid}:#{rails_gid}")
      rescue => e
        @logger.warn("[FuPreparsingService] Could not change ownership/permissions on output file: #{e.message}")
        # Try chmod as fallback
        begin
          FileUtils.chmod(0666, output_file)  # Make world-writable as fallback
        rescue => e2
          @logger.warn("[FuPreparsingService] Could not chmod output file: #{e2.message}")
        end
      end
    end
  end

  def build_command(file_path)
    upload_dir_str = upload_dir.to_s

    @logger.info("[FuPreparsingService] Building command with file_path: #{file_path}")
    @logger.info("[FuPreparsingService] Upload directory: #{upload_dir_str}")
    @logger.info("[FuPreparsingService] File exists before command? #{File.exist?(file_path)}")

    #docker_tag = get_docker_image_tag
    # Construct script name using the tag (e.g., 'v8' -> 'preparse.v8.py')
    # Ensure tag has 'v' prefix
    #tag_with_v = docker_tag.start_with?('v') ? docker_tag : "v#{docker_tag}"
    python_script_name = "preparse.v8.py"
    
    script_args = ['python3', "/srv/#{python_script_name}"]
    script_args << '--sel' << @options[:sel].to_s if @options[:sel].present?
    script_args << '--col' << @options[:gene_name_col].to_s if @options[:gene_name_col].present?
    # Check if delimiter key exists and has a non-empty value
    # Empty string means tab delimiter - don't pass --delim argument (script defaults to tab)
    # Only pass --delim when delimiter is explicitly set to a non-empty value
    if @options.key?(:delimiter) && @options[:delimiter] != nil && @options[:delimiter].to_s != ''
      delim_value = @options[:delimiter].to_s
      # Add delimiter argument - Shellwords.join will handle proper escaping
      script_args << '--delim' << delim_value
    end
    if @options.key?(:has_header)
      header_value = (@options[:has_header] == '1' || @options[:has_header] == true) ? 'true' : 'false'
      script_args << '--header' << header_value
    end

    # Note: organism_id is not passed to the preparsing script
    # It's stored in options for use in predictions later
    script_args << '-f' << file_path.to_s
    script_args << '-o' << upload_dir_str
    script_cmd = Shellwords.join(script_args)
    
    @logger.info("[FuPreparsingService] fu upload dir: #{@fu.upload_dir}")
    @logger.info("[FuPreparsingService] File path to pass to Python: #{file_path}")
    @logger.info("[FuPreparsingService] Python script: #{python_script_name}")
    
    # Use docker exec on the configured ASAP run container
    # Run as rvmuser (UID 1006) which is the default user in the Dockerfile
    # This ensures files are created with the correct ownership
    # Set working directory to output directory so extracted files go there
    docker_cmd = [
      'docker', 'exec',
      '--user', '1006:1006',  # rvmuser:rvmuser (matches Dockerfile USER directive)
      '--workdir', upload_dir_str,  # Set working directory to output directory
      ENV.fetch('ASAP_RUN_CONTAINER'),
      '/bin/sh', '-c', script_cmd
     ]

    full_cmd = Shellwords.join(docker_cmd)
    @logger.info("[FuPreparsingService] Docker command: #{full_cmd}")
    full_cmd
  end

 

  def load_output_json
    output_path = upload_dir + 'output.json'
    raise "Missing output file at #{output_path}" unless output_path.exist?

    JSON.parse(output_path.read)
  rescue JSON::ParserError => e
    raise "Unable to parse preparsing output: #{e.message}"
  end

  def build_summary(output)
    @prediction_debug_data = []  # Store prediction debug info for each dataset
    
    # Check if we have any datasets
    list_groups = output['list_groups']
    if list_groups.blank? || (list_groups.is_a?(Array) && list_groups.empty?)
      @logger.warn("[FuPreparsingService] No datasets found in preparsing output. File may be an archive listing files only, or preparsing may have failed to detect matrix data.")
    end
    
    datasets = Array(list_groups).map do |group|
      # Parse genes and cells - they can be arrays (from JSON) or Python list strings like "['gene1', 'gene2']"
      genes = parse_genes_or_cells(group['genes'])
      cells = parse_genes_or_cells(group['cells'])
      
      nber_rows = group['nber_rows'] || group['nb_genes']
      nber_cols = group['nber_cols'] || group['nb_cells']
      
      dataset_hash = {
        name: group['group'],
        cell_count: nber_cols,  # Use nber_cols if available
        gene_count: nber_rows,  # Use nber_rows if available
        predicted_ram: group['pred_max_ram'],
        predicted_duration: group['pred_process_duration'],
        is_count_matrix: group['is_count'] == 1 || group['is_count'] == '1' || group['is_count'] == true,
        metadata: group['metadata'],
        existing_metadata: group['existing_metadata'],
        sample_matrix: group['matrix'],  # Include sample matrix
        genes: genes,  # Parsed gene names array
        cells: cells   # Parsed cell names array
      }
      
      # Get predictions if we have dimensions
      if nber_rows && nber_cols && nber_rows.to_i > 0 && nber_cols.to_i > 0
        prediction_result = get_predictions(nber_rows.to_i, nber_cols.to_i)
        
        # prediction_result should always be a hash now (never nil)
        if prediction_result && prediction_result.is_a?(Hash)
          @logger.info("[FuPreparsingService] Prediction result for dataset #{group['group']}: #{prediction_result.inspect}")
          if prediction_result[:predictions]
            dataset_hash[:predicted_ram] = prediction_result[:predictions][:predicted_ram] if prediction_result[:predictions][:predicted_ram]
            dataset_hash[:predicted_duration] = prediction_result[:predictions][:predicted_duration] if prediction_result[:predictions][:predicted_duration]
            @logger.info("[FuPreparsingService] Set predicted_ram=#{dataset_hash[:predicted_ram]}, predicted_duration=#{dataset_hash[:predicted_duration]} for dataset #{group['group']}")
          else
            @logger.warn("[FuPreparsingService] No predictions in prediction_result for dataset #{group['group']}")
          end
          
          # Always store debug data for this dataset (even if predictions failed)
          if prediction_result[:debug_data]
            @prediction_debug_data << {
              dataset_name: group['group'],
              nber_rows: nber_rows.to_i,
              nber_cols: nber_cols.to_i,
              debug: prediction_result[:debug_data]
            }
          end
        else
          @logger.warn("[FuPreparsingService] prediction_result is nil or not a hash for dataset #{group['group']}")
        end
      end
      
      dataset_hash
    end

    primary_dataset = datasets.first
    
    # Warn if no datasets found
    if datasets.empty?
      @logger.warn("[FuPreparsingService] Preparsing completed but found 0 datasets. Format: #{output['detected_format']}. This may be normal for archive files or files without matrix data.")
    end
    
    summary = {
      detected_format: output['detected_format'],
      dataset_count: datasets.size,
      datasets: datasets,
      list_files: output['list_files'],
      metadata: output['metadata'],
      displayed_error: output['displayed_error'],
      primary_dimensions: primary_dimensions(primary_dataset),
      command: @command  # Include the preparsing command
    }
    
    # Add prediction debug data to summary (always include, even if empty)
    summary[:prediction_debug] = @prediction_debug_data
    
    summary
  end

  def write_predictions_to_output(output, summary)
    # Add predictions to list_groups in the output hash so they're written to output.json
    @logger.info("[FuPreparsingService] write_predictions_to_output called")
    @logger.info("[FuPreparsingService] output['list_groups'] present? #{output['list_groups'].present?}")
    @logger.info("[FuPreparsingService] summary[:datasets] present? #{summary[:datasets].present?}")
    @logger.info("[FuPreparsingService] summary[:datasets] size: #{summary[:datasets]&.size}")
    
    if output['list_groups'] && summary[:datasets] && summary[:datasets].size > 0
      summary[:datasets].each_with_index do |dataset, index|
        @logger.info("[FuPreparsingService] Processing dataset #{index}: predicted_ram=#{dataset[:predicted_ram].inspect}, predicted_duration=#{dataset[:predicted_duration].inspect}")
        if output['list_groups'][index]
          # Write predictions back to the output hash
          if dataset[:predicted_ram]
            output['list_groups'][index]['pred_max_ram'] = dataset[:predicted_ram]
            @logger.info("[FuPreparsingService] Set pred_max_ram=#{dataset[:predicted_ram]} for list_groups[#{index}]")
          else
            @logger.warn("[FuPreparsingService] predicted_ram is nil for dataset #{index}")
          end
          if dataset[:predicted_duration]
            output['list_groups'][index]['pred_process_duration'] = dataset[:predicted_duration]
            @logger.info("[FuPreparsingService] Set pred_process_duration=#{dataset[:predicted_duration]} for list_groups[#{index}]")
          else
            @logger.warn("[FuPreparsingService] predicted_duration is nil for dataset #{index}")
          end
        else
          @logger.warn("[FuPreparsingService] output['list_groups'][#{index}] is nil")
        end
      end
      
      # Write the updated output back to the file
      output_file = upload_dir + 'output.json'
      @logger.info("[FuPreparsingService] About to write to file: #{output_file}")
      
      # Ensure file is writable - fix permissions if needed
      begin
        FileUtils.chmod(0644, output_file) if File.exist?(output_file)
      rescue => e
        @logger.warn("[FuPreparsingService] Could not chmod file: #{e.message}")
      end
      
      begin
        File.open(output_file, 'w') do |f|
          f.write(JSON.pretty_generate(output))
          f.fsync  # Force write to disk
        end
        @logger.info("[FuPreparsingService] Successfully wrote predictions back to output.json at #{output_file}")
        
        # Verify the write by reading it back immediately
        if File.exist?(output_file)
          verify_content = Basic.safe_parse_json(File.read(output_file), {})
          if verify_content['list_groups'] && verify_content['list_groups'][0]
            @logger.info("[FuPreparsingService] Verification - pred_max_ram in file: #{verify_content['list_groups'][0]['pred_max_ram'].inspect}")
            @logger.info("[FuPreparsingService] Verification - pred_process_duration in file: #{verify_content['list_groups'][0]['pred_process_duration'].inspect}")
            @logger.info("[FuPreparsingService] Verification - list_groups[0] keys in file: #{verify_content['list_groups'][0].keys.inspect}")
          else
            @logger.error("[FuPreparsingService] Verification failed - list_groups[0] not found in file")
          end
        else
          @logger.error("[FuPreparsingService] Verification failed - file doesn't exist after write!")
        end
      rescue => e
        @logger.error("[FuPreparsingService] Error writing predictions to file: #{e.class} - #{e.message}")
        @logger.error(e.backtrace.join("\n")) if e.backtrace
        # Don't raise - allow preparsing to continue even if we can't write predictions
      end
    else
      # Only warn if we expected to have datasets but don't
      if summary[:datasets].empty?
        @logger.warn("[FuPreparsingService] Cannot write predictions: no datasets found in preparsing output")
      else
        @logger.debug("[FuPreparsingService] Cannot write predictions: output['list_groups']=#{output['list_groups'].present?}, summary[:datasets]=#{summary[:datasets].present?}, size=#{summary[:datasets]&.size}")
      end
    end
  rescue => e
    @logger.error("[FuPreparsingService] Error writing predictions to output.json: #{e.class} - #{e.message}")
    @logger.error(e.backtrace.join("\n")) if e.backtrace
  end

  def parse_genes_or_cells(value)
    # If value is already an array, return it directly
    if value.is_a?(Array)
      @logger.debug("[FuPreparsingService] parse_genes_or_cells: value is already an array with #{value.length} items")
      return value
    end
    
    # If value is blank or nil, return empty array
    if value.blank?
      @logger.debug("[FuPreparsingService] parse_genes_or_cells: value is blank/nil, returning empty array")
      return []
    end
    
    # Otherwise, parse as Python list string
    @logger.debug("[FuPreparsingService] parse_genes_or_cells: parsing as Python list string: #{value.inspect[0..100]}")
    parse_python_list_string(value)
  end

  def parse_python_list_string(str)
    return [] if str.blank?
    
    # Handle Python list string like "['item1', 'item2']" or "[1, 2, 3]"
    str = str.strip
    return [] unless str.start_with?('[') && str.end_with?(']')
    
    # Remove brackets and split by comma
    content = str[1..-2].strip
    return [] if content.empty?
    
    # Split by comma, handling quoted strings
    items = []
    current_item = ''
    in_quotes = false
    quote_char = nil
    
    content.each_char do |char|
      if (char == '"' || char == "'") && !in_quotes
        in_quotes = true
        quote_char = char
      elsif char == quote_char && in_quotes
        in_quotes = false
        quote_char = nil
        items << current_item.strip
        current_item = ''
      elsif char == ',' && !in_quotes
        items << current_item.strip unless current_item.strip.empty?
        current_item = ''
      else
        current_item += char
      end
    end
    
    items << current_item.strip unless current_item.strip.empty?
    
    # Clean up quotes and whitespace
    items.map { |item| item.gsub(/^["']|["']$/, '').strip }.reject(&:empty?)
  rescue StandardError => e
    @logger.warn("[FuPreparsingService] Failed to parse Python list string: #{str.inspect} - #{e.message}")
    []
  end

  def collect_warnings(output)
    warnings = []
    warnings << output['displayed_error'] if output['displayed_error'].present?

    error_file = upload_dir + 'output.err'
    if error_file.exist?
      content = error_file.read.strip
      warnings << content unless content.blank?
    end

    warnings.compact
  end

  def primary_dimensions(dataset)
    return {} unless dataset

    {
      nber_rows: dataset[:gene_count],
      nber_cols: dataset[:cell_count]
    }
  end

  def safe_integer(value)
    return if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def default_organism_id
    Organism.first&.id
  end

  def upload_dir
    @upload_dir ||= @fu.upload_dir
  end

  def ensure_directory_writable
    upload_dir_str = upload_dir.to_s
    
    # Use docker exec as root to fix permissions on the directory inside the container
    # The directory might be owned by root, and the container runs as rvmuser
    # Fix permissions so rvmuser can write to it
    fix_permissions_cmd = [
      'docker', 'exec',
      '--user', 'root',
      ENV.fetch('ASAP_RUN_CONTAINER'),
      '/bin/sh', '-c',
      "chmod 775 '#{upload_dir_str}' && chown rvmuser:rvmuser '#{upload_dir_str}'"
    ]
    
    begin
      stdout, stderr, status = Open3.capture3(*fix_permissions_cmd)
      if status.success?
        @logger.info("[FuPreparsingService] Fixed permissions on #{upload_dir_str}")
      else
        @logger.warn("[FuPreparsingService] Could not fix permissions: #{stderr}")
      end
    rescue => e
      @logger.warn("[FuPreparsingService] Error fixing permissions: #{e.message}")
    end
  end

  def get_predictions(nber_rows, nber_cols)
    version_id = nil
    std_method_id = nil
    pred_cmd_str = nil
    r_script_cmd = nil
    docker_cmd_preview_str = nil
    attempted_version_id = nil
    early_return_reason = nil
    asap_docker_image = nil
    parsing_step = nil
    std_method = nil
    
    begin
      # Resolve version_id from explicit options first, then from the bound project.
      # Do not auto-pick a "latest" version, as that can point to the wrong model set.
      attempted_version_id = @options[:version_id]
      
      if @options[:version_id].present?
        version_id = safe_integer(@options[:version_id])
        unless version_id
          early_return_reason = "version_id could not be parsed: #{@options[:version_id].inspect}"
          raise early_return_reason
        end
        
        version = Version.find_by(id: version_id)
        unless version
          early_return_reason = "Version with id #{version_id} not found"
          raise early_return_reason
        end
      elsif @fu.project&.version_id.present?
        version_id = @fu.project.version_id
        version = Version.find_by(id: version_id)
        unless version
          early_return_reason = "Project version with id #{version_id} not found"
          raise early_return_reason
        end
        @logger.info("[FuPreparsingService] Using project version #{version_id} for predictions")
      else
        early_return_reason = "version_id is missing in options and project context"
        raise early_return_reason
      end
      
      # Get docker image for this version
      asap_docker_image = Basic.get_asap_docker(version)
      unless asap_docker_image
        early_return_reason = "Could not get docker image for version #{version_id}"
        raise early_return_reason
      end
      
      # Get parsing step
      parsing_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'parsing').first
      unless parsing_step
        early_return_reason = "Parsing step not found for docker_image_id #{asap_docker_image.id}"
        raise early_return_reason
      end
      
      # Get standard method for parsing step
      std_method = StdMethod.where(:step_id => parsing_step.id).first
      unless std_method
        early_return_reason = "Standard method not found for step_id #{parsing_step.id}"
        raise early_return_reason
      end
      
      std_method_id = std_method.id
      
      # Build prediction command (following original application pattern)
      docker_image_tag = asap_docker_image.tag || "v#{version_id}"
      docker_image = "fabdavid/asap_run:#{docker_image_tag}"
      
      # Build the R script command inside the container
      models_base = Basic.prediction_models_path_for_r
      r_script_cmd = "Rscript prediction.tool.2.R predict #{models_base}/#{version_id} #{std_method_id} #{nber_rows} #{nber_cols}"
      @logger.info("[FuPreparsingService] R script command: #{r_script_cmd}")
      
      prediction_mount_root = Basic.prediction_data_root_mount
      @logger.info("[FuPreparsingService] Prediction volume mount root: #{prediction_mount_root}")

      # Build Docker command
      docker_cmd = [
        'docker', 'run',
        '--entrypoint', '/bin/sh',
        '--rm',
        '-v', "#{prediction_mount_root}:#{prediction_mount_root}",
        '-v', '/srv/asap_run/srv:/srv',
        docker_image,
        '-c', r_script_cmd
      ]
      
      pred_cmd_str = Shellwords.join(docker_cmd)
      @logger.info("[FuPreparsingService] Running prediction command: #{pred_cmd_str}")
      
      # Execute command and capture output
      stdout_str, stderr_str, status = Open3.capture3(*docker_cmd)
      
      @logger.info("[FuPreparsingService] Prediction STDOUT: #{stdout_str}") unless stdout_str.blank?
      @logger.info("[FuPreparsingService] Prediction STDERR: #{stderr_str}") unless stderr_str.blank?
      @logger.info("[FuPreparsingService] Prediction command exit status: #{status.exitstatus}")
      
      # Get first line of output (JSON result)
      pred_results_json = stdout_str.split("\n").first
      h_pred_results = Basic.safe_parse_json(pred_results_json, {})
      
      @logger.info("[FuPreparsingService] Prediction raw JSON line: #{pred_results_json}")
      @logger.info("[FuPreparsingService] Prediction parsed JSON: #{h_pred_results.inspect}")
      
      predicted_ram = (h_pred_results['predicted_ram'] == 'NA') ? nil : h_pred_results['predicted_ram']
      predicted_time = (h_pred_results['predicted_time'] == 'NA') ? nil : h_pred_results['predicted_time']
      
      # Build debug data
      debug_data = {
        command: pred_cmd_str,
        r_script_command: r_script_cmd,
        stdout: stdout_str,
        stderr: stderr_str,
        exit_status: status.exitstatus,
        raw_json_line: pred_results_json,
        parsed_json: h_pred_results,
        version_id: version_id,
        std_method_id: std_method_id,
        nber_rows: nber_rows,
        nber_cols: nber_cols,
        success: status.success?
      }
      
      @logger.info("[FuPreparsingService] Prediction command exit status: #{status.exitstatus}")
      @logger.info("[FuPreparsingService] Prediction parsed JSON: #{h_pred_results.inspect}")
      
      {
        predictions: {
          predicted_ram: predicted_ram,
          predicted_duration: predicted_time
        },
        debug_data: debug_data
      }
    rescue => e
      error_message = early_return_reason || e.message
      @logger.warn("[FuPreparsingService] Failed to get predictions: #{error_message}")
      @logger.warn(e.backtrace.join("\n")) if e.backtrace
      
      # Try to get std_method_id even if we had an error earlier
      # This helps us build a more accurate command preview
      if version_id && std_method_id.nil?
        begin
          version_obj = Version.find_by(id: version_id) if version_id
          if version_obj
            asap_docker_image_obj = Basic.get_asap_docker(version_obj) unless asap_docker_image
            asap_docker_image_obj ||= asap_docker_image
            if asap_docker_image_obj
              parsing_step_obj = Step.where(:docker_image_id => asap_docker_image_obj.id, :name => 'parsing').first unless parsing_step
              parsing_step_obj ||= parsing_step
              if parsing_step_obj
                std_method_obj = StdMethod.where(:step_id => parsing_step_obj.id).first unless std_method
                std_method_obj ||= std_method
                std_method_id = std_method_obj.id if std_method_obj
              end
            end
          end
        rescue => lookup_error
          @logger.warn("[FuPreparsingService] Could not lookup std_method_id for preview: #{lookup_error.message}")
        end
      end
      
      # Build R script command with actual values if we have them.
      # This must never raise from here, otherwise prediction failures
      # incorrectly fail the whole preparsing job.
      models_base = begin
        Basic.prediction_models_path_for_r
      rescue KeyError => config_error
        @logger.warn("[FuPreparsingService] Prediction models path unavailable: #{config_error.message}")
        '<prediction_models_path_unavailable>'
      end
      if version_id && std_method_id
        r_script_cmd = "Rscript prediction.tool.2.R predict #{models_base}/#{version_id} #{std_method_id} #{nber_rows} #{nber_cols}"
      elsif version_id
        r_script_cmd = "Rscript prediction.tool.2.R predict #{models_base}/#{version_id} <std_method_id> #{nber_rows} #{nber_cols}"
      else
        r_script_cmd = "Rscript prediction.tool.2.R predict #{models_base}/<version_id> <std_method_id> #{nber_rows} #{nber_cols}"
      end
      
      # Build docker command preview if we can
      begin
        prediction_mount_root = Basic.prediction_data_root_mount
        if version_id
          docker_image_tag = if asap_docker_image
                               asap_docker_image.tag || "v#{version_id}"
                             else
                               "v#{version_id}"
                             end
          docker_image = "fabdavid/asap_run:#{docker_image_tag}"
          
          docker_cmd_preview = [
            'docker', 'run',
            '--entrypoint', '/bin/sh',
            '--rm',
            '-v', "#{prediction_mount_root}:#{prediction_mount_root}",
            '-v', '/srv/asap_run/srv:/srv',
            docker_image,
            '-c', r_script_cmd
          ]
          docker_cmd_preview_str = Shellwords.join(docker_cmd_preview)
        end
      rescue => build_error
        @logger.warn("[FuPreparsingService] Could not build docker command preview: #{build_error.message}")
        docker_cmd_preview_str = "Could not build command preview: #{build_error.message}"
      end
      
      # Always return debug data, even on early return or error
      {
        predictions: nil,
        debug_data: {
          error: error_message,
          error_class: e.class.name,
          backtrace: e.backtrace&.first(5),
          command: pred_cmd_str || docker_cmd_preview_str,
          r_script_command: r_script_cmd,
          docker_command_preview: docker_cmd_preview_str,
          version_id: version_id,
          std_method_id: std_method_id,
          nber_rows: nber_rows,
          nber_cols: nber_cols,
          options_version_id: @options[:version_id],
          attempted_version_id: attempted_version_id,
          early_return: !early_return_reason.nil?
        }
      }
    end
  end

end

