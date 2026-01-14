namespace :parsing do
  desc "Test parsing with all example files using preparsing test results"
  task :test_all, [:version_id] => :environment do |t, args|
    puts "Running parsing tests using preparsing results..."
    puts "=" * 80
    puts ""
    puts "NOTE: This task uses output.json files from preparsing tests"
    puts "      Make sure preparsing tests have been run first: rake preparsing:test_all"
    puts ""
    
    # Get version_id from argument or ENV
    version_id = args[:version_id] || ENV['ASAP_VERSION_ID']
    
    if version_id
      puts "Using ASAP Version ID: #{version_id}"
      ENV['ASAP_VERSION_ID'] = version_id.to_s
    else
      # Try to use the first available version
      version = Version.first
      if version
        puts "No version specified, using first available version: #{version.id}"
        ENV['ASAP_VERSION_ID'] = version.id.to_s
      else
        puts "ERROR: No ASAP version specified and no versions found in database"
        puts "Usage: rake parsing:test_all[VERSION_ID]"
        puts "   or: ASAP_VERSION_ID=VERSION_ID rake parsing:test_all"
        exit 1
      end
    end
    
    # Verify version exists and has required info
    version = Version.find_by(id: ENV['ASAP_VERSION_ID'].to_i)
    unless version
      puts "ERROR: Version with ID #{ENV['ASAP_VERSION_ID']} not found"
      exit 1
    end
    
    h_env = Basic.safe_parse_json(version.env_json, {})
    asap_docker_image = Basic.get_asap_docker(version)
    
    unless asap_docker_image
      puts "ERROR: Could not find ASAP docker image for version #{version.id}"
      exit 1
    end
    
    db_version = h_env['asap_data_db_version']
    unless db_version
      puts "ERROR: Version #{version.id} does not have asap_data_db_version in env_json"
      exit 1
    end
    
    docker_tag = asap_docker_image.tag || "v#{version.id}"
    
    puts "Docker Tag: #{docker_tag}"
    puts "Database Version: #{db_version}"
    puts ""
    
    # Check that preparsing results directory exists
    preparsing_results_dir = Pathname.new('/data/asap2_test/tests/preparsing/results')
    unless preparsing_results_dir.exist?
      puts "ERROR: Preparsing results directory does not exist: #{preparsing_results_dir}"
      puts "       Please run preparsing tests first: rake preparsing:test_all"
      exit 1
    end
    
    # Check that datasets list file exists
    datasets_list_file = Pathname.new('/data/asap2_test/tests/parsing/list_datasets.tsv')
    unless datasets_list_file.exist?
      puts "ERROR: Datasets list file does not exist: #{datasets_list_file}"
      puts "       Please create list_datasets.tsv with the files to test"
      exit 1
    end
    
    puts "Using datasets from list_datasets.tsv"
    puts ""
    
    # Run tests directly (rails test handles environment automatically)
    # Set RAILS_ENV=test explicitly
    result = system("cd #{Rails.root} && RAILS_ENV=test bundle exec rails test test/services/parsing_test.rb")
    
    exit(result ? 0 : 1)
  end
  
  desc "Set up test database environment"
  task setup_test_db: :environment do
    puts "Setting up test database environment..."
    system("cd #{Rails.root} && RAILS_ENV=test bundle exec rails db:environment:set RAILS_ENV=test")
    puts "Done!"
  end
  
  desc "List all testable files in the examples directory"
  task list_files: :environment do
    input_dir = '/mnt/asap-old/input_examples/'
    
    unless Dir.exist?(input_dir)
      puts "ERROR: Directory #{input_dir} does not exist!"
      exit 1
    end
    
    excluded_patterns = [
      /.metadata.txt$/,
      /.csv$/,
      /.json$/,
      /.gtf.mapping.txt$/,
      /FCA/
    ]
    
    files = Dir.glob(File.join(input_dir, '*')).select do |file|
      next false unless File.file?(file)
      next false if excluded_patterns.any? { |pattern| file.match?(pattern) }
      next false unless File.readable?(file)
      next false if File.size(file) == 0
      true
    end.sort
    
    puts "Found #{files.size} testable files:"
    puts "=" * 80
    
    files.each_with_index do |file, index|
      filename = File.basename(file)
      size = File.size(file)
      size_mb = (size / 1024.0 / 1024.0).round(2)
      puts "#{index + 1}. #{filename} (#{size_mb} MB)"
    end
    
    puts "\nTotal: #{files.size} files"
  end
end

