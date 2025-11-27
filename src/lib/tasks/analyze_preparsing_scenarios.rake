namespace :preparsing do
  desc "Analyze preparsing JSON outputs and identify different UI scenarios"
  task analyze_scenarios: :environment do
    require 'json'
    require 'pathname'
    
    input_dir = '/mnt/asap-old/input_examples/'
    output_base_dir = Pathname.new(ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus'))
    
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
    
    puts "Analyzing preparsing outputs for #{files.size} files..."
    puts "=" * 80
    
    scenarios = {
      single_dataset: [],
      multiple_datasets: [],
      errors: [],
      warnings: [],
      compressed_files: [],
      archive_files: [],
      h5ad_files: [],
      loom_files: [],
      h5_files: [],
      text_files: []
    }
    
    files.each_with_index do |source_file, index|
      filename = File.basename(source_file)
      puts "\n[#{index + 1}/#{files.size}] Analyzing: #{filename}"
      
      # Check if output.json exists for this file (from a previous test run)
      # We'll need to run preparsing if outputs don't exist
      output_path = nil
      
      # Try to find existing output by searching for files with this name
      # For now, we'll need to actually run preparsing to get outputs
      # This is a placeholder - you'll need to run the tests first
      
      begin
        # Create a temporary Fu record for analysis
        user = User.first || User.create!(email: 'analyzer@example.com', password: 'password123')
        organism = Organism.first || Organism.create!(name: 'Test Organism')
        
        fu = Fu.create!(
          user: user,
          upload_file_name: 'input_file',
          upload_file_size: File.size(source_file),
          status: 'uploaded',
          name: filename
        )
        
        upload_dir = output_base_dir.join(fu.id.to_s)
        FileUtils.mkdir_p(upload_dir) unless upload_dir.exist?
        
        source_ext = File.extname(source_file)
        upload_filename = "input_file#{source_ext}"
        upload_path = upload_dir.join(upload_filename)
        
        FileUtils.cp(source_file, upload_path)
        fu.update!(upload_file_name: upload_filename)
        
        # Run preparsing
        service = FuPreparsingService.new(fu, { organism_id: organism.id })
        result = service.call
        
        # Analyze the output
        summary = result[:summary]
        warnings = result[:warnings]
        
        output_info = {
          filename: filename,
          fu_id: fu.id,
          detected_format: summary[:detected_format],
          dataset_count: summary[:dataset_count] || 0,
          datasets: summary[:datasets] || [],
          has_errors: summary[:displayed_error].present?,
          has_warnings: warnings.any?,
          warnings: warnings,
          error: summary[:displayed_error]
        }
        
        # Categorize scenarios
        if output_info[:dataset_count] == 1
          scenarios[:single_dataset] << output_info
        elsif output_info[:dataset_count] > 1
          scenarios[:multiple_datasets] << output_info
        end
        
        if output_info[:has_errors]
          scenarios[:errors] << output_info
        end
        
        if output_info[:has_warnings]
          scenarios[:warnings] << output_info
        end
        
        # File type categorization
        if filename.match?(/\.(tar|tar\.gz|zip)$/i)
          scenarios[:archive_files] << output_info
        elsif filename.match?(/\.(gz|bz2|xz)$/i)
          scenarios[:compressed_files] << output_info
        elsif filename.match?(/\.h5ad$/i)
          scenarios[:h5ad_files] << output_info
        elsif filename.match?(/\.loom$/i)
          scenarios[:loom_files] << output_info
        elsif filename.match?(/\.h5$/i)
          scenarios[:h5_files] << output_info
        elsif filename.match?(/\.(txt|tab|tsv)$/i)
          scenarios[:text_files] << output_info
        end
        
        puts "  Format: #{output_info[:detected_format]}"
        puts "  Datasets: #{output_info[:dataset_count]}"
        if output_info[:has_warnings]
          puts "  Warnings: #{warnings.size}"
        end
        
        # Cleanup
        FileUtils.rm_rf(upload_dir) if upload_dir.exist?
        
      rescue => e
        puts "  ERROR: #{e.class}: #{e.message}"
        scenarios[:errors] << {
          filename: filename,
          error: "#{e.class}: #{e.message}"
        }
      end
    end
    
    # Print analysis summary
    puts "\n" + "=" * 80
    puts "SCENARIO ANALYSIS SUMMARY"
    puts "=" * 80
    
    puts "\nSINGLE DATASET FILES (#{scenarios[:single_dataset].size}):"
    scenarios[:single_dataset].first(10).each do |info|
      puts "  - #{info[:filename]}: #{info[:detected_format]}"
    end
    puts "  ... and #{[0, scenarios[:single_dataset].size - 10].max} more" if scenarios[:single_dataset].size > 10
    
    puts "\nMULTIPLE DATASET FILES (#{scenarios[:multiple_datasets].size}):"
    scenarios[:multiple_datasets].each do |info|
      puts "  - #{info[:filename]}: #{info[:dataset_count]} datasets (#{info[:detected_format]})"
      info[:datasets].each_with_index do |dataset, idx|
        puts "    #{idx + 1}. #{dataset[:name]} (#{dataset[:cell_count]} cells, #{dataset[:gene_count]} genes)"
      end
    end
    
    puts "\nFILES WITH WARNINGS (#{scenarios[:warnings].size}):"
    scenarios[:warnings].each do |info|
      puts "  - #{info[:filename]}:"
      info[:warnings].each do |warning|
        puts "    * #{warning}"
      end
    end
    
    puts "\nFILES WITH ERRORS (#{scenarios[:errors].size}):"
    scenarios[:errors].each do |info|
      puts "  - #{info[:filename]}: #{info[:error]}"
    end
    
    puts "\nFILE TYPE BREAKDOWN:"
    puts "  Archive files (.tar, .zip): #{scenarios[:archive_files].size}"
    puts "  Compressed files (.gz, .bz2): #{scenarios[:compressed_files].size}"
    puts "  H5AD files: #{scenarios[:h5ad_files].size}"
    puts "  Loom files: #{scenarios[:loom_files].size}"
    puts "  H5 files: #{scenarios[:h5_files].size}"
    puts "  Text files (.txt, .tab): #{scenarios[:text_files].size}"
    
    # Generate scenario report
    puts "\n" + "=" * 80
    puts "UI SCENARIO RECOMMENDATIONS"
    puts "=" * 80
    
    if scenarios[:multiple_datasets].any?
      puts "\n1. MULTIPLE DATASET SELECTION SCENARIO"
      puts "   Files with multiple datasets need a selection interface:"
      scenarios[:multiple_datasets].each do |info|
        puts "   - #{info[:filename]} (#{info[:dataset_count]} datasets)"
      end
      puts "\n   UI Requirements:"
      puts "   * Display list of datasets with details (cells, genes, name)"
      puts "   * Allow user to select one dataset"
      puts "   * Rerun preparsing for selected dataset (or extract details from existing output)"
      puts "   * Update form fields based on selected dataset"
    end
    
    if scenarios[:errors].any?
      puts "\n2. ERROR HANDLING SCENARIO"
      puts "   Files that failed preparsing need error display:"
      scenarios[:errors].first(5).each do |info|
        puts "   - #{info[:filename]}: #{info[:error]}"
      end
      puts "\n   UI Requirements:"
      puts "   * Show clear error message"
      puts "   * Suggest possible solutions"
      puts "   * Allow user to retry or upload different file"
    end
    
    if scenarios[:warnings].any?
      puts "\n3. WARNING DISPLAY SCENARIO"
      puts "   Files with warnings need attention display:"
      puts "\n   UI Requirements:"
      puts "   * Show warnings in a prominent but non-blocking way"
      puts "   * Allow user to proceed with warnings"
      puts "   * Document what warnings mean"
    end
    
    puts "\n" + "=" * 80
    puts "Analysis complete!"
  end
end

