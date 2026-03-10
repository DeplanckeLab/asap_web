require_relative 'test_base_without_fixtures'
require 'open3'
require 'shellwords'

class ParsingTest < TestBaseWithoutFixtures
  
  PREPARSING_RESULTS_DIR = Pathname.new('/data/asap2_test/tests/preparsing/results')
  INPUT_EXAMPLES_DIR = '/mnt/asap-old/input_examples/'
  PARSING_OUTPUT_DIR = Pathname.new('/data/asap2_test/tests/parsing')
  DATASETS_LIST_FILE = Pathname.new('/data/asap2_test/tests/parsing/list_datasets.tsv')
  
  setup do
    # Suppress ActiveRecord SQL logging during tests
    @original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil
    
    # Suppress Rails logger output during tests (reduce verbosity)
    @original_rails_logger = Rails.logger
    @original_rails_logger_level = Rails.logger.level
    Rails.logger.level = Logger::WARN
    
    # Get organism (same as preparsing test)
    @organism = Organism.first || Organism.create!(name: 'Test Organism')
    
    # Get version from ENV or use first available
    version_id = ENV['ASAP_VERSION_ID']&.to_i
    @version = if version_id
                 Version.find_by(id: version_id)
               else
                 Version.first
               end
    
    unless @version
      skip "No ASAP version available. Set ASAP_VERSION_ID or ensure versions exist in database"
    end
    
    h_env = Basic.safe_parse_json(@version.env_json, {})
    @asap_docker_image = Basic.get_asap_docker(@version)
    
    unless @asap_docker_image
      skip "Could not find ASAP docker image for version #{@version.id}"
    end
    
    @db_version = h_env['asap_data_db_version']
    unless @db_version
      skip "Version #{@version.id} does not have asap_data_db_version in env_json"
    end
    
    docker_tag = @asap_docker_image.tag || "v#{@version.id}"
    # Ensure tag has 'v' prefix and normalize version (e.g., 'v8.1' -> 'v8', 'v8' -> 'v8')
    tag_with_v = docker_tag.start_with?('v') ? docker_tag : "v#{docker_tag}"
    # Extract major version number (e.g., 'v8.1' -> 'v8', 'v8' -> 'v8')
    major_version = tag_with_v.match(/^v(\d+)/)
    version_str = major_version ? "v#{major_version[1]}" : tag_with_v
    @python_script = "parse.#{version_str}.py"
    
    # Set up parsing output directory
    FileUtils.mkdir_p(PARSING_OUTPUT_DIR) unless PARSING_OUTPUT_DIR.exist?
  end
  
  teardown do
    # Restore loggers
    ActiveRecord::Base.logger = @original_logger if defined?(@original_logger)
    Rails.logger.level = @original_rails_logger_level if defined?(@original_rails_logger_level)
  end
  
  def load_datasets_list
    unless DATASETS_LIST_FILE.exist?
      puts "WARNING: Datasets list file does not exist: #{DATASETS_LIST_FILE}"
      return {}
    end
    
    datasets_map = {}
    
    begin
      lines = File.readlines(DATASETS_LIST_FILE)
      # Skip header line
      lines[1..-1].each do |line|
        next if line.strip.empty?
        
        # Parse TSV: organism_id, sel, filetype, filename
        parts = line.chomp.split("\t")
        next if parts.size < 4
        
        organism_id = parts[0].strip
        sel = parts[1].strip
        filetype = parts[2].strip
        filename = parts[3].strip
        
        # Normalize filename: remove 'input_examples/' prefix if present
        normalized_filename = filename.gsub(/^input_examples\//, '')
        
        # Store with normalized filename as key
        datasets_map[normalized_filename] = {
          organism_id: organism_id.to_i,
          sel: sel.empty? ? nil : sel,
          filetype: filetype,
          original_filename: filename
        }
      end
    rescue => e
      puts "WARNING: Could not read datasets list file: #{e.message}"
    end
    
    datasets_map
  end
  
  def get_preparsing_results
    unless PREPARSING_RESULTS_DIR.exist?
      puts "WARNING: Preparsing results directory does not exist: #{PREPARSING_RESULTS_DIR}"
      puts "Make sure preparsing tests have been run first: rake preparsing:test_all"
      return []
    end
    
    # Load datasets list from TSV file - this is our source of truth
    datasets_map = load_datasets_list
    
    if datasets_map.empty?
      puts "WARNING: No datasets found in list_datasets.tsv"
      return []
    end
    
    results = []
    
    # Only process files that are in the TSV file
    datasets_map.each do |normalized_filename, dataset_info|
      begin
        # Find the preparsing output file
        # Try exact match first, then try with different extensions
        output_file = PREPARSING_RESULTS_DIR.join("#{normalized_filename}_output.json")
        
        unless output_file.exist?
          # Try to find output file with same base name but different extension
          base_name = File.basename(normalized_filename, '.*')
          matching_outputs = PREPARSING_RESULTS_DIR.glob("#{base_name}_output.json")
          output_file = matching_outputs.first if matching_outputs.any?
        end
        
        # Skip if no preparsing output found
        unless output_file && output_file.exist?
          puts "WARNING: No preparsing output found for #{normalized_filename} (skipping)"
          next
        end
        
        # Read preparsing output
        content = File.read(output_file)
        output_json = Basic.safe_parse_json(content, {})
        
        # Find the original input file
        source_file = File.join(INPUT_EXAMPLES_DIR, normalized_filename)
        unless File.exist?(source_file)
          # Try to find file with same base name but different extension
          base_name = File.basename(normalized_filename, '.*')
          matching_files = Dir.glob(File.join(INPUT_EXAMPLES_DIR, "#{base_name}.*"))
          source_file = matching_files.first if matching_files.any?
        end
        
        if source_file && File.exist?(source_file)
          results << {
            output_file: output_file,
            source_file: source_file,
            output_json: output_json,
            filename: normalized_filename,
            organism_id: dataset_info[:organism_id],
            sel: dataset_info[:sel],
            filetype: dataset_info[:filetype]
          }
        else
          puts "WARNING: Source file not found for #{normalized_filename} (skipping)"
        end
      rescue => e
        puts "WARNING: Could not process #{normalized_filename}: #{e.message}"
      end
    end
    
    results
  end
  
  test "parsing works for all preparsing results" do
    preparsing_results = get_preparsing_results
    
    skip "No preparsing results found. Run preparsing tests first: rake preparsing:test_all" if preparsing_results.empty?
    
    puts "\nTesting parsing for #{preparsing_results.size} preparsing results..."
    
    results = {
      passed: [],
      failed: [],
      skipped: []
    }
    
    preparsing_results.each_with_index do |preparsing_result, index|
      output_json = preparsing_result[:output_json]
      source_file = preparsing_result[:source_file]
      filename = preparsing_result[:filename]
      organism_id = preparsing_result[:organism_id]
      sel_value = preparsing_result[:sel]
      
      print "[#{index + 1}/#{preparsing_results.size}] #{filename}... "
      
      begin
        # Use filetype from TSV file
        filetype = preparsing_result[:filetype]
        
        # Skip if filetype not found in TSV
        unless filetype.present?
          puts "✗ (filetype not found in list_datasets.tsv)"
          results[:skipped] << { filename: filename, reason: 'filetype not found in TSV' }
          next
        end
        
        # Skip if organism_id not found in TSV
        unless organism_id
          puts "✗ (organism_id not found in list_datasets.tsv)"
          results[:skipped] << { filename: filename, reason: 'organism_id not found in TSV' }
          next
        end
        
        # Build parsing command
        # Use postgres:5434 since we're joining the same docker network (asap2_asap_network)
        # This matches how parse.rake connects to the database
        db_host = ENV.fetch('ASAP2_REMOTE_HOST', 'postgres')
        db_port = ENV.fetch('ASAP2_REMOTE_PORT', '5434')  # Container port when on same network
        db_url = "#{db_host}:#{db_port}/asap_data_v#{@db_version}"
        
        # Create output directory named after the dataset
        # Use the filename (without extension) as the directory name
        dataset_name = File.basename(filename, '.*').gsub(/[^a-zA-Z0-9._-]/, '_')
        test_output_dir = PARSING_OUTPUT_DIR.join(dataset_name)
        FileUtils.mkdir_p(test_output_dir)
        # Ensure directory is writable by Docker user (1006:1006)
        FileUtils.chmod(0777, test_output_dir) if test_output_dir.exist?
        
        # Run parsing command
        result = run_parsing_command(source_file, filetype, organism_id, db_url, sel_value, test_output_dir)
        
        if result[:success]
          # Validate output.json
          validation = validate_parsing_output(result[:output_json], organism_id, filename)
          
          if validation[:valid]
            if validation[:warning]
              puts "✓ (#{validation[:reason]})"
              results[:passed] << { filename: filename, warning: validation[:reason] }
            else
              puts "✓"
              results[:passed] << filename
            end
          else
            error_msg = validation[:reason]
            puts "✗ (#{error_msg})"
            results[:failed] << { filename: filename, error: error_msg }
          end
        else
          error_msg = result[:stderr].presence || result[:stdout].presence || "Exit code #{result[:exit_code]}"
          puts "✗ (#{error_msg.split("\n").first})"
          results[:failed] << { filename: filename, error: error_msg }
        end
        
        # Keep output directory and files (output.loom and output.json) for inspection
        # Files are saved in /data/asap2_test/tests/parsing/<dataset_name>/
        
      rescue => e
        error_msg = "#{e.class}: #{e.message}"
        puts "✗ (#{error_msg})"
        results[:failed] << { filename: filename, error: error_msg }
      end
    end
    
    # Print summary
    passed_count = results[:passed].size
    warnings_count = results[:passed].count { |p| p.is_a?(Hash) && p[:warning] }
    puts "\nSummary: #{passed_count} passed (#{warnings_count} with warnings), #{results[:failed].size} failed, #{results[:skipped].size} skipped"
    
    if results[:failed].any?
      puts "\nFailed files:"
      results[:failed].each do |failure|
        puts "  - #{failure[:filename]}: #{failure[:error].split("\n").first}"
      end
    end
    
    if warnings_count > 0
      puts "\nFiles with warnings:"
      results[:passed].select { |p| p.is_a?(Hash) && p[:warning] }.each do |warning|
        puts "  - #{warning[:filename]}: #{warning[:warning]}"
      end
    end
    
    # Assert that at least some tests passed
    assert results[:passed].any?, "At least one parsing test should have passed"
  end
  
  def run_parsing_command(source_file, filetype, organism_id, db_url, sel_value = nil, output_dir = nil)
    # Build Python script command arguments
    script_args = [
      'python3', "/srv/#{@python_script}",
      '-f', source_file,
      '--filetype', filetype.to_s,
      '--organism', organism_id.to_s,
      '--dburl', db_url
    ]
    
    # Add --sel only if sel_value is present and not empty
    if sel_value.present? && !sel_value.strip.empty?
      script_args << '--sel' << sel_value.to_s
    end
    
    # Add output directory if specified
    if output_dir.present?
      script_args << '-o' << output_dir.to_s
    end
    
    script_cmd = Shellwords.join(script_args)
    
    # Build docker image name (e.g., fabdavid/asap_run:v8)
    docker_tag = @asap_docker_image.tag || "v#{@version.id}"
    tag_with_v = docker_tag.start_with?('v') ? docker_tag : "v#{docker_tag}"
    major_version = tag_with_v.match(/^v(\d+)/)
    version_str = major_version ? "v#{major_version[1]}" : tag_with_v
    docker_image = "fabdavid/asap_run:#{version_str}"
    
    # Build docker run command (similar to how predictions are run)
    # Mount necessary volumes: input examples and output directory
    # The parse script is already in the docker image at /srv/parse.v8.py
    # Pass environment variables needed by the parsing script
    # Join the same network as postgres to use postgres:5434
    env_file_path = '/data/asap2_test/.env_asap_run'
    docker_cmd = [
      'docker', 'run',
      '--rm',
      '--user', '1006:1006',
      '--network', 'asap2_asap_network'  # Join same network as postgres container
    ]
    
    # Add env file if it exists, otherwise pass individual env vars
    if File.exist?(env_file_path)
      docker_cmd << '--env-file' << env_file_path
    else
      # Pass essential environment variables
      docker_cmd << '-e' << "POSTGRES_USER=#{ENV['POSTGRES_USER'] || 'postgres'}"
      docker_cmd << '-e' << "POSTGRES_PASSWORD=#{ENV['POSTGRES_PASSWORD'] || ''}"
    end
    
    # Add volume mounts
    docker_cmd << '-v' << "#{INPUT_EXAMPLES_DIR}:#{INPUT_EXAMPLES_DIR}:ro"  # Mount input directory read-only
    docker_cmd << '-v' << "#{PARSING_OUTPUT_DIR}:#{PARSING_OUTPUT_DIR}"  # Mount output directory for writing
    docker_cmd << docker_image
    docker_cmd << '/bin/sh' << '-c' << script_cmd
    
    cmd = Shellwords.join(docker_cmd)
    
    # Run parsing command
    stdout_str, stderr_str, status = Open3.capture3(*docker_cmd)
    
    # Try to read output.json if output_dir is specified
    output_json = nil
    if output_dir && status.success?
      # The output.json should be in the output directory
      # Since we're running in docker, the path might need to be accessible from host
      output_json_path = Pathname.new(output_dir).join('output.json')
      
      # Also check if it's in the same directory as source file (fallback)
      source_dir = Pathname.new(source_file).dirname
      fallback_path = source_dir.join('output.json')
      
      # Try output_dir first, then fallback
      json_path = output_json_path.exist? ? output_json_path : (fallback_path.exist? ? fallback_path : nil)
      
      if json_path && json_path.exist?
        begin
          output_json = Basic.safe_parse_json(File.read(json_path), {})
        rescue => e
          # Ignore errors reading output.json
        end
      end
    end
    
    {
      success: status.success?,
      stdout: stdout_str,
      stderr: stderr_str,
      exit_code: status.exitstatus,
      output_json: output_json
    }
  end
  
  def validate_parsing_output(output_json, expected_organism_id, filename)
    return { valid: false, reason: 'output.json not found' } unless output_json
    
    nber_not_found_genes = output_json['nber_not_found_genes']
    nber_rows = output_json['nber_rows']
    
    # If nber_not_found_genes is not present, we can't validate
    unless nber_not_found_genes
      return { valid: false, reason: 'nber_not_found_genes not found in output.json' }
    end
    
    nber_not_found_genes = nber_not_found_genes.to_i
    nber_rows = nber_rows.to_i if nber_rows
    
    # Success: all genes found
    if nber_not_found_genes == 0
      return { 
        valid: true, 
        reason: 'all genes found',
        nber_not_found_genes: 0,
        nber_rows: nber_rows
      }
    end
    
    # Calculate percentage if we have total genes
    percentage = nber_rows > 0 ? (nber_not_found_genes.to_f * 100 / nber_rows).round(2) : nil
    
    # If most genes are not found (>50%), probably wrong species
    if nber_rows > 0 && percentage > 50
      return { 
        valid: false, 
        reason: "most genes not found (#{nber_not_found_genes}/#{nber_rows} = #{percentage}%) - likely wrong organism",
        nber_not_found_genes: nber_not_found_genes,
        nber_rows: nber_rows,
        percentage: percentage
      }
    end
    
    # If some genes are not found but less than 50%, might be dataset/DB version issue
    # Still consider it a warning but not necessarily a failure
    return { 
      valid: true, 
      reason: "some genes not found (#{nber_not_found_genes}/#{nber_rows} = #{percentage}%) - might be dataset/DB version issue",
      nber_not_found_genes: nber_not_found_genes,
      nber_rows: nber_rows,
      percentage: percentage,
      warning: true
    }
  end
  
  test "parsing fails with wrong organism_id" do
    datasets_map = load_datasets_list
    skip "No datasets found in list_datasets.tsv" if datasets_map.empty?
    
    # Get first dataset from TSV
    first_entry = datasets_map.values.first
    filename = first_entry[:original_filename].gsub(/^input_examples\//, '')
    source_file = File.join(INPUT_EXAMPLES_DIR, filename)
    
    skip "Source file not found: #{source_file}" unless File.exist?(source_file)
    
    correct_organism_id = first_entry[:organism_id]
    wrong_organism_id = 99999  # Use a non-existent organism_id
    filetype = first_entry[:filetype]
    sel_value = first_entry[:sel]
    db_host = ENV.fetch('ASAP2_REMOTE_HOST', 'postgres')
    db_port = ENV.fetch('ASAP2_REMOTE_PORT', '5434')  # Container port when on same network
    db_url = "#{db_host}:#{db_port}/asap_data_v#{@db_version}"
    
    puts "\nTesting wrong organism_id for #{filename}..."
    puts "  Correct organism_id: #{correct_organism_id}"
    puts "  Wrong organism_id: #{wrong_organism_id}"
    
    result = run_parsing_command(source_file, filetype, wrong_organism_id, db_url, sel_value)
    
    assert !result[:success], "Parsing should fail with wrong organism_id"
    puts "  ✓ Parsing correctly failed with wrong organism_id"
  end
  
  test "parsing fails with wrong filetype" do
    datasets_map = load_datasets_list
    skip "No datasets found in list_datasets.tsv" if datasets_map.empty?
    
    # Get first dataset from TSV
    first_entry = datasets_map.values.first
    filename = first_entry[:original_filename].gsub(/^input_examples\//, '')
    source_file = File.join(INPUT_EXAMPLES_DIR, filename)
    
    skip "Source file not found: #{source_file}" unless File.exist?(source_file)
    
    organism_id = first_entry[:organism_id]
    correct_filetype = first_entry[:filetype]
    wrong_filetype = correct_filetype == 'H5AD' ? 'LOOM' : 'H5AD'  # Use opposite filetype
    sel_value = first_entry[:sel]
    db_host = ENV.fetch('ASAP2_REMOTE_HOST', 'postgres')
    db_port = ENV.fetch('ASAP2_REMOTE_PORT', '5434')  # Container port when on same network
    db_url = "#{db_host}:#{db_port}/asap_data_v#{@db_version}"
    
    puts "\nTesting wrong filetype for #{filename}..."
    puts "  Correct filetype: #{correct_filetype}"
    puts "  Wrong filetype: #{wrong_filetype}"
    
    result = run_parsing_command(source_file, wrong_filetype, organism_id, db_url, sel_value)
    
    assert !result[:success], "Parsing should fail with wrong filetype"
    puts "  ✓ Parsing correctly failed with wrong filetype"
  end
  
  test "parsing fails with wrong sel parameter" do
    datasets_map = load_datasets_list
    
    # Find a dataset that has a sel value
    entry_with_sel = datasets_map.values.find { |entry| entry[:sel].present? }
    skip "No dataset with sel parameter found in list_datasets.tsv" unless entry_with_sel
    
    filename = entry_with_sel[:original_filename].gsub(/^input_examples\//, '')
    source_file = File.join(INPUT_EXAMPLES_DIR, filename)
    
    skip "Source file not found: #{source_file}" unless File.exist?(source_file)
    
    organism_id = entry_with_sel[:organism_id]
    filetype = entry_with_sel[:filetype]
    correct_sel = entry_with_sel[:sel]
    wrong_sel = "/nonexistent/dataset"  # Use a non-existent dataset name
    db_host = ENV.fetch('ASAP2_REMOTE_HOST', 'postgres')
    db_port = ENV.fetch('ASAP2_REMOTE_PORT', '5434')  # Container port when on same network
    db_url = "#{db_host}:#{db_port}/asap_data_v#{@db_version}"
    
    puts "\nTesting wrong sel parameter for #{filename}..."
    puts "  Correct sel: #{correct_sel}"
    puts "  Wrong sel: #{wrong_sel}"
    
    result = run_parsing_command(source_file, filetype, organism_id, db_url, wrong_sel)
    
    assert !result[:success], "Parsing should fail with wrong sel parameter"
    puts "  ✓ Parsing correctly failed with wrong sel parameter"
  end
end
