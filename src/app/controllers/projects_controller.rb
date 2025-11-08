class ProjectsController < ApplicationController
  before_action :set_project, only: %i[ show edit update destroy metadata_coordinates metadata_vectors gene_expression get_file]

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
    all_loom_files = Annot.available_loom_files(@project.id)
    available_metadata = Annot.available_metadata(@project.id)
    
    @h_metadata = organize_metadata(available_metadata)

    # Filter loom files to only include those with 2D/3D visualizations (UMAP/tSNE with 2 or 3 rows)
    @available_loom_files = all_loom_files.select do |filepath|
      @h_metadata[filepath] && 
      @h_metadata[filepath]['cell'] && 
      @h_metadata[filepath]['cell']['NUMERIC'] &&
      @h_metadata[filepath]['cell']['NUMERIC'].any? { |m| m.nber_rows && (m.nber_rows == 2) } # limit to 2D for now
    end
    
    # Get all embeddings for all loom files
    @all_embeddings_by_loom = {}
    @available_loom_files.each do |filepath|
      @all_embeddings_by_loom[filepath] = Annot.available_embeddings_for_loom(@project.id, filepath)
    end
    
    # Get default loom file - use the first loom file with visualizations
    Rails.logger.debug "🔍 [DEBUG] Available loom files: #{@available_loom_files.inspect}"
    Rails.logger.debug "🔍 [DEBUG] All loom files: #{all_loom_files.inspect}"
    @default_loom_file = @available_loom_files.first || all_loom_files.first || 'parsing/output.loom'
    Rails.logger.debug "🔍 [DEBUG] Default loom file set to: #{@default_loom_file}"

    # Preload expression matrices (dim = 3) grouped by loom file
    @expression_matrices_by_loom = Annot.where(project_id: @project.id, dim: 3)
                                        .order(id: :asc)
                                        .group_by(&:filepath)
    
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
    begin
      unless ENV["USER_DATA_DIR"]
        Rails.logger.error "get_file: USER_DATA_DIR environment variable is not set"
        render json: { error: 'Server configuration error' }, status: 500
        return
      end

      unless @project.user_id
        Rails.logger.error "get_file: Project #{@project.id} has no user_id"
        render json: { error: 'Project has no associated user' }, status: 500
        return
      end

      project_dir = Pathname.new(ENV["USER_DATA_DIR"]) + @project.user_id.to_s + @project.key
      run_id = (params[:run_id]) ? params[:run_id] : nil #((params[:filename] and m = params[:filename].match(/^(\d+)\.\w{1,3}/)) ? m[1].to_i : nil)                                                                                               
      step_name = params[:step]
      if run_id
        run =  Run.where(:id => run_id).first
        h_outputs = Basic.safe_parse_json(run.output_json, {})
        h_file_by_id = {}
        h_outputs.each_key do |k|
          h_outputs[k].each_key do |k2|
            t = k2.split(":")
            relative_path = t[0]
            full_path = project_dir + relative_path
            h_file_by_id[h_outputs[k][k2]['onum']]={:filename => h_outputs[k][k2]['filename'], :filepath => full_path}
          end
        end
        step_name = (step = run.step) ? step.name : nil
      end
  
      filepath = nil
      filename = nil
      if params[:onum]
        filename = h_file_by_id[params[:onum].to_i][:filename]
        filepath = h_file_by_id[params[:onum].to_i][:filepath]
      elsif params[:filename]
        filename = params[:filename]
        # Use @project.key instead of params[:key] since we already have the project loaded
        tmp_dir = Pathname.new(ENV["USER_DATA_DIR"]) + @project.user_id.to_s + @project.key
        tmp_dir += step_name if step_name
        tmp_dir += params[:run_id].to_s if params[:run_id]
        filepath = tmp_dir + filename
        Rails.logger.info "get_file: Constructed filepath for filename param: #{filepath}"
      end

      if filename.nil?
        Rails.logger.error "get_file: No filename provided and no onum provided"
        render :plain => "Filename or onum parameter required", status: 400
        return
      end
      
      ext = filename.split(".").last
      #    obj = c.constantize if params[:step] and c= params[:step].classify and ['GeneSet'].include?(c)                                                                                                                                          
      #    obj = Run                                                                                                                                                                                                                               
  
      # Allow JSON files from parsing/cell_filtering steps for autocomplete (they're project data files)
      json_allowed = (ext == 'json' && (step_name == 'parsing' || step_name == 'cell_filtering'))
      
      Rails.logger.info "get_file: filename=#{filename}, step_name=#{step_name}, ext=#{ext}, json_allowed=#{json_allowed}, filepath=#{filepath}"
      Rails.logger.info "get_file: readable?=#{readable?(@project)}, exportable?=#{exportable?(@project)}"
      
      authorized = readable?(@project) and (exportable?(@project) or ['png', 'pdf', 'jpeg', 'jpg'].include?(ext)) or (step_name == 'visualization' and filename.match(/trajectory/) and ext == 'json') or (step_name and run and exportable_item?(@project, run)) or json_allowed
      Rails.logger.info "get_file: authorized=#{authorized}"
      
      if authorized
  
        ## export to h5ad                                                                                                                                                                                                                          
        if filepath.to_s.match(/output\.h5ad$/)
          loom_filepath = filepath.dup.to_s
          loom_filepath.gsub!(/\.h5ad$/, '.loom')
          if !File.exist? filepath or (File.exist? filepath and File.ctime(filepath) < File.mtime(loom_filepath))  ## convert everytime                                                                                                           \
                                                                                                                                                                                                                                                   
            h_env = Basic.safe_parse_json(@project.version.env_json, {})
            docker_name = "#{h_env['docker_images']['asap_run']['name']}:#{h_env['docker_images']['asap_run']['tag']}"
            loom_filepath = filepath.dup.to_s
            loom_filepath.gsub!(/\.h5ad$/, '.loom')
            # if !File.exist? project_dir + h5ad_file                                                                                                                                                                                              
            rscript_cmd = "Rscript -e 'library(\\\"sceasy\\\"); loom_file <- \\\"#{loom_filepath}\\\"; sceasy::convertFormat(loom_file, from=\\\"loom\\\", to=\\\"anndata\\\", outFile=\\\"#{filepath.to_s}\\\")'"
            data_dir = ENV["DATA_DIR"] || ENV["USER_DATA_DIR"]
            cmd = "docker run --entrypoint '/bin/sh' --rm -v #{data_dir}:#{data_dir} #{docker_name} -c \"#{rscript_cmd}\""
            logger.debug("CREATE H5AD file: " + cmd)
            `#{cmd}`
          end
        end
        if File.exist? filepath
          if ['exec.err', 'exec.out'].include? filename
            content = File.read(filepath)
            content.gsub!(project_dir.to_s, "$PROJECT_DIR")
            send_data content, type: params[:content_type] || 'text', # type: 'application/octet-stream'                                                                                                                                           
            x_sendfile: true, buffer_size: 512, disposition: (!params[:display]) ? ("attachment; filename=" + [@project.key, step_name,  run_id, filename].compact.join("_")) : ''
          elsif ext == 'json' || filename.match(/\.json$/)
            # For JSON files, read and return content directly (needed for autocomplete_genes.json)
            Rails.logger.info "get_file: Reading JSON file from path: #{filepath}"
            if File.exist?(filepath)
              Rails.logger.info "get_file: File exists, size: #{File.size(filepath)} bytes"
              content = File.read(filepath)
              Rails.logger.info "get_file: File read successfully, content length: #{content.length} chars"
              begin
                json_data = JSON.parse(content)
                Rails.logger.info "get_file: JSON parsed successfully, keys: #{json_data.keys.inspect}"
                render json: json_data, content_type: 'application/json'
              rescue JSON::ParserError => e
                Rails.logger.error "Error parsing JSON file #{filename}: #{e.message}"
                Rails.logger.error "File content preview (first 500 chars): #{content[0..500]}"
                render json: { error: 'Invalid JSON file' }, status: 500
              end
            else
              Rails.logger.error "get_file: JSON file does not exist at path: #{filepath}"
              render json: { error: 'File not found' }, status: 404
            end
          else
            logger.debug "FILEPATH:" + filepath.to_s
            new_filepath = filepath.to_s.gsub(/^\/data\/asap2/, '/rails_send_file')

                       path = filepath.to_s.gsub(/\/data\/asap2/, "/rails_send_file") #"/rails_send_file/FB2020_05.sql.gz.05"                                                                                                                      
             headers['Content-Disposition'] = (!params[:display]) ? ("attachment; filename=" + [@project.key, step_name,  run_id, filename].compact.join("_")) : ''
              headers['X-Accel-Redirect'] = path #'/download_public/uploads/stories/' + params[:story_id] +'/' + params[:story_id] + '.zip'                                                                                                        
             # headers["X-Accel-Mapping"]=  "/data/asap2/=/rails_send_file/"                                                                                                                                                                       
             headers['Content-Type'] = "application/octet-stream"
             headers['Content-Length'] = File.size filepath
            render :nothing => true
  
          end
        else
          render :plain => "This file doesn't exist."
        end
      else
        Rails.logger.warn "get_file: Unauthorized access attempt for project #{@project.id}, filename: #{filename}"
        render :plain => 'Not authorized to download this file.', status: 403
      end
  
    rescue => e
      Rails.logger.error "get_file: Exception occurred: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: 'Internal server error', message: e.message }, status: 500
    end
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
    
    # Find the metadata annotation
    metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
    
    if metadata.nil?
      render json: { error: 'Metadata not found' }, status: 404
      return
    end
    
    # Use the metadata's own filepath to find the correct loom file
    loom_file = params[:loom_file] || metadata.filepath
    
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
    metadata_ids = params[:metadata_ids]&.split(',') || []
    
    begin
      metadata_vectors_data = {}
      loom_files_used = []
      
      metadata_ids.each do |metadata_id|
        metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
        next unless metadata
        
        # Use the metadata's own filepath to find the correct loom file
        loom_file = params[:loom_file] || metadata.filepath
        loom_path = @project_dir + loom_file
        loom_files_used << loom_file unless loom_files_used.include?(loom_file)
        
        Rails.logger.info "Loading metadata vector for: #{metadata.display_name} (ID: #{metadata_id})"
        Rails.logger.info "Metadata path: #{metadata.name}, Data type: #{metadata.data_type.name}"
        Rails.logger.info "Loom file path: #{loom_path}"
        preview_cmd = H5DataService.asap_command(
          '-T', 'ExtractMetadata',
          '-meta', metadata.name,
          '-loom', loom_path.to_s
        )
        Rails.logger.info "Full command will be: #{H5DataService.command_to_string(preview_cmd)}"
        
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
        loom_files: loom_files_used
      }
    rescue => e
      Rails.logger.error "Error loading metadata vectors: #{e.message}"
      render json: { error: 'Failed to load metadata vectors' }, status: 500
    end
  end

  # GET /projects/1/gene_expression.json?stable_id=123&loom_file=parsing/output.loom
  def gene_expression
    begin
      stable_id = params[:stable_id]
      loom_file = params[:loom_file] || 'parsing/output.loom'
      
      unless stable_id
        render json: { error: 'stable_id parameter is required' }, status: 400
        return
      end

      loom_path = @project_dir + loom_file
      # Resolve the expression matrix (Annot with dim 3)
      matrix_annot = nil
      if params[:annot_id].present?
        matrix_annot = Annot.find_by(id: params[:annot_id], project_id: @project.id, filepath: loom_file, dim: 3)
      end
      if matrix_annot.nil? && params[:layer].present?
        matrix_annot = Annot.where(project_id: @project.id, filepath: loom_file, dim: 3, name: params[:layer]).first
      end
      matrix_annot ||= Annot.where(project_id: @project.id, filepath: loom_file, dim: 3, name: '/matrix').first
      matrix_name = matrix_annot&.name || '/matrix'
      matrix_annot_id = matrix_annot&.id

      Rails.logger.info "Using expression matrix: #{matrix_name} (annot_id: #{matrix_annot_id || 'none'})"

      # Find gene metadata with _StableID name
      gene_metadata = Annot.where(project_id: @project.id, dim: 2, name: '/row_attrs/_StableID')
                             .where("filepath = ?", loom_file)
                             .first
      
      unless gene_metadata
        render json: { error: 'Gene metadata _StableID not found' }, status: 404
        return
      end

      # Use the metadata's actual name path from the database
      # This might be different from the hardcoded path
      stable_id_path = gene_metadata.name
      Rails.logger.info "Using stable_id path from metadata: #{stable_id_path} (filepath: #{gene_metadata.filepath})"
      
      # Get the stable ID vector to find the index
      Rails.logger.info "Extracting stable_id vector from: #{loom_path} at path: #{stable_id_path}"
      Rails.logger.info "File exists? #{File.exist?(loom_path)}"
      
      begin
        # Call get_metadata_vector and capture any issues
        Rails.logger.info "Calling H5DataService.get_metadata_vector with loom_path: #{loom_path}, metadata_path: #{stable_id_path}"
        stable_id_vector = H5DataService.get_metadata_vector(loom_path.to_s, stable_id_path)
        Rails.logger.info "get_metadata_vector returned: type=#{stable_id_vector.class}, size=#{stable_id_vector.respond_to?(:length) ? stable_id_vector.length : 'N/A'}"
      rescue => e
        Rails.logger.error "Error extracting stable_id vector: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        # Return more detailed error to help debug
        render json: { error: "Failed to extract stable ID vector: #{e.message}. File: #{loom_file}, Path: #{loom_path}. Please check Rails logs for ASAP.jar command output." }, status: 500
        return
      end
      
      Rails.logger.info "Gene expression lookup: stable_id=#{stable_id} (type: #{stable_id.class}), loom_file=#{loom_file}, vector_size=#{stable_id_vector.length}"
      
      if stable_id_vector.nil? || stable_id_vector.empty?
        Rails.logger.error "Stable ID vector is empty or nil! Path used: #{stable_id_path}, Loom file path: #{loom_path}, Loom file param: #{loom_file}"
        # Try alternative path as fallback
        fallback_path = '/row_attrs/_StableID'
        Rails.logger.info "Trying fallback path: #{fallback_path}"
        begin
          stable_id_vector = H5DataService.get_metadata_vector(loom_path.to_s, fallback_path)
          Rails.logger.info "Fallback path result: vector_size=#{stable_id_vector.length if stable_id_vector}"
        rescue => e
          Rails.logger.error "Fallback path also failed: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end
        
        if stable_id_vector.nil? || stable_id_vector.empty?
          error_msg = "Stable ID vector is empty. Loom file: #{loom_file} (full path: #{loom_path}). Tried metadata path: #{stable_id_path} and fallback: #{fallback_path}. Check if _StableID metadata exists in the loom file."
          Rails.logger.error error_msg
          render json: { error: error_msg }, status: 404
          return
        end
      end
      
      # Log first few values to see format
      sample_values = stable_id_vector.first(10).map(&:to_s)
      Rails.logger.info "Sample stable_id values from vector (first 10): #{sample_values.inspect}"
      Rails.logger.info "Sample value types: #{stable_id_vector.first(5).map { |v| "#{v} (#{v.class})" }.join(', ')}"
      
      # Find the index where stable_id matches
      gene_index = nil
      stable_id_vector.each_with_index do |value, index|
        # Convert both to string and strip whitespace for comparison
        value_str = value.to_s.strip
        stable_id_str = stable_id.to_s.strip
        
        if value_str == stable_id_str
          gene_index = index
          Rails.logger.info "Found gene at index #{index}: value=#{value_str}, stable_id=#{stable_id_str}"
          break
        end
      end

      unless gene_index
        # Log more details for debugging
        Rails.logger.warn "Gene not found. Looking for: '#{stable_id.to_s}' (type: #{stable_id.class})"
        Rails.logger.warn "Sample values from vector: #{sample_values.inspect}"
        Rails.logger.warn "Checking if any value matches (with type conversion)..."
        stable_id_vector.first(10).each_with_index do |val, idx|
          Rails.logger.warn "  [#{idx}] value='#{val}' (#{val.class}) == '#{stable_id}' (#{stable_id.class})? #{val.to_s.strip == stable_id.to_s.strip}"
        end
        render json: { error: "Gene with stable_id #{stable_id} not found. Sample values in file: #{sample_values.first(5).join(', ')}" }, status: 404
        return
      end

      # Get expression data for this gene index
      # gene_index is 0-based from the stable_id_vector.each_with_index
      # get_pathway_data converts 1-based IDs to 0-based indexes, so pass gene_index + 1
      Rails.logger.info "Extracting expression data for gene_index: #{gene_index} (0-based), passing #{gene_index + 1} (1-based) to get_pathway_data"
      expression_data = H5DataService.get_pathway_data([gene_index + 1], loom_path.to_s, matrix_name)
      
      Rails.logger.info "Expression data response: nber_rows=#{expression_data['nber_rows']}, nber_cols=#{expression_data['nber_cols']}, values type=#{expression_data['values']&.class}, values length=#{expression_data['values']&.length}"
      
      # Extract the expression values
      # The response should have a 'values' array where each element is a row (gene)
      # For a single row request, values[0] should be the row (array of expression values)
      expression_values = []
      if expression_data && expression_data['values']
        if expression_data['values'].is_a?(Array) && expression_data['values'].length > 0
          # get_pathway_data returns values as an array of rows
          # Each row is an array of expression values for all cells
          first_row = expression_data['values'][0]
          if first_row.is_a?(Array)
            # This is the row we want - array of expression values
            expression_values = first_row
            Rails.logger.info "Extracted expression values: #{expression_values.length} cells"
          else
            Rails.logger.warn "Unexpected format: first row is not an array, type=#{first_row.class}"
          end
        else
          Rails.logger.warn "No values found in expression_data response"
        end
      else
        Rails.logger.warn "Invalid expression_data response: #{expression_data.inspect}"
      end

      render json: {
        stable_id: stable_id.to_s,
        gene_index: gene_index,
        expression_values: expression_values,
        nber_cols: expression_data ? expression_data['nber_cols'] : 0,
        matrix_name: matrix_name,
        annot_id: matrix_annot_id
      }
    rescue => e
      Rails.logger.error "Error loading gene expression: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: 'Failed to load gene expression', message: e.message }, status: 500
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_project
      identifier = params.expect(:id)
      
      # Try to find by numeric ID first (for backward compatibility)
      if identifier.match?(/^\d+$/)
        @project = Project.find_by(id: identifier.to_i)
      end
      
      # Try to find by key if not found
      if @project.nil?
        @project = Project.find_by(key: identifier)
      end
      
      # Try to find by public_id if still not found
      if @project.nil?
        # public_id might be numeric or in format like "ASAP49"
        if identifier.match?(/^ASAP\d+$/i)
          # Extract numeric part from "ASAP49" format
          numeric_part = identifier.match(/\d+$/).to_s.to_i
          @project = Project.find_by(public_id: numeric_part)
        else
          @project = Project.find_by(public_id: identifier.to_i) if identifier.match?(/^\d+$/)
        end
      end
      
      # Raise error if project not found
      unless @project
        raise ActiveRecord::RecordNotFound, "Project not found with identifier: #{identifier}"
      end
      
      @project_dir = Pathname.new(ENV["USER_DATA_DIR"]) + @project.user_id.to_s + @project.key
    end

    # Only allow a list of trusted parameters through.
    def project_params
      params.fetch(:project, {})
    end
    
    # Compress coordinate data to binary format for maximum efficiency
    def compress_coordinates_to_binary(coordinates)
      # coordinates is an array of arrays: [[x1, y1], [x2, y2], ...]
      # We'll round to 2 decimal places and store as 16-bit signed integers
      
      Rails.logger.info "Starting binary compression of #{coordinates.length} coordinate pairs"
      
      # Convert to integers (multiply by 100 for 2 decimal precision, allowing larger coordinate ranges)
      integer_coords = coordinates.map do |coord_pair|
        if coord_pair.is_a?(Array) && coord_pair.length >= 2
          x = (coord_pair[0].to_f * 100).round
          y = (coord_pair[1].to_f * 100).round
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
      # This gives us a range of -327.68 to 327.67 with 2 decimal precision
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
      when 'NUMERIC'
        compress_continuous_metadata_vector(raw_vector, metadata)
      when 'STRING'
        compress_discrete_metadata_vector(raw_vector, metadata)
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
            # Sort categories by count (largest to smallest) to match HTML legend ordering
            categories = parsed_categories.sort_by { |category, count| -count }.map(&:first)
          elsif parsed_categories.is_a?(Array)
            categories = parsed_categories.sort
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Failed to parse categories for #{metadata.display_name}: #{e.message}"
          return { data: nil, info: "Failed to parse categories" }
        end
      end
      
      # If no categories from JSON, extract them from raw data (for STRING metadata without categories_json)
      if categories.empty?
        Rails.logger.info "No categories_json found for #{metadata.display_name}, extracting from raw data"
        # Extract unique values from raw_vector
        unique_values = raw_vector.map { |v| v.is_a?(Array) ? v[0] : v }.uniq.compact.sort
        categories = unique_values
        Rails.logger.info "Extracted #{categories.length} unique categories from raw data for #{metadata.display_name}"
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
      
      # Handle edge case: only 1 category - no data needed, all cells are the same
      if num_categories <= 1
        Rails.logger.info "Only #{num_categories} unique category(ies) found - no data needed (all cells same category)"
        return { 
          data: nil, 
          info: {
            single_category: true,
            category_index: unique_indices.first || 0,
            length: indices.length,
            categories: categories,
            num_categories: num_categories
          }.to_json
        }
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
