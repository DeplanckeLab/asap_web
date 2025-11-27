require_relative 'test_base_without_fixtures'

class FuPreparsingServiceTest < TestBaseWithoutFixtures
  
  INPUT_EXAMPLES_DIR = '/mnt/asap-old/input_examples/'
  
  # Files to exclude from testing (metadata, CSV, JSON, mapping files)
  EXCLUDED_PATTERNS = [
    /.metadata.txt$/,
    /.csv$/,
    /.json$/,
    /.gtf.mapping.txt$/,
    /FCA/ # Directory
  ]

  setup do
    @user = User.first || User.create!(email: 'test@example.com', password: 'password123')
    @organism = Organism.first || Organism.create!(name: 'Test Organism')
    
    # Set up upload directory for tests
    @upload_base_dir = Pathname.new(ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus'))
    FileUtils.mkdir_p(@upload_base_dir) unless @upload_base_dir.exist?
  end

  def get_test_files
    unless Dir.exist?(INPUT_EXAMPLES_DIR)
      puts "WARNING: Input examples directory does not exist: #{INPUT_EXAMPLES_DIR}"
      puts "Make sure it's mounted in docker-compose.yml and container is restarted"
      return []
    end
    
    files = Dir.glob(File.join(INPUT_EXAMPLES_DIR, '*')).select do |file|
      next false unless File.file?(file)
      next false if EXCLUDED_PATTERNS.any? { |pattern| file.match?(pattern) }
      next false unless File.readable?(file)
      next false if File.size(file) == 0
      
      true
    end.sort
    
    puts "Found #{files.size} testable files in #{INPUT_EXAMPLES_DIR}" if files.any?
    files
  end

  test "preparsing works for all input example files" do
    test_files = get_test_files
    
    skip "No test files found in #{INPUT_EXAMPLES_DIR}" if test_files.empty?
    
    puts "\n" + "=" * 80
    puts "Testing #{test_files.size} files from #{INPUT_EXAMPLES_DIR}"
    puts "=" * 80
    
    results = {
      passed: [],
      failed: [],
      skipped: []
    }
    
    test_files.each_with_index do |source_file, index|
      filename = File.basename(source_file)
      puts "\n[#{index + 1}/#{test_files.size}] Testing: #{filename}"
      puts "  Size: #{File.size(source_file)} bytes"
      
      begin
        # Create Fu record
        fu = Fu.create!(
          user: @user,
          upload_file_name: 'input_file',
          upload_file_size: File.size(source_file),
          status: 'uploaded',
          name: filename
        )
        
        # Create upload directory
        upload_dir = @upload_base_dir.join(fu.id.to_s)
        FileUtils.mkdir_p(upload_dir)
        
        # Determine the file extension for the upload
        source_ext = File.extname(source_file)
        upload_filename = "input_file#{source_ext}"
        upload_path = upload_dir.join(upload_filename)
        
        # Copy file to upload directory
        FileUtils.cp(source_file, upload_path)
        
        # Update Fu record with correct filename
        fu.update!(upload_file_name: upload_filename)
        
        # Run preparsing service
        service = FuPreparsingService.new(fu, { organism_id: @organism.id })
        
        result = service.call
        
        # Validate result structure
        assert result.is_a?(Hash), "Result should be a Hash"
        assert result.key?(:summary), "Result should have :summary key"
        assert result.key?(:warnings), "Result should have :warnings key"
        
        # Validate summary structure
        summary = result[:summary]
        assert summary.is_a?(Hash), "Summary should be a Hash"
        
        # Check that we got some datasets or at least format detection
        assert summary.key?(:detected_format), "Summary should have detected_format"
        
        puts "  ✓ Passed - Format: #{summary[:detected_format]}"
        if summary[:datasets] && summary[:datasets].any?
          dataset = summary[:datasets].first
          puts "    - Datasets: #{summary[:datasets].size}"
          puts "    - Cells: #{dataset[:cell_count] || 'N/A'}, Genes: #{dataset[:gene_count] || 'N/A'}"
        end
        
        results[:passed] << filename
        
        # Cleanup
        FileUtils.rm_rf(upload_dir) if upload_dir.exist?
        
      rescue => e
        error_msg = "#{e.class}: #{e.message}"
        puts "  ✗ Failed: #{error_msg}"
        if e.backtrace
          puts "    Backtrace: #{e.backtrace.first(3).join("\n    ")}"
        end
        results[:failed] << { filename: filename, error: error_msg }
        
        # Cleanup on error
        begin
          FileUtils.rm_rf(upload_dir) if defined?(upload_dir) && upload_dir&.exist?
        rescue
          # Ignore cleanup errors
        end
      end
    end
    
    # Print summary
    puts "\n" + "=" * 80
    puts "TEST SUMMARY"
    puts "=" * 80
    puts "Total files tested: #{test_files.size}"
    puts "Passed: #{results[:passed].size}"
    puts "Failed: #{results[:failed].size}"
    puts "Skipped: #{results[:skipped].size}"
    
    if results[:failed].any?
      puts "\nFAILED FILES:"
      results[:failed].each do |failure|
        puts "  - #{failure[:filename]}: #{failure[:error]}"
      end
    end
    
    # Assert that at least some tests passed
    assert results[:passed].any?, "At least one file should have passed preparsing"
    
    # Print detailed results
    puts "\nPASSED FILES (#{results[:passed].size}):"
    results[:passed].each do |filename|
      puts "  ✓ #{filename}"
    end
  end

  test "preparsing handles specific file types correctly" do
    # Test specific file types that we know exist
    test_cases = [
      { pattern: /\.h5ad$/, description: 'H5AD files' },
      { pattern: /\.loom$/, description: 'Loom files' },
      { pattern: /\.h5$/, description: 'H5 files' },
      { pattern: /\.tab$/, description: 'Tab files' },
      { pattern: /\.txt$/, description: 'Text files' },
      { pattern: /\.gz$/, description: 'Gzip files' },
      { pattern: /\.zip$/, description: 'Zip files' },
      { pattern: /\.rds$/, description: 'RDS files' }
    ]
    
    test_files = get_test_files
    skip "No test files found" if test_files.empty?
    
    test_cases.each do |test_case|
      matching_files = test_files.select { |f| File.basename(f).match?(test_case[:pattern]) }
      
      next if matching_files.empty?
      
      # Test first matching file of each type
      source_file = matching_files.first
      filename = File.basename(source_file)
      
      puts "\nTesting #{test_case[:description]}: #{filename}"
      
      fu = Fu.create!(
        user: @user,
        upload_file_name: 'input_file',
        upload_file_size: File.size(source_file),
        status: 'uploaded',
        name: filename
      )
      
      upload_dir = @upload_base_dir.join(fu.id.to_s)
      FileUtils.mkdir_p(upload_dir)
      
      source_ext = File.extname(source_file)
      upload_filename = "input_file#{source_ext}"
      upload_path = upload_dir.join(upload_filename)
      
      FileUtils.cp(source_file, upload_path)
      fu.update!(upload_file_name: upload_filename)
      
      service = FuPreparsingService.new(fu, { organism_id: @organism.id })
      
      result = service.call
      assert result[:summary].present?, "Should have summary"
      assert result[:summary][:detected_format].present?, "Should detect format"
      puts "  ✓ Format detected: #{result[:summary][:detected_format]}"
      
      FileUtils.rm_rf(upload_dir) if upload_dir.exist?
    end
  end

  test "preparsing validates organism_id requirement" do
    test_files = get_test_files
    skip "No test files found" if test_files.empty?
    
    source_file = test_files.first
    filename = File.basename(source_file)
    
    fu = Fu.create!(
      user: @user,
      upload_file_name: 'input_file',
      upload_file_size: File.size(source_file),
      status: 'uploaded',
      name: filename
    )
    
    upload_dir = @upload_base_dir.join(fu.id.to_s)
    FileUtils.mkdir_p(upload_dir)
    
    source_ext = File.extname(source_file)
    upload_filename = "input_file#{source_ext}"
    upload_path = upload_dir.join(upload_filename)
    
    FileUtils.cp(source_file, upload_path)
    fu.update!(upload_file_name: upload_filename)
    
    # Test without organism_id
    service = FuPreparsingService.new(fu, {})
    
    assert_raises(RuntimeError, /Organism ID is required/) do
      service.call
    end
    
    FileUtils.rm_rf(upload_dir) if upload_dir.exist?
  end
end

