require 'open3'
require 'json'

class H5DataService
  # 1. Gene expression data
  def self.get_gene_data(genes, h5_path)
    # Construct the command to query the h5 file
    # Adjust the command based on your actual h5 query tool
    # Escape gene names that might contain special characters
    escaped_genes = genes.map { |g| g.gsub("'", "\\'") }
    cmd = "java -jar lib/ASAP.jar -T ExtractRow -loom #{h5_path} -iAnnot /matrix -names '#{escaped_genes.join(',')}'"

    stdout, stderr, status = Open3.capture3(cmd)

    if status.success?
      begin
        JSON.parse(stdout)
      rescue JSON::ParserError => e
        Rails.logger.error("Failed to parse JSON from h5 query: #{e.message}")
        Rails.logger.error("Command output: #{stdout}")
        raise "Failed to parse h5 query results"
      end
    else
      Rails.logger.error("h5 query failed: #{stderr}")
      raise "Failed to query h5 file"
    end
  end

  # 1b. Pathway expression data (same as genes but from pathway-specific loom file)
  def self.get_pathway_data(pathway_ids, h5_path)
    # Use indexes (IDs) instead of names to avoid comma-separation issues
    # Convert pathway IDs to 0-based indexes (assuming IDs start from 1)
    indexes = pathway_ids.map { |id| (id.to_i - 1).to_s }
    cmd = "java -jar lib/ASAP.jar -T ExtractRow -loom #{h5_path} -iAnnot /matrix -indexes #{indexes.join(',')}"

    stdout, stderr, status = Open3.capture3(cmd)

    if status.success?
      begin
        JSON.parse(stdout)
      rescue JSON::ParserError => e
        raise "Failed to parse pathway h5 query results"
      end
    else
      raise "Failed to query pathway h5 file"
    end
  end

  # 2. UMAP coordinates (from JSON file)
  def self.get_umap_coordinates(umap_path)
    #raise "UMAP file not found: #{umap_path}" unless File.exist?(umap_path)
    #JSON.parse(File.read(umap_path))
    cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -meta /col_attrs/#{annot_name} -loom #{h5_path}"

    stdout, stderr, status = Open3.capture3(cmd)
  end

  # 3. Annotation categories (category => [cell_ids])
  def self.get_annotation_categories(h5_path, annot_name, dataset_metadata_path = nil)
    cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -meta /col_attrs/#{annot_name} -loom #{h5_path}"

    stdout, stderr, status = Open3.capture3(cmd)

    raise "Failed to extract annotation metadata: #{stderr}" unless status.success?

    begin
      meta = JSON.parse(stdout)
      values = meta['values']

      if values.include?('Unselected')
        unselected_count_original = values.count('Unselected')
      end

      # If dataset name is provided, check for dataset filtering
      if dataset_metadata_path and dataset_metadata_path.strip != "Integrated"
        dataset_cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -meta /col_attrs/Condition -loom #{h5_path}"
        dataset_stdout, dataset_stderr, dataset_status = Open3.capture3(dataset_cmd)

        if dataset_status.success?
          dataset_meta = JSON.parse(dataset_stdout)
          dataset_values = dataset_meta['values']

          # Count cells for each dataset
          dataset_counts = dataset_values.group_by(&:itself).transform_values(&:count)

          # Modify annotation values to "Unselected" when dataset doesn't match the specified name
          unselected_count = 0
          selected_count = 0
          values.each_with_index do |value, idx|
            if dataset_values[idx] != dataset_metadata_path
              values[idx] = "Unselected"
              unselected_count += 1
            else
              selected_count += 1
            end
          end
        else
          Rails.logger.warn("Failed to extract dataset metadata: #{dataset_stderr}")
          Rails.logger.warn("Dataset command status: #{dataset_status}")
        end
      else
        Rails.logger.debug("Dataset filtering disabled - dataset_metadata_path: #{dataset_metadata_path}")
        Rails.logger.debug("No filtering applied - using original annotation values")
      end

      cell_ids = (0...values.length).to_a
      categories = values.uniq

      result = {}
      categories.each { |cat| result[cat] = [] }
      values.each_with_index { |cat, idx| result[cat] << cell_ids[idx] }

      # Log summary of final categories
      total_cells = result.values.sum(&:length)

      result
    rescue JSON::ParserError => e
      Rails.logger.error("JSON parse error: #{e.message}")
      Rails.logger.error("STDOUT content: #{stdout}")
      raise "Failed to parse annotation metadata JSON: #{e.message}"
    end
  end



  def self.get_metadata_values(h5_file, metadata_path)
    begin
      # Use ASAP.jar to extract metadata values with -no-values flag for clean summary
      cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -no-values -meta #{metadata_path} -loom #{h5_file}"
      result = `#{cmd}`

      if $?.success?
        # Parse the JSON output to extract unique category names
        begin
          json_data = JSON.parse(result)
          categories = json_data['categories']
          if categories
            # Return just the category names (keys) as an array
            categories.keys.sort
          else
            Rails.logger.error "No categories found in metadata output: #{result}"
            []
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Failed to parse JSON from metadata extraction: #{e.message}"
          Rails.logger.error "Raw output: #{result}"
          []
        end
      else
        Rails.logger.error "Failed to extract metadata from #{metadata_path}: #{result}"
        []
      end
    rescue => e
      Rails.logger.error "Error extracting metadata from #{metadata_path}: #{e.message}"
      []
    end
  end

  # Extract the full metadata vector for all cells (one value per cell)
  def self.get_metadata_vector(h5_file, metadata_path)
    begin
      # Use ASAP.jar to extract the full metadata vector (with values)
      cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -meta #{metadata_path} -loom #{h5_file}"
      Rails.logger.info "Executing ASAP.jar command: #{cmd}"
      result = `#{cmd}`
      Rails.logger.info "Command exit status: #{$?.exitstatus}"
      Rails.logger.info "Command output length: #{result.length} characters"

      if $?.success?
        begin
          # Parse JSON - handle both single vectors and coordinate pairs
          json_data = JSON.parse(result)
          
          Rails.logger.info "Metadata extraction result for #{metadata_path}: nber_rows=#{json_data['nber_rows']}, values type=#{json_data['values']&.class}"
          
          if json_data['values'].is_a?(Array)
            case json_data['nber_rows']
            when 2
              # Coordinate pairs - extract two vectors and zip them
              v1, v2 = json_data['values']
              if v1.is_a?(Array) && v2.is_a?(Array) && v1.length == v2.length
                # Convert to coordinate pairs
                coordinates = v1.zip(v2)
                Rails.logger.info "Successfully extracted metadata vector with #{coordinates.length} coordinate pairs from #{metadata_path}"
                return coordinates
              else
                Rails.logger.error "Invalid vector format for coordinate pairs: v1.length=#{v1&.length}, v2.length=#{v2&.length}"
                Rails.logger.error "v1 type: #{v1&.class}, v2 type: #{v2&.class}"
                return []
              end
            when 1
              # Single vector - return as array of single values
              single_vector = json_data['values']
              if single_vector.is_a?(Array)
                Rails.logger.info "Successfully extracted metadata vector with #{single_vector.length} single values from #{metadata_path}"
                return single_vector
              else
                Rails.logger.error "Invalid single vector format: type=#{single_vector.class}"
                return []
              end
            else
              Rails.logger.error "Unexpected nber_rows value: #{json_data['nber_rows']} (expected 1 or 2)"
              Rails.logger.error "JSON structure: #{json_data.keys}" if json_data.is_a?(Hash)
              Rails.logger.error "Raw output: #{result[0..500]}..." # Show first 500 chars
              return []
            end
          else
            Rails.logger.error "Invalid JSON format: 'values' is not an array"
            Rails.logger.error "JSON structure: #{json_data.keys}" if json_data.is_a?(Hash)
            Rails.logger.error "values type: #{json_data['values']&.class}"
            Rails.logger.error "Raw output: #{result[0..500]}..." # Show first 500 chars
            return []
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Failed to parse JSON from metadata vector extraction: #{e.message}"
          Rails.logger.error "Raw output: #{result}"
          return []
        end
      else
        Rails.logger.error "Failed to extract metadata vector from #{metadata_path}: #{result}"
        []
      end
    rescue => e
      Rails.logger.error "Error extracting metadata vector from #{metadata_path}: #{e.message}"
      []
    end
  end
end