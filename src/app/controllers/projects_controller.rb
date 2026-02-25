require 'open3'
require 'zlib'
require 'base64'

class ProjectsController < ApplicationController
  include ComplianceHelpers

  before_action :set_project, only: %i[ show edit update destroy clone metadata_coordinates metadata_vectors gene_expression get_file step_results refresh_steps_panel restart_step delete_all_runs_from_step queue_position get_attributes data_content run_status run_counts graph pipeline_runs instructions get_commands get_loom_files_json toggle_public cluster_comparison filter_de_results filter_ge_results search_gene search_gene_set_items prepare_metadata do_import_metadata sample_identifiers get_annot_info get_annot_evidences]

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
      page: params[:page] || 1,
      # User permission context for filtering
      current_user_id: current_user&.id,
      is_admin: admin?
    }
    
    # Use Elasticsearch for search
    search_results = Project.search(@query, @filters)
    
    # Extract projects from search results with preloaded associations
    @projects = search_results.records.includes(:project_steps, :project_type, :organism, :annots)
    
    # Get aggregations for filter dropdowns
    @aggregations = search_results.response['aggregations']
    
    # For filter dropdowns (fallback to database if no aggregations)
    @organisms = Organism.order(:name)
    @grouped_organisms = group_organisms(@organisms)
    @statuses = Status.order(:name)
    raw_technologies = @aggregations&.dig('technologies', 'buckets')&.map { |b| b['key'] } || Project.distinct.pluck(:technology).compact
    @technologies = raw_technologies.map { |v| [v.sub(/\A./) { |c| c.upcase }, v] }.sort_by { |label, _| label.downcase }

    raw_tissues = @aggregations&.dig('tissues', 'buckets')&.map { |b| b['key'] } || Project.distinct.pluck(:tissue).compact
    @tissues = raw_tissues.map { |v| [v.sub(/\A./) { |c| c.upcase }, v] }.sort_by { |label, _| label.downcase }
    
    # Pagination - extract total count from Elasticsearch response
    @total_count = search_results.response['hits']['total']['value']
    @current_page = (params[:page] || 1).to_i
    @per_page = 20
    
    # Store the current browse URL for "back to projects" links
    session[:projects_browse_url] = request.fullpath
    
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
    # Ensure project steps exist (safeguard for existing projects)
    @project.ensure_project_steps
    
    # Get available loom files and metadata for the project
    all_loom_files = Annot.available_loom_files(@project.id)
    available_metadata = Annot.available_metadata(@project.id)
    
    # Build project directory path for file existence checks
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    
    # Filter loom files to only include those that actually exist on disk
    existing_loom_files = all_loom_files.select do |filepath|
      full_path = @project_dir + filepath
      exists = File.exist?(full_path)
      Rails.logger.debug "[show] Checking loom file existence: #{full_path} -> #{exists}"
      exists
    end
    
    # Filter metadata to only include files that exist
    existing_metadata = available_metadata.select do |metadata|
      existing_loom_files.include?(metadata.filepath)
    end
    
    @h_metadata = organize_metadata(existing_metadata)

    # Filter loom files to only include those with 2D/3D visualizations (UMAP/tSNE with 2 or 3 rows)
    @available_loom_files = existing_loom_files.select do |filepath|
      @h_metadata[filepath] && 
      @h_metadata[filepath]['cell'] && 
      @h_metadata[filepath]['cell']['NUMERIC'] &&
      @h_metadata[filepath]['cell']['NUMERIC'].any? { |m| m.nber_rows && (m.nber_rows == 2) } # limit to 2D for now
    end
    
    # Get default loom file - use the first loom file with visualizations (only from existing files)
    Rails.logger.debug "[show] Existing loom files: #{existing_loom_files.inspect}"
    Rails.logger.debug "[show] Available loom files with visualizations: #{@available_loom_files.inspect}"
    @default_loom_file = @available_loom_files.first || existing_loom_files.first
    Rails.logger.debug "[show] Default loom file set to: #{@default_loom_file.inspect}"

    # Build embedding metadata (2D/3D coordinate sets) grouped by loom file
    @all_embeddings_by_loom = {}
    @available_loom_files.each do |filepath|
      numeric_metadata = @h_metadata.dig(filepath, 'cell', 'NUMERIC') || []
      @all_embeddings_by_loom[filepath] = numeric_metadata.select do |metadata|
        metadata.nber_rows.present? && (metadata.nber_rows == 2 || metadata.nber_rows == 3)
      end
    end
    
    # Check if a specific embedding_id was requested
    if params[:embedding_id].present?
      requested_embedding = Annot.find_by(id: params[:embedding_id], project_id: @project.id)
      if requested_embedding && requested_embedding.nber_rows.present? && (requested_embedding.nber_rows == 2 || requested_embedding.nber_rows == 3)
        @default_embedding = requested_embedding
        @default_embedding_loom_file = requested_embedding.filepath
        @default_loom_file = requested_embedding.filepath if requested_embedding.filepath.present?
      else
        @default_embedding = @all_embeddings_by_loom[@default_loom_file]&.first
        @default_embedding_loom_file = @default_embedding ? @default_loom_file : nil
      end
    else
      @default_embedding = @all_embeddings_by_loom[@default_loom_file]&.first
      @default_embedding_loom_file = @default_embedding ? @default_loom_file : nil
    end
    
    unless @default_embedding
      fallback_entry = @all_embeddings_by_loom.find { |_path, embeddings| embeddings.present? }
      if fallback_entry
        @default_embedding_loom_file = fallback_entry[0]
        @default_embedding = fallback_entry[1].first
      end
    end

    # Preload expression matrices (dim = 3) grouped by loom file
    @expression_matrices_by_loom = Annot.where(project_id: @project.id, dim: 3)
                                        .order(id: :asc)
                                        .group_by(&:filepath)
    
    # Precompute best CLA annotation metadata per categorical metadata category
    categorical_metadata = []
    @h_metadata.each_value do |dimension_hash|
      next unless dimension_hash
      discrete = dimension_hash.dig('cell', 'DISCRETE')
      categorical_metadata.concat(discrete) if discrete.present?
    end
    build_best_cla_category_map(categorical_metadata)
    
    # Check if we have visualization data (embeddings or categorical/numerical cell metadata)
    has_visualization_embeddings = @all_embeddings_by_loom.any? { |_filepath, embeddings| embeddings.present? }
    has_categorical_metadata = categorical_metadata.present?
    has_numerical_cell_metadata = @h_metadata.any? do |_filepath, dimension_hash|
      dimension_hash&.dig('cell', 'NUMERIC')&.present?
    end
    
    has_visualization_data = has_visualization_embeddings || has_categorical_metadata || has_numerical_cell_metadata
    
    # Set default view type: use visualization if we have visualization data, otherwise use summary
    @view_type = params[:view] || (has_visualization_data ? 'visualization' : 'summary')
    
    #@available_embeddings = default_loom_file ? @all_embeddings_by_loom[default_loom_file] : []

    # Steps logic for summary and analysis views
    if @view_type == 'summary' || @view_type == 'analysis'
      # Get project type for display
      @project_type = @project.project_type
      
      # Get runs for the project
      @runs = @project.runs.includes(:annots)
      
      # Build steps with status using shared method
      prepare_steps_with_status
      
      # Set selected step ID from URL parameter (for step selector on narrow screens)
      # This allows linking directly to a specific step from the run show page
      @selected_step_id = params[:step_id].present? ? params[:step_id].to_i : nil
      # Set selected run ID from URL parameter (to auto-load a specific run)
      @selected_run_id = params[:run_id].present? ? params[:run_id].to_i : nil
      
      # Determine if we should load the run panel
      # If a step-specific partial exists (like _parsing.html.erb), we don't load the run panel
      # because step_results will render the custom partial instead
      # This matches the behavior of clicking on a step in the left panel
      @load_run_panel = false
      @run_panel_html = nil
      if @selected_run_id.present?
        selected_run = Run.find_by(id: @selected_run_id)
        selected_step = selected_run&.step
        Rails.logger.info("[show] run_panel_logic: selected_run_id=#{@selected_run_id}, selected_run=#{selected_run&.id}, selected_step=#{selected_step&.name}")
        if selected_run && selected_step
          begin
            @run_panel_html = render_run_panel_to_string(selected_run, selected_step)
            @load_run_panel = true
            Rails.logger.info("[show] run_panel rendered server-side, html_length=#{@run_panel_html&.length}")
          rescue => e
            Rails.logger.error("[show] Error rendering run panel: #{e.class} - #{e.message}")
            Rails.logger.error(e.backtrace.first(10).join("\n"))
            @load_run_panel = false
            @run_panel_html = nil
          end
        end
      end

      @load_sub_view = false
      @sub_view_html = nil
      if params[:sub_view].present? && @selected_step_id.present?
        begin
          sub_view_step = Step.find_by(id: @selected_step_id)
          if sub_view_step
            saved_step = @step
            saved_runs = @runs
            saved_show_form = @show_form
            saved_show_custom_form = @show_custom_form
            saved_show_dashboard = @show_dashboard
            saved_show_view = @show_view
            saved_view_param = params[:view]

            @step = sub_view_step
            @runs = @project.runs.where(step_id: @selected_step_id).includes(:annots).order(created_at: :desc)
            @project_step = ProjectStep.find_or_create_by(project_id: @project.id, step_id: @selected_step_id)
            @show_form = false
            @show_custom_form = false
            @show_dashboard = false
            @show_view = false

            params[:view] = params[:sub_view]

            @sub_view_html = render_to_string(partial: 'projects/views/step_results', layout: false)
            @load_sub_view = true
            Rails.logger.info("[show] sub_view rendered: #{params[:sub_view]}, html_length=#{@sub_view_html&.length}")

            params[:view] = saved_view_param
            @step = saved_step
            @runs = saved_runs
            @show_form = saved_show_form
            @show_custom_form = saved_show_custom_form
            @show_dashboard = saved_show_dashboard
            @show_view = saved_show_view
          end
        rescue => e
          Rails.logger.error("[show] Error preparing sub_view: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.first(10).join("\n"))
          @load_sub_view = false
          @sub_view_html = nil
        end
      end

      if @load_sub_view && params[:gene_list_run_id].present? && params[:gene_list_type].present?
        begin
          gl_run = Run.find(params[:gene_list_run_id])
          gl_step = gl_run.step
          gl_std_method = gl_run.std_method
          params[:type] = params[:gene_list_type]
          params[:from] ||= 'de_results'

          @run = gl_run
          @step = gl_step
          @std_method = gl_std_method
          @fields = ["Gene index", "EnsemblID", "Gene name", "Alt names", "Description", "logFC", "P-value", "FDR", "Avg group1", "Avg group2"]
          @limit = 3000
          @h_std_method_attrs = { gl_std_method.id => Basic.get_std_method_attrs(gl_std_method, gl_step)[:h_attrs] }
          @h_run_attrs = gl_run.attrs_json ? JSON.parse(gl_run.attrs_json) : {}
          @data = []
          project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

          filename = project_dir + "de" + gl_run.id.to_s + "filtered.#{params[:type]}.json"
          list_filtered_rows = Basic.safe_parse_json(File.read(filename), [])
          @h_filtered_rows = {}
          list_filtered_rows.each { |e| @h_filtered_rows[e.to_i] = 1 }
          @nber_genes = list_filtered_rows.size

          filename = project_dir + "de" + gl_run.id.to_s + "output.txt"
          @tmp_data = File.readlines(filename)
          i = 0; j = 0
          if params[:type] == 'up'
            @tmp_data.reverse.each do |l|
              if @h_filtered_rows[@tmp_data.size - 1 - i]
                t = l.chomp.split("\t")
                t[2] = t[2].split(",").join(", ")
                @data.push t
                j += 1
              end
              i += 1
              break if j == @limit
            end
          else
            @tmp_data.each do |l|
              if @h_filtered_rows[i]
                t = l.chomp.split("\t")
                t[2] = t[2].split(",").join(", ")
                @data.push t
                j += 1
              end
              i += 1
              break if j == @limit
            end
          end

          @sub_view_html = render_to_string(partial: 'runs/get_de_gene_list', layout: false)
          Rails.logger.info("[show] gene_list sub_view rendered for run #{gl_run.id}, type=#{params[:type]}, genes=#{@nber_genes}")
        rescue => e
          Rails.logger.error("[show] Error preparing gene_list sub_view: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.first(10).join("\n"))
        end
      end

      if @load_sub_view && params[:geneset_list_run_id].present? && params[:geneset_list_type].present?
        begin
          gs_run = Run.find(params[:geneset_list_run_id])
          gs_step = gs_run.step
          gs_std_method = gs_run.std_method
          params[:type] = params[:geneset_list_type]
          params[:from] ||= 'ge_results'

          @run = gs_run
          @step = gs_step
          @std_method = gs_std_method
          @h_ge_filters = Basic.safe_parse_json(@project.ge_filter_json, {})
          @limit = 3000
          @data = []
          @h_run_attrs = gs_run.attrs_json ? JSON.parse(gs_run.attrs_json) : {}

          project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
          filename = project_dir + "ge" + gs_run.id.to_s + "output.json"
          h_output = Basic.safe_parse_json(File.read(filename), {})
          @fields = h_output["headers"]
          h_fields = {}
          @fields.each_index { |i| h_fields[@fields[i]] = i }

          if h_output[params[:type]]
            h_output[params[:type]].sort { |a, b| b[h_fields['effect size']].to_f <=> a[h_fields['effect size']].to_f }.each do |e|
              if e[h_fields['fdr']] <= @h_ge_filters['fdr_cutoff'].to_f
                @data.push e
              end
            end
          end
          @nber_genesets = @data.size

          @sub_view_html = render_to_string(partial: 'runs/get_ge_geneset_list', layout: false)
          Rails.logger.info("[show] geneset_list sub_view rendered for run #{gs_run.id}, type=#{params[:type]}, genesets=#{@nber_genesets}")
        rescue => e
          Rails.logger.error("[show] Error preparing geneset_list sub_view: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.first(10).join("\n"))
        end
      end
    end
    
    # Variables specific to data view
    if @view_type == 'data'
      # Get project type for display
      @project_type = @project.project_type
      
      # Get all annotations with step and run information for ordering
      all_annots = Annot.where(project_id: @project.id)
                        .where.not(filepath: nil)
                        .includes(:step, run: [:std_method])
                        .order(:name)
      
      # Get unique filepaths with their minimum step rank and run id for ordering
      # We use the minimum to get the earliest step/run that created each file
      filepath_info = {}
      all_annots.each do |annot|
        next unless annot.filepath.present?
        
        filepath = annot.filepath
        step_rank = annot.step&.rank
        run_id = annot.run_id
        
        if filepath_info[filepath]
          # Update with minimum step rank and run id
          # Priority: step_rank first, then run_id
          existing = filepath_info[filepath]
          existing_step_rank = existing[:step_rank] || 9999
          existing_run_id = existing[:run_id] || 999999
          
          current_step_rank = step_rank || 9999
          current_run_id = run_id || 999999
          
          # Compare: step_rank first, then run_id if step_rank is equal
          should_update = false
          if current_step_rank < existing_step_rank
            should_update = true
          elsif current_step_rank == existing_step_rank && current_run_id < existing_run_id
            should_update = true
          end
          
          if should_update
            existing[:step_rank] = step_rank
            existing[:run_id] = run_id
          end
        else
          # Initialize with this annotation's step rank and run id
          filepath_info[filepath] = {
            step_rank: step_rank,
            run_id: run_id
          }
        end
      end
      
      # Sort loom files by step rank (ascending) then by run id (ascending)
      # Use high numbers for nil values to push them to the end
      @available_loom_files = filepath_info.keys.sort_by do |filepath|
        info = filepath_info[filepath]
        [info[:step_rank] || 9999, info[:run_id] || 999999]
      end
      
      # Store filepath info for use in helper
      @filepath_info = filepath_info
      
      # Preload runs and steps for helper
      run_ids = filepath_info.values.map { |info| info[:run_id] }.compact.uniq
      @loom_file_runs = Run.where(id: run_ids).includes(:step, :std_method).index_by(&:id) if run_ids.any?
      @loom_file_runs ||= {}
      
      # Get selected loom file from params or use first available
      @selected_loom_file = params[:loom_file].presence || @available_loom_files.first
      
      # Group annotations by loom file and type
      @annots_by_loom_and_type = {}
      @matrix_dims_by_loom = {}
      @available_loom_files.each do |filepath|
        @annots_by_loom_and_type[filepath] = {
          matrices: [],
          col_attrs: [],
          row_attrs: [],
          global: []
        }
        
        file_annots = all_annots.select { |a| a.filepath == filepath }
        
        # Find the matrix annotation (name == '/matrix') to get dimensions for metadata
        matrix_annot = file_annots.find { |a| a.name == '/matrix' }
        if matrix_annot
          @matrix_dims_by_loom[filepath] = {
            nber_cols: matrix_annot.nber_cols,
            nber_rows: matrix_annot.nber_rows
          }
        end
        
        file_annots.each do |annot|
          annot_name = annot.name || ''
          if annot_name == '/matrix' || (annot.dim == 3 && annot_name.start_with?('/layers/'))
            @annots_by_loom_and_type[filepath][:matrices] << annot
          elsif annot_name.start_with?('/col_attrs/')
            @annots_by_loom_and_type[filepath][:col_attrs] << annot
          elsif annot_name.start_with?('/row_attrs/')
            @annots_by_loom_and_type[filepath][:row_attrs] << annot
          else
            @annots_by_loom_and_type[filepath][:global] << annot
          end
        end
      end
      
      # Get selected data type from params or default to matrices
      @selected_data_type = params[:data_type].presence || 'matrices'
    end
    
    # Variables specific to settings view
    if @view_type == 'settings'
      # Load shares for user rights management
      @shares = @project.shares.includes(:user).to_a
    end

    # Variables specific to compliance view
    if @view_type == 'compliance'
      if params[:validation_id].present?
        cv = ComplianceValidation.find_by(id: params[:validation_id], project_id: @project.id)
        @validation_result = cv&.result_data
        @viewing_historical = cv if @validation_result
      end
      @validation_result ||= load_validation_result(@project)

      # Load field group definitions for structured display
      co_id_to_tag = CellOntology.pluck(:id, :tag).to_h
      @compliance_field_groups = OntologyTermType.where.not(field_group_id: [nil, ''])
                                                  .order(:display_order)
                                                  .map { |ott| ott.to_field_group(co_id_to_tag) }

      # Load current metadata values (categories) for each field from Annot records.
      # Also load co-occurrence pairs for paired fields (term <-> label matching).
      @compliance_field_values = {}
      all_paths = @compliance_field_groups.flat_map { |fg| [fg[:term_path], fg[:label_path]].compact }
      paired_paths = @compliance_field_groups
                       .select { |fg| fg[:label_path].present? }
                       .map { |fg| [fg[:term_path], fg[:label_path]] }

      loom_path = find_project_loom_path(@project)
      if loom_path.present?
        raw = batch_read_field_values(loom_path, all_paths, paired_paths: paired_paths)
        raw.each { |k, v| @compliance_field_values[k] = v if v.present? }
      else
        annots_by_name = @project.annots.where(name: all_paths, latest_version: true).index_by(&:name)
        all_paths.each do |path|
          annot = annots_by_name[path]
          next unless annot
          if annot.list_cat_json.present?
            begin
              vals = JSON.parse(annot.list_cat_json)
              @compliance_field_values[path] = vals if vals.is_a?(Array) && vals.any?
            rescue JSON::ParserError; end
          elsif annot.categories_json.present?
            begin
              cats = JSON.parse(annot.categories_json)
              @compliance_field_values[path] = cats.keys if cats.is_a?(Hash) && cats.any?
            rescue JSON::ParserError; end
          end
        end
      end

      # Read per-value resolution from the validation result (computed during validation).
      # Fall back to on-the-fly resolution if no validation result is available.
      if @validation_result&.dig(:field_resolutions).present?
        @compliance_resolved = @validation_result[:field_resolutions].transform_keys(&:to_s)
        @compliance_resolved.each do |path, val_map|
          next unless val_map.is_a?(Hash)
          @compliance_resolved[path] = val_map.transform_keys(&:to_s)
        end
      else
        @compliance_resolved = resolve_field_values(@compliance_field_groups, @compliance_field_values)
      end
    end
    
    # Variables specific to summary view
    if @view_type == 'summary'
      # Get parsing status for display
      @parsing_status = 'complete'
      @parsing_step = Step.where(name: 'parsing').first
      if @parsing_step
        @parsing_project_step = ProjectStep.find_by(project_id: @project.id, step_id: @parsing_step.id)
        if @parsing_project_step
          @parsing_status = case @parsing_project_step.status_id
          when 1
            'waiting'
          when 2
            'running'
          when 3
            'complete'
          when 4
            'failed'
          else
            'complete'
          end
        end
      end
      
      # Get time to destroy for sandbox projects
      @time_to_destroy = nil
      if @project.sandbox? && !current_user
        @time_to_destroy = @project.updated_at + 2.days
      end
      
      # Get cloned project info if applicable
      @cloned_project = @project.cloned_project if @project.cloned_project_id
      
      # Get runs for the project (needed for filter_runs partial)
      @runs = @project.runs.includes(:annots) unless @runs
      
      # Get steps hash (needed for filter_runs partial)
      unless @h_steps
      @h_steps = {}
      Step.all.each do |step|
        @h_steps[step.id] = step
        end
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
      
      # Get all identifier types (needed for displaying other identifiers from identifiers_json)
      @h_identifier_types = {}
      IdentifierType.all.each { |it| @h_identifier_types[it.id] = it }
      
      # Get experimental entries grouped by identifier type
      @h_exp_entries = {}
      @project.exp_entries.includes(:identifier_type).each do |exp_entry|
        type_id = exp_entry.identifier_type_id
        @h_exp_entries[type_id] ||= []
        @h_exp_entries[type_id] << exp_entry
      end

      # Get articles hash for project DOI references (for Publications section)
      @h_articles = {}
      if @project.doi.present?
        dois = @project.doi.split(/\s*,\s*/).map(&:strip).reject(&:blank?)
        Article.where(doi: dois).each do |article|
          @h_articles[article.doi] = article
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
      session[:clust_comparison] ||= {}
      session[:clust_comparison][@project.id] ||= {}
      session[:clust_comparison][@project.id][:op] ||= "1"
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
      format.html # Use application layout
      format.json { render json: @project }
    end
  end

  # GET /projects/organisms_for_version
  def organisms_for_version
    version_id = params[:version_id].presence
    organisms = fetch_organisms_for_version(version_id)
    grouped_organisms = group_organisms(organisms)
    
    render json: {
      organisms: grouped_organisms.map do |domain, orgs|
        {
          domain: domain,
          count: orgs.count,
          organisms: orgs.map { |display_name, id, tax_id| { display_name: display_name, id: id, tax_id: tax_id } }
        }
      end
    }
  rescue StandardError => e
    Rails.logger.error("[ProjectsController] Error fetching organisms for version #{version_id}: #{e.class} - #{e.message}")
    Rails.logger.error("[ProjectsController] Backtrace: #{e.backtrace.first(5).join("\n")}")
    render json: { error: e.message }, status: :internal_server_error
  end

  # GET /projects/new
  def new
    @project = Project.new
    # Explicitly set organism_id to nil to override database default
    @project.organism_id = nil
    @project_types = ProjectType.order(:name)
    @versions = available_versions
    @file_formats = FileFormat.ordered
    # Set default version to the latest available version
    @project.version_id = @versions.first&.id if @versions.any?
    # Fetch organisms based on selected version (default to latest)
    @organisms = fetch_organisms_for_version(@project.version_id || @versions.first&.id)
    @grouped_organisms = group_organisms(@organisms)

    # Handle integration mode
    # Source keys can arrive via URL params (from reset_parsing redirect) or session
    # (from prepare_integrate). URL params take precedence because session cookies
    # are not always reliably set during Turbo Drive fetch-based redirects.
    @integrate_mode = params[:integrate] == '1'
    if @integrate_mode
      integrate_keys = if params[:source_keys].present?
                         params[:source_keys].split(',')
                       elsif session[:integrate_project_keys].present?
                         session[:integrate_project_keys]
                       end
      # Persist in session so a page refresh of the form still works
      session[:integrate_project_keys] = integrate_keys if integrate_keys.present?
      @integrate_projects = integrate_keys.present? ? Project.where(key: integrate_keys).includes(:organism).to_a : []
      if @integrate_projects.any?
        # Pre-fill organism from the integration projects
        @project.organism_id = @integrate_projects.first.organism_id
        # Pre-fill project type (single-cell transcriptomics by default)
        sc_type = @project_types.find { |pt| pt.name&.downcase&.include?('single') } || @project_types.first
        @project.project_type_id = sc_type&.id

        # Load categorical annotations for each integration project
        @integrate_annots = {}
        @integrate_projects.each do |p|
          # Get categorical cell-level metadata (dim=1 means cell-level, nber_cats > 0 means categorical)
          annots = Annot.where(project_id: p.id, dim: 1)
                        .where('nber_cats > 0')
                        .order(:name)
          @integrate_annots[p.id] = annots.to_a
        end
      end
    end
  end

  # GET /projects/1/edit
  def edit
    @organisms = Organism.order(:name)
    @project_types = ProjectType.order(:name)
    @versions = available_versions
    @file_formats = FileFormat.ordered
  end

  # POST /projects or /projects.json
  def create
    @project = Project.new(project_params)
    
    # Get file formats for parsing attributes handling
    @h_formats = {}
    FileFormat.all.map { |f| @h_formats[f.name] = f }
    
    # Delete project if already exists with this key (if editable)
    # Note: This allows reusing project keys for the same user
    if @project.key.present? && (existing_project = Project.find_by(key: @project.key))
      if editable?(existing_project)
        # Clear Fu records that reference this project to avoid foreign key constraint violations
        Fu.where(project_id: existing_project.id).update_all(project_id: nil)
        
        # Simple deletion - just destroy the project record
        # In production, you might want to also clean up files and related records
        existing_project.destroy
      end
    end
    
    # Handle parsing attributes from params
    tmp_attrs = params[:attrs] || {}
    tmp_attrs[:has_header] = 1 if tmp_attrs[:has_header]
    
    # Collect parsing attributes from params
    [:file_type, :sel_name, :nber_cols, :nber_rows, :delimiter, :gene_name_col, :has_header, :integrate_batch_paths, :integrate_n_pcs].each do |k|
      if params[k].present? && (!params[k].is_a?(String) || !params[k].strip.empty?)
        tmp_attrs[k] = params[k]
      end
    end
    
    # Set defaults for RAW_TEXT file types (matching original application behavior)
    # This matches the logic in /srv/asap2/app/controllers/fus_controller.rb lines 99-104
    detected_format = tmp_attrs[:file_type] || params[:file_type]
    if detected_format.blank? || ['ARCHIVE', 'ARCHIVE_COMPRESSED', 'COMPRESSED', 'RAW_TEXT'].include?(detected_format)
      tmp_attrs[:gene_name_col] ||= 'first' unless tmp_attrs[:gene_name_col].present?
      tmp_attrs[:delimiter] ||= '' unless tmp_attrs[:delimiter].present?
      tmp_attrs[:has_header] ||= '1' unless tmp_attrs[:has_header].present?
    end
    
    # Remove RAW_TEXT parsing options for non-text formats
    if tmp_attrs[:file_type] && @h_formats[tmp_attrs[:file_type]] && @h_formats[tmp_attrs[:file_type]].child_format != 'RAW_TEXT'
      [:delimiter, :gene_name_col, :has_header].each do |k|
        tmp_attrs.delete(k)
      end
    end
    
    # Set project attributes
    @project.parsing_attrs_json = tmp_attrs.to_json
    @project.nber_cols = params[:nber_cols] if params[:nber_cols]
    @project.nber_rows = params[:nber_rows] if params[:nber_rows]
    @project.user_id = current_user.id if user_signed_in?
    @project.user_id ||= 1
    @project.step_id ||= 1
    @project.status_id ||= 1
    @project.sandbox = current_user ? false : true
    @project.modified_at = Time.now
    
    # Generate unique project key if not provided
    unless @project.key.present?
      loop do
        @project.key = SecureRandom.alphanumeric(10).downcase
        break unless Project.exists?(key: @project.key)
      end
    end
    
    # Get version and docker image info
    @version = @project.version
    if @version
      @h_env = Basic.safe_parse_json(@version.env_json, {})
      if @h_env && @h_env['docker_images']
        @list_docker_image_names = @h_env['docker_images'].keys.map { |k| 
          @h_env['docker_images'][k]["name"] + ":" + @h_env['docker_images'][k]["tag"] 
        }
        tmp_text = "full_name in (" + @list_docker_image_names.map { |e| "'#{e}'" }.join(",") + ")"
        @docker_images = DockerImage.where(tmp_text).all
        asap_docker_name = ENV["ASAP_DOCKER_NAME"] || 'fabdavid/asap_run'
        @asap_docker_image = @docker_images.select { |e| e.name == asap_docker_name }.first
      end
    end
    
    # Get input file from session
    input_file = nil
    Rails.logger.info("[ProjectsController#create] ===== START FILE UPLOAD CHECK =====")
    Rails.logger.info("[ProjectsController#create] Checking session for file_upload: #{session[:file_upload].inspect}")
    Rails.logger.info("[ProjectsController#create] Project user_id: #{@project.user_id}, current_user.id: #{current_user&.id}")
    
    # Initialize input_file to nil
    input_file = nil
    
    # Check session conditions step by step
    # Rails sessions serialize hash keys as strings, so we need to use string keys
    has_session = session[:file_upload].present?
    Rails.logger.info("[ProjectsController#create] Session[:file_upload] exists: #{has_session}")
    
    if has_session
      # Try both symbol and string keys (Rails may serialize as strings)
      file_upload_hash = session[:file_upload]
      session_complete = file_upload_hash[:complete] || file_upload_hash['complete']
      session_fu_id = file_upload_hash[:fu_id] || file_upload_hash['fu_id']
      session_path = file_upload_hash[:path] || file_upload_hash['path']
      
      Rails.logger.info("[ProjectsController#create] Session[:file_upload][:complete]: #{file_upload_hash[:complete].inspect}")
      Rails.logger.info("[ProjectsController#create] Session[:file_upload]['complete']: #{file_upload_hash['complete'].inspect}")
      Rails.logger.info("[ProjectsController#create] session_complete (resolved): #{session_complete.inspect} (#{session_complete.class})")
      Rails.logger.info("[ProjectsController#create] Session[:file_upload][:fu_id]: #{file_upload_hash[:fu_id].inspect}")
      Rails.logger.info("[ProjectsController#create] Session[:file_upload]['fu_id']: #{file_upload_hash['fu_id'].inspect}")
      Rails.logger.info("[ProjectsController#create] session_fu_id (resolved): #{session_fu_id.inspect} (#{session_fu_id.class})")
      Rails.logger.info("[ProjectsController#create] session_path (resolved): #{session_path.inspect}")
      
      if session_fu_id
        fu_id = session_fu_id
        # Fu records are created with current_user.id, so use that to find the record
        search_user_id = current_user&.id
        Rails.logger.info("[ProjectsController#create] Looking for Fu with id: #{fu_id}, user_id: #{search_user_id}")
        
        # Try to find Fu record - first with user_id, then without
        input_file = if search_user_id
                       Fu.find_by(id: fu_id, user_id: search_user_id)
                     else
                       Fu.find_by(id: fu_id)
                     end
        Rails.logger.info("[ProjectsController#create] First Fu lookup result: #{input_file.inspect}")
        
        # If not found with user_id filter, try without it (in case user_id doesn't match)
        if input_file.nil? && search_user_id
          Rails.logger.warn("[ProjectsController#create] Fu not found with user_id filter, trying without user_id")
          input_file = Fu.find_by(id: fu_id)
          Rails.logger.info("[ProjectsController#create] Second Fu lookup (without user_id) result: #{input_file.inspect}")
        end
        
        Rails.logger.info("[ProjectsController#create] Final input_file after Fu lookup: #{input_file.inspect}")
        
        # If still not found, check if Fu record exists at all
        if input_file.nil?
          all_fus_with_id = Fu.where(id: fu_id)
          Rails.logger.error("[ProjectsController#create] Fu record not found! Searched for id: #{fu_id}, user_id: #{search_user_id}")
          Rails.logger.error("[ProjectsController#create] Total Fu records with this id: #{all_fus_with_id.count}")
          all_fus_with_id.each_with_index do |fu, idx|
            Rails.logger.error("[ProjectsController#create]   Fu[#{idx}]: id=#{fu.id}, user_id=#{fu.user_id}, upload_file_name=#{fu.upload_file_name}")
          end
        else
          Rails.logger.info("[ProjectsController#create] ✓ Successfully found Fu record: id=#{input_file.id}, user_id=#{input_file.user_id}, upload_file_name=#{input_file.upload_file_name}")
    end
      else
        Rails.logger.warn("[ProjectsController#create] Session check failed - fu_id: #{session_fu_id.inspect}")
      end
    else
      Rails.logger.warn("[ProjectsController#create] No session[:file_upload] found")
    end
    
    Rails.logger.info("[ProjectsController#create] ===== END FILE UPLOAD CHECK - input_file: #{input_file.inspect} =====")
    
    # Set default filters
    default_de_filter = {
      fc_cutoff: '2',
      fdr_cutoff: '0.05'
    }
    @project.de_filter_json = default_de_filter.to_json
    
    default_ge_filter = {
      fdr_cutoff: 0.05
    }
    @project.ge_filter_json = default_ge_filter.to_json

    Rails.logger.info("[ProjectsController#create] About to enter respond_to block, request format: #{request.format}")
    respond_to do |format|
      Rails.logger.info("[ProjectsController#create] ===== VALIDATION CHECK =====")
      Rails.logger.info("[ProjectsController#create] Inside respond_to block, format: #{format.inspect}")
      Rails.logger.info("[ProjectsController#create] input_file at validation: #{input_file.inspect}")
      Rails.logger.info("[ProjectsController#create] input_file.present?: #{input_file.present?}")
      Rails.logger.info("[ProjectsController#create] input_file.upload_file_name: #{input_file&.upload_file_name.inspect}")
      
      # Check if this is an integration request (no file upload needed)
      is_integrate = params[:integrate_batch_paths].present?
      
      # Require an input file for project creation (unless integrating)
      # Check if we have either a Fu record OR a valid session path
      # Rails sessions serialize hash keys as strings, so we need to use string keys
      has_input_file = input_file.present? && input_file.upload_file_name.present?
      file_upload_hash = session[:file_upload]
      session_path_check = file_upload_hash && (file_upload_hash[:path] || file_upload_hash['path'])
      has_session_path = session_path_check && File.exist?(session_path_check)
      
      Rails.logger.info("[ProjectsController#create] is_integrate: #{is_integrate}")
      Rails.logger.info("[ProjectsController#create] has_input_file: #{has_input_file}")
      Rails.logger.info("[ProjectsController#create] session[:file_upload][:path]: #{session_path_check.inspect}")
      Rails.logger.info("[ProjectsController#create] File.exist?(session_path): #{session_path_check && File.exist?(session_path_check)}")
      Rails.logger.info("[ProjectsController#create] has_session_path: #{has_session_path}")
      
      unless is_integrate || has_input_file || has_session_path
        Rails.logger.warn("[ProjectsController#create] ===== VALIDATION FAILED =====")
        Rails.logger.warn("[ProjectsController#create] Input file validation failed - input_file: #{input_file.inspect}, session_path exists: #{has_session_path}")
        @organisms = Organism.order(:name)
        @project_types = ProjectType.order(:name)
        @versions = available_versions
        @file_formats = FileFormat.ordered
        @grouped_organisms = group_organisms(fetch_organisms_for_version(@project.version_id))
        @project.errors.add(:base, "An input file is required to create a project. Please upload a file first.")
        format.html { 
          Rails.logger.info("[ProjectsController#create] Rendering :new template (HTML format)")
          render template: 'projects/new', status: :unprocessable_entity 
        return
        }
        format.turbo_stream { 
          Rails.logger.info("[ProjectsController#create] Rendering :new template (turbo_stream format)")
          render template: 'projects/new', status: :unprocessable_entity 
          return
        }
        format.json { 
          render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity 
          return
        }
      end
      
      Rails.logger.info("[ProjectsController#create] ===== BEFORE PROJECT SAVE =====")
      Rails.logger.info("[ProjectsController#create] Attempting to save project: #{@project.inspect}")
      Rails.logger.info("[ProjectsController#create] Request format: #{request.format}")
      Rails.logger.info("[ProjectsController#create] input_file at save check: #{input_file.inspect}")
      Rails.logger.info("[ProjectsController#create] input_file.present?: #{input_file.present?}")
      Rails.logger.info("[ProjectsController#create] input_file.upload_file_name: #{input_file&.upload_file_name.inspect}")
      
      if @project.save
        Rails.logger.info("[ProjectsController#create] ===== PROJECT SAVED SUCCESSFULLY =====")
        Rails.logger.info("[ProjectsController#create] Project saved successfully with ID: #{@project.id}, key: #{@project.key}")
        
        # === INTEGRATION PATH ===
        if is_integrate
          Rails.logger.info("[ProjectsController#create] ===== INTEGRATION MODE =====")
          
          # Create project directory
          user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
          project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
          FileUtils.mkdir_p(project_dir)
          
          # Initialize project steps
          init_project_steps()
          
          # Launch integration process
          @project.integrate()
          
          # Clean up session
          session.delete(:integrate_project_keys)
          
          format.html { redirect_to project_path(@project, view: 'analysis'), notice: "Integrated project was successfully created." }
          format.turbo_stream { redirect_to project_path(@project, view: 'analysis'), status: :see_other, notice: "Integrated project was successfully created." }
          format.json { render :show, status: :created, location: @project }
          next
        end
        
        # === NORMAL FILE UPLOAD PATH ===
        Rails.logger.info("[ProjectsController#create] input_file after save: #{input_file.inspect}")
        Rails.logger.info("[ProjectsController#create] input_file.present?: #{input_file.present?}")
        
        # Check session path
        # Rails sessions serialize hash keys as strings, so we need to use string keys
        file_upload_hash = session[:file_upload]
        session_path = file_upload_hash && (file_upload_hash[:path] || file_upload_hash['path'])
        session_path_exists = session_path && File.exist?(session_path)
        Rails.logger.info("[ProjectsController#create] session[:file_upload][:path]: #{file_upload_hash && file_upload_hash[:path].inspect}")
        Rails.logger.info("[ProjectsController#create] session[:file_upload]['path']: #{file_upload_hash && file_upload_hash['path'].inspect}")
        Rails.logger.info("[ProjectsController#create] session_path (resolved): #{session_path.inspect}")
        Rails.logger.info("[ProjectsController#create] Session path file exists: #{session_path_exists}")
        
        # Ensure we have either input_file or session path (validation already checked this)
        unless input_file.present? || session_path_exists
          Rails.logger.error("[ProjectsController#create] Neither input_file nor session path available after validation passed! This should not happen.")
          @project.errors.add(:base, "Internal error: input file not found")
          format.html { render template: 'projects/new', status: :unprocessable_entity }
          format.turbo_stream { render template: 'projects/new', status: :unprocessable_entity }
          format.json { render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity }
          return
        end
        
        # Create project directory
        user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
        project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
        FileUtils.mkdir_p(project_dir)
        
        # Get preparsing data from output.json
        upload_base_dir = ENV["UPLOAD_DATA_DIR"]
        
        # Use input_file.id if available, otherwise use session path
        Rails.logger.info("[ProjectsController#create] ===== DETERMINING UPLOAD PATH =====")
        Rails.logger.info("[ProjectsController#create] input_file: #{input_file.inspect}")
        Rails.logger.info("[ProjectsController#create] input_file && input_file.id: #{input_file && input_file.id}")
        
        if input_file && input_file.id
          upload_dir = Pathname.new(upload_base_dir) + input_file.id.to_s
        input_filename = input_file.upload_file_name
          Rails.logger.info("[ProjectsController#create] Using input_file path - upload_dir: #{upload_dir}, input_filename: #{input_filename}")
        else
          # Fallback: use session path directly if Fu record not found
          # Rails sessions serialize hash keys as strings, so we need to use string keys
          file_upload_hash = session[:file_upload]
          session_path_str = file_upload_hash && (file_upload_hash[:path] || file_upload_hash['path'])
          if session_path_str
            session_path = Pathname.new(session_path_str)
            upload_dir = session_path.dirname
            input_filename = session_path.basename.to_s
            Rails.logger.warn("[ProjectsController#create] Using session path fallback: #{upload_dir}/#{input_filename}")
          else
            Rails.logger.error("[ProjectsController#create] Cannot determine upload directory - input_file: #{input_file.inspect}, session: #{session[:file_upload].inspect}")
            @project.errors.add(:base, "Cannot locate uploaded file")
            format.html { render template: 'projects/new', status: :unprocessable_entity }
            format.turbo_stream { render template: 'projects/new', status: :unprocessable_entity }
            format.json { render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity }
            return
          end
        end
        
        # Get all valid extensions from FileFormat model
        valid_extensions = FileFormat.all.flat_map do |ff|
          if ff.ext.present?
            ff.ext.split(',').map(&:strip).reject(&:blank?)
          else
            []
          end
        end.compact.uniq.map(&:downcase)
        
        # Determine extension from the filename
        ext = input_filename.split(".").last.downcase
        unless valid_extensions.include?(ext)
          ext = 'txt'
        end
        
        @project.input_filename = input_filename
        @project.fu_id = input_file&.id  # Use safe navigation operator
        @project.extension = ext
        @project.save
        
        # Create symlink from upload directory to project directory
        upload_path = upload_dir + input_filename
        symlink_path = project_dir + ('input.' + ext)
        
        # Check if there's an uncompressed version of the file (for compressed files like .bz2, .gz)
        # Prefer uncompressed file if it exists, as Java parsing command may need it
        uncompressed_path = nil
        if input_filename.match(/\.(bz2|gz|zip)$/i)
          base_name = input_filename.sub(/\.(bz2|gz|zip)$/i, '')
          uncompressed_path = upload_dir + base_name
          if File.exist?(uncompressed_path)
            upload_path = uncompressed_path
            Rails.logger.info "Found uncompressed file, using #{uncompressed_path} instead of #{upload_dir + input_filename}"
          end
        end
        
        # Remove existing symlink if it exists
        File.delete(symlink_path) if File.exist?(symlink_path) || File.symlink?(symlink_path)
        
        # Create symlink
        if File.exist?(upload_path)
          File.symlink(upload_path, symlink_path)
          Rails.logger.info "Created symlink from #{upload_path} to #{symlink_path}"
        else
          Rails.logger.error "Upload file not found at #{upload_path}"
        end
        
        # Update Fu record with project info (if it exists)
        if input_file.present?
        input_file.update!(
          project_id: @project.id,
          project_key: @project.key,
          status: 'completed'
        )
        else
          file_upload_hash = session[:file_upload]
          session_path = file_upload_hash && (file_upload_hash[:path] || file_upload_hash['path'])
          Rails.logger.warn("[ProjectsController#create] Fu record not found, skipping update. Project created with session path: #{session_path}")
        end
        
        # ProjectStep records are initialized lazily when needed for display
        
        # Call parse_files if the method exists
        if @project.respond_to?(:parse_files)
          h_data = {}
          @project.parse_files(h_data)
        end
        
        # Clean up session
        session.delete(:file_upload)
        
        Rails.logger.info("[ProjectsController#create] About to redirect to project #{@project.id}")
        format.html { redirect_to project_path(@project, view: 'analysis'), notice: "Project was successfully created." }
        format.turbo_stream { 
          Rails.logger.info("[ProjectsController#create] Turbo stream format - redirecting to project #{@project.id}")
          redirect_to project_path(@project, view: 'analysis'), status: :see_other, notice: "Project was successfully created." 
        }
        format.json { render :show, status: :created, location: @project }
      else
        Rails.logger.error("[ProjectsController#create] Project save failed: #{@project.errors.full_messages.inspect}")
        @organisms = Organism.order(:name)
        @project_types = ProjectType.order(:name)
        @versions = available_versions
        @file_formats = FileFormat.ordered
        format.html { render :new, status: :unprocessable_entity }
        format.turbo_stream { render :new, status: :unprocessable_entity }
        format.json { render json: @project.errors, status: :unprocessable_entity }
      end
    end
  end

  # POST /projects/upload_file_chunk
  # PATCH/PUT /projects/1 or /projects/1.json
  def update
    # Check if we're resetting parsing
    is_resetting_parsing = session[:resetting_parsing] && session[:resetting_parsing_project_id] == @project.id
    
    if is_resetting_parsing
      # Handle parsing reset similar to create action
      # Get file formats for parsing attributes handling
      @h_formats = {}
      FileFormat.all.map { |f| @h_formats[f.name] = f }
      
      # Handle parsing attributes from params
      tmp_attrs = params[:attrs] || {}
      tmp_attrs[:has_header] = 1 if tmp_attrs[:has_header]
      
      # Collect parsing attributes from params
      [:file_type, :sel_name, :nber_cols, :nber_rows, :delimiter, :gene_name_col, :has_header].each do |k|
        if params[k].present? && (!params[k].is_a?(String) || !params[k].strip.empty?)
          tmp_attrs[k] = params[k]
        end
      end
      
      # Set defaults for RAW_TEXT file types
      detected_format = tmp_attrs[:file_type] || params[:file_type]
      if detected_format.blank? || ['ARCHIVE', 'ARCHIVE_COMPRESSED', 'COMPRESSED', 'RAW_TEXT'].include?(detected_format)
        tmp_attrs[:gene_name_col] ||= 'first' unless tmp_attrs[:gene_name_col].present?
        tmp_attrs[:delimiter] ||= '' unless tmp_attrs[:delimiter].present?
        tmp_attrs[:has_header] ||= '1' unless tmp_attrs[:has_header].present?
      end
      
      # Remove RAW_TEXT parsing options for non-text formats
      if tmp_attrs[:file_type] && @h_formats[tmp_attrs[:file_type]] && @h_formats[tmp_attrs[:file_type]].child_format != 'RAW_TEXT'
        [:delimiter, :gene_name_col, :has_header].each do |k|
          tmp_attrs.delete(k)
        end
      end
      
      # Update project attributes
      @project.assign_attributes(project_params)
      @project.parsing_attrs_json = tmp_attrs.to_json
      @project.nber_cols = params[:nber_cols] if params[:nber_cols]
      @project.nber_rows = params[:nber_rows] if params[:nber_rows]
      @project.step_id ||= 1
      @project.status_id ||= 1
      @project.modified_at = Time.now
      
      # Get input file from session
      input_file = nil
      if session[:file_upload].present?
        file_upload_hash = session[:file_upload]
        session_complete = file_upload_hash[:complete] || file_upload_hash['complete']
        session_fu_id = file_upload_hash[:fu_id] || file_upload_hash['fu_id']
        
        if session_complete && session_fu_id
          fu_id = session_fu_id
          search_user_id = current_user&.id
          input_file = if search_user_id
                         Fu.find_by(id: fu_id, user_id: search_user_id)
                       else
                         Fu.find_by(id: fu_id)
                       end
          
          if input_file.nil? && search_user_id
            input_file = Fu.find_by(id: fu_id)
          end
        end
      end
      
      # Update Fu record with project info (if it exists)
      if input_file.present?
        input_file.update!(
          project_id: @project.id,
          project_key: @project.key,
          status: 'completed'
        )
        @project.fu_id = input_file.id
      end
      
      # Reset parsing step status
      parsing_step = Step.where(name: 'parsing').first
      if parsing_step
        project_step = ProjectStep.find_by(project_id: @project.id, step_id: parsing_step.id)
        if project_step
          project_step.update!(status_id: 1) # Set to waiting
        else
          ProjectStep.create!(
            project_id: @project.id,
            step_id: parsing_step.id,
            status_id: 1
          )
        end
      end
      
      respond_to do |format|
        if @project.save
          # Call parse_files if the method exists
          if @project.respond_to?(:parse_files)
            h_data = {}
            @project.parse_files(h_data)
          end
          
          # Clean up session flags
          session.delete(:resetting_parsing)
          session.delete(:resetting_parsing_project_id)
          session.delete(:file_upload)
          
          format.html { redirect_to project_path(@project, view: 'analysis'), notice: "Project parsing was successfully reset." }
          format.json { render :show, status: :ok, location: @project }
        else
          @project_types = ProjectType.order(:name)
          @versions = available_versions
          @file_formats = FileFormat.ordered
          @organisms = fetch_organisms_for_version(@project.version_id)
          @grouped_organisms = group_organisms(@organisms)
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: @project.errors, status: :unprocessable_entity }
        end
      end
    else
      # Normal update
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
  end

  # DELETE /projects/1 or /projects/1.json
  def destroy
    @project.destroy!

    respond_to do |format|
      format.html { redirect_to projects_path, status: :see_other, notice: "Project was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  # POST /projects/bulk_destroy
  def bulk_destroy
    project_ids = params[:project_ids]

    unless project_ids.is_a?(Array) && project_ids.any?
      respond_to do |format|
        format.html { redirect_to projects_path, alert: "No projects selected." }
        format.json { render json: { success: false, error: "No projects selected." }, status: :unprocessable_entity }
      end
      return
    end

    project_ids = project_ids.map(&:to_i).compact
    projects = Project.where(id: project_ids)

    deleted_count = 0
    skipped_count = 0
    skipped_names = []

    projects.each do |project|
      if deletable?(project)
        project.destroy
        deleted_count += 1
      else
        skipped_count += 1
        skipped_names << project.display_name
      end
    end

    message = "#{deleted_count} project(s) deleted."
    if skipped_count > 0
      message += " #{skipped_count} project(s) skipped (no permission): #{skipped_names.join(', ')}."
    end

    respond_to do |format|
      format.html { redirect_to projects_path, notice: message }
      format.json { render json: { success: true, deleted: deleted_count, skipped: skipped_count, skipped_names: skipped_names, message: message } }
    end
  end

  # POST /projects/prepare_integrate
  # Validates selected projects and stores them in session for integration.
  # Only single-cell transcriptomics projects are eligible for integration.
  def prepare_integrate
    project_ids = params[:project_ids]
    selected_organism_id = params[:organism_id]

    unless project_ids.is_a?(Array) && project_ids.size >= 2
      render json: { success: false, error: "Please select at least 2 single-cell transcriptomics projects to integrate." }, status: :unprocessable_entity
      return
    end

    project_ids = project_ids.map(&:to_i).compact
    projects = Project.where(id: project_ids).includes(:organism, :project_type)

    sc_projects = projects.select(&:single_cell?)
    if sc_projects.size < 2
      render json: { success: false, error: "Integration requires at least 2 single-cell transcriptomics projects. Found #{sc_projects.size}." }, status: :unprocessable_entity
      return
    end

    groups = sc_projects.group_by(&:organism_id)

    # If a specific organism was selected (from the modal), filter to that group
    if selected_organism_id.present?
      organism_id = selected_organism_id.to_i
      group_projects = groups[organism_id]
      unless group_projects && group_projects.size >= 2
        render json: { success: false, error: "Not enough projects for the selected organism." }, status: :unprocessable_entity
        return
      end
      session[:integrate_project_keys] = group_projects.map(&:key).compact
      render json: { success: true, redirect_url: new_project_path(integrate: 1) }
      return
    end

    # Check if all single-cell projects share the same species
    if groups.size == 1
      session[:integrate_project_keys] = sc_projects.map(&:key).compact
      render json: { success: true, redirect_url: new_project_path(integrate: 1) }
    else
      # Multiple species: return groups so the JS can show a modal
      species_groups = groups.map do |organism_id, group_projects|
        organism = group_projects.first.organism
        {
          organism_id: organism_id,
          organism_name: organism&.display_name || 'Unknown',
          project_count: group_projects.size,
          projects: group_projects.map { |p| { id: p.id, name: p.display_name } }
        }
      end.select { |g| g[:project_count] >= 2 }
        .sort_by { |g| -g[:project_count] }

      if species_groups.empty?
        render json: { success: false, error: "No species has 2 or more selected projects. Integration requires at least 2 projects from the same species." }, status: :unprocessable_entity
      else
        render json: { success: false, species_selection_required: true, species_groups: species_groups }
      end
    end
  end

  # POST /projects/1/clone
  # Clones the project and redirects to the new project
  def clone
    unless clonable?(@project)
      respond_to do |format|
        format.html { redirect_to project_path(@project), alert: "You don't have permission to clone this project." }
        format.json { render json: { error: "Permission denied" }, status: :forbidden }
      end
      return
    end

    clone_service = ProjectCloneService.new(@project, user: current_user, session: session)
    new_project = clone_service.call

    if new_project
      respond_to do |format|
        format.html { redirect_to project_path(new_project), notice: "Project successfully cloned." }
        format.json { render json: { project_key: new_project.key, redirect_url: project_path(new_project) }, status: :created }
      end
    else
      error_message = clone_service.errors.first || "Failed to clone project"
      respond_to do |format|
        format.html { redirect_to project_path(@project), alert: error_message }
        format.json { render json: { error: error_message }, status: :unprocessable_entity }
      end
    end
  end

  # POST /projects/:id/toggle_public
  # Toggle the public status of a project
  # Requires compliance validation (as configured in Version env_json) to make public
  def toggle_public
    # Check permissions - only owner or admin can change public status
    unless @project.user_id == current_user&.id || admin?
      respond_to do |format|
        format.html { redirect_to project_path(@project), alert: "You don't have permission to change this project's public status." }
        format.json { render json: { success: false, error: "Permission denied" }, status: :forbidden }
      end
      return
    end

    # Determine the desired new state
    new_public_state = params[:public] == 'true' || params[:public] == true
    
    # If trying to make public, check compliance requirements
    if new_public_state && !@project.public?
      can_publish, reason = @project.can_be_public?
      unless can_publish
        respond_to do |format|
          format.html { redirect_to project_path(@project, view: 'summary'), alert: reason }
          format.json { render json: { success: false, error: reason, requires_validation: true }, status: :unprocessable_entity }
        end
        return
      end
    end

    # Update the public status
    if new_public_state && !@project.public?
      # Making public - set public_id if not already set
      if @project.public_id.nil?
        max_public_id = Project.maximum(:public_id) || 0
        @project.public_id = max_public_id + 1
      end
      @project.public = true
      @project.public_at = Time.current
    elsif !new_public_state && @project.public?
      # Making private
      @project.public = false
      # Keep public_id and public_at for record keeping
    end

    if @project.save
      status_text = @project.public? ? 'public' : 'private'
      respond_to do |format|
        format.html { redirect_to project_path(@project, view: 'summary'), notice: "Project is now #{status_text}." }
        format.json { render json: { success: true, public: @project.public?, public_id: @project.public_id, message: "Project is now #{status_text}." } }
      end
    else
      respond_to do |format|
        format.html { redirect_to project_path(@project, view: 'summary'), alert: "Failed to update project status." }
        format.json { render json: { success: false, error: @project.errors.full_messages.join(', ') }, status: :unprocessable_entity }
      end
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

      # Check if "users" is already in USER_DATA_DIR to avoid double "users"
      user_data_dir = ENV["USER_DATA_DIR"].to_s.chomp('/')
      base_dir = user_data_dir.end_with?("/users") || user_data_dir.end_with?("users") ? Pathname.new(user_data_dir) : Pathname.new(user_data_dir) + "users"
      project_dir = base_dir + @project.user_id.to_s + @project.key
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
        # File structure: USER_DATA_DIR/users/user_id/project_key/step/filename
        # Check if "users" is already in USER_DATA_DIR to avoid double "users"
        user_data_dir = ENV["USER_DATA_DIR"].to_s.chomp('/')
        base_dir = user_data_dir.end_with?("/users") || user_data_dir.end_with?("users") ? Pathname.new(user_data_dir) : Pathname.new(user_data_dir) + "users"
        tmp_dir = base_dir + @project.user_id.to_s + @project.key
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
            # Stream file through Rails (proxy approach)
            # This works when the proxy nginx doesn't have direct filesystem access
            # For large files: x_sendfile will use X-Sendfile header if nginx supports it
            # Otherwise Rails will stream the file chunked (which works but uses more memory)
            file_size = File.size(filepath)
            Rails.logger.info "get_file: Serving file #{filename}, size: #{file_size} bytes (#{(file_size / 1024.0 / 1024.0).round(2)} MB)"
            
            disposition = (!params[:display]) ? ("attachment; filename=" + [@project.key, step_name, run_id, filename].compact.join("_")) : 'inline'
            send_file filepath,
              type: 'application/octet-stream',
              disposition: disposition,
              x_sendfile: true  # Use X-Sendfile if nginx supports it (most efficient for large files)
  
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


  # POST /projects/1/cluster_comparison
  def cluster_comparison
    session[:clust_comparison] ||= {}
    session[:clust_comparison][@project.id] ||= {}
    session[:clust_comparison][@project.id][:op] ||= "1"

    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

    [:run_id1, :run_id2, :op].each { |e| session[:clust_comparison][@project.id][e] = params[e] }

    @res = []
    p = session[:clust_comparison][@project.id]
    @vals = []
    @h_runs = {}

    if p[:run_id1].present? && p[:run_id2].present? && p[:op].present?
      list_run_ids = [p[:run_id1], p[:run_id2]]
      Run.where(id: list_run_ids).each { |r| @h_runs[r.id.to_s] = r }
      annots = Annot.where(run_id: list_run_ids).to_a
      @h_annots = {}
      annots.each { |a| @h_annots[a.run_id.to_s] = a }

      @list_cats = []
      list_run_ids.each do |e|
        cats = Basic.safe_parse_json(@h_annots[e].list_cat_json, [])
        @list_cats.push(cats)
        loom_file = @project_dir + @h_annots[e].filepath
        cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata -loom #{loom_file} -meta \"#{@h_annots[e].name}\" -names"
        tmp_res = Basic.safe_parse_json(`#{cmd}`, {})
        h_vals = {}
        cats.each { |cat| h_vals[cat] = [] }
        if tmp_res['values'] && tmp_res['cells']
          tmp_res['values'].each_index do |i|
            h_vals[tmp_res['values'][i]]&.push(tmp_res['cells'][i])
          end
        end
        @vals.push(h_vals)
      end

      @list_cats[0].each_index do |i|
        @res[i] = []
        set1 = @vals[0][@list_cats[0][i]]
        next unless set1
        @list_cats[1].each_index do |j|
          set2 = @vals[1][@list_cats[1][j]]
          @res[i][j] = case p[:op]
                        when "1" then set1 - set2
                        when "2" then set2 - set1
                        else          set1 & set2
                        end
        end
      end
    end

    render partial: "cluster_comparison_results"
  end

  # POST /projects/1/filter_de_results
  def filter_de_results
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

    asap_docker_image = Basic.get_asap_docker(@project.version)
    de_step = Step.where(docker_image_id: asap_docker_image.id, name: 'de').first
    @step = de_step
    @runs = @project.runs.where(step_id: de_step.id).includes(:annots).order(created_at: :desc)
    annots = Annot.where(run_id: @runs.map(&:id)).to_a

    @h_de_filter = Basic.safe_parse_json(@project.de_filter_json, { 'fc_cutoff' => 2, 'fdr_cutoff' => 0.05 })

    if params[:filter].present?
      new_fc = params[:filter][:fc_cutoff].to_f
      new_fdr = params[:filter][:fdr_cutoff].to_f
      @project.update_attribute(:de_filter_json, { fc_cutoff: new_fc, fdr_cutoff: new_fdr }.to_json)
      @h_de_filter = { 'fc_cutoff' => new_fc, 'fdr_cutoff' => new_fdr }
    end

    @h_stats = run_de_filter(annots, @h_de_filter)

    @h_std_methods = {}
    StdMethod.where(docker_image_id: asap_docker_image.id).each { |s| @h_std_methods[s.id] = s }

    render partial: 'projects/views/de_results_table', layout: false
  end

  # POST /projects/1/filter_ge_results
  def filter_ge_results
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

    asap_docker_image = Basic.get_asap_docker(@project.version)
    ge_step = Step.where(docker_image_id: asap_docker_image.id, name: 'ge').first
    @step = ge_step
    @runs = @project.runs.where(step_id: ge_step.id).includes(:annots).order(created_at: :desc)

    @h_ge_filter = Basic.safe_parse_json(@project.ge_filter_json, { 'fdr_cutoff' => 0.05 })

    if params[:filter].present?
      new_fdr = params[:filter][:fdr_cutoff].to_f
      @project.update_attribute(:ge_filter_json, { fdr_cutoff: new_fdr }.to_json)
      @h_ge_filter = { 'fdr_cutoff' => new_fdr }
    end

    fdr_cutoff = @h_ge_filter['fdr_cutoff'].to_f
    @h_stats = {}
    completed_runs = @runs.select { |r| r.status_id == 3 }
    completed_runs.each do |run|
      output_file = @project_dir + 'ge' + run.id.to_s + 'output.json'
      next unless File.exist?(output_file)
      h_output = Basic.safe_parse_json(File.read(output_file), {})
      headers = h_output['headers'] || []
      h_fields = {}
      headers.each_index { |i| h_fields[headers[i]] = i }
      fdr_idx = h_fields['fdr']
      next unless fdr_idx
      up_count = 0
      down_count = 0
      (h_output['up'] || []).each { |e| up_count += 1 if e[fdr_idx].to_f <= fdr_cutoff }
      (h_output['down'] || []).each { |e| down_count += 1 if e[fdr_idx].to_f <= fdr_cutoff }
      @h_stats[run.id.to_s] = { 'up' => up_count, 'down' => down_count }
    end

    @h_std_methods = {}
    StdMethod.where(docker_image_id: asap_docker_image.id).each { |s| @h_std_methods[s.id] = s }

    render partial: 'projects/views/ge_results_table', layout: false
  end

  # GET /projects/1/search_gene
  def search_gene
    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = "asap2_data_v#{h_env['asap_data_db_version']}"

    @gene = nil
    if params[:ensembl_id].present?
      @gene = RemoteGene.find_by_ensembl_id(params[:ensembl_id], version: db_version)
    end

    render partial: 'projects/views/gene_details', layout: false
  end

  # GET /projects/1/search_gene_set_items
  def search_gene_set_items
    require 'ostruct'
    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = "asap2_data_v#{h_env['asap_data_db_version']}"

    @gsi = nil
    @genes = []
    @h_all_genes = {}
    @h_enriched_genes = {}

    ge_run = Run.find_by(id: params[:ge_run_id])
    h_ge_run_attrs = ge_run ? Basic.safe_parse_json(ge_run.attrs_json, {}) : {}
    gene_set_id = params[:gene_set_id] || h_ge_run_attrs['gene_set_id']

    if gene_set_id.present? && params[:identifier].present?
      RemoteGene.with_remote(db_version) do
        conn = RemoteGene.connection
        gsi_rows = conn.select_all(
          "SELECT * FROM gene_set_items WHERE gene_set_id = #{gene_set_id.to_i} AND identifier = #{conn.quote(params[:identifier])}"
        )
        if gsi_rows.any?
          @gsi = OpenStruct.new(gsi_rows.first)
          if @gsi.content.present?
            gene_rows = conn.select_all(
              "SELECT * FROM genes WHERE id IN (#{@gsi.content})"
            )
            @genes = gene_rows.map { |r| OpenStruct.new(r) }
          end
        end
      end
    end

    if ge_run && params[:type].present?
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

      input_de = h_ge_run_attrs['input_de']
      if input_de && input_de['run_id']
        de_output_file = project_dir + 'de' + input_de['run_id'].to_s + 'output.txt'
        h_stable_ids = {}
        if File.exist?(de_output_file)
          File.readlines(de_output_file).each do |line|
            cols = line.strip.split("\t")
            if cols[1]
              @h_all_genes[cols[1]] = 1
              h_stable_ids[cols[0]] = cols[1] if cols[0]
            end
          end
        end

        filtered_filename = "#{ge_run.user_id}_#{input_de['run_id']}_#{h_ge_run_attrs['fc_cutoff']}_#{h_ge_run_attrs['fdr_cutoff']}_filtered_ids.json"
        filtered_file = project_dir + 'tmp' + filtered_filename
        if File.exist?(filtered_file)
          h_filtered = Basic.safe_parse_json(File.read(filtered_file), {})
          (h_filtered[params[:type]] || []).each do |gid|
            ensembl_id = h_stable_ids[gid.to_s]
            @h_enriched_genes[ensembl_id] = 1 if ensembl_id
          end
        end
      end
    end

    render partial: 'projects/views/gene_set_item_details', layout: false
  end

  # GET /projects/1/data_content
  # Returns just the right panel content for AJAX loading
  def data_content
    # Set view type to data
    @view_type = 'data'
    
    # Get project type for display
    @project_type = @project.project_type
    
    # Get all annotations with step and run information for ordering
    all_annots = Annot.where(project_id: @project.id)
                      .where.not(filepath: nil)
                      .includes(:step, run: [:std_method])
                      .order(:name)
    
    # Get unique filepaths with their minimum step rank and run id for ordering
    filepath_info = {}
    all_annots.each do |annot|
      next unless annot.filepath.present?
      
      filepath = annot.filepath
      step_rank = annot.step&.rank
      run_id = annot.run_id
      
      if filepath_info[filepath]
        existing = filepath_info[filepath]
        existing_step_rank = existing[:step_rank] || 9999
        existing_run_id = existing[:run_id] || 999999
        
        current_step_rank = step_rank || 9999
        current_run_id = run_id || 999999
        
        should_update = false
        if current_step_rank < existing_step_rank
          should_update = true
        elsif current_step_rank == existing_step_rank && current_run_id < existing_run_id
          should_update = true
        end
        
        if should_update
          existing[:step_rank] = step_rank
          existing[:run_id] = run_id
        end
      else
        filepath_info[filepath] = {
          step_rank: step_rank,
          run_id: run_id
        }
      end
    end
    
    # Get selected loom file from params
    @selected_loom_file = params[:loom_file].presence
    
    # Get selected data type from params or default to matrices
    @selected_data_type = params[:data_type].presence || 'matrices'
    
    # Get available loom files list for empty state check
    @available_loom_files = filepath_info.keys.sort_by do |filepath|
      info = filepath_info[filepath]
      [info[:step_rank] || 9999, info[:run_id] || 999999]
    end
    
    # Group annotations by loom file and type
    @annots_by_loom_and_type = {}
    @matrix_dims_by_loom = {}
    
    if @selected_loom_file
      @annots_by_loom_and_type[@selected_loom_file] = {
        matrices: [],
        col_attrs: [],
        row_attrs: [],
        global: []
      }
      
      file_annots = all_annots.select { |a| a.filepath == @selected_loom_file }
      
      # Find the matrix annotation (name == '/matrix') to get dimensions for metadata
      matrix_annot = file_annots.find { |a| a.name == '/matrix' }
      if matrix_annot
        @matrix_dims_by_loom[@selected_loom_file] = {
          nber_cols: matrix_annot.nber_cols,
          nber_rows: matrix_annot.nber_rows
        }
      end
      
      file_annots.each do |annot|
        annot_name = annot.name || ''
        if annot_name == '/matrix' || (annot.dim == 3 && annot_name.start_with?('/layers/'))
          @annots_by_loom_and_type[@selected_loom_file][:matrices] << annot
        elsif annot_name.start_with?('/col_attrs/')
          @annots_by_loom_and_type[@selected_loom_file][:col_attrs] << annot
        elsif annot_name.start_with?('/row_attrs/')
          @annots_by_loom_and_type[@selected_loom_file][:row_attrs] << annot
        else
          @annots_by_loom_and_type[@selected_loom_file][:global] << annot
        end
      end
    end
    
    # Store filepath info for use in helper
    @filepath_info = filepath_info
    
    # Preload runs and steps for helper
    run_ids = filepath_info.values.map { |info| info[:run_id] }.compact.uniq
    @loom_file_runs = Run.where(id: run_ids).includes(:step, :std_method).index_by(&:id) if run_ids.any?
    @loom_file_runs ||= {}
    
    respond_to do |format|
      format.html { render partial: 'projects/views/data_content', layout: false }
    end
  end

  # POST /projects/1/prepare_metadata
  def prepare_metadata
    delimiters = ["\n", "\t", " ", ";", ","]

    upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                        ENV["UPLOAD_DATA_DIR"]
                      elsif ENV["DATA_DIR"]
                        Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                      else
                        '/data/asap2/fus'
                      end

    h_fu = {
      project_id: @project.id,
      project_key: @project.key,
      status: 'new',
      upload_type: 2,
      upload_file_name: 'clipboard.txt',
      upload_content_type: 'text/plain',
      user_id: current_user&.id || 1
    }

    fu = Fu.new(h_fu)
    fu.save!

    fu_dir = Pathname.new(upload_base_dir) + fu.id.to_s
    FileUtils.mkdir_p(fu_dir)
    filepath = fu_dir + 'clipboard.txt'

    duplicates = []
    h_identifiers = {}
    final_content = []

    if params[:file].present?
      raw_content = params[:file].read
    else
      raw_content = params[:content] || ''
    end

    input_type_id = params[:input_type_id].to_s
    metadata_type_id = params[:metadata_type_id].to_s
    delimiter_idx = (params[:delimiter] || '0').to_i
    name = params[:name] || ''
    has_header = params[:has_header].to_s != '0'

    header_name = nil

    if metadata_type_id == '4'
      raw_content.split(/\n/).each do |line|
        line = line.strip
        next if line.empty?
        final_content.push(line)
      end
    elsif input_type_id == '2'
      lines = raw_content.split(/\n/)
      lines.each_with_index do |line, idx|
        if idx == 0 && has_header
          final_content.push(line)
          next
        end
        parts = line.split(/\t/)
        identifier = parts[0]
        if identifier && !h_identifiers[identifier]
          h_identifiers[identifier] = 1
          final_content.push(line)
        elsif identifier
          duplicates.push(identifier)
        end
      end
    elsif input_type_id == '1'
      delimiter = delimiters[delimiter_idx] || "\n"
      entries = raw_content.split(/#{Regexp.escape(delimiter)}+/).map(&:strip).reject(&:empty?)

      if has_header && entries.any?
        header_name = entries.shift
        header_prefix = metadata_type_id == '2' ? 'genes' : 'cells'
        final_content.push("#{header_prefix}\t#{header_name}")
      end

      entries.each do |e|
        if !h_identifiers[e]
          h_identifiers[e] = 1
          final_content.push("#{e}\t1")
        else
          duplicates.push(e)
        end
      end
    end

    File.open(filepath, 'w') { |f| f.write(final_content.join("\n")) }

    if File.exist?(filepath) && File.size(filepath) > 0
      fu.update(
        status: 'written',
        upload_file_size: File.size(filepath),
        upload_updated_at: Time.now
      )
    end

    preview_lines = final_content.first(20)

    response = {
      fu_id: fu.id,
      duplicates: duplicates,
      preview_lines: preview_lines,
      total_lines: final_content.size
    }
    response[:header_name] = header_name if header_name.present?

    render json: response
  end

  # POST /projects/1/do_import_metadata
  def do_import_metadata
    fu_id = params[:fu_id]
    metadata_type_id = params[:metadata_type_id].to_s
    loom_file = params[:loom_file]

    unless fu_id
      render json: { status: 'error', message: 'No file upload ID provided' }, status: :unprocessable_entity
      return
    end

    fu = Fu.find_by(id: fu_id)
    unless fu
      render json: { status: 'error', message: 'File upload not found' }, status: :not_found
      return
    end

    asap_docker_image = Basic.get_asap_docker(@project.version)
    import_metadata_step = Step.where(docker_image_id: asap_docker_image.id, name: 'import_metadata').first

    unless import_metadata_step
      render json: { status: 'error', message: 'Import metadata step not found' }, status: :unprocessable_entity
      return
    end

    std_method = StdMethod.where(docker_image_id: asap_docker_image.id, name: 'add_meta').first

    last_run = Run.joins(:step)
                  .where(project_id: @project.id, steps: { name: 'import_metadata' })
                  .order(num: :asc).last

    h_run = {
      project_id: @project.id,
      step_id: import_metadata_step.id,
      std_method_id: std_method&.id,
      status_id: 1,
      num: last_run ? last_run.num + 1 : 1,
      user_id: current_user&.id || 1,
      command_json: '{}',
      attrs_json: '{}',
      output_json: '{}',
      lineage_run_ids: '',
      submitted_at: Time.now
    }

    new_run = Run.new(h_run)
    new_run.save!

    input_run_ids = Run.joins(:step)
                       .where(project_id: @project.id, steps: { name: ['parsing', 'cell_filtering', 'gene_filtering'] })
                       .pluck(:id).join(',')

    h_attrs = {
      input_run_ids: input_run_ids,
      ori_filename: fu.upload_file_name,
      input_filename: fu.upload_file_name,
      metadata_type_id: metadata_type_id,
      fu_id: fu_id,
      loom_file: loom_file
    }

    h_command = {
      program: "rake parse_metadata[#{new_run.id}]",
      host_name: 'localhost',
      opts: [],
      args: []
    }

    new_run.update(
      command_json: h_command.to_json,
      attrs_json: h_attrs.to_json
    )

    render json: { status: 'ok', run_id: new_run.id }
  end

  # GET /projects/1/sample_identifiers?loom_file=...
  def sample_identifiers
    loom_file = params[:loom_file]
    result = { cells: [], genes: [] }

    if loom_file.present?
      user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
      project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
      loom_path = project_dir + loom_file

      if File.exist?(loom_path)
        [
          { key: :cells, meta: '/col_attrs/CellID' },
          { key: :genes, meta: '/row_attrs/Gene' }
        ].each do |entry|
          begin
            values = H5DataService.get_metadata_vector(loom_path.to_s, entry[:meta])
            result[entry[:key]] = values.first(10).map(&:to_s) if values.is_a?(Array)
          rescue => e
            Rails.logger.warn("sample_identifiers: could not extract #{entry[:meta]}: #{e.message}")
          end
        end
      end
    end

    render json: result
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

  # GET /projects/1/graph
  def graph
    # Get only successful (completed) runs for the project with step and std_method information
    # status_id == 3 means completed/successful
    @runs = @project.runs.includes(:step, :std_method, :annots)
                      .where(status_id: 3)
                      .order(:step_id, :num, :id)
    
    # Get steps hash
    asap_docker_image = Basic.get_asap_docker(@project.version)
    @h_steps = {}
    if asap_docker_image
      Step.where(docker_image_id: asap_docker_image.id).each do |step|
        @h_steps[step.id] = step
      end
    end
    
    # Generate klay data for pipeline visualization (runs only)
    @klay_data = generate_klay_data
    
    render partial: 'projects/views/graph', layout: false
  end

  # GET /projects/1/get_lineage
  def get_lineage
    # Placeholder for get_lineage action
    render plain: "Lineage for project #{@project.key}"
  end

  # GET /projects/1/get_annot_info?annot_id=123&cat_idx=0&cat_name=foo
  def get_annot_info
    annot_id = params[:annot_id].to_i
    cat_idx = params[:cat_idx].to_i
    cat_name = params[:cat_name]

    annot = Annot.find_by(id: annot_id)
    return render(json: { error: "Annotation not found" }, status: :not_found) unless annot

    annot_cell_set = AnnotCellSet.where(annot_id: annot.id, cat_idx: cat_idx).first
    clas_list = []
    if annot_cell_set&.cell_set_id
      clas_list = Cla.active.where(cell_set_id: annot_cell_set.cell_set_id)
                     .order(Arel.sql("(nber_agree - nber_disagree) DESC, created_at DESC"))
                     .to_a
    end

    cla_data = clas_list.map do |cla|
      {
        id: cla.id,
        num: cla.num,
        name: cla.name,
        cell_ontology_term_ids: cla.cell_ontology_term_ids,
        sorted_cell_ontology_term_ids: cla.sorted_cell_ontology_term_ids,
        up_gene_ids: cla.up_gene_ids,
        sorted_up_gene_ids: cla.sorted_up_gene_ids,
        down_gene_ids: cla.down_gene_ids,
        sorted_down_gene_ids: cla.sorted_down_gene_ids,
        comment: cla.comment,
        nber_agree: cla.nber_agree || 0,
        nber_disagree: cla.nber_disagree || 0,
        score: cla.score,
        created_at: cla.created_at&.strftime("%Y-%m-%d %H:%M"),
        obsolete: cla.obsolete
      }
    end

    render json: {
      annot_id: annot.id,
      cat_idx: cat_idx,
      cat_name: cat_name,
      clas: cla_data
    }
  end

  # GET /projects/1/get_annot_evidences?annot_id=123&cat_idx=0
  def get_annot_evidences
    annot_id = params[:annot_id].to_i
    cat_idx = params[:cat_idx].to_i

    annot = Annot.find_by(id: annot_id, project_id: @project.id)
    return render(json: { error: 'Annotation not found' }, status: :not_found) unless annot

    unless marker_compatible_metadata?(annot)
      return render json: {
        state: 'unsupported',
        message: 'FindMarkers evidences are available only for categorical metadata (for example clustering or selections).',
        rows_up: [],
        rows_down: []
      }
    end

    run_data = find_or_start_marker_run_for_annot(annot)
    marker_run = run_data[:run]
    return render(json: { state: 'error', message: run_data[:error] || 'Unable to initialize FindMarkers run.', rows_up: [], rows_down: [] }) unless marker_run

    status_id = marker_run.status_id.to_i
    status_name = marker_run.status&.name.to_s

    if status_id == 1
      msg = if marker_run.slurm_job_id.present?
              'FindMarkers is queued for execution.'
            elsif run_data[:submitted]
              'FindMarkers was queued. Waiting for scheduler assignment.'
            else
              'FindMarkers is pending scheduling.'
            end
      return render json: {
        state: 'queued',
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        message: msg,
        rows_up: [],
        rows_down: []
      }
    end

    if [2, 6].include?(status_id)
      msg = run_data[:started] ? 'FindMarkers started for this category. Results will appear when the run is complete.' : 'FindMarkers is running for this category.'
      return render json: {
        state: 'running',
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        message: msg,
        rows_up: [],
        rows_down: []
      }
    end

    if status_id == 4
      return render json: {
        state: 'failed',
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        message: 'FindMarkers failed for this category. Retry once the run issue is resolved.',
        rows_up: [],
        rows_down: []
      }
    end

    unless status_id == 3
      return render json: {
        state: 'running',
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        message: 'FindMarkers status is being updated. Please refresh in a few seconds.',
        rows_up: [],
        rows_down: []
      }
    end

    parsed = parse_marker_rows_for_category(marker_run, cat_idx)
    if parsed[:error]
      return render json: {
        state: 'failed',
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        message: parsed[:error],
        rows_up: [],
        rows_down: []
      }
    end

    render json: {
      state: 'completed',
      run_id: marker_run.id,
      status_id: status_id,
      status_name: status_name,
      message: "FindMarkers evidences loaded for category #{cat_idx + 1}.",
      rows_up: parsed[:rows_up],
      rows_down: parsed[:rows_down]
    }
  end

  # GET /projects/1/pipeline_runs?annot_id=123 or ?run_id=456
  def pipeline_runs
    annot_id = params[:annot_id]
    run_id = params[:run_id]
    
    unless annot_id.present? || run_id.present?
      render json: { error: 'annot_id or run_id parameter is required' }, status: :bad_request
      return
    end
    
    ori_run_id = nil
    
    if annot_id.present?
      # Get the annotation
      annot = Annot.find_by(id: annot_id, project_id: @project.id)
      unless annot
        render json: { error: 'Annotation not found' }, status: :not_found
        return
      end
      
      # Get the original run that created this annotation
      ori_run_id = annot.ori_run_id || annot.run_id
    else
      # Use run_id directly
      run = Run.find_by(id: run_id, project_id: @project.id)
      unless run
        render json: { error: 'Run not found' }, status: :not_found
        return
      end
      ori_run_id = run.id
    end
    
    unless ori_run_id
      render json: { error: 'No run found' }, status: :not_found
      return
    end
    
    # Get all runs in the pipeline starting from ori_run_id
    pipeline_run_ids = get_pipeline_run_ids(ori_run_id)
    
    # Get all runs with their steps and std_methods
    # Order by ID descending (most recent first, oldest last) for proper lineage display
    runs = Run.where(id: pipeline_run_ids, project_id: @project.id)
              .includes(:step, :std_method, :status)
              .order(id: :desc)
              .to_a
    
    # Get steps hash for display
    asap_docker_image = Basic.get_asap_docker(@project.version)
    @h_steps = {}
    if asap_docker_image
      Step.where(docker_image_id: asap_docker_image.id).each { |s| @h_steps[s.id] = s }
    end
    
    # Prepare data for the partial (similar to std_step)
    @runs = runs
    
    # Identify the immediate parent run (the one that created the annotation)
    @immediate_parent_run_id = ori_run_id
    
    # Get std_methods for runs
    std_method_ids = runs.map(&:std_method_id).compact.uniq
    @h_std_methods = {}
    StdMethod.where(id: std_method_ids).each { |m| @h_std_methods[m.id] = m } if std_method_ids.any?
    
    # Pre-load annots and their associated runs/steps for dataset parameters
    @h_annots_for_params = {}
    @h_ori_runs_for_params = {}
    @h_steps_for_params = {}
    annot_ids = []
    direct_run_ids = []
    runs.each do |run|
      h_attrs = run.attrs_json.present? ? Basic.safe_parse_json(run.attrs_json, {}) : {}
      h_attrs.each_value do |v|
        if v.is_a?(Hash)
          if v['annot_id'].present? || v[:annot_id].present?
            annot_ids << (v['annot_id'] || v[:annot_id])
          elsif v['run_id'].present? || v[:run_id].present?
            direct_run_ids << (v['run_id'] || v[:run_id])
          end
        elsif v.is_a?(Array)
          v.each do |item|
            if item.is_a?(Hash)
              if item['annot_id'].present? || item[:annot_id].present?
                annot_ids << (item['annot_id'] || item[:annot_id])
              elsif item['run_id'].present? || item[:run_id].present?
                direct_run_ids << (item['run_id'] || item[:run_id])
              end
            end
          end
        end
      end
    end
    if annot_ids.any?
      Annot.where(id: annot_ids.uniq).each do |annot|
        @h_annots_for_params[annot.id] = annot
        if annot.ori_run_id.present? && !@h_ori_runs_for_params[annot.ori_run_id]
          ori_run = Run.find_by(id: annot.ori_run_id)
          if ori_run
            @h_ori_runs_for_params[annot.ori_run_id] = ori_run
            if ori_run.step_id.present? && !@h_steps_for_params[ori_run.step_id]
              step = Step.find_by(id: ori_run.step_id)
              @h_steps_for_params[ori_run.step_id] = step if step
            end
          end
        end
      end
    end
    # Also load runs that are directly referenced by run_id without annot_id
    if direct_run_ids.any?
      Run.where(id: direct_run_ids.uniq).each do |direct_run|
        @h_ori_runs_for_params[direct_run.id] = direct_run unless @h_ori_runs_for_params[direct_run.id]
        if direct_run.step_id.present? && !@h_steps_for_params[direct_run.step_id]
          step = Step.find_by(id: direct_run.step_id)
          @h_steps_for_params[direct_run.step_id] = step if step
        end
      end
    end
    
    render partial: 'projects/views/pipeline_runs_list', layout: false
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
    
    # Get all identifier types (needed for displaying other identifiers from identifiers_json)
    @h_identifier_types = {}
    IdentifierType.all.each { |it| @h_identifier_types[it.id] = it }
    
    # Get experimental entries grouped by identifier type
    @h_exp_entries = {}
    @project.exp_entries.includes(:identifier_type).each do |exp_entry|
      type_id = exp_entry.identifier_type_id
      @h_exp_entries[type_id] ||= []
      @h_exp_entries[type_id] << exp_entry
    end

    # Get articles hash for project DOI references (for Publications section)
    @h_articles = {}
    if @project.doi.present?
      dois = @project.doi.split(/\s*,\s*/).map(&:strip).reject(&:blank?)
      Article.where(doi: dois).each do |article|
        @h_articles[article.doi] = article
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
    session[:clust_comparison] ||= {}
    session[:clust_comparison][@project.id] ||= {}
    session[:clust_comparison][@project.id][:op] ||= "1"
    
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
    
    # Check if the loom file exists before trying to extract metadata
    unless File.exist?(loom_path)
      Rails.logger.warn "Loom file does not exist: #{loom_path}"
      render json: { error: "Data file not found: #{loom_file}" }, status: 404
      return
    end
    
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
        
        # Check if the loom file exists before trying to extract metadata
        unless File.exist?(loom_path)
          Rails.logger.warn "Loom file does not exist: #{loom_path} - skipping metadata #{metadata_id}"
          next
        end
        
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

  def fetch_organisms_for_version(version_id)
    # Get organisms based on the selected ASAP version
    # Database version is stored in version.env_json['asap_data_db_version']
    # Always use remote asap2_data_vX databases - if one doesn't exist, it's a database configuration issue
    return [] unless version_id

    version = Version.find_by(id: version_id)
    return [] unless version

    # Get database version from env_json
    env_data = Basic.safe_parse_json(version.env_json, {})
    db_version = env_data['asap_data_db_version']
    
    unless db_version
      Rails.logger.error("[ProjectsController] Version #{version_id} does not have asap_data_db_version in env_json")
      return []
    end
    
    # Map to remote database name
    db_name = "asap2_data_v#{db_version}"
    
    # Fetch from remote database - returns array of hashes
    # If database doesn't exist, RemoteOrganism.list_for_version will raise an ArgumentError
    # This indicates a database configuration issue that should be fixed
    RemoteOrganism.list_for_version(db_name)
  end

  def group_organisms(organisms)
    groups = Hash.new { |h, k| h[k] = [] }
    
    # Define model organisms - only these specific ones
    model_organisms = ['Homo sapiens', 'Mus musculus', 'Rattus norvegicus', 'Danio rerio', 
                       'Drosophila melanogaster', 'Caenorhabditis elegans', 'Arabidopsis thaliana']
    
    # Handle both ActiveRecord relations (local) and arrays of hashes (remote)
    organisms_list = organisms.is_a?(Array) ? organisms : organisms.to_a
    
    organisms_list.each do |organism|
      # Handle both ActiveRecord objects and hash objects
      if organism.is_a?(Hash)
        # Remote organism (hash)
        organism_name = organism['name']
        organism_id = organism['id']
        display_name = organism['short_name'].presence || organism['name'] || 'Unknown'
        tax_id = organism['tax_id']
        
        # Get domain name from hash (already fetched in RemoteOrganism.list_for_version)
        domain_name = organism['domain_name'] || 'Other'
      else
        # Local organism (ActiveRecord)
        organism_name = organism.name
        organism_id = organism.id
        display_name = organism.display_name.presence || organism.name || 'Unknown'
        tax_id = organism.tax_id
        
        # Get domain name from local database
        domain_name = if organism.ensembl_subdomain
          organism.ensembl_subdomain.name
        else
          'Other'
        end
      end
      
      # Skip organisms without required data (name is required)
      next unless organism_name.present? && organism_id.present?
      
      # Capitalize and format domain name for display
      formatted_domain = domain_name.split('_').map(&:capitalize).join(' ')
      
      # Check if this is a model organism
      is_model_organism = false
      if model_organisms.include?(organism_name)
        # For Mouse and Rat, only include the base species (not subspecies)
        if organism_name == 'Mus musculus' || organism_name == 'Rattus norvegicus'
          # Only include if display_name is exactly "Mouse" or "Rat"
          if display_name == 'Mouse' || display_name == 'Rat'
            is_model_organism = true
          end
        else
          # For other model organisms, include all entries
          is_model_organism = true
        end
      end
      
      # Add to domain group (all organisms go to their domain)
      groups[formatted_domain] << [display_name, organism_id, tax_id]
      
      # Also add to Main model organisms group if applicable (model organisms appear in both groups)
      if is_model_organism
        groups['Main model organisms'] << [display_name, organism_id, tax_id]
      end
    end
    
    # Sort each group alphabetically by display name
    groups.each { |_k, v| v.sort_by! { |item| (item[0] || '').downcase } }
    
    # Sort groups: Main model organisms first, then alphabetically, with Other at the end
    sorted_groups = groups.sort_by do |k, _v|
      case k
      when 'Main model organisms' then '00'
      when 'Other' then 'zzz'
      else k.downcase
      end
    end.to_h
    sorted_groups
  end

  # Deprecated: Use @project.ensure_project_steps instead
  # Kept for backwards compatibility
  def init_project_steps
    @project.ensure_project_steps
  end

  # GET /projects/:id/creating
  def creating
    @project = Project.find(params[:id])
  end

  # GET /projects/:id/step_results
  def step_results
    Rails.logger.info("===== STEP_RESULTS CALLED =====")
    Rails.logger.info("Project ID: #{@project&.id}, Step ID param: #{params[:step_id]}")
    
    begin
      # Reload project to ensure fresh state (in case restart_step left it in a bad state)
      @project.reload
      Rails.logger.info("Project reloaded: #{@project.id}")
      
      # Ensure project steps exist (safeguard for existing projects)
      @project.ensure_project_steps
      Rails.logger.info("Project steps ensured")
      
      step_id = params[:step_id]
      if step_id.blank?
        Rails.logger.error("Step ID is blank!")
        render plain: "Step ID is required", status: :bad_request
        return
      end
      
      Rails.logger.info("Looking for step with ID: #{step_id}")
      @step = Step.find_by(id: step_id)
      
      if @step.nil?
        Rails.logger.error("Step not found for ID: #{step_id}")
        render plain: "Step not found", status: :not_found
        return
      end
      
      Rails.logger.info("Step found: #{@step.name} (ID: #{@step.id})")
      
      # Get runs for this step
      @runs = @project.runs.where(step_id: step_id).includes(:annots).order(created_at: :desc)
      
      # Get project step status (ensure it exists)
      @project_step = ProjectStep.find_by(project_id: @project.id, step_id: step_id)
      unless @project_step
        # Create project step if it doesn't exist
        @project_step = ProjectStep.create(
          project_id: @project.id,
          step_id: step_id,
          status_id: (@step.name == 'parsing') ? 1 : nil
        )
      end
      
      # For steps with has_multiple_runs = false, get the current run for status display
      # This is used to show waiting/running panels when results are not yet available
      if @step && !@step.multiple_runs
        # Get the run to use for status display
        # Priority: 1) most recent run (to show current status), 2) completed run if no active run
        # This matches the logic used in the left panel - we want to show the current/active run's status
        @current_run = @runs.order(created_at: :desc).first
        Rails.logger.info("[step_results] Current run selected for step #{@step.name}: #{@current_run&.id}, status_id: #{@current_run&.status_id}, created_at: #{@current_run&.created_at}")
        
        # For parsing step, also set @parsing_run for backward compatibility
        if @step.name == 'parsing'
          @parsing_run = @current_run
        end
        
        # Get queue position if run is waiting (for any step, not just parsing)
        @queue_position = nil
        if @current_run && @current_run.status_id == 1 && @current_run.slurm_job_id
          begin
            slurm_service = SlurmService.new(logger: Rails.logger)
            @queue_position = slurm_service.get_job_queue_position(@current_run.slurm_job_id)
            Rails.logger.info("[step_results] Queue position for Run##{@current_run.id}: #{@queue_position}")
          rescue => e
            Rails.logger.warn("[step_results] Could not get queue position: #{e.message}")
          end
        end
      end
      
      # For parsing step, load the results from output.json
      if @step.name == 'parsing'
        # @parsing_run is already set above if @current_run exists
        @parsing_run ||= @current_run if @current_run
        
        @results = nil
        
        # Load results if we have a run (completed or failed)
        # After restart, runs are deleted, so @parsing_run will be nil or have a different status
        if @parsing_run && (@parsing_run.status_id == 3 || @parsing_run.status_id == 4)
          project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
          step_dir = project_dir + 'parsing'
          output_json = step_dir + 'output.json'
          
          # Load output.json if it exists
          if File.exist?(output_json)
            @results = Basic.safe_parse_json(File.read(output_json), {})
            
            # If output.json contains displayed_error, the parsing actually failed
            # Update the run and project_step status to reflect this
            if @results && @results['displayed_error'].present?
              error_msg = if @results['displayed_error'].is_a?(Array)
                @results['displayed_error'].join('; ')
              else
                @results['displayed_error'].to_s
              end
              
              # Update run status to failed if we have a run that was marked as complete
              if @parsing_run && @parsing_run.status_id == 3
                @parsing_run.update(status_id: 4, error: error_msg)
                @parsing_run.reload
              end
              
              # Update project_step status to failed if it was marked as complete
              if @project_step && @project_step.status_id == 3
                @project_step.update(status_id: 4, error_message: error_msg)
                @project_step.reload
              end
            end
          end
        end
        
        # Build summary arrays for warnings and errors based on all conditions in the view
        @parsing_warnings = []
        @parsing_errors = []
        
        if @results
          # Collect warnings from @results['warnings'] (array or single value)
          if @results['warnings']
            warnings = @results['warnings'].is_a?(Array) ? @results['warnings'] : [@results['warnings']]
            @parsing_warnings.concat(warnings.compact.reject(&:blank?))
          end
          
          # Collect warnings from @results['warning'] (single value)
          if @results['warning'].present?
            @parsing_warnings << @results['warning']
          end
          
          # Collect errors from @results['errors'] (array or single value)
          if @results['errors']
            errors = @results['errors'].is_a?(Array) ? @results['errors'] : [@results['errors']]
            @parsing_errors.concat(errors.compact.reject(&:blank?))
          end
          
          # Collect errors from @results['error'] (single value, but not displayed_error)
          if @results['error'].present? && !@results['displayed_error']
            @parsing_errors << @results['error']
          end
          
          # Collect validation warnings/errors based on data conditions
          nber_not_found_genes = @results['nber_not_found_genes']
          
          # Validation errors (shown as danger alerts)
          if @results['nber_rows'] && @results['nber_rows'] < 3
            @parsing_errors << "For many steps of the pipeline at least three #{helpers.row_label(@project)} are required"
          end
          
          if @results['nber_cols'] && @results['nber_cols'] == 0
            @parsing_errors << "You may have selected wrong parameters for the parsing, in particular not the appropriated delimiter"
          elsif @results['nber_cols'] && @results['nber_cols'] < 3
            @parsing_errors << "Original dataset has less than 3 #{helpers.col_label(@project)}. For many steps of the pipeline at least three #{helpers.col_label(@project)} are required"
          end
          
          # Count matrix validation (error if not a count table)
          if @results['is_count_table'] != 1 && @results['is_count_table'] != true && @results.key?('is_count_table')
            @parsing_errors << "The original matrix contains floats. Many methods will NOT be available if your original file is not a count matrix"
          end
          
          # Ensembl mapping errors
          if nber_not_found_genes && nber_not_found_genes > 0
            total_genes = @results['nber_rows'] || 1
            not_found_percentage = (nber_not_found_genes.to_f * 100 / total_genes).round(2)
            @parsing_errors << "#{nber_not_found_genes} (#{not_found_percentage}%) #{helpers.row_label(@project)} were not found in Ensembl. Did you select the right species (now #{@project.organism&.name || 'Unknown'})? If not, create a new project"
          end
          
          # Validation warnings (info alerts - zero values percentage)
          if @results['nber_zeros'] && @results['nber_rows'] && @results['nber_cols']
            total_values = @results['nber_rows'].to_f * @results['nber_cols'].to_f
            if total_values > 0
              zero_percentage = ((@results['nber_zeros'].to_f * 100) / total_values).round(2)
              @parsing_warnings << "#{zero_percentage}% of values are zeros"
            end
          end
        end
        
        # Load file formats for display
        @h_formats = {}
        FileFormat.all.each { |f| @h_formats[f.name] = f }
        
        # Handle show_form parameter for parsing step
        # Since parsing skips prepare_std_step_data, we need to set @show_custom_form manually
        # Parsing step uses custom form (has_std_form = false), so we use @show_custom_form
        if params[:show_form].present? && params[:show_form].to_s == '1'
          @show_custom_form = true
          @show_form = false
          @show_view = false
          @show_dashboard = false
        else
          # Initialize @show_form if not set (parsing might not always show form)
          @show_form ||= false
          @show_view ||= false
          @show_dashboard ||= false
          @show_custom_form ||= false
        end
      end
      
      # For cell_filtering step, prepare data for the form
      if @step.name == 'cell_filtering'
        begin
          # Ensure @project is loaded and has the runs association
          @project.reload if @project.changed?
          prepare_cell_filtering_data
          Rails.logger.info("[step_results] Cell filtering data prepared. @parsing_run: #{@parsing_run&.id || 'nil'}")
        rescue => e
          Rails.logger.error("[step_results] Error preparing cell filtering data: #{e.class} - #{e.message}")
          Rails.logger.error("[step_results] Backtrace: #{e.backtrace.first(10).join("\n")}")
          # Set defaults to prevent view errors
          @parsing_run = nil
          @h_data = {}
          @h_data_json = nil
          @list_p = []
          @h_p = {}
          @annots = []
          @h_annots = {}
        end
      end
      
      # Prepare data for standard dashboard and view
      # Skip for parsing step as it has its own special handling
      if @step.name != 'parsing' && (@step.has_std_dashboard || @step.has_std_view || @step.has_std_form)
        begin
          Rails.logger.info("[step_results] Calling prepare_std_step_data for step: #{@step.name}, multiple_runs: #{@step.multiple_runs}, has_std_dashboard: #{@step.has_std_dashboard}, has_std_view: #{@step.has_std_view}, has_std_form: #{@step.has_std_form}, runs_count: #{@runs&.count || 0}")
          prepare_std_step_data
          Rails.logger.info("[step_results] After prepare_std_step_data: show_dashboard=#{@show_dashboard}, show_view=#{@show_view}, show_form=#{@show_form}, show_custom_form=#{@show_custom_form}")
        rescue => e
          Rails.logger.error("[step_results] Error preparing std step data: #{e.class} - #{e.message}")
          Rails.logger.error("[step_results] Backtrace: #{e.backtrace.first(10).join("\n")}")
          # Set defaults to prevent view errors
          @show_dashboard = false
          @show_view = false
          @show_form = false
          @show_custom_form = false
        end
      else
        Rails.logger.info("[step_results] Skipping prepare_std_step_data - step: #{@step.name}, has_std_dashboard: #{@step.has_std_dashboard}, has_std_view: #{@step.has_std_view}, has_std_form: #{@step.has_std_form}")
        # Initialize display flags even if prepare_std_step_data is not called
        @show_dashboard = false
        @show_view = false
        @show_form = false
        @show_custom_form = false
        # If step has std_form and no runs, show the form
        if @step.has_std_form && @runs.empty?
          Rails.logger.info("[step_results] Step has std_form and no runs - setting show_form = true")
          @show_form = true
          prepare_std_form_data
        end
      end
    rescue => e
      Rails.logger.error("Error in step_results: #{e.class} - #{e.message}")
      Rails.logger.error("Error backtrace: #{e.backtrace.first(10).join("\n")}")
      render plain: "Error loading step results: #{e.message}", status: :internal_server_error
      return
    end
    
    Rails.logger.info("About to render step_results partial")
    Rails.logger.info("@step: #{@step.inspect}")
    Rails.logger.info("@step.name: #{@step&.name}")
    Rails.logger.info("@project_step: #{@project_step.inspect}")
    Rails.logger.info("@project_step.status_id: #{@project_step&.status_id}")
    Rails.logger.info("@runs count: #{@runs&.count}")
    if @step&.name == 'parsing'
      Rails.logger.info("@results: #{@results.present? ? 'present' : 'nil'}")
      Rails.logger.info("@parsing_run: #{@parsing_run&.id}, status_id: #{@parsing_run&.status_id}")
      Rails.logger.info("Status to use: #{@parsing_run&.status_id || @project_step&.status_id}")
      Rails.logger.info("@h_formats: #{@h_formats&.keys}")
    end
    
    respond_to do |format|
      format.html { 
        begin
          # If compare_clusters view is requested, return the comparison UI
          if params[:view] == 'compare_clusters'
            render partial: 'projects/views/cluster_comparison', layout: false
            return
          end
          # If show_form is requested, return just the form (for AJAX or new page)
          if params[:show_form].present? && params[:show_form].to_s == '1'
            if @show_form
              if request.xhr?
                # AJAX request - return just the form partial
                render partial: 'projects/views/std_form', layout: false
              else
                # Regular page request - render full page with just the form
                render 'projects/views/form_only', layout: 'application'
              end
            else
              render plain: '<div class="p-4 text-center text-red-600">Form not available for this step.</div>', status: :not_found
            end
          else
            Rails.logger.info("Rendering partial: projects/views/step_results")
            result = render partial: 'projects/views/step_results', layout: false
            Rails.logger.info("Render completed, result length: #{result&.length || 'nil'}")
            Rails.logger.info("Result preview (first 1000 chars): #{result.to_s[0..1000] if result}")
            
            # If result is empty, render a test message to debug
            if result.blank? || result.to_s.strip.length < 10
              Rails.logger.error("Rendered content is empty! Step: #{@step&.name}, ProjectStep: #{@project_step&.id}, Status: #{@project_step&.status_id}, Results: #{@results.present? ? 'present' : 'nil'}")
              render plain: "<div class='alert alert-warning p-4'><h3>Debug Info</h3><p>Step: #{@step&.name}</p><p>ProjectStep: #{@project_step&.id || 'nil'}</p><p>Status: #{@project_step&.status_id || 'nil'}</p><p>Results: #{@results.present? ? 'present' : 'nil'}</p><p>Runs: #{@runs&.count || 0}</p></div>", layout: false
            end
          end
        rescue => e
          Rails.logger.error("Error rendering step_results partial: #{e.class} - #{e.message}")
          Rails.logger.error("Error backtrace: #{e.backtrace.first(10).join("\n")}")
          render plain: "Error rendering step results: #{e.message}", status: :internal_server_error
        end
      }
      format.json { render json: { step: @step, runs: @runs } }
    end
  end

  # GET /projects/:id/queue_position
  def queue_position
    slurm_job_id = params[:slurm_job_id]
    run_id = params[:run_id]
    
    queue_position = nil
    wait_time = nil
    
    if slurm_job_id.present?
      begin
        run = nil
        run_status_id = nil
        
        # Verify run belongs to this project if run_id is provided
        if run_id.present?
          run = Run.find_by(id: run_id, project_id: @project.id)
          unless run
            render json: { error: 'Run not found or does not belong to this project' }, status: :not_found
            return
          end
          
          run_status_id = run.status_id
          Rails.logger.info("[queue_position] Run found: id=#{run.id}, status_id=#{run_status_id.inspect}, slurm_job_id=#{run.slurm_job_id}")
          
          if run.submitted_at
            wait_time = (Time.now - run.submitted_at).to_i
          end
        end
        
        slurm_service = SlurmService.new(logger: Rails.logger)
        # Pass the run's status_id to help determine if queue is empty
        Rails.logger.info("[queue_position] Calling get_job_queue_position with slurm_job_id=#{slurm_job_id}, run_status_id=#{run_status_id.inspect}")
        queue_position = slurm_service.get_job_queue_position(slurm_job_id, run_status_id)
        Rails.logger.info("[queue_position] For SLURM job #{slurm_job_id}, run status_id: #{run_status_id}, queue_position: #{queue_position.inspect}, wait_time: #{wait_time.inspect}")
      rescue => e
        Rails.logger.warn("[queue_position] Error getting queue position: #{e.message}")
        Rails.logger.warn("[queue_position] Backtrace: #{e.backtrace.first(5).join("\n")}")
      end
    end
    
    Rails.logger.info("[queue_position] Returning: queue_position=#{queue_position.inspect}, wait_time=#{wait_time.inspect}")
    render json: {
      queue_position: queue_position,
      wait_time: wait_time
    }
  end

  def refresh_steps_panel
    # Ensure project steps exist (safeguard for existing projects)
    @project.ensure_project_steps
    
    # Get runs for the project
    @runs = @project.runs.includes(:annots) unless @runs
    
    # Build steps with status using shared method
    prepare_steps_with_status
    
    # Track which step is selected by the client (for blue border)
    # This is separate from is_current (which is for the unlock icon)
    @selected_step_id = params[:selected_step_id].present? ? params[:selected_step_id].to_i : nil
    
    respond_to do |format|
      format.html { render partial: 'projects/views/steps_panel', layout: false }
      format.json { render json: { steps: @steps_with_status } }
    end
  end

  # GET /projects/:id/run_status?run_id=:run_id
  def run_status
    # Check authorization - user must be able to read the project
    unless readable?(@project)
      render json: { error: 'Not authorized' }, status: :forbidden
      return
    end
    
    run_id = params[:run_id].to_i
    run = @project.runs.find_by(id: run_id)
    
    unless run
      render json: { error: 'Run not found' }, status: :not_found
      return
    end
    
    # Reload to get latest status
    run.reload
    
    render json: {
      run_id: run.id,
      status_id: run.status_id,
      status_name: case run.status_id
                   when 1 then 'Waiting'
                   when 2 then 'Running'
                   when 3 then 'Completed'
                   when 4 then 'Failed'
                   else 'Unknown'
                   end,
      duration: run.duration ? run.duration.to_i : nil,
      start_time: run.start_time ? run.start_time.iso8601 : nil,
      submitted_at: run.submitted_at ? run.submitted_at.iso8601 : nil,
      waiting_duration: run.waiting_duration ? run.waiting_duration.to_i : nil
    }
  end

  # GET /projects/:id/run_counts
  # Returns run counts by status for header updates
  def run_counts
    unless readable?(@project)
      render json: { error: 'Not authorized' }, status: :forbidden
      return
    end

    # Aggregate run counts from project_steps' nber_runs_json
    # Each project_step has nber_runs_json like {"3": 1, "4": 2} where key is status_id
    totals = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
    
    @project.project_steps.each do |ps|
      next if ps.nber_runs_json.blank?
      
      json_data = ps.nber_runs_json.is_a?(String) ? JSON.parse(ps.nber_runs_json) : ps.nber_runs_json
      json_data.each do |status_id, count|
        status_key = status_id.to_i
        totals[status_key] = (totals[status_key] || 0) + count.to_i if totals.key?(status_key)
      end
    end
    
    # Map to canonical keys
    counts = {
      waiting: totals[1],
      running: totals[2],
      completed: totals[3],
      failed: totals[4],
      cell_count: @project.cell_count,
      col_label: helpers.col_label(@project)
    }

    render json: counts
  end

  # POST /projects/:id/restart_step
  def restart_step
    begin
      step_id = params[:step_id].to_i
      @step = Step.find_by(id: step_id)
      
      if @step.nil?
        redirect_to project_path(@project, view: 'analysis'), alert: 'Step not found.'
        return
      end
      
      # Check if step has multiple_runs = false and status is complete or failed
      @project_step = ProjectStep.find_by(project_id: @project.id, step_id: step_id)
      
      unless @project_step && !@step.multiple_runs && (@project_step.status_id == 3 || @project_step.status_id == 4)
        redirect_to project_path(@project, view: 'analysis', step_id: step_id), alert: 'Step cannot be restarted.'
        return
      end
      
      # Get the rank of the step being restarted
      restart_step_rank = @step.rank
      
      if restart_step_rank.nil?
        redirect_to project_path(@project, view: 'analysis', step_id: step_id), alert: 'Step has no rank and cannot be restarted.'
        return
      end
      
      # Get all steps with rank >= the restarted step's rank
      steps_to_reset = Step.where('rank >= ?', restart_step_rank).order(:rank, :id).all
      
      steps_to_reset.each do |step|
        project_step = ProjectStep.find_by(project_id: @project.id, step_id: step.id)
        if project_step
          # Kill any running jobs for this step
          begin
            Basic.kill_jobs(Rails.logger, @project.id, step.id)
          rescue => e
            Rails.logger.error("Error killing jobs for step #{step.id}: #{e.message}")
          end
          
          # Delete all runs for this step (not just waiting/running)
          runs = @project.runs.where(step_id: step.id).all
          runs.each do |run|
            # Cancel SLURM job if it exists and is running/waiting
            if run.slurm_job_id.present?
              begin
                slurm_service = SlurmService.new(logger: Rails.logger)
                if slurm_service.cancel_job(run.slurm_job_id)
                  Rails.logger.info("Cancelled SLURM job #{run.slurm_job_id} for run #{run.id}")
                else
                  Rails.logger.warn("Failed to cancel SLURM job #{run.slurm_job_id} for run #{run.id}")
                end
              rescue => e
                Rails.logger.error("Error cancelling SLURM job for run #{run.id}: #{e.message}")
              end
            end
            
            # Properly destroy the run and clean up files/annotations
            begin
              # Clear any class-level instance variables that might pollute state
              RunsController.instance_variable_set(:@log, nil)
              RunsController.instance_variable_set(:@h_step_ids, nil)
              
              RunsController.destroy_run_call(@project, run)
              
              # Clear class-level instance variables after use to prevent state pollution
              RunsController.instance_variable_set(:@log, nil)
              RunsController.instance_variable_set(:@h_step_ids, nil)
            rescue => e
              Rails.logger.error("Error destroying run #{run.id}: #{e.message}")
              Rails.logger.error("Error backtrace: #{e.backtrace.first(5).join("\n")}")
              # Clear variables even on error
              RunsController.instance_variable_set(:@log, nil)
              RunsController.instance_variable_set(:@h_step_ids, nil)
              # Fallback: just delete the run if destroy_run_call fails
              begin
                run.destroy
              rescue => e2
                Rails.logger.error("Error in fallback run destroy: #{e2.message}")
              end
            end
          end
          
        # Reset project step status to nil BEFORE updating
        # This ensures status is nil even if upd_project_step finds old runs
        project_step.update(status_id: nil, error_message: nil)
        Rails.logger.info("Reset project_step #{step.id} status to nil")
        
        # Verify runs are actually deleted
        runs_count = @project.runs.where(step_id: step.id).count
        Rails.logger.info("Runs count for step #{step.id} after deletion: #{runs_count}")
        
        # Update project step to reflect the deleted runs
        # upd_project_step will set status to nil if there are no runs
        begin
          Basic.upd_project_step(@project, step.id)
          # Reload and verify status is nil
          project_step.reload
          if project_step.status_id != nil && runs_count == 0
            Rails.logger.warn("upd_project_step set status to #{project_step.status_id} but there are no runs, forcing to nil")
            project_step.update(status_id: nil)
          end
          Rails.logger.info("Final project_step #{step.id} status: #{project_step.status_id}")
        rescue => e
          Rails.logger.error("Error updating project step #{step.id}: #{e.message}")
          # Ensure status is nil on error
          project_step.reload
          project_step.update(status_id: nil) if project_step.status_id != nil
        end
          
        # Broadcast update for this step so websockets update the UI
        # Wrap in rescue to prevent broadcast errors from breaking restart
        begin
          if @project.respond_to?(:broadcast)
            @project.broadcast(step.id)
            Rails.logger.info("Broadcast sent for step #{step.id}")
          end
        rescue => e
          Rails.logger.error("Error broadcasting update for step #{step.id}: #{e.class} - #{e.message}")
          Rails.logger.error("Error backtrace: #{e.backtrace.first(5).join("\n")}")
          # Don't fail restart if broadcast fails
        end
        end
      end
      
      # Reload project to ensure fresh state
      @project.reload
      
      # If we restarted the parsing step, show the form and rerun preparsing
      if @step.name == 'parsing'
        begin
          # Find the Fu (file upload) associated with this project
          fu = if @project.fu_id
                 Fu.find_by(id: @project.fu_id)
               else
                 Fu.where(:project_id => @project.id, :upload_type => 1).first
               end
          
          if fu
            # Extract parsing parameters from parsing_attrs_json
            h_attrs = {}
            if @project.parsing_attrs_json.present?
              h_attrs = Basic.safe_parse_json(@project.parsing_attrs_json, {})
            end
            
            # Build options hash for preparsing job
            options = {}
            
            # Get organism_id and version_id from project
            options[:organism_id] = @project.organism_id if @project.organism_id.present?
            options[:version_id] = @project.version_id if @project.version_id.present?
            
            # Add dataset selection if present
            options[:sel] = h_attrs['sel'] if h_attrs['sel'].present?
            
            # Add parsing parameters for text files (delimiter can be empty string for tab)
            options[:delimiter] = h_attrs['delimiter'] if h_attrs.key?('delimiter')
            options[:gene_name_col] = h_attrs['gene_name_col'] if h_attrs['gene_name_col'].present?
            options[:has_header] = h_attrs['has_header'] if h_attrs.key?('has_header')
            
            # Rerun preparsing with saved parameters (this updates preparsing results)
            fu.update!(status: 'preparsing')
            FuPreparsingJob.perform_later(fu.id, options.compact)
            
            # Redirect to show the form (user can then submit to trigger parsing)
            redirect_to step_results_project_path(@project, step_id: @step.id, show_form: 1), notice: 'Parsing step restarted successfully. Preparsing has been rerun with saved parameters.'
          else
            Rails.logger.error("No Fu found for project #{@project.id} when restarting parsing step")
            # Still redirect to form, parsing will fail if Fu is missing but that's expected
            redirect_to step_results_project_path(@project, step_id: @step.id, show_form: 1), alert: 'Parsing step restarted, but file upload record not found. Please try again.'
          end
        rescue => e
          Rails.logger.error("Error rerunning preparsing: #{e.message}")
          Rails.logger.error("Error backtrace: #{e.backtrace.first(5).join("\n")}")
          redirect_to step_results_project_path(@project, step_id: @step.id, show_form: 1), alert: 'Step restarted successfully, but failed to rerun preparsing. Please try again.'
        end
      else
        # Redirect without step_id - websockets will handle the UI updates
        redirect_to project_path(@project, view: 'analysis'), notice: 'Step restarted successfully. All subsequent steps have been reset.'
      end
    rescue => e
      Rails.logger.error("Error in restart_step: #{e.class} - #{e.message}")
      Rails.logger.error("Error backtrace: #{e.backtrace.first(10).join("\n")}")
      redirect_to project_path(@project, view: 'analysis'), alert: "Error restarting step: #{e.message}"
    end
  end

  # POST /projects/:id/delete_all_runs_from_step
  def delete_all_runs_from_step
    begin
      step_id = params[:step_id].to_i
      @step = Step.find_by(id: step_id)
      
      if @step.nil?
        redirect_to project_path(@project, view: 'analysis'), alert: 'Step not found.'
        return
      end
      
      # Get runs to delete - either selected runs or all runs
      if params[:run_ids].present? && params[:run_ids].is_a?(Array)
        # Delete selected runs only
        run_ids = params[:run_ids].map(&:to_i).compact
        runs = @project.runs.where(step_id: step_id, id: run_ids).all
      else
        # Delete all runs for this step
        runs = @project.runs.where(step_id: step_id).all
      end
      
      if runs.empty?
        redirect_to step_results_project_path(@project, step_id: step_id), notice: 'No runs to delete.'
        return
      end
      
      # Delete each run
      runs.each do |run|
        # Cancel SLURM job if it exists and is running/waiting
        if run.slurm_job_id.present?
          begin
            slurm_service = SlurmService.new(logger: Rails.logger)
            if slurm_service.cancel_job(run.slurm_job_id)
              Rails.logger.info("Cancelled SLURM job #{run.slurm_job_id} for run #{run.id}")
            else
              Rails.logger.warn("Failed to cancel SLURM job #{run.slurm_job_id} for run #{run.id}")
            end
          rescue => e
            Rails.logger.error("Error cancelling SLURM job for run #{run.id}: #{e.message}")
          end
        end
        
        # Properly destroy the run and clean up files/annotations
        begin
          # Clear any class-level instance variables that might pollute state
          RunsController.instance_variable_set(:@log, nil)
          RunsController.instance_variable_set(:@h_step_ids, nil)
          
          RunsController.destroy_run_call(@project, run)
          
          # Clear class-level instance variables after use to prevent state pollution
          RunsController.instance_variable_set(:@log, nil)
          RunsController.instance_variable_set(:@h_step_ids, nil)
        rescue => e
          Rails.logger.error("Error destroying run #{run.id}: #{e.message}")
          Rails.logger.error("Error backtrace: #{e.backtrace.first(5).join("\n")}")
          # Clear variables even on error
          RunsController.instance_variable_set(:@log, nil)
          RunsController.instance_variable_set(:@h_step_ids, nil)
          # Fallback: just delete the run if destroy_run_call fails
          begin
            run.destroy
          rescue => e2
            Rails.logger.error("Error in fallback run destroy: #{e2.message}")
          end
        end
      end
      
      # Update project step to reflect the deleted runs
      project_step = ProjectStep.find_by(project_id: @project.id, step_id: step_id)
      if project_step
        project_step.update(status_id: nil, error_message: nil)
        begin
          Basic.upd_project_step(@project, step_id)
          project_step.reload
          if project_step.status_id != nil && runs.count == 0
            Rails.logger.warn("upd_project_step set status to #{project_step.status_id} but there are no runs, forcing to nil")
            project_step.update(status_id: nil)
          end
        rescue => e
          Rails.logger.error("Error updating project step #{step_id}: #{e.message}")
          project_step.reload
          project_step.update(status_id: nil) if project_step.status_id != nil
        end
      end
      
      # Broadcast update for this step so websockets update the UI
      begin
        if @project.respond_to?(:broadcast)
          @project.broadcast(step_id)
          Rails.logger.info("Broadcast sent for step #{step_id}")
        end
      rescue => e
        Rails.logger.error("Error broadcasting update for step #{step_id}: #{e.class} - #{e.message}")
      end
      
      # Reload project to ensure fresh state
      @project.reload
      
      # Check if there are no runs left and step has std_form - if so, show the form
      remaining_runs = @project.runs.where(step_id: step_id).count
      show_form = remaining_runs == 0 && @step.has_std_form
      
      # Determine success message
      deleted_count = runs.count
      if params[:run_ids].present? && params[:run_ids].is_a?(Array)
        success_message = "#{deleted_count} run(s) deleted successfully."
      else
        success_message = "All runs deleted successfully."
      end
      
      respond_to do |format|
        format.html {
          if show_form
            redirect_to step_results_project_path(@project, step_id: step_id, show_form: 1), notice: success_message
          else
            redirect_to step_results_project_path(@project, step_id: step_id), notice: success_message
          end
        }
        format.json {
          render json: {
            status: 'success',
            message: success_message,
            show_form: show_form
          }
        }
      end
    rescue => e
      Rails.logger.error("Error in delete_all_runs_from_step: #{e.class} - #{e.message}")
      Rails.logger.error("Error backtrace: #{e.backtrace.first(10).join("\n")}")
      redirect_to project_path(@project, view: 'analysis'), alert: "Error deleting runs: #{e.message}"
    end
  end

  # GET /projects/:id/reset_parsing
  def reset_parsing
    @original_project = Project.find(params[:id])
    
    # Check if this is an integration project (no file upload, source projects instead)
    h_attrs = Basic.safe_parse_json(@original_project.parsing_attrs_json, {})
    if h_attrs['integrate_batch_paths'].present?
      source_keys = h_attrs['integrate_batch_paths'].keys
      session[:integrate_project_keys] = source_keys
      # Pass source_keys in URL params so the new action does not depend solely
      # on the session cookie surviving the redirect (Turbo Drive + fetch can
      # occasionally lose the Set-Cookie from the intermediate 302 response).
      redirect_to new_project_path(integrate: 1, source_keys: source_keys.join(','))
      return
    end

    # Find the Fu (file upload) associated with this project
    fu = if @original_project.fu_id
           Fu.find_by(id: @original_project.fu_id)
         else
           Fu.where(:project_id => @original_project.id, :upload_type => 1).first
         end
    
    unless fu
      redirect_to project_path(@original_project, view: 'analysis'), alert: 'File upload record not found. Cannot reset parsing.'
      return
    end
    
    # Set up session with existing file upload data
    upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                        ENV["UPLOAD_DATA_DIR"]
                      elsif ENV["DATA_DIR"]
                        Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                      else
                        '/data/asap2/fus'
                      end
    upload_dir = Pathname.new(upload_base_dir) + fu.id.to_s
    upload_file_path = upload_dir + fu.upload_file_name
    
    unless File.exist?(upload_file_path)
      redirect_to project_path(@original_project, view: 'analysis'), alert: 'Uploaded file not found. Cannot reset parsing.'
      return
    end
    
    # Set up session with file upload info
    session[:file_upload] = {
      fu_id: fu.id,
      original_filename: fu.name || fu.upload_file_name,
      input_filename: fu.upload_file_name,
      path: upload_file_path.to_s,
      size: fu.upload_file_size || File.size(upload_file_path),
      total_size: fu.upload_file_size || File.size(upload_file_path),
      complete: true,
      organism_id: @original_project.organism_id,
      version_id: @original_project.version_id
    }
    
    # Extract parsing attributes from existing project
    h_attrs = {}
    if @original_project.parsing_attrs_json.present?
      h_attrs = Basic.safe_parse_json(@original_project.parsing_attrs_json, {})
    end
    
    # Use the existing project instead of creating a new one
    # This ensures we keep the same project ID
    @project = @original_project
    
    # Store flag in session to indicate we're resetting parsing
    session[:resetting_parsing] = true
    session[:resetting_parsing_project_id] = @original_project.id
    
    # Set up form data
    @project_types = ProjectType.order(:name)
    @versions = available_versions
    @file_formats = FileFormat.ordered
    @organisms = fetch_organisms_for_version(@project.version_id || @versions.first&.id)
    @grouped_organisms = group_organisms(@organisms)
    
    # Store parsing attributes in instance variable for form pre-filling
    @parsing_attrs = h_attrs
    
    # Check if preparsing is already complete by checking for output.json
    output_file = upload_dir + 'output.json'
    if File.exist?(output_file) && File.size(output_file) > 0
      # Preparsing is complete - ensure Fu status reflects this
      # This prevents the JavaScript from thinking preparsing is still running
      if fu.status != 'preparsed'
        begin
          # Try to load the output to verify it's valid
          output_content = File.read(output_file)
          output_json = Basic.safe_parse_json(output_content, {})
          if output_json.present? && output_json.is_a?(Hash)
            fu.update!(status: 'preparsed')
            Rails.logger.info("[reset_parsing] Set Fu##{fu.id} status to 'preparsed' (preparsing already complete)")
          else
            Rails.logger.warn("[reset_parsing] Output file exists but is invalid, keeping Fu##{fu.id} status as: #{fu.status}")
          end
        rescue => e
          Rails.logger.error("[reset_parsing] Error checking preparsing output: #{e.message}")
          # If we can't read the file, don't change the status
        end
      end
    else
      # Preparsing output doesn't exist - if status is 'preparsing', it might be stuck
      # Set to 'uploaded' so it can be detected properly
      if fu.status == 'preparsing'
        fu.update!(status: 'uploaded')
        Rails.logger.info("[reset_parsing] Set Fu##{fu.id} status to 'uploaded' (preparsing output missing, may need to rerun)")
      end
    end
    
    # Store fu_id for the form to detect existing upload
    @existing_fu_id = fu.id
    @existing_filename = fu.name || fu.upload_file_name
    
    # Flag to indicate we're resetting parsing (for button text)
    @is_resetting_parsing = true
    
    # Note: We don't rerun preparsing - the existing preparsing results will be used
    # The file upload controller will detect the existing fu_id and show preparsing results
    
    # Render the new project form
    render :new
  end

  # GET /projects/:id/creation_status
  def creation_status
    @project = Project.find(params[:id])
    
    # Determine current step based on project status and steps
    status_info = {
      project_created: true,
      project_key: @project.key,
      parsing_status: 'waiting',
      parsing_complete: false,
      metadata_status: 'waiting',
      metadata_complete: false,
      all_complete: false,
      redirect_url: nil
    }
    
    # Check parsing step status
    parsing_step = Step.where(name: 'parsing').first
    if parsing_step
      project_step = ProjectStep.find_by(project_id: @project.id, step_id: parsing_step.id)
      if project_step
        status_info[:parsing_status] = case project_step.status_id
        when 1
          'waiting'
        when 2
          'running'
        when 3
          'complete'
        when 4
          'failed'
        else
          'waiting'
        end
        status_info[:parsing_complete] = (project_step.status_id == 3)
      end
    end
    
    # Check metadata status - for now, mark as complete when parsing is done
    # In the future, you can add a separate metadata copying step check here
    if status_info[:parsing_complete]
      status_info[:metadata_status] = 'complete'
      status_info[:metadata_complete] = true
    elsif status_info[:parsing_status] == 'running'
      status_info[:metadata_status] = 'waiting'
    end
    
    # Check if project is fully ready (parsing and metadata complete)
    if status_info[:parsing_complete] && status_info[:metadata_complete]
      status_info[:all_complete] = true
      status_info[:redirect_url] = project_path(@project)
    end
    
    respond_to do |format|
      format.json { render json: status_info }
    end
  end

  # GET /projects/:key/get_attributes?step_id=:step_id&obj_id=:obj_id
  # Returns attribute fields for a step and method
  def get_attributes
    step_id = params[:step_id]
    obj_id = params[:obj_id] || params[:std_method_id]
    
    unless step_id && obj_id
      render plain: '<div class="p-4 text-center text-red-600">Missing required parameters: step_id and obj_id</div>', status: :bad_request
      return
    end
    
    @step = Step.find_by(id: step_id)
    @std_method = StdMethod.find_by(id: obj_id)
    
    unless @step && @std_method
      render plain: '<div class="p-4 text-center text-red-600">Step or method not found</div>', status: :not_found
      return
    end
    
    # Get attributes using Basic.get_std_method_attrs
    h_res = Basic.get_std_method_attrs(@std_method, @step)
    @h_attrs = h_res[:h_attrs]
    
    # Get attribute layout from std_method
    @attr_layout = Basic.safe_parse_json(@std_method.attr_layout_json, [])
    
    # If no layout, create a simple default layout
    if @attr_layout.empty? && @h_attrs.any?
      @attr_layout = [{
        "horiz_elements" => [{
          "attr_list" => @h_attrs.keys,
          "class" => "",
          "container_class" => "col-12"
        }]
      }]
    end
    
    # Get available runs for input selection
    @h_runs = {}
    successful_runs = Run.where(project_id: @project.id, status_id: 3) # status_id 3 = success
    successful_runs.each { |run| @h_runs[run.id] = run }
    
      # Get steps for lookups
      asap_docker_image = Basic.get_asap_docker(@project.version)
      @h_steps = {}
      if asap_docker_image
        Step.where(docker_image_id: asap_docker_image.id).each { |s| @h_steps[s.id] = s }
      end
      
      # Get annotations for input_data widgets (needed to find annot_id)
      @h_annots = {}
      successful_runs.each do |run|
        annots = Annot.where(run_id: run.id, data_type_id: 3).all
        annots.each { |a| @h_annots[a.id] = a }
      end
      
      render partial: 'projects/views/attributes', layout: false
  rescue StandardError => e
    Rails.logger.error("[get_attributes] Error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    render plain: "<div class='p-4 text-center text-red-600'>Error loading attributes: #{e.message}</div>", status: :internal_server_error
  end

  private

  def find_or_start_marker_run_for_annot(annot)
    marker_run = marker_run_for_annot(annot)
    started = false
    submitted = false

    if marker_run.nil? || marker_run.status_id.to_i == 4
      user_id = current_user&.id || @project.user_id
      res = Basic.find_markers(Rails.logger, @project, annot, user_id)
      marker_run = res[:run]
      started = marker_run.present?
    end

    if marker_run && marker_run.status_id.to_i == 1 && marker_run.slurm_job_id.blank? && marker_run.req_id.blank?
      Basic.exec_run(Rails.logger, marker_run)
      submitted = true
    end

    marker_run&.reload
    { run: marker_run, started: started, submitted: submitted, error: marker_run ? nil : 'Marker run could not be created.' }
  rescue StandardError => e
    Rails.logger.error("[get_annot_evidences] find_or_start_marker_run_for_annot failed: #{e.class} - #{e.message}")
    { run: nil, started: false, submitted: false, error: e.message }
  end

  def marker_run_for_annot(annot)
    asap_docker_image = Basic.get_asap_docker(@project.version)
    return nil unless asap_docker_image

    marker_step = Step.find_by(docker_image_id: asap_docker_image.id, name: 'markers')
    return nil unless marker_step

    matrix_annot = Annot.find_by(project_id: @project.id, dim: 3, name: '/matrix', filepath: annot.filepath)
    return nil unless matrix_annot

    marker_groups_id = Basic.marker_groups_annot_id(@project, annot)
    attrs = {
      input_matrix: { 'annot_id' => matrix_annot.id, 'run_id' => matrix_annot.run_id },
      groups_filename: project_data_dir + annot.filepath,
      groups_dataset: annot.name,
      groups_id: marker_groups_id
    }

    Run.where(project_id: @project.id, step_id: marker_step.id, attrs_json: attrs.to_json).order(id: :desc).first
  end

  def parse_marker_rows_for_category(marker_run, cat_idx)
    marker_file = project_data_dir + 'markers' + marker_run.id.to_s + "cat_#{cat_idx + 1}.tsv"
    return { error: 'FindMarkers output is not available yet. Please refresh shortly.' } unless File.exist?(marker_file)

    rows_up = []
    rows_down = []
    fdr_cutoff = 0.05
    fc_cutoff = Math.log2(2.0)
    max_rows_per_group = 100

    File.foreach(marker_file).with_index do |line, line_idx|
      next if line_idx.zero? && line.include?('gene')
      cols = line.rstrip.split("\t")
      next if cols.size < 9

      log2fc = cols[4].to_f
      p_value = cols[5].to_f
      fdr = cols[6].to_f
      next if fdr > fdr_cutoff
      next if log2fc.abs < fc_cutoff

      row = {
        gene_id: cols[0].to_s,
        gene: cols[2].to_s,
        log2fc: log2fc.round(4),
        p_value: p_value,
        fdr: fdr
      }

      if log2fc >= 0
        rows_up << row if rows_up.size < max_rows_per_group
      else
        rows_down << row if rows_down.size < max_rows_per_group
      end

      break if rows_up.size >= max_rows_per_group && rows_down.size >= max_rows_per_group
    end

    { rows_up: rows_up, rows_down: rows_down }
  rescue StandardError => e
    Rails.logger.error("[get_annot_evidences] parse_marker_rows_for_category failed: #{e.class} - #{e.message}")
    { error: e.message }
  end

  def project_data_dir
    Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
  end

  def marker_compatible_metadata?(annot)
    return false unless annot

    data_type = annot.data_type
    return false unless data_type
    return false unless data_type.name.to_s == 'DISCRETE'
    return false if annot.nber_cats.to_i <= 1

    true
  end

  def run_de_filter(annots, h_de_filter)
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    h_stats = {}

    h_annots_by_loom_path = {}
    annots_to_do = annots.select do |annot|
      output_txt = project_dir + 'de' + annot.run_id.to_s + 'output.txt'
      !File.exist?(output_txt) || File.size(output_txt) == 0
    end
    annots_to_do.each do |annot|
      h_annots_by_loom_path[annot.filepath] ||= []
      h_annots_by_loom_path[annot.filepath].push(annot)
    end

    h_ensembl_ids = {}
    h_ensembl_ids_by_loom_path = {}
    h_gene_names_by_loom_path = {}

    loom_paths = annots_to_do.map(&:filepath).uniq
    loom_paths.each do |loom_path|
      to_compute = h_annots_by_loom_path[loom_path].any? do |annot|
        output_file = project_dir + 'de' + annot.run_id.to_s + 'output.txt'
        !File.exist?(output_file) || File.size(output_file) == 0
      end

      next unless to_compute

      loom_file = project_dir + loom_path
      cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata -loom #{loom_file} -meta /row_attrs/Accession"
      h_res = Basic.safe_parse_json(`#{cmd}`, {})
      if h_res['values']
        h_res['values'].each { |v| h_ensembl_ids[v] = 1 }
      end
      h_ensembl_ids_by_loom_path[loom_path] = h_res['values']

      cmd2 = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata -loom #{loom_file} -meta /row_attrs/Gene"
      h_res2 = Basic.safe_parse_json(`#{cmd2}`, {})
      h_gene_names_by_loom_path[loom_path] = h_res2['values']
    end

    h_genes = {}
    if annots_to_do.size > 0
      version = @project.version
      h_env = Basic.safe_parse_json(version.env_json, {})
      res = Basic.sql_query2(:asap_data, h_env['asap_data_db_version'], 'genes', '', 'ensembl_id, organism_id, name, description, alt_names', "organism_id = #{@project.organism_id}")
      res.select { |g| h_ensembl_ids[g.ensembl_id] }.each { |g| h_genes[g.ensembl_id] = g }
    end

    annots_to_do.select { |a| File.exist?(project_dir + 'de' + a.run_id.to_s) }.each do |annot|
      loom_path = annot.filepath
      loom_file = project_dir + loom_path
      output_file = project_dir + 'de' + annot.run_id.to_s + 'output.txt'

      next if File.exist?(output_file) && File.size(output_file) > 0

      cmd3 = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata --scientific -prec 5 -loom #{loom_file} -meta \"#{annot.name}\""
      h_results = Basic.safe_parse_json(`#{cmd3}`.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8), {})
      if h_results['values']
        h_results['values'].each_index do |i|
          h_results['values'][i] = h_results['values'][i].map { |e| e ? e.to_f : 'NA' } if h_results['values'][i]
        end
      end

      ensembl_ids = h_ensembl_ids_by_loom_path[loom_path]
      gene_names = h_gene_names_by_loom_path[loom_path]

      File.open(output_file, 'w') do |f|
        if h_results['values'] && h_results['values'][0] && h_results['values'][0].size > 0
          f.write(
            (0..h_results['values'][0].size - 1).to_a
              .select { |e| h_results['values'][0][e] }
              .sort { |a, b| h_results['values'][0][a].to_f <=> h_results['values'][0][b].to_f }
              .map { |i|
                if ensembl_ids && ensembl_ids[i] && (g = h_genes[ensembl_ids[i]])
                  details = [i, g.ensembl_id, g.name, g.alt_names, g.description]
                else
                  details = [i, nil, gene_names ? gene_names[i] : nil, nil, nil]
                end
                (details + (0..4).map { |vi|
                  val = h_results['values'][vi][i]
                  if val
                    if [1, 2].include?(vi) || !val.is_a?(Float)
                      val
                    elsif val.is_a?(Float) && val.abs > 0.001
                      '%.3f' % val
                    else
                      '%.e' % val
                    end
                  else
                    'NA'
                  end
                }).join("\t")
              }.join("\n") + "\n"
          )
        end
      end
    end

    user_id = current_user ? current_user.id : 1
    list_of_run_ids = annots.map(&:run_id)

    filtered_stats_txt_file = project_dir + 'tmp' + "#{user_id}_de_filtered_stats.txt"
    File.delete(filtered_stats_txt_file) if File.exist?(filtered_stats_txt_file)

    FileUtils.mkdir_p(project_dir + 'tmp')
    cmd = "echo '#{list_of_run_ids.join("\n")}' | xargs -P 24 -I '{}' lib/filter_de '#{project_dir}' #{h_de_filter['fdr_cutoff']} #{h_de_filter['fc_cutoff']} de_results #{user_id} '{}' > #{project_dir + 'toto.txt'}"
    script_file = project_dir + 'tmp' + "#{user_id}_de_script.sh"
    File.open(script_file, 'w') { |f| f.write(cmd) }
    `sh #{script_file}`

    if File.exist?(filtered_stats_txt_file)
      File.open(filtered_stats_txt_file, 'r') do |f|
        while (l = f.gets)
          t = l.chomp.split("\t")
          h_stats[t[0]] = { 'up' => t[1].to_i, 'down' => t[2].to_i }
        end
      end

      filtered_stats_json = project_dir + 'tmp' + "#{user_id}_de_filtered_stats.json"
      File.open(filtered_stats_json, 'w') { |f| f.write(h_stats.to_json) }
    end

    h_stats
  end

  # Get all run IDs in the pipeline that created a given run
  # This returns only the run itself and all its ancestors (the pipeline that produced it)
  # It does NOT include descendants (runs that used this run as input)
  # Returns runs in lineage order: [oldest_ancestor, ..., parent, root_run]
  def get_pipeline_run_ids(root_run_id)
    require 'set'
    
    # Load ALL runs for this project
    all_runs = Run.where(project_id: @project.id).to_a
    runs_by_id = all_runs.index_by(&:id)
    
    # Get the root run
    root_run = runs_by_id[root_run_id] || Run.find_by(id: root_run_id, project_id: @project.id)
    return [root_run_id] unless root_run
    
    run_ids_set = Set.new([root_run_id])
    ordered_run_ids = []
    
    # Get all ancestors (parents, grandparents, etc.) - the pipeline that created this run
    # lineage_run_ids contains all ancestor run IDs in order (oldest first)
    if root_run.lineage_run_ids.present?
      lineage_ids = root_run.lineage_run_ids.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
      lineage_ids.each do |id|
        if id > 0 && !run_ids_set.include?(id)
          run_ids_set.add(id)
          ordered_run_ids << id
        end
      end
    end
    
    # Also traverse run_parents_json to ensure we get all ancestors (in case lineage_run_ids is incomplete)
    ancestor_visited = Set.new
    ancestor_queue = [root_run_id]
    additional_ancestors = []
    
    while ancestor_queue.any?
      current_run_id = ancestor_queue.shift
      next if ancestor_visited.include?(current_run_id)
      ancestor_visited.add(current_run_id)
      
      current_run = runs_by_id[current_run_id] || Run.find_by(id: current_run_id, project_id: @project.id)
      next unless current_run && current_run.run_parents_json.present?
      
      begin
        parents = Basic.safe_parse_json(current_run.run_parents_json, [])
        if parents.is_a?(Array) && parents.any?
          parents.each do |parent|
            parent_id = parent.is_a?(Hash) ? (parent[:run_id] || parent['run_id']) : parent
            parent_id = parent_id.to_i if parent_id
            
            if parent_id && parent_id > 0 && !ancestor_visited.include?(parent_id)
              if !run_ids_set.include?(parent_id)
                run_ids_set.add(parent_id)
                additional_ancestors << parent_id
              end
              ancestor_queue << parent_id
            end
          end
        end
      rescue => e
        Rails.logger.warn("Error parsing run_parents_json for run #{current_run_id}: #{e.message}")
      end
    end
    
    # Combine: lineage order first, then any additional ancestors (sorted by id), then root run
    # Sort additional ancestors by id to maintain some order
    additional_ancestors.sort!
    
    # Final order: ancestors from lineage (oldest first) + additional ancestors + root run
    result = ordered_run_ids + additional_ancestors
    result << root_run_id unless result.include?(root_run_id)
    result.uniq
  end

    # Helper method to check if a step can be unlocked based on attrs_json requirements
    # This checks ONLY if required Annot instances are available, regardless of step completion status
    # A step is unlocked only if at least one std_method is available (has all required inputs)
    def step_can_be_unlocked?(step, previous_steps_with_status, successful_runs)
      result = step_unlock_status(step, previous_steps_with_status, successful_runs)
      result[:unlocked]
    end
    
    # Returns both unlock status and reason: { unlocked: boolean, reason: string or nil }
    def step_unlock_status(step, previous_steps_with_status, successful_runs)
      # If the parsing method restricts downstream steps (e.g. integration),
      # only allow steps explicitly listed in allowed_downstream_steps
      if @parsing_method_allowed_steps.present?
        if step.name.in?(@parsing_method_allowed_steps)
          return { unlocked: true, reason: nil }
        else
          return { unlocked: false, reason: "Not available after integration" }
        end
      end
      
      # Debug logging for project 69560
      if @project.id == 69560 && step.name == 'normalization'
        Rails.logger.info("[DEBUG] step_unlock_status called for normalization step")
      end
      
      # Get all std_methods for this step
      asap_docker_image = Basic.get_asap_docker(@project.version)
      return { unlocked: true, reason: nil } unless asap_docker_image # If no docker image, allow step (fallback)
      
      std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, step_id: step.id, obsolete: false).all
      
      if @project.id == 69560 && step.name == 'normalization'
        Rails.logger.info("[DEBUG] StdMethods count: #{std_methods.count}")
        std_methods.each { |m| Rails.logger.info("[DEBUG]   StdMethod #{m.id}: #{m.name}") }
      end
      
      # If no std_methods, step cannot be unlocked (no methods available)
      return { unlocked: false, reason: "No methods available" } if std_methods.empty?
      
      # Get ALL available annotations in this project (not just from successful runs)
      # We check all annotations because they represent available datasets
      available_annots = get_available_annotations_for_project
      
      if @project.id == 69560 && step.name == 'normalization'
        Rails.logger.info("[DEBUG] Available annotations count: #{available_annots.count}")
      end
      
      # Get project type for filtering
      project_type_tag = @project.project_type ? @project.project_type.tag : nil
      
      # Get steps by name for lookup
      h_steps_by_name = {}
      if asap_docker_image
        Step.where(docker_image_id: asap_docker_image.id).each { |s| h_steps_by_name[s.name] = s if s.respond_to?(:name) }
      end
      
      # Track missing requirements for computing the lock reason
      # Key: step_name, Value: Set of required types
      all_missing_requirements = []
      
      # Track project type mismatches
      methods_with_requirements_but_wrong_type = []
      all_required_project_types = Set.new
      
      # Check if at least one std_method has all required parameters satisfied AND matches project type
      # This means at least one method is available
      available_methods_count = 0
      result = std_methods.any? do |std_method|
        # Check project type compatibility
        method_obj_attrs = Basic.safe_parse_json(std_method.obj_attrs_json, {})
        method_project_types = method_obj_attrs["project_types"] || []
        project_type_match = method_project_types.empty? || method_project_types.include?(project_type_tag)
        
        # Track the project types required by methods
        all_required_project_types.merge(method_project_types) if method_project_types.any?
        
        # Check if method has all required inputs and collect missing requirements
        has_requirements, missing_requirements = std_method_requirements_with_reason(step, std_method, available_annots, h_steps_by_name)
        
        # Track methods that have all data requirements but fail project type check
        if has_requirements && !project_type_match
          methods_with_requirements_but_wrong_type << std_method
        end
        
        # Track missing requirements for the lock reason
        all_missing_requirements.concat(missing_requirements)
        
        # Method is available only if it matches project type AND has all requirements
        is_available = project_type_match && has_requirements
        available_methods_count += 1 if is_available
        
        is_available
      end
      
      # Step is unlocked only if at least one method is available
      # If no methods are available (after all checks), step is locked
      if result
        { unlocked: true, reason: nil }
      else
        # Build a detailed lock reason
        # First check if it's a project type mismatch (all methods have requirements but wrong project type)
        reason = if methods_with_requirements_but_wrong_type.any? && all_missing_requirements.empty?
                   # All methods have the data they need, but project type doesn't match
                   project_type_label = case project_type_tag
                                        when 'sc' then 'single-cell'
                                        when 'bulk' then 'bulk'
                                        else project_type_tag || 'unknown'
                                        end
                   required_types_labels = all_required_project_types.map do |t|
                     case t
                     when 'sc' then 'single-cell'
                     when 'bulk' then 'bulk'
                     else t
                     end
                   end
                   "Only available for #{required_types_labels.join(' or ')} projects (current: #{project_type_label})"
                 elsif all_missing_requirements.any?
                   # Missing data requirements
                   # Group by types to create a clear message
                   # Format: "Requires <type> from <step>"
                   requirement_messages = all_missing_requirements.map do |req|
                     step_names = req[:steps].map do |step_name|
                       step_obj = h_steps_by_name[step_name]
                       step_obj ? (step_obj.label.presence || step_obj.name.humanize) : step_name.humanize
                     end.uniq.join(" or ")
                     
                     # Use format_valid_types which applies DataClass templates and filters out 'dataset'
                     type_label = format_valid_types(req[:valid_types])
                     
                     if type_label.present?
                       "#{type_label} from #{step_names}"
                     else
                       # If all types were filtered out (e.g., only 'dataset'), just show the step name
                       "data from #{step_names}"
                     end
                   end.uniq
                   
                   "Requires: #{requirement_messages.join('; ')}"
                 else
                   # Fallback: try to get info from step's and methods' attrs_json
                   required_inputs = []
                   
                   # Check step attrs
                   step_attrs = Basic.safe_parse_json(step.attrs_json, {})
                   step_attrs.each do |attr_name, attr_config|
                     next unless attr_config.is_a?(Hash)
                     if attr_config['source_steps'].present?
                       source_step_names = attr_config['source_steps'].map do |ssn|
                         step_obj = h_steps_by_name[ssn]
                         step_obj ? (step_obj.label.presence || step_obj.name.humanize) : ssn.humanize
                       end
                       types_str = attr_config['valid_types'].present? ? format_valid_types(attr_config['valid_types']) : nil
                       if types_str.present?
                         required_inputs << "#{types_str} from #{source_step_names.join(' or ')}"
                       else
                         required_inputs << source_step_names.join(" or ")
                       end
                     end
                   end
                   
                   # Also check first std_method's attrs if step attrs don't have requirements
                   if required_inputs.empty? && std_methods.any?
                     first_method = std_methods.first
                     begin
                       h_res = Basic.get_std_method_attrs(first_method, step)
                       combined_attrs = h_res[:h_attrs] || {}
                       combined_attrs.each do |attr_name, attr_config|
                         next unless attr_config.is_a?(Hash)
                         if attr_config['source_steps'].present?
                           source_step_names = attr_config['source_steps'].map do |ssn|
                             step_obj = h_steps_by_name[ssn]
                             step_obj ? (step_obj.label.presence || step_obj.name.humanize) : ssn.humanize
                           end
                           types_str = attr_config['valid_types'].present? ? format_valid_types(attr_config['valid_types']) : nil
                           if types_str.present?
                             required_inputs << "#{types_str} from #{source_step_names.join(' or ')}"
                           else
                             required_inputs << source_step_names.join(" or ")
                           end
                         end
                       end
                     rescue => e
                       Rails.logger.error("[step_unlock_status] Error getting method attrs: #{e.message}")
                     end
                   end
                   
                   if required_inputs.any?
                     "Requires: #{required_inputs.uniq.join('; ')}"
                   else
                     "Previous steps must be completed first"
                   end
                 end
        { unlocked: false, reason: reason }
      end
    end
    
    # Format data type names into human-readable labels
    # Format a single data type name to a user-friendly label
    # Uses DataClass.label_template and replaces {row_label}/{col_label} with project type values
    def format_data_type_label(types_str)
      return types_str if types_str.blank?
      
      # Build data class cache if not already cached
      @data_class_cache ||= begin
        cache = {}
        DataClass.all.each do |dc|
          cache[dc.name] = { template: dc.label_template, category: dc.category }
        end
        cache
      end
      
      # Get project type labels for template substitution
      row_label = @project&.project_type&.row_label || 'rows'
      col_label = @project&.project_type&.col_label || 'columns'
      row_label_singular = row_label.singularize
      col_label_singular = col_label.singularize
      
      # Replace technical names with friendly labels from templates
      result = types_str.dup
      @data_class_cache.each do |tech_name, dc_info|
        template = dc_info[:template]
        next if template.nil?  # Skip types with nil template (like 'dataset')
        
        # Replace template placeholders with actual labels
        friendly_name = template.gsub('{row_label}', row_label)
                                .gsub('{col_label}', col_label)
                                .gsub('{row_label_singular}', row_label_singular)
                                .gsub('{col_label_singular}', col_label_singular)
        result.gsub!(tech_name, friendly_name)
      end
      
      result
    end
    
    # Format valid_types array into a readable string
    # valid_types is like [["dataset"], ["num_matrix", "int_matrix"]]
    # - outer array = AND conditions (all must be present)
    # - inner arrays = OR conditions (any one of these types satisfies this requirement)
    # Uses DataClass categories to intelligently combine base types and value types
    # Example output: "gene metadata (float or integer values)" instead of "row_mdata AND (numeric_mdata or discrete_mdata)"
    def format_valid_types(valid_types)
      return nil if valid_types.blank?
      
      # Build data class cache if not already cached
      @data_class_cache ||= begin
        cache = {}
        DataClass.all.each do |dc|
          cache[dc.name] = { template: dc.label_template, category: dc.category }
        end
        cache
      end
      
      # Get project type labels for template substitution (singularized for metadata)
      row_label = @project&.project_type&.row_label || 'rows'
      col_label = @project&.project_type&.col_label || 'columns'
      row_label_singular = row_label.singularize
      col_label_singular = col_label.singularize
      
      # Flatten all types and categorize them
      all_types = valid_types.flatten.uniq
      
      base_types = []      # e.g., row_mdata, col_mdata
      value_types = []     # e.g., numeric_mdata, string_mdata
      matrix_types = []    # e.g., num_matrix, int_matrix
      other_types = []     # everything else
      
      all_types.each do |type|
        dc_info = @data_class_cache[type]
        next if dc_info.nil? || dc_info[:category] == 'skip'
        
        case dc_info[:category]
        when 'base'
          base_types << type
        when 'value_type'
          value_types << type
        when 'matrix'
          matrix_types << type
        else
          other_types << type
        end
      end
      
      result_parts = []
      
      # Format base types with value types combined
      # e.g., "gene metadata (float values)" or "gene metadata (float or integer values)"
      if base_types.any?
        base_labels = base_types.map do |type|
          template = @data_class_cache[type][:template]
          template.gsub('{row_label_singular}', row_label_singular)
                  .gsub('{col_label_singular}', col_label_singular)
                  .gsub('{row_label}', row_label)
                  .gsub('{col_label}', col_label)
        end
        
        base_str = base_labels.size == 1 ? base_labels.first : "(#{base_labels.join(' or ')})"
        
        if value_types.any?
          value_labels = value_types.map { |type| @data_class_cache[type][:template] }
          value_str = value_labels.size == 1 ? value_labels.first : value_labels.join(' or ')
          result_parts << "#{base_str} (#{value_str} values)"
        else
          result_parts << base_str
        end
      elsif value_types.any?
        # Value types without base type (shouldn't happen often)
        value_labels = value_types.map { |type| @data_class_cache[type][:template] }
        value_str = value_labels.size == 1 ? value_labels.first : value_labels.join(' or ')
        result_parts << "metadata (#{value_str} values)"
      end
      
      # Format matrix types
      if matrix_types.any?
        matrix_labels = matrix_types.map { |type| @data_class_cache[type][:template] }
        matrix_str = matrix_labels.size == 1 ? matrix_labels.first : "(#{matrix_labels.join(' or ')})"
        result_parts << matrix_str
      end
      
      # Format other types
      other_types.each do |type|
        template = @data_class_cache[type][:template]
        if template
          result_parts << template.gsub('{row_label_singular}', row_label_singular)
                                  .gsub('{col_label_singular}', col_label_singular)
                                  .gsub('{row_label}', row_label)
                                  .gsub('{col_label}', col_label)
        end
      end
      
      return nil if result_parts.empty?
      
      result_parts.join(' AND ')
    end
    
    # Get all available annotations in the project
    # This checks ALL annotations, not just from successful runs
    def get_available_annotations_for_project
      # Get all annotations for this project
      # Include run association for later filtering by step
      Annot.where(project_id: @project.id)
           .includes(:run)
           .all
    end
    
    # Check if a std_method has all required parameters satisfied
    def std_method_has_all_requirements?(step, std_method, available_annots)
      # Use Basic.get_std_method_attrs to get properly combined attributes
      # This method handles the combination of step.attrs_json, step.method_attrs_json,
      # std_method.attrs_json, and std_method.obj_attrs_json correctly
      begin
        h_res = Basic.get_std_method_attrs(std_method, step)
        combined_attrs = h_res[:h_attrs] || {}
      rescue => e
        Rails.logger.error("[std_method_has_all_requirements] Error calling get_std_method_attrs: #{e.message}")
        # Fallback to manual combination
        step_attrs = Basic.safe_parse_json(step.attrs_json, {})
        method_attrs = Basic.safe_parse_json(std_method.attrs_json, {})
        method_obj_attrs = Basic.safe_parse_json(std_method.obj_attrs_json, {})
        combined_attrs = step_attrs.deep_merge(method_attrs).deep_merge(method_obj_attrs)
      end
      
      # Debug logging for project 69560
      if @project.id == 69560 && step.name == 'normalization'
        Rails.logger.info("[DEBUG] Checking normalization step for project #{@project.id}")
        Rails.logger.info("[DEBUG] Step attrs_json: #{step.attrs_json}")
        Rails.logger.info("[DEBUG] StdMethod #{std_method.id} (#{std_method.name}) attrs_json: #{std_method.attrs_json}")
        Rails.logger.info("[DEBUG] StdMethod #{std_method.id} obj_attrs_json: #{std_method.obj_attrs_json}")
        Rails.logger.info("[DEBUG] Combined attrs: #{combined_attrs.to_json}")
        Rails.logger.info("[DEBUG] Available annotations count: #{available_annots.count}")
      end
      
      # Get data classes hash for lookup
      h_data_classes = {}
      DataClass.all.each { |dc| h_data_classes[dc.id] = dc; h_data_classes[dc.name] = dc }
      
      # Get steps by name for lookup - use steps from project's docker_image_id
      asap_docker_image = Basic.get_asap_docker(@project.version)
      h_steps_by_name = {}
      if asap_docker_image
        Step.where(docker_image_id: asap_docker_image.id).each { |s| h_steps_by_name[s.name] = s if s.respond_to?(:name) }
      end
      
      # Check each parameter that requires a dataset
      combined_attrs.each do |attr_name, attr_config|
        next unless attr_config.is_a?(Hash)
        next unless attr_config['source_steps'].present? && attr_config['valid_types'].present?
        
        source_steps = attr_config['source_steps']
        valid_types = attr_config['valid_types']
        
        # Debug logging for project 69560
        if @project.id == 69560 && step.name == 'normalization'
          Rails.logger.info("[DEBUG] Checking parameter: #{attr_name}")
          Rails.logger.info("[DEBUG] Source steps: #{source_steps.inspect}")
          Rails.logger.info("[DEBUG] Valid types: #{valid_types.inspect}")
        end
        
        # Get source step IDs from the project's docker_image_id
        source_step_ids = source_steps.map { |ssn| h_steps_by_name[ssn]&.id }.compact
        
        if @project.id == 69560 && step.name == 'normalization'
          Rails.logger.info("[DEBUG] Source step names: #{source_steps.inspect}")
          Rails.logger.info("[DEBUG] Source step IDs: #{source_step_ids.inspect}")
          source_steps.each do |ssn|
            step_obj = h_steps_by_name[ssn]
            Rails.logger.info("[DEBUG] Step '#{ssn}': #{step_obj ? "found (id=#{step_obj.id})" : 'NOT FOUND'}")
          end
        end
        
        next if source_step_ids.empty? # Skip if source steps don't exist
        
        # Filter annotations to only those from source steps
        # Match by step ID from the project's docker_image_id
        source_annots = available_annots.select do |annot|
          # Check step_id directly
          if annot.step_id && source_step_ids.include?(annot.step_id)
            true
          # Check ori_step_id
          elsif annot.ori_step_id && source_step_ids.include?(annot.ori_step_id)
            true
          else
            # Otherwise check the run's step_id
            annot_run = if annot.run_id && annot.run
                          annot.run
                        elsif annot.ori_run_id
                          Run.find_by(id: annot.ori_run_id)
                        else
                          nil
                        end
            
            annot_run && source_step_ids.include?(annot_run.step_id)
          end
        end
        
        if @project.id == 69560 && step.name == 'normalization'
          Rails.logger.info("[DEBUG] Source annotations count: #{source_annots.count}")
          source_annots.first(5).each do |annot|
            Rails.logger.info("[DEBUG]   Annot #{annot.id}: step_id=#{annot.step_id}, run_id=#{annot.run_id}, ori_run_id=#{annot.ori_run_id}, data_class_ids=#{annot.data_class_ids}")
          end
        end
        
        # Check if any annotation matches valid_types requirement
        # valid_types is an array of arrays: [["dataset"], ["num_matrix", "int_matrix"]]
        # Inner arrays are OR conditions, outer array elements are AND conditions
        has_valid_dataset = source_annots.any? do |annot|
          next false unless annot.data_class_ids.present?
          
          # Get data class names for this annotation
          annot_data_class_names = annot.data_class_ids.split(',').map do |dc_id|
            h_data_classes[dc_id.to_i]&.name
          end.compact
          
          if @project.id == 69560 && step.name == 'normalization' && source_annots.index(annot) < 3
            Rails.logger.info("[DEBUG]   Checking annot #{annot.id}: data_class_names=#{annot_data_class_names.inspect}")
          end
          
          # Check if annotation matches valid_types requirement
          # Each inner array is OR, outer array elements are AND
          matches = valid_types.all? do |or_group|
            # At least one type in the OR group must match
            or_group.any? { |valid_type| annot_data_class_names.include?(valid_type) }
          end
          
          if @project.id == 69560 && step.name == 'normalization' && source_annots.index(annot) < 3
            Rails.logger.info("[DEBUG]   Matches: #{matches}")
          end
          
          matches
        end
        
        if @project.id == 69560 && step.name == 'normalization'
          Rails.logger.info("[DEBUG] Has valid dataset for #{attr_name}: #{has_valid_dataset}")
        end
        
        # If this required parameter doesn't have a matching dataset, this std_method is not available
        return false unless has_valid_dataset
      end
      
      # All required parameters have matching datasets
      if @project.id == 69560 && step.name == 'normalization'
        Rails.logger.info("[DEBUG] StdMethod #{std_method.id} (#{std_method.name}) PASSED all requirements")
      end
      true
    end
    
    # Check if a std_method has all required parameters satisfied AND return which source steps are missing
    # Returns: [has_all_requirements (boolean), missing_requirements (array of hashes with step and types info)]
    def std_method_requirements_with_reason(step, std_method, available_annots, h_steps_by_name)
      begin
        h_res = Basic.get_std_method_attrs(std_method, step)
        combined_attrs = h_res[:h_attrs] || {}
      rescue => e
        Rails.logger.error("[std_method_requirements_with_reason] Error calling get_std_method_attrs: #{e.message}")
        step_attrs = Basic.safe_parse_json(step.attrs_json, {})
        method_attrs = Basic.safe_parse_json(std_method.attrs_json, {})
        method_obj_attrs = Basic.safe_parse_json(std_method.obj_attrs_json, {})
        combined_attrs = step_attrs.deep_merge(method_attrs).deep_merge(method_obj_attrs)
      end
      
      # Get data classes hash for lookup
      h_data_classes = {}
      DataClass.all.each { |dc| h_data_classes[dc.id] = dc; h_data_classes[dc.name] = dc }
      
      missing_requirements = []
      
      # Check each parameter that requires a dataset
      combined_attrs.each do |attr_name, attr_config|
        next unless attr_config.is_a?(Hash)
        
        # Check for source_steps - if present, this parameter requires input from another step
        next unless attr_config['source_steps'].present?
        
        source_steps = attr_config['source_steps']
        valid_types = attr_config['valid_types'] || []
        
        # Get source step IDs from the project's docker_image_id
        source_step_ids = source_steps.map { |ssn| h_steps_by_name[ssn]&.id }.compact
        
        # If source steps don't exist, this is a missing requirement
        if source_step_ids.empty?
          missing_requirements << {
            steps: source_steps,
            valid_types: valid_types  # Store raw array for later formatting with templates
          }
          next
        end
        
        # Filter annotations to only those from source steps
        source_annots = available_annots.select do |annot|
          if annot.step_id && source_step_ids.include?(annot.step_id)
            true
          elsif annot.ori_step_id && source_step_ids.include?(annot.ori_step_id)
            true
          else
            annot_run = if annot.run_id && annot.run
                          annot.run
                        elsif annot.ori_run_id
                          Run.find_by(id: annot.ori_run_id)
                        else
                          nil
                        end
            annot_run && source_step_ids.include?(annot_run.step_id)
          end
        end
        
        # If no valid_types specified, just check if any annotations exist from source steps
        if valid_types.blank?
          unless source_annots.any?
            missing_requirements << {
              steps: source_steps,
              valid_types: []  # Empty array means any data
            }
          end
          next
        end
        
        # Check if any annotation matches valid_types requirement
        has_valid_dataset = source_annots.any? do |annot|
          next false unless annot.data_class_ids.present?
          
          annot_data_class_names = annot.data_class_ids.split(',').map do |dc_id|
            h_data_classes[dc_id.to_i]&.name
          end.compact
          
          valid_types.all? do |or_group|
            or_group.any? { |valid_type| annot_data_class_names.include?(valid_type) }
          end
        end
        
        # If this required parameter doesn't have a matching dataset, track the missing requirement
        unless has_valid_dataset
          missing_requirements << {
            steps: source_steps,
            valid_types: valid_types  # Store raw array for later formatting with templates
          }
        end
      end
      
      has_all = missing_requirements.empty?
      [has_all, missing_requirements]
    end

    def prepare_steps_with_status
      # Get steps hash
      @h_steps = {}
      Step.all.each do |step|
        @h_steps[step.id] = step
      end
      
      # Get statuses hash for looking up status names
      @h_statuses ||= {}
      Status.all.each { |s| @h_statuses[s.id] = s } if @h_statuses.empty?
      
      # Get project steps for availability checking
      @project_steps_hash = {}
      ProjectStep.where(project_id: @project.id).each do |ps|
        @project_steps_hash[ps.step_id] = ps
      end
      
      # Get all steps for this project's docker image, ordered by rank
      asap_docker_image = Basic.get_asap_docker(@project.version)
      @all_project_steps = if asap_docker_image
                             Step.where(docker_image_id: asap_docker_image.id)
                                 .where.not(hidden: true)
                                 .order(:rank, :name)
                           else
                             Step.none
                           end
      
      # Filter to pretreatment group steps (steps with group_name 'pretreatment' or blank/null)
      # Sort by rank to ensure proper order
      # If no pretreatment steps found, show all steps (fallback)
      @pretreatment_steps = @all_project_steps.select { |s| s.group_name == 'pretreatment' || s.group_name.blank? || s.group_name.nil? }
                                             .sort_by { |s| [s.rank || 9999, s.name] }
      
      # Fallback: if no pretreatment steps found, use all steps
      if @pretreatment_steps.empty?
        Rails.logger.warn("[ProjectsController] No pretreatment steps found, using all steps")
        @pretreatment_steps = @all_project_steps.sort_by { |s| [s.rank || 9999, s.name] }
      end
      
      # Filter steps based on project type
      # Steps can have a project_types array in attrs_json that specifies which project types they apply to
      # If project_types is empty or missing, the step applies to all project types (backward compatibility)
      # Also check std_methods - if ALL std_methods for a step require a different project type, exclude the step
      asap_docker_image = Basic.get_asap_docker(@project.version)
      
      if @project.project_type
        project_type_name = @project.project_type.name
        project_type_tag = @project.project_type.tag
        
        @pretreatment_steps = @pretreatment_steps.select do |step|
          # First check step-level project_types
          step_attrs = Basic.safe_parse_json(step.attrs_json, {})
          step_project_types = step_attrs['project_types']
          
          # If step has explicit project_types and doesn't match, exclude it
          if step_project_types.present?
            step_matches = step_project_types.include?(project_type_name) || 
                          (project_type_tag.present? && step_project_types.include?(project_type_tag))
            next false unless step_matches
          end
          
          # Check if any std_method for this step matches the project type
          # If all std_methods are restricted to other project types, exclude the step
          if asap_docker_image
            std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, step_id: step.id, obsolete: false)
            
            if std_methods.any?
              # Check if at least one method matches the project type
              has_matching_method = std_methods.any? do |std_method|
                method_obj_attrs = Basic.safe_parse_json(std_method.obj_attrs_json, {})
                method_project_types = method_obj_attrs["project_types"] || []
                
                # Method matches if it has no project_types restriction OR matches the current project type
                method_project_types.empty? || 
                  method_project_types.include?(project_type_name) || 
                  (project_type_tag.present? && method_project_types.include?(project_type_tag))
              end
              
              next false unless has_matching_method
            end
          end
          
          true
        end
        
        Rails.logger.info("[ProjectsController] After project type filtering (#{project_type_name}): #{@pretreatment_steps.count} steps")
      else
        Rails.logger.info("[ProjectsController] No project type set, including all steps")
      end
      
      Rails.logger.info("[ProjectsController] Found #{@pretreatment_steps.count} steps for project #{@project.id}")
      Rails.logger.info("[ProjectsController] Steps: #{@pretreatment_steps.map { |s| "#{s.name} (rank: #{s.rank}, group: #{s.group_name})" }.join(', ')}")
      
      # Get successful runs for checking input requirements
      successful_runs = @runs.select { |r| r.status_id == 3 } # status_id 3 = complete/success
      
      # Determine step availability: a step is available if all previous steps (by rank) are complete
      # AND if all required inputs (from attrs_json) are available
      @steps_with_status = []
      @current_step_info = nil
      
      # Find parsing step index to filter out steps before it
      parsing_step_index = @pretreatment_steps.index { |s| s.name == 'parsing' }
      
      # Check if the parsing method restricts which downstream steps are allowed
      # (e.g. the "integration" method may set allowed_downstream_steps: ["umap", "clustering"])
      @parsing_method_allowed_steps = nil
      if parsing_step_index
        parsing_step = @pretreatment_steps[parsing_step_index]
        parsing_runs = @runs.select { |r| r.step_id == parsing_step.id && r.status_id == 3 }
        latest_parsing_run = parsing_runs.max_by(&:created_at)
        if latest_parsing_run&.std_method_id
          parsing_std_method = StdMethod.find_by(id: latest_parsing_run.std_method_id)
          if parsing_std_method
            method_obj_attrs = Basic.safe_parse_json(parsing_std_method.obj_attrs_json, {})
            @parsing_method_allowed_steps = method_obj_attrs['allowed_downstream_steps']
          end
        end
      end
      
      # Filter to only show steps from parsing onwards
      steps_to_show = if parsing_step_index
                        @pretreatment_steps[parsing_step_index..-1]
                      else
                        @pretreatment_steps
                      end
      
      steps_to_show.each_with_index do |step, adjusted_index|
        project_step = @project_steps_hash[step.id]
        # Use the run's status_id directly, not project_step status_id
        # Get the most recent run for this step (to show current/active status), or fall back to project_step if no run exists
        step_runs = @runs.select { |r| r.step_id == step.id }
        if step_runs.any?
          # Use the most recent run's status (to show current/active status)
          status_id = step_runs.max_by(&:created_at)&.status_id
        else
          status_id = project_step&.status_id
        end
        
        # Check if all previous steps (by rank) are complete
        # Previous steps are those with lower rank, or same rank but earlier in the list
        # Only consider steps from parsing onwards
        previous_steps = steps_to_show[0...adjusted_index]
        all_previous_complete = previous_steps.all? do |prev_step|
          # Check runs first (more accurate), then fall back to ProjectStep
          prev_step_runs = @runs.select { |r| r.step_id == prev_step.id }
          if prev_step_runs.any?
            # Use the most recent run's status
            prev_status_id = prev_step_runs.max_by(&:created_at)&.status_id
            prev_status_id == 3 # 3 = complete
          else
            # Fall back to ProjectStep status
            prev_ps = @project_steps_hash[prev_step.id]
            prev_ps && prev_ps.status_id == 3 # 3 = complete
          end
        end
        
        # Get previous steps with status for input requirement checking
        previous_steps_with_status = @steps_with_status.select { |s| previous_steps.include?(s[:step]) }
        
        # Step is available if:
        # 1. It's the parsing step (first after filtering), OR
        # 2. At least one std_method has all required inputs available (based on Annot instances)
        # We don't check previous step completion - only check if required datasets are available
        unlock_result = if adjusted_index == 0
                          { unlocked: true, reason: nil } # Parsing step is always available
                        else
                          step_unlock_status(step, previous_steps_with_status, successful_runs)
                        end
        is_available = unlock_result[:unlocked]
        lock_reason = unlock_result[:reason]
        
        # Current step is the first incomplete step that is available
        # Only set current if we haven't found one yet
        is_current = false
        if !@current_step_info && is_available && status_id != 3
          is_current = true
          @current_step_info = {
            step: step,
            project_step: project_step,
            status_id: status_id,
            index: adjusted_index
          }
        end
        
        # Count runs by status for this step
        status_counts = {
          waiting: step_runs.count { |r| r.status_id == 1 },
          running: step_runs.count { |r| r.status_id == 2 },
          completed: step_runs.count { |r| r.status_id == 3 },
          failed: step_runs.count { |r| r.status_id == 4 }
        }
        
        @steps_with_status << {
          step: step,
          project_step: project_step,
          status_id: status_id,
          status: status_id.present? && @h_statuses[status_id] ? @h_statuses[status_id].name : 'not_started',
          is_available: is_available,
          lock_reason: lock_reason,
          is_current: is_current,
          is_complete: (status_id == 3),
          status_counts: status_counts
        }
      end
      
      # Find the current step
      @current_step = @current_step_info ? @current_step_info[:step] : nil
    end

    def available_versions
      # Show all versions (activated or not, including beta) if admin, otherwise only activated versions
      # Matching original logic: admins see all versions, regular users see only activated
      if admin?
        Version.where("id > 3").order(id: :desc)
      else
        Version.where(activated: true).where("id > 3").order(id: :desc)
      end
    end

    def build_best_cla_category_map(categorical_metadata)
      @best_clas_by_metadata_category = {}
      return if categorical_metadata.blank?

      metadata_by_id = categorical_metadata.index_by(&:id)
      annot_ids = metadata_by_id.keys

      annot_cell_sets = AnnotCellSet
                          .includes(:cell_set)
                          .where(project_id: @project.id, annot_id: annot_ids)

      cell_set_ids = annot_cell_sets.filter_map { |annot_cell_set| annot_cell_set.cell_set_id }.uniq
      cla_by_cell_set_id =
        if cell_set_ids.empty?
          {}
        else
          Cla.active.where(cell_set_id: cell_set_ids).group_by(&:cell_set_id)
        end

      annot_cell_sets.each do |annot_cell_set|
          metadata = metadata_by_id[annot_cell_set.annot_id]
          next unless metadata

          cell_set = annot_cell_set.cell_set
          next unless cell_set

        cla_candidates = cla_by_cell_set_id[cell_set.id]
        next if cla_candidates.blank?

        best_cla = cla_candidates.max_by { |cla| [cla_consensus_score(cla), cla.created_at&.to_i || 0] }
          next unless best_cla

          category_label = category_label_for(metadata, annot_cell_set.cat_idx, cell_set)
          next unless category_label.present?

          entry = build_best_cla_entry(best_cla).merge(
            category_label: category_label,
            nber_clas: cla_candidates.size
          )
          store_best_cla_entry(metadata.id, category_label, entry)
        end
    end

    def store_best_cla_entry(metadata_id, category_label, entry)
      normalized_key = normalize_category_key(category_label)
      @best_clas_by_metadata_category[metadata_id] ||= {}
      existing_entry = @best_clas_by_metadata_category[metadata_id][category_label] ||
                       @best_clas_by_metadata_category[metadata_id][normalized_key]
      return if existing_entry && existing_entry[:score] >= entry[:score]

      @best_clas_by_metadata_category[metadata_id][category_label] = entry
      @best_clas_by_metadata_category[metadata_id][normalized_key] = entry
    end

    def normalize_category_key(value)
      value.to_s.strip.downcase
    end

    def category_label_for(metadata, cat_idx, cell_set)
      label =
        category_label_from_cat_info(metadata, cat_idx) ||
        category_label_from_list_cat(metadata, cat_idx) ||
        category_label_from_categories_json(metadata, cat_idx) ||
        category_label_from_aliases(metadata, cat_idx) ||
        cell_set&.key

      label.present? ? label.to_s : nil
    end

    def category_label_from_cat_info(metadata, cat_idx)
      info = parse_json_field(metadata.cat_info_json)
      return unless info.is_a?(Array)

      cat_idx_int = cat_idx.to_i
      candidate = info.find do |item|
        next unless item.is_a?(Hash)
        idx_value = item['cat_idx'] || item['idx'] || item['index'] || item['i']
        idx_value.to_i == cat_idx_int
      end
      extract_category_label(candidate)
    end

    def category_label_from_list_cat(metadata, cat_idx)
      list = parse_json_field(metadata.list_cat_json)
      return unless list.is_a?(Array)

      value = list[cat_idx.to_i]
      extract_value_from_list_entry(value)
    end

    def category_label_from_categories_json(metadata, cat_idx)
      data = parse_json_field(metadata.categories_json)
      return if data.blank?

      if data.is_a?(Array)
        extract_value_from_list_entry(data[cat_idx.to_i])
      elsif data.is_a?(Hash)
        # cat_idx may be stored as key
        value = data[cat_idx.to_s] || data[cat_idx.to_i] || data[cat_idx.to_s.to_sym]
        if value.is_a?(Hash)
          extract_category_label(value)
        elsif value.present?
          value.to_s
        else
          # Fallback: if keys are category names, try index
          keys = data.keys
          extract_value_from_list_entry(keys[cat_idx.to_i])
        end
      end
    end

    def category_label_from_aliases(metadata, cat_idx)
      aliases = parse_json_field(metadata.cat_aliases_json)
      return if aliases.blank?

      if aliases.is_a?(Array)
        extract_value_from_list_entry(aliases[cat_idx.to_i])
      elsif aliases.is_a?(Hash)
        value = aliases[cat_idx.to_s] || aliases[cat_idx.to_i] || aliases[cat_idx.to_s.to_sym]
        value.present? ? value.to_s : nil
      end
    end

    def extract_category_label(hash)
      return unless hash.is_a?(Hash)
      %w[name label value cat category display text].each do |key|
        value = hash[key] || hash[key.to_sym]
        return value.to_s if value.present?
      end
      nil
    end

    def extract_value_from_list_entry(value)
      case value
      when Array
        value.first.to_s
      when Hash
        extract_category_label(value)
      else
        value.present? ? value.to_s : nil
      end
    end

    def parse_json_field(raw_value)
      return nil if raw_value.blank?
      JSON.parse(raw_value)
    rescue JSON::ParserError
      nil
    end

    def build_best_cla_entry(cla)
      {
        score: cla_consensus_score(cla),
        name: cla.name.presence || "Unnamed annotation",
        cell_ontology_term_ids: format_cla_list(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids),
        sorted_up_gene_ids: format_cla_list(cla.sorted_up_gene_ids),
        sorted_down_gene_ids: format_cla_list(cla.sorted_down_gene_ids)
      }
    end

    def cla_consensus_score(cla)
      (cla.nber_agree || 0) - (cla.nber_disagree || 0)
    end

    def format_cla_list(raw_value, limit: 5)
      list = parse_cla_field(raw_value)
      return nil if list.empty?

      display = list.first(limit)
      text = display.join(", ")
      text += "…" if list.length > limit
      text
    end

    def parse_cla_field(value)
      return [] if value.blank?

      text = value.to_s.strip
      return [] if text.blank?

      candidates = []

      begin
        parsed = JSON.parse(text)
        case parsed
        when Array
          candidates = parsed
        when Hash
          candidates = parsed.values
        else
          candidates = [parsed]
        end
      rescue JSON::ParserError
        normalized = text.tr("[]{}", "")
        candidates = normalized.split(/[\s,;|]+/)
      end

      candidates.map { |item| item.to_s.strip }.reject(&:blank?)
    end

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
      
      # Check if "users" is already in USER_DATA_DIR to avoid double "users"
      user_data_dir = ENV["USER_DATA_DIR"].to_s.chomp('/')
      base_dir = user_data_dir.end_with?("/users") || user_data_dir.end_with?("users") ? Pathname.new(user_data_dir) : Pathname.new(user_data_dir) + "users"
      @project_dir = base_dir + @project.user_id.to_s + @project.key
    end

    # Only allow a list of trusted parameters through.
    def project_params
      params.fetch(:project, {}).permit(
        :name, :key, :description, :organism_id, :project_type_id, 
        :version_id, :step_id, :status_id, :technology, :tissue, :extra_info, :input_filename,
        :parsing_attrs_json, :nber_cols, :nber_rows, :extension, :fu_id
      )
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
    
    # Generate klay data for pipeline visualization (runs only)
    def generate_klay_data
      data = []
      
      # Only include runs that exist
      return data if @runs.blank?
      
      # Group runs by step for better organization
      runs_by_step = @runs.group_by(&:step_id)
      
      # Add nodes for each run
      @runs.each do |run|
        step = @h_steps[run.step_id]
        
        # Create label: #run_number std_method_name (only show #run_number if multiple_runs == true)
        label_parts = []
        
        # Add run number only if step has multiple_runs enabled
        if step && step.multiple_runs
          if run.num
            label_parts << "##{run.num}"
          elsif run.id
            label_parts << "##{run.id}"
          end
        end
        
        # Add std_method name
        if run.std_method && run.std_method.name.present?
          label_parts << run.std_method.name
        elsif step
          # Fallback to step name if no std_method
          label_parts << (step.label.presence || step.name)
        else
          label_parts << "Run #{run.id}"
        end
        
        label = label_parts.join(' ')
        
        data << {
          data: {
            id: "run_#{run.id}",
            label: label,
            color: get_step_color(run.step_id),
            run_id: run.id,
            step_id: run.step_id
          }
        }
      end
      
      # Create a hash of run IDs for quick lookup
      run_ids_set = @runs.map(&:id).to_set
      
      # Add edges based on run_parents_json (most reliable source)
      edges_added = false
      @runs.each do |run|
        next if run.run_parents_json.blank?
        
        begin
          parents = Basic.safe_parse_json(run.run_parents_json, [])
          if parents.is_a?(Array) && parents.any?
            parents.each do |parent|
              parent_id = parent.is_a?(Hash) ? parent[:run_id] || parent['run_id'] : parent
              parent_id = parent_id.to_i if parent_id
              
              # Check if parent run exists in our runs list
              if parent_id && run_ids_set.include?(parent_id)
                data << {
                  data: {
                    id: "edge_#{parent_id}_#{run.id}",
                    source: "run_#{parent_id}",
                    target: "run_#{run.id}"
                  }
                }
                edges_added = true
              end
            end
          end
        rescue => e
          Rails.logger.warn("Error parsing run_parents_json for run #{run.id}: #{e.message}")
        end
      end
      
      # Fallback to pipeline_parent_run_ids if run_parents_json didn't provide edges
      if !edges_added
        @runs.each do |run|
          next if run.pipeline_parent_run_ids.blank?
          
          parent_ids = run.pipeline_parent_run_ids.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
          parent_ids.each do |parent_id|
            # Check if parent run exists in our runs list
            if run_ids_set.include?(parent_id)
              data << {
                data: {
                  id: "edge_#{parent_id}_#{run.id}",
                  source: "run_#{parent_id}",
                  target: "run_#{run.id}"
                }
              }
              edges_added = true
            end
          end
        end
      end
      
      # If still no edges, create edges based on step order and run creation time
      if !edges_added
        # Group runs by step and sort by step rank, then by creation time
        runs_by_step_id = runs_by_step.keys.sort_by { |step_id| @h_steps[step_id]&.rank || 9999 }
        
        runs_by_step_id.each_with_index do |step_id, index|
          next if index == 0
          
          prev_step_id = runs_by_step_id[index - 1]
          prev_runs = (runs_by_step[prev_step_id] || []).sort_by { |r| [r.created_at || Time.at(0), r.id] }
          current_runs = (runs_by_step[step_id] || []).sort_by { |r| [r.created_at || Time.at(0), r.id] }
          
          # Connect each run from previous step to corresponding run in current step
          # If multiple runs, connect in order
          max_runs = [prev_runs.length, current_runs.length].max
          max_runs.times do |i|
            prev_run = prev_runs[i] || prev_runs.last
            current_run = current_runs[i] || current_runs.first
            
            if prev_run && current_run
              edge_id = "edge_#{prev_run.id}_#{current_run.id}"
              # Avoid duplicate edges
              unless data.any? { |item| item[:data][:id] == edge_id }
                data << {
                  data: {
                    id: edge_id,
                    source: "run_#{prev_run.id}",
                    target: "run_#{current_run.id}"
                  }
                }
              end
            end
          end
        end
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
    
    # Prepare data for cell filtering form
    def prepare_cell_filtering_data
      Rails.logger.info("[prepare_cell_filtering_data] Starting for project #{@project.id}")
      
      # Get the docker image for this project
      asap_docker_image = Basic.get_asap_docker(@project.version)
      Rails.logger.info("[prepare_cell_filtering_data] Docker image: #{asap_docker_image&.id || 'not found'}, version: #{@project.version}")
      
      if asap_docker_image.nil?
        @parsing_run = nil
        Rails.logger.error("[prepare_cell_filtering_data] No docker image found for project version #{@project.version}")
        return
      end
      
      # Find the parsing step for this docker image
      parsing_step = Step.where(name: 'parsing', docker_image_id: asap_docker_image.id).first
      Rails.logger.info("[prepare_cell_filtering_data] Parsing step: #{parsing_step&.id || 'not found'} for docker_image_id=#{asap_docker_image.id}")
      
      if parsing_step
        # Query directly using Run model
        all_parsing_runs = Run.where(project_id: @project.id, step_id: parsing_step.id).order(created_at: :desc)
        Rails.logger.info("[prepare_cell_filtering_data] Found #{all_parsing_runs.count} parsing runs for project_id=#{@project.id}, step_id=#{parsing_step.id}")
        
        # Get the most recent completed parsing run (status_id == 3)
        completed_run = all_parsing_runs.where(status_id: 3).first
        @parsing_run = completed_run || all_parsing_runs.first
        
        Rails.logger.info("[prepare_cell_filtering_data] Selected parsing run: #{@parsing_run&.id || 'not found'}, status: #{@parsing_run&.status_id}")
      else
        @parsing_run = nil
        Rails.logger.warn("[prepare_cell_filtering_data] Parsing step not found for docker_image_id=#{asap_docker_image.id}")
      end
      
      # Get other filtering runs for metadata selection (using the same docker image)
      cell_filtering_step = Step.where(name: 'cell_filtering', docker_image_id: asap_docker_image.id).first
      gene_filtering_step = Step.where(name: 'gene_filtering', docker_image_id: asap_docker_image.id).first
      
      @cell_filtering_runs = []
      @gene_filtering_runs = []
      if cell_filtering_step
        @cell_filtering_runs = Run.where(project_id: @project.id, step_id: cell_filtering_step.id).order(created_at: :desc).to_a
      end
      if gene_filtering_step
        @gene_filtering_runs = Run.where(project_id: @project.id, step_id: gene_filtering_step.id).order(created_at: :desc).to_a
      end
      
      # Get annotations for metadata filtering
      store_run_id = @parsing_run&.id
      @annots = Annot.where(project_id: @project.id, store_run_id: store_run_id, data_type_id: 3, dim: 1).all if store_run_id
      @annots ||= []
      
      @h_annots = {}
      @h_annot_runs = {}
      @annots.each { |a| @h_annots[a.id] = { name: a.name } }
      annot_run_ids = @annots.map(&:run_id).compact.uniq
      Run.where(id: annot_run_ids).each { |r| @h_annot_runs[r.id] = r } if annot_run_ids.any?
      
      # Prepare QC data from parsing output
      @h_float = { "mito" => 1, "ribo" => 1, "protein_coding" => 1 }
      @h_data = {}
      @h_data_json = nil
      
      if @parsing_run
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
        loom_file = project_dir + 'parsing' + 'output.loom'
        compressed_zip_annot_json_file = project_dir + 'parsing' + 'compressed_zip_annot.json'
        
        # Generate QC data file if it doesn't exist or is invalid
        # First try to load existing file to check if it's valid
        if File.exist?(compressed_zip_annot_json_file) && File.size(compressed_zip_annot_json_file) > 2
          if @project.nber_cols && @project.nber_cols > 20000
            @h_data_json = File.read(compressed_zip_annot_json_file)
          else
            loaded_data = Basic.safe_parse_json(File.read(compressed_zip_annot_json_file), {})
            @h_data = loaded_data if loaded_data.is_a?(Hash) && !loaded_data.empty?
          end
        end
        
        # Generate if file doesn't exist or doesn't have all 5 metrics
        file_exists = File.exist?(compressed_zip_annot_json_file)
        file_valid = false
        if file_exists
          begin
            file_valid = File.size(compressed_zip_annot_json_file) > 2
          rescue => e
            Rails.logger.warn("[prepare_cell_filtering_data] Error checking file size: #{e.message}")
            file_valid = false
          end
        end
        data_valid = @h_data && @h_data.keys.size == 5
        
        if !file_valid || !data_valid
          Rails.logger.info("[prepare_cell_filtering_data] Generating QC data file from LOOM file")
          
          if File.exist?(loom_file)
            # Use H5DataService to extract metadata (runs in docker container)
            begin
              h_cmd = {
                "depth" => H5DataService.asap_command('-T', 'ExtractMetadata', '-loom', loom_file.to_s, '-meta', '/col_attrs/_Depth'),
                "ribo" => H5DataService.asap_command('-T', 'ExtractMetadata', '-prec', '1', '-loom', loom_file.to_s, '-meta', '/col_attrs/_Ribosomal_Content'),
                "mito" => H5DataService.asap_command('-T', 'ExtractMetadata', '-prec', '1', '-loom', loom_file.to_s, '-meta', '/col_attrs/_Mitochondrial_Content'),
                "detected_genes" => H5DataService.asap_command('-T', 'ExtractMetadata', '-loom', loom_file.to_s, '-meta', '/col_attrs/_Detected_Genes'),
                "protein_coding" => H5DataService.asap_command('-T', 'ExtractMetadata', '-prec', '1', '-loom', loom_file.to_s, '-meta', '/col_attrs/_Protein_Coding_Content')
              }
              
              File.open(compressed_zip_annot_json_file, "w", encoding: 'ascii-8bit') do |fw|
                h_cmd.each_key do |k|
                  begin
                    stdout, stderr, status = Open3.capture3(*h_cmd[k])
                    if status.success? && !stdout.empty?
                      tmp_json = stdout.gsub(/\n/, '').encode('ASCII', :replace => '0')
                      parsed_data = Basic.safe_parse_json(tmp_json, {})
                      if parsed_data['values'] && parsed_data['values'].is_a?(Array)
                        # Convert values: multiply by 10 for float types, then pack as shorts
                        values = parsed_data['values'].map { |e| (@h_float[k] == 1) ? (e * 10).to_i : e.to_i }
                        packed = values.pack("S*")
                        compressed = Zlib::Deflate.deflate(packed)
                        encoded = Base64.encode64(compressed).gsub("\n", "")
                        @h_data[k] = {'values' => encoded}
                        Rails.logger.info("[prepare_cell_filtering_data] Extracted #{values.length} values for #{k}")
                      end
                    else
                      Rails.logger.warn("[prepare_cell_filtering_data] Failed to extract #{k}: #{stderr}")
                    end
                  rescue => e
                    Rails.logger.error("[prepare_cell_filtering_data] Error extracting #{k}: #{e.message}")
                  end
                end
                fw.write(@h_data.to_json)
              end
              
              Rails.logger.info("[prepare_cell_filtering_data] QC data file generated with #{@h_data.keys.size} metrics")
            rescue => e
              Rails.logger.error("[prepare_cell_filtering_data] Error generating QC data: #{e.message}")
              Rails.logger.error("[prepare_cell_filtering_data] Backtrace: #{e.backtrace.first(5).join("\n")}")
            end
          else
            Rails.logger.warn("[prepare_cell_filtering_data] LOOM file not found: #{loom_file}")
          end
        end
        
        # Load compressed data if it exists (after generation attempt)
        if File.exist?(compressed_zip_annot_json_file) && File.size(compressed_zip_annot_json_file) > 2
          if @project.nber_cols && @project.nber_cols > 20000
            @h_data_json = File.read(compressed_zip_annot_json_file)
            Rails.logger.info("[prepare_cell_filtering_data] Loaded h_data_json (large dataset mode), size: #{@h_data_json.length}")
          else
            loaded_data = Basic.safe_parse_json(File.read(compressed_zip_annot_json_file), {})
            if loaded_data.is_a?(Hash) && !loaded_data.empty?
              @h_data = loaded_data
              Rails.logger.info("[prepare_cell_filtering_data] Loaded h_data with keys: #{@h_data.keys.inspect}, total keys: #{@h_data.keys.size}")
            else
              Rails.logger.warn("[prepare_cell_filtering_data] Failed to load h_data, got: #{loaded_data.class}")
            end
          end
        else
          Rails.logger.warn("[prepare_cell_filtering_data] QC data file doesn't exist or is too small: #{compressed_zip_annot_json_file}")
        end
      else
        Rails.logger.warn("[prepare_cell_filtering_data] No parsing run, cannot load QC data")
      end
      
      # Define filter parameters
      @list_p = [
        { name: "depth", attr_name: 'depth', type: :lower, threshold: 1000, label: "UMI/reads" },
        { name: "detected_genes", attr_name: 'detected_genes', type: :lower, threshold: 1000, label: "detected genes" },
        { name: "protein_coding", attr_name: 'protein_coding_content', type: :lower, threshold: 80, label: "% protein coding genes" },
        { name: "mito", attr_name: 'mito_content', type: :greater, threshold: 20, label: "% mitochondrial genes" },
        { name: "ribo", attr_name: 'ribo_content', type: :greater, threshold: 40, label: "% ribosomal genes" }
      ]
      
      @h_p = {}
      @list_p.each do |e|
        @h_p[e[:type]] ||= {}
        @h_p[e[:type]][e[:name]] = { threshold: e[:threshold] }
      end
      
      # Get standard method details if needed (optional for now)
      @std_method = nil
      @h_method_details = nil
      if @step
        @std_method = StdMethod.where(step_id: @step.id, obsolete: false).first
        # @h_method_details = get_attr(@step, @std_method) if @std_method
        # For now, we'll work without method details
      end
    end
    
    # Prepare data for standard dashboard and view
    def prepare_std_step_data
      # Get docker image and steps
      asap_docker_image = Basic.get_asap_docker(@project.version)
      unless asap_docker_image
        Rails.logger.warn("[prepare_std_step_data] No docker image found for version: #{@project.version}")
        return
      end
      
      # Get all steps for this docker image
      @h_steps = {}
      Step.where(docker_image_id: asap_docker_image.id).each { |s| @h_steps[s.id] = s }
      
      # Get statuses
      @h_statuses = {}
      Status.all.each { |s| @h_statuses[s.id] = s }
      
      # Get dashboard card configuration
      @h_dashboard_card = {}
      if @step.dashboard_card_json.present?
        @h_dashboard_card[@step.id] = Basic.safe_parse_json(@step.dashboard_card_json, {})
      end
      
      # Get step attributes
      @h_attrs = Basic.safe_parse_json(@step.attrs_json, {}) if @step.attrs_json.present?
      @h_attrs ||= {}
      
      # Determine if we should show dashboard, view, or form
      # Version 8+: only 1 run allowed, so show view directly if has_std_view
      # Before version 8: multiple runs possible, show dashboard if has_std_dashboard and multiple runs
      @show_dashboard = false
      @show_view = false
      @show_form = false
      @show_custom_form = false
      
      # Convert runs to array for consistent checking
      runs_array = @runs.to_a
      runs_count = runs_array.size
      
      Rails.logger.info("[prepare_std_step_data] Step: #{@step.name}, multiple_runs: #{@step.multiple_runs}, has_std_dashboard: #{@step.has_std_dashboard}, has_std_view: #{@step.has_std_view}, runs_count: #{runs_count}")
      
      # Check if show_form parameter is set (for "New run" button)
      force_show_form = params[:show_form].present? && params[:show_form].to_s == '1'
      
      # If show_form is requested and step has std_form, show form
      if force_show_form && @step.has_std_form
        @show_form = true
        prepare_std_form_data
      # For steps with only one run authorized (multiple_runs == false) that are just unlocked (no runs yet)
      elsif !@step.multiple_runs && runs_count == 0
        if @step.has_std_form
          # Show standard form if std_form option is activated
          @show_form = true
          prepare_std_form_data
        else
          # Show specific partial _<step_name>_form.html.erb if std_form == false
          @show_custom_form = true
        end
      # If no runs and has_std_form (for multiple_runs steps), show form
      elsif runs_count == 0 && @step.has_std_form
        @show_form = true
        prepare_std_form_data
      # When multiple_runs == true, has_std_dashboard == true, and at least one run exists, show standard dashboard
      elsif @step.multiple_runs && @step.has_std_dashboard && runs_count > 0
        Rails.logger.info("[prepare_std_step_data] Setting show_dashboard = true for step: #{@step.name}")
        @show_dashboard = true
        # Prepare dashboard data
        @h_cards = create_run_cards(runs_array, nil)
      # When multiple_runs == false, has_std_view == true, and at least one run exists, show standard view
      elsif !@step.multiple_runs && @step.has_std_view && runs_count > 0
        @show_view = true
        # Prepare view data for single run
        @run = runs_array.first
        if @run
          prepare_run_view_data(@run)
        end
      end
    end
    
    # Prepare data for standard form
    def prepare_std_form_data
      Rails.logger.info("[prepare_std_form_data] Called for step #{@step.id} (#{@step.name})")
      
      # Get docker image
      asap_docker_image = Basic.get_asap_docker(@project.version)
      unless asap_docker_image
        Rails.logger.error("[prepare_std_form_data] No docker image found for version #{@project.version}")
        @std_methods = []
        @h_unavailable_methods = {}
        @h_obj_attrs_by_std_method = {}
        @h_std_methods_by_name = {}
        return
      end
      
      # Get step attributes
      @h_step_attrs = Basic.safe_parse_json(@step.attrs_json, {}) if @step.attrs_json.present?
      @h_step_attrs ||= {}
      
      # Get standard methods for this step
      @h_std_methods = {}
      all_std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, obsolete: false).all
      all_std_methods.each { |s| @h_std_methods[s.id] = s }
      
      @std_methods = all_std_methods.select { |e| e.step_id == @step.id }.sort { |a, b| a.name <=> b.name }
      Rails.logger.info("[prepare_std_form_data] Found #{@std_methods.count} std_methods for step #{@step.id}")
      
      # Get steps by name for lookups - use steps from project's docker_image_id
      @h_steps ||= {}
      @h_steps_by_name = {}
      if asap_docker_image
        Step.where(docker_image_id: asap_docker_image.id).each { |s| @h_steps_by_name[s.name] = s if s.respond_to?(:name) }
      end
      # Also populate from @h_steps if it exists (for backward compatibility)
      @h_steps.each { |id, step| @h_steps_by_name[step.name] = step if step.respond_to?(:name) && !@h_steps_by_name[step.name] }
      
      # Get object attributes by standard method
      @h_obj_attrs_by_std_method = {}
      @std_methods.each { |s| @h_obj_attrs_by_std_method[s.id] = Basic.safe_parse_json(s.obj_attrs_json, {}) }
      
      # Get standard methods by name
      @h_std_methods_by_name = {}
      @std_methods.each { |s| @h_std_methods_by_name[s.name] = s }
      
      # Check available methods based on available annotations
      # Use the same logic as step unlocking - check if required datasets are available
      @h_unavailable_methods = {}
      
      # Get all available annotations in the project
      all_annots = Annot.where(project_id: @project.id).includes(:run).all
      
      # Get data classes for validation
      h_data_classes = {}
      DataClass.all.each { |dc| h_data_classes[dc.id] = dc; h_data_classes[dc.name] = dc }
      
      Rails.logger.info("[prepare_std_form_data] Checking #{@std_methods.count} std_methods for step #{@step.id} (#{@step.name})")
      Rails.logger.info("[prepare_std_form_data] h_steps_by_name count: #{@h_steps_by_name.count}")
      
      @std_methods.each do |std_method|
        # Use Basic.get_std_method_attrs to get properly combined attributes
        begin
          h_res = Basic.get_std_method_attrs(std_method, @step)
          combined_attrs = h_res[:h_attrs] || {}
        rescue => e
          Rails.logger.error("[prepare_std_form_data] Error calling get_std_method_attrs for method #{std_method.id}: #{e.message}")
          Rails.logger.error("[prepare_std_form_data] Error backtrace: #{e.backtrace.first(5).join("\n")}")
          # Fallback to obj_attrs_json only
          combined_attrs = @h_obj_attrs_by_std_method[std_method.id] || {}
        end
        
        # Check each parameter that requires a dataset
        combined_attrs.each do |attr_name, attr_config|
          next unless attr_config.is_a?(Hash)
          next unless attr_config['source_steps'].present? && attr_config['valid_types'].present?
          
          source_steps = attr_config['source_steps']
          valid_types = attr_config['valid_types']
          
          # Get source step IDs from project's docker_image_id
          source_step_ids = source_steps.map { |ssn| @h_steps_by_name[ssn]&.id }.compact
          next if source_step_ids.empty?
          
          # Filter annotations to only those from source steps
          source_annots = all_annots.select do |annot|
            if annot.step_id && source_step_ids.include?(annot.step_id)
              true
            elsif annot.ori_step_id && source_step_ids.include?(annot.ori_step_id)
              true
            else
              annot_run = if annot.run_id && annot.run
                            annot.run
                          elsif annot.ori_run_id
                            Run.find_by(id: annot.ori_run_id)
                          else
                            nil
                          end
              annot_run && source_step_ids.include?(annot_run.step_id)
            end
          end
          
          # Check if any annotation matches valid_types requirement
          has_valid_dataset = source_annots.any? do |annot|
            next false unless annot.data_class_ids.present?
            
            annot_data_class_names = annot.data_class_ids.split(',').map do |dc_id|
              h_data_classes[dc_id.to_i]&.name
            end.compact
            
            # Check if annotation matches valid_types requirement
            valid_types.all? do |or_group|
              or_group.any? { |valid_type| annot_data_class_names.include?(valid_type) }
            end
          end
          
          # If this required parameter doesn't have a matching dataset, mark method as unavailable
          unless has_valid_dataset
            @h_unavailable_methods[std_method.id] = true
            break # No need to check other parameters for this method
          end
        end
      end
      
      # Create a new Req object for the form
      @req = Req.new
    end
    
    # Prepare data for a single run view
    def prepare_run_view_data(run)
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
      step_dir = project_dir + @step.name
      output_dir = (@step.multiple_runs) ? (step_dir + run.id.to_s) : step_dir
      
      output_json_file = output_dir + "output.json"
      @h_res = {}
      @h_outputs = {}
      @h_run_attrs = {}
      
      begin
        @h_run_attrs = Basic.safe_parse_json(run.attrs_json, {}) if run.attrs_json.present?
        @h_res = Basic.safe_parse_json(File.read(output_json_file), {}) if File.exist?(output_json_file)
        @h_outputs = Basic.safe_parse_json(run.output_json, {}) if run.output_json.present? && run.output_json.match(/^\{/)
      rescue => e
        Rails.logger.error("[prepare_run_view_data] Error loading run data: #{e.message}")
      end
      
      # Get annotations
      @h_annots_by_dim = {}
      annots = Annot.where(run_id: run.id).all
      annots.each { |a| @h_annots_by_dim[a.dim] ||= []; @h_annots_by_dim[a.dim].push(a) }
      
      # Get standard method attributes
      @h_std_method_attrs = {}
      if run.std_method_id
        std_method = StdMethod.find_by(id: run.std_method_id)
        if std_method && std_method.attrs_json.present?
          @h_std_method_attrs = Basic.safe_parse_json(std_method.attrs_json, {})
        end
      end
      
      # Get layout from show_view_json
      @layout = []
      if @step.show_view_json.present?
        @layout = Basic.safe_parse_json(@step.show_view_json, [])
      end
      
      # Prepare element data (@h_el) for standard view
      @h_el = {}
      
      # Prepare files and links
      h_files = {}
      h_links = {}
      
      if @h_dashboard_card[@step.id] && @h_dashboard_card[@step.id]["output_links"]
        h_links = get_h_links(@h_outputs, @h_dashboard_card[@step.id]["output_links"])
      end
      
      if @h_dashboard_card[@step.id] && @h_dashboard_card[@step.id]["output_files"]
        list_p = @h_dashboard_card[@step.id]["output_files"]
        list_p.select { |e| @h_outputs && @h_outputs[e["key"]] && ((admin? || e["admin"] == true) || !e["admin"]) }.each do |e|
          k = e["key"]
          @h_outputs[k].keys.each do |output_key|
            t = output_key.split(":")
            h_files[t[0]] ||= {
              h_output: @h_outputs[k][output_key],
              datasets: []
            }
            h_files[t[0]][:datasets].push({ name: t[1], dataset_size: @h_outputs[k][output_key]['dataset_size'] }) if t.size > 1
          end
        end
      end
      
      # Build dataset results
      dataset_results = []
      h_dim = { 1 => 'Cell metadata', 2 => 'Gene metadata', 3 => 'Expression matrix', 4 => "Other" }
      @h_annots_by_dim.each_key do |dim|
        subtitle = h_dim[dim]
        subtitle = subtitle.pluralize if subtitle && @h_annots_by_dim[dim].size > 1 && dim > 2
        dataset_results.push "<h4>#{subtitle}</h4><p style='line-height:2.5em'>" +
          @h_annots_by_dim[dim].map { |annot|
            col_name = ([1, 3].include?(dim)) ? 'cell' : 'column'
            row_name = ([2, 3].include?(dim)) ? 'gene' : 'row'
            col_name = col_name.pluralize if annot.nber_cols && annot.nber_cols > 1
            row_name = row_name.pluralize if annot.nber_rows && annot.nber_rows > 1
            "<button id='annot_#{annot.id}_btn' class='btn btn-outline-secondary btn-sm annot_btn'>#{annot.name} <span class='badge badge-light'>#{annot.nber_cols} #{col_name}</span> <span class='badge badge-light'>#{annot.nber_rows} #{row_name}</span></button>"
          }.join(" ") + "</p>"
      end
      
      # Set standard card elements
      @h_el = {
        "card-params" => {
          card_header: 'Parameters',
          card_body: display_run_attrs(run, @h_run_attrs, @h_std_method_attrs, {})
        },
        "card-downloads" => {
          card_header: 'Downloads',
          card_body: ((h_files.keys.size > 0) ? ("<p class='card-text'>" + h_files.keys.map { |k| display_download_btn(run, h_files[k]) }.join(" ") + "</p>") : "")
        },
        "card-results" => {
          card_header: 'Results',
          card_body: ((run.status_id == 3 && @h_res['warnings']) ? @h_res['warnings'].map { |e|
            if e.is_a?(Hash)
              "<p class='text-warning text-truncate' title=\"#{e['name']}. #{e['description']}\">#{e['name']}</p>"
            else
              "<p class='text-warning text-truncate' title='#{e}'>#{e}</p>"
            end
          }.join(" ") : '') + dataset_results.join("<br/>\n")
        }
      }
    end
    
    # Create run cards for dashboard
    def create_run_cards(runs, sel_req_id)
      return { run_cards: [], req_cards: [] } if runs.empty?
      
      # Ensure @h_steps is set
      unless @h_steps
        asap_docker_image = Basic.get_asap_docker(@project.version)
        @h_steps = {}
        if asap_docker_image
          Step.where(docker_image_id: asap_docker_image.id).each { |s| @h_steps[s.id] = s }
        end
      end
      
      # Ensure @h_statuses is set
      unless @h_statuses
        @h_statuses = {}
        Status.all.each { |s| @h_statuses[s.id] = s }
      end
      
      # Ensure @h_dashboard_card is set
      unless @h_dashboard_card
        @h_dashboard_card = {}
        if @step && @step.dashboard_card_json.present?
          @h_dashboard_card[@step.id] = Basic.safe_parse_json(@step.dashboard_card_json, {})
        end
      end
      
      # Get standard method details
      std_method_ids = runs.map(&:std_method_id).compact.uniq
      @h_std_methods = {}
      StdMethod.where(id: std_method_ids).each { |m| @h_std_methods[m.id] = m }
      
      # Get users
      @h_users = {}
      user_ids = runs.map(&:user_id).compact.uniq
      User.where(id: user_ids).each { |u| @h_users[u.id] = u }
      
      run_cards = []
      runs.sort { |a, b| (b.created_at || Time.at(0)) <=> (a.created_at || Time.at(0)) }.each do |run|
        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
        step_dir = project_dir + @h_steps[run.step_id].name
        output_dir = (@h_steps[run.step_id].multiple_runs) ? (step_dir + run.id.to_s) : step_dir
        output_json_file = output_dir + "output.json"
        
        h_attrs = {}
        h_res = {}
        h_outputs = {}
        
        begin
          h_attrs = Basic.safe_parse_json(run.attrs_json, {}) if run.attrs_json.present?
          h_res = Basic.safe_parse_json(File.read(output_json_file), {}) if File.exist?(output_json_file)
          h_outputs = Basic.safe_parse_json(run.output_json, {}) if run.output_json.present? && run.output_json.match(/^\{/)
        rescue => e
          Rails.logger.error("[create_run_cards] Error loading data for run #{run.id}: #{e.message}")
        end
        
        # Prepare files
        h_files = {}
        if @h_dashboard_card && @h_dashboard_card[run.step_id] && @h_dashboard_card[run.step_id]["output_files"]
          list_p = @h_dashboard_card[run.step_id]["output_files"]
          list_p.select { |e| h_outputs && h_outputs[e["key"]] && ((admin? || e["admin"] == true) || !e["admin"]) }.each do |e|
            k = e["key"]
            h_outputs[k].keys.each do |output_key|
              t = output_key.split(":")
              h_files[t[0]] ||= {
                h_output: h_outputs[k][output_key],
                datasets: []
              }
              h_files[t[0]][:datasets].push({ name: t[1], dataset_size: h_outputs[k][output_key]['dataset_size'] }) if t.size > 1
            end
          end
        end
        
        # Get standard method attributes
        h_std_method_attrs = {}
        if run.std_method_id && @h_std_methods[run.std_method_id]
          std_method = @h_std_methods[run.std_method_id]
          if std_method.attrs_json.present?
            h_std_method_attrs = Basic.safe_parse_json(std_method.attrs_json, {})
          end
        end
        
        status_name = (@h_statuses[run.status_id] && @h_statuses[run.status_id].respond_to?(:name)) ? @h_statuses[run.status_id].name : 
                      (case run.status_id
                       when 1 then 'Waiting'
                       when 2 then 'Running'
                       when 3 then 'Completed'
                       when 4 then 'Failed'
                       else 'Unknown'
                       end)
        status_badge = case run.status_id
        when 1 then 'warning'
        when 2 then 'info'
        when 3 then 'success'
        when 4 then 'danger'
        else 'secondary'
        end
        
        run_time = (run.start_time && run.duration) ? (run.start_time + run.duration) : Time.now
        estimated_time_txt = (run.pred_process_duration) ? "Estimated #{duration(run.pred_process_duration)} - " : ''
        
        card_body = [
          "<p class='card-title'><span class='badge badge-#{status_badge}'>#{status_name}</span> #{display_run(run)}</p>",
          "<p class='sub-run_card'>Parameters</p>",
          display_run_attrs(run, h_attrs, h_std_method_attrs, {}),
          ((run.status_id == 3 && @h_dashboard_card && @h_dashboard_card[run.step_id] && @h_dashboard_card[run.step_id]["output_values"] && @h_dashboard_card[run.step_id]["output_values"].size > 0) ? ("<p class='sub-run_card'>Output summary</p><p class='card-text'>" + @h_dashboard_card[run.step_id]["output_values"].select { |e| h_res[e["key"]] }.map { |e| "<span class='badge badge-info'>#{e["label"]}:#{(h_res[e["key"]]) ? h_res[e["key"]] : 'NA'}</span>" }.join(" ") + "</p>") : ''),
          ((h_files.keys.size > 0) ? ("<p class='sub-run_card'>Results</p><p class='card-text'>" + h_files.keys.map { |k| display_download_btn(run, h_files[k]) }.join(" ") + "</p>") : ""),
          ((run.status_id == 3 && h_res['warnings']) ? h_res['warnings'].map { |e|
            if e.is_a?(Hash)
              "<p class='text-warning text-truncate' title=\"#{e['name']}. #{e['description']}\">#{e['name']}</p>"
            else
              "<p class='text-warning text-truncate' title='#{e}'>#{e}</p>"
            end
          }.join(" ") : ''),
          (([4, 5].include?(run.status_id) && h_res['displayed_error'].is_a?(Array)) ? ("<p class='card-text'>" + ((h_res['displayed_error']) ? h_res['displayed_error'].map { |e|
            help = (e && (e.match(/Probably out of RAM/) || e.match(/Not enough memory/))) ? "<a href='#{tutorial_home_index_path({ t: 'out_of_ram' })}'>Help</a>" : ''
            "<p class='text-danger text-truncate' title=\"#{e}\">#{e} <small>#{help}</small></p>"
          }.join(" ") : '') + "</p>") : '')
        ].join("")
        
        card_footer = "<small class='text-muted'>" +
          "##{run.id}, " +
          [
            "<span class='nowrap'>#{run.created_at&.strftime("%Y-%m-%d %H:%M") || 'N/A'}</span>",
            ((run.waiting_duration) ? "<span class='nowrap'>Wait #{duration(run.waiting_duration.to_i)}</span>" : ((run.status_id == 1) ? "<span id='ongoing_wait_#{run.id}' class='nowrap'>Wait #{duration((Time.now - (run.submitted_at || run.created_at)).to_i)}</span>" : nil)),
            ((run.duration && run.status_id != 2) ? "<span class='nowrap'>Run #{duration(run.duration.to_i)}</span>" : (([1, 2].include?(run.status_id)) ? "<br/>#{estimated_time_txt}<span id='ongoing_run_#{run.id}' class='nowrap'>Run #{duration((run.start_time) ? (Time.now - run.start_time).to_i : 0)}</span>" : nil)),
            ((run.max_ram) ? "<span class='nowrap'>Max. RAM #{display_mem(run.max_ram * 1000)}</span>" : nil),
            "created by #{(admin? && @h_users[run.user_id]) ? 'Admin' : (@h_users[run.user_id]&.email&.split(/\@/)&.first || 'Unknown')}"
          ].compact.join(", ") +
          "</small>"
        
        run_cards.push({
          card_id: "run_card_#{run.id}",
          card_class: "run_card",
          body: card_body,
          footer: card_footer
        })
      end
      
      { run_cards: run_cards, req_cards: [] }
    end
    
    # Helper method to get links from outputs
    def get_h_links(h_outputs, output_links_config)
      h_links = {}
      return h_links unless h_outputs && output_links_config
      
      output_links_config.each do |link_config|
        key = link_config["key"]
        if h_outputs[key]
          h_links[key] = h_outputs[key]
        end
      end
      
      h_links
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

    def render_run_panel_to_string(run, step)
      saved_ivars = {}
      %i[@run @step @std_method @status @h_run_attrs @h_std_method_attrs @h_dashboard_card
         @project_dir @h_res @h_outputs @h_steps @h_statuses @h_annots_by_dim @layout @h_el
         @h_annots_for_params @h_ori_runs_for_params @h_steps_for_params @asap_docker_image @ps].each do |ivar|
        saved_ivars[ivar] = instance_variable_get(ivar) if instance_variable_defined?(ivar)
      end

      begin
        @run = run
        @step = step
        @std_method = run.std_method

        asap_docker_image = Basic.get_asap_docker(@project.version)
        @asap_docker_image = asap_docker_image

        @ps = ProjectStep.find_by(project_id: @project.id, step_id: step.id)
        @status = Status.find_by(id: run.status_id)

        @h_run_attrs = run.attrs_json.present? ? Basic.safe_parse_json(run.attrs_json, {}) : {}

        @h_std_method_attrs = {}
        if @std_method && @step
          h_res = Basic.get_std_method_attrs(@std_method, @step)
          @h_std_method_attrs = h_res[:h_attrs] || {}
        elsif @std_method && @std_method.attrs_json.present?
          @h_std_method_attrs = Basic.safe_parse_json(@std_method.attrs_json, {})
        end

        @h_dashboard_card = {}
        if step.dashboard_card_json.present?
          @h_dashboard_card[step.id] = Basic.safe_parse_json(step.dashboard_card_json, {})
        end

        @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
        step_dir = @project_dir + step.name
        output_dir = step.multiple_runs ? (step_dir + run.id.to_s) : step_dir
        output_json_file = output_dir + "output.json"

        @h_res = {}
        @h_outputs = {}
        begin
          @h_res = Basic.safe_parse_json(File.read(output_json_file), {}) if File.exist?(output_json_file)
          @h_outputs = Basic.safe_parse_json(run.output_json, {}) if run.output_json.present? && run.output_json.match(/^\{/)
        rescue => e
          Rails.logger.error("[render_run_panel_to_string] Error loading run data: #{e.message}")
        end

        @h_steps = {}
        Step.where(docker_image_id: asap_docker_image.id).each { |s| @h_steps[s.id] = s } if asap_docker_image

        @h_statuses = {}
        Status.all.each { |s| @h_statuses[s.id] = s }

        if step.has_std_view
          @h_annots_by_dim = {}
          Annot.where(run_id: run.id).each { |a| @h_annots_by_dim[a.dim] ||= []; @h_annots_by_dim[a.dim].push(a) }

          @layout = step.show_view_json.present? ? Basic.safe_parse_json(step.show_view_json, []) : []

          @h_el = {}
          h_files = {}
          h_links = {}

          if @h_dashboard_card[step.id] && @h_dashboard_card[step.id]["output_links"]
            output_links_config = @h_dashboard_card[step.id]["output_links"]
            if @h_outputs && output_links_config
              output_links_config.each do |link_config|
                key = link_config["key"]
                h_links[key] = @h_outputs[key] if @h_outputs[key]
              end
            end
          end

          if @h_dashboard_card[step.id] && @h_dashboard_card[step.id]["output_files"]
            list_p = @h_dashboard_card[step.id]["output_files"]
            list_p.select { |e| @h_outputs && @h_outputs[e["key"]] && ((admin? || e["admin"] == true) || !e["admin"]) }.each do |e|
              k = e["key"]
              @h_outputs[k].keys.each do |output_key|
                t = output_key.split(":")
                h_files[t[0]] ||= { h_output: @h_outputs[k][output_key], datasets: [] }
                h_files[t[0]][:datasets].push({ name: t[1], dataset_size: @h_outputs[k][output_key]['dataset_size'] }) if t.size > 1
              end
            end
          end

          dataset_results = []
          h_dim = { 1 => 'Cell metadata', 2 => 'Gene metadata', 3 => 'Expression matrix', 4 => "Other" }
          @h_annots_by_dim.each_key do |dim|
            subtitle = h_dim[dim]
            subtitle = subtitle.pluralize if subtitle && @h_annots_by_dim[dim].size > 1
            dataset_results.push "<h4>#{subtitle}</h4><p style='line-height:2.5em'>" +
              @h_annots_by_dim[dim].map { |annot|
                col_name = ([1, 3].include?(dim)) ? 'cell' : 'column'
                row_name = ([2, 3].include?(dim)) ? 'gene' : 'row'
                col_name = col_name.pluralize if annot.nber_cols && annot.nber_cols > 1
                row_name = row_name.pluralize if annot.nber_rows && annot.nber_rows > 1
                annot_link = Rails.application.routes.url_helpers.annot_path(annot)
                "<a href='#{annot_link}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors'>#{annot.name} <span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{annot.nber_cols} #{col_name}</span> <span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{annot.nber_rows} #{row_name}</span></a>"
              }.join(" ") + "</p>"
          end

          exec_files_html = ""
          if admin?
            exec_out_path = output_dir + "exec.out"
            exec_err_path = output_dir + "exec.err"
            exec_files = []
            if File.exist?(exec_out_path)
              file_size_display = helpers.display_mem(File.size(exec_out_path))
              exec_files << "<a href='#{get_file_project_path(@project, filename: 'exec.out', step: step.name, run_id: run.id)}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors'><span>exec.out</span><span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{file_size_display}</span></a>"
            end
            if File.exist?(exec_err_path)
              file_size_display = helpers.display_mem(File.size(exec_err_path))
              exec_files << "<a href='#{get_file_project_path(@project, filename: 'exec.err', step: step.name, run_id: run.id)}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors'><span>exec.err</span><span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{file_size_display}</span></a>"
            end
            exec_files_html = exec_files.join("")
          end

          @h_el = {
            "card-params" => {
              card_header: 'Parameters',
              card_body: helpers.display_run_attrs(run, @h_run_attrs, @h_std_method_attrs, {})
            },
            "card-downloads" => {
              card_header: 'Downloads',
              card_body: ((h_files.keys.size > 0) ? ("<div class='flex flex-wrap gap-1 items-start'>" + h_files.keys.map { |k| helpers.display_download_btn(run, h_files[k]) }.join("") + "</div>") : "") + (exec_files_html.present? ? "<div class='flex flex-wrap gap-1 items-start mt-1'>" + exec_files_html.strip + "</div>" : "")
            },
            "card-results" => {
              card_header: 'Results',
              card_body: ((run.status_id == 3 && @h_res['warnings']) ? @h_res['warnings'].map { |e|
                if e.is_a?(Hash)
                  "<p class='text-warning text-truncate' title=\"#{e['name']}. #{e['description']}\">#{e['name']}</p>"
                else
                  "<p class='text-warning text-truncate' title='#{e}'>#{e}</p>"
                end
              }.join(" ") : '') + dataset_results.join("<br/>\n")
            }
          }
        else
          @h_annots_by_dim = {}
          @layout = []
          @h_el = {}
        end

        @h_annots_for_params = {}
        @h_ori_runs_for_params = {}
        @h_steps_for_params = {}
        annot_ids = []
        direct_run_ids = []
        h_attrs = run.attrs_json.present? ? Basic.safe_parse_json(run.attrs_json, {}) : {}
        h_attrs.each_value do |v|
          if v.is_a?(Hash)
            annot_ids << (v['annot_id'] || v[:annot_id]) if v['annot_id'].present? || v[:annot_id].present?
            direct_run_ids << (v['run_id'] || v[:run_id]) if v['run_id'].present? || v[:run_id].present?
          elsif v.is_a?(Array)
            v.each do |item|
              next unless item.is_a?(Hash)
              annot_ids << (item['annot_id'] || item[:annot_id]) if item['annot_id'].present? || item[:annot_id].present?
              direct_run_ids << (item['run_id'] || item[:run_id]) if item['run_id'].present? || item[:run_id].present?
            end
          end
        end
        if annot_ids.any?
          Annot.where(id: annot_ids.uniq).each do |annot|
            @h_annots_for_params[annot.id] = annot
            if annot.ori_run_id.present? && !@h_ori_runs_for_params[annot.ori_run_id]
              ori_run = Run.find_by(id: annot.ori_run_id)
              if ori_run
                @h_ori_runs_for_params[annot.ori_run_id] = ori_run
                if ori_run.step_id.present? && !@h_steps_for_params[ori_run.step_id]
                  s = Step.find_by(id: ori_run.step_id)
                  @h_steps_for_params[ori_run.step_id] = s if s
                end
              end
            end
          end
        end
        if direct_run_ids.any?
          Run.where(id: direct_run_ids.uniq).each do |dr|
            @h_ori_runs_for_params[dr.id] = dr unless @h_ori_runs_for_params[dr.id]
            if dr.step_id.present? && !@h_steps_for_params[dr.step_id]
              s = Step.find_by(id: dr.step_id)
              @h_steps_for_params[dr.step_id] = s if s
            end
          end
        end

        render_to_string(partial: 'runs/panel', layout: false)
      ensure
        saved_ivars.each { |ivar, val| instance_variable_set(ivar, val) }
        %i[@run @step @std_method @status @h_run_attrs @h_std_method_attrs @h_dashboard_card
           @project_dir @h_res @h_outputs @h_steps @h_statuses @h_annots_by_dim @layout @h_el
           @h_annots_for_params @h_ori_runs_for_params @h_steps_for_params @asap_docker_image @ps].each do |ivar|
          remove_instance_variable(ivar) if instance_variable_defined?(ivar) && !saved_ivars.key?(ivar)
        end
      end
    end
end

