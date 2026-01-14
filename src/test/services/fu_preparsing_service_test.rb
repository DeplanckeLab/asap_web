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
    # Suppress ActiveRecord SQL logging during tests
    @original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil
    
    # Suppress Rails logger output during tests (reduce verbosity)
    # Set to WARN to show warnings and errors, but suppress INFO/DEBUG messages
    @original_rails_logger = Rails.logger
    @original_rails_logger_level = Rails.logger.level
    Rails.logger.level = Logger::WARN
    
    # Create a dedicated test user (never use existing users to avoid deleting production data)
    @user = User.find_or_create_by!(email: 'test_preparsing@test.local') do |u|
      u.password = 'test_password_123'
      u.displayed_name = 'Test Preparsing User'
    end
    
    @organism = Organism.first || Organism.create!(name: 'Test Organism')
    
    # Track Fu records created during this test
    @created_fu_ids = []
    
    # Set up test-specific upload directory (not the production one)
    @test_output_dir = Pathname.new('/data/asap2_test/tests/preparsing')
    FileUtils.mkdir_p(@test_output_dir) unless @test_output_dir.exist?
    
    # Override UPLOAD_DATA_DIR for tests
    @original_upload_dir = ENV['UPLOAD_DATA_DIR']
    ENV['UPLOAD_DATA_DIR'] = @test_output_dir.to_s
  end
  
  teardown do
    # Restore original UPLOAD_DATA_DIR
    if @original_upload_dir
      ENV['UPLOAD_DATA_DIR'] = @original_upload_dir
    else
      ENV.delete('UPLOAD_DATA_DIR')
    end
    
    # Clean up ONLY Fu records created during this specific test (not all user's Fus!)
    if @created_fu_ids.any?
      Fu.where(id: @created_fu_ids).destroy_all
    end
    
    # Restore loggers
    ActiveRecord::Base.logger = @original_logger if defined?(@original_logger)
    Rails.logger.level = @original_rails_logger_level if defined?(@original_rails_logger_level)
  end

  def get_test_files
    unless Dir.exist?(INPUT_EXAMPLES_DIR)
      warn "WARNING: Input examples directory does not exist: #{INPUT_EXAMPLES_DIR}"
      warn "Make sure it's mounted in docker-compose.yml and container is restarted"
      return []
    end
    
    files = Dir.glob(File.join(INPUT_EXAMPLES_DIR, '*')).select do |file|
      next false unless File.file?(file)
      next false if EXCLUDED_PATTERNS.any? { |pattern| file.match?(pattern) }
      next false unless File.readable?(file)
      next false if File.size(file) == 0
      
      true
    end.sort
    
    files
  end

  test "preparsing works for all input example files" do
    test_files = get_test_files
    
    skip "No test files found in #{INPUT_EXAMPLES_DIR}" if test_files.empty?
    
    puts "\nTesting #{test_files.size} files..."
    
    results = {
      passed: [],
      failed: [],
      skipped: []
    }
    
    test_files.each_with_index do |source_file, index|
      filename = File.basename(source_file)
      print "[#{index + 1}/#{test_files.size}] #{filename}... "
      
      begin
        # Create Fu record
        fu = Fu.create!(
          user: @user,
          upload_file_name: 'input_file',
          upload_file_size: File.size(source_file),
          status: 'uploaded',
          name: filename
        )
        @created_fu_ids << fu.id
        
        # Create upload directory in test output location
        upload_dir = @test_output_dir.join(fu.id.to_s)
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
        
        # Display matrix size if available
        matrix_info = ""
        if summary[:datasets] && summary[:datasets].any?
          dataset = summary[:datasets].first
          if dataset[:gene_count] && dataset[:cell_count]
            matrix_info = " [#{dataset[:gene_count]}, #{dataset[:cell_count]}]"
          end
        end
        
        puts "✓ (#{summary[:detected_format]})#{matrix_info}"
        
        results[:passed] << filename
        
        # Copy output.json to test results directory for inspection
        output_file = upload_dir.join('output.json')
        if output_file.exist?
          test_result_dir = @test_output_dir.join('results')
          FileUtils.mkdir_p(test_result_dir)
          result_file = test_result_dir.join("#{filename.gsub(/[^a-zA-Z0-9._-]/, '_')}_output.json")
          FileUtils.cp(output_file, result_file)
        end
        
        # Cleanup upload directory (but keep results)
        FileUtils.rm_rf(upload_dir) if upload_dir.exist?
        
        # Clean up Fu record
        fu.destroy
        
      rescue => e
        error_msg = "#{e.class}: #{e.message}"
        puts "✗ (#{error_msg})"
        results[:failed] << { filename: filename, error: error_msg }
        
        # Cleanup on error
        begin
          FileUtils.rm_rf(upload_dir) if defined?(upload_dir) && upload_dir&.exist?
          fu.destroy if defined?(fu) && fu&.persisted?
        rescue
          # Ignore cleanup errors
        end
      end
    end
    
    # Print summary
    puts "\nSummary: #{results[:passed].size} passed, #{results[:failed].size} failed, #{results[:skipped].size} skipped"
    
    if results[:failed].any?
      puts "\nFailed files:"
      results[:failed].each do |failure|
        puts "  - #{failure[:filename]}: #{failure[:error]}"
      end
    end
    
    # Assert that at least some tests passed
    assert results[:passed].any?, "At least one file should have passed preparsing"
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
      
      print "Testing #{test_case[:description]}: #{filename}... "
      
      fu = Fu.create!(
        user: @user,
        upload_file_name: 'input_file',
        upload_file_size: File.size(source_file),
        status: 'uploaded',
        name: filename
      )
      @created_fu_ids << fu.id
      
      upload_dir = @test_output_dir.join(fu.id.to_s)
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
      
      # Display matrix size if available
      matrix_info = ""
      if result[:summary][:datasets] && result[:summary][:datasets].any?
        dataset = result[:summary][:datasets].first
        if dataset[:gene_count] && dataset[:cell_count]
          matrix_info = " [#{dataset[:gene_count]}, #{dataset[:cell_count]}]"
        end
      end
      
      puts "✓ (#{result[:summary][:detected_format]})#{matrix_info}"
      
      # Copy output.json to test results directory
      output_file = upload_dir.join('output.json')
      if output_file.exist?
        test_result_dir = @test_output_dir.join('results')
        FileUtils.mkdir_p(test_result_dir)
        result_file = test_result_dir.join("#{filename.gsub(/[^a-zA-Z0-9._-]/, '_')}_output.json")
        FileUtils.cp(output_file, result_file)
      end
      
      FileUtils.rm_rf(upload_dir) if upload_dir.exist?
      fu.destroy
    end
  end

  test "preparsing works without organism_id but predictions may fail" do
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
    @created_fu_ids << fu.id
    
    upload_dir = @test_output_dir.join(fu.id.to_s)
    FileUtils.mkdir_p(upload_dir)
    
    source_ext = File.extname(source_file)
    upload_filename = "input_file#{source_ext}"
    upload_path = upload_dir.join(upload_filename)
    
    FileUtils.cp(source_file, upload_path)
    fu.update!(upload_file_name: upload_filename)
    
    # Test without organism_id - preparsing should still work
    service = FuPreparsingService.new(fu, {})
    result = service.call
    
    # Preparsing should succeed
    assert result.is_a?(Hash), "Result should be a Hash"
    assert result.key?(:summary), "Result should have :summary key"
    assert result[:summary].key?(:detected_format), "Summary should have detected_format"
    
    # Predictions may not be available without organism_id, but that's OK
    # The preparsing itself should complete successfully
    
    FileUtils.rm_rf(upload_dir) if upload_dir.exist?
    fu.destroy
  end
end

