class ProjectsController < ApplicationController
  before_action :set_project, only: %i[ show edit update destroy metadata_coordinates metadata_vectors]

  # GET /projects or /projects.json
  def index
    @query = params[:q]
    @filters = {
      organism_id: params[:organism_id],
      technology: params[:technology],
      tissue: params[:tissue],
      status_id: params[:status_id],
      public_only: params[:public_only],
      sort: params[:sort] || 'created_at',
      page: params[:page] || 1
    }
    
    # Use Elasticsearch for search
    search_results = Project.search(@query, @filters)
    
    # Extract projects from search results
    @projects = search_results.records
    
    # Get aggregations for filter dropdowns
    @aggregations = search_results.response['aggregations']
    
    # For filter dropdowns (fallback to database if no aggregations)
    @organisms = Organism.order(:name)
    @statuses = Status.order(:name)
    @technologies = @aggregations&.dig('technologies', 'buckets')&.map { |b| b['key'] } || Project.distinct.pluck(:technology).compact.sort
    @tissues = @aggregations&.dig('tissues', 'buckets')&.map { |b| b['key'] } || Project.distinct.pluck(:tissue).compact.sort
    
    # Pagination - extract total count from Elasticsearch response
    @total_count = search_results.response['hits']['total']['value']
    @current_page = (params[:page] || 1).to_i
    @per_page = 20
    
    respond_to do |format|
      format.html
      format.json { render json: @projects }
    end
  end

  def organize_metadata(available_metadata)
    h_metadata = {}
    h_data_types = {}
    DataType.all.each do |data_type|
      h_data_types[data_type.id] = data_type
    end
    dims = ['cell', 'gene', 'expression','global']
    available_metadata.each do |metadata|
      h_metadata[metadata.filepath]||={}
      h_metadata[metadata.filepath][dims[metadata.dim-1]] ||= {}
      h_metadata[metadata.filepath][dims[metadata.dim-1]][h_data_types[metadata.data_type_id].name] ||= []
      h_metadata[metadata.filepath][dims[metadata.dim-1]][h_data_types[metadata.data_type_id].name] << metadata
    end
    h_metadata
  end

  # GET /projects/1 or /projects/1.json
  def show
    @view_type = params[:view] || 'visualization'
    
    # Get available loom files and metadata for the project
    @available_loom_files = Annot.available_loom_files(@project.id)
    available_metadata = Annot.available_metadata(@project.id)
    
    @h_metadata = organize_metadata(available_metadata)

    # Get all embeddings for all loom files
    #@all_embeddings_by_loom = {}
    #@available_loom_files.each do |filepath|
    #  @all_embeddings_by_loom[filepath] = Annot.available_embeddings_for_loom(@project.id, filepath)
    #end
    
    # Get default embeddings (for the first loom file that has embeddings)
    @default_loom_file = 'parsing/output.loom'
    #@available_embeddings = default_loom_file ? @all_embeddings_by_loom[default_loom_file] : []

    # Variables for summary view
    if @view_type == 'summary'
      # Get time to destroy for sandbox projects
      @time_to_destroy = nil
      if @project.sandbox? && !current_user
        @time_to_destroy = @project.updated_at + 2.days
      end
      
      # Get cloned project info if applicable
      @cloned_project = @project.cloned_project if @project.cloned_project_id
      
      # Get runs for the project (needed for filter_runs partial)
      @runs = @project.runs.includes(:annots)
      
      # Get steps hash (needed for filter_runs partial)
      @h_steps = {}
      Step.all.each do |step|
        @h_steps[step.id] = step
      end
      
      # Additional variables needed for filter_runs partial
      @h_all_runs = {}
      @runs.each { |run| @h_all_runs[run.id] = run }
      
      @h_lineage_run_ids_by_step_id = {}
      @runs.group_by(&:step_id).each do |step_id, runs|
        @h_lineage_run_ids_by_step_id[step_id] = runs.map(&:id)
      end
      
      @list_filter_run_ids = []
      @h_children_run_ids = {}
      @step = @project.step || Step.first
      @disable_filter = false
      
      # Get articles hash for DOI references
      @h_articles = {}
      if @project.doi.present?
        dois = @project.doi.split(/\s*,\s*/)
        Article.where(doi: dois).each do |article|
          @h_articles[article.doi] = article
        end
      end
      
      # Get experimental entries and identifier types
      @h_exp_entries = {}
      @h_identifier_types = {}
      @project.exp_entries.includes(:identifier_type).each do |exp_entry|
        type_id = exp_entry.identifier_type_id
        @h_exp_entries[type_id] ||= []
        @h_exp_entries[type_id] << exp_entry
        
        if exp_entry.identifier_type
          @h_identifier_types[type_id] = exp_entry.identifier_type
        end
      end
      
      # Get project type
      @project_type = @project.project_type
      
      # Generate klay data for pipeline visualization
      @klay_data = generate_klay_data
      
      # Generate list cards for runs display
      @list_cards = generate_list_cards
      
      # Initialize session variables if not present
      session[:activated_filter] ||= {}
      session[:activated_filter][@project.id] ||= false
    end
    
    # For testing, if no embeddings found, use a project that has them
    #if @available_embeddings.empty?
    #if test_project
     # #  test_project = Project.joins(:annots).where("annots.name LIKE ?", '/col_attrs/_umap_%').first
     #   @available_embeddings = Annot.available_embeddings(test_project.id)
    #    @available_metadata = Annot.available_metadata(test_project.id)
    #  end
    #end
    
    respond_to do |format|
      format.html { render layout: false }
      format.json { render json: @project }
    end
  end

  # GET /projects/new
  def new
    @project = Project.new
  end

  # GET /projects/1/edit
  def edit
  end

  # POST /projects or /projects.json
  def create
    @project = Project.new(project_params)

    respond_to do |format|
      if @project.save
        format.html { redirect_to @project, notice: "Project was successfully created." }
        format.json { render :show, status: :created, location: @project }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @project.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /projects/1 or /projects/1.json
  def update
    respond_to do |format|
      if @project.update(project_params)
        format.html { redirect_to @project, notice: "Project was successfully updated." }
        format.json { render :show, status: :ok, location: @project }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @project.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /projects/1 or /projects/1.json
  def destroy
    @project.destroy!

    respond_to do |format|
      format.html { redirect_to projects_path, status: :see_other, notice: "Project was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  # GET /projects/1/instructions
  def instructions
    # Placeholder for instructions action
    render plain: "Instructions for project #{@project.key}"
  end

  # GET /projects/1/get_commands
  def get_commands
    # Placeholder for get_commands action
    render plain: "Commands for project #{@project.key}"
  end

  # GET /projects/1/get_file
  def get_file
    # Placeholder for get_file action
    render plain: "File for project #{@project.key}"
  end

  # GET /projects/1/get_loom_files_json
  def get_loom_files_json
    # Placeholder for get_loom_files_json action
    render json: []
  end

  # GET /projects/1/get_step
  def get_step
    # Placeholder for get_step action
    render plain: "Step for project #{@project.key}"
  end

  # GET /projects/1/get_run
  def get_run
    # Placeholder for get_run action
    render plain: "Run for project #{@project.key}"
  end

  # GET /projects/1/get_lineage
  def get_lineage
    # Placeholder for get_lineage action
    render plain: "Lineage for project #{@project.key}"
  end

  # GET /projects/1/tsv_from_json
  def tsv_from_json
    # Placeholder for tsv_from_json action
    render plain: "TSV from JSON for project #{@project.key}"
  end

  # GET /projects/1/summary_test
  def summary_test
    @view_type = 'summary'
    # Get time to destroy for sandbox projects
    @time_to_destroy = nil
    if @project.sandbox? && !current_user
      @time_to_destroy = @project.updated_at + 2.days
    end
    
    # Get cloned project info if applicable
    @cloned_project = @project.cloned_project if @project.cloned_project_id
    
    # Get runs for the project (needed for filter_runs partial)
    @runs = @project.runs.includes(:annots)
    
    # Get steps hash (needed for filter_runs partial)
    @h_steps = {}
    Step.all.each do |step|
      @h_steps[step.id] = step
    end
    
    # Additional variables needed for filter_runs partial
    @h_all_runs = {}
    @runs.each { |run| @h_all_runs[run.id] = run }
    
    @h_lineage_run_ids_by_step_id = {}
    @runs.group_by(&:step_id).each do |step_id, runs|
      @h_lineage_run_ids_by_step_id[step_id] = runs.map(&:id)
    end
    
    @list_filter_run_ids = []
    @h_children_run_ids = {}
    @step = @project.step || Step.first
    @disable_filter = false
    
    # Get articles hash for DOI references
    @h_articles = {}
    if @project.doi.present?
      dois = @project.doi.split(/\s*,\s*/)
      Article.where(doi: dois).each do |article|
        @h_articles[article.doi] = article
      end
    end
    
    # Get experimental entries and identifier types
    @h_exp_entries = {}
    @h_identifier_types = {}
    @project.exp_entries.includes(:identifier_type).each do |exp_entry|
      type_id = exp_entry.identifier_type_id
      @h_exp_entries[type_id] ||= []
      @h_exp_entries[type_id] << exp_entry
      
      if exp_entry.identifier_type
        @h_identifier_types[type_id] = exp_entry.identifier_type
      end
    end
    
    # Get project type
    @project_type = @project.project_type
    
    # Generate klay data for pipeline visualization
    @klay_data = generate_klay_data
    
    # Generate list cards for runs display
    @list_cards = generate_list_cards
    
    # Initialize session variables if not present
    session[:activated_filter] ||= {}
    session[:activated_filter][@project.id] ||= false
    
    render 'summary_test'
  end

  # GET /projects/1/metadata_coordinates.json
  def metadata_coordinates
    metadata_id = params[:metadata_id]
    loom_file = params[:loom_file] || @default_loom_file
    
    # Find the metadata annotation
    metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
    
    if metadata.nil?
      render json: { error: 'Metadata not found' }, status: 404
      return
    end
    
    # Get the full path to the loom file
    loom_path = @project_dir + loom_file
    
    begin
      # Extract metadata coordinates using the service
      Rails.logger.info "Extracting metadata coordinates for: #{metadata.name}"
      Rails.logger.info "Loom file path: #{loom_path}"
      
      # Use metadata name directly (it should already include the correct path)
      coordinates = H5DataService.get_metadata_vector(loom_path.to_s, metadata.name)
      
      Rails.logger.info "Raw coordinates retrieved: #{coordinates.length} coordinate pairs"
      Rails.logger.info "First 5 coordinates: #{coordinates.first(5).inspect}"
      Rails.logger.info "Last 5 coordinates: #{coordinates.last(5).inspect}"
      
      if coordinates.empty?
        Rails.logger.error "No coordinates found for metadata: #{metadata.name}"
        render json: { error: 'No coordinates found' }, status: 404
        return
      end
      
      # Log coordinate statistics
      if coordinates.first.is_a?(Array) && coordinates.first.length >= 2
        x_values = coordinates.map { |coord| coord[0] }.compact
        y_values = coordinates.map { |coord| coord[1] }.compact
        
        Rails.logger.info "X values range: #{x_values.min} to #{x_values.max}"
        Rails.logger.info "Y values range: #{y_values.min} to #{y_values.max}"
        Rails.logger.info "X values sample: #{x_values.first(10).inspect}"
        Rails.logger.info "Y values sample: #{y_values.first(10).inspect}"
      end
      
      # Compress the data to binary format
      binary_data = compress_coordinates_to_binary(coordinates)
      
      # Return binary data with metadata headers
      response.headers['Content-Type'] = 'application/octet-stream'
      response.headers['X-Metadata-ID'] = metadata_id.to_s
      response.headers['X-Metadata-Name'] = metadata.display_name
      response.headers['X-Cell-Count'] = coordinates.length.to_s
      response.headers['X-Data-Type'] = 'coordinates'
      
      render body: binary_data
    rescue => e
      Rails.logger.error "Error fetching metadata coordinates: #{e.message}"
      render json: { error: 'Failed to fetch coordinates' }, status: 500
    end
  end

  # GET /projects/1/metadata_vectors.json
  def metadata_vectors
    loom_file = params[:loom_file] || @default_loom_file
    metadata_ids = params[:metadata_ids]&.split(',') || []
    
    # Get the full path to the loom file
    loom_path = @project_dir + loom_file
    
    begin
      metadata_vectors_data = {}
      
      metadata_ids.each do |metadata_id|
        metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
        next unless metadata
        
        Rails.logger.info "Loading metadata vector for: #{metadata.display_name} (ID: #{metadata_id})"
        Rails.logger.info "Metadata path: #{metadata.name}, Data type: #{metadata.data_type.name}"
        Rails.logger.info "Loom file path: #{loom_path}"
        Rails.logger.info "Full command will be: java -jar lib/ASAP.jar -T ExtractMetadata -meta '#{metadata.name}' -loom '#{loom_path}'"
        
        # Get the raw metadata vector
        raw_vector = H5DataService.get_metadata_vector(loom_path.to_s, metadata.name)
        
        if raw_vector.empty?
          Rails.logger.warn "No data found for metadata: #{metadata.display_name} (path: #{metadata.name})"
          Rails.logger.warn "This could be due to: 1) Metadata path not found in loom file, 2) Empty metadata, 3) ASAP.jar extraction failed"
          next
        end
        
        Rails.logger.info "Successfully extracted #{raw_vector.length} values for #{metadata.display_name}"
        
        # Compress based on data type
        compressed_data = compress_metadata_vector(raw_vector, metadata)
        
        metadata_vectors_data[metadata_id] = {
          id: metadata.id,
          name: metadata.display_name,
          data_type: metadata.data_type.name,
          compressed_data: compressed_data[:data] ? Base64.encode64(compressed_data[:data]) : nil,
          compression_info: compressed_data[:info]
        }
        
        Rails.logger.info "Compressed metadata #{metadata.display_name}: #{compressed_data[:info]}"
      end
      
      render json: { 
        metadata_vectors: metadata_vectors_data,
        total_loaded: metadata_vectors_data.size,
        loom_file: loom_file
      }
    rescue => e
      Rails.logger.error "Error loading metadata vectors: #{e.message}"
      render json: { error: 'Failed to load metadata vectors' }, status: 500
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_project
      @project = Project.find(params.expect(:id))
      @project_dir = Pathname.new(ENV["USER_DATA_DIR"]) + @project.user_id.to_s + @project.key
    end

    # Only allow a list of trusted parameters through.
    def project_params
      params.fetch(:project, {})
    end
    
    # Compress coordinate data to binary format for maximum efficiency
    def compress_coordinates_to_binary(coordinates)
      # coordinates is an array of arrays: [[x1, y1], [x2, y2], ...]
      # We'll round to 3 decimal places and store as 16-bit signed integers
      
      Rails.logger.info "Starting binary compression of #{coordinates.length} coordinate pairs"
      
      # Convert to integers (multiply by 1000 for 3 decimal precision)
      integer_coords = coordinates.map do |coord_pair|
        if coord_pair.is_a?(Array) && coord_pair.length >= 2
          x = (coord_pair[0].to_f * 1000).round
          y = (coord_pair[1].to_f * 1000).round
          # Clamp to 16-bit signed integer range (-32,768 to 32,767)
          x = [[x, -32768].max, 32767].min
          y = [[y, -32768].max, 32767].min
          [x, y]
        else
          Rails.logger.warn "Invalid coordinate pair: #{coord_pair.inspect}"
          [0, 0] # fallback for invalid data
        end
      end
      
      # Log compression statistics
      x_integers = integer_coords.map { |coord| coord[0] }
      y_integers = integer_coords.map { |coord| coord[1] }
      
      Rails.logger.info "Integer X range: #{x_integers.min} to #{x_integers.max}"
      Rails.logger.info "Integer Y range: #{y_integers.min} to #{y_integers.max}"
      Rails.logger.info "First 5 integer coordinates: #{integer_coords.first(5).inspect}"
      
      # Create binary data using 16-bit signed integers (2 bytes per coordinate)
      # This gives us a range of -32.768 to 32.767 with 3 decimal precision
      binary_data = String.new(encoding: 'ASCII-8BIT')
      
      integer_coords.each do |x, y|
        # Pack as little-endian 16-bit signed integers
        binary_data << [x].pack('s<')  # 's<' = signed 16-bit little-endian
        binary_data << [y].pack('s<')
      end
      
      Rails.logger.info "Binary compression complete: #{binary_data.bytesize} bytes for #{coordinates.length} coordinate pairs"
      Rails.logger.info "Compression ratio: #{(coordinates.length * 2 * 8.0 / binary_data.bytesize).round(2)}x"
      
      binary_data
    end
    
    # Compress metadata vector based on data type
    def compress_metadata_vector(raw_vector, metadata)
      data_type = metadata.data_type.name
      
      case data_type
      when 'DISCRETE'
        compress_discrete_metadata_vector(raw_vector, metadata)
      when 'CONTINUOUS'
        compress_continuous_metadata_vector(raw_vector, metadata)
      else
        Rails.logger.warn "Unknown data type for compression: #{data_type}"
        { data: nil, info: "Unknown data type: #{data_type}" }
      end
    end
    
    # Compress discrete metadata by replacing values with category indices
    def compress_discrete_metadata_vector(raw_vector, metadata)
      Rails.logger.info "Compressing discrete metadata: #{metadata.display_name}"
      
      # Parse categories from metadata
      categories = []
      if metadata.categories_json.present?
        begin
          parsed_categories = JSON.parse(metadata.categories_json)
          if parsed_categories.is_a?(Hash)
            categories = parsed_categories.keys.sort
          elsif parsed_categories.is_a?(Array)
            categories = parsed_categories.sort
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Failed to parse categories for #{metadata.display_name}: #{e.message}"
          return { data: nil, info: "Failed to parse categories" }
        end
      end
      
      if categories.empty?
        Rails.logger.warn "No categories found for discrete metadata: #{metadata.display_name}"
        return { data: nil, info: "No categories available" }
      end
      
      # Create category to index mapping
      category_to_index = {}
      categories.each_with_index { |cat, idx| category_to_index[cat] = idx }
      
      Rails.logger.info "Found #{categories.length} categories for #{metadata.display_name}: #{categories.first(5).join(', ')}#{categories.length > 5 ? '...' : ''}"
      
      # Convert values to indices
      indices = raw_vector.map do |value|
        # Handle both single values and coordinate pairs
        actual_value = value.is_a?(Array) ? value[0] : value
        category_to_index[actual_value.to_s] || 0 # fallback to 0 if not found
      end
      
      # Determine optimal bit width based on actual number of unique categories
      unique_indices = indices.uniq.sort
      num_categories = unique_indices.length
      
      # Handle edge cases
      if num_categories <= 1
        Rails.logger.info "Only #{num_categories} unique category(ies) found - no compression needed"
        return { data: nil, info: "Only #{num_categories} category - no compression needed" }
      end
      
      # Calculate minimum bits needed
      min_bits_needed = Math.log2(num_categories).ceil
      
      # Choose bit width that can accommodate all categories
      bit_width = case min_bits_needed
                  when 1 then 1    # 1 bit for 2 categories (0, 1)
                  when 2..8 then 8     # 8 bits (1 byte) for 2-256 categories
                  when 9..16 then 16   # 16 bits (2 bytes) for 257-65536 categories
                  when 17..32 then 32  # 32 bits (4 bytes) for more categories
                  else 32  # fallback
                  end
      
      max_index = indices.max
      actual_categories_used = unique_indices.length
      
      Rails.logger.info "Compression optimization: #{actual_categories_used} unique categories, #{min_bits_needed} bits needed, using #{bit_width}-bit encoding"
      
      # Pack indices into binary data
      binary_data = String.new(encoding: 'ASCII-8BIT')
      
      case bit_width
      when 1
        # Special case: pack 8 indices per byte for 1-bit encoding
        indices.each_slice(8) do |slice|
          byte = 0
          slice.each_with_index do |idx, i|
            byte |= (idx & 1) << i
          end
          binary_data << [byte].pack('C')
        end
      when 8
        indices.each { |idx| binary_data << [idx].pack('C') }  # unsigned char
      when 16
        indices.each { |idx| binary_data << [idx].pack('v') }  # unsigned short little-endian
      when 32
        indices.each { |idx| binary_data << [idx].pack('V') }  # unsigned long little-endian
      end
      
      compression_info = {
        type: 'discrete',
        categories: categories,
        bit_width: bit_width,
        cell_count: raw_vector.length,
        category_count: categories.length,
        unique_categories_used: actual_categories_used,
        min_bits_needed: min_bits_needed,
        binary_size: binary_data.bytesize,
        compression_ratio: (raw_vector.length * 4.0 / binary_data.bytesize).round(2) # assuming original was 4 bytes per value
      }
      
      Rails.logger.info "Discrete compression complete: #{binary_data.bytesize} bytes for #{raw_vector.length} cells (#{compression_info[:compression_ratio]}x compression)"
      
      { data: binary_data, info: compression_info }
    end
    
    # Compress continuous metadata using float compression
    def compress_continuous_metadata_vector(raw_vector, metadata)
      Rails.logger.info "Compressing continuous metadata: #{metadata.display_name}"
      
      # Extract numeric values from raw vector
      numeric_values = raw_vector.map do |value|
        # Handle both single values and coordinate pairs
        actual_value = value.is_a?(Array) ? value[0] : value
        actual_value.to_f
      end
      
      # Calculate statistics
      min_val = numeric_values.min
      max_val = numeric_values.max
      range = max_val - min_val
      
      Rails.logger.info "Continuous value range: #{min_val} to #{max_val} (range: #{range})"
      
      # Determine optimal precision and bit width
      if range <= 0
        Rails.logger.warn "Zero range for continuous metadata: #{metadata.display_name}"
        return { data: nil, info: "Zero range - no variation in data" }
      end
      
      # Use 16-bit unsigned integers with normalization
      # This gives us good precision for most continuous data
      normalized_values = numeric_values.map do |val|
        # Normalize to 0-65535 range
        normalized = ((val - min_val) / range * 65535).round
        [[normalized, 0].max, 65535].min  # clamp to valid range
      end
      
      # Pack into binary data
      binary_data = String.new(encoding: 'ASCII-8BIT')
      normalized_values.each { |val| binary_data << [val].pack('v') }  # unsigned short little-endian
      
      compression_info = {
        type: 'continuous',
        min_val: min_val,
        max_val: max_val,
        range: range,
        cell_count: raw_vector.length,
        bit_width: 16,
        binary_size: binary_data.bytesize,
        compression_ratio: (raw_vector.length * 8.0 / binary_data.bytesize).round(2) # assuming original was 8 bytes per value
      }
      
      Rails.logger.info "Continuous compression complete: #{binary_data.bytesize} bytes for #{raw_vector.length} cells (#{compression_info[:compression_ratio]}x compression)"
      
      { data: binary_data, info: compression_info }
    end
    
    # Generate klay data for pipeline visualization
    def generate_klay_data
      data = []
      
      # Add nodes for each step
      @h_steps.each do |step_id, step|
        data << {
          data: {
            id: step_id.to_s,
            label: step.name || "Step #{step_id}",
            color: get_step_color(step_id)
          }
        }
      end
      
      # Add edges between steps (simplified - you may want to make this more sophisticated)
      step_ids = @h_steps.keys.sort
      step_ids.each_with_index do |step_id, index|
        next if index == 0
        
        prev_step_id = step_ids[index - 1]
        data << {
          data: {
            id: "edge_#{prev_step_id}_#{step_id}",
            source: prev_step_id.to_s,
            target: step_id.to_s
          }
        }
      end
      
      data
    end
    
    # Generate list cards for runs display
    def generate_list_cards
      cards = []
      
      @h_steps.each do |step_id, step|
        runs_for_step = @runs.select { |run| run.step_id == step_id }
        
        # Generate card body with runs information
        card_body = "<h6 class='card-title'>#{step.name || "Step #{step_id}"}</h6>"
        
        if runs_for_step.any?
          card_body += "<div class='run-list'>"
          runs_for_step.each do |run|
            status_badge = get_status_badge_class(run.status_id)
            status_name = get_status_name(run.status_id)
            card_body += "<div class='run-item mb-2'>"
            card_body += "<span class='badge badge-secondary'>Run ##{run.num || run.id}</span> "
            card_body += "<span class='badge badge-#{status_badge}'>#{status_name}</span>"
            if run.created_at
              card_body += "<br><small class='text-muted'>#{run.created_at.strftime("%m/%d/%Y %H:%M")}</small>"
            end
            card_body += "</div>"
          end
          card_body += "</div>"
        else
          card_body += "<p class='text-muted'>No runs for this step</p>"
        end
        
        cards << {
          card_id: "step-#{step_id}",
          card_class: 'summary_step_card',
          body: card_body,
          footer: nil
        }
      end
      
      cards
    end
    
    # Get color for step visualization
    def get_step_color(step_id)
      colors = ['#3498db', '#e74c3c', '#2ecc71', '#f39c12', '#9b59b6', '#1abc9c', '#34495e']
      colors[step_id % colors.length]
    end
    
    # Get status badge class for display
    def get_status_badge_class(status_id)
      case status_id
      when 1
        'warning'  # waiting
      when 2
        'info'     # running
      when 3
        'success'  # completed
      when 4
        'danger'   # failed
      else
        'secondary'
      end
    end
    
    # Get status name for display
    def get_status_name(status_id)
      case status_id
      when 1
        'Waiting'
      when 2
        'Running'
      when 3
        'Completed'
      when 4
        'Failed'
      else
        'Unknown'
      end
    end
end
