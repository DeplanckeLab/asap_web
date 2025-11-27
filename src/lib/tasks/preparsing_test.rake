namespace :preparsing do
  desc "Test preparsing service with all example files from /mnt/asap-old/input_examples/"
  task test_all: :environment do
    puts "Running preparsing tests for all example files..."
    puts "=" * 80
    puts ""
    puts "NOTE: Make sure /mnt/asap-old/input_examples/ is mounted in docker-compose.yml"
    puts "      and the container has been restarted."
    puts ""
    
    # Run tests directly (rails test handles environment automatically)
    # Set RAILS_ENV=test explicitly
    result = system("cd #{Rails.root} && RAILS_ENV=test bundle exec rails test test/services/fu_preparsing_service_test.rb")
    
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

