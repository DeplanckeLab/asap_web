# coding: utf-8
require 'ostruct'
require 'open3'
require 'zlib'
require 'base64'
require 'fileutils'
require 'securerandom'
require 'set'

class ProjectsController < ApplicationController
  include ComplianceHelpers
  helper_method :de_filter_cache_key, :metadata_only_view_request?, :force_unarchive_requested?, :selectable_project_types
  rescue_from ActiveRecord::RecordNotFound, with: :handle_project_not_found

  # Project show views that only depend on database metadata (no need for unarchived
  # project files on disk). These views can be rendered for archived projects without
  # triggering an unarchive job.
  METADATA_ONLY_PROJECT_VIEWS = %w[summary settings access annotations].freeze

  before_action :set_project, only: %i[ show edit update destroy clone clone_status metadata_coordinates metadata_vectors gene_expression heatmap_data heatmap_metadata_catalog heatmap_track get_file step_results refresh_steps_panel restart_step stop_parsing delete_all_runs_from_step reset_parsing queue_position get_attributes upd_pred data_content run_status run_counts run_list unarchive_status graph pipeline_runs instructions get_commands get_loom_files_json export_h5ad data_file_metadata_catalog project_data_files toggle_public cluster_comparison filter_de_results viz_de_results filter_ge_results filter_doublet_results search_gene search_gene_memberships search_gene_membership_items search_gene_set_items gene_set_collection_items gene_set_collection_status gene_set_item_genes gene_set_item_module_score cancel_gene_set_item_module_score download_gene_set_collection save_manual_gene_set create_gene_set_collection save_de_gene_set import_gene_set_collection delete_manual_gene_set prepare_metadata prepare_metadata_from_project_annot do_import_metadata export_consensus_annotation preview_consensus_annotation related_clone_projects federated_annotations consensus_annotation_support sample_identifiers get_autocomplete_genes get_annot_info create_cla get_annot_evidences search_visualization_metadata get_cell_set_annotations discover_metadata_import_sources discover_metadata_import_from_project metadata_import_cell_sets save_metadata_from_selection save_batch_compose_metadata delete_selection rename_selection rename_gene_set_collection selection_states delete_gene_set_collection collection_owned_project_autocomplete collection_add_project spatial_data spatial_image]
  before_action :forbid_bot_html_access_to_public_project_show, only: %i[show]
  before_action :authorize_project_read_access, only: %i[show clone_status metadata_coordinates metadata_vectors gene_expression heatmap_data heatmap_metadata_catalog heatmap_track get_file step_results refresh_steps_panel queue_position get_attributes upd_pred data_content run_status run_counts run_list unarchive_status graph pipeline_runs instructions get_commands get_loom_files_json export_h5ad data_file_metadata_catalog project_data_files cluster_comparison filter_de_results viz_de_results filter_ge_results filter_doublet_results search_gene search_gene_memberships search_gene_membership_items search_gene_set_items gene_set_collection_items gene_set_collection_status gene_set_item_genes gene_set_item_module_score cancel_gene_set_item_module_score download_gene_set_collection sample_identifiers get_autocomplete_genes get_annot_info get_annot_evidences search_visualization_metadata get_cell_set_annotations discover_metadata_import_sources discover_metadata_import_from_project metadata_import_cell_sets related_clone_projects federated_annotations consensus_annotation_support selection_states spatial_data spatial_image]
  before_action :authorize_project_edit_access, only: %i[edit update destroy restart_step stop_parsing delete_all_runs_from_step reset_parsing save_manual_gene_set create_gene_set_collection save_de_gene_set import_gene_set_collection delete_manual_gene_set prepare_metadata prepare_metadata_from_project_annot do_import_metadata delete_selection rename_selection rename_gene_set_collection delete_gene_set_collection collection_owned_project_autocomplete collection_add_project]
  before_action :authorize_project_analyze_access, only: %i[save_metadata_from_selection save_batch_compose_metadata]
  before_action :authorize_project_owner_access, only: %i[export_consensus_annotation preview_consensus_annotation]
  GENE_DETAILS_CACHE_ATTRS = %w[id ensembl_id name description biotype function_description alt_names obsolete_alt_names].freeze
  GENE_DETAILS_CACHE_TTL = 24.hours
  GENE_MEMBERSHIPS_CACHE_TTL = 1.hour

  MANUAL_GENE_SET_COLLECTION_ID = 'manual_local'.freeze
  MANUAL_GENE_SET_COLLECTION_NEW_ID = '__new_manual_collection__'.freeze
  MANUAL_GENE_SET_COLLECTION_LABEL = 'Manual Gene Sets'.freeze
  DE_GENE_SET_COLLECTION_NEW_ID = '__new_de_collection__'.freeze
  DE_GENE_SET_COLLECTION_LABEL = 'DE results'.freeze
  HEATMAP_GENE_SET_COLLECTION_NEW_ID = '__new_heatmap_collection__'.freeze
  HEATMAP_GENE_SET_COLLECTION_LABEL = 'Heatmap selection'.freeze
  LOCAL_GENE_SET_COLLECTION_ID_PREFIX = 'local_collection'.freeze
  GENE_SET_COLLECTION_TYPE_MANUAL = 'manual'.freeze
  GENE_SET_COLLECTION_TYPE_IMPORTED = 'imported'.freeze
  GENE_SET_COLLECTION_TYPE_GLOBAL = 'global'.freeze
  GENE_SET_COLLECTION_TYPE_FROM_DE = 'from_de'.freeze
  GENE_SET_COLLECTION_TYPE_FROM_FIND_MARKERS = 'from_find_markers'.freeze
  GENE_SET_COLLECTION_TYPE_FROM_HEATMAP = 'from_heatmap'.freeze
  MARKER_EVIDENCES_ANALYZE_FORBIDDEN_MESSAGE =
    'FindMarkers requires analyze permission on this project. You can view completed marker tables when a run has already finished.'.freeze

  # GET /projects or /projects.json
  def index
    @query, @filters = project_search_query_and_filters

    # Use Elasticsearch for search
    search_results = Project.search(@query, @filters)
    
    # Extract projects from search results with preloaded associations
    @projects = search_results.records.includes(:project_steps, :project_type, :organism, :annots, :archive_status, :user, provider_projects: :provider)
    @latest_compliance_passed_by_project_id =
      ComplianceValidation.latest_passed_by_project_id(@projects.map(&:id))

    # Get aggregations for filter dropdowns
    @aggregations = search_results.response['aggregations']
    
    # For filter dropdowns (fallback to database if no aggregations)
    @organisms = Organism.order(:name)
    @grouped_organisms = group_organisms(@organisms)
    @project_types = ProjectType.order(:name)
    @statuses = Status.order(:name)

    raw_tissues = @aggregations&.dig('tissues', 'buckets')&.map { |b| b['key'] } || Project.distinct.pluck(:tissue).compact
    @tissues = raw_tissues.map { |v| [v.sub(/\A./) { |c| c.upcase }, v] }.sort_by { |label, _| label.downcase }
    
    # Pagination - extract total count from Elasticsearch response
    @total_count = search_results.response['hits']['total']['value']
    @current_page = (params[:page] || 1).to_i
    @per_page = 20
    @v8_active_for_integration = Version.where(id: 8, activated: true).exists?
    
    # Store the current browse URL for "back to projects" links
    session[:projects_browse_url] = request.fullpath
    
    respond_to do |format|
      format.html
      format.json {

        file_path = Pathname.new(ENV.fetch("PROD_DATA_DIR")) + 'projects.json'
        headers['Content-Type'] = 'application/json'
        headers['Cache-Control'] = 'no-cache'
        headers['Content-Disposition'] = "inline; filename=#{File.basename(file_path)}"

        # Use send_file to stream the content directly to the client                                                                                                                                                       
        send_file(file_path, type: 'application/json', disposition: 'inline', stream: true)


      }
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
      dim_key = dims[metadata.dim.to_i - 1]
      unless dim_key
        Rails.logger.warn("[organize_metadata] Skipping annot ##{metadata.id}: invalid dim=#{metadata.dim.inspect}")
        next
      end

      data_type = h_data_types[metadata.data_type_id] || metadata.data_type
      unless data_type&.name.present?
        Rails.logger.warn("[organize_metadata] Skipping annot ##{metadata.id}: missing data_type for data_type_id=#{metadata.data_type_id.inspect}")
        next
      end

      h_metadata[metadata.filepath]||={}
      h_metadata[metadata.filepath][dim_key] ||= {}
      h_metadata[metadata.filepath][dim_key][data_type.name] ||= []
      h_metadata[metadata.filepath][dim_key][data_type.name] << metadata
    end
    h_metadata
  end

  # GET /projects/1 or /projects/1.json
  def show
    if crawler_archived_summary_only?
      requested_view = params[:view].to_s
      unless requested_view.blank? || METADATA_ONLY_PROJECT_VIEWS.include?(requested_view)
        redirect_to project_path(@project, view: 'summary')
        return
      end
    end

    queue_unarchive_if_project_files_missing
    track_project_view!
    set_sandbox_self_destruct_at!

    if @project.version_id < 4
       redirect_to "https://asap-old.epfl.ch/projects/#{@project.key}", allow_other_host: true
       return
    end

    # Bare project URLs should open the curated landing visualization checkpoint when set
    # (legacy landing_page_json behavior). Explicit ?view=... keeps normal navigation.
    # Search-engine crawlers must keep archived projects on the summary page and never restore files.
    if params[:view].blank? && params[:checkpoint_id].blank? && !crawler_archived_summary_only?
      landing_checkpoint = @project.checkpoints.visualization.find_by(is_landing_page: true)
      if landing_checkpoint
        redirect_to project_path(@project, view: 'visualization', checkpoint_id: landing_checkpoint.id)
        return
      end
    end

    if selective_project_view_loading_enabled?
      with_request_profile('projects#show', view: params[:view]) do
        @view_type = resolve_project_view_type(params[:view])
        # Summary/settings/access/annotations are metadata-only; creating ProjectStep
        # rows is only needed when the analysis pipeline UI is loaded.
        @project.apply_project_type_from_assay_metadata!
        @project.ensure_project_steps unless METADATA_ONLY_PROJECT_VIEWS.include?(@view_type)
        return unless authorize_requested_view_access!(@view_type)
        load_view_context_for(@view_type)
        return if performed?

        respond_to do |format|
          format.html
          format.json { render json: Basic.generate_project_json(@project) }
        end
      end
      return
    end

    # Infer spat/atac/multi from assay metadata when the type was left blank.
    @project.apply_project_type_from_assay_metadata!

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

    # Filter loom files to only include those with 2D visualizations (2 rows)
    @available_loom_files = existing_loom_files.select do |filepath|
      @h_metadata[filepath] && 
      @h_metadata[filepath]['cell'] && 
      @h_metadata[filepath]['cell']['NUMERIC'] &&
      @h_metadata[filepath]['cell']['NUMERIC'].any? { |m| m.nber_rows && (m.nber_rows == 2) }
    end
    
    # Get default loom file - use the first loom file with visualizations (only from existing files)
    Rails.logger.debug "[show] Existing loom files: #{existing_loom_files.inspect}"
    Rails.logger.debug "[show] Available loom files with visualizations: #{@available_loom_files.inspect}"
    @default_loom_file = @available_loom_files.first || existing_loom_files.first
    Rails.logger.debug "[show] Default loom file set to: #{@default_loom_file.inspect}"

    # Build embedding metadata (2-row coordinate sets) grouped by loom file
    @all_embeddings_by_loom = {}
    @available_loom_files.each do |filepath|
      numeric_metadata = @h_metadata.dig(filepath, 'cell', 'NUMERIC') || []
      @all_embeddings_by_loom[filepath] = numeric_metadata.select do |metadata|
        metadata.nber_rows.present? && metadata.nber_rows == 2
      end
    end
    
    # Check if a specific embedding_id was requested
    if params[:embedding_id].present?
      requested_embedding = Annot.find_by(id: params[:embedding_id], project_id: @project.id)
      if requested_embedding && requested_embedding.nber_rows.present? && requested_embedding.nber_rows == 2
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
    @expression_matrices_by_loom = Annot.light.where(project_id: @project.id, dim: 3)
                                        .order(id: :asc)
                                        .group_by(&:filepath)
    
    # Precompute best CLA annotation metadata per categorical metadata category
    # (annotation tool is limited to single-cell transcriptomics projects)
    if @project.single_cell?
      categorical_metadata = []
      @h_metadata.each_value do |dimension_hash|
        next unless dimension_hash
        discrete = dimension_hash.dig('cell', 'DISCRETE')
        categorical_metadata.concat(discrete) if discrete.present?
      end
      build_best_cla_category_map(categorical_metadata)
    else
      @best_clas_by_metadata_category = {}
    end
    
    # Check if we have embeddings for visualization
    has_visualization_embeddings = @all_embeddings_by_loom.any? { |_filepath, embeddings| embeddings.present? }

    @initial_selection_items = []
    if @default_loom_file.present?
      @initial_selection_items = selection_cache_items_for_loom(@default_loom_file, cleanup_completed: true)
      @initial_selection_items.concat(selection_items_from_annots(@default_loom_file))
      @initial_selection_items.sort_by! { |entry| entry[:created_at].to_s }
      @initial_selection_items.reverse!
    end
    
    # Default to visualization only when embeddings exist.
    # Projects without embeddings should open in analysis.
    default_view = "summary" #has_visualization_embeddings ? 'visualization' : 'summary'
    @view_type = resolve_project_view_type(params[:view].presence || default_view)
    return unless authorize_requested_view_access!(@view_type)
    
    load_gene_set_collections if @view_type == 'visualization'

    #@available_embeddings = default_loom_file ? @all_embeddings_by_loom[default_loom_file] : []

    # Steps logic for summary and analysis views
    if @view_type == 'summary' || @view_type == 'analysis'
      # Get project type for display
      @project_type = @project.project_type
      
      # Get runs for the project
      @runs = apply_publication_snapshot_to_runs(@project.runs.includes(:annots))
      
      # Build steps with status using shared method
      prepare_steps_with_status
      
      # Set selected step ID from URL parameter (for step selector on narrow screens)
      # This allows linking directly to a specific step from the run show page
      @selected_step_id = params[:step_id].present? ? params[:step_id].to_i : nil
      # Set selected run ID from URL parameter (to auto-load a specific run)
      @selected_run_id = params[:run_id].present? ? params[:run_id].to_i : nil
      
      # Run panels are fetched client-side from /runs/:id?panel=1 to keep a single
      # rendering path for right-panel run content.
      @load_run_panel = false
      @run_panel_html = nil

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
            @runs = apply_publication_snapshot_to_runs(
              @project.runs.where(step_id: @selected_step_id).includes(:annots).order(created_at: :desc)
            )
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
          de_aid = params[:gene_list_de_annot_id].presence
          @de_gene_list_annot_id = de_aid
          de_list_dir = Basic.de_filter_gene_list_dir(project_dir, gl_run.id, de_aid)

          filename = de_list_dir + "filtered.#{params[:type]}.json"
          list_filtered_rows = Basic.safe_parse_json(File.read(filename), [])
          @h_filtered_rows = {}
          list_filtered_rows.each { |e| @h_filtered_rows[e.to_i] = 1 }
          @nber_genes = list_filtered_rows.size

          output_txt = de_list_dir + 'output.txt'
          @tmp_data = File.readlines(output_txt)
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
      all_annots = apply_publication_snapshot_to_annots(
        Annot.light.where(project_id: @project.id)
             .where.not(filepath: nil)
             .includes(:step, :data_type, :data_transformation, run: [:std_method])
             .order(:name)
      )
      
      # Associate each loom file to the run that produced its /matrix annotation.
      filepath_info = build_filepath_info_from_matrix_annots(all_annots)
      
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
      @selected_loom_file = params[:loom_file].presence
      
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

      if @selected_loom_file.present? && @selected_data_type == 'global'
        load_global_attr_card_values!(
          @selected_loom_file,
          @annots_by_loom_and_type[@selected_loom_file]&.dig(:global) || []
        )
      end

      if editable?(@project)
        @sim_step_options = helpers.sim_step_options_for_project(@project)
      end
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

      @compliance_check_groups = resolve_compliance_check_groups(@validation_result) if @validation_result.present?
    end
    
    # Variables specific to summary view
    if @view_type == 'summary'
      # Get parsing status for display
      @parsing_status = 'success'
      @parsing_step = parsing_step_for_project(@project)
      if @parsing_step
        @parsing_project_step = ProjectStep.find_by(project_id: @project.id, step_id: @parsing_step.id)
        if @parsing_project_step
          status_name = @parsing_project_step.status&.name.to_s.downcase
          @parsing_status = if %w[pending running success failed].include?(status_name)
                              status_name
                            else
                              'success'
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
      @runs ||= apply_publication_snapshot_to_runs(@project.runs.includes(:annots))
      
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

      assign_summary_collection_context!

      compute_summary_loom_overview
      
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

      assign_summary_submitted_file_link!
      assign_summary_scfair_metadata_context!
    end
    
    # For testing, if no embeddings found, use a project that has them
    #if @available_embeddings.empty?
    #if test_project
     # #  test_project = Project.joins(:annots).where("annots.name LIKE ?", '/col_attrs/_umap_%').first
     #   @available_embeddings = Annot.available_embeddings(test_project.id)
    #    @available_metadata = Annot.available_metadata(test_project.id)
    #  end
    #end

    if !selective_project_view_loading_enabled? && @view_type == 'analysis' && request.get? && request.format.html?
      @integration_in_progress = @project.integration_in_progress?
      redirect_analysis_to_parsing_step_if_integration_in_progress!
      return if performed?

      all_annots_for_loom = load_loom_file_list_context
      assign_analysis_loom_file_from_session!
      redirect_analysis_single_run_canonical_url!(all_annots_for_loom)
      return if performed?
    end

    respond_to do |format|
      format.html # Use application layout
      format.json {
        render json: Basic.generate_project_json(@project)
      }
    end
  end

  # GET /projects/organisms_for_version
  def organisms_for_version
    version_id = params[:version_id].presence
    organisms = fetch_organisms_for_version(version_id)
    grouped_organisms = group_organisms(organisms, version_id: version_id)
    
    render json: {
      organisms: grouped_organisms.map do |domain, orgs|
        {
          domain: domain,
          count: orgs.count,
          organisms: orgs.map do |display_name, id, tax_id, assembly_status|
            {
              display_name: display_name,
              id: id,
              tax_id: tax_id,
              assembly_status: assembly_status
            }
          end
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
    @project_types = selectable_project_types
    @versions = available_versions
    @file_formats = FileFormat.ordered
    @project.version_id = @versions.first&.id if @project.version_id.blank?
    default_version_for_organisms = @project.version_id
    @organisms = fetch_organisms_for_version(default_version_for_organisms)
    @grouped_organisms = group_organisms(@organisms, version_id: default_version_for_organisms)

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
        sc_type = single_cell_transcriptomics_project_type || @project_types.first
        @project.project_type_id = sc_type&.id
        @lock_project_type = true

        @integrate_annots = {}
        @integrate_projects.each do |p|
          annots = Annot.light.where(project_id: p.id, dim: 1)
                        .where('nber_cats > 0 OR list_cat_json IS NOT NULL')
                        .order(:name)
                        .select(&:integration_batch_metadata?)
          @integrate_annots[p.id] = annots
        end
      end
    end

    @prefill_file_url = params[:file_url].to_s.strip.presence
    @project_origin_name = resolve_project_origin_name_for_new(
      params[:from],
      params[:fu_id],
      integrate: @integrate_mode
    )
    if @project_origin_name == ProjectOrigin::SCFAIR_VALIDATION
      sc_type = single_cell_transcriptomics_project_type
      @project.project_type_id = sc_type.id if sc_type
      @lock_project_type = true
    end
    adopt_upload_fu_for_new_project(params[:fu_id])
  end

  # GET /projects/1/edit
  def edit
    @organisms = Organism.order(:name)
    @project_types = selectable_project_types
    @versions = available_versions
    @file_formats = FileFormat.ordered
  end

  # POST /projects or /projects.json
  def create
    @project = Project.new(project_params)

    # Guest sandbox projects must use the session sandbox key so access checks pass.
    @project.key = session[:sandbox] unless current_user
    
    # Get file formats for parsing attributes handling
    @h_formats = {}
    FileFormat.all.map { |f| @h_formats[f.name] = f }
    
    # Delete project if already exists with this key (if editable)
    # Note: This allows reusing project keys for the same user
    if @project.key.present? && (existing_project = Project.find_by(key: @project.key))
      if editable?(existing_project)
        # Clear Fu records that reference this project to avoid foreign key constraint violations
        Fu.where(project_id: existing_project.id).update_all(project_id: nil)

        # Destroy DB row; Project after_commit removes USER_DATA_DIR/<user>/<key>/ (and .tgz).
        existing_project.destroy
      end
    end
    
    # Handle parsing attributes from params
    raw_attrs = params[:attrs].presence
    tmp_attrs = if raw_attrs
                  source_attrs = raw_attrs.respond_to?(:to_unsafe_h) ? raw_attrs.to_unsafe_h : raw_attrs.to_h
                  source_attrs.deep_symbolize_keys
                else
                  {}
                end
    tmp_attrs[:has_header] = 1 if tmp_attrs[:has_header]
    
    # Collect parsing attributes from params
    [:file_type, :sel_name, :sel, :nber_cols, :nber_rows, :gene_name_col, :has_header, :integrate_method, :integrate_source_keys, :integrate_batch_paths, :integrate_n_pcs].each do |k|
      if params[k].present? && (!params[k].is_a?(String) || !params[k].strip.empty?)
        tmp_attrs[k] = params[k]
      end
    end
    # Delimiter may be empty (tab) or whitespace (space); accept whenever submitted.
    if params.key?(:delimiter)
      tmp_attrs[:delimiter] = params[:delimiter].to_s
    end
    if tmp_attrs[:integrate_method].present? && !Basic::INTEGRATION_METHODS.include?(tmp_attrs[:integrate_method].to_s)
      tmp_attrs.delete(:integrate_method)
    end
    [:rowname_metadata, :colname_metadata].each do |k|
      tmp_attrs[k] = params[k] if params.key?(k)
    end
    if tmp_attrs[:file_type].to_s == 'H5AD'
      tmp_attrs[:rowname_metadata] = H5adPreparsingMetadata.java_metadata_path(tmp_attrs[:rowname_metadata], :row) if tmp_attrs[:rowname_metadata].present?
      tmp_attrs[:colname_metadata] = H5adPreparsingMetadata.java_metadata_path(tmp_attrs[:colname_metadata], :col) if tmp_attrs[:colname_metadata].present?
    end
    # The UI submits dataset selection as `sel`; persist canonical key `sel_name` for parse task.
    if tmp_attrs[:sel].present?
      tmp_attrs[:sel_name] = tmp_attrs[:sel]
      tmp_attrs.delete(:sel)
    end
    # RAW_TEXT preparsing "group" labels (often the filename) are not archive members.
    # Keeping them as sel_name makes reset/restart preparsing pass Java -sel and fail.
    if tmp_attrs[:file_type].to_s.upcase == 'RAW_TEXT'
      tmp_attrs.delete(:sel_name)
    end
    
    # Set defaults for RAW_TEXT file types (matching original application behavior)
    # This matches the logic in /srv/asap2/app/controllers/fus_controller.rb lines 99-104
    detected_format = tmp_attrs[:file_type] || params[:file_type]
    if detected_format.blank? || ['ARCHIVE', 'ARCHIVE_COMPRESSED', 'COMPRESSED', 'RAW_TEXT'].include?(detected_format)
      tmp_attrs[:gene_name_col] ||= 'first' unless tmp_attrs[:gene_name_col].present?
      tmp_attrs[:delimiter] = '' unless tmp_attrs.key?(:delimiter)
      tmp_attrs[:has_header] ||= '1' unless tmp_attrs[:has_header].present?
    end
    
    # Remove RAW_TEXT-only parsing options for any non-RAW_TEXT format.
    if tmp_attrs[:file_type].present?
      format_name = tmp_attrs[:file_type].to_s
      format_obj = @h_formats[format_name] || @h_formats[format_name.upcase]
      is_raw_text = (format_name == 'RAW_TEXT') || (format_obj && format_obj.child_format == 'RAW_TEXT')
      unless is_raw_text
        [:delimiter, :gene_name_col, :has_header].each do |k|
          tmp_attrs.delete(k)
        end
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
    assign_project_origin_on_create!(@project)
    enforce_locked_project_type_on_create!(@project)
    
    # Generate unique project key only for signed-in users if not provided.
    unless @project.key.present?
      @project.key = Project.generate_unique_key
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

    if unauthorized_restricted_project_type?(@project)
      @organisms = Organism.order(:name)
      @project_types = selectable_project_types
      @versions = available_versions
      @file_formats = FileFormat.ordered
      @grouped_organisms = group_organisms(fetch_organisms_for_version(@project.version_id), version_id: @project.version_id)
      @project.errors.add(:project_type_id, 'is not available')
      respond_to do |format|
        format.html { render template: 'projects/new', status: :unprocessable_entity }
        format.turbo_stream { render template: 'projects/new', status: :unprocessable_entity }
        format.json { render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity }
      end
      return
    end

    Rails.logger.info("[ProjectsController#create] About to enter respond_to block, request format: #{request.format}")
    respond_to do |format|
      Rails.logger.info("[ProjectsController#create] ===== VALIDATION CHECK =====")
      Rails.logger.info("[ProjectsController#create] Inside respond_to block, format: #{format.inspect}")
      Rails.logger.info("[ProjectsController#create] input_file at validation: #{input_file.inspect}")
      Rails.logger.info("[ProjectsController#create] input_file.present?: #{input_file.present?}")
      Rails.logger.info("[ProjectsController#create] input_file.upload_file_name: #{input_file&.upload_file_name.inspect}")
      
      # Check if this is an integration request (no file upload needed)
      is_integrate = params[:integrate] == '1'
      
      # Require a Fu-backed input file for project creation (unless integrating).
      has_input_file = input_file.present? && input_file.id.present? && input_file.upload_file_name.present?

      Rails.logger.info("[ProjectsController#create] is_integrate: #{is_integrate}")
      Rails.logger.info("[ProjectsController#create] has_input_file: #{has_input_file}")

      unless is_integrate || has_input_file
        Rails.logger.warn("[ProjectsController#create] ===== VALIDATION FAILED =====")
        Rails.logger.warn("[ProjectsController#create] Input file validation failed - no valid Fu record")
        @organisms = Organism.order(:name)
        @project_types = selectable_project_types
        @versions = available_versions
        @file_formats = FileFormat.ordered
        @grouped_organisms = group_organisms(fetch_organisms_for_version(@project.version_id), version_id: @project.version_id)
        @project.errors.add(:base, "A valid uploaded file record is required to create a project. Please upload a file again.")
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
          
          parsing_step = parsing_step_for_project(@project)
          analysis_params = { view: 'analysis' }
          analysis_params[:step_id] = parsing_step.id if parsing_step
          
          format.html { redirect_to project_path(@project, **analysis_params), notice: "Integrated project was successfully created." }
          format.turbo_stream { redirect_to project_path(@project, **analysis_params), status: :see_other, notice: "Integrated project was successfully created." }
          format.json { render :show, status: :created, location: @project }
          next
        end
        
        # === NORMAL FILE UPLOAD PATH ===
        Rails.logger.info("[ProjectsController#create] input_file after save: #{input_file.inspect}")
        Rails.logger.info("[ProjectsController#create] input_file.present?: #{input_file.present?}")
        
        unless input_file.present? && input_file.id.present?
          Rails.logger.error("[ProjectsController#create] Fu record missing after validation; aborting")
          @project.errors.add(:base, "Internal error: uploaded file record not found")
          format.html { render template: 'projects/new', status: :unprocessable_entity }
          format.turbo_stream { render template: 'projects/new', status: :unprocessable_entity }
          format.json { render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity }
          return
        end
        
        # Create project directory
        user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
        project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
        FileUtils.mkdir_p(project_dir)
        clear_stale_sandbox_parsing_output!(project_dir) if @project.sandbox?
        
        begin
          ProjectInputFinalizerService.call(
            project: @project,
            project_dir: project_dir,
            input_file: input_file,
            formats_by_name: @h_formats,
            logger: Rails.logger
          )
        rescue => e
          Rails.logger.error("[ProjectsController#create] Upload finalization failed: #{e.class} - #{e.message}")
          @project.errors.add(:base, e.message)
          format.html { render template: 'projects/new', status: :unprocessable_entity }
          format.turbo_stream { render template: 'projects/new', status: :unprocessable_entity }
          format.json { render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity }
          return
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
        @project_types = selectable_project_types
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
    reset_requested = params[:reset_parsing].to_s == '1'
    is_resetting_parsing = (session[:resetting_parsing] && session[:resetting_parsing_project_id] == @project.id) || reset_requested
    
    if is_resetting_parsing
      previous_fu_id = @project.fu_id

      # Handle parsing reset similar to create action
      # Get file formats for parsing attributes handling
      @h_formats = {}
      FileFormat.all.map { |f| @h_formats[f.name] = f }
      
      # Handle parsing attributes from params
      raw_attrs = params[:attrs].presence
      tmp_attrs = if raw_attrs
                    source_attrs = raw_attrs.respond_to?(:to_unsafe_h) ? raw_attrs.to_unsafe_h : raw_attrs.to_h
                    source_attrs.deep_symbolize_keys
                  else
                    {}
                  end
      tmp_attrs[:has_header] = 1 if tmp_attrs[:has_header]
      
      # Collect parsing attributes from params
      [:file_type, :sel_name, :sel, :nber_cols, :nber_rows, :gene_name_col, :has_header].each do |k|
        if params[k].present? && (!params[k].is_a?(String) || !params[k].strip.empty?)
          tmp_attrs[k] = params[k]
        end
      end
      # Delimiter may be empty (tab) or whitespace (space); accept whenever submitted.
      if params.key?(:delimiter)
        tmp_attrs[:delimiter] = params[:delimiter].to_s
      end
      [:rowname_metadata, :colname_metadata].each do |k|
        tmp_attrs[k] = params[k] if params.key?(k)
      end
      # Keep previously detected file type when reset form does not submit one.
      existing_attrs = Basic.safe_parse_json(@project.parsing_attrs_json, {}).deep_symbolize_keys
      tmp_attrs[:file_type] ||= existing_attrs[:file_type]
      # The UI submits dataset selection as `sel`; persist canonical key `sel_name` for parse task.
      if tmp_attrs[:sel].present?
        tmp_attrs[:sel_name] = tmp_attrs[:sel]
        tmp_attrs.delete(:sel)
      end
      # RAW_TEXT preparsing "group" labels (often the filename) are not archive members.
      if tmp_attrs[:file_type].to_s.upcase == 'RAW_TEXT'
        tmp_attrs.delete(:sel_name)
      end
      
      # Set defaults for RAW_TEXT file types
      detected_format = tmp_attrs[:file_type] || params[:file_type]
      if detected_format.blank? || ['ARCHIVE', 'ARCHIVE_COMPRESSED', 'COMPRESSED', 'RAW_TEXT'].include?(detected_format)
        tmp_attrs[:gene_name_col] ||= 'first' unless tmp_attrs[:gene_name_col].present?
        tmp_attrs[:delimiter] = '' unless tmp_attrs.key?(:delimiter)
        tmp_attrs[:has_header] ||= '1' unless tmp_attrs[:has_header].present?
      end
      
      # Remove RAW_TEXT-only parsing options for any non-RAW_TEXT format.
      if tmp_attrs[:file_type].present?
        format_name = tmp_attrs[:file_type].to_s
        format_obj = @h_formats[format_name] || @h_formats[format_name.upcase]
        is_raw_text = (format_name == 'RAW_TEXT') || (format_obj && format_obj.child_format == 'RAW_TEXT')
        unless is_raw_text
          [:delimiter, :gene_name_col, :has_header].each do |k|
            tmp_attrs.delete(k)
          end
        end
      end
      
      # Update project attributes
      @project.assign_attributes(project_params)
      if unauthorized_restricted_project_type?(@project)
        @project.errors.add(:project_type_id, 'is not available')
        @project_types = selectable_project_types
        @versions = available_versions
        @file_formats = FileFormat.ordered
        @organisms = fetch_organisms_for_version(@project.version_id)
        @grouped_organisms = group_organisms(@organisms, version_id: @project.version_id)
        respond_to do |format|
          format.html { render :new, status: :unprocessable_entity }
          format.turbo_stream { render :new, status: :unprocessable_entity }
          format.json { render json: @project.errors, status: :unprocessable_entity }
        end
        return
      end
      @project.parsing_attrs_json = tmp_attrs.to_json
      # Defer destructive reset cleanup to parse.rake execution context.
      h_parsing_attrs = Basic.safe_parse_json(@project.parsing_attrs_json, {})
      h_parsing_attrs['reset_mode'] = true
      @project.parsing_attrs_json = h_parsing_attrs.to_json
      @project.nber_cols = params[:nber_cols] if params[:nber_cols]
      @project.nber_rows = params[:nber_rows] if params[:nber_rows]
      @project.step_id ||= 1
      # Force project back to waiting during reset to avoid stale "success" UI state.
      @project.status_id = 1
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
        old_upload_dir = input_file.global_upload_dir
        input_file.update!(
          project_id: @project.id,
          project_key: @project.key,
          status: 'completed'
        )
        input_file.reload

        new_upload_dir = input_file.upload_dir
        if File.exist?(old_upload_dir.to_s) && old_upload_dir.to_s != new_upload_dir.to_s
          FileUtils.mkdir_p(new_upload_dir.parent)
          FileUtils.rm_rf(new_upload_dir) if File.exist?(new_upload_dir.to_s)
          FileUtils.mv(old_upload_dir.to_s, new_upload_dir.to_s)
          Rails.logger.info("[ProjectsController#update] Moved reset upload directory from #{old_upload_dir} to #{new_upload_dir}")
        end

        @project.fu_id = input_file.id

        # Keep the canonical project input file in sync with the selected FU.
        # parse.rake reads project_dir/input_filename; if this copy is stale, the
        # run can mix old matrix dimensions with new preparsing parameters.
        user_data_root = Pathname.new(ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s)
        project_dir = user_data_root + @project.user_id.to_s + @project.key
        FileUtils.mkdir_p(project_dir.to_s) unless File.directory?(project_dir.to_s)

        source_upload_file = input_file.upload_dir_for_project(@project) + input_file.upload_file_name
        unless File.exist?(source_upload_file.to_s)
          raise "Selected upload file is missing: #{source_upload_file}"
        end

        @project.input_filename = 'input_file'
        canonical_project_input_file = project_dir + @project.input_filename
        FileUtils.rm_f(canonical_project_input_file.to_s)
        FileUtils.cp(source_upload_file.to_s, canonical_project_input_file.to_s)
      end
      
      # Reset parsing step status
      parsing_step = parsing_step_for_project(@project)
      if parsing_step
        # Zero other steps' counters immediately. Their runs still exist until
        # parse.rake reset_mode cleanup, but the header must not keep showing
        # stale success/failed counts once the new parsing starts.
        ProjectStep.where(project_id: @project.id).where.not(step_id: parsing_step.id)
                   .update_all(status_id: nil, error_message: nil, nber_runs_json: '{}', updated_at: Time.current)

        project_step = ProjectStep.find_by(project_id: @project.id, step_id: parsing_step.id)
        if project_step
          project_step.update!(status_id: 1) # Set to waiting
        else
          ProjectStep.find_or_create_by!(project_id: @project.id, step_id: parsing_step.id) do |ps|
            ps.status_id = 1
          end
        end

        # Move the latest parsing run out of failed immediately so header summaries
        # reflect the restart request without waiting for async job execution.
        parsing_run = @project.runs.where(step_id: parsing_step.id).order(id: :desc).first
        if parsing_run
          parsing_run.update!(
            status_id: 1,
            error: nil,
            slurm_job_id: nil,
            pid: nil,
            start_time: nil,
            duration: nil,
            submitted_at: Time.current,
            waiting_duration: nil
          )
        end

        # Keep aggregated counters in sync and push websocket update now.
        Basic.upd_project_step(@project, parsing_step.id)
        @project.reload
        @project.broadcast(parsing_step.id) if @project.respond_to?(:broadcast)
      end

      # Clear previous parsing artifacts immediately so reset does not display stale results
      # while the new parsing run is being scheduled.
      if @project.user_id.present? && @project.key.present?
        user_data_root = Pathname.new(ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s)
        parsing_dir = user_data_root + @project.user_id.to_s + @project.key + 'parsing'
        if File.directory?(parsing_dir.to_s)
          FileUtils.rm_rf(parsing_dir.to_s)
        end
        FileUtils.mkdir_p(parsing_dir.to_s, mode: 0777)
        FileUtils.chmod(0777, parsing_dir.to_s) if File.directory?(parsing_dir.to_s)
      end
      
      respond_to do |format|
        if @project.save
          # Trigger parsing; parse.rake will perform reset cleanup in reset_mode.
          if @project.respond_to?(:parse_files)
            h_data = {}
            @project.parse_files(h_data)
          end

          # If a new upload replaced the previous project Fu, remove stale upload data.
          if input_file.present? && previous_fu_id.present? && previous_fu_id != input_file.id
            previous_fu = Fu.find_by(id: previous_fu_id)
            if previous_fu
              stale_paths = [previous_fu.upload_dir.to_s, previous_fu.global_upload_dir.to_s].uniq
              stale_paths.each do |stale_path|
                next unless File.exist?(stale_path)

                FileUtils.rm_rf(stale_path)
                Rails.logger.info("[ProjectsController#update] Removed stale reset upload directory #{stale_path} (previous_fu_id=#{previous_fu_id}, new_fu_id=#{input_file.id})")
              end
            end
          end

          # Keep only the latest upload directory for this project after reset upload succeeds.
          if input_file.present? && @project.user_id.present? && @project.key.present?
            project_fus_root = Pathname.new(ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s) + @project.user_id.to_s + @project.key + 'fus'
            if File.directory?(project_fus_root.to_s)
              Dir.children(project_fus_root.to_s).each do |entry|
                next unless entry.match?(/\A\d+\z/)
                next if entry.to_i == input_file.id

                stale_project_fu_dir = project_fus_root + entry
                next unless File.directory?(stale_project_fu_dir.to_s)

                FileUtils.rm_rf(stale_project_fu_dir.to_s)
                Rails.logger.info("[ProjectsController#update] Removed stale project fu directory #{stale_project_fu_dir} (kept_fu_id=#{input_file.id})")
              end
            end
          end
          
          # Clean up session flags
          session.delete(:resetting_parsing)
          session.delete(:resetting_parsing_project_id)
          session.delete(:file_upload)
          
          format.html { redirect_to project_path(@project, view: 'analysis', step_id: parsing_step&.id), notice: "Project recreation started. Parsing will restart shortly." }
          format.json { render :show, status: :ok, location: @project }
        else
          @project_types = selectable_project_types
          @versions = available_versions
          @file_formats = FileFormat.ordered
          @organisms = fetch_organisms_for_version(@project.version_id)
          @grouped_organisms = group_organisms(@organisms, version_id: @project.version_id)
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: @project.errors, status: :unprocessable_entity }
        end
      end
    else
      # Normal update
      if project_params.key?(:name) && !(@project.user_id == current_user&.id || admin?)
        respond_to do |format|
          format.html { redirect_to project_path(@project, view: 'summary'), alert: "You don't have permission to update this project's title." }
          format.json { render json: { error: "Not authorized" }, status: :forbidden }
        end
        return
      end

      if project_params.key?(:project_type_id) && @project.project_type_id.nil?
        new_project_type_id = project_params[:project_type_id].presence
        type_set_error = if @project.version_id.to_i >= 8
          "Project type can only be set for ASAP releases before version 8."
        elsif new_project_type_id.blank?
          "Project type is required."
        elsif (ptype = ProjectType.find_by(id: new_project_type_id)).nil?
          "Invalid project type."
        elsif ptype.admin_report_only? && !admin_report?
          "This project type is not available."
        end

        if type_set_error
          respond_to do |format|
            format.html { redirect_to project_path(@project, view: 'settings'), alert: type_set_error }
            format.json { render json: { error: type_set_error }, status: :unprocessable_entity }
          end
          return
        end
      end

      respond_to do |format|
        begin
          ActiveRecord::Base.transaction do
            apply_project_collection_assignment!
            unless @project.update(project_params)
              raise ActiveRecord::RecordInvalid, @project
            end
          end
          format.html { redirect_to @project, notice: "Project was successfully updated." }
          format.json { render :show, status: :ok, location: @project }
        rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
          message = e.is_a?(ActiveRecord::RecordInvalid) ? @project.errors.full_messages.to_sentence : e.message
          format.html { redirect_to @project, alert: message }
          format.json { render json: { error: message }, status: :unprocessable_entity }
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

    unknown_type_projects = projects.select { |project| project.project_type_id.nil? }
    if unknown_type_projects.any?
      render json: {
        success: false,
        unknown_project_type: true,
        projects: unknown_type_projects.map { |project|
          {
            id: project.id,
            name: project.display_name,
            settings_url: project_path(project, view: 'settings')
          }
        }
      }, status: :unprocessable_entity
      return
    end

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

    if @project.version_id.to_i < 4
      respond_to do |format|
        format.html { redirect_to projects_path, alert: "Cloning is not available for projects on ASAP release before v4." }
        format.json { render json: { error: "Cloning is not available for this project release" }, status: :unprocessable_entity }
      end
      return
    end

    clone_service = ProjectCloneService.new(@project, user: current_user, session: session, admin: admin?)
    new_project = clone_service.start!

    if new_project
      ProjectCloneJob.perform_later(new_project.id)
      respond_to do |format|
        format.html { redirect_to project_path(new_project) }
        format.json { render json: { project_key: new_project.key, redirect_url: project_path(new_project), status: 'cloning' }, status: :accepted }
      end
    else
      error_message = clone_service.errors.first || "Failed to clone project"
      respond_to do |format|
        format.html { redirect_to project_path(@project), alert: error_message }
        format.json { render json: { error: error_message }, status: :unprocessable_entity }
      end
    end
  end

  def clone_status
    render json: {
      project_id: @project.id,
      being_cloned: @project.being_cloned,
      clone_status: @project.being_cloned ? 'copying' : 'completed',
      redirect_url: project_path(@project)
    }
  end

  # POST /projects/:id/toggle_public
  # Start publication (being_published), cancel in-progress publication, or unpublish.
  # public/public_at flip only after H5AD exports + scFAIR H5AD validation succeed.
  def toggle_public
    if @project.sandbox?
      message = "Sandbox projects cannot be made public. Clone the project into a regular account project first."
      respond_to do |format|
        format.html { redirect_to project_path(@project, view: 'settings'), alert: message }
        format.json { render json: { success: false, error: message }, status: :unprocessable_entity }
      end
      return
    end

    unless @project.user_id == current_user&.id || admin?
      respond_to do |format|
        format.html { redirect_to project_path(@project), alert: "You don't have permission to change this project's public status." }
        format.json { render json: { success: false, error: "Permission denied" }, status: :forbidden }
      end
      return
    end

    new_public_state = params[:public] == 'true' || params[:public] == true
    user_id = current_user&.id || @project.user_id

    if new_public_state && @project.public?
      respond_publication_json_or_html(
        success: true,
        message: 'Project is already public.',
        notice: 'Project is already public.'
      )
      return
    end

    if new_public_state && @project.publishing?
      respond_publication_json_or_html(
        success: false,
        error: 'Publication is already in progress.',
        status: :unprocessable_entity,
        alert: 'Publication is already in progress.'
      )
      return
    end

    if new_public_state && !@project.public?
      can_publish, reason = @project.can_be_public?
      unless can_publish
        respond_to do |format|
          format.html { redirect_to project_path(@project, view: 'summary'), alert: reason }
          format.json { render json: { success: false, error: reason, requires_validation: true }, status: :unprocessable_entity }
        end
        return
      end

      begin
        result = ProjectPublicationService.start!(@project, user_id: user_id, logger: Rails.logger)
        if result[:status] == 'finalized'
          respond_publication_json_or_html(
            success: true,
            message: 'Project is now public.',
            notice: 'Project is now public.'
          )
        else
          respond_publication_json_or_html(
            success: true,
            message: 'Publication started. Exporting and validating H5AD files…',
            notice: 'Publication started. Exporting and validating H5AD files…'
          )
        end
      rescue ProjectPublicationService::Error => e
        respond_to do |format|
          format.html { redirect_to project_path(@project, view: 'settings'), alert: e.message }
          format.json do
            render json: publication_status_payload(success: false, error: e.message),
                   status: :unprocessable_entity
          end
        end
      end
      return
    end

    if !new_public_state && @project.publishing?
      ProjectPublicationService.cancel!(@project, logger: Rails.logger)
      respond_publication_json_or_html(
        success: true,
        message: 'Publication cancelled.',
        notice: 'Publication cancelled.'
      )
      return
    end

    if !new_public_state && @project.public?
      @project.public = false
      # Keep public_id and public_at for record keeping
      if @project.save
        respond_publication_json_or_html(
          success: true,
          message: 'Project is now private.',
          notice: 'Project is now private.'
        )
      else
        respond_to do |format|
          format.html { redirect_to project_path(@project, view: 'summary'), alert: 'Failed to update project status.' }
          format.json do
            render json: publication_status_payload(
              success: false,
              error: @project.errors.full_messages.join(', ')
            ), status: :unprocessable_entity
          end
        end
      end
      return
    end

    respond_publication_json_or_html(
      success: true,
      message: 'No change.',
      notice: 'No change.'
    )
  end

  # GET /projects/:id/collection_owned_project_autocomplete
  def collection_owned_project_autocomplete
    collection = @project.project_collection
    unless collection && can_manage_project_collection?(collection)
      return render json: { error: 'Not authorized to manage this collection.' }, status: :forbidden
    end
    unless current_user
      return render json: { error: 'Authentication required.' }, status: :unauthorized
    end

    query = params[:q].to_s.strip
    scope = Project.not_deleted.where(user_id: current_user.id)
    scope = scope.where.not(id: collection.projects.select(:id))
    if query.present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      scope = scope.where(
        "COALESCE(name, '') ILIKE :q OR COALESCE(key, '') ILIKE :q OR CAST(id AS TEXT) ILIKE :q OR CAST(public_id AS TEXT) ILIKE :q",
        q: like
      )
    end

    projects = scope
      .order(Arel.sql("LOWER(COALESCE(name, '')) ASC"), :id)
      .limit(20)
      .to_a

    render json: {
      projects: projects.map { |project| summary_collection_project_payload(project) }
    }
  end

  # POST /projects/:id/collection_add_project
  def collection_add_project
    collection = @project.project_collection
    unless collection && can_manage_project_collection?(collection)
      return render json: { error: 'Not authorized to manage this collection.' }, status: :forbidden
    end
    unless current_user
      return render json: { error: 'Authentication required.' }, status: :unauthorized
    end

    target_id = params[:project_id].to_i
    if target_id <= 0
      return render json: { error: 'Select a project to add.' }, status: :unprocessable_entity
    end

    target = Project.not_deleted.find_by(id: target_id)
    unless target
      return render json: { error: 'Project not found.' }, status: :not_found
    end
    unless target.user_id == current_user.id
      return render json: { error: 'You can only add projects you own.' }, status: :forbidden
    end
    if target.project_collection_id == collection.id
      return render json: {
        error: 'Project is already in this collection.',
        project: summary_collection_project_payload(target, current: target.id == @project.id)
      }, status: :unprocessable_entity
    end

    begin
      authorize_project_collection_assignment!(collection)
      target.update!(project_collection_id: collection.id)
    rescue ArgumentError => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    member_count = collection.projects.not_deleted.count
    render json: {
      success: true,
      project: summary_collection_project_payload(target, current: target.id == @project.id),
      project_count: member_count
    }
  end

  def publication_status_payload(success:, message: nil, error: nil)
    @project.reload
    {
      success: success,
      public: @project.public?,
      being_published: @project.publishing?,
      publication_error: @project.publication_error,
      public_id: @project.public_id,
      message: message,
      error: error
    }.compact
  end
  private :publication_status_payload

  def respond_publication_json_or_html(success:, message: nil, notice: nil, alert: nil, error: nil, status: :ok)
    respond_to do |format|
      format.html do
        opts = {}
        opts[:notice] = notice if notice.present?
        opts[:alert] = alert.presence || error
        redirect_to project_path(@project, view: 'settings'), **opts.compact
      end
      format.json do
        render json: publication_status_payload(success: success, message: message, error: error),
               status: status
      end
    end
  end
  private :respond_publication_json_or_html

  # GET /projects/1/instructions
  def instructions
    @reproduction_server_url = ENV.fetch('SERVER_URL').to_s.chomp('/')
    text = render_to_string(template: 'projects/reproduction_instructions', formats: [:text], layout: false)
    send_data text,
              filename: "instructions_to_reproduce_#{@project.key}.txt",
              type: 'text/plain; charset=utf-8',
              disposition: 'inline'
  end

  # GET /projects/1/get_commands
  def get_commands
    version = @project.version
    unless version
      return render plain: 'Project has no version; cannot build reproduction script.', status: :unprocessable_entity
    end

    asap_docker_image = Basic.get_asap_docker(version)
    unless asap_docker_image
      return render plain: 'No ASAP docker image for this project version; cannot build reproduction script.', status: :unprocessable_entity
    end

    h_env = Basic.safe_parse_json(version.env_json, {})
    unless h_env['docker_images'].is_a?(Hash) && h_env['docker_images']['asap_run']
      return render plain: 'Version env_json is missing docker_images.asap_run; cannot build reproduction script.', status: :unprocessable_entity
    end

    begin
      asap_data_db = Basic.asap_data_db_name_from_env!(h_env)
    rescue ArgumentError => e
      return render plain: e.message.to_s, status: :unprocessable_entity
    end

    docker_name = "#{h_env['docker_images']['asap_run']['name']}:#{h_env['docker_images']['asap_run']['tag']}"
    server_url = ENV.fetch('SERVER_URL').to_s.chomp('/')
    project_dir = @project_dir

    @h_steps = {}
    Step.where(docker_image_id: asap_docker_image.id).find_each { |s| @h_steps[s.id] = s }
    @h_std_methods = StdMethod.where(docker_image_id: asap_docker_image.id).index_by(&:id)
    @h_dashboard_card = {}
    Step.where(docker_image_id: asap_docker_image.id).find_each do |step|
      @h_dashboard_card[step.id] = Basic.safe_parse_json(step.dashboard_card_json, {})
    end

    list_cmds = []
    list_cmds.push("## This script contains all commands executed in the PROJECT #{@project.key} and can be run again using the ASAP_run docker (https://hub.docker.com/layers/fabdavid/asap_run)")
    list_cmds.push("echo '*******************Reproducing analysis of PROJECT #{@project.key}#{@project.public? ? " / ASAP#{@project.public_id}" : ''}**********************'")
    list_cmds.push("echo '***************************************************************************************'")
    list_cmds.push('')

    list_cmds.push("## CONFIGURATION (edit below to match your machine; lines until the separator)")
    list_cmds.push("export ASAP_PROJECTS_DIR=/asap_projects ## change this to write analysis results there (there will be subdirectory for each project key).")
    list_cmds.push("export LOOM_DIR=$ASAP_PROJECTS_DIR/loom_files")
    list_cmds.push("export ASAP_DATA_DB_HOST=localhost; export ASAP_DATA_DB_PORT=5432")
    list_cmds.push("export PSQL_DIR=/usr/pgsql-10/bin")
    list_cmds.push('')
    list_cmds.push("## =========================================================")
    list_cmds.push('')
    list_cmds.push("export PROJECT_DIR=$ASAP_PROJECTS_DIR/#{@project.key}")

    list_cmds.push("## Pull Docker images (must run before any docker run in this script)")
    list_cmds.push('')
    h_env['docker_images'].each_key do |img_key|
      tmp = "#{h_env['docker_images'][img_key]['name']}:#{h_env['docker_images'][img_key]['tag']}"
      list_cmds.push("docker pull #{tmp}")
    end
    list_cmds.push('')

    list_cmds.push("## Host LOOM staging directory (inside Docker volume)")
    list_cmds.push("docker run --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"mkdir -p $LOOM_DIR; chmod 777 $LOOM_DIR\"")
    list_cmds.push('')
    if @project.public?
      list_cmds.push("echo 'This project is PUBLIC => Nothing to do'")
    else
      list_cmds.push("echo 'This project is PRIVATE => Please download the Inital Loom file from the Report section of the project (Loom file generated after the parsing step) and save it in LOOM_DIR'")
      list_cmds.push("read -p 'When ready press any key to continue... ' -n1 -s")
    end
    list_cmds.push('')

    asap_data_db_url = "#{server_url}/dumps/#{asap_data_db}.sql.gz"
    list_cmds.push("## Local PostgreSQL: create ASAP data database and load dump if missing")
    list_cmds.push("if ! psql -lqt | cut -d \\| -f 1 | grep -qw #{asap_data_db}; then echo 'Create database #{asap_data_db}'; echo '$PSQL_DIR/createdb -p $ASAP_DATA_DB_PORT #{asap_data_db}'; $PSQL_DIR/createdb -p $ASAP_DATA_DB_PORT #{asap_data_db}; echo 'wget -qO - #{asap_data_db_url} | gunzip | grep -v \\'AS integer\\' | $PSQL_DIR/psql -p $ASAP_DATA_DB_PORT #{asap_data_db}'; wget -qO - #{asap_data_db_url} | gunzip | grep -v 'AS integer' | $PSQL_DIR/psql -p $ASAP_DATA_DB_PORT #{asap_data_db}; fi")
    list_cmds.push('')

    list_cmds.push("## Project directory on the shared volume")
    list_cmds.push("docker run --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"mkdir -p $PROJECT_DIR\"")
    list_cmds.push('')

    run_step_ids = @project.runs.distinct.pluck(:step_id).compact
    mk_steps = Step.where(id: run_step_ids, docker_image_id: asap_docker_image.id).to_a
    list_dirs = mk_steps.map { |step| "$PROJECT_DIR/#{step.name}/" }
    if list_dirs.any?
      list_cmds.push("## Step output directories (one folder per pipeline step that has runs)")
      mkdir_cmd = list_dirs.map { |d| "mkdir -p #{d}" }.join(' && ')
      list_cmds.push("docker run --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"#{mkdir_cmd}\"")
      list_cmds.push('')
    end

    list_cmds.push("## Parsed LOOM file (public: wget; private: place file then symlink as below)")
    list_cmds.push("echo 'Loading parsed Loom file...'")
    if @project.public_id.present?
      list_cmds.push("docker run --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"wget -qO $PROJECT_DIR/parsing/output.loom '#{server_url}/projects/#{@project.key}/get_file?filename=parsing/output.loom'\"")
    else
      list_cmds.push("docker run --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"ln -s #{@project.key}_parsing_output.loom parsing/output.loom\"")
    end
    list_cmds.push('')

    parsing_step_id = Step.find_by(docker_image_id: asap_docker_image.id, name: 'parsing')&.id

    list_cmds.push("## Re-execute each recorded run (parsing step is skipped; LOOM is already in place)")
    list_cmds.push('')

    @project.runs.includes(:std_method, :step).order(:id).each do |run|
      next if parsing_step_id && run.step_id == parsing_step_id

      step = run.step
      next unless step

      step_dir = project_dir + step.name
      local_step_dir = "$PROJECT_DIR/#{step.name}/"
      std_method = run.std_method
      next unless std_method

      list_cmds.push('')
      list_cmds.push("## ----------------------------------------------------------------")
      list_cmds.push("## Run #{run.id}  #{@h_steps[run.step_id]&.label}  (#{reproduction_run_short_txt(run)})")
      list_cmds.push("## ----------------------------------------------------------------")
      list_cmds.push('')

      h_res = Basic.get_std_method_attrs(std_method, step)
      h_method_attr_defs = h_res[:h_attrs] || {}

      output_dir = step.multiple_runs? ? (step_dir + run.id.to_s) : step_dir
      local_output_dir = (step.multiple_runs? ? "#{local_step_dir}#{run.id}/" : local_step_dir).to_s
      list_cmds.push("## Ensure output directory exists")
      list_cmds.push("docker run --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"mkdir -p #{local_output_dir}\"")
      list_cmds.push('')

      h_method_attr_defs.each_key do |ak|
        filename = h_method_attr_defs[ak].is_a?(Hash) ? h_method_attr_defs[ak]['write_in_file'] : nil
        next if filename.blank?

        filepath = output_dir + filename
        local_filepath = "#{local_output_dir}#{filename}"
        operation = "writing file #{local_filepath}"
        list_cmds.push("## #{operation}")
        list_cmds.push("echo '-> #{operation}'")
        next unless File.exist?(filepath)

        file_body = File.read(filepath)
        safe_body = file_body.gsub("'", "'\\''")
        list_cmds.push("docker run --net=host --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"echo '#{safe_body}' > #{local_filepath}\"")
        list_cmds.push('')
      end

      h_cmd = Basic.safe_parse_json(run.command_json, {})
      if h_cmd['docker_call']
        h_cmd['docker_call'] = h_cmd['docker_call'].gsub('-v /srv/asap_run/srv:/srv', '')
        h_cmd['docker_call'] = h_cmd['docker_call'].gsub('/data/asap2:/data/asap2', '$ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR')
        h_cmd['docker_call'] = h_cmd['docker_call'].gsub('--network=asap2_asap_network', '--net=host')
      end
      h_cmd['time_call'] = nil
      %w[opts args].each do |ek|
        next unless h_cmd[ek]

        h_cmd[ek].each_index do |i|
          next unless h_cmd[ek][i] && h_cmd[ek][i]['value']

          h_cmd[ek][i]['value'] = h_cmd[ek][i]['value'].to_s.gsub(project_dir.to_s, '$PROJECT_DIR')
        end
      end

      db_meta = h_cmd['db_json']
      if db_meta.is_a?(Hash)
        df = File.basename((db_meta['filename'] || 'db.json').to_s)
        if df.present? && df != '.'
          db_filepath = output_dir + df
          local_db_path = "#{local_output_dir}#{df}"
          db_operation = "writing #{df} (annot dump for de.v8)"
          list_cmds.push("## #{db_operation}")
          list_cmds.push("echo '-> #{db_operation}'")
          db_body = nil
          db_body = File.read(db_filepath.to_s) if File.exist?(db_filepath.to_s)
          if db_body.blank? && db_meta['annot_ids'].is_a?(Array) && db_meta['annot_ids'].any?
            pl = Basic.de_db_json_payload_from_annot_ids(db_meta['annot_ids'], @project.id)
            db_body = JSON.generate(pl) if pl && pl['annots'].present?
          end
          if db_body.present?
            safe_db = db_body.gsub("'", "'\\''")
            list_cmds.push("docker run --net=host --entrypoint '/bin/sh' --rm -v $ASAP_PROJECTS_DIR:$ASAP_PROJECTS_DIR #{docker_name} -c \"echo '#{safe_db}' > #{local_db_path}\"")
            list_cmds.push('')
          else
            list_cmds.push("## #{db_operation} skipped (file missing on server and annot_ids could not rebuild payload)")
            list_cmds.push('')
          end
        end
      end

      h_run_attrs = run.attrs_json.present? ? Basic.safe_parse_json(run.attrs_json, {}) : {}
      h_std_method_attrs = { run.std_method_id => h_method_attr_defs }
      attrs_txt = helpers.display_run_attrs_txt(run, h_run_attrs, h_std_method_attrs)
      operation = "Running #{@h_steps[run.step_id]&.label} [#{run.id}] [#{reproduction_run_short_txt(run)}] (#{attrs_txt})"
      list_cmds.push("## #{operation}")
      list_cmds.push("echo '-> #{operation}'")
      list_cmds.push('')

      cmd_line = Basic.build_cmd(h_cmd)
      cmd_line = cmd_line.gsub(project_dir.to_s, '$PROJECT_DIR')
      cmd_line = cmd_line.gsub(/postgres:\d+\/asap_data_v\d+/, "$ASAP_DATA_DB_HOST:$ASAP_DATA_DB_PORT/#{asap_data_db}")
      cmd_line = cmd_line.gsub(/postgres:\d+\/asap2_data_v\d+/, "$ASAP_DATA_DB_HOST:$ASAP_DATA_DB_PORT/#{asap_data_db}")
      list_cmds.push("## Command")
      list_cmds.push(cmd_line)
      list_cmds.push('')
    end

    send_data list_cmds.join("\n"),
              filename: "ASAP_analysis_#{@project.key}.sh",
              type: 'text/plain; charset=utf-8',
              disposition: 'inline'
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
      run = nil
      h_file_by_id = {}
      if run_id
        run = Run.find_by(id: run_id, project_id: @project.id)
        if run
          h_outputs = Basic.safe_parse_json(run.output_json, {})
          h_outputs.each_key do |k|
            h_outputs[k].each_key do |k2|
              t = k2.split(":")
              relative_path = t[0]
              full_path = project_dir + relative_path
              h_file_by_id[h_outputs[k][k2]['onum']] = { :filename => h_outputs[k][k2]['filename'], :filepath => full_path }
            end
          end
          step_name = run.step&.name
        end
      end

      if run && publication_snapshot_reader?(@project) && !@project.locked_from_publication?(run)
        render plain: 'Not authorized to access this file.', status: 403
        return
      end
  
      filepath = nil
      filename = nil
      if params[:onum]
        entry = h_file_by_id[params[:onum].to_i]
        if entry
          filename = entry[:filename]
          filepath = entry[:filepath]
        end
      elsif params[:filename]
        filename = params[:filename]
        # Use @project.key instead of params[:key] since we already have the project loaded
        # File layout matches RunExecutionJob: step/run_id/filename only when step.multiple_runs;
        # otherwise step/filename (e.g. parsing/output.loom).
        # Check if "users" is already in USER_DATA_DIR to avoid double "users"
        user_data_dir = ENV["USER_DATA_DIR"].to_s.chomp('/')
        base_dir = user_data_dir.end_with?("/users") || user_data_dir.end_with?("users") ? Pathname.new(user_data_dir) : Pathname.new(user_data_dir) + "users"
        tmp_dir = base_dir + @project.user_id.to_s + @project.key
        tmp_dir += step_name if step_name
        tmp_dir += params[:run_id].to_s if params[:run_id].present? && run&.step&.multiple_runs
        filepath = tmp_dir + filename
        Rails.logger.info "get_file: Constructed filepath for filename param: #{filepath}"
      end

      project_root = base_dir + @project.user_id.to_s + @project.key
      unless filepath.nil? || get_file_path_within_project_root?(project_root, filepath)
        Rails.logger.warn "get_file: Rejected path outside project directory (project #{@project.id}): #{filepath}"
        render plain: "Invalid file path", status: 400
        return
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

        # Before serving a loom (summary LOOM/H5AD modal, data-view download, etc.):
        # refresh /attrs/analysis_pipeline and /attrs/anndata_mapping from current Annots.
        # H5AD is produced asynchronously by export_h5ad / loom_to_h5ad (SLURM); get_file only serves.
        if filepath.to_s.match?(/\.loom\z/i)
          ensure_analysis_json_before_download!(project_root, filepath)
        end

        if File.exist? filepath
          if ['exec.err', 'exec.out'].include? filename
            content = File.read(filepath)
            content.gsub!(project_dir.to_s, "$PROJECT_DIR")
            send_data content, type: params[:content_type] || 'text', # type: 'application/octet-stream'                                                                                                                                           
            x_sendfile: true, buffer_size: 512, disposition: (!params[:display]) ? ("attachment; filename=" + [@project.key, step_name,  run_id, File.basename(filename)].compact.join("_")) : ''
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
            
            disposition = (!params[:display]) ? ("attachment; filename=" + [@project.key, step_name, run_id, File.basename(filename)].compact.join("_")) : 'inline'
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
    project_session_key = @project.id.to_s
    session[:clust_comparison][project_session_key] ||= (session[:clust_comparison][@project.id] || {})
    session[:clust_comparison][project_session_key]['op'] ||= "1"

    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

    %w[run_id1 run_id2 op].each do |key|
      session[:clust_comparison][project_session_key][key] = params[key] if params[key].present?
    end

    @res = []
    p = session[:clust_comparison][project_session_key]
    @vals = []
    @h_runs = {}

    if p['run_id1'].present? && p['run_id2'].present? && p['op'].present?
      list_run_ids = [p['run_id1'], p['run_id2']]
      Run.where(id: list_run_ids).each { |r| @h_runs[r.id.to_s] = r }
      annots = Annot.light.where(run_id: list_run_ids).to_a
      @h_annots = {}
      annots.each { |a| @h_annots[a.run_id.to_s] = a }

      @list_cats = []
      list_run_ids.each do |e|
        annot = @h_annots[e.to_s]
        unless annot
          @list_cats.push([])
          @vals.push({})
          next
        end

        loom_file = @project_dir + annot.filepath
        cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata -loom #{loom_file} -meta \"#{annot.name}\" -names"
        tmp_res = Basic.safe_parse_json(`#{cmd}`, {})

        cats = Basic.safe_parse_json(annot.list_cat_json, [])
        if cats.blank? && tmp_res['values'].is_a?(Array)
          cats = tmp_res['values'].compact.map(&:to_s).uniq.sort
        end
        @list_cats.push(cats)

        h_vals = {}
        cats.each { |cat| h_vals[cat] = [] }
        if tmp_res['values'] && tmp_res['cells']
          tmp_res['values'].each_index do |i|
            key = tmp_res['values'][i].to_s
            h_vals[key] ||= []
            h_vals[key] << tmp_res['cells'][i]
          end
        end
        @vals.push(h_vals)
      end

      if @list_cats[0].present? && @list_cats[1].present?
        @list_cats[0].each_index do |i|
        @res[i] = []
        set1 = @vals[0][@list_cats[0][i]]
        next unless set1
        @list_cats[1].each_index do |j|
          set2 = @vals[1][@list_cats[1][j]]
          @res[i][j] = case p['op']
                        when "1" then set1 - set2
                        when "2" then set2 - set1
                        else          set1 & set2
                        end
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
    @runs = apply_publication_snapshot_to_runs(@project.runs.where(step_id: de_step.id)).includes(:annots).order(created_at: :desc)
    annots = Annot.light.where(run_id: @runs.map(&:id)).to_a

    @h_de_filter = Basic.safe_parse_json(@project.de_filter_json, { 'fc_cutoff' => 2, 'fdr_cutoff' => 0.05 })

    if params[:filter].present?
      new_fc = params[:filter][:fc_cutoff].to_f
      new_fdr = params[:filter][:fdr_cutoff].to_f
      if editable?(@project)
        @project.update_attribute(:de_filter_json, { fc_cutoff: new_fc, fdr_cutoff: new_fdr }.to_json)
      end
      @h_de_filter = { 'fc_cutoff' => new_fc, 'fdr_cutoff' => new_fdr }
    end

    Rails.logger.info(
      "[filter_de_results] project_id=#{@project.id} user_id=#{current_user&.id || 'guest'} " \
      "cache_key=#{de_filter_cache_key} runs=#{@runs.size} fdr=#{@h_de_filter['fdr_cutoff']} fc=#{@h_de_filter['fc_cutoff']}"
    )

    @h_stats = run_de_filter(annots, @h_de_filter, de_runs: @runs)

    respond_to do |format|
      format.html do
        @de_table_rows = Basic.de_table_rows_for_runs(@runs.select { |r| r.status_id == 3 })
        @h_std_methods = {}
        StdMethod.where(docker_image_id: asap_docker_image.id).each { |s| @h_std_methods[s.id] = s }
        render partial: 'projects/views/de_results_table', layout: false
      end
      format.json { render json: { h_stats: @h_stats } }
    end
  end

  # GET/POST /projects/:id/viz_de_results
  def viz_de_results
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

    asap_docker_image = Basic.get_asap_docker(@project.version)
    de_step = Step.where(docker_image_id: asap_docker_image.id, name: 'de').first
    @runs = apply_publication_snapshot_to_runs(@project.runs.where(step_id: de_step.id)).includes(:annots).order(created_at: :desc)
    annots = Annot.light.where(run_id: @runs.map(&:id)).to_a

    fdr_cutoff = params[:fdr_cutoff].to_f
    fc_cutoff  = params[:fc_cutoff].to_f
    fdr_cutoff = 0.05 if fdr_cutoff <= 0
    fc_cutoff  = 2.0  if fc_cutoff  <= 0
    @h_de_filter = { 'fdr_cutoff' => fdr_cutoff, 'fc_cutoff' => fc_cutoff }

    @h_std_methods = {}
    StdMethod.where(docker_image_id: asap_docker_image.id).each { |s| @h_std_methods[s.id] = s }

    @h_stats = run_de_filter(annots, @h_de_filter, de_runs: @runs)

    respond_to do |format|
      format.json { render json: { h_stats: @h_stats } }
      format.html { render partial: 'projects/views/de_viz_results_tab', layout: false }
    end
  end

  # POST /projects/1/filter_ge_results
  def filter_ge_results
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

    asap_docker_image = Basic.get_asap_docker(@project.version)
    ge_step_ids = Step.where(docker_image_id: asap_docker_image.id, name: 'ge').pluck(:id)
    @step = Step.find_by(id: ge_step_ids.first)
    ge_runs_scope = if ge_step_ids.any?
                      @project.runs.where(step_id: ge_step_ids)
                    else
                      @project.runs.joins(:step).where(steps: { name: 'ge' })
                    end
    @runs = apply_publication_snapshot_to_runs(ge_runs_scope).includes(:annots).order(created_at: :desc)

    @h_ge_filter = Basic.safe_parse_json(@project.ge_filter_json, { 'fdr_cutoff' => 0.05 })
    requested_run_ids = []

    if params[:filter].present?
      new_fdr = params[:filter][:fdr_cutoff].to_f
      if editable?(@project)
        @project.update_attribute(:ge_filter_json, { fdr_cutoff: new_fdr }.to_json)
      end
      @h_ge_filter = { 'fdr_cutoff' => new_fdr }
      requested_run_ids = Array(params.dig(:filter, :run_ids)).map(&:to_i).select { |id| id > 0 }
    end

    if requested_run_ids.any?
      @runs = apply_publication_snapshot_to_runs(@project.runs.where(id: requested_run_ids)).includes(:annots).order(created_at: :desc)
    end

    fdr_cutoff = @h_ge_filter['fdr_cutoff'].to_f
    @h_stats = {}
    completed_runs = @runs.select { |r| r.status_id == 3 }
    completed_runs.each do |run|
      output_file = @project_dir + 'ge' + run.id.to_s + 'output.json'
      unless File.exist?(output_file)
        Rails.logger.warn("[filter_ge_results] missing_output_file run_id=#{run.id} path=#{output_file}")
        next
      end
      raw_output = File.binread(output_file)
      sanitized_output = raw_output.gsub("\\N", "\\\\N")
      sanitized_output = sanitized_output.gsub(/\\(?!["\\\/bfnrtu])/) { '\\\\' }
      sanitized_output = sanitized_output.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      sanitized_output = sanitized_output.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/, '')
      h_output = {}
      begin
        h_output = JSON.parse(sanitized_output, allow_nan: true)
      rescue JSON::ParserError, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
        Rails.logger.warn(
          "[filter_ge_results] parse_failed run_id=#{run.id} path=#{output_file} " \
          "size=#{raw_output.bytesize} error=#{e.class}: #{e.message}"
        )
        begin
          # Fallback: replace explicit invalid escape sequence from some GE outputs.
          fallback_output = sanitized_output.gsub("\\N", "\\\\N")
          h_output = JSON.parse(fallback_output, allow_nan: true)
        rescue JSON::ParserError, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e2
          Rails.logger.warn(
            "[filter_ge_results] parse_failed_fallback run_id=#{run.id} path=#{output_file} " \
            "error=#{e2.class}: #{e2.message}"
          )
          h_output = {}
        end
      end
      headers = h_output['headers'] || []
      h_fields = {}
      headers.each_index { |i| h_fields[headers[i]] = i }
      fdr_idx = h_fields['fdr']
      unless fdr_idx
        Rails.logger.warn("[filter_ge_results] missing_fdr_index run_id=#{run.id} headers_sample=#{headers.first(8).inspect}")
        next
      end
      up_count = 0
      down_count = 0
      (h_output['up'] || []).each { |e| up_count += 1 if e[fdr_idx].to_f <= fdr_cutoff }
      (h_output['down'] || []).each { |e| down_count += 1 if e[fdr_idx].to_f <= fdr_cutoff }
      @h_stats[run.id.to_s] = { 'up' => up_count, 'down' => down_count }
    end

    Rails.logger.info(
      "[filter_ge_results] project_id=#{@project.id} user_id=#{current_user&.id || 'guest'} " \
      "fdr=#{fdr_cutoff} requested_run_ids=#{requested_run_ids.inspect} " \
      "completed_runs=#{completed_runs.map(&:id).inspect} h_stats=#{@h_stats.inspect}"
    )

    @h_std_methods = {}
    StdMethod.where(docker_image_id: asap_docker_image.id).each { |s| @h_std_methods[s.id] = s }

    respond_to do |format|
      format.html { render partial: 'projects/views/ge_results_table', layout: false }
      format.json { render json: { h_stats: @h_stats } }
    end
  end

  # POST /projects/1/filter_doublet_results
  # Re-runs doublet.calling.v8.py on saved scores (dynamic threshold on the result page).
  def filter_doublet_results
    unless editable?(@project) && analyzable?(@project)
      return render json: { error: "You need edit and analysis rights to apply doublet calling filters." }, status: :forbidden
    end

    run_id = params.dig(:filter, :run_id).to_i
    method_name = params.dig(:filter, :method).to_s.presence || "auto"
    allowed_methods = %w[auto valley threshold top_n top_pct]
    unless allowed_methods.include?(method_name)
      return render json: { error: "Invalid calling method: #{method_name}" }, status: :unprocessable_entity
    end

    asap_docker_image = Basic.get_asap_docker(@project.version)
    @step = Step.where(docker_image_id: asap_docker_image.id, name: "doublet_calling").first
    unless @step
      return render json: { error: "Doublet calling step is not configured for this project version." }, status: :unprocessable_entity
    end

    run = apply_publication_snapshot_to_runs(@project.runs.where(id: run_id, step_id: @step.id)).first
    unless run && run.status_id == 3
      return render json: { error: "Completed doublet calling run not found." }, status: :not_found
    end
    if @project.locked_from_publication?(run)
      return render json: { error: helpers.publication_locked_step_message }, status: :forbidden
    end

    ctx = DoubletCallingFilterService.context_for_run(@project, run, @step)
    filter_params = {
      loom_path: ctx[:loom_path],
      input_score_meta: ctx[:input_score_meta],
      output_call_meta: ctx[:output_call_meta],
      method: method_name,
      output_dir: ctx[:filter_output_dir]
    }
    if method_name == "threshold"
      filter_params[:threshold] = params.dig(:filter, :threshold)
    elsif method_name == "top_n"
      filter_params[:n_doublets] = params.dig(:filter, :n_doublets)
    elsif method_name == "top_pct"
      filter_params[:doublet_rate] = params.dig(:filter, :doublet_rate)
    end

    result = DoubletCallingFilterService.run!(**filter_params)
    DoubletCallingFilterService.reload_call_annot!(@project, run, ctx, result)
    render json: result
  rescue DoubletCallingFilterService::FilterError => e
    Rails.logger.warn("[filter_doublet_results] #{e.class}: #{e.message}")
    render json: { error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error("[filter_doublet_results] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace&.first(8)&.join("\n"))
    render json: { error: "Doublet calling filter failed." }, status: :internal_server_error
  end

  # GET /projects/1/search_gene
  # Params (any subset): gene_id (remote genes.id), ensembl_id, gene_symbol.
  # Resolution order: gene_id; then organism_id + ensembl_id; organism_id + symbol;
  # then global ensembl_id; then global symbol (uses organism indexes when possible).
  def search_gene
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    timings = {}

    db_version = nil
    timings[:env_ms] = search_gene_step_ms do
      h_env = Basic.safe_parse_json(@project.version.env_json, {})
      db_version = asap_data_db_name_for_env(h_env, context: "search_gene")
    end

    gid_q = nil
    ens_q = nil
    sym_q = nil
    timings[:normalize_ms] = search_gene_step_ms do
      gid_q = params[:gene_id].to_s.strip
      ens_q, sym_q = normalize_search_gene_identity_params(
        ensembl_id: params[:ensembl_id],
        gene_symbol: params[:gene_symbol]
      )
    end

    cache_key =
      if gid_q.present? || ens_q.present? || sym_q.present?
        [
          "search_gene/v5",
          db_version.to_s,
          @project.organism_id.to_s,
          gid_q,
          ens_q.downcase,
          sym_q.downcase
        ]
      end

    cache_hit = true
    timings[:resolve_ms] = search_gene_step_ms do
      payload =
        if cache_key
          Rails.cache.fetch(cache_key, expires_in: GENE_DETAILS_CACHE_TTL) do
            cache_hit = false
            gene_row = search_gene_resolve_remote_gene(db_version)
            if gene_row
              { "hit" => true, "attrs" => gene_row.attributes.slice(*GENE_DETAILS_CACHE_ATTRS) }
            else
              { "hit" => false }
            end
          end
        else
          cache_hit = false
          { "hit" => false }
        end

      if payload["hit"] && payload["attrs"].is_a?(Hash) && payload["attrs"]["id"].to_i <= 0
        refreshed_gene = search_gene_resolve_remote_gene(db_version)
        payload["attrs"]["id"] = refreshed_gene.id if refreshed_gene
      end

      @gene = payload["hit"] ? OpenStruct.new(payload["attrs"]) : nil
    end

    # Gene-set memberships are loaded asynchronously (search_gene_memberships).
    @gene_set_collection_memberships = nil
    timings[:release_feature_ms] = search_gene_step_ms do
      @ensembl_release_feature = search_gene_ensembl_release_feature(@gene, db_version)
    end

    timings[:render_ms] = search_gene_step_ms do
      response.headers["Cache-Control"] = "no-store, max-age=0"
      response.headers["Pragma"] = "no-cache"
      render partial: 'projects/views/gene_details', layout: false
    end

    timings[:total_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
    Rails.logger.info(
      "[search_gene.timing] project=#{@project.key} ens=#{ens_q.presence || '-'} sym=#{sym_q.presence || '-'} " \
      "gid=#{gid_q.presence || '-'} hit=#{@gene.present?} cache_hit=#{cache_hit} db=#{db_version} " \
      "env_ms=#{timings[:env_ms]} normalize_ms=#{timings[:normalize_ms]} resolve_ms=#{timings[:resolve_ms]} " \
      "release_feature_ms=#{timings[:release_feature_ms]} render_ms=#{timings[:render_ms]} total_ms=#{timings[:total_ms]}"
    )
  end

  # GET /projects/1/search_gene_memberships
  # Params: gene_id (preferred), and/or ensembl_id / gene_symbol (same as search_gene).
  def search_gene_memberships
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    timings = {}

    db_version = nil
    timings[:env_ms] = search_gene_step_ms do
      h_env = Basic.safe_parse_json(@project.version.env_json, {})
      db_version = asap_data_db_name_for_env(h_env, context: "search_gene_memberships")
    end

    timings[:resolve_ms] = search_gene_step_ms do
      gene =
        if params[:gene_id].to_s.strip.match?(/\A\d+\z/) && params[:gene_id].to_i.positive?
          RemoteGene.find_by_remote_id(params[:gene_id].to_i, version: db_version)
        end
      gene ||= search_gene_resolve_remote_gene(db_version)
      @gene = gene
    end

    timings[:memberships_ms] = search_gene_step_ms do
      @gene_set_collection_memberships = build_gene_set_collection_memberships_for_gene(@gene, db_version)
    end

    timings[:render_ms] = search_gene_step_ms do
      response.headers["Cache-Control"] = "no-store, max-age=0"
      response.headers["Pragma"] = "no-cache"
      if @gene
        render partial: 'projects/views/gene_details_memberships', layout: false
      else
        render html: '<div class="pt-2 border-t border-gray-200"><div class="mt-2 text-sm text-gray-500">Gene set collections unavailable.</div></div>'.html_safe
      end
    end

    timings[:total_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
    Rails.logger.info(
      "[search_gene_memberships.timing] project=#{@project.key} gene_id=#{@gene&.id || params[:gene_id]} " \
      "collections=#{Array(@gene_set_collection_memberships).size} " \
      "env_ms=#{timings[:env_ms]} resolve_ms=#{timings[:resolve_ms]} " \
      "memberships_ms=#{timings[:memberships_ms]} render_ms=#{timings[:render_ms]} total_ms=#{timings[:total_ms]}"
    )
  end

  # GET /projects/1/search_gene_membership_items
  # Params: gene_id, collection_id
  def search_gene_membership_items
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: "search_gene_membership_items")
    collection_id = params[:collection_id].to_s.strip

    gene =
      if params[:gene_id].to_s.strip.match?(/\A\d+\z/) && params[:gene_id].to_i.positive?
        RemoteGene.find_by_remote_id(params[:gene_id].to_i, version: db_version)
      end
    gene ||= search_gene_resolve_remote_gene(db_version)

    memberships = build_gene_set_collection_memberships_for_gene(gene, db_version)
    collection = Array(memberships).find { |entry| entry[:id].to_s == collection_id }

    @gene = gene
    @gene_set_membership_collection_id = collection_id
    @gene_set_membership_collection_label = collection ? collection[:label].to_s : ''
    @gene_set_membership_items = collection ? Array(collection[:gene_sets]) : []

    response.headers["Cache-Control"] = "no-store, max-age=0"
    response.headers["Pragma"] = "no-cache"
    total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
    Rails.logger.info(
      "[search_gene_membership_items.timing] project=#{@project.key} gene_id=#{gene&.id || params[:gene_id]} " \
      "collection_id=#{collection_id} items=#{@gene_set_membership_items.size} total_ms=#{total_ms}"
    )
    render partial: 'projects/views/gene_details_membership_items', layout: false
  end

  # GET /projects/1/search_gene_set_items
  def search_gene_set_items
    require 'ostruct'
    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: "search_gene_set_items")

    @gsi = nil
    @genes = []
    @h_all_genes = {}
    @h_enriched_genes = {}
    @gsi_redirected_from = nil

    ge_run = Run.find_by(id: params[:ge_run_id])
    h_ge_run_attrs = ge_run ? Basic.safe_parse_json(ge_run.attrs_json, {}) : {}
    gene_set_id = params[:gene_set_id] || h_ge_run_attrs['gene_set_id']
    requested_identifier = params[:identifier].to_s.strip
    resolved = AsapData::GoTermReplacement.chain_resolve(requested_identifier)
    lookup_identifier = resolved[:identifier]
    @gsi_redirected_from = resolved[:redirected_from]

    if gene_set_id.present? && lookup_identifier.present?
      RemoteGene.with_remote(db_version) do
        conn = RemoteGene.connection
        gsi_rows = conn.select_all(
          "SELECT * FROM gene_set_items WHERE gene_set_id = #{gene_set_id.to_i} AND identifier = #{conn.quote(lookup_identifier)}"
        )
        # If replacement is in another GO split gene_set for this organism, resolve via identifier only.
        if gsi_rows.empty? && @gsi_redirected_from.present?
          gsi_rows = conn.select_all(<<~SQL)
            SELECT gsi.*
            FROM gene_set_items gsi
            JOIN gene_sets gs ON gs.id = gsi.gene_set_id
            WHERE gs.organism_id = #{@project.organism_id.to_i}
              AND gsi.identifier = #{conn.quote(lookup_identifier)}
              AND gs.label IN ('GO Biological Processes','GO Cellular Components','GO Molecular Functions')
            LIMIT 1
          SQL
        end
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

        filtered_filename = "#{de_filter_cache_key}_#{input_de['run_id']}_#{h_ge_run_attrs['fc_cutoff']}_#{h_ge_run_attrs['fdr_cutoff']}_filtered_ids.json"
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

  # GET /projects/1/search_visualization_metadata?q=...
  # Searches metadata names, category names and annotation content used by the visualization view.
  def search_visualization_metadata
    query = params[:q].to_s.strip
    return render json: { query: query, results: [] } if query.blank?

    limit = params[:limit].to_i
    limit = 150 if limit <= 0
    limit = 500 if limit > 500
    safe_text = lambda do |value|
      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').scrub
    rescue StandardError
      value.to_s
    end
    metadata_label = lambda do |annot|
      raw_name = safe_text.call(annot&.name)
      cleaned = raw_name.gsub('/col_attrs/', '').gsub('/row_attrs/', '').gsub('/attrs/', '').gsub(/\Aattrs\//, '')
      cleaned.present? ? cleaned : "Annotation #{annot&.id}"
    end
    global_attr_name = lambda do |annot|
      name = annot&.name.to_s
      name.start_with?('/attrs/') || name.start_with?('attrs/')
    end
    query_lc = safe_text.call(query).downcase

    metadata_scope = Annot.joins(:data_type)
                         .where(project_id: @project.id, data_types: { name: %w[DISCRETE NUMERIC] })
                         .select(:id, :name, :categories_json, :list_cat_json, :data_type_id, :run_id)
    metadata_rows = metadata_scope.to_a
    metadata_by_id = metadata_rows.index_by(&:id)

    asap_docker_image = Basic.get_asap_docker(@project.version)
    de_step = asap_docker_image && Step.where(docker_image_id: asap_docker_image.id, name: 'de').first
    de_runs_by_id = {}
    if de_step
      de_runs_by_id = apply_publication_snapshot_to_runs(
        @project.runs.where(step_id: de_step.id, status_id: 3)
      ).includes(:std_method).index_by(&:id)
    end
    de_table_rows_by_annot_id = {}
    de_table_rows_by_run_id = {}
    if de_runs_by_id.any?
      Basic.de_table_rows_for_runs(de_runs_by_id.values).each do |row|
        run = row[:run]
        next unless run

        de_table_rows_by_run_id[run.id] ||= []
        de_table_rows_by_run_id[run.id] << row
        if row[:annot]
          de_table_rows_by_annot_id[row[:annot].id] = row
        end
      end
    end

    results = []
    seen = Set.new

    metadata_rows.each do |metadata|
      de_run = de_runs_by_id[metadata.run_id]
      if de_run && global_attr_name.call(metadata)
        metadata_name = metadata_label.call(metadata)
        std_method = de_run.std_method
        method_label = if std_method
                         safe_text.call(std_method.label.presence || std_method.name.presence || 'N/A')
                       else
                         'N/A'
                       end
        run_num = de_run.num.presence || de_run.id
        table_row = de_table_rows_by_annot_id[metadata.id]
        if table_row.nil?
          table_row = Array(de_table_rows_by_run_id[de_run.id]).find { |row| row[:annot].nil? } ||
                      Array(de_table_rows_by_run_id[de_run.id]).first
        end
        reference_group = safe_text.call(table_row && table_row[:reference_group])
        display_label = "DE ##{run_num}"
        display_label = "#{display_label} · #{method_label}" if method_label.present? && method_label != 'N/A'
        display_label = "#{display_label} · #{reference_group}" if reference_group.present?

        search_terms = [
          ['DE result', display_label],
          ['Metadata name', metadata_name],
          ['DE run', "##{run_num}"],
          ['DE run', run_num.to_s],
          ['Method', method_label],
          ['Reference group', reference_group],
          ['DE', 'DE'],
          ['Differential expression', 'differential expression']
        ]
        match = search_terms.find do |_label, value|
          value.present? && value.to_s.downcase.include?(query_lc)
        end
        if match
          match_label, match_value = match
          key = "de:#{metadata.id}:#{match_label.downcase}:#{match_value.to_s.downcase}"
          unless seen.include?(key)
            results << {
              type: 'de_result',
              match_value: match_value.to_s,
              match_label: match_label,
              metadata_id: metadata.id,
              metadata_name: metadata_name,
              annot_id: metadata.id,
              run_id: de_run.id,
              run_num: run_num,
              method_name: method_label,
              reference_group: reference_group.presence,
              display_label: display_label
            }
            seen << key
          end
        end
        break if results.length >= limit
        next
      end

      metadata_name = metadata_label.call(metadata)
      if metadata_name.downcase.include?(query_lc)
        key = "meta:#{metadata.id}:#{metadata_name.downcase}"
        unless seen.include?(key)
          results << {
            type: 'metadata_name',
            match_value: metadata_name,
            metadata_id: metadata.id,
            metadata_name: metadata_name
          }
          seen << key
          break if results.length >= limit
        end
      end
      next if results.length >= limit

      categories = []
      if metadata.categories_json.present?
        parsed_categories =
          begin
            JSON.parse(safe_text.call(metadata.categories_json))
          rescue JSON::ParserError, ArgumentError
            nil
          end
        categories = if parsed_categories.is_a?(Hash)
                       parsed_categories.keys
                     elsif parsed_categories.is_a?(Array)
                       parsed_categories
                     else
                       []
                     end
      end

      categories.each_with_index do |category, idx|
        category_name = safe_text.call(category)
        next unless category_name.downcase.include?(query_lc)

        key = "cat:#{metadata.id}:#{idx}:#{category_name.downcase}"
        next if seen.include?(key)

        results << {
          type: 'category_name',
          match_value: category_name,
          metadata_id: metadata.id,
          metadata_name: metadata_name,
          category_name: category_name,
          cat_idx: idx
        }
        seen << key
        break if results.length >= limit
      end
      break if results.length >= limit
    end

    if results.length < limit
      clas = Cla.active.where(project_id: @project.id, annot_id: metadata_by_id.keys)
               .select(
                 :id, :annot_id, :cat, :cat_idx, :name, :comment,
                 :sorted_cell_ontology_term_ids, :cell_ontology_term_ids,
                 :sorted_up_gene_ids, :up_gene_ids,
                 :sorted_down_gene_ids, :down_gene_ids
               )
               .to_a

      cot_ids = clas.flat_map do |cla|
        parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
      end.map { |value| value.to_i }.select(&:positive?).uniq

      cot_map = {}
      if cot_ids.any?
        CellOntologyTerm.where(id: cot_ids).pluck(:id, :identifier, :name).each do |id, identifier, name|
          cot_map[id] = { identifier: identifier.to_s, name: name.to_s }
        end
      end

      h_env = @project.version ? Basic.safe_parse_json(@project.version.env_json, {}) : {}
      db_version = asap_data_db_name_for_env(h_env, context: "search_visualization_metadata")

      gene_ids = clas.flat_map do |cla|
        [
          parse_cla_field(cla.sorted_up_gene_ids.presence || cla.up_gene_ids),
          parse_cla_field(cla.sorted_down_gene_ids.presence || cla.down_gene_ids)
        ].flatten
      end.map { |value| value.to_s.strip }.reject(&:blank?).uniq

      gene_map = {}
      loom_gene_map = project_cla_gene_info_by_stable_id(@project)
      gene_ids.each do |gid|
        info = loom_gene_map[gid]
        next unless info

        gene_map[gid] = { symbol: info[:symbol].to_s, ensembl_id: info[:ensembl_id].to_s }
      end

      # Legacy rows may still store asap_data genes.id; fill only unresolved ids.
      unresolved_gene_ids = gene_ids.reject { |gid| gene_map.key?(gid) }.map(&:to_i).select(&:positive?).uniq
      if db_version.present? && unresolved_gene_ids.any?
        RemoteGene.with_remote(db_version) do
          RemoteGene.where(id: unresolved_gene_ids).pluck(:id, :name, :ensembl_id).each do |gid, symbol, ensembl_id|
            gene_map[gid.to_s] = { symbol: symbol.to_s, ensembl_id: ensembl_id.to_s }
          end
        end
      end

      clas.each do |cla|
        metadata = metadata_by_id[cla.annot_id]
        next unless metadata

        metadata_name = metadata_label.call(metadata)
        category_name = safe_text.call(cla.cat)
        annotation_terms = []
        annotation_terms << ['Annotation name', safe_text.call(cla.name)]
        annotation_terms << ['Annotation comment', safe_text.call(cla.comment)]

        parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids).each do |cot_id|
          cot = cot_map[cot_id.to_i]
          next unless cot
          annotation_terms << ['Ontology term', safe_text.call(cot[:identifier])]
          annotation_terms << ['Ontology term', safe_text.call(cot[:name])]
        end

        parse_cla_field(cla.sorted_up_gene_ids.presence || cla.up_gene_ids).each do |gene_id|
          gid = safe_text.call(gene_id)
          g = gene_map[gid]
          annotation_terms << ['Up gene id', gid]
          if g
            annotation_terms << ['Up gene symbol', safe_text.call(g[:symbol])]
            annotation_terms << ['Up gene Ensembl', safe_text.call(g[:ensembl_id])]
          end
        end

        parse_cla_field(cla.sorted_down_gene_ids.presence || cla.down_gene_ids).each do |gene_id|
          gid = safe_text.call(gene_id)
          g = gene_map[gid]
          annotation_terms << ['Down gene id', gid]
          if g
            annotation_terms << ['Down gene symbol', safe_text.call(g[:symbol])]
            annotation_terms << ['Down gene Ensembl', safe_text.call(g[:ensembl_id])]
          end
        end

        match = annotation_terms.find do |_label, value|
          value.present? && value.to_s.downcase.include?(query_lc)
        end
        next unless match

        match_label, match_value = match
        key = "annot:#{cla.id}:#{match_label.downcase}:#{match_value.to_s.downcase}"
        next if seen.include?(key)

        results << {
          type: 'annotation',
          match_value: match_value.to_s,
          match_label: match_label,
          metadata_id: cla.annot_id,
          metadata_name: metadata_name,
          category_name: category_name,
          cat_idx: cla.cat_idx,
          cla_id: cla.id
        }
        seen << key
        break if results.length >= limit
      end
    end

    render json: { query: query, results: results }
  rescue StandardError => e
    Rails.logger.error("[search_visualization_metadata] #{e.class}: #{e.message}")
    render json: { error: 'Unable to search visualization metadata' }, status: :internal_server_error
  end

  # GET /projects/1/data_content
  # Returns just the right panel content for AJAX loading
  def data_content
    with_request_profile('projects#data_content', view: 'data') do
    # Set view type to data
    @view_type = 'data'
    
    # Get project type for display
    @project_type = @project.project_type
    
    @selected_loom_file = params[:loom_file].presence
    @selected_data_type = params[:data_type].presence || 'matrices'

    # Scope to one loom when the client asks for a specific file (AJAX right panel).
    # Loading every Annot for the project is very slow on large projects.
    annot_relation = Annot.light.where(project_id: @project.id).where.not(filepath: nil)
    annot_relation = annot_relation.where(filepath: @selected_loom_file) if @selected_loom_file.present?

    all_annots = apply_publication_snapshot_to_annots(
      annot_relation.includes(:step, :data_type, :data_transformation, run: [:std_method]).order(:name)
    ).to_a

    filepath_info = if @selected_loom_file.present?
      matrix_annot = all_annots.find { |a| a.name == '/matrix' }
      if matrix_annot
        {
          @selected_loom_file => {
            step_rank: matrix_annot.step&.rank,
            run_id: matrix_annot.run_id
          }
        }
      else
        {}
      end
    else
      build_filepath_info_from_matrix_annots(all_annots)
    end

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

      load_global_attr_card_values!(
        @selected_loom_file,
        @annots_by_loom_and_type[@selected_loom_file][:global]
      ) if @selected_data_type == 'global'
    end
    
    # Store filepath info for use in helper
    @filepath_info = filepath_info
    
    # Preload runs and steps for helper
    run_ids = filepath_info.values.map { |info| info[:run_id] }.compact.uniq
    @loom_file_runs = Run.where(id: run_ids).includes(:step, :std_method).index_by(&:id) if run_ids.any?
    @loom_file_runs ||= {}

    if editable?(@project)
      @sim_step_options = helpers.sim_step_options_for_project(@project)
    end
    
    respond_to do |format|
      format.html { render partial: 'projects/views/data_content', layout: false }
    end
    end
  end

  # POST /projects/1/prepare_metadata
  def prepare_metadata
    raw_content =
      if params[:file].present?
        params[:file].read
      else
        params[:content] || ""
      end

    input_type_id = params[:input_type_id].to_s
    metadata_type_id = params[:metadata_type_id].to_s
    delimiter_idx = (params[:delimiter] || "0").to_i
    name = params[:name] || ""
    has_header = params[:has_header].to_s != "0"

    staged = MetadataImportPrepareStaging.call(
      project: @project,
      user_id: current_user&.id || 1,
      raw_content: raw_content,
      metadata_type_id: metadata_type_id,
      input_type_id: input_type_id,
      delimiter_idx: delimiter_idx,
      name: name,
      has_header: has_header
    )

    final_content = staged[:final_content]
    header_name = staged[:header_name]

    response = {
      fu_id: staged[:fu].id,
      duplicates: staged[:duplicates],
      preview_lines: final_content.first(20),
      total_lines: final_content.size,
      preview: MetadataImportPreviewBuilder.call(
        final_content: final_content,
        duplicates: staged[:duplicates],
        metadata_type_id: metadata_type_id,
        input_type_id: input_type_id,
        name: header_name.presence || name,
        project: @project,
        loom_file: params[:loom_file]
      )
    }
    response[:header_name] = header_name if header_name.present?

    validation = MetadataFileImportValidation.analyze(
      project: @project,
      metadata_type_id: metadata_type_id,
      input_type_id: input_type_id,
      name: name,
      header_name: header_name,
      has_header: has_header,
      raw_content: raw_content
    )
    response[:import_validation] = import_validation_json(validation)

    render json: response
  end

  # POST /projects/:id/prepare_metadata_from_project_annot
  # Stages matrix import content from a readable source project's {Annot}; reuses collision / reserved checks.
  def prepare_metadata_from_project_annot
    source_project_id = params[:source_project_id].to_i
    source_annot_id = params[:source_annot_id].to_i

    unless source_project_id.positive? && source_annot_id.positive?
      return render json: { error: "source_project_id and source_annot_id are required" }, status: :unprocessable_entity
    end

    source_project = Project.find_by(id: source_project_id)
    unless source_project
      return render json: { error: "Source project not found" }, status: :not_found
    end

    unless readable?(source_project)
      return render json: { error: "You do not have access to the source project" }, status: :forbidden
    end

    annot = Annot.find_by(id: source_annot_id, project_id: source_project.id)
    unless annot
      return render json: { error: "Metadata column not found on the source project" }, status: :not_found
    end

    unless annot.latest_version
      return render json: { error: "Only the latest version of a metadata column can be imported this way." }, status: :unprocessable_entity
    end

    t_pcs = @project.project_cell_set_id
    s_pcs = source_project.project_cell_set_id
    unless t_pcs.present? && s_pcs.present? && t_pcs == s_pcs
      return render json: { error: "Source project does not share the same cell-set identity as this project." }, status: :unprocessable_entity
    end

    h = MetadataImportDiscoveryHelpers
    dim = h.dimension_alignment(@project, source_project)
    auth = MetadataNameAuthorizationService.call(project: @project, name: annot.name)
    ok_compat, reason = h.compatibility_for_annot(@project, annot, dim, auth)
    unless ok_compat
      return render json: { error: reason.presence || "This metadata cannot be imported from the source project." }, status: :unprocessable_entity
    end

    built = MetadataImportMatrixFromAnnotBuilder.call(annot: annot)
    unless built[:ok]
      return render json: { error: built[:error] }, status: built[:status] || :unprocessable_entity
    end

    raw_content = built[:raw_content]
    metadata_type_id = built[:metadata_type_id]
    input_type_id = "2"
    has_header = true

    staged = MetadataImportPrepareStaging.call(
      project: @project,
      user_id: current_user&.id || 1,
      raw_content: raw_content,
      metadata_type_id: metadata_type_id,
      input_type_id: input_type_id,
      delimiter_idx: 0,
      name: "",
      has_header: has_header
    )

    final_content = staged[:final_content]

    validation = MetadataFileImportValidation.analyze(
      project: @project,
      metadata_type_id: metadata_type_id,
      input_type_id: input_type_id,
      name: "",
      header_name: nil,
      has_header: has_header,
      raw_content: raw_content
    )

    response = {
      fu_id: staged[:fu].id,
      duplicates: staged[:duplicates],
      preview_lines: final_content.first(20),
      total_lines: final_content.size,
      metadata_type_id: metadata_type_id,
      input_type_id: input_type_id,
      import_validation: import_validation_json(validation),
      preview: MetadataImportPreviewBuilder.call(
        final_content: final_content,
        duplicates: staged[:duplicates],
        metadata_type_id: metadata_type_id,
        input_type_id: input_type_id,
        name: nil,
        project: @project,
        loom_file: params[:loom_file]
      )
    }

    render json: response
  end

  # POST /projects/1/do_import_metadata
  def do_import_metadata
    fu_id = params[:fu_id]
    metadata_type_id = params[:metadata_type_id].to_s
    loom_file = params[:loom_file]
    input_type_id = params[:input_type_id].to_s
    name = params[:name].to_s
    header_name = params[:header_name].to_s
    has_header = params[:has_header]
    collision_resolution = params[:collision_resolution].to_s

    unless fu_id
      render json: { status: 'error', message: 'No file upload ID provided' }, status: :unprocessable_entity
      return
    end

    fu = Fu.find_by(id: fu_id)
    unless fu
      render json: { status: 'error', message: 'File upload not found' }, status: :not_found
      return
    end

    unless fu.project_id == @project.id
      render json: { status: 'error', message: 'Upload does not belong to this project' }, status: :forbidden
      return
    end

    submission = MetadataFileImportSubmission.prepare_staged_file!(
      project: @project,
      fu: fu,
      metadata_type_id: metadata_type_id,
      input_type_id: input_type_id.presence || "1",
      name: name,
      header_name: header_name,
      has_header: has_header,
      collision_resolution: collision_resolution,
      loom_file: loom_file
    )
    unless submission[:ok]
      payload = { status: 'error', message: submission[:error] }
      payload[:dependent_run_ids] = submission[:dependent_run_ids] if submission[:dependent_run_ids].present?
      render json: payload, status: submission[:status] || :unprocessable_entity
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
      program: "rails parse_metadata[#{new_run.id}]",
      host_name: 'localhost',
      opts: [],
      args: []
    }

    new_run.update(
      command_json: h_command.to_json,
      attrs_json: h_attrs.to_json
    )

    Basic.upd_project_step(@project, import_metadata_step.id)
    Basic.exec_run(Rails.logger, new_run)

    render json: { status: 'ok', run_id: new_run.id }
  end

  # GET /projects/:id/related_clone_projects?scope=current|my_clones|all_children|lineage
  def related_clone_projects
    result = CloneRelatedProjectsQuery.call(
      project: @project,
      scope: params[:scope].presence || 'current',
      user: current_user,
      readable_if: ->(project) { readable?(project) }
    )
    unless result[:ok]
      return render json: { status: 'error', message: result[:error] }, status: :unprocessable_entity
    end

    render json: { status: 'ok', scope: result[:scope], projects: result[:projects] }
  end

  # GET /projects/:id/federated_annotations?project_ids[]=&ontology_term_type_id=
  def federated_annotations
    project_ids = Array(params[:project_ids]).presence || [@project.id]
    result = FederatedAnnotationsQuery.call(
      project_ids: project_ids,
      ontology_term_type_id: params[:ontology_term_type_id],
      readable_if: ->(project) { readable?(project) },
      current_project: @project
    )
    unless result[:ok]
      return render json: { status: 'error', message: result[:error] }, status: :unprocessable_entity
    end

    render json: {
      status: 'ok',
      annotations: result[:annotations],
      annotation_type_options: result[:annotation_type_options],
      annotation_metadata_by_type: result[:annotation_metadata_by_type],
      consensus_metadata_by_type: result[:consensus_metadata_by_type]
    }
  end

  # GET /projects/:id/consensus_annotation_support
  def consensus_annotation_support
    result = ConsensusAnnotationSupportService.call(
      project: @project,
      user: current_user,
      readable_if: ->(project) { readable?(project) }
    )
    unless result[:ok]
      return render json: { status: 'error', message: result[:error] }, status: :unprocessable_entity
    end

    render json: { status: 'ok', by_type: result[:by_type] }
  end

  # POST /projects/:id/preview_consensus_annotation
  def preview_consensus_annotation
    ontology_term_type_id = params[:ontology_term_type_id].presence&.to_i
    unless ontology_term_type_id&.positive?
      return render json: { status: 'error', message: 'ontology_term_type_id is required' }, status: :unprocessable_entity
    end

    unless @project.filesystem_project_data_present?
      return render json: {
        status: 'error',
        message: 'Project data files are not available on this server. Unarchive the project before previewing consensus metadata.'
      }, status: :unprocessable_entity
    end

    project_ids = Array(params[:project_ids]).presence || [@project.id]
    preview = ConsensusAnnotationPreviewService.call(
      project: @project,
      ontology_term_type_id: ontology_term_type_id,
      project_ids: project_ids,
      readable_if: ->(project) { readable?(project) },
      equal_rank_choices: params[:equal_rank_choices] || {},
      collision_choices: params[:collision_choices] || {},
      build_vectors: false
    )
    unless preview[:ok]
      return render json: { status: 'error', message: preview[:error] }, status: :unprocessable_entity
    end

    render json: preview.merge(status: 'ok')
  end

  # POST /projects/:id/export_consensus_annotation
  # Builds /col_attrs/_asap_consensus_<annotation_type_tag> from CLAs of one ontology type
  # (small cell sets first; assigned cells stay fixed), backs up any differing existing
  # column, then writes the loom dataset and Annot immediately.
  def export_consensus_annotation
    ontology_term_type_id = params[:ontology_term_type_id].presence&.to_i
    unless ontology_term_type_id&.positive?
      return render json: { status: 'error', message: 'ontology_term_type_id is required' }, status: :unprocessable_entity
    end

    unless @project.filesystem_project_data_present?
      return render json: {
        status: 'error',
        message: 'Project data files are not available on this server. Unarchive the project before exporting consensus metadata.'
      }, status: :unprocessable_entity
    end

    project_ids = Array(params[:project_ids]).presence || [@project.id]
    built = ConsensusAnnotationMetadataExportService.call(
      project: @project,
      ontology_term_type_id: ontology_term_type_id,
      project_ids: project_ids,
      readable_if: ->(project) { readable?(project) },
      equal_rank_choices: params[:equal_rank_choices] || {},
      collision_choices: params[:collision_choices] || {}
    )
    unless built[:ok]
      return render json: { status: 'error', message: built[:error] }, status: :unprocessable_entity
    end

    policy = params[:previous_metadata_policy].presence || params[:previousMetadataPolicy]
    replacing_paths = []
    [
      [built[:metadata_path], built[:labels]],
      [built[:ontology_id_path], built[:ontology_term_ids]]
    ].each do |path, labels|
      annot = @project.annots.where(name: path, latest_version: true).order(id: :desc).first
      next unless annot
      next unless consensus_metadata_labels_would_change?(annot, built[:loom_file], labels)

      replacing_paths << path
    end

    if replacing_paths.any?
      gate = MetadataRewritePolicyGate.call(
        project: @project,
        paths: replacing_paths,
        loom_file: built[:loom_file],
        previous_metadata_policy: policy
      )
      if gate[:requires_choice]
        return render json: {
          status: 'requires_choice',
          message: 'Previous consensus metadata exists. Choose whether to keep it as a versioned backup or delete it (and its dependents).',
          dependents: gate[:dependents],
          options: gate[:options]
        }, status: :conflict
      end
      unless gate[:ok]
        return render json: { status: 'error', message: gate[:error] }, status: :unprocessable_entity
      end
    end

    previous_policy = policy.to_s
    if previous_policy != 'delete'
      backup = ConsensusAnnotationMetadataBackupService.call(
        project: @project,
        loom_file: built[:loom_file],
        metadata_path: built[:metadata_path],
        new_labels: built[:labels]
      )
      unless backup[:ok]
        return render json: { status: 'error', message: backup[:error] }, status: :unprocessable_entity
      end

      ontology_id_backup = ConsensusAnnotationMetadataBackupService.call(
        project: @project,
        loom_file: built[:loom_file],
        metadata_path: built[:ontology_id_path],
        new_labels: built[:ontology_term_ids]
      )
      unless ontology_id_backup[:ok]
        return render json: { status: 'error', message: ontology_id_backup[:error] }, status: :unprocessable_entity
      end
    else
      backup = {
        ok: true,
        backed_up: false,
        unchanged: !replacing_paths.include?(built[:metadata_path])
      }
      ontology_id_backup = {
        ok: true,
        backed_up: false,
        unchanged: !replacing_paths.include?(built[:ontology_id_path])
      }
    end

    if backup[:unchanged] && ontology_id_backup[:unchanged] && previous_policy != 'delete'
      payload = {
        status: 'ok',
        metadata_path: built[:metadata_path],
        ontology_id_path: built[:ontology_id_path],
        annotation_type_label: built[:annotation_type_label],
        assigned_cell_count: built[:assigned_cell_count],
        total_cell_count: built[:total_cell_count],
        cell_set_count: built[:cell_set_count],
        backed_up: false,
        ontology_id_backed_up: false,
        unchanged: true
      }
      return render json: payload
    end

    annot_id = nil
    unless backup[:unchanged]
      persisted = ConsensusAnnotationMetadataPersistService.call(
        project: @project,
        loom_file: built[:loom_file],
        metadata_path: built[:metadata_path],
        metadata_basename: built[:metadata_basename],
        labels: built[:labels],
        user_id: current_user&.id || @project.user_id
      )
      unless persisted[:ok]
        return render json: { status: 'error', message: persisted[:error] }, status: :unprocessable_entity
      end
      annot_id = persisted[:annot_id]
    end

    ontology_id_annot_id = nil
    unless ontology_id_backup[:unchanged]
      ontology_persisted = ConsensusAnnotationMetadataPersistService.call(
        project: @project,
        loom_file: built[:loom_file],
        metadata_path: built[:ontology_id_path],
        metadata_basename: built[:ontology_id_basename],
        labels: built[:ontology_term_ids],
        user_id: current_user&.id || @project.user_id
      )
      unless ontology_persisted[:ok]
        return render json: { status: 'error', message: ontology_persisted[:error] }, status: :unprocessable_entity
      end
      ontology_id_annot_id = ontology_persisted[:annot_id]
    end

    payload = {
      status: 'ok',
      metadata_path: built[:metadata_path],
      ontology_id_path: built[:ontology_id_path],
      annotation_type_label: built[:annotation_type_label],
      assigned_cell_count: built[:assigned_cell_count],
      total_cell_count: built[:total_cell_count],
      cell_set_count: built[:cell_set_count],
      annot_id: annot_id,
      ontology_id_annot_id: ontology_id_annot_id,
      backed_up: backup[:backed_up] == true,
      ontology_id_backed_up: ontology_id_backup[:backed_up] == true,
      unchanged: false
    }
    if backup[:backed_up]
      payload[:backup_path] = backup[:backup_path]
      payload[:backup_idx] = backup[:backup_idx]
      payload[:backup_annot_id] = backup[:backup_annot_id]
    end
    if ontology_id_backup[:backed_up]
      payload[:ontology_id_backup_path] = ontology_id_backup[:backup_path]
      payload[:ontology_id_backup_idx] = ontology_id_backup[:backup_idx]
      payload[:ontology_id_backup_annot_id] = ontology_id_backup[:backup_annot_id]
    end
    render json: payload
  end

  # POST /projects/:id/save_metadata_from_selection
  def save_metadata_from_selection
    unless analyzable?(@project)
      render json: { status: 'error', message: 'Not authorized' }, status: :forbidden
      return
    end

    list_cols = Array(params[:list_cols]).map { |v| Integer(v) rescue nil }.compact.uniq
    if list_cols.empty?
      render json: { status: 'error', message: 'No cells selected' }, status: :unprocessable_entity
      return
    end

    embedding_metadata_id = params[:embedding_metadata_id].to_i
    embedding_annot = Annot.find_by(id: embedding_metadata_id, project_id: @project.id)
    unless embedding_annot&.run
      render json: { status: 'error', message: 'Embedding metadata not found' }, status: :unprocessable_entity
      return
    end

    loom_file = params[:loom_file].presence || embedding_annot.filepath
    selection_name = params[:selection_name].to_s.strip
    selected_name = selection_name
    unselected_name = params[:unselected_name].to_s.strip.presence || 'Not selected'
    compose_steps = sanitize_compose_steps(params[:compose_steps])
    selection_source = sanitize_selection_source(params[:selection_source])
    filter_components = sanitize_filter_components(params[:filter_components])
    plot_context = if selection_source == 'heatmap-rect'
                     selection_plot_context_with_heatmap_params(
                       params[:plot_context],
                       { 'heatmap_run_id' => params[:heatmap_run_id] }
                     )
                   else
                     sanitize_plot_context(params[:plot_context])
                   end

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    loom_path = project_dir + loom_file
    unless File.exist?(loom_path)
      render json: { status: 'error', message: "Loom file not found: #{loom_file}" }, status: :unprocessable_entity
      return
    end

    stable_ids = H5DataService.get_metadata_vector(loom_path.to_s, '/col_attrs/_StableID')
    if !stable_ids.is_a?(Array) || stable_ids.empty?
      render json: { status: 'error', message: 'Could not extract cell identifiers from loom' }, status: :unprocessable_entity
      return
    end

    selected_cells = list_cols.filter_map { |idx| stable_ids[idx] }
    if selected_cells.empty?
      render json: { status: 'error', message: 'Selected cells could not be mapped to identifiers' }, status: :unprocessable_entity
      return
    end

    asap_docker_image = Basic.get_asap_docker(@project.version)
    step = Step.where(docker_image_id: asap_docker_image.id, name: 'cell_selection').first
    std_method = StdMethod.where(docker_image_id: asap_docker_image.id, name: 'cell_sel').first
    unless step && std_method
      render json: { status: 'error', message: 'Selection step configuration not found' }, status: :unprocessable_entity
      return
    end

    last_num = Run.where(project_id: @project.id, step_id: step.id).maximum(:num).to_i
    lineage_run_ids = embedding_annot.run.lineage_run_ids.to_s.split(',').map(&:strip).reject(&:blank?)
    lineage_run_ids << embedding_annot.run.id.to_s
    lineage_run_ids.uniq!
    selection_index = Run.where(project_id: @project.id, step_id: step.id).count + 1
    selection_metadata_name = "#{embedding_annot.name}.sel_#{selection_index}"

    run = Run.create!(
      project_id: @project.id,
      step_id: step.id,
      std_method_id: std_method.id,
      status_id: 1,
      num: last_num + 1,
      user_id: current_user&.id || @project.user_id,
      command_json: '{}',
      attrs_json: '{}',
      output_json: '{}',
      lineage_run_ids: lineage_run_ids.join(','),
      submitted_at: Time.current
    )

    run_dir = project_dir + 'metadata' + run.id.to_s
    FileUtils.mkdir_p(run_dir)
    selected_cells_file = run_dir + 'selected_cells.json'
    File.open(selected_cells_file, 'w') do |f|
      f.write({ selected_cells: selected_cells }.to_json)
    end

    cmd = {
      program: "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar",
      opts: [
        { opt: '-T', value: 'CreateCellSelection' },
        { opt: '-loom', value: loom_path.to_s },
        { opt: '-meta', value: selection_metadata_name },
        { opt: '-f', value: selected_cells_file.to_s }
      ],
      args: []
    }

    run_attrs = {
      loom_file: loom_file,
      source_metadata_id: embedding_annot.id,
      source_run_id: embedding_annot.run_id,
      selected_name: selected_name,
      unselected_name: unselected_name,
      selection_source: selection_source,
      selection_metadata_name: selection_metadata_name,
      selected_cells_file: selected_cells_file.to_s
    }
    if selection_source == 'heatmap-rect'
      heatmap_run_id = params[:heatmap_run_id].to_i
      run_attrs[:heatmap_run_id] = heatmap_run_id if heatmap_run_id > 0
    end
    run_attrs[:compose_steps] = compose_steps if compose_steps.present?
    run_attrs[:filter_components] = filter_components if filter_components.present?
    run_attrs[:plot_context] = plot_context if plot_context.present?

    run.update!(
      command_json: cmd.to_json,
      attrs_json: run_attrs.to_json
    )

    cache_key = SecureRandom.uuid
    cache_data = selection_session_cache
    cache_entry = {
      id: cache_key,
      run_id: run.id,
      loom_file: loom_file,
      name: selected_name,
      unselected_name: unselected_name,
      selected_count: selected_cells.size,
      selection_metadata_name: selection_metadata_name,
      selection_number: selection_number_from_metadata_name(selection_metadata_name),
      selection_source: selection_source,
      source_metadata_id: embedding_annot.id,
      status: 'queued',
      created_at: Time.current.iso8601,
      plot_context: plot_context
    }
    cache_data[cache_key] = cache_entry
    write_selection_session_cache(cache_data)

    SelectionMetadataImportJob.perform_later(run.id)
    broadcast_selection_states_changed(loom_file: loom_file, reason: 'queued')

    response_item = cache_entry.merge(
      compose_steps: compose_steps,
      filter_components: filter_components,
      plot_context: plot_context
    )
    render json: {
      status: 'ok',
      item: response_item
    }
  end

  # POST /projects/:id/save_batch_compose_metadata
  # Writes one multi-category annot from a batch-compose label vector (not .sel_N).
  # Admin-only while the batch compose gate is experimental.
  def save_batch_compose_metadata
    unless admin?
      render json: { status: 'error', message: 'Batch compose is available to admins only' }, status: :forbidden
      return
    end

    unless analyzable?(@project)
      render json: { status: 'error', message: 'Not authorized' }, status: :forbidden
      return
    end

    unless @project.filesystem_project_data_present?
      render json: {
        status: 'error',
        message: 'Project data files are not available on this server. Unarchive the project before saving batch compose metadata.'
      }, status: :unprocessable_entity
      return
    end

    loom_file = params[:loom_file].to_s.strip
    fanout_annot_id = params[:fanout_annot_id].to_i
    labels = Array(params[:labels]).map { |v| v.nil? ? '' : v.to_s }
    compose_steps = sanitize_compose_steps(params[:compose_steps])
    metadata_basename = normalize_batch_compose_basename(params[:metadata_basename])
    previous_policy = (params[:previous_metadata_policy].presence || params[:previousMetadataPolicy]).to_s.strip.downcase.presence
    previous_new_name = params[:previous_metadata_new_name].presence || params[:previousMetadataNewName]

    if loom_file.blank?
      render json: { status: 'error', message: 'loom_file is required' }, status: :unprocessable_entity
      return
    end
    if metadata_basename.blank?
      render json: { status: 'error', message: 'metadata_basename is required' }, status: :unprocessable_entity
      return
    end
    if labels.empty?
      render json: { status: 'error', message: 'labels are required' }, status: :unprocessable_entity
      return
    end

    fanout_annot = Annot.find_by(id: fanout_annot_id, project_id: @project.id)
    unless fanout_annot
      render json: { status: 'error', message: 'Fan-out metadata not found' }, status: :unprocessable_entity
      return
    end

    metadata_path = "/col_attrs/#{metadata_basename}"
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    loom_path = project_dir + loom_file
    unless File.exist?(loom_path)
      render json: { status: 'error', message: "Loom file not found: #{loom_file}" }, status: :unprocessable_entity
      return
    end

    stable_ids = H5DataService.get_metadata_vector(loom_path.to_s, '/col_attrs/_StableID')
    n_cells = stable_ids.is_a?(Array) ? stable_ids.length : 0
    if n_cells <= 0 || labels.length != n_cells
      render json: {
        status: 'error',
        message: "labels length (#{labels.length}) must match loom cell count (#{n_cells})"
      }, status: :unprocessable_entity
      return
    end

    existing_annot = @project.annots.where(name: metadata_path, latest_version: true).order(id: :desc).first
    if existing_annot
      inventory = AnnotDependentsInventory.call(project: @project, annot: existing_annot)
      dependents = AnnotDependentsInventory.merge_results([inventory])
      suggested_version_name = MetadataFileImportValidation.next_versioned_path(@project, metadata_path).to_s.sub(%r{\A/col_attrs/}, '')
      suggested_previous_name = suggest_batch_compose_rename_basename(metadata_basename)

      if previous_policy.blank?
        render json: {
          status: 'requires_choice',
          message: 'Metadata already exists at this name. Keep the previous metadata under a new name, or replace it (deleting dependents).',
          dependents: dependents,
          suggested_previous_name: suggested_previous_name,
          suggested_version_name: suggested_version_name,
          existing_metadata_path: metadata_path,
          options: [
            {
              policy: 'rename',
              label: 'Rename previous metadata to a custom name (.batch_compose)',
              description: 'Move the existing annot aside under a free name ending in .batch_compose, then write the new result at the canonical name.'
            },
            {
              policy: 'archive',
              label: 'Keep previous metadata as automatic .bkp.N',
              description: 'Rename the existing annot to existing_name.bkp.N automatically, then write the new result at the canonical name.'
            },
            {
              policy: 'delete',
              label: 'Replace previous metadata and delete dependents',
              description: 'Deletes the previous annot/loom column and the dependent items listed below, then writes the new result.'
            }
          ]
        }, status: :conflict
        return
      end

      case previous_policy
      when 'rename'
        rename_basename = normalize_batch_compose_basename(previous_new_name.presence || suggested_previous_name)
        if rename_basename.blank?
          render json: { status: 'error', message: 'previous_metadata_new_name is required for rename' }, status: :unprocessable_entity
          return
        end
        rename_path = "/col_attrs/#{rename_basename}"
        if rename_path == metadata_path
          render json: { status: 'error', message: 'Rename target must differ from the canonical batch compose name' }, status: :unprocessable_entity
          return
        end
        if @project.annots.exists?(name: rename_path) || H5DataService.metadata_dataset_exists?(loom_path.to_s, rename_path)
          render json: { status: 'error', message: "Rename target already exists: #{rename_basename}" }, status: :unprocessable_entity
          return
        end
        renamed = MetadataAnnotRenameService.call(
          project: @project,
          loom_file: loom_file,
          metadata_path: metadata_path,
          new_metadata_path: rename_path
        )
        unless renamed[:ok]
          render json: { status: 'error', message: renamed[:error] }, status: :unprocessable_entity
          return
        end
      when 'archive'
        archived = MetadataAnnotVersionArchiveService.call(
          project: @project,
          loom_file: loom_file,
          metadata_path: metadata_path
        )
        unless archived[:ok]
          render json: { status: 'error', message: archived[:error] }, status: :unprocessable_entity
          return
        end
      when 'delete'
        gate = MetadataRewritePolicyGate.call(
          project: @project,
          paths: [metadata_path],
          loom_file: loom_file,
          previous_metadata_policy: 'delete'
        )
        unless gate[:ok]
          render json: { status: 'error', message: gate[:error] || 'Failed to replace previous metadata' }, status: :unprocessable_entity
          return
        end
      else
        render json: { status: 'error', message: "Unknown previous_metadata_policy: #{previous_policy}" }, status: :unprocessable_entity
        return
      end
    end

    persisted = BatchComposeMetadataPersistService.call(
      project: @project,
      loom_file: loom_file,
      metadata_path: metadata_path,
      metadata_basename: metadata_basename,
      labels: labels,
      user_id: current_user&.id || @project.user_id,
      provenance: {
        fanout_annot_id: fanout_annot.id,
        fanout_annot_name: fanout_annot.name,
        compose_steps: compose_steps
      }
    )
    unless persisted[:ok]
      render json: { status: 'error', message: persisted[:error] }, status: :unprocessable_entity
      return
    end

    render json: {
      status: 'ok',
      annot_id: persisted[:annot_id],
      metadata_path: persisted[:metadata_path],
      metadata_basename: persisted[:metadata_basename],
      nber_cats: persisted[:nber_cats],
      nber_cols: persisted[:nber_cols],
      previous_metadata_policy: previous_policy
    }
  end

  # GET /projects/:id/selection_states
  def selection_states
    loom_file = params[:loom_file].presence
    items = selection_cache_items_for_loom(loom_file, cleanup_completed: true)
    items.concat(selection_items_from_annots(loom_file))
    items.sort_by! { |entry| entry[:created_at].to_s }
    items.reverse!

    render json: { status: 'ok', items: items }
  end

  # POST /projects/:id/delete_selection
  def delete_selection
    unless editable?(@project)
      render json: { status: 'error', message: 'Not authorized' }, status: :forbidden
      return
    end

    run_id = params[:run_id].to_i
    selection_id = params[:selection_id].to_s.strip

    if run_id > 0
      run = @project.runs.find_by(id: run_id)
      unless run
        deleted = selection_id.present? ? remove_selection_from_cache_by_id(selection_id) : false
        if deleted
          broadcast_selection_states_changed(reason: 'deleted')
          render json: { status: 'ok', deleted_run: false, selection_id: selection_id, recovered_from_missing_run: true }
        else
          render json: { status: 'error', message: 'Run not found' }, status: :not_found
        end
        return
      end

      if immutable_since_publication?(run)
        render json: { status: 'error', message: 'This selection was created before publication and cannot be deleted.' }, status: :forbidden
        return
      end

      RunsController.destroy_run_call(@project, run)
      cleanup_selection_cache_for_run_id(run_id)
      run_attrs = Basic.safe_parse_json(run.attrs_json, {})
      broadcast_selection_states_changed(loom_file: run_attrs['loom_file'], reason: 'deleted')

      render json: { status: 'ok', deleted_run: true, run_id: run_id }
      return
    end

    if selection_id.blank?
      render json: { status: 'error', message: 'Missing selection identifier' }, status: :unprocessable_entity
      return
    end

    deleted = remove_selection_from_cache_by_id(selection_id)
    unless deleted
      render json: { status: 'error', message: 'Selection not found in cache. Persisted selections must be deleted via run deletion.' }, status: :not_found
      return
    end

    broadcast_selection_states_changed(reason: 'deleted')
    render json: { status: 'ok', deleted_run: false, selection_id: selection_id }
  rescue StandardError => e
    Rails.logger.error("delete_selection failed for #{selection_id}: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Deletion failed: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/rename_selection
  def rename_selection
    unless editable?(@project)
      render json: { status: 'error', message: 'Not authorized' }, status: :forbidden
      return
    end

    selection_id = params[:selection_id].to_s.strip
    new_name = params[:selection_name].to_s.strip
    run_id = params[:run_id].to_i
    metadata_id = params[:metadata_id].to_s.strip
    Rails.logger.info("[rename_selection] selection_id=#{selection_id.inspect} run_id=#{run_id} metadata_id=#{metadata_id.inspect} new_name=#{new_name.inspect}")
    if selection_id.blank?
      render json: { status: 'error', message: 'Missing selection identifier' }, status: :unprocessable_entity
      return
    end

    if selection_id.start_with?('annot-')
      annot_id = selection_id.sub('annot-', '').to_i
      annot = Annot.find_by(id: annot_id, project_id: @project.id)
      unless annot
        render json: { status: 'error', message: 'Selection not found' }, status: :not_found
        return
      end

      if immutable_since_publication?(annot)
        render json: { status: 'error', message: 'This selection was created before publication and cannot be edited.' }, status: :forbidden
        return
      end

      aliases = Basic.safe_parse_json(annot.cat_aliases_json, {})
      aliases['names'] ||= {}
      aliases['names']['1'] = new_name
      annot.update!(cat_aliases_json: aliases.to_json)

      if annot.run_id.present?
        run = @project.runs.find_by(id: annot.run_id)
        if run
          run_attrs = Basic.safe_parse_json(run.attrs_json, {})
          run_attrs['selected_name'] = new_name
          run.update!(attrs_json: run_attrs.to_json)
        end
      end

      broadcast_selection_states_changed(loom_file: annot.filepath, reason: 'renamed')
      render json: { status: 'ok', selection_id: selection_id, name: new_name }
      return
    end

    cache_data = selection_session_cache
    key, entry = cache_data.find { |_cache_key, cache_entry| String(cache_entry['id'] || cache_entry[:id]) == selection_id }
    if (!key || !entry) && run_id > 0
      key, entry = cache_data.find { |_cache_key, cache_entry| (cache_entry['run_id'] || cache_entry[:run_id]).to_i == run_id }
    end
    unless key && entry
      annot = nil
      if metadata_id.start_with?('annot-')
        annot_id = metadata_id.sub('annot-', '').to_i
        annot = Annot.find_by(id: annot_id, project_id: @project.id)
      end
      unless annot
        render json: { status: 'error', message: 'Selection not found in cache' }, status: :not_found
        return
      end

      if immutable_since_publication?(annot)
        render json: { status: 'error', message: 'This selection was created before publication and cannot be edited.' }, status: :forbidden
        return
      end

      aliases = Basic.safe_parse_json(annot.cat_aliases_json, {})
      aliases['names'] ||= {}
      aliases['names']['1'] = new_name
      annot.update!(cat_aliases_json: aliases.to_json)

      run = @project.runs.find_by(id: annot.run_id || run_id)
      if run
        run_attrs = Basic.safe_parse_json(run.attrs_json, {})
        run_attrs['selected_name'] = new_name
        run.update!(attrs_json: run_attrs.to_json)
      end

      broadcast_selection_states_changed(loom_file: annot.filepath, reason: 'renamed')
      render json: { status: 'ok', selection_id: selection_id, name: new_name }
      return
    end

    entry['name'] = new_name
    entry[:name] = new_name
    cache_data[key] = entry
    write_selection_session_cache(cache_data)

    run_id = (entry['run_id'] || entry[:run_id]).to_i
    if run_id > 0
      run = @project.runs.find_by(id: run_id)
      if run
        if immutable_since_publication?(run)
          render json: { status: 'error', message: 'This selection was created before publication and cannot be edited.' }, status: :forbidden
          return
        end
        run_attrs = Basic.safe_parse_json(run.attrs_json, {})
        run_attrs['selected_name'] = new_name
        run.update!(attrs_json: run_attrs.to_json)
      end
    end

    broadcast_selection_states_changed(loom_file: (entry['loom_file'] || entry[:loom_file]), reason: 'renamed')
    render json: { status: 'ok', selection_id: selection_id, name: new_name }
  rescue StandardError => e
    Rails.logger.error("rename_selection failed for #{selection_id}: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Rename failed: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/create_gene_set_collection
  def create_gene_set_collection
    name = params[:name].to_s.strip
    collection_type = params[:collection_type].to_s.strip

    unless collection_type == GENE_SET_COLLECTION_TYPE_FROM_HEATMAP
      render json: { status: 'error', message: 'Unsupported gene set collection type' }, status: :unprocessable_entity
      return
    end

    target_collection = create_heatmap_gene_set_collection!(
      name: name.presence || HEATMAP_GENE_SET_COLLECTION_LABEL
    )

    render json: {
      status: 'ok',
      collection: {
        id: local_gene_set_collection_id(target_collection),
        label: target_collection.name.to_s,
        nb_items: 0,
        custom: true,
        locked: immutable_since_publication?(target_collection)
      }
    }.deep_merge(collection_type_presentation_for_collection(target_collection))
  rescue StandardError => e
    Rails.logger.error("create_gene_set_collection failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to create gene set collection: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/save_manual_gene_set
  def save_manual_gene_set
    name = params[:name].to_s.strip
    if name.blank?
      render json: { status: 'error', message: 'Missing gene set name' }, status: :unprocessable_entity
      return
    end

    submitted_genes = Array(params[:genes]).map do |gene|
      next unless gene.is_a?(ActionController::Parameters) || gene.is_a?(Hash)
      raw = if gene.is_a?(ActionController::Parameters)
              gene.permit(:symbol, :ensembl_id, :stable_id).to_h
            else
              gene.to_h.slice('symbol', 'ensembl_id', 'stable_id', :symbol, :ensembl_id, :stable_id)
            end
      symbol = raw['symbol'].to_s.strip
      ensembl_id = raw['ensembl_id'].to_s.strip
      stable_id = raw['stable_id'].to_s.strip
      next if symbol.blank? && ensembl_id.blank? && stable_id.blank?
      {
        symbol: symbol,
        ensembl_id: ensembl_id,
        stable_id: stable_id
      }
    end.compact

    if submitted_genes.empty?
      render json: { status: 'error', message: 'No genes to save' }, status: :unprocessable_entity
      return
    end

    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: "save_manual_gene_set")
    genes_with_ids = resolve_manual_gene_ids(submitted_genes, db_version)
    collection_type = params[:collection_type].to_s.strip
    target_collection = if collection_type == GENE_SET_COLLECTION_TYPE_FROM_HEATMAP
      resolve_target_heatmap_collection(
        params[:collection_id],
        new_collection_name: params[:new_collection_name]
      )
    else
      resolve_target_manual_collection(
        params[:collection_id],
        new_collection_name: params[:new_collection_name]
      )
    end
    unless target_collection
      label = collection_type == GENE_SET_COLLECTION_TYPE_FROM_HEATMAP ? 'heatmap' : 'manual'
      render json: { status: 'error', message: "Target #{label} gene set collection not found" }, status: :unprocessable_entity
      return
    end
    if immutable_since_publication?(target_collection)
      render json: { status: 'error', message: 'This gene set collection was created before publication and cannot be edited.' }, status: :forbidden
      return
    end

    payload = load_local_gene_set_collection_payload(target_collection.file_key, target_collection.name)
    items = Array(payload['items'])
    timestamp = Time.now.utc.iso8601
    if collection_type == GENE_SET_COLLECTION_TYPE_FROM_HEATMAP
      heatmap_run = @project.runs.find_by(id: params[:heatmap_run_id].to_i)
      unless heatmap_run&.num.present?
        render json: { status: 'error', message: 'Heatmap run is required to save a heatmap gene set' }, status: :unprocessable_entity
        return
      end
      item_identifier = "heatmap_#{heatmap_run.num}_#{SecureRandom.hex(6)}"
    else
      item_identifier = "manual_#{SecureRandom.hex(6)}"
    end
    item_id = "#{local_gene_set_collection_id(target_collection)}:#{item_identifier}"
    new_item = {
      'id' => item_id,
      'identifier' => item_identifier,
      'name' => name,
      'genes' => genes_with_ids,
      'created_at' => timestamp,
      'updated_at' => timestamp
    }
    items << new_item
    payload['collection'] = target_collection.name.to_s
    payload['items'] = items
    payload['updated_at'] = timestamp

    write_local_gene_set_collection_payload(target_collection.file_key, payload)

    render json: {
      status: 'ok',
      collection: {
        id: local_gene_set_collection_id(target_collection),
        label: target_collection.name.to_s,
        nb_items: items.length,
        custom: true,
        locked: immutable_since_publication?(target_collection)
      },
      item: {
        id: item_id,
        identifier: item_identifier,
        name: name,
        gene_count: genes_with_ids.length
      }
    }.deep_merge(collection_type_presentation_for_collection(target_collection))
  rescue StandardError => e
    Rails.logger.error("save_manual_gene_set failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to save manual gene set: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/save_de_gene_set
  def save_de_gene_set
    run_id    = params[:run_id].to_i
    annot_id  = params[:annot_id].presence
    direction = params[:direction].to_s.strip
    name      = params[:name].to_s.strip
    fdr_cutoff = params[:fdr_cutoff].to_f
    fc_cutoff  = params[:fc_cutoff].to_f
    collection_id_param = params[:collection_id].to_s.strip
    new_collection_name = params[:new_collection_name].to_s.strip

    unless %w[up down].include?(direction)
      render json: { status: 'error', message: 'Invalid direction' }, status: :unprocessable_entity
      return
    end
    if name.blank?
      render json: { status: 'error', message: 'Missing gene set name' }, status: :unprocessable_entity
      return
    end

    run = @project.runs.find_by(id: run_id)
    unless run
      render json: { status: 'error', message: 'DE run not found' }, status: :unprocessable_entity
      return
    end

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    de_list_dir = Basic.de_filter_gene_list_dir(project_dir, run.id, annot_id)
    output_txt  = de_list_dir + 'output.txt'

    unless File.exist?(output_txt)
      render json: { status: 'error', message: 'DE output file not found' }, status: :unprocessable_entity
      return
    end

    fdr_cutoff = 0.05 if fdr_cutoff <= 0
    fc_cutoff  = 2.0  if fc_cutoff  <= 0

    Basic.de_filter_write_filtered_json!(output_txt, fdr_cutoff, fc_cutoff)
    filtered_json = de_list_dir + "filtered.#{direction}.json"
    filtered_rows = Basic.safe_parse_json(File.read(filtered_json), [])
    h_filtered = {}
    filtered_rows.each { |i| h_filtered[i.to_i] = true }

    tmp_data = File.readlines(output_txt)
    genes = []
    tmp_data.each_with_index do |line, i|
      next unless h_filtered[i]
      cols = line.chomp.split("\t")
      ensembl_id = cols[1].to_s.strip
      symbol     = cols[2].to_s.split(',').first.to_s.strip
      genes << { symbol: symbol, ensembl_id: ensembl_id, stable_id: '' }
    end

    if genes.empty?
      render json: { status: 'error', message: 'No genes pass the current thresholds' }, status: :unprocessable_entity
      return
    end

    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: 'save_de_gene_set')
    genes_with_ids = resolve_manual_gene_ids(genes, db_version)

    collection = resolve_target_de_collection(collection_id_param, new_collection_name: new_collection_name)
    unless collection
      render json: { status: 'error', message: 'Target DE gene set collection not found' }, status: :unprocessable_entity
      return
    end
    if immutable_since_publication?(collection)
      render json: { status: 'error', message: 'This gene set collection was created before publication and cannot be edited.' }, status: :forbidden
      return
    end

    timestamp = Time.now.utc.iso8601
    payload = load_local_gene_set_collection_payload(collection.file_key, collection.name)
    items = Array(payload['items'])
    item_identifier = "de_#{SecureRandom.hex(6)}"
    item_id = "#{local_gene_set_collection_id(collection)}:#{item_identifier}"
    items << {
      'id'         => item_id,
      'identifier' => item_identifier,
      'name'       => name,
      'genes'      => genes_with_ids,
      'created_at' => timestamp,
      'updated_at' => timestamp
    }
    payload['collection'] = collection.name.to_s
    payload['items'] = items
    payload['updated_at'] = timestamp
    write_local_gene_set_collection_payload(collection.file_key, payload)

    render json: {
      status: 'ok',
      gene_count: genes_with_ids.length,
      collection: {
        id:       local_gene_set_collection_id(collection),
        label:    collection.name.to_s,
        nb_items: items.length,
        custom:   true,
        locked:   immutable_since_publication?(collection)
      },
      item: {
        id: item_id,
        identifier: item_identifier,
        name: name,
        gene_count: genes_with_ids.length
      }
    }.deep_merge(collection_type_presentation_for_collection(collection))
  rescue StandardError => e
    Rails.logger.error("save_de_gene_set failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to save gene set: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/import_gene_set_collection
  def import_gene_set_collection
    collection_name = params[:name].to_s.strip
    if collection_name.blank?
      render json: { status: 'error', message: 'Missing gene set collection name' }, status: :unprocessable_entity
      return
    end

    create_empty = ActiveModel::Type::Boolean.new.cast(params[:empty])
    if create_empty
      collection_record = create_manual_gene_set_collection!(name: collection_name)
      render json: {
        status: 'ok',
        collection: {
          id: local_gene_set_collection_id(collection_record),
          label: collection_record.name.to_s,
          nb_items: 0,
          custom: true,
          locked: immutable_since_publication?(collection_record),
          import_pending: false
        }
      }.deep_merge(collection_type_presentation_for_collection(collection_record))
      return
    end

    uploaded_file = params[:file]
    unless uploaded_file.respond_to?(:read)
      render json: { status: 'error', message: 'Missing file to import' }, status: :unprocessable_entity
      return
    end

    extension = File.extname(uploaded_file.original_filename.to_s).to_s.downcase
    source_kind = extension == '.gmt' ? 'gmt' : ''
    if source_kind.blank?
      render json: { status: 'error', message: 'Unsupported file format. Please upload a .gmt file.' }, status: :unprocessable_entity
      return
    end

    uploaded_path = uploaded_file.respond_to?(:path) ? uploaded_file.path.to_s : ''
    if uploaded_path.blank? || !File.exist?(uploaded_path) || File.size(uploaded_path).to_i <= 0
      render json: { status: 'error', message: 'Uploaded file is empty' }, status: :unprocessable_entity
      return
    end

    loom_file = params[:loom_file].to_s.strip
    if loom_file.blank?
      render json: { status: 'error', message: 'Missing loom file' }, status: :unprocessable_entity
      return
    end

    import_id = params[:import_id].to_s.strip
    import_id = SecureRandom.uuid if import_id.blank?
    staged_upload_path = stage_gene_set_collection_upload!(uploaded_path, import_id: import_id)
    collection_record = GeneSetCollection.create!(
      project_id: @project.id,
      user_id: current_user&.id,
      name: collection_name,
      file_key: "gene_set_collection_#{SecureRandom.hex(12)}",
      source_kind: source_kind,
      gene_set_collection_type_id: gene_set_collection_type_id_for!(GENE_SET_COLLECTION_TYPE_IMPORTED),
      staged_upload_path: staged_upload_path,
      import_loom_file: loom_file,
      import_id: import_id
    )
    GeneSetCollectionImportJob.perform_later(
      @project.id,
      collection_record.id,
      staged_upload_path,
      import_id,
      loom_file
    )

    render json: {
      status: 'queued',
      import_id: import_id,
      collection: {
        id: local_gene_set_collection_id(collection_record),
        label: collection_record.name.to_s,
        nb_items: 0,
        custom: true,
        locked: immutable_since_publication?(collection_record),
        import_pending: true
      }
    }.deep_merge(collection_type_presentation_for_collection(collection_record))
  rescue JSON::ParserError => e
    Rails.logger.error("import_gene_set_collection failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Invalid JSON format: #{e.message}" }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error("import_gene_set_collection failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to import gene set collection: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/delete_manual_gene_set
  def delete_manual_gene_set
    item_id = params[:item_id].to_s.strip
    if item_id.blank?
      render json: { status: 'error', message: 'Missing manual gene set identifier' }, status: :unprocessable_entity
      return
    end

    collection_id_raw = if item_id.start_with?("#{LOCAL_GENE_SET_COLLECTION_ID_PREFIX}:")
      parts = item_id.split(':')
      parts.length >= 3 ? "#{parts[0]}:#{parts[1]}" : ''
    else
      MANUAL_GENE_SET_COLLECTION_ID
    end

    local_collection_id = parse_local_gene_set_collection_id(collection_id_raw)
    if local_collection_id
      local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      unless local_collection
        render json: { status: 'error', message: 'Manual gene set collection not found' }, status: :not_found
        return
      end
      if immutable_since_publication?(local_collection)
        render json: { status: 'error', message: 'This gene set collection was created before publication and cannot be edited.' }, status: :forbidden
        return
      end
      payload = load_local_gene_set_collection_payload(local_collection.file_key, local_collection.name)
    elsif collection_id_raw == MANUAL_GENE_SET_COLLECTION_ID
      manual_collection = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).find { |collection| gene_set_collection_manual?(collection) }
      if manual_collection && immutable_since_publication?(manual_collection)
        render json: { status: 'error', message: 'This gene set collection was created before publication and cannot be edited.' }, status: :forbidden
        return
      end
      payload = load_manual_gene_set_collection_payload
    else
      render json: { status: 'error', message: 'Invalid manual gene set identifier' }, status: :unprocessable_entity
      return
    end

    items = Array(payload['items'])
    index = items.index { |raw_item| normalize_manual_gene_set_item(raw_item)&.dig(:id).to_s == item_id }
    if index.nil?
      render json: { status: 'error', message: 'Manual gene set not found' }, status: :not_found
      return
    end

    removed_item = normalize_manual_gene_set_item(items[index]) || {}
    items.delete_at(index)
    payload['items'] = items
    payload['updated_at'] = Time.now.utc.iso8601
    if local_collection_id
      write_local_gene_set_collection_payload(local_collection.file_key, payload)
    else
      write_manual_gene_set_collection_payload(payload)
    end

    deleted_runs_count = delete_related_manual_module_score_runs(removed_item)

    render json: {
      status: 'ok',
      item_id: item_id,
      deleted_runs_count: deleted_runs_count,
      collection: {
        id: local_collection_id ? local_gene_set_collection_id(local_collection) : MANUAL_GENE_SET_COLLECTION_ID,
        label: local_collection_id ? local_collection.name.to_s : MANUAL_GENE_SET_COLLECTION_LABEL,
        nb_items: items.length,
        custom: true,
        locked: local_collection ? immutable_since_publication?(local_collection) : false
      }
    }.deep_merge(collection_type_presentation_for_collection(local_collection))
  rescue StandardError => e
    Rails.logger.error("delete_manual_gene_set failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to delete manual gene set: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/delete_gene_set_collection
  def rename_gene_set_collection
    collection_id_raw = params[:collection_id].to_s.strip
    new_name = params[:name].to_s.strip
    if collection_id_raw.blank?
      render json: { status: 'error', message: 'Missing gene set collection identifier' }, status: :unprocessable_entity
      return
    end
    if new_name.blank?
      render json: { status: 'error', message: 'Missing gene set collection name' }, status: :unprocessable_entity
      return
    end

    local_collection_id = parse_local_gene_set_collection_id(collection_id_raw)
    unless local_collection_id
      render json: { status: 'error', message: 'Only imported gene set collections can be renamed' }, status: :forbidden
      return
    end

    local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
    unless local_collection
      render json: { status: 'error', message: 'Gene set collection not found' }, status: :not_found
      return
    end
    if immutable_since_publication?(local_collection)
      render json: { status: 'error', message: 'This gene set collection was created before publication and cannot be edited.' }, status: :forbidden
      return
    end

    local_collection.update!(name: new_name)
    local_payload = load_local_gene_set_collection_payload(local_collection.file_key, new_name)
    local_payload['collection'] = new_name
    local_payload['updated_at'] = Time.current.utc.iso8601
    write_local_gene_set_collection_payload(local_collection.file_key, local_payload)

    render json: {
      status: 'ok',
      collection: {
        id: local_gene_set_collection_id(local_collection),
        label: local_collection.name.to_s,
        nb_items: Array(local_payload['items']).length,
        custom: true,
        locked: immutable_since_publication?(local_collection),
        import_pending: false
      }
    }.deep_merge(collection_type_presentation_for_collection(local_collection))
  rescue StandardError => e
    Rails.logger.error("rename_gene_set_collection failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to rename gene set collection: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /projects/:id/delete_gene_set_collection
  def delete_gene_set_collection
    collection_id_raw = params[:collection_id].to_s.strip
    if collection_id_raw.blank?
      render json: { status: 'error', message: 'Missing gene set collection identifier' }, status: :unprocessable_entity
      return
    end

    if collection_id_raw == MANUAL_GENE_SET_COLLECTION_ID
      manual_collection = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).find { |collection| gene_set_collection_manual?(collection) }
      if manual_collection && immutable_since_publication?(manual_collection)
        render json: { status: 'error', message: 'This gene set collection was created before publication and cannot be deleted.' }, status: :forbidden
        return
      end
      payload = load_manual_gene_set_collection_payload
      items = Array(payload['items']).map { |item| normalize_manual_gene_set_item(item) }.compact
      deleted_runs_count = items.sum { |item| delete_related_manual_module_score_runs(item) }

      legacy_path = manual_gene_set_collection_file_path
      File.delete(legacy_path) if File.exist?(legacy_path)

      if manual_collection
        local_path = local_gene_set_collection_file_path(manual_collection.file_key)
        File.delete(local_path) if File.exist?(local_path)
        manual_collection.destroy!
      end

      render json: { status: 'ok', collection_id: collection_id_raw, deleted_runs_count: deleted_runs_count }
      return
    end

    local_collection_id = parse_local_gene_set_collection_id(collection_id_raw)
    if local_collection_id
      local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      unless local_collection
        render json: { status: 'error', message: 'Gene set collection not found' }, status: :not_found
        return
      end
      if immutable_since_publication?(local_collection)
        render json: { status: 'error', message: 'This gene set collection was created before publication and cannot be deleted.' }, status: :forbidden
        return
      end

      if gene_set_collection_manual?(local_collection)
        payload = load_local_gene_set_collection_payload(local_collection.file_key, local_collection.name)
        items = Array(payload['items']).map { |item| normalize_manual_gene_set_item(item) }.compact
        deleted_runs_count = items.sum { |item| delete_related_manual_module_score_runs(item) }
      end

      local_path = local_gene_set_collection_file_path(local_collection.file_key)
      File.delete(local_path) if File.exist?(local_path)
      local_collection.destroy!
      render json: { status: 'ok', collection_id: collection_id_raw, deleted_runs_count: deleted_runs_count.to_i }
      return
    end

    collection_id = collection_id_raw.to_i
    if collection_id <= 0
      render json: { status: 'error', message: 'Invalid gene set collection identifier' }, status: :unprocessable_entity
      return
    end

    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: "delete_manual_gene_set")
    current_user_id = current_user&.id

    deleted = false

    RemoteGene.with_remote(db_version) do
      conn = RemoteGene.connection
      row = conn.select_one("SELECT id, project_id, user_id, ref_id FROM gene_sets WHERE id = #{collection_id}")

      unless row
        render json: { status: 'error', message: 'Gene set collection not found' }, status: :not_found
        return
      end

      project_id = row['project_id']&.to_i
      owner_user_id = row['user_id']&.to_i
      ref_id = row['ref_id']&.to_i
      owned_by_project = project_id.present? && project_id == @project.id
      owned_by_user = current_user_id.present? &&
                      owner_user_id.present? &&
                      owner_user_id == current_user_id &&
                      project_id.blank? &&
                      ref_id.blank?

      unless owned_by_project || owned_by_user
        render json: { status: 'error', message: 'Only custom gene set collections can be deleted' }, status: :forbidden
        return
      end

      conn.execute("DELETE FROM gene_set_items WHERE gene_set_id = #{collection_id}")
      conn.execute("DELETE FROM gene_sets WHERE id = #{collection_id}")
      deleted = true
    end

    if deleted
      render json: { status: 'ok', collection_id: collection_id }
    else
      render json: { status: 'error', message: 'Deletion failed' }, status: :unprocessable_entity
    end
  end

  # GET /projects/:id/gene_set_collection_items
  def gene_set_collection_items
    collection_id_raw = params[:collection_id].to_s.strip
    if collection_id_raw.blank?
      render json: { status: 'error', message: 'Missing gene set collection identifier' }, status: :unprocessable_entity
      return
    end

    query = params[:query].to_s.strip
    loom_file = params[:loom_file].to_s.strip
    if loom_file.blank?
      render json: { status: 'error', message: 'Missing loom file' }, status: :unprocessable_entity
      return
    end
    limit = 100

    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: "download_gene_set_collection")
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
    loom_path = project_dir + loom_file
    unless File.exist?(loom_path)
      render json: { status: 'error', message: 'Loom file not found' }, status: :not_found
      return
    end

    perf_req_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      dataset_lookup = cached_dataset_stable_lookup(loom_path)
      dataset_stable_by_accession = dataset_lookup[:by_accession]
      dataset_stable_by_symbol = dataset_lookup[:by_symbol]
      dataset_stable_ids = dataset_lookup[:stable_ids]
    rescue => e
      Rails.logger.error("gene_set_collection_items: failed to extract dataset gene mappings from #{loom_path}: #{e.message}")
      render json: { status: 'error', message: 'Failed to read dataset gene identifiers' }, status: :unprocessable_entity
      return
    end

    local_collection_id = parse_local_gene_set_collection_id(collection_id_raw)
    if local_collection_id
      local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      unless local_collection
        render json: { status: 'error', message: 'Gene set collection not found' }, status: :not_found
        return
      end

      local_payload = load_local_gene_set_collection_payload(local_collection.file_key, local_collection.name)
      collection_locked = immutable_since_publication?(local_collection)
      local_items = Array(local_payload['items']).map { |item| normalize_manual_gene_set_item(item) }.compact
      filtered_items = if query.present?
        query_downcase = query.downcase
        local_items.select do |item|
          item[:name].to_s.downcase.include?(query_downcase) || item[:identifier].to_s.downcase.include?(query_downcase)
        end
      else
        local_items
      end

      total_count = filtered_items.length
      limited_items = filtered_items.first(limit)

      items_payload = limited_items.map do |item|
        genes = item[:genes]
        in_dataset_count = genes.count do |gene|
          manual_gene_in_dataset?(
            gene,
            dataset_stable_by_accession: dataset_stable_by_accession,
            dataset_stable_by_symbol: dataset_stable_by_symbol,
            dataset_stable_ids: dataset_stable_ids
          )
        end

        {
          id: item[:id],
          identifier: item[:identifier],
          name: item[:name],
          display_name: item[:name].presence || item[:identifier],
          gene_count: genes.length,
          in_dataset_count: in_dataset_count,
          supports_module_score: in_dataset_count > 0,
          created_at: item[:created_at],
          deletable: !collection_locked && editable?(@project)
        }
      end

      render json: {
        status: 'ok',
        collection: {
          id: local_gene_set_collection_id(local_collection),
          label: local_collection.name.to_s,
          locked: collection_locked
        },
        items: items_payload,
        total_count: total_count,
        limit: limit
      }
      return
    end

    if collection_id_raw == MANUAL_GENE_SET_COLLECTION_ID
      manual_collection = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).find { |collection| gene_set_collection_manual?(collection) }
      collection_locked = manual_collection ? immutable_since_publication?(manual_collection) : false
      manual_payload = load_manual_gene_set_collection_payload
      manual_items = Array(manual_payload['items']).map { |item| normalize_manual_gene_set_item(item) }.compact

      filtered_items = if query.present?
        query_downcase = query.downcase
        manual_items.select { |item| item[:name].to_s.downcase.include?(query_downcase) }
      else
        manual_items
      end

      total_count = filtered_items.length
      limited_items = filtered_items.first(limit)

      items_payload = limited_items.map do |item|
        genes = item[:genes]
        in_dataset_count = genes.count do |gene|
          manual_gene_in_dataset?(
            gene,
            dataset_stable_by_accession: dataset_stable_by_accession,
            dataset_stable_by_symbol: dataset_stable_by_symbol,
            dataset_stable_ids: dataset_stable_ids
          )
        end

        {
          id: item[:id],
          identifier: item[:identifier],
          name: item[:name],
          display_name: item[:name].presence || item[:identifier],
          gene_count: genes.length,
          in_dataset_count: in_dataset_count,
          supports_module_score: in_dataset_count > 0,
          created_at: item[:created_at],
          deletable: !collection_locked && editable?(@project)
        }
      end

      render json: {
        status: 'ok',
        collection: {
          id: MANUAL_GENE_SET_COLLECTION_ID,
          label: MANUAL_GENE_SET_COLLECTION_LABEL,
          locked: collection_locked
        },
        items: items_payload,
        total_count: total_count,
        limit: limit
      }
      return
    end

    collection_id = collection_id_raw.to_i
    if collection_id <= 0
      render json: { status: 'error', message: 'Invalid gene set collection identifier' }, status: :unprocessable_entity
      return
    end

    payload = nil
    perf_db = {}
    RemoteGene.with_remote(db_version) do
      conn = RemoteGene.connection

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      collection_row = conn.select_one(
        "SELECT id, label FROM gene_sets WHERE id = #{collection_id} AND organism_id = #{@project.organism_id.to_i} AND COALESCE(obsolete, FALSE) = FALSE"
      )
      perf_db[:collection_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
      unless collection_row
        render json: { status: 'error', message: 'Gene set collection not found' }, status: :not_found
        return
      end

      where_clause = "gene_set_id = #{collection_id}"
      has_item_obsolete = conn.select_value(<<~SQL).present?
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'gene_set_items' AND column_name = 'obsolete'
        LIMIT 1
      SQL

      # Exact GO id search keeps the requested term (including obsolete);
      # replacement metadata is attached below for UI linking.
      redirected_from = nil
      if query.present? && query.match?(/\AGO:\d+\z/i)
        where_clause += " AND identifier = #{conn.quote(query.upcase)}"
      elsif query.present?
        escaped_query = conn.quote("%#{query.downcase}%")
        where_clause += " AND (LOWER(COALESCE(name, '')) LIKE #{escaped_query} OR LOWER(COALESCE(identifier, '')) LIKE #{escaped_query})"
      end

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      total_count = conn.select_value("SELECT COUNT(*) FROM gene_set_items WHERE #{where_clause}").to_i
      perf_db[:count_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)

      obsolete_select = has_item_obsolete ? "obsolete" : "FALSE AS obsolete"
      item_select_sql = <<~SQL.squish
        id,
        identifier,
        name,
        content,
        #{obsolete_select},
        COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(identifier), ''), 'Unnamed gene set') AS display_name,
        CASE
          WHEN content IS NULL OR TRIM(content) = '' THEN 0
          ELSE array_length(string_to_array(content, ','), 1)
        END AS gene_count
      SQL
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # Unfiltered list is capped at `limit` and sorted by name; obsolete terms often
      # start far past that window, so reserve a slice so badges are visible by default.
      if query.blank? && has_item_obsolete
        obsolete_limit = [15, (limit / 5)].max
        active_limit = limit - obsolete_limit
        rows = conn.select_all(<<~SQL)
          SELECT * FROM (
            (
              SELECT #{item_select_sql}
              FROM gene_set_items
              WHERE #{where_clause} AND COALESCE(obsolete, FALSE) = FALSE
              ORDER BY LOWER(COALESCE(name, ''))
              LIMIT #{active_limit}
            )
            UNION ALL
            (
              SELECT #{item_select_sql}
              FROM gene_set_items
              WHERE #{where_clause} AND obsolete = TRUE
              ORDER BY LOWER(COALESCE(name, ''))
              LIMIT #{obsolete_limit}
            )
          ) gene_set_item_rows
          ORDER BY LOWER(COALESCE(name, ''))
        SQL
      else
        rows = conn.select_all(<<~SQL)
          SELECT #{item_select_sql}
          FROM gene_set_items
          WHERE #{where_clause}
          ORDER BY LOWER(COALESCE(name, ''))
          LIMIT #{limit}
        SQL
      end
      perf_db[:rows_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)

      replacement_by_identifier = {}
      replacement_ids = rows.filter_map do |row|
        next unless ActiveModel::Type::Boolean.new.cast(row['obsolete'])

        AsapData::GoTermReplacement.resolve(row['identifier'].to_s)
      end.uniq
      if replacement_ids.any?
        quoted = replacement_ids.map { |id| conn.quote(id) }.join(",")
        replacement_scope = has_item_obsolete ? "AND COALESCE(obsolete, FALSE) = FALSE" : ""
        conn.select_all(<<~SQL).each do |rep_row|
          SELECT id, identifier, name
          FROM gene_set_items
          WHERE gene_set_id = #{collection_id}
            AND identifier IN (#{quoted})
            #{replacement_scope}
        SQL
          replacement_by_identifier[rep_row['identifier'].to_s] = {
            id: rep_row['id'].to_i,
            identifier: rep_row['identifier'].to_s,
            name: rep_row['name'].to_s
          }
        end
      end

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      all_gene_ids = rows.flat_map do |row|
        row['content'].to_s.split(',').map { |v| v.to_i }.select { |v| v > 0 }
      end.uniq
      perf_db[:parse_gene_ids_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
      perf_db[:unique_gene_ids] = all_gene_ids.length

      gene_lookup = {}
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if all_gene_ids.any?
        gene_rows = conn.select_all(<<~SQL)
          SELECT id, ensembl_id, name
          FROM genes
          WHERE id IN (#{all_gene_ids.join(',')})
        SQL
        gene_rows.each do |gene_row|
          gene_lookup[gene_row['id'].to_i] = {
            id: gene_row['id'].to_i,
            ensembl_id: gene_row['ensembl_id'].to_s,
            name: gene_row['name'].to_s
          }
        end
      end
      perf_db[:gene_lookup_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)

      ontology_by_tag = AsapData::OntologyIdentifierUrl.ontology_by_tag_index
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      payload = {
        status: 'ok',
        collection: {
          id: collection_row['id'].to_i,
          label: collection_row['label'].to_s
        },
        redirected_from: redirected_from,
        items: rows.map do |row|
          gene_ids = row['content'].to_s.split(',').map { |v| v.to_i }.select { |v| v > 0 }
          in_dataset_count = gene_ids.count do |gene_id|
            gene_info = gene_lookup[gene_id]
            next false unless gene_info
            accession_key = gene_info[:ensembl_id].to_s.strip.downcase
            symbol_key = gene_info[:name].to_s.strip.downcase
            (accession_key.present? && dataset_stable_by_accession.key?(accession_key)) ||
              (symbol_key.present? && dataset_stable_by_symbol.key?(symbol_key))
          end

          identifier = row['identifier'].to_s
          obsolete = ActiveModel::Type::Boolean.new.cast(row['obsolete'])
          replaced_by_identifier = obsolete ? AsapData::GoTermReplacement.resolve(identifier) : nil
          replaced_by_item = replaced_by_identifier.present? ? replacement_by_identifier[replaced_by_identifier] : nil
          identifier_url = AsapData::OntologyIdentifierUrl.url_for(
            identifier,
            ontology_by_tag: ontology_by_tag
          )
          replaced_by_url = replaced_by_identifier.present? ? AsapData::OntologyIdentifierUrl.url_for(
            replaced_by_identifier,
            ontology_by_tag: ontology_by_tag
          ) : nil

          {
            id: row['id'].to_i,
            identifier: identifier,
            identifier_url: identifier_url,
            name: row['name'].to_s,
            display_name: row['display_name'].to_s,
            obsolete: obsolete,
            replaced_by_identifier: replaced_by_identifier,
            replaced_by_item_id: replaced_by_item && replaced_by_item[:id],
            replaced_by_name: replaced_by_item && replaced_by_item[:name],
            replaced_by_url: replaced_by_url,
            gene_count: row['gene_count'].to_i,
            in_dataset_count: in_dataset_count,
            supports_module_score: true
          }
        end,
        total_count: total_count,
        limit: limit
      }
      perf_db[:build_items_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
    end

    perf_db[:remote_total_ms] = perf_db.values_at(:collection_ms, :count_ms, :rows_ms, :parse_gene_ids_ms, :gene_lookup_ms, :build_items_ms).compact.sum.round(1)
    perf_request_total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - perf_req_t0) * 1000.0).round(1)
    Rails.logger.info(
      "[perf][gene_set_collection_items] project_id=#{@project.id} collection_id=#{collection_id} " \
      "db=#{db_version} loom_file=#{loom_file} filtered=#{query.present?} " \
      "total_count=#{payload[:total_count]} returned=#{payload[:items].length} " \
      "unique_gene_ids=#{perf_db[:unique_gene_ids]} " \
      "ms_collection=#{perf_db[:collection_ms]} ms_count=#{perf_db[:count_ms]} ms_rows=#{perf_db[:rows_ms]} " \
      "ms_parse_gene_ids=#{perf_db[:parse_gene_ids_ms]} ms_gene_lookup=#{perf_db[:gene_lookup_ms]} " \
      "ms_build_items=#{perf_db[:build_items_ms]} ms_remote_total=#{perf_db[:remote_total_ms]} " \
      "ms_request_total=#{perf_request_total_ms}"
    )

    render json: payload
  end

  # GET /projects/:id/gene_set_collection_status
  def gene_set_collection_status
    collection_id_raw = params[:collection_id].to_s.strip
    if collection_id_raw.blank?
      render json: { status: 'error', message: 'Missing gene set collection identifier' }, status: :unprocessable_entity
      return
    end

    local_collection_id = parse_local_gene_set_collection_id(collection_id_raw)
    if local_collection_id
      collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      unless collection
        render json: { status: 'failed', message: 'Gene set collection not found' }
        return
      end

      payload = load_local_gene_set_collection_payload(collection.file_key, collection.name)
      items = Array(payload['items'])
      if items.any?
        render json: {
          status: 'completed',
          collection: {
            id: local_gene_set_collection_id(collection),
            label: collection.name.to_s,
            nb_items: items.length,
            custom: true
          }
        }.deep_merge(collection_type_presentation_for_collection(collection))
      else
        render json: {
          status: 'pending',
          collection: {
            id: local_gene_set_collection_id(collection),
            label: collection.name.to_s,
            nb_items: 0,
            custom: true,
            import_pending: true
          }
        }.deep_merge(collection_type_presentation_for_collection(collection))
      end
      return
    end

    render json: { status: 'completed' }
  rescue StandardError => e
    Rails.logger.error("gene_set_collection_status failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to get collection status: #{e.message}" }, status: :unprocessable_entity
  end

  # GET /projects/:id/gene_set_item_genes
  def gene_set_item_genes
    item_id_raw = params[:item_id].to_s.strip
    if item_id_raw.blank?
      render json: { status: 'error', message: 'Missing gene set item identifier' }, status: :unprocessable_entity
      return
    end

    loom_file = params[:loom_file].to_s.strip
    if loom_file.blank?
      render json: { status: 'error', message: 'Missing loom file' }, status: :unprocessable_entity
      return
    end

    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: "gene_set_item_genes")
    current_user_id = current_user&.id
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
    loom_path = project_dir + loom_file
    unless File.exist?(loom_path)
      render json: { status: 'error', message: 'Loom file not found' }, status: :not_found
      return
    end

    begin
      dataset_lookup = cached_dataset_stable_lookup(loom_path)
      dataset_stable_by_accession = dataset_lookup[:by_accession]
      dataset_stable_by_symbol = dataset_lookup[:by_symbol]
      dataset_stable_ids = dataset_lookup[:stable_ids]
    rescue => e
      Rails.logger.error("gene_set_item_genes: failed to extract dataset gene mappings from #{loom_path}: #{e.message}")
      render json: { status: 'error', message: 'Failed to read dataset gene identifiers' }, status: :unprocessable_entity
      return
    end

    local_collection_id = parse_local_gene_set_collection_id_from_item_id(item_id_raw)
    if local_collection_id
      local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      unless local_collection
        render json: { status: 'error', message: 'Gene set collection not found' }, status: :not_found
        return
      end

      local_payload = load_local_gene_set_collection_payload(local_collection.file_key, local_collection.name)
      local_item = Array(local_payload['items']).map { |item| normalize_manual_gene_set_item(item) }.compact.find do |item|
        item[:id].to_s == item_id_raw
      end

      unless local_item
        render json: { status: 'error', message: 'Gene set item not found' }, status: :not_found
        return
      end

      genes_found = []
      missing_genes = []
      local_item[:genes].each do |gene|
        symbol_value = gene[:symbol].to_s.strip
        ensembl_value = gene[:ensembl_id].to_s.strip
        selected_stable_id = resolve_manual_gene_stable_id(
          gene,
          dataset_stable_by_accession: dataset_stable_by_accession,
          dataset_stable_by_symbol: dataset_stable_by_symbol,
          dataset_stable_ids: dataset_stable_ids
        )

        if selected_stable_id.present?
          genes_found << {
            symbol: symbol_value,
            ensembl_id: ensembl_value,
            stable_id: selected_stable_id
          }
        else
          missing_genes << {
            symbol: symbol_value,
            ensembl_id: ensembl_value,
            stable_id: gene[:stable_id].to_s.strip
          }
        end
      end

      render json: {
        status: 'ok',
        item_id: item_id_raw,
        source: 'local',
        gene_set_id: local_gene_set_collection_id(local_collection),
        genes: genes_found,
        missing_genes: missing_genes
      }
      return
    end

    if item_id_raw.start_with?("#{MANUAL_GENE_SET_COLLECTION_ID}:")
      manual_item = find_manual_gene_set_item(item_id_raw)
      unless manual_item
        render json: { status: 'error', message: 'Gene set item not found' }, status: :not_found
        return
      end

      genes = []
      missing_genes = []
      manual_item[:genes].each do |gene|
        symbol_value = gene[:symbol].to_s.strip
        ensembl_value = gene[:ensembl_id].to_s.strip
        stable_value = gene[:stable_id].to_s.strip
        accession_key = ensembl_value.downcase
        symbol_key = symbol_value.downcase
        selected_stable_id = nil
        selected_stable_id = stable_value if stable_value.present? && dataset_stable_ids.include?(stable_value)
        selected_stable_id ||= dataset_stable_by_accession[accession_key] if accession_key.present?
        selected_stable_id ||= dataset_stable_by_symbol[symbol_key] if symbol_key.present?

        if selected_stable_id.present?
          genes << {
            symbol: symbol_value,
            ensembl_id: ensembl_value,
            stable_id: selected_stable_id
          }
        else
          missing_genes << {
            symbol: symbol_value,
            ensembl_id: ensembl_value
          }
        end
      end

      render json: {
        status: 'ok',
        item: {
          id: manual_item[:id],
          gene_set_id: MANUAL_GENE_SET_COLLECTION_ID,
          name: manual_item[:name],
          identifier: manual_item[:identifier]
        },
        genes: genes,
        missing_genes: missing_genes
      }
      return
    end

    item_id = item_id_raw.to_i
    if item_id <= 0
      render json: { status: 'error', message: 'Invalid gene set item identifier' }, status: :unprocessable_entity
      return
    end

    payload = nil
    RemoteGene.with_remote(db_version) do
      conn = RemoteGene.connection

      visibility_sql = [
        "(gs.project_id IS NULL AND gs.ref_id IS NOT NULL)",
        "gs.project_id = #{@project.id}"
      ]
      if current_user_id.present?
        visibility_sql << "(gs.project_id IS NULL AND gs.user_id = #{current_user_id.to_i} AND gs.ref_id IS NULL)"
      end

      item_row = conn.select_one(<<~SQL)
        SELECT
          gsi.id,
          gsi.gene_set_id,
          gsi.name,
          gsi.identifier,
          gsi.content
        FROM gene_set_items gsi
        JOIN gene_sets gs ON gs.id = gsi.gene_set_id
        WHERE gsi.id = #{item_id}
          AND gs.organism_id = #{@project.organism_id.to_i}
          AND COALESCE(gs.obsolete, FALSE) = FALSE
          AND (#{visibility_sql.join(' OR ')})
      SQL

      unless item_row
        render json: { status: 'error', message: 'Gene set item not found' }, status: :not_found
        return
      end

      gene_ids = item_row['content'].to_s.split(',').map { |v| v.to_i }.select { |v| v > 0 }
      genes = []
      missing_genes = []

      if gene_ids.any?
        ordered_ids_sql = gene_ids.join(',')
        if ordered_ids_sql.blank?
          payload = {
            status: 'ok',
            item: {
              id: item_row['id'].to_i,
              gene_set_id: item_row['gene_set_id'].to_i,
              name: item_row['name'].to_s,
              identifier: item_row['identifier'].to_s
            },
            genes: []
          }
          next
        end

        gene_rows = conn.select_all(<<~SQL)
          SELECT
            g.id AS stable_id,
            g.name,
            g.ensembl_id
          FROM genes g
          WHERE g.id IN (#{ordered_ids_sql})
          ORDER BY array_position(ARRAY[#{ordered_ids_sql}], g.id)
        SQL

        gene_rows.each do |row|
          ensembl_value = row['ensembl_id'].to_s.strip
          name_value = row['name'].to_s.strip
          accession_key = ensembl_value.downcase
          symbol_key = name_value.downcase
          selected_stable_id = dataset_stable_by_accession[accession_key]
          selected_stable_id ||= dataset_stable_by_symbol[symbol_key]
          if selected_stable_id.present?
            genes << {
              symbol: name_value,
              ensembl_id: ensembl_value,
              stable_id: selected_stable_id
            }
          else
            missing_genes << {
              symbol: name_value,
              ensembl_id: ensembl_value
            }
          end
        end
      end

      payload = {
        status: 'ok',
        item: {
          id: item_row['id'].to_i,
          gene_set_id: item_row['gene_set_id'].to_i,
          name: item_row['name'].to_s,
          identifier: item_row['identifier'].to_s
        },
        genes: genes,
        missing_genes: missing_genes
      }
    end

    render json: payload
  end

  # GET /projects/:id/download_gene_set_collection
  def download_gene_set_collection
    collection_id_raw = params[:collection_id].to_s.strip
    if collection_id_raw.blank?
      render json: { status: 'error', message: 'Missing gene set collection identifier' }, status: :unprocessable_entity
      return
    end

    export_format = params[:export_format].to_s.strip
    unless %w[json gmt_ensembl gmt_symbol].include?(export_format)
      render json: { status: 'error', message: 'Unsupported export format' }, status: :unprocessable_entity
      return
    end

    loom_file = params[:loom_file].to_s.strip
    if loom_file.blank?
      render json: { status: 'error', message: 'Missing loom file' }, status: :unprocessable_entity
      return
    end

    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = asap_data_db_name_for_env(h_env, context: "gene_set_collection_items")
    current_user_id = current_user&.id
    dataset_stable_by_accession, dataset_stable_by_symbol = build_dataset_stable_lookup_for_export(loom_file)
    collection_payload = load_gene_set_collection_for_export(
      collection_id_raw,
      db_version: db_version,
      current_user_id: current_user_id,
      dataset_stable_by_accession: dataset_stable_by_accession,
      dataset_stable_by_symbol: dataset_stable_by_symbol
    )

    collection_label = collection_payload[:label].to_s
    safe_name = sanitize_collection_export_filename(collection_label)
    case export_format
    when 'json'
      data = JSON.pretty_generate({
        collection: collection_label,
        id: collection_payload[:id],
        items: collection_payload[:items].map do |item|
          {
            id: item[:id],
            identifier: item[:identifier],
            name: item[:name],
            genes: item[:genes].map do |gene|
              {
                symbol: gene[:symbol].to_s,
                ensembl_id: gene[:ensembl_id].to_s,
                stable_id: gene[:stable_id].to_s,
                gene_id: gene[:gene_id]
              }
            end
          }
        end
      })
      send_data data, filename: "#{safe_name}.json", type: 'application/json; charset=utf-8', disposition: 'attachment'
    when 'gmt_ensembl'
      data = build_gene_set_collection_gmt_export(collection_payload, mode: :ensembl)
      send_data data, filename: "#{safe_name}_ensembl.gmt", type: 'text/plain; charset=utf-8', disposition: 'attachment'
    when 'gmt_symbol'
      data = build_gene_set_collection_gmt_export(collection_payload, mode: :symbol)
      send_data data, filename: "#{safe_name}_symbols.gmt", type: 'text/plain; charset=utf-8', disposition: 'attachment'
    end
  rescue StandardError => e
    Rails.logger.error("download_gene_set_collection failed: #{e.class} - #{e.message}")
    render json: { status: 'error', message: "Failed to download gene set collection: #{e.message}" }, status: :unprocessable_entity
  end

  # GET /projects/:id/gene_set_item_module_score
  def gene_set_item_module_score
    item_id_raw = params[:item_id].to_s.strip
    if item_id_raw.blank?
      render json: { status: 'error', message: 'Missing gene set item identifier' }, status: :unprocessable_entity
      return
    end

    loom_file = params[:loom_file].to_s.strip
    if loom_file.blank?
      render json: { status: 'error', message: 'Missing loom file' }, status: :unprocessable_entity
      return
    end

    dataset_path = params[:dataset].to_s.strip
    dataset_path = '/matrix' if dataset_path.blank?

    request_id = params[:request_id].to_s.strip
    if request_id.blank?
      render json: { status: 'error', message: 'Missing module score request identifier' }, status: :unprocessable_entity
      return
    end

    existing = ModuleScoreRequest.find_by(request_id: request_id, project_id: @project.id)
    if existing
      render_module_score_request(existing)
      return
    end

    loom_path = @project.data_dir + loom_file
    unless File.exist?(loom_path)
      render json: { status: 'error', message: 'Loom file not found' }, status: :not_found
      return
    end

    request = ModuleScoreRequest.create!(
      request_id: request_id,
      project_id: @project.id,
      user_id: current_user&.id,
      item_id: item_id_raw,
      loom_file: loom_file,
      dataset: dataset_path,
      status: 'pending'
    )
    GeneSetItemModuleScoreJob.perform_later(request.id)
    render json: { status: 'pending', request_id: request.request_id }
  end

  # POST /projects/:id/cancel_gene_set_item_module_score
  def cancel_gene_set_item_module_score
    request_id = params[:request_id].to_s.strip
    if request_id.blank?
      render json: { status: 'error', message: 'Missing module score request identifier' }, status: :unprocessable_entity
      return
    end

    request = ModuleScoreRequest.find_by(request_id: request_id, project_id: @project.id)
    if request
      current_user_id = current_user&.id
      if current_user_id.present? && request.user_id.present? && request.user_id.to_i != current_user_id.to_i
        render json: { status: 'error', message: 'Invalid module score request owner' }, status: :forbidden
        return
      end

      request.update!(status: 'canceled') unless request.terminal?
      terminate_module_score_process(request.pid.to_i) if request.pid.present?
    end

    render json: { status: 'ok', request_id: request_id }
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

  # GET /projects/1/get_autocomplete_genes?loom_file=...
  # Payload:
  # {
  #   "schema_version": 3,
  #   "search": ["Gene ENSID {stable}", ...],
  #   "h_indexes": { "stable" => idx, ... },
  #   "aliases": { "ENSID" => { "alt" => [...], "obsolete" => [...] }, ... },
  #   "feature_names": { "stable" => "release symbol", ... },
  #   "ensembl_release": 101
  # }
  def get_autocomplete_genes
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key

    loom_file = params[:loom_file].presence
    if loom_file.blank?
      loom_file = Annot.light.where(project_id: @project.id, dim: 3, name: '/matrix').order(id: :asc).pick(:filepath)
      loom_file ||= Annot.light.where(project_id: @project.id, dim: 3).order(id: :asc).pick(:filepath)
    end

    empty_payload = {
      schema_version: GeneAutocompleteBuilder::SCHEMA_VERSION,
      search: [],
      h_indexes: {},
      aliases: {},
      feature_names: {},
      ensembl_release: nil
    }

    if loom_file.blank?
      render json: empty_payload
      return
    end

    autocomplete_file = project_dir + File.dirname(loom_file) + 'autocomplete_genes.json'
    if File.exist?(autocomplete_file)
      begin
        cached = JSON.parse(File.read(autocomplete_file))
        if GeneAutocompleteBuilder.usable_cached_payload?(cached)
          render json: cached
          return
        end
        Rails.logger.info("get_autocomplete_genes: rebuilding stale cache #{autocomplete_file}")
      rescue JSON::ParserError => e
        Rails.logger.warn("get_autocomplete_genes: existing file is invalid JSON (#{autocomplete_file}): #{e.message}")
      end
    end

    loom_path = project_dir + loom_file
    unless File.exist?(loom_path)
      render json: empty_payload
      return
    end

    begin
      vectors = H5DataService.get_metadata_vectors(
        loom_path.to_s,
        %w[/row_attrs/Gene /row_attrs/Accession /row_attrs/_StableID /row_attrs/feature_name]
      )
      gene_values = vectors['/row_attrs/Gene'] || []
      accession_values = vectors['/row_attrs/Accession'] || []
      stable_values = vectors['/row_attrs/_StableID'] || []
      feature_name_values = vectors['/row_attrs/feature_name']
    rescue => e
      Rails.logger.error("get_autocomplete_genes: failed to extract row attrs from #{loom_path}: #{e.message}")
      render json: empty_payload
      return
    end

    size = [gene_values.length, accession_values.length, stable_values.length].min
    if size <= 0
      render json: empty_payload
      return
    end

    h_env = @project.version ? Basic.safe_parse_json(@project.version.env_json, {}) : {}
    db_version = begin
      asap_data_db_name_for_env(h_env, context: 'get_autocomplete_genes')
    rescue ArgumentError => e
      Rails.logger.warn("get_autocomplete_genes: #{e.message}")
      nil
    end

    ensembl_release = nil
    begin
      attrs = H5DataService.read_short_global_attr_strings(loom_path.to_s, ['/attrs/ensembl_release'])
      ensembl_release = attrs['/attrs/ensembl_release'].to_s.strip
    rescue StandardError => e
      Rails.logger.info("get_autocomplete_genes: ensembl_release attr unavailable: #{e.message}")
    end
    if ensembl_release.blank?
      meta = Scfair::ProjectEnsemblMetadataResolver.call(@project)
      ensembl_release = meta&.dig(:ensembl_release)
    end

    payload = GeneAutocompleteBuilder.build(
      gene_values: gene_values,
      accession_values: accession_values,
      stable_values: stable_values,
      feature_name_values: feature_name_values,
      ensembl_release: ensembl_release,
      organism_id: @project.organism_id,
      db_version: db_version
    )

    begin
      FileUtils.mkdir_p(autocomplete_file.dirname)
      File.write(autocomplete_file, payload.to_json)
    rescue => e
      Rails.logger.warn("get_autocomplete_genes: failed to cache file #{autocomplete_file}: #{e.message}")
    end

    render json: payload
  end


  # GET /projects/1/get_loom_files_json
  # Lists LOOM matrices (dim 3) with download URLs and optional H5AD sibling paths, matching legacy ASAP summary behavior.
  # ATAC projects also include DNA accessibility tabix and index download entries.
  def get_loom_files_json
    unless ENV['USER_DATA_DIR'].present?
      Rails.logger.error 'get_loom_files_json: USER_DATA_DIR environment variable is not set'
      return render json: { error: 'Server configuration error' }, status: :internal_server_error
    end

    unless @project.user_id
      Rails.logger.error "get_loom_files_json: Project #{@project.id} has no user_id"
      return render json: { error: 'Project has no associated user' }, status: :internal_server_error
    end

    user_data_dir = ENV['USER_DATA_DIR'].to_s.chomp('/')
    base_dir = if user_data_dir.end_with?('/users') || user_data_dir.end_with?('users')
                 Pathname.new(user_data_dir)
               else
                 Pathname.new(user_data_dir) + 'users'
               end
    project_dir = base_dir + @project.user_id.to_s + @project.key
    # Same-origin base so modal download links stay on this instance (SERVER_URL may
    # point at another host, e.g. production, on shared/dev .env files).
    server_url = request.base_url.to_s.chomp('/')

    h_data_types = DataType.pluck(:id, :name).to_h
    # Use /matrix annots for loom ownership (same rule as build_filepath_info_from_matrix_annots).
    # Later normalization/scaling layers are also dim 3 on the same filepath and must not
    # redefine the loom's step label (e.g. cell_filtering loom shown as Normalization).
    annots = Annot.light.where(project_id: @project.id).includes(:data_type, run: [:step, :std_method]).to_a
    h_annots_by_path = Hash.new { |h, k| h[k] = [] }
    h_file_details = {}

    annots.each do |a|
      next if a.filepath.blank?

      run = a.run
      next unless run

      h_annots_by_path[a.filepath].push(
        name: a.name,
        nber_cols: a.nber_cols,
        nber_rows: a.nber_rows,
        data_type: (a.data_type_id && h_data_types[a.data_type_id]) ? h_data_types[a.data_type_id] : 'NA',
        imported: a.imported
      )

      next unless a.dim == 3 && a.name == '/matrix'
      next if h_file_details[a.filepath]

      full_path = project_dir + a.filepath
      file_size = File.exist?(full_path) ? File.size(full_path) : 0
      h_attrs = Basic.safe_parse_json(run.attrs_json, {})
      h_std_method_attrs = {}
      if run.std_method_id.present? && run.std_method&.attrs_json.present?
        h_std_method_attrs = Basic.safe_parse_json(run.std_method.attrs_json, {})
      end

      h_file_details[a.filepath] = {
        file_size: file_size,
        run_name: helpers.display_run(run),
        run_attrs: helpers.display_run_attrs(run, h_attrs, h_std_method_attrs, {}),
        nber_cols: a.nber_cols,
        nber_rows: a.nber_rows
      }
    end

    list_files = []
    h_annots_by_path.each_key do |rel_path|
      details = h_file_details[rel_path]
      next unless details

      h5ad_path = rel_path.sub(/loom\z/, 'h5ad')
      export_run = nil
      h5ad_status = 'missing'
      begin
        if rel_path.to_s.match?(/\.loom\z/i)
          export_run = Basic.latest_h5ad_export_run(@project, rel_path)
          h5ad_status = Basic.h5ad_export_status(@project, rel_path, run: export_run)
        end
      rescue ArgumentError => e
        Rails.logger.warn("get_loom_files_json: h5ad status skipped for #{rel_path}: #{e.message}")
      end

      list_files.push(
        name: rel_path,
        file_size: helpers.display_mem(details[:file_size]),
        run_name: details[:run_name],
        run_attrs: details[:run_attrs],
        nber_cols: details[:nber_cols],
        nber_rows: details[:nber_rows],
        url: "#{server_url}#{get_file_project_path(@project.key, filename: rel_path)}",
        url_h5ad: "#{server_url}#{get_file_project_path(@project.key, filename: h5ad_path)}",
        h5ad_status: h5ad_status,
        h5ad_run_id: export_run&.id,
        h5ad_status_id: export_run&.status_id,
        content: h_annots_by_path[rel_path]
      )
    end

    list_files.sort_by! { |e| e[:name].to_s }

    if params[:download].present?
      send_data list_files.to_json, filename: "loom_files_#{@project.key}.json", type: 'application/json'
    else
      atac = compliance_atac_assay_present?(@project.cxg_validation_result)
      render json: {
        files: list_files,
        atac: atac,
        dna_accessibility: atac ? dna_accessibility_download_entries(server_url) : []
      }
    end
  end

  # POST /projects/:id/export_h5ad
  # Start (or reuse) a hidden export_h5ad SLURM run for a project-relative loom path.
  def export_h5ad
    unless readable?(@project) && exportable?(@project)
      return render json: { error: 'Not authorized to export this file.' }, status: :forbidden
    end

    loom_rel = params[:input_loom].presence || params[:filename].presence
    if loom_rel.blank?
      return render json: { error: 'input_loom is required' }, status: :bad_request
    end

    user_id = current_user&.id || @project.user_id
    result = Basic.find_or_start_h5ad_export(Rails.logger, @project, loom_rel, user_id)
    if result[:error].present? && result[:run].nil?
      return render json: { error: result[:error], h5ad_status: result[:h5ad_status] }, status: :unprocessable_entity
    end

    run = result[:run]
    render json: {
      run_id: run&.id,
      status_id: run&.status_id,
      h5ad_status: result[:h5ad_status],
      error: result[:error]
    }
  end

  # GET /projects/:id/project_data_files
  # GET /api/projects/:id/project_data_files
  def project_data_files
    data_files = Annot.light.where(project_id: @project.id)
                      .where.not(filepath: [nil, ''])
                      .distinct
                      .pluck(:filepath)
                      .map { |path| Basic.normalize_data_file_path(path) }
                      .select { |path| Basic.data_file_type_from_path(path) }
                      .uniq
                      .sort

    render json: { data_files: data_files }
  end

  # GET /projects/:id/data_file_metadata_catalog?data_file=parsing/output.loom
  # GET /api/projects/:id/data_file_metadata_catalog?data_file=parsing/output.h5ad
  def data_file_metadata_catalog
    data_file = params[:data_file].presence || params[:filepath].presence
    if data_file.blank?
      return render json: { error: 'data_file parameter is required' }, status: :bad_request
    end

    catalog = Basic.generate_data_file_metadata_catalog(@project, data_file)
    if catalog.nil?
      return render json: { error: 'Data file not found for this project' }, status: :not_found
    end

    render json: catalog
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
    runs_scope = @project.runs.includes(:step, :std_method, :annots)
                        .where(status_id: 3)

    # Apply loom-file context filter when available (same as analysis view)
    begin
      all_annots_for_loom = load_loom_file_list_context
      if @available_loom_files.present?
        assign_analysis_loom_file_from_session!

        if @selected_loom_file && all_annots_for_loom
          loom_run_ids = all_annots_for_loom.select { |a| a.filepath == @selected_loom_file }.map(&:run_id).compact.uniq
          runs_scope = runs_scope.where(id: loom_run_ids) if loom_run_ids.any?
        end
      end
    rescue => e
      Rails.logger.error("[graph] Error applying loom file context: #{e.class} - #{e.message}")
    end

    runs_scope = apply_publication_snapshot_to_runs(runs_scope)
    @runs = runs_scope.order(:step_id, :num, :id)
    
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
    unless @project.single_cell?
      return render json: {
        error: 'Annotation is available only for single-cell transcriptomics projects.'
      }, status: :unprocessable_entity
    end

    annot_id = params[:annot_id].to_i
    cat_idx = params[:cat_idx].to_i
    cat_name = params[:cat_name]

    annot = Annot.find_by(id: annot_id)
    return render(json: { error: "Annotation not found" }, status: :not_found) unless annot

    annot_cell_set = AnnotCellSet.where(annot_id: annot.id, cat_idx: cat_idx).first
    clas_list = []
    if annot_cell_set&.cell_set_id
      clas_list = Cla.active.where(cell_set_id: annot_cell_set.cell_set_id)
                     .includes(:project, :annot, :cla_source)
                     .order(Arel.sql("(nber_agree - nber_disagree) DESC, created_at DESC"))
                     .to_a
      clas_list = clas_list.select { |cla| cla.project && readable?(cla.project) }
    end

    symbol_map_by_project_id = {}
    clas_list.group_by(&:project_id).each do |project_id, _project_clas|
      project = Project.find_by(id: project_id) || clas_list.find { |cla| cla.project_id == project_id }&.project
      next unless project

      symbol_map_by_project_id[project_id] = project_cla_gene_info_by_stable_id(project)
    end

    cot_ids = clas_list.flat_map do |cla|
      parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
    end.map { |value| value.to_i }.select(&:positive?).uniq
    cot_map = {}
    if cot_ids.any?
      CellOntologyTerm.where(id: cot_ids).pluck(:id, :identifier, :name).each do |id, identifier, name|
        cot_map[id] = {
          id: id,
          identifier: identifier.to_s,
          name: name.to_s
        }
      end
    end

    cla_data = clas_list.map do |cla|
      proj = cla.project
      meta = cla.annot
      metadata_name = (meta&.display_name.presence || meta&.name).to_s
      category_label = cla.cat.to_s.presence || ''
      sm = symbol_map_by_project_id[cla.project_id] || {}
      up_ids = parse_cla_field(cla.sorted_up_gene_ids.presence || cla.up_gene_ids)
      down_ids = parse_cla_field(cla.sorted_down_gene_ids.presence || cla.down_gene_ids)
      cot_ids_for_cla = parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
      up_genes = up_ids.filter_map do |gid|
        key = gid.to_s.strip
        next if key.blank?

        g = sm[key]
        if g
          { gene_id: key, symbol: g[:symbol], ensembl_id: g[:ensembl_id] }
        else
          { gene_id: key, symbol: key, ensembl_id: nil }
        end
      end
      down_genes = down_ids.filter_map do |gid|
        key = gid.to_s.strip
        next if key.blank?

        g = sm[key]
        if g
          { gene_id: key, symbol: g[:symbol], ensembl_id: g[:ensembl_id] }
        else
          { gene_id: key, symbol: key, ensembl_id: nil }
        end
      end

      {
        id: cla.id,
        num: cla.num,
        name: cla.name,
        cell_ontology_term_ids: cla.cell_ontology_term_ids,
        sorted_cell_ontology_term_ids: cla.sorted_cell_ontology_term_ids,
        cell_ontology_terms: cot_ids_for_cla.filter_map do |cot_id|
          cot_map[cot_id.to_i]
        end,
        up_gene_ids: cla.up_gene_ids,
        sorted_up_gene_ids: cla.sorted_up_gene_ids,
        down_gene_ids: cla.down_gene_ids,
        sorted_down_gene_ids: cla.sorted_down_gene_ids,
        up_genes: up_genes,
        down_genes: down_genes,
        comment: cla.comment,
        nber_agree: cla.nber_agree || 0,
        nber_disagree: cla.nber_disagree || 0,
        score: cla.score,
        created_at: cla.created_at&.strftime("%Y-%m-%d %H:%M"),
        obsolete: cla.obsolete,
        project_id: cla.project_id,
        project: {
          key: proj&.key.to_s,
          name: proj&.name.to_s,
          public_id: proj&.public_id
        },
        annot_id: cla.annot_id,
        cat_idx: cla.cat_idx,
        metadata_name: metadata_name,
        category_label: category_label,
        origin: cla.origin_label
      }
    end

    render json: {
      annot_id: annot.id,
      cat_idx: cat_idx,
      cat_name: cat_name,
      project_id: @project.id,
      clas: cla_data
    }
  end

  # POST /projects/:id/create_cla
  # Manual CLA creation from the visualization annotation popup.
  def create_cla
    unless @project.single_cell?
      return render json: {
        status: 'error',
        errors: ['Annotation is available only for single-cell transcriptomics projects.']
      }, status: :unprocessable_entity
    end

    unless annotable?(@project)
      return render json: {
        status: 'error',
        errors: ['You should be logged in and associate your ORCID ID to your account to submit annotations.']
      }, status: :forbidden
    end

    annot_id = params[:annot_id].presence || params.dig(:cla, :annot_id)
    annot = Annot.find_by(id: annot_id.to_i, project_id: @project.id)
    return render(json: { status: 'error', errors: ['Annotation not found'] }, status: :not_found) unless annot

    if annot.name.to_s.start_with?('/col_attrs/_asap_consensus_')
      return render json: {
        status: 'error',
        errors: ['Manual annotations are not allowed on consensus annotation metadata. Annotate the underlying clusterings or other non-consensus categorical metadata instead.']
      }, status: :unprocessable_entity
    end

    list_cats = Basic.safe_parse_json(annot.list_cat_json, [])
    cat_idx = (params[:cat_idx].presence || params.dig(:cla, :cat_idx)).to_i
    cat_name = (params[:cat_name].presence || params.dig(:cla, :cat) || list_cats[cat_idx]).to_s
    if cat_idx < 0 || cat_idx >= list_cats.size
      return render json: { status: 'error', errors: ['Invalid category index'] }, status: :unprocessable_entity
    end

    annot_cell_set = AnnotCellSet.where(annot_id: annot.id, cat_idx: cat_idx).first
    unless annot_cell_set&.cell_set_id
      Basic.ensure_annot_cell_sets(@project, annot, logger: Rails.logger)
      annot_cell_set = AnnotCellSet.where(annot_id: annot.id, cat_idx: cat_idx).first
    end
    unless annot_cell_set&.cell_set_id
      return render json: { status: 'error', errors: ['Cell set not found for this category'] }, status: :unprocessable_entity
    end
    cell_set = CellSet.find_by(id: annot_cell_set.cell_set_id)
    unless cell_set
      return render json: { status: 'error', errors: ['Cell set not found for this category'] }, status: :unprocessable_entity
    end

    name = (params[:name].presence || params.dig(:cla, :name)).to_s.strip
    comment = (params[:comment].presence || params.dig(:cla, :comment)).to_s.strip
    ontology_term_type_id = (params[:ontology_term_type_id].presence || params.dig(:cla, :ontology_term_type_id)).presence
    ontology_term_type_id = ontology_term_type_id.to_i if ontology_term_type_id
    ontology_term_type_id = nil unless ontology_term_type_id&.positive?
    ontology_term_type = ontology_term_type_id ? OntologyTermType.find_by(id: ontology_term_type_id) : nil
    if ontology_term_type_id && !ontology_term_type
      return render json: { status: 'error', errors: ['Invalid annotation type'] }, status: :unprocessable_entity
    end

    cot_ids = normalize_cla_id_list(
      params[:cell_ontology_term_ids].presence || params.dig(:cla, :cell_ontology_term_ids)
    )
    up_gene_ids = normalize_cla_id_list(
      params[:up_gene_ids].presence || params.dig(:cla, :up_gene_ids)
    )
    down_gene_ids = normalize_cla_id_list(
      params[:down_gene_ids].presence || params.dig(:cla, :down_gene_ids)
    )

    if cot_ids.empty?
      return render json: {
        status: 'error',
        errors: ['At least one ontology term is required.']
      }, status: :unprocessable_entity
    end

    if ontology_term_type
      obs_field = Scfair::Rules.obs_field_name_from_path(ontology_term_type.term_path)
      unless Scfair::Rules.multi_value_field?(obs_field) || cot_ids.size <= 1
        return render json: {
          status: 'error',
          errors: ['This annotation type allows only one ontology term.']
        }, status: :unprocessable_entity
      end
    elsif cot_ids.size > 1
      return render json: {
        status: 'error',
        errors: ['Multiple ontology terms require a multi-value annotation type.']
      }, status: :unprocessable_entity
    end

    overlap_ids = up_gene_ids & down_gene_ids
    if overlap_ids.any?
      return render json: {
        status: 'error',
        errors: ['The same gene cannot be both up-regulated and down-regulated.']
      }, status: :unprocessable_entity
    end

    found_cot_ids = CellOntologyTerm.where(id: cot_ids).pluck(:id).map(&:to_s)
    missing_cots = cot_ids - found_cot_ids
    if missing_cots.any?
      return render json: {
        status: 'error',
        errors: ["Unknown ontology term id(s): #{missing_cots.join(', ')}"]
      }, status: :unprocessable_entity
    end

    gene_ids_to_check = (up_gene_ids | down_gene_ids).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    if gene_ids_to_check.any?
      stable_symbol_map = project_cla_gene_symbol_by_stable_id(@project)
      ensure_project_cla_gene_symbols_for_loom!(
        stable_symbol_map,
        @project,
        annot.filepath,
        required_ids: gene_ids_to_check
      )
      missing_genes = gene_ids_to_check.reject { |gid| stable_symbol_map.key?(gid) }
      if missing_genes.any?
        return render json: {
          status: 'error',
          errors: ["Unknown gene stable id(s) for this project loom: #{missing_genes.join(', ')}"]
        }, status: :unprocessable_entity
      end
    end

    sorted_cot_ids = cot_ids.sort_by { |v| v.to_i }
    sorted_up_gene_ids = up_gene_ids.sort_by { |v| v.to_i }
    sorted_down_gene_ids = down_gene_ids.sort_by { |v| v.to_i }

    orcid_user = current_user.orcid_user
    cla = Cla.new(
      annot_id: annot.id,
      project_id: @project.id,
      cat: cat_name.presence || list_cats[cat_idx].to_s,
      cat_idx: cat_idx,
      cell_set_id: cell_set.id,
      name: name,
      comment: comment,
      ontology_term_type_id: ontology_term_type_id,
      cell_ontology_term_ids: cot_ids.join(','),
      sorted_cell_ontology_term_ids: sorted_cot_ids.join(','),
      up_gene_ids: up_gene_ids.join(','),
      down_gene_ids: down_gene_ids.join(','),
      sorted_up_gene_ids: sorted_up_gene_ids.join(','),
      sorted_down_gene_ids: sorted_down_gene_ids.join(','),
      cla_source_id: Basic::MANUAL_CLA_SOURCE_ID,
      user_id: current_user.id,
      orcid_user_id: orcid_user&.id,
      nber_agree: 0,
      nber_disagree: 0,
      obsolete: false
    )

    errors = []
    if cot_ids.any?
      existing_cla = Cla.where(cell_set_id: cell_set.id, cell_ontology_term_ids: cla.cell_ontology_term_ids).first
      if existing_cla
        errors << "Annotation ##{existing_cla.num} in group #{existing_cla.cat} has the same ontology terms."
      end
    end
    if name.present?
      existing_cla = Cla.where(cell_set_id: cell_set.id, name: name, cell_ontology_term_ids: [nil, '']).first
      if existing_cla
        errors << "Annotation ##{existing_cla.num} in group #{existing_cla.cat} has the same name."
      end
    end
    if up_gene_ids.any? || down_gene_ids.any?
      existing_cla = Cla.where(
        cell_set_id: cell_set.id,
        sorted_up_gene_ids: cla.sorted_up_gene_ids,
        sorted_down_gene_ids: cla.sorted_down_gene_ids
      ).first
      if existing_cla
        errors << "Annotation ##{existing_cla.num} in group #{existing_cla.cat} has the same gene lists (up and down)."
      end
    end

    if errors.any?
      return render json: { status: 'error', errors: errors }, status: :unprocessable_entity
    end

    all_clas = Cla.where(cell_set_id: cell_set.id).to_a
    cla.num = all_clas.map(&:num).compact.max.to_i + 1

    h_up = up_gene_ids.each_with_object({}) { |gid, h| h[gid] = 1 }
    h_down = down_gene_ids.each_with_object({}) { |gid, h| h[gid] = 1 }
    h_cot = cot_ids.each_with_object({}) { |cid, h| h[cid] = 1 }

    approaching = { cot_ids: [], up_gene_ids: [], down_gene_ids: [] }
    max_common = { cot_ids: 0, up_gene_ids: 0, down_gene_ids: 0 }
    all_clas_by_id = {}
    all_clas.each do |existing|
      all_clas_by_id[existing.id] = existing
      if existing.sorted_up_gene_ids.to_s != cla.sorted_up_gene_ids.to_s
        tmp = parse_cla_field(existing.up_gene_ids)
        nber_common = tmp.sum { |gid| h_up[gid] || 0 }
        if nber_common > max_common[:up_gene_ids]
          max_common[:up_gene_ids] = nber_common
          approaching[:up_gene_ids] = [existing.id]
        elsif nber_common.positive? && nber_common == max_common[:up_gene_ids]
          approaching[:up_gene_ids] << existing.id
        end
      end
      if existing.sorted_down_gene_ids.to_s != cla.sorted_down_gene_ids.to_s
        tmp = parse_cla_field(existing.down_gene_ids)
        nber_common = tmp.sum { |gid| h_down[gid] || 0 }
        if nber_common > max_common[:down_gene_ids]
          max_common[:down_gene_ids] = nber_common
          approaching[:down_gene_ids] = [existing.id]
        elsif nber_common.positive? && nber_common == max_common[:down_gene_ids]
          approaching[:down_gene_ids] << existing.id
        end
      end
      if existing.sorted_cell_ontology_term_ids.to_s != cla.sorted_cell_ontology_term_ids.to_s
        tmp = parse_cla_field(existing.cell_ontology_term_ids)
        nber_common = tmp.sum { |cid| h_cot[cid] || 0 }
        if nber_common > max_common[:cot_ids]
          max_common[:cot_ids] = nber_common
          approaching[:cot_ids] = [existing.id]
        elsif nber_common.positive? && nber_common == max_common[:cot_ids]
          approaching[:cot_ids] << existing.id
        end
      end
    end
    approaching.each_value(&:uniq!)

    confirm = params[:confirm].to_s == '1' || params[:confirm] == true || params[:confirm].to_s == 'true'
    needs_confirm = max_common.values.any?(&:positive?)
    if needs_confirm && !confirm
      warnings = []
      if max_common[:cot_ids].positive?
        labels = approaching[:cot_ids].filter_map { |id| all_clas_by_id[id] }.map { |c| "#{c.cat} ##{c.num}" }
        warnings << "Annotations exist for this group with #{max_common[:cot_ids]} ontology term#{'s' if max_common[:cot_ids] > 1} in common: #{labels.join(', ')}"
      end
      if max_common[:up_gene_ids].positive?
        labels = approaching[:up_gene_ids].filter_map { |id| all_clas_by_id[id] }.map { |c| "#{c.cat} ##{c.num}" }
        warnings << "Annotations exist for this group with #{max_common[:up_gene_ids]} up-regulated gene#{'s' if max_common[:up_gene_ids] > 1} in common: #{labels.join(', ')}"
      end
      if max_common[:down_gene_ids].positive?
        labels = approaching[:down_gene_ids].filter_map { |id| all_clas_by_id[id] }.map { |c| "#{c.cat} ##{c.num}" }
        warnings << "Annotations exist for this group with #{max_common[:down_gene_ids]} down-regulated gene#{'s' if max_common[:down_gene_ids] > 1} in common: #{labels.join(', ')}"
      end
      return render json: {
        status: 'warning',
        requires_confirm: true,
        warnings: warnings,
        errors: []
      }
    end

    unless cla.save
      return render json: {
        status: 'error',
        errors: cla.errors.full_messages.presence || ['Failed to save annotation']
      }, status: :unprocessable_entity
    end

    vote_attrs = {
      cla_id: cla.id,
      cla_source_id: Basic::MANUAL_CLA_SOURCE_ID,
      agree: true,
      user_id: current_user.id,
      user_name: current_user.displayed_name,
      orcid_user_id: orcid_user&.id
    }
    cla_vote = ClaVote.where(cla_id: cla.id, user_id: current_user.id).first
    if cla_vote
      cla_vote.update!(vote_attrs)
    else
      ClaVote.create!(vote_attrs)
    end
    cla.update!(nber_agree: 1)

    refreshed_clas = Cla.where(cell_set_id: cell_set.id).to_a
    selected_cla = refreshed_clas.max_by { |c| (c.nber_agree || 0) - (c.nber_disagree || 0) }

    h_cat_info = Basic.safe_parse_json(annot.cat_info_json, {})
    h_cat_info['nber_clas'] = Array.new(list_cats.size, 0) unless h_cat_info['nber_clas'].is_a?(Array)
    h_cat_info['selected_cla_ids'] = Array.new(list_cats.size, '') unless h_cat_info['selected_cla_ids'].is_a?(Array)
    while h_cat_info['nber_clas'].size < list_cats.size
      h_cat_info['nber_clas'] << 0
    end
    while h_cat_info['selected_cla_ids'].size < list_cats.size
      h_cat_info['selected_cla_ids'] << ''
    end
    h_cat_info['nber_clas'][cat_idx] = refreshed_clas.size
    h_cat_info['selected_cla_ids'][cat_idx] = selected_cla.id if selected_cla
    annot.update!(cat_info_json: h_cat_info.to_json)
    cell_set.update!(nber_clas: refreshed_clas.size, cla_id: selected_cla&.id)

    render json: {
      status: 'ok',
      cla_id: cla.id,
      num: cla.num,
      cat_idx: cat_idx,
      annot_id: annot.id
    }, status: :created
  end

  # GET /projects/1/get_cell_set_annotations?cell_set_key=<md5>
  def get_cell_set_annotations
    unless @project.single_cell?
      return render json: {
        error: 'Annotation is available only for single-cell transcriptomics projects.'
      }, status: :unprocessable_entity
    end

    cell_set_key = params[:cell_set_key].to_s.strip
    if cell_set_key.blank?
      return render json: { error: 'Cell set key is required' }, status: :unprocessable_entity
    end

    clas = Cla.active.joins(:cell_set)
             .where(cell_sets: { key: cell_set_key })
             .includes(:project, :annot, :cell_set, :user, :cla_source)
             .order(Arel.sql("(clas.nber_agree - clas.nber_disagree) DESC, clas.created_at DESC"))
             .to_a

    readable_clas = clas.select { |cla| cla.project && readable?(cla.project) }

    symbol_map_by_project_id = {}
    readable_clas.group_by(&:project_id).each do |project_id, project_clas|
      project = project_clas.first&.project
      next unless project

      symbol_map_by_project_id[project_id] = project_cla_gene_info_by_stable_id(project)
    end

    rows = readable_clas.map do |cla|
      up_gene_ids = parse_cla_field(cla.sorted_up_gene_ids.presence || cla.up_gene_ids)
      down_gene_ids = parse_cla_field(cla.sorted_down_gene_ids.presence || cla.down_gene_ids)
      gene_info_map = symbol_map_by_project_id[cla.project_id] || {}

      creator_label = if cla.user && current_user && cla.user.id == current_user.id
                        'me'
                      elsif cla.user&.email.present?
                        cla.user.email.to_s.split('@').first
                      else
                        '-'
                      end

      map_gene = lambda do |gene_id|
        key = gene_id.to_s.strip
        info = gene_info_map[key] || {}
        {
          gene_id: key,
          symbol: info[:symbol].presence || key,
          ensembl_id: info[:ensembl_id]
        }
      end

      proj = cla.project
      {
        project_id: cla.project_id,
        project_key: proj&.key.to_s,
        project: {
          key: proj&.key.to_s,
          name: proj&.name.to_s,
          public_id: proj&.public_id
        },
        metadata_name: (cla.annot&.display_name.presence || cla.annot&.name.to_s),
        cluster_category: cla.cat.presence || cla.name.presence || '-',
        label: cla.name.presence || cla.cat.presence || '-',
        cell_set_key: cla.cell_set&.key.to_s,
        up_genes: up_gene_ids.map { |gene_id| map_gene.call(gene_id) },
        down_genes: down_gene_ids.map { |gene_id| map_gene.call(gene_id) },
        nber_agree: cla.nber_agree || 0,
        nber_disagree: cla.nber_disagree || 0,
        created_by: creator_label,
        created_at: cla.created_at&.strftime('%b %d, %Y'),
        origin: cla.origin_label
      }
    end

    render json: { cell_set_key: cell_set_key, annotations: rows }
  rescue StandardError => e
    Rails.logger.error("[get_cell_set_annotations] #{e.class}: #{e.message}")
    render json: { error: 'Unable to load cell set annotations' }, status: :internal_server_error
  end

  # GET /projects/:id/discover_metadata_import_sources?cell_set_id=... OR ?cell_set_key=...
  # Mode A (R-M1a): readable source projects sharing project_cell_set_id + Annots on that cell set.
  def discover_metadata_import_sources
    cell_set_id = params[:cell_set_id].presence&.to_i
    cell_set_key = params[:cell_set_key].to_s.strip.presence

    unless cell_set_id&.positive? || cell_set_key.present?
      return render json: { error: "cell_set_id or cell_set_key is required" }, status: :unprocessable_entity
    end

    result = MetadataImportModeADiscoveryService.call(
      target_project: @project,
      cell_set_id: (cell_set_id if cell_set_id&.positive?),
      cell_set_key: cell_set_key,
      readable_if: ->(p) { readable?(p) }
    )

    unless result[:ok]
      return render json: { error: result[:error] }, status: result[:status] || :unprocessable_entity
    end

    render json: result[:payload]
  end

  # GET /projects/:id/discover_metadata_import_from_project?source_project_id=... OR ?source_project_key=...
  # Mode B (R-M1b): readable source project + compatible Annot list for multi-select import planning.
  def discover_metadata_import_from_project
    source_project_id = params[:source_project_id].presence&.to_i
    source_project_key = params[:source_project_key].to_s.strip.presence

    unless source_project_id&.positive? || source_project_key.present?
      return render json: { error: "source_project_id or source_project_key is required" }, status: :unprocessable_entity
    end

    result = MetadataImportModeBDiscoveryService.call(
      target_project: @project,
      source_project_id: (source_project_id if source_project_id&.positive?),
      source_project_key: source_project_key,
      readable_if: ->(p) { readable?(p) }
    )

    unless result[:ok]
      return render json: { error: result[:error] }, status: result[:status] || :unprocessable_entity
    end

    render json: result[:payload]
  end

  # GET /projects/:id/metadata_import_cell_sets
  # Cell sets sharing {project_cell_set_id} with this project (for Mode A picker in import wizard).
  def metadata_import_cell_sets
    pcs_id = @project.project_cell_set_id
    unless pcs_id
      return render json: { cell_sets: [], error: "This project has no cell-set identity (project_cell_set_id)." }
    end

    rows = CellSet.where(project_cell_set_id: pcs_id).order(:id).pluck(:id, :key)
    render json: {
      cell_sets: rows.map { |id, key| { id: id, key: key.to_s } }
    }
  end

  # GET /projects/1/get_annot_evidences?annot_id=123&cat_idx=0
  def get_annot_evidences
    unless @project.single_cell?
      return render json: {
        error: 'Annotation is available only for single-cell transcriptomics projects.'
      }, status: :unprocessable_entity
    end

    annot_id = params[:annot_id].to_i
    cat_idx = params[:cat_idx].to_i

    annot = Annot.find_by(id: annot_id, project_id: @project.id)
    return render(json: { error: 'Annotation not found' }, status: :not_found) unless annot

    unless marker_compatible_metadata?(annot)
      return render json: {
        state: 'unsupported',
        message: 'FindMarkers evidences are available only for categorical metadata with more than one category (for example clustering or selections).',
        rows_up: [],
        rows_down: []
      }
    end

    unless analyzable?(@project)
      if %w[1 true].include?(params[:status_only].to_s.downcase)
        return render json: marker_evidences_status_json_non_analyzable_peek(annot)
      end

      marker_run = marker_run_for_annot(annot)
      unless marker_run
        return render json: {
          state: 'analyze_forbidden',
          message: MARKER_EVIDENCES_ANALYZE_FORBIDDEN_MESSAGE,
          rows_up: [],
          rows_down: []
        }
      end

      status_id = marker_run.status_id.to_i
      status_name = marker_run.status&.name.to_s

      if status_id == 4
        return render json: {
          state: 'failed',
          run_id: marker_run.id,
          status_id: status_id,
          status_name: status_name,
          message: markers_failed_user_message(marker_run),
          rows_up: [],
          rows_down: []
        }
      end

      if status_id == 3
        parsed = parse_marker_rows_for_category(marker_run, cat_idx, annot: annot)
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

        return render json: {
          state: 'completed',
          run_id: marker_run.id,
          status_id: status_id,
          status_name: status_name,
          message: "FindMarkers evidences loaded for category #{cat_idx + 1}.",
          rows_up: parsed[:rows_up],
          rows_down: parsed[:rows_down]
        }
      end

      return render json: {
        state: 'analyze_forbidden',
        message: MARKER_EVIDENCES_ANALYZE_FORBIDDEN_MESSAGE,
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        rows_up: [],
        rows_down: []
      }
    end

    # Read-only poll: existing run status only; does not create or enqueue FindMarkers.
    if %w[1 true].include?(params[:status_only].to_s.downcase)
      return render json: marker_evidences_status_json_readonly(annot, cat_idx)
    end

    run_data = find_or_start_marker_run_for_annot(annot)
    marker_run = run_data[:run]
    return render(json: { state: 'error', message: run_data[:error] || 'Unable to initialize FindMarkers run.', rows_up: [], rows_down: [] }) unless marker_run

    status_id = marker_run.status_id.to_i
    status_name = marker_run.status&.name.to_s

    if run_data[:error].present? && (status_id == 1 || (status_id == 6 && marker_run.slurm_job_id.blank?))
      return render json: {
        state: 'failed',
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        message: run_data[:error],
        rows_up: [],
        rows_down: []
      }
    end

    if marker_run_slurm_executing?(marker_run) && [1, 2, 6].include?(status_id)
      broadcast_markers_run_status_changed(marker_run) if [1, 6].include?(status_id)
      msg = if run_data[:started]
              'FindMarkers started for this metadata. Results will appear when the run is complete.'
            else
              'FindMarkers is running for this metadata.'
            end
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

    if status_id == 1 || (status_id == 6 && marker_run.slurm_job_id.blank?)
      msg = if marker_run.slurm_job_id.present?
              'FindMarkers is queued for execution.'
            elsif run_data[:resubmitted]
              'FindMarkers queue submission was refreshed. Waiting for scheduler assignment.'
            elsif run_data[:submitted]
              'FindMarkers was queued. Waiting for scheduler assignment.'
            else
              'FindMarkers is pending scheduling.'
            end
      details = { message: msg }
      if marker_run.slurm_job_id.present?
        snap = marker_slurm.pending_job_queue_snapshot(marker_run.slurm_job_id)
        details = marker_queued_json_from_snapshot(snap, msg) if snap
      end
      return render json: {
        state: 'queued',
        run_id: marker_run.id,
        status_id: status_id,
        status_name: status_name,
        rows_up: [],
        rows_down: []
      }.merge(details)
    end

    if status_id == 2 || (status_id == 6 && marker_run.slurm_job_id.present?)
      jid = marker_run.slurm_job_id
      if jid.present?
        snap = marker_slurm.pending_job_queue_snapshot(jid)
        if snap
          base = 'FindMarkers is queued on the cluster. The job has not started on a compute node yet.'
          return render json: {
            state: 'queued',
            run_id: marker_run.id,
            status_id: status_id,
            status_name: status_name,
            rows_up: [],
            rows_down: []
          }.merge(marker_queued_json_from_snapshot(snap, base))
        end

        if slurm_job_pending_in_scheduler?(jid)
          return render json: {
            state: 'queued',
            run_id: marker_run.id,
            status_id: status_id,
            status_name: status_name,
            message: 'FindMarkers is queued on the cluster. The job has not started on a compute node yet.',
            rows_up: [],
            rows_down: []
          }
        end
      end

      msg = run_data[:started] ? 'FindMarkers started for this metadata. Results will appear when the run is complete.' : 'FindMarkers is running for this metadata.'
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
        message: markers_failed_user_message(marker_run),
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

    parsed = parse_marker_rows_for_category(marker_run, cat_idx, annot: annot)
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
    @runs = runs.select { |r| run_visible_under_publication_rules?(@project, r) }
    
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
      Annot.light.where(id: annot_ids.uniq).each do |annot|
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
    
    @h_statuses = Status.all.index_by(&:id)
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
    @runs = apply_publication_snapshot_to_runs(@project.runs.includes(:annots))
    
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

    assign_summary_submitted_file_link!

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

  # GET /projects/:id/spatial_data
  # Returns the spot coordinates for a spatial (Visium) embedding together with
  # the tissue image extent and Visium scalefactors so the visualization can draw
  # the tissue map behind the spots (CellxGene-style spatial view).
  #
  # Spot coordinates are the fullres pixel positions stored in the loom at
  # /col_attrs/spatial (origin top-left, Y increases downward — same as the
  # tissue image and CellxGene spatial embeddings). Do not negate Y here: that
  # produced a vertically flipped view relative to CellxGene.
  def spatial_data
    metadata = Annot.find_by(id: params[:metadata_id], project_id: @project.id)
    if metadata.nil?
      render json: { error: 'Embedding not found' }, status: :not_found
      return
    end

    loom_file = params[:loom_file].presence || metadata.filepath
    loom_path = @project_dir + loom_file
    unless File.exist?(loom_path)
      render json: { error: "Data file not found: #{loom_file}" }, status: :not_found
      return
    end

    coordinates = H5DataService.get_metadata_vector(loom_path.to_s, metadata.name)
    if coordinates.blank?
      render json: { error: 'No spatial coordinates found' }, status: :not_found
      return
    end

    display_coordinates = coordinates.map do |pair|
      [pair[0].to_f, pair[1].to_f]
    end

    info = SpatialDataService.metadata_info(loom_path.to_s)

    result = {
      is_spatial: true,
      name: metadata.display_name,
      cell_count: display_coordinates.length,
      coordinates: display_coordinates,
      has_image: false
    }

    scalef = info['tissue_hires_scalef']
    if info['has_image'] && scalef && scalef.to_f.positive? && info['library'].present?
      hires_width = info['hires_width'].to_f
      hires_height = info['hires_height'].to_f
      extent_x = hires_width / scalef.to_f
      extent_y = hires_height / scalef.to_f

      result[:has_image] = true
      result[:library] = info['library']
      result[:tissue_hires_scalef] = scalef.to_f
      result[:spot_diameter_fullres] = info['spot_diameter_fullres']&.to_f
      # Image extent in the same pixel coordinate space as the spots (Y down).
      result[:image_extent] = { minX: 0.0, maxX: extent_x, minY: 0.0, maxY: extent_y }
      result[:image_url] = spatial_image_project_path(@project, loom_file: loom_file, library: info['library'])
    end

    render json: result
  rescue => e
    Rails.logger.error "Error fetching spatial data: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    render json: { error: 'Failed to fetch spatial data' }, status: :internal_server_error
  end

  # GET /projects/:id/spatial_image
  # Streams the hires tissue image (PNG) for a Visium library so it can be drawn
  # as the background of the spatial visualization.
  def spatial_image
    loom_file = params[:loom_file].presence
    library = params[:library].presence
    if loom_file.blank? || library.blank? || !library.match?(/\A[0-9A-Za-z_\-]+\z/)
      render json: { error: 'Invalid parameters' }, status: :bad_request
      return
    end

    loom_path = @project_dir + loom_file
    unless File.exist?(loom_path)
      render json: { error: "Data file not found: #{loom_file}" }, status: :not_found
      return
    end

    cache_path = SpatialDataService.export_hires_png(loom_path.to_s, library)
    if cache_path.nil? || !File.exist?(cache_path)
      render json: { error: 'Tissue image not available' }, status: :not_found
      return
    end

    response.headers['Cache-Control'] = 'private, max-age=86400'
    send_file cache_path, type: 'image/png', disposition: 'inline'
  rescue => e
    Rails.logger.error "Error serving spatial image: #{e.message}"
    render json: { error: 'Failed to serve tissue image' }, status: :internal_server_error
  end

  # GET /projects/:id/heatmap_data?run_id=:run_id[&part=matrix]
  # Serves the precomputed heatmap output for the interactive viewer:
  #   - part=matrix -> streams heatmap_matrix.bin (Float32 little-endian, row-major genes x columns)
  #   - otherwise   -> renders heatmap_meta.json (orders, dendrograms, labels, tracks, value range)
  def heatmap_data
    run = Run.find_by(id: params[:run_id], project_id: @project.id)
    if run.nil?
      render json: { error: 'Run not found' }, status: :not_found
      return
    end

    step = run.step || Step.find_by(id: run.step_id)
    step_name = step&.name || 'heatmap'
    step_dir = @project_dir + step_name
    output_dir = (step && step.multiple_runs == false) ? step_dir : (step_dir + run.id.to_s)

    meta_path = output_dir + 'heatmap_meta.json'
    matrix_path = output_dir + 'heatmap_matrix.bin'

    if params[:part].to_s == 'matrix'
      unless File.exist?(matrix_path)
        render json: { error: 'Heatmap matrix not found' }, status: :not_found
        return
      end
      response.headers['Content-Type'] = 'application/octet-stream'
      response.headers['X-Run-ID'] = run.id.to_s
      send_file matrix_path.to_s, type: 'application/octet-stream', disposition: 'inline'
      return
    end

    unless File.exist?(meta_path)
      render json: { error: 'Heatmap results not found', status: run.status_id }, status: :not_found
      return
    end

    # Legacy runs stored dendrograms as deeply nested JSON; read without the
    # default nesting cap, convert to flat linkage, then serialize (render json:
    # would hit the same cap when re-encoding nested trees).
    meta = JSON.parse(File.read(meta_path), max_nesting: false)
    HeatmapMetaNormalizer.normalize!(meta)
    meta['loom_file'] = heatmap_loom_file_for_run(run)
    meta['matrix_url'] = heatmap_data_project_path(@project, run_id: run.id, part: 'matrix')
    enrich_heatmap_selection_meta!(meta, meta['loom_file'])
    render body: JSON.generate(meta), content_type: 'application/json'
  rescue StandardError => e
    Rails.logger.error("[heatmap_data] #{e.class} - #{e.message}")
    render json: { error: 'Failed to load heatmap data' }, status: :internal_server_error
  end

  # GET /projects/:id/heatmap_metadata_catalog?run_id=:run_id
  # Lists cell (column) and gene (row) metadata available for dynamic annotation tracks.
  def heatmap_metadata_catalog
    run = heatmap_run_for_params
    return unless run

    loom_file = heatmap_loom_file_for_run(run)
    if loom_file.blank?
      render json: { error: 'Heatmap loom file not found' }, status: :not_found
      return
    end

    render json: {
      loom_file: loom_file,
      column_metadata: heatmap_metadata_options_for(loom_file, dim: 1),
      row_metadata: heatmap_metadata_options_for(loom_file, dim: 2)
    }
  rescue StandardError => e
    Rails.logger.error("[heatmap_metadata_catalog] #{e.class} - #{e.message}")
    render json: { error: 'Failed to load metadata catalog' }, status: :internal_server_error
  end

  # GET /projects/:id/heatmap_track?run_id=&metadata_id=&axis=column|row
  # Returns a metadata vector aligned to the heatmap column or row order.
  def heatmap_track
    run = heatmap_run_for_params
    return unless run

    metadata_id = params[:metadata_id].to_i
    axis = params[:axis].to_s
    unless metadata_id.positive? && %w[column row].include?(axis)
      render json: { error: 'metadata_id and axis (column or row) are required' }, status: :bad_request
      return
    end

    annot = Annot.find_by(id: metadata_id, project_id: @project.id)
    unless annot
      render json: { error: 'Metadata not found' }, status: :not_found
      return
    end

    expected_dim = axis == 'column' ? 1 : 2
    if annot.dim != expected_dim
      render json: { error: "Metadata is not valid for #{axis} tracks" }, status: :unprocessable_entity
      return
    end

    meta = heatmap_meta_for_run(run)
    unless meta
      render json: { error: 'Heatmap results not found' }, status: :not_found
      return
    end

    loom_file = params[:loom_file].presence || heatmap_loom_file_for_run(run)
    loom_path = @project_dir + loom_file
    unless File.exist?(loom_path)
      render json: { error: "Loom file not found: #{loom_file}" }, status: :not_found
      return
    end

    raw_vector = H5DataService.get_metadata_vector(loom_path.to_s, annot.name)
    if raw_vector.blank?
      render json: { error: 'No metadata values found' }, status: :not_found
      return
    end

    values = if axis == 'column'
               HeatmapTrackAligner.column_values(meta, raw_vector, loom_path)
             else
               HeatmapTrackAligner.row_values(meta, raw_vector, loom_path)
             end

    render json: HeatmapTrackAligner.build_track_payload(annot, values)
  rescue StandardError => e
    Rails.logger.error("[heatmap_track] #{e.class} - #{e.message}")
    render json: { error: 'Failed to load heatmap track' }, status: :internal_server_error
  end

  # GET /projects/1/metadata_vectors.json
  def metadata_vectors
    metadata_ids = params[:metadata_ids]&.split(',') || []
    
    begin
      metadata_vectors_data = {}
      loom_files_used = []
      metadata_errors = {}
      
      metadata_ids.each do |metadata_id|
        begin
          metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
          next unless metadata
          
          # Use the metadata's own filepath to find the correct loom file
          loom_file = params[:loom_file] || metadata.filepath
          loom_path = @project_dir + loom_file
          
          # Check if the loom file exists before trying to extract metadata
          unless File.exist?(loom_path)
            Rails.logger.warn "Loom file does not exist: #{loom_path} - skipping metadata #{metadata_id}"
            metadata_errors[metadata_id] = "Loom file not found: #{loom_file}"
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
            metadata_errors[metadata_id] = "No data found for metadata"
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
        rescue => e
          Rails.logger.error "Error loading metadata vector #{metadata_id}: #{e.class} - #{e.message}"
          metadata_errors[metadata_id] = e.message
          next
        end
      end
      
      render json: { 
        metadata_vectors: metadata_vectors_data,
        total_loaded: metadata_vectors_data.size,
        loom_files: loom_files_used,
        errors: metadata_errors
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
        matrix_annot = Annot.light.where(project_id: @project.id, filepath: loom_file, dim: 3, name: params[:layer]).first
      end
      matrix_annot ||= Annot.light.where(project_id: @project.id, filepath: loom_file, dim: 3, name: '/matrix').first
      matrix_name = matrix_annot&.name || '/matrix'
      matrix_annot_id = matrix_annot&.id

      Rails.logger.info "Using expression matrix: #{matrix_name} (annot_id: #{matrix_annot_id || 'none'})"

      # Find gene metadata with _StableID name
      gene_metadata = Annot.light.where(project_id: @project.id, dim: 2, name: '/row_attrs/_StableID')
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
    # Remote DB name is stored in version.env_json['asap_data_db_name']
    # Always use remote asap_data_vX databases - if one doesn't exist, it's a database configuration issue
    return [] unless version_id

    version = Version.find_by(id: version_id)
    return [] unless version

    # Get remote database name from env_json
    env_data = Basic.safe_parse_json(version.env_json, {})
    db_name = env_data['asap_data_db_name']

    unless db_name
      Rails.logger.error("[ProjectsController] Version #{version_id} does not have asap_data_db_name in env_json")
      return []
    end
    
    # Fetch from remote database - returns array of hashes
    # If database doesn't exist, RemoteOrganism.list_for_version will raise an ArgumentError
    # This indicates a database configuration issue that should be fixed
    RemoteOrganism.list_for_version(db_name)
  end

  def asap_data_db_name_for_env(h_env, context: nil)
    db_name = h_env['asap_data_db_name'].to_s.strip
    return db_name if db_name.present?

    source = context.present? ? " (#{context})" : ""
    raise ArgumentError, "Missing asap_data_db_name in version env_json#{source}"
  end

  def group_organisms(organisms, version_id: nil)
    groups = Hash.new { |h, k| h[k] = [] }
    grouped_seen = Hash.new { |h, k| h[k] = {} }
    
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
        short_name = organism['short_name']
        display_name = Organism.selector_label(organism_name, short_name)
        tax_id = organism['tax_id']
        assembly_status = organism['assembly_status']
        
        # Get domain name from hash (already fetched in RemoteOrganism.list_for_version)
        domain_name = organism['domain_name'] || 'Other'
      else
        # Local organism (ActiveRecord)
        organism_name = organism.name
        organism_id = organism.id
        short_name = organism.short_name
        display_name = Organism.selector_label(organism_name, short_name)
        tax_id = organism.tax_id
        assembly_status = nil
        
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
          # Only include if short_name is exactly "Mouse" or "Rat"
          if short_name == 'Mouse' || short_name == 'Rat'
            is_model_organism = true
          end
        else
          # For other model organisms, include all entries
          is_model_organism = true
        end
      end
      
      # Keep each organism in a single group to avoid duplicates in the selector.
      # Model organisms are surfaced in the dedicated group; all others stay in domain groups.
      target_group = is_model_organism ? 'Main model organisms' : formatted_domain
      group_entry = [display_name, organism_id, tax_id, assembly_status]

      # Remote v8+ lists can contain duplicate rows; keep only one entry per group.
      next if grouped_seen[target_group][group_entry]

      grouped_seen[target_group][group_entry] = true
      groups[target_group] << group_entry
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

  def version_v8_or_later?(version_id)
    version_id.to_i >= 8
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
    with_request_profile('projects#step_results', view: params[:view] || params[:step_id]) do
    Rails.logger.info("===== STEP_RESULTS CALLED =====")
    Rails.logger.info("Project ID: #{@project&.id}, Step ID param: #{params[:step_id]}")

    begin
      # Reload project to ensure fresh state (in case restart_step left it in a bad state)
      @project.reload
      Rails.logger.info("Project reloaded: #{@project.id}")
      
      # Ensure project steps exist (safeguard for existing projects)
      @project.ensure_project_steps
      Rails.logger.info("Project steps ensured")

      # Load loom file context for filtering runs and inputs (analysis-style context)
      all_annots_for_loom = nil
      begin
        all_annots_for_loom = load_loom_file_list_context
        assign_analysis_loom_file_from_session! if @available_loom_files.present?
      rescue => e
        Rails.logger.error("[step_results] Error loading loom file context: #{e.class} - #{e.message}")
      end
      
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
      
      # Get runs for this step, optionally filtered by selected loom file context.
      # For multi-run steps, treat same-name step IDs within the same docker image
      # as one logical step and load their runs together.
      step_ids_for_runs =
        if @step.multiple_runs
          scoped_steps = step_scope_for_project(@project)
          scoped_steps = scoped_steps.where(name: @step.name)
          scoped_steps.pluck(:id)
        else
          [@step.id]
        end
      runs_scope = @project.runs.where(step_id: step_ids_for_runs).includes(:status)
      if @selected_loom_file.present? && all_annots_for_loom
        loom_run_ids = all_annots_for_loom.select { |a| a.filepath == @selected_loom_file }.map(&:run_id).compact.uniq
        if loom_run_ids.any?
          run_ids_for_scope = loom_run_ids.dup
          # Single-run steps: queued/running jobs have no matrix annots yet; keep them visible.
          unless @step.multiple_runs
            active_ids = @project.runs.where(step_id: step_ids_for_runs, status_id: [1, 2, 6]).pluck(:id)
            run_ids_for_scope.concat(active_ids)
            run_ids_for_scope.uniq!
          end
          runs_scope = runs_scope.where(id: run_ids_for_scope)
        end
      end
      runs_scope = apply_publication_snapshot_to_runs(runs_scope)
      @runs = runs_scope.includes(:annots, :status).order(created_at: :desc)
      Rails.logger.info("[step_results][debug] step_id=#{step_id} step_name=#{@step&.name} selected_loom_file=#{@selected_loom_file.inspect} show_form_param=#{params[:show_form].inspect} prefer_runs_list_param=#{params[:prefer_runs_list].inspect} runs_count=#{@runs.size} run_ids=#{@runs.map(&:id).join(',')}")
      @missing_single_run_in_loom_context =
        @step &&
        !@step.multiple_runs &&
        @selected_loom_file.present? &&
        @runs.empty? &&
        @project.runs.where(step_id: @step.id).exists?

      # Enforce single-run invariant for steps configured with multiple_runs = false.
      # Keep the most recent run and remove older duplicates.
      if @step && !@step.multiple_runs && @runs.size > 1
        runs_to_keep = @runs.first
        runs_to_delete = @runs.drop(1).reject { |r| @project.locked_from_publication?(r) }
        Rails.logger.warn("[step_results] Found #{runs_to_delete.size} extra run(s) for single-run step #{@step.name} in project #{@project.id}; deleting older runs and keeping run #{runs_to_keep.id}")
        runs_to_delete.each do |run|
          begin
            RunsController.destroy_run_call(@project, run)
          rescue => e
            Rails.logger.error("[step_results] Failed to delete duplicate run #{run.id}: #{e.class} - #{e.message}")
            raise
          end
        end
        @runs = apply_publication_snapshot_to_runs(@project.runs.where(step_id: step_id)).includes(:annots, :status).order(created_at: :desc)
      end
      
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
        @slurm_queue_hover = nil
        if @current_run && [1, 6].include?(@current_run.status_id) && @current_run.slurm_job_id
          begin
            slurm_service = SlurmService.new(logger: Rails.logger)
            job_status = slurm_service.get_job_status(@current_run.slurm_job_id, @current_run)
            if slurm_service.show_slurm_queue_line?(@current_run.slurm_job_id, job_status)
              @queue_position = slurm_service.get_job_queue_position(
                @current_run.slurm_job_id,
                @current_run.status_id,
                job_status: job_status,
                run: @current_run
              )
              snap = slurm_service.pending_job_queue_snapshot(@current_run.slurm_job_id)
              @slurm_queue_hover = MarkerQueueText.hover_summary(snap, @queue_position)
            end
            Rails.logger.info("[step_results] Queue position for Run##{@current_run.id}: #{@queue_position.inspect}")
          rescue => e
            Rails.logger.warn("[step_results] Could not get queue position: #{e.message}")
          end
        end
      end
      
      # For parsing step, load the results from output.json
      if @step.name == 'parsing'
        # @parsing_run is already set above if @current_run exists (loom-filtered @runs).
        # Fall back to the project's parsing run so the custom view still works when a loom
        # filter hides that run from @runs.
        @parsing_run ||= @current_run if @current_run
        unless @parsing_run
          @parsing_run = apply_publication_snapshot_to_runs(
            @project.runs.where(step_id: @step.id)
          ).order(created_at: :desc).first
        end

        @results = nil

        project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
        step_dir = project_dir + 'parsing'
        # Parsing output is stored at the parsing step root.
        output_json = step_dir + 'output.json'

        parsing_in_progress = @parsing_run && [1, 2].include?(@parsing_run.status_id)

        # Load output.json when parsing is not actively running (completed, failed, or stale file after reset).
        if File.exist?(output_json) && !parsing_in_progress
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

        # Build summary arrays for warnings and errors based on all conditions in the view
        @parsing_warnings = []
        @parsing_infos = []
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

          # Collect info notes from @results['messages'] (array or single value)
          if @results['messages']
            messages = @results['messages'].is_a?(Array) ? @results['messages'] : [@results['messages']]
            @parsing_infos.concat(messages.compact.reject(&:blank?))
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
          
          # Ensembl mapping: error only when a meaningful fraction is missing (>= 5%)
          if nber_not_found_genes && nber_not_found_genes > 0
            total_genes = @results['nber_rows'] || 1
            not_found_percentage = (nber_not_found_genes.to_f * 100 / total_genes).round(2)
            msg = "#{nber_not_found_genes} (#{not_found_percentage}%) #{helpers.row_label(@project)} were not found in Ensembl"
            if not_found_percentage >= 5
              @parsing_errors << "#{msg}. Did you select the right species (now #{@project.organism&.name || 'Unknown'})? if not, reset the project"
            else
              @parsing_infos << msg
            end
          end
          
          # Validation warnings (info alerts - zero values percentage)
          if @results['nber_zeros'] && @results['nber_rows'] && @results['nber_cols']
            total_values = @results['nber_rows'].to_f * @results['nber_cols'].to_f
            if total_values > 0
              zero_percentage = ((@results['nber_zeros'].to_f * 100) / total_values).round(2)
              @parsing_infos << "#{zero_percentage}% of values are zeros"
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

      if @step.name == "doublet_calling"
        begin
          prepare_doublet_calling_data
        rescue => e
          Rails.logger.error("[step_results] Error preparing doublet calling data: #{e.class} - #{e.message}")
          Rails.logger.error("[step_results] Backtrace: #{e.backtrace.first(10).join("\n")}")
          @doublet_loom_path = nil
          @doublet_score_path = nil
          @doublet_call_path = nil
          @doublet_score_histogram = {}
          @doublet_scores = []
          @std_method = nil
          @h_run_attrs = {}
          @h_std_method_attrs = {}
          @h_annots_for_params = {}
          @h_ori_runs_for_params = {}
          @h_steps_for_params = {}
          @doublet_method_attrs = {}
          @doublet_param_sections = []
        end
      end
      
      # Prepare data for standard dashboard and view
      # Skip for parsing step as it has its own special handling
      if @step.name != 'parsing' && (@step.has_std_dashboard || @step.has_std_view || @step.has_std_form || !@step.multiple_runs)
        begin
          Rails.logger.info("[step_results] Calling prepare_std_step_data for step: #{@step.name}, multiple_runs: #{@step.multiple_runs}, has_std_dashboard: #{@step.has_std_dashboard}, has_std_view: #{@step.has_std_view}, has_std_form: #{@step.has_std_form}, runs_count: #{@runs&.count || 0}")
          prepare_std_step_data
          Rails.logger.info("[step_results] After prepare_std_step_data: show_dashboard=#{@show_dashboard}, show_view=#{@show_view}, show_form=#{@show_form}, show_custom_form=#{@show_custom_form}")
          Rails.logger.info("[step_results][debug] post_prepare flags step_id=#{@step.id} show_form=#{@show_form} show_dashboard=#{@show_dashboard} show_view=#{@show_view} show_custom_form=#{@show_custom_form} params_show_form=#{params[:show_form].inspect} params_prefer_runs_list=#{params[:prefer_runs_list].inspect}")
        rescue => e
          Rails.logger.error("[step_results] Error preparing std step data: #{e.class} - #{e.message}")
          Rails.logger.error("[step_results] Backtrace: #{e.backtrace.first(10).join("\n")}")
          # Set defaults to prevent view errors
          @show_dashboard = false
          @show_view = false
          @show_form = false
          @show_custom_form = false
          @show_specific_view = false
        end

      else
        Rails.logger.info("[step_results] Skipping prepare_std_step_data - step: #{@step.name}, has_std_dashboard: #{@step.has_std_dashboard}, has_std_view: #{@step.has_std_view}, has_std_form: #{@step.has_std_form}")
        # Initialize display flags even if prepare_std_step_data is not called
        @show_dashboard = false
        @show_view = false
        @show_form = false
        @show_custom_form = false
        @show_specific_view = false
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
    
    @h_statuses ||= Status.all.index_by(&:id)

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
          # DE has dedicated sub-views (de_filter, markers, dashboard) that must
          # bypass generic std_step rendering flags.
          if @step&.name == 'de' && %w[de_filter markers dashboard].include?(params[:view].to_s)
            render partial: 'projects/views/de', layout: false
            return
          end

          # GE has dedicated sub-views (ge_filter, dashboard) that must
          # bypass generic std_step rendering flags.
          if @step&.name == 'ge' && %w[ge_filter dashboard].include?(params[:view].to_s)
            render partial: 'projects/views/ge', layout: false
            return
          end

          # If compare_clusters view is requested, return the comparison UI
          if params[:view] == 'compare_clusters'
            render partial: 'projects/views/cluster_comparison', layout: false
            return
          end

          # Parsing always uses the dedicated partial (never std_step / std_run_view).
          if @step&.name == 'parsing'
            render partial: 'projects/views/parsing', layout: false
            return
          end

          # If show_form is requested, return just the form (for AJAX or new page),
          # except for single-run steps with a specific view and existing runs:
          # these must always render the summary/view, not the form.
          force_specific_single_run_view = !@step.multiple_runs && !@step.has_std_view && @runs.present? && @runs.any?
          prefer_runs_list = params[:prefer_runs_list].present? && params[:prefer_runs_list].to_s == '1'
          Rails.logger.info("[step_results][debug] render_branch show_form_param=#{params[:show_form].inspect} prefer_runs_list=#{prefer_runs_list} force_specific_single_run_view=#{force_specific_single_run_view} show_form_flag=#{@show_form} show_custom_form_flag=#{@show_custom_form}")
          if params[:show_form].present? && params[:show_form].to_s == '1' && !prefer_runs_list && !force_specific_single_run_view
            if @show_form
              if request.xhr?
                # AJAX request - return just the form partial
                render partial: 'projects/views/std_form', layout: false
              else
                # Regular page request - render full page with just the form
                render 'projects/views/form_only', layout: 'application'
              end
            elsif @show_custom_form
              if request.xhr?
                # AJAX request - return custom step form partial
                custom_form_partial = "projects/views/#{@step.name}"
                if lookup_context.template_exists?(custom_form_partial, [], true)
                  render partial: custom_form_partial, layout: false
                else
                  render partial: 'projects/views/step_results', layout: false
                end
              else
                # Regular request fallback
                render partial: 'projects/views/step_results', layout: false
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
  end

  # GET /projects/:id/queue_position
  def queue_position
    slurm_job_id = params[:slurm_job_id]
    run_id = params[:run_id]
    
    queue_position = nil
    wait_time = nil
    slurm_queue_hover = nil
    slurm_blocker_message = nil
    show_slurm_queue = nil

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
        job_status = slurm_service.get_job_status(slurm_job_id, run)
        show_slurm_queue = slurm_service.show_slurm_queue_line?(slurm_job_id, job_status)
        Rails.logger.info("[queue_position] slurm_job_id=#{slurm_job_id}, job_status=#{job_status.inspect}, show_slurm_queue=#{show_slurm_queue}")

        if show_slurm_queue
          queue_position = slurm_service.get_job_queue_position(slurm_job_id, run_status_id, job_status: job_status, run: run)
          snap = slurm_service.pending_job_queue_snapshot(slurm_job_id)
          slurm_queue_hover = MarkerQueueText.hover_summary(snap, queue_position)
          slurm_blocker_message = MarkerQueueText.blocker_message(snap: snap)
        end
        Rails.logger.info("[queue_position] For SLURM job #{slurm_job_id}, run status_id: #{run_status_id}, queue_position: #{queue_position.inspect}, wait_time: #{wait_time.inspect}")
      rescue => e
        Rails.logger.warn("[queue_position] Error getting queue position: #{e.message}")
        Rails.logger.warn("[queue_position] Backtrace: #{e.backtrace.first(5).join("\n")}")
      end
    end

    Rails.logger.info("[queue_position] Returning: queue_position=#{queue_position.inspect}, wait_time=#{wait_time.inspect}, show_slurm_queue=#{show_slurm_queue.inspect}")
    render json: {
      queue_position: queue_position,
      wait_time: wait_time,
      slurm_queue_hover: slurm_queue_hover,
      slurm_blocker_message: slurm_blocker_message,
      show_slurm_queue: show_slurm_queue
    }
  end

  def refresh_steps_panel
    # Ensure project steps exist (safeguard for existing projects)
    @project.ensure_project_steps
    
    # Get runs for the project
    @runs ||= apply_publication_snapshot_to_runs(@project.runs.includes(:annots))
    
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
      status_name: Status.find_by(id: run.status_id)&.ui_label || 'Unknown',
      duration: run.duration ? run.duration.to_i : nil,
      start_time: run.start_time ? run.start_time.iso8601 : nil,
      submitted_at: run.submitted_at ? run.submitted_at.iso8601 : nil,
      waiting_duration: run.waiting_duration ? run.waiting_duration.to_i : nil,
      nber_clusters: run.clustering_nber_clusters
    }
  end

  # GET /projects/:id/run_counts
  # Returns run counts by status for header updates
  def run_counts
    unless readable?(@project)
      render json: { error: 'Not authorized' }, status: :forbidden
      return
    end

    visible_step_ids = Step.where.not(hidden: true).pluck(:id)
    totals =
      if @project.publication_lock_active? && publication_snapshot_reader?(@project)
        tallies = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
        @project.runs
                .where(step_id: visible_step_ids)
                .where('runs.created_at < ?', @project.public_at)
                .group(:status_id)
                .count
                .each do |status_id, n|
          k = status_id.to_i
          tallies[k] = n if tallies.key?(k)
        end
        tallies
      else
        out = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
        json_data = @project.nber_runs_json.is_a?(String) ? JSON.parse(@project.nber_runs_json) : @project.nber_runs_json
        json_data ||= {}
        json_data.each do |status_id, count|
          status_key = status_id.to_i
          out[status_key] = count.to_i if out.key?(status_key)
        end
        out
      end

    # Map to canonical keys used by header and step selectors.
    counts = {
      pending: totals[1],
      running: totals[2],
      success: totals[3],
      failed: totals[4],
      cell_count: @project.cell_count,
      col_label: helpers.col_label(@project)
    }

    render json: counts
  end

  # GET /projects/search_snapshot
  # Fingerprint of the current search-results page: total count, result IDs, and
  # display fields for the current page. The search page flashes a refresh
  # control when the result set changes, and patches row values in place when
  # only already-displayed projects changed.
  def search_snapshot
    query, filters = project_search_query_and_filters
    filters[:skip_aggregations] = true
    search_results = Project.search(query, filters)
    hits = search_results.response['hits']
    ids = Array(hits['hits']).map { |hit| hit['_id'].to_i }

    projects_by_id = {}
    if ids.any?
      Project.where(id: ids).includes(:project_type, :organism, :annots, :archive_status, :user).find_each do |project|
        projects_by_id[project.id] = project
      end
    end

    render json: {
      total_count: hits['total']['value'].to_i,
      ids: ids,
      projects: ids.filter_map { |id|
        project = projects_by_id[id]
        next unless project
        search_snapshot_project_payload(project)
      }
    }
  end

  # GET /projects/run_counts_batch?ids=1,2,3
  # Returns run counts for multiple projects (search page adaptive polling).
  # Unauthorized or missing IDs are omitted. Caps at 50 IDs.
  def run_counts_batch
    raw_ids = params[:ids]
    id_list =
      if raw_ids.is_a?(Array)
        raw_ids
      else
        raw_ids.to_s.split(',')
      end
    project_ids = id_list.map { |id| id.to_i }.select(&:positive?).uniq.first(50)

    result = {}
    if project_ids.any?
      Project.where(id: project_ids).find_each do |project|
        next unless readable?(project)
        counts = helpers.project_run_counts(project)
        result[project.id.to_s] = {
          pending: counts[:pending],
          running: counts[:running],
          success: counts[:success],
          failed: counts[:failed]
        }
      end
    end

    render json: result
  end

  # GET /projects/:id/run_list?status=failed
  # Returns the refreshed HTML for a run-status dropdown popup. Called by
  # nav_dropdown_controller when the user opens the popup so the list always
  # reflects the latest runs rather than the snapshot rendered at page load.
  def run_list
    status_key = params[:status].to_s.to_sym
    allowed_keys = %i[pending running success failed]
    unless allowed_keys.include?(status_key)
      render plain: '', status: :bad_request
      return
    end

    visible_ids = Step.where.not(hidden: true).pluck(:id)
    h_status_ids = Status.where(name: %w[pending running success failed stopped]).pluck(:name, :id).to_h.symbolize_keys
    status_id_scopes = {
      pending: [h_status_ids[:pending]].compact,
      running: [h_status_ids[:running]].compact,
      success: [h_status_ids[:success]].compact,
      failed:  [h_status_ids[:failed], h_status_ids[:stopped]].compact
    }

    scope_ids = status_id_scopes[status_key]
    run_list =
      if scope_ids.any?
        scope = @project.runs.includes(:step, :std_method).where(status_id: scope_ids, step_id: visible_ids)
        scope = scope.where('runs.created_at < ?', @project.public_at) if publication_snapshot_reader?(@project)
        scope.order(created_at: :desc)
      else
        []
      end

    count = run_list.respond_to?(:count) ? run_list.count : run_list.size

    # Pre-load dataset parameter display data
    header_annot_ids = []
    header_run_ids   = []
    run_list.limit(20).each do |run|
      next unless run.attrs_json.present?
      h_attrs = Basic.safe_parse_json(run.attrs_json, {})
      h_attrs.each_value do |v|
        if v.is_a?(Hash)
          header_annot_ids << v['annot_id'] if v['annot_id']
          header_run_ids   << v['run_id']   if v['run_id']
        elsif v.is_a?(Array)
          v.each do |item|
            next unless item.is_a?(Hash)
            header_annot_ids << item['annot_id'] if item['annot_id']
            header_run_ids   << item['run_id']   if item['run_id']
          end
        end
      end
    end

    header_h_annots   = {}
    header_h_ori_runs = {}
    header_h_steps    = {}
    if header_annot_ids.any?
      Annot.light.where(id: header_annot_ids.uniq).each do |a|
        header_h_annots[a.id] = a
        header_run_ids << a.ori_run_id if a.ori_run_id
      end
    end
    if header_run_ids.any?
      Run.includes(:step).where(id: header_run_ids.uniq).each do |r|
        header_h_ori_runs[r.id] = r
        header_h_steps[r.step_id] = r.step if r.step
      end
    end

    header_h_statuses = Status.all.index_by(&:id)
    summary_label     = helpers.run_summary_tooltip_label(status_key)

    render partial: 'shared/run_status_dropdown_list',
           locals: {
             run_list:,
             count:,
             summary_label:,
             header_h_statuses:,
             header_h_annots:,
             header_h_ori_runs:,
             header_h_steps:
           }
  end

  # GET /projects/:id/unarchive_status
  # Lightweight polling endpoint used by the unarchive pending overlay as a
  # fallback when the ActionCable completion broadcast is missed (e.g. the
  # unarchive job finished before the browser subscribed, or the WebSocket
  # never connected).
  def unarchive_status
    render json: {
      project_id: @project.id,
      unarchive_status: @project.unarchive_client_state
    }
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
      
      # Single-run steps can be reset when complete, failed, queued, or running.
      restartable_statuses = [1, 2, 3, 4, 6]
      unless @project_step && !@step.multiple_runs && restartable_statuses.include?(@project_step.status_id)
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

      locked_single_run_steps = steps_to_reset.select do |step|
        next false if step.multiple_runs

        @project.runs.where(step_id: step.id).any? { |run| @project.locked_from_publication?(run) }
      end
      if locked_single_run_steps.any?
        labels = locked_single_run_steps.map { |s| s.label.presence || s.name.humanize }.join(', ')
        redirect_to project_path(@project, view: 'analysis', step_id: step_id),
                    alert: "Cannot reset: #{labels} include analyses in the public snapshot."
        return
      end
      
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
            if @project.locked_from_publication?(run)
              Rails.logger.info("[restart_step] Skipping run #{run.id} (created before publication)")
              next
            end

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
              RunsController.instance_variable_set(:@log, nil)
              RunsController.instance_variable_set(:@h_step_ids, nil)
              raise
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
            
            # sel_name is archive/H5AD/RDS selection only; RAW_TEXT group labels must not
            # be passed as Java -sel (that treats the matrix as COMPRESSED/ARCHIVED).
            file_type = h_attrs['file_type'].to_s.upcase
            if h_attrs['sel_name'].present? && file_type != 'RAW_TEXT'
              options[:sel] = h_attrs['sel_name']
            end
            
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
        if params[:return_to_form].to_s == '1'
          redirect_to project_path(@project, view: 'analysis', step_id: @step.id, show_form: 1), notice: 'Step reset successfully.'
        else
          # Redirect without step_id - websockets will handle the UI updates
          redirect_to project_path(@project, view: 'analysis'), notice: 'Step restarted successfully. All subsequent steps have been reset.'
        end
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

      immutable_runs = runs.select { |run| immutable_since_publication?(run) }
      runs = runs.reject { |run| immutable_since_publication?(run) }
      
      if runs.empty?
        message = immutable_runs.any? ? 'Selected runs were created before publication and cannot be deleted.' : 'No runs to delete.'
        redirect_to step_results_project_path(@project, step_id: step_id), notice: message
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
          RunsController.instance_variable_set(:@log, nil)
          RunsController.instance_variable_set(:@h_step_ids, nil)
          raise
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
      locked_count = immutable_runs.count
      if params[:run_ids].present? && params[:run_ids].is_a?(Array)
        success_message = "#{deleted_count} run(s) deleted successfully."
      else
        success_message = "All runs deleted successfully."
      end
      if locked_count > 0
        success_message += " #{locked_count} run(s) were kept because they were created before publication."
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

  # POST /projects/:id/stop_parsing
  def stop_parsing
    parsing_step = parsing_step_for_project(@project)
    if parsing_step.nil?
      redirect_to project_path(@project, view: 'analysis'), alert: 'Parsing step not found.'
      return
    end

    parsing_run = @project.runs.where(step_id: parsing_step.id, status_id: [1, 2]).order(id: :desc).first
    if parsing_run.nil?
      redirect_to project_path(@project, view: 'analysis', step_id: parsing_step.id), alert: 'No running parsing job found.'
      return
    end

    begin
      if parsing_run.slurm_job_id.present?
        begin
          slurm_service = SlurmService.new(logger: Rails.logger)
          slurm_service.cancel_job(parsing_run.slurm_job_id)
        rescue => e
          Rails.logger.error("[stop_parsing] Error cancelling SLURM job for run #{parsing_run.id}: #{e.message}")
        end
      end

      begin
        Basic.kill_run(parsing_run)
      rescue => e
        Rails.logger.error("[stop_parsing] Error killing run container for run #{parsing_run.id}: #{e.message}")
      end

      if parsing_run.pid.present?
        begin
          Process.kill('TERM', parsing_run.pid.to_i)
        rescue Errno::ESRCH, Errno::EPERM
          # Process already gone or not permitted; status update still proceeds.
        end
      end

      h_upd = {
        status_id: 4,
        error: 'Stopped by user',
        duration: parsing_run.start_time ? (Time.now - parsing_run.start_time).to_f : parsing_run.duration
      }
      parsing_run.update(h_upd)

      project_step = ProjectStep.find_by(project_id: @project.id, step_id: parsing_step.id)
      project_step.update(status_id: 4, error_message: 'Stopped by user') if project_step
      Basic.upd_project_step(@project, parsing_step.id)
      @project.update(status_id: 4)
      @project.broadcast(parsing_step.id) if @project.respond_to?(:broadcast)

      redirect_to project_path(@project, view: 'analysis', step_id: parsing_step.id), notice: 'Parsing has been stopped and marked as failed.'
    rescue => e
      Rails.logger.error("[stop_parsing] Error stopping parsing for project #{@project.id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n")) if e.backtrace
      redirect_to project_path(@project, view: 'analysis', step_id: parsing_step.id), alert: "Error stopping parsing: #{e.message}"
    end
  end

  # GET /projects/:id/reset_parsing
  def reset_parsing
    @original_project = Project.find_by(id: params[:id]) || Project.find_by!(key: params[:id])

    parsing_step = parsing_step_for_project(@original_project)
    if parsing_step && !parsing_step.multiple_runs
      parsing_run = @original_project.runs.where(step_id: parsing_step.id).order(created_at: :desc).first
      if parsing_run && @original_project.locked_from_publication?(parsing_run)
        redirect_to project_path(@original_project, view: 'analysis', step_id: parsing_step.id),
                    alert: helpers.publication_locked_step_message
        return
      end
    end
    
    # Check if this is an integration project (no file upload, source projects instead)
    h_attrs = Basic.safe_parse_json(@original_project.parsing_attrs_json, {})
    if Basic.integration_project?(h_attrs)
      source_keys = Basic.integration_source_keys(h_attrs)
      session[:integrate_project_keys] = source_keys
      Rails.logger.info("[reset_parsing] Integration project detected, redirecting to new project integrate form source_keys=#{source_keys.inspect}")
      # Pass source_keys in URL params so the new action does not depend solely
      # on the session cookie surviving the redirect (Turbo Drive + fetch can
      # occasionally lose the Set-Cookie from the intermediate 302 response).
      redirect_to new_project_path(integrate: 1, source_keys: source_keys.join(','))
      return
    end

    # Find the Fu (file upload) associated with this project
    fu = Fu.resolve_for_project(@original_project)
    
    unless fu
      Rails.logger.warn("[reset_parsing] Fu not found for project id=#{@original_project.id} key=#{@original_project.key}; redirecting back to analysis")
      redirect_to reset_parsing_failure_path(@original_project, parsing_step, 'File upload record not found. Cannot reset parsing.')
      return
    end
    
    # Restore fus/<fu_id>/input_file.<ext> from the canonical project copy, then rerun preparsing.
    # Cloned projects may share fu_id with the source; always use this project's fus path.
    upload_dir = fu.upload_dir_for_project(@original_project)
    upload_file_path = upload_dir + fu.upload_file_name

    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = @original_project.data_dir
    input_filename_candidates = [
      @original_project.input_filename,
      fu.upload_file_name,
      'input_file.tar.gz',
      'input_file.tgz',
      'input_file.zip',
      'input_file'
    ].compact.map(&:to_s).uniq
    canonical_project_input_filename = input_filename_candidates.find do |candidate|
      File.exist?(project_dir + candidate)
    end
    canonical_project_input_file_path = canonical_project_input_filename ? (project_dir + canonical_project_input_filename) : nil
    Rails.logger.info("[reset_parsing] Using fu id=#{fu.id} upload_dir=#{upload_dir} upload_file_path=#{upload_file_path} input_filename_candidates=#{input_filename_candidates.inspect} selected_input_filename=#{canonical_project_input_filename.inspect} selected_input_file_path=#{canonical_project_input_file_path}")

    unless canonical_project_input_file_path && File.exist?(canonical_project_input_file_path)
      checked_paths = input_filename_candidates.map { |candidate| (project_dir + candidate).to_s }
      fu_expected_path = upload_file_path.to_s
      Rails.logger.warn("[reset_parsing] Could not resolve project input file. checked_paths=#{checked_paths.inspect} fu_expected_path=#{fu_expected_path} project_dir_exists=#{File.exist?(project_dir)} upload_dir_exists=#{File.exist?(upload_dir)}")
      redirect_to reset_parsing_failure_path(
        @original_project,
        parsing_step,
        'Project input file copy not found (expected archived upload is missing). Please re-upload the file before resetting parsing.'
      )
      return
    end

    if @original_project.input_filename != canonical_project_input_filename
      @original_project.update_column(:input_filename, canonical_project_input_filename)
    end

    source_path = canonical_project_input_file_path.to_s
    bundle_reset = begin
      File.directory?(File.realpath(source_path))
    rescue StandardError
      false
    end

    preparsing_in_progress = fu.status == 'preparsing'
    restored_file_size = nil

    unless preparsing_in_progress
    if bundle_reset
      # For MTX bundle projects (pre-extracted triplet under fus/<fu_id>/input_file/),
      # upload_dir must retain BOTH the real uploaded archive (upload_file_path) and
      # the pre-extracted bundle. Previous logic removed the whole upload_dir and then
      # wrote matrix.mtx on top of upload_file_path, which destroyed the original
      # tar.gz and left a plain MatrixMarket file under a *.tar.gz name. The next
      # preparsing then classified that as a bare MTX and never re-created the
      # bundle, and parsing later failed with "This file type 'MTX' does not exist."
      # The bundle and original archive are already on disk from the initial
      # project creation, so the reset only needs to clear preparsing artifacts
      # and rerun preparsing on the untouched archive.

      matrix_in_bundle = upload_dir + "input_file" + "matrix.mtx"
      unless matrix_in_bundle.file?
        mtx_one = Dir[(upload_dir + "input_file" + "*.mtx").to_s].find { |p| File.file?(p) }
        matrix_in_bundle = Pathname.new(mtx_one) if mtx_one.present?
      end
      unless matrix_in_bundle.file?
        Rails.logger.warn("[reset_parsing] MTX bundle reset: no matrix file under #{upload_dir + 'input_file'}")
        redirect_to reset_parsing_failure_path(@original_project, parsing_step, 'Project MTX bundle is missing matrix.mtx. Please re-upload the file before resetting parsing.')
        return
      end

      unless File.exist?(upload_file_path)
        Rails.logger.warn("[reset_parsing] MTX bundle reset: original upload missing at #{upload_file_path}")
        redirect_to reset_parsing_failure_path(@original_project, parsing_step, 'Original upload file is missing from the project. Please re-upload before resetting parsing.')
        return
      end

      %w[output.json output.err].each do |name|
        FileUtils.rm_f((upload_dir + name).to_s)
      end

      restored_file_size = File.size(upload_file_path)
      Rails.logger.info("[reset_parsing] MTX bundle reset: kept bundle at #{upload_dir + 'input_file'} and original upload at #{upload_file_path}")
    elsif !version_v8_or_later?(@original_project.version_id) && File.exist?(upload_file_path)
      # v<8: the fus/ directory holds the original upload and is the ground truth.
      # The legacy parsing pipeline modifies files in-place at the project root,
      # so copying from project root back to fus/ would propagate corruption.
      # Instead, keep fus/ intact and only clear preparsing artifacts.
      %w[output.json output.err].each do |name|
        FileUtils.rm_f((upload_dir + name).to_s)
      end
      restored_file_size = File.size(upload_file_path)
      Rails.logger.info("[reset_parsing] v<8 reset: kept original upload at #{upload_file_path} (#{restored_file_size} bytes)")
    else
      source_realpath = begin
        File.realpath(source_path)
      rescue StandardError
        source_path
      end
      upload_dir_realpath = File.expand_path(upload_dir.to_s)
      source_inside_upload_dir = source_realpath == upload_dir_realpath || source_realpath.start_with?(upload_dir_realpath + "/")

      staged_source_path = nil
      if source_inside_upload_dir
        staged_source_path = upload_dir.parent + ".reset_staging_#{fu.id}_#{SecureRandom.hex(6)}"
        FileUtils.cp(source_path, staged_source_path.to_s)
        source_path = staged_source_path.to_s
      end

      # Do not rm_rf upload_dir: in-flight preparsing runs docker exec with this
      # directory as --workdir; deleting it causes getcwd() failures and R errors.
      FileUtils.mkdir_p(upload_dir)
      %w[output.json output.err].each do |name|
        FileUtils.rm_f((upload_dir + name).to_s)
      end
      input_file_subdir = upload_dir + 'input_file'
      FileUtils.rm_rf(input_file_subdir) if File.directory?(input_file_subdir)
      FileUtils.cp(source_path, upload_file_path.to_s)
      FileUtils.rm_f(staged_source_path.to_s) if staged_source_path
      restored_file_size = File.size(upload_file_path)
      Rails.logger.info("[reset_parsing] Restored upload file to #{upload_file_path} from #{source_path}")
    end

    # Extract parsing attributes before restarting preparsing so text-matrix
    # options (especially delimiter) are applied on the reset form too.
    h_attrs = {}
    if @original_project.parsing_attrs_json.present?
      h_attrs = Basic.safe_parse_json(@original_project.parsing_attrs_json, {})
    end

    preparsing_options = {
      organism_id: @original_project.organism_id,
      version_id: @original_project.version_id,
      project_id: @original_project.id
    }
    # sel_name is only an archive/H5AD/RDS selection. For RAW_TEXT it is often just
    # the preparsing group label (filename) and must not be passed as Java -sel.
    file_type = h_attrs['file_type'].to_s.upcase
    if h_attrs['sel_name'].present? && file_type != 'RAW_TEXT'
      preparsing_options[:sel] = h_attrs['sel_name']
    end
    # Delimiter may be empty (tab); include whenever previously stored.
    preparsing_options[:delimiter] = h_attrs['delimiter'] if h_attrs.key?('delimiter')
    preparsing_options[:gene_name_col] = h_attrs['gene_name_col'] if h_attrs['gene_name_col'].present?
    preparsing_options[:has_header] = h_attrs['has_header'] if h_attrs.key?('has_header')
    preparsing_options = preparsing_options.compact

    fu.update!(
      upload_file_size: restored_file_size,
      status: 'preparsing'
    )
    FuPreparsingJob.perform_later(fu.id, preparsing_options)
    Rails.logger.info("[reset_parsing] Restarted preparsing for Fu##{fu.id} with options #{preparsing_options.inspect}")
    else
      restored_file_size = if File.exist?(upload_file_path)
                             File.size(upload_file_path)
                           else
                             fu.upload_file_size.to_i
                           end
      Rails.logger.info("[reset_parsing] Fu##{fu.id} preparsing in progress; skipping file restore and re-enqueue")
    end

    # Set up session with file upload info
    session[:file_upload] = {
      fu_id: fu.id,
      original_filename: fu.name || fu.upload_file_name,
      input_filename: fu.upload_file_name,
      path: upload_file_path.to_s,
      size: restored_file_size,
      total_size: restored_file_size,
      complete: true,
      organism_id: @original_project.organism_id,
      version_id: @original_project.version_id
    }
    
    # Use the existing project instead of creating a new one
    # This ensures we keep the same project ID
    @project = @original_project
    
    # Store flag in session to indicate we're resetting parsing
    session[:resetting_parsing] = true
    session[:resetting_parsing_project_id] = @original_project.id
    
    # Set up form data
    @project_types = selectable_project_types
    @versions = available_versions
    @file_formats = FileFormat.ordered
    @organisms = fetch_organisms_for_version(@project.version_id || @versions.first&.id)
    @grouped_organisms = group_organisms(@organisms, version_id: @project.version_id || @versions.first&.id)
    
    # Store parsing attributes in instance variable for form pre-filling
    @parsing_attrs = h_attrs
    
    # Store fu_id for the form to detect existing upload
    @existing_fu_id = fu.id
    @existing_filename = fu.name || fu.upload_file_name
    
    # Flag to indicate we're resetting parsing (for button text)
    @is_resetting_parsing = true
    
    # Render the new project form
    Rails.logger.info("[reset_parsing] Rendering new project form for project id=#{@project.id} key=#{@project.key} existing_fu_id=#{@existing_fu_id.inspect}")
    render :new
  end

  def reset_parsing_failure_path(project, parsing_step, message)
    flash[:alert] = message
    if parsing_step
      project_path(project, view: 'analysis', step_id: parsing_step.id)
    else
      project_path(project, view: 'analysis')
    end
  end
  private :reset_parsing_failure_path

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
    parsing_step = parsing_step_for_project(@project)
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
      status_info[:redirect_url] = creation_complete_redirect_url(@project)
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
    inject_pipeline_gene_set_collection_options!(@h_attrs) if %w[module_score ge].include?(@step.name)
    inject_heatmap_gene_set_collection_options!(@h_attrs) if @step.name == 'heatmap'
    
    # Get attribute layout from std_method
    @attr_layout = Basic.safe_parse_json(@std_method.attr_layout_json, [])
    ensure_de_second_metadata_attrs_and_layout!(@step, @h_attrs, @attr_layout)
    
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

    # Layout is authoritative when provided:
    # only attributes explicitly listed in attr_layout_json are rendered.
    
    # Get available runs for input selection
    @h_runs = {}
    successful_runs = Run.where(project_id: @project.id, status_id: 3) # status_id 3 = success

    # Apply analysis loom-file context to input candidates
    @selected_loom_file = nil
    begin
      all_annots_for_loom = load_loom_file_list_context
      if @available_loom_files.present?
        assign_analysis_loom_file_from_session!

        if @selected_loom_file && all_annots_for_loom
          loom_run_ids = all_annots_for_loom.select { |a| a.filepath == @selected_loom_file }.map(&:run_id).compact.uniq
          successful_runs = successful_runs.where(id: loom_run_ids) if loom_run_ids.any?
        end
      end
    rescue => e
      Rails.logger.error("[get_attributes] Error applying loom file context: #{e.class} - #{e.message}")
    end

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
        annots = Annot.light.where(run_id: run.id, data_type_id: 3).all
        annots.each { |a| @h_annots[a.id] = a }
      end
      
      render partial: 'projects/views/attributes', layout: false
  rescue StandardError => e
    Rails.logger.error("[get_attributes] Error: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    render plain: "<div class='p-4 text-center text-red-600'>Error loading attributes: #{e.message}</div>", status: :internal_server_error
  end

  def ensure_de_second_metadata_attrs_and_layout!(step, h_attrs, attr_layout)
    return unless step&.name.to_s == 'de'
    return unless h_attrs.is_a?(Hash) && attr_layout.is_a?(Array)
    return unless h_attrs['groups'].is_a?(Hash)

    toggle_attr_name = if h_attrs.key?('group_comp_from_other_metadata')
                        'group_comp_from_other_metadata'
                      elsif h_attrs.key?('second_group_from_other_metadata')
                        'second_group_from_other_metadata'
                      else
                        'group_comp_from_other_metadata'
                      end

    unless h_attrs[toggle_attr_name].is_a?(Hash)
      h_attrs[toggle_attr_name] = {
        'label' => 'Use another metadata for compared group',
        'widget' => 'checkbox',
        'default' => false
      }
    end

    unless h_attrs['groups2'].is_a?(Hash)
      groups2_attr = Basic.safe_parse_json(h_attrs['groups'].to_json, {})
      groups2_attr['label'] = 'Compared group metadata'
      groups2_attr['default'] = nil
      h_attrs['groups2'] = groups2_attr
    end

    attr_layout.each do |vertical|
      next unless vertical.is_a?(Hash) && vertical['horiz_elements'].is_a?(Array)
      vertical['horiz_elements'].each do |horiz|
        next unless horiz.is_a?(Hash) && horiz['attr_list'].is_a?(Array)
        attrs = horiz['attr_list']
        next unless attrs.include?('groups')

        attrs.delete(toggle_attr_name)
        attrs.delete('groups2')

        insert_idx = attrs.index('group_comp') || attrs.length
        attrs.insert(insert_idx, toggle_attr_name)
        attrs.insert(insert_idx + 1, 'groups2')
      end
    end
  end

  # POST /projects/:id/upd_pred
  # Predicts RAM and duration from the largest selected input dataset (same idea as legacy ASAP).
  def upd_pred
    annot_ids = params[:annot_ids].to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i).uniq
    std_method = StdMethod.find_by(id: params[:std_method_id])

    h_vals = {
      '0' => '0s',
      'NA' => '?'
    }
    h_title = {
      'NA' => 'Not enough benchmarked data yet to make this prediction.'
    }

    empty_payload = {
      predicted_time: nil,
      predicted_ram: nil,
      time_display: '',
      ram_display: '',
      time_severity: 'none',
      ram_severity: 'none',
      prevent_submit: false,
      prevent_messages: []
    }

    unless std_method && annot_ids.any?
      render json: empty_payload
      return
    end

    annots = Annot.light.where(id: annot_ids).to_a
    unless annots.size == annot_ids.size
      render json: empty_payload.merge(error: 'Some annotations were not found.')
      return
    end

    biggest_annot = annots.max_by { |a| a.nber_cols.to_i * a.nber_rows.to_i }
    unless biggest_annot
      render json: empty_payload
      return
    end

    rows = biggest_annot.nber_rows.to_i
    cols = biggest_annot.nber_cols.to_i
    if rows <= 0 || cols <= 0
      render json: empty_payload.merge(
        error: 'Selected input has invalid dimensions for prediction.',
        time_title: 'Rows/columns must be positive.',
        ram_title: 'Rows/columns must be positive.'
      )
      return
    end

    version = @project.version
    asap_docker_image = Basic.get_asap_docker(version)
    unless asap_docker_image
      render json: empty_payload.merge(error: 'Docker image for this version is not configured.')
      return
    end

    asap_docker_name = "fabdavid/asap_run:#{asap_docker_image.tag}"
    vol = Basic.prediction_docker_volume_mount_arg
    models_base = Basic.prediction_models_path_for_r
    # Do not mount over /srv: prediction.tool.2.R ships in the asap_run image WORKDIR (/srv).
    cmd = "docker run --entrypoint '/bin/sh' --rm #{vol} #{asap_docker_name} -c 'Rscript prediction.tool.2.R predict #{models_base}/#{@project.version_id} #{std_method.id} #{rows} #{cols} 2>&1'"

    pred_text, process_status = Open3.capture2e(cmd)
    Rails.logger.info("[upd_pred] prediction exit=#{process_status&.exitstatus} bytes=#{pred_text.to_s.bytesize} cmd=#{cmd}")

    h_results = parse_prediction_script_output(pred_text)
    unless h_results.is_a?(Hash)
      snippet = pred_text.to_s.gsub(/\s+/, ' ').strip[0, 500]
      Rails.logger.warn("[upd_pred] No prediction JSON in output snippet=#{snippet.inspect}")
      render json: empty_payload.merge(
        prediction_parse_failed: true,
        error: 'Could not read prediction output from the server.',
        time_display: '',
        ram_display: '',
        time_title: 'The prediction script did not return JSON. Check Docker and PROD_DATA_DIR (pred_models under that root).',
        ram_title: ''
      )
      return
    end

    if h_results['displayed_error'].present?
      msg = h_results['displayed_error'].to_s
      Rails.logger.warn("[upd_pred] prediction.tool.2.R displayed_error=#{msg}")
      render json: empty_payload.merge(
        error: msg,
        prediction_script_error: true,
        time_display: '',
        ram_display: ''
      )
      return
    end

    raw_time = h_results.fetch('predicted_time', :missing)
    raw_ram = h_results.fetch('predicted_ram', :missing)

    time_na = prediction_r_reports_na?(raw_time)
    ram_na = prediction_r_reports_na?(raw_ram)

    time_sec = prediction_seconds(raw_time)
    ram_kb = prediction_ram_kb(raw_ram)

    pred_time_raw =
      if raw_time == :missing
        ''
      elsif time_na
        'NA'
      elsif time_sec.nil?
        raw_time.to_s.strip
      else
        time_sec.to_s
      end

    time_display =
      if raw_time == :missing
        ''
      elsif time_na
        h_vals['NA']
      elsif time_sec.nil?
        h_vals[pred_time_raw] || helpers.duration(pred_time_raw.to_i)
      elsif time_sec <= 0
        '0s'
      else
        helpers.duration(time_sec)
      end

    ram_display =
      if raw_ram == :missing
        ''
      elsif ram_na
        h_vals['NA']
      elsif ram_kb.nil?
        h_vals['NA']
      elsif ram_kb <= 0
        '0 B'
      else
        helpers.display_mem(ram_kb * 1024)
      end

    time_severity = 'none'
    if time_sec.is_a?(Integer) && time_sec.positive?
      if time_sec > 48 * 3600
        time_severity = 'danger'
      elsif time_sec > 24 * 3600
        time_severity = 'warning'
      end
    end

    ram_severity = 'none'
    if ram_kb.is_a?(Integer) && ram_kb.positive?
      if ram_kb > 100_000_000
        ram_severity = 'danger'
      elsif ram_kb > 50_000_000
        ram_severity = 'warning'
      end
    end

    prevent_messages = []
    if ram_kb.is_a?(Integer) && ram_kb > 100_000_000
      prevent_messages << 'Predicted RAM exceeds 100Gb for the biggest input dataset selected.'
    end
    if time_sec.is_a?(Integer) && time_sec > 48 * 3600
      prevent_messages << 'Predicted execution time exceeds 2 days for the biggest input dataset selected.'
    end

    na_title = h_title['NA'].to_s
    missing_title = 'This field was not present in the prediction script output.'

    render json: {
      predicted_time: time_na ? nil : (time_sec.is_a?(Integer) ? time_sec.to_s : nil),
      predicted_ram: ram_na ? nil : ram_kb,
      time_display: time_display,
      ram_display: ram_display,
      time_severity: time_severity,
      ram_severity: ram_severity,
      time_title: time_na ? na_title : (raw_time == :missing ? missing_title : ''),
      ram_title: ram_na ? na_title : (raw_ram == :missing ? missing_title : ''),
      prevent_submit: prevent_messages.any?,
      prevent_messages: prevent_messages
    }
  rescue StandardError => e
    Rails.logger.error("[upd_pred] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    render json: { error: e.message }, status: :internal_server_error
  end

  private
    def search_snapshot_ontology_by_tag
      @search_snapshot_ontology_by_tag ||= AsapData::OntologyIdentifierUrl.ontology_by_tag_index
    end

    def search_snapshot_term_payload(entries, color)
      terms = Array(entries)
      {
        labels: terms.map { |entry| entry[:label] },
        terms: terms,
        color: color
      }
    end

    def search_snapshot_project_payload(project)
      project_type = project.project_type
      run_counts = helpers.project_run_counts(project)
      payload = {
        id: project.id,
        display_name: project.display_name,
        key: project.key,
        public_id: project.public_id,
        version_id: project.version_id,
        archive_status_icon: project.archive_status_icon_class_for_display,
        archive_status_label: project.archive_status_label_for_display,
        project_type_tag: project_type&.tag,
        project_type_name: project_type&.name,
        organism: {
          labels: project.organism&.name.present? ? [project.organism.name] : [],
          color: helpers.ontology_term_type_color('organism')
        },
        technology: search_snapshot_term_payload(
          project.compliance_term_entries_for(
            'technology',
            ontology_by_tag: search_snapshot_ontology_by_tag
          ),
          helpers.ontology_term_type_color('technology')
        ),
        cell_count: helpers.number_with_delimiter(project.cell_count),
        col_label: helpers.col_label(project),
        gene_count: helpers.number_with_delimiter(project.gene_count),
        row_label: helpers.row_label(project),
        updated_at: project.updated_at&.strftime("%b %d, %Y"),
        run_counts: {
          pending: run_counts[:pending],
          running: run_counts[:running],
          success: run_counts[:success],
          failed: run_counts[:failed]
        }
      }
      payload[:user_email] = project.user&.email.presence if admin?
      payload
    end

    def project_search_query_and_filters
      query = params[:q]
      visibility = params[:visibility].presence || (
        if params[:public_only].present?
          params[:public_only] == 'true' ? 'public' : 'private'
        else
          'all'
        end
      )

      filters = {
        organism_id: params[:organism_id],
        project_type_id: params[:project_type_id],
        tissue: params[:tissue],
        status_id: params[:status_id],
        visibility: visibility,
        sort: params[:sort] || 'updated_at',
        page: params[:page] || 1,
        current_user_id: current_user&.id,
        is_admin: admin?
      }

      [query, filters]
    end

    def creation_complete_redirect_url(project)
      project_path(project, view: 'analysis')
    end

    def adopt_upload_fu_for_new_project(fu_id)
      return if fu_id.blank?

      fu = find_upload_fu_for_new_project(fu_id)
      path = fu&.file_path&.to_s
      return unless path.present? && File.exist?(path)

      fu.adopt_as_project_input!

      size = File.size(path)
      session[:file_upload] = {
        fu_id: fu.id,
        original_filename: fu.name.presence || fu.upload_file_name,
        input_filename: fu.upload_file_name,
        path: path,
        size: size,
        total_size: fu.upload_file_size.presence || size,
        complete: true
      }
      @existing_fu_id = fu.id
      @existing_filename = fu.name.presence || fu.upload_file_name
    end

    def resolve_project_origin_name_for_new(from_param, fu_id, integrate: false)
      return ProjectOrigin::INTEGRATION if integrate

      from_name = from_param.to_s.strip
      return from_name if ProjectOrigin::NAMES.include?(from_name)

      if fu_id.present?
        fu = find_upload_fu_for_new_project(fu_id)
        if fu && UploadType.name_for(fu.upload_type) == 'compliance_file_check'
          return ProjectOrigin::SCFAIR_VALIDATION
        end
      end

      ProjectOrigin::UPLOAD
    end

    def assign_project_origin_on_create!(project)
      name =
        if params[:integrate].to_s == '1'
          ProjectOrigin::INTEGRATION
        else
          requested = params[:project_origin].to_s.strip
          ProjectOrigin::NAMES.include?(requested) ? requested : ProjectOrigin::UPLOAD
        end
      origin_id = ProjectOrigin.id_for(name)
      project.project_origin_id = origin_id if origin_id.present?
    end

    def enforce_locked_project_type_on_create!(project)
      return unless project.from_scfair_validation? || params[:integrate].to_s == '1'

      sc_type = single_cell_transcriptomics_project_type
      return unless sc_type

      project.project_type_id = sc_type.id
    end

    def selectable_project_types
      ProjectType.selectable_for(include_restricted: admin_report?)
    end

    def unauthorized_restricted_project_type?(project)
      ptype = ProjectType.find_by(id: project.project_type_id)
      return false if ptype.nil?

      ptype.admin_report_only? && !admin_report?
    end

    def single_cell_transcriptomics_project_type
      types = @project_types || ProjectType.order(:name)
      types.find { |pt| pt.tag.to_s == 'sc' } ||
        types.find { |pt| pt.name.to_s.downcase.include?('single') }
    end

    def find_upload_fu_for_new_project(fu_id)
      if user_signed_in?
        uid = current_user.id
        fu_t = Fu.arel_table
        projects_t = Project.arel_table
        scope = Fu.left_joins(:project).where(id: fu_id).where(
          fu_t[:user_id].eq(uid).or(projects_t[:user_id].eq(uid))
        )
        return Fu.find_by(id: fu_id) if scope.exists?
      elsif session[:sandbox].present?
        return Fu.find_by(id: fu_id, user_id: nil, project_key: session[:sandbox])
      end

      nil
    end

    def render_module_score_request(request)
      case request.status
      when 'pending', 'running'
        render json: { status: request.status, request_id: request.request_id }
      when 'canceled'
        render json: { status: 'canceled', request_id: request.request_id }
      when 'failed'
        render json: { status: 'error', message: request.error_message.presence || 'ModuleScore execution failed' }, status: :unprocessable_entity
      when 'completed'
        scores = request.read_scores
        render json: { status: 'ok', scores: scores, dataset: request.dataset }
      else
        raise ArgumentError, "Unknown module score status #{request.status}"
      end
    end

    def module_score_run_cache_key(request_id)
      "module_score_run:#{request_id}"
    end

    def module_score_cancel_cache_key(request_id)
      "module_score_cancel:#{request_id}"
    end

    def terminate_module_score_process(pid)
      normalized_pid = pid.to_i
      return if normalized_pid <= 0

      begin
        Process.kill('TERM', normalized_pid)
      rescue Errno::ESRCH
        return
      rescue StandardError
        # Keep cancellation best effort.
      end

      10.times do
        sleep 0.1
        begin
          Process.getpgid(normalized_pid)
        rescue Errno::ESRCH
          return
        rescue StandardError
          break
        end
      end

      begin
        Process.kill('KILL', normalized_pid)
      rescue Errno::ESRCH
        nil
      rescue StandardError
        nil
      end
    end

    def import_validation_json(validation)
      if validation[:skip_name_checks]
        return { skip_name_checks: true }
      end

      {
        skip_name_checks: false,
        error: validation[:error],
        dependents: validation[:dependents],
        checks: validation[:checks].map do |c|
          {
            path: c.path,
            authorized: c.authorized,
            auth_message: c.auth_message,
            collision: c.collision,
            dependent_run_count: Array(c.dependent_run_ids).size,
            dependents: c.dependents
          }
        end
      }
    end

    def search_gene_resolve_remote_gene(db_version)
      org_id = @project.organism_id
      gid_str = params[:gene_id].to_s.strip
      ens, sym = normalize_search_gene_identity_params(
        ensembl_id: params[:ensembl_id],
        gene_symbol: params[:gene_symbol]
      )

      if gid_str.match?(/\A\d+\z/)
        gid = gid_str.to_i
        if gid.positive?
          row = RemoteGene.find_by_remote_id(gid, version: db_version)
          return row if row
        end
      end

      # Prefer Ensembl ID over symbol (IDs are unambiguous; symbols collide across organisms).
      if org_id.present?
        if ens.present?
          row = RemoteGene.find_by_organism_and_ensembl(org_id, ens, version: db_version)
          return row if row
        end
        if sym.present?
          row = RemoteGene.find_by_organism_and_symbol(org_id, sym, version: db_version)
          return row if row
          row = find_remote_gene_by_alias(org_id, sym, db_version)
          return row if row
        end
      end

      if ens.present?
        row = RemoteGene.find_by_ensembl_id_flexible(ens, version: db_version)
        return row if row
      end

      if sym.present?
        row = RemoteGene.find_by_gene_symbol(sym, version: db_version)
        return row if row
        return find_remote_gene_by_alias(nil, sym, db_version)
      end

      nil
    end

    def search_gene_step_ms
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
    end

    ENSEMBL_STABLE_ID_RE = /\b((?:ENS[A-Z]{0,4}G|MGP_[A-Za-z0-9]+_G)\d+)(?:\.\d+)?\b/i

    def normalize_search_gene_identity_params(ensembl_id:, gene_symbol:)
      ens = ensembl_id.to_s.strip
      sym = gene_symbol.to_s.strip

      extracted = []
      [ens, sym].each do |text|
        text.to_s.scan(ENSEMBL_STABLE_ID_RE) { |match| extracted << match[0] }
      end
      extracted = extracted.map { |value| value.to_s.sub(/\.\d+\z/, '') }.uniq

      if extracted.any?
        ens = extracted.first
      elsif ens.match?(/\A\[.*\]\z/) || (ens.include?(',') && !ens.match?(ENSEMBL_STABLE_ID_RE))
        # Corrupted clients sometimes send alt-name blobs as ensembl_id.
        ens = ''
      end

      if sym.match?(ENSEMBL_STABLE_ID_RE)
        sym = sym.gsub(ENSEMBL_STABLE_ID_RE, ' ')
                 .gsub(/\[.*?\]/, ' ')
                 .gsub(/\s+/, ' ')
                 .strip
      end

      [ens, sym]
    end

    def find_remote_gene_by_alias(organism_id, query, db_version)
      q = query.to_s.strip
      return nil if q.blank?

      RemoteGene.with_remote(db_version) do
        scope = RemoteGene.all
        scope = scope.where(organism_id: organism_id) if organism_id.present?
        # Exact token match inside CSV/text alias fields.
        quoted = RemoteGene.connection.quote(q.downcase)
        scope.where(
          "(',' || LOWER(COALESCE(alt_names, '')) || ',') LIKE '%,' || #{quoted} || ',%' OR " \
          "(',' || LOWER(COALESCE(obsolete_alt_names, '')) || ',') LIKE '%,' || #{quoted} || ',%'"
        ).order(:id).first
      end
    end

    # Returns { ensembl_release:, feature_name: } from loom-backed autocomplete / request
    # params. Does not read Ensembl gene.txt dumps.
    def search_gene_ensembl_release_feature(gene, _db_version)
      feature_name = params[:feature_name].to_s.strip.presence
      release = params[:ensembl_release].to_s.strip.presence

      if feature_name.blank?
        from_cache = search_gene_feature_name_from_autocomplete(gene)
        feature_name = from_cache[:feature_name]
        release ||= from_cache[:ensembl_release]
      end

      # No feature_name → omit the row (do not resolve release alone).
      return nil if feature_name.blank?

      if release.blank?
        meta = Scfair::ProjectEnsemblMetadataResolver.call(@project)
        release = meta&.dig(:ensembl_release)
      end

      release_i = release.to_i
      return nil unless release_i.positive?

      {
        ensembl_release: release_i,
        ensembl_assembly: nil,
        ensembl_database: nil,
        feature_name: feature_name,
        source: :loom
      }
    rescue StandardError => e
      Rails.logger.warn("[search_gene] release feature_name failed: #{e.class} - #{e.message}")
      nil
    end

    def search_gene_feature_name_from_autocomplete(gene)
      result = { feature_name: nil, ensembl_release: nil }
      loom_file = params[:loom_file].to_s.strip.presence
      return result if loom_file.blank?

      user_data_dir = ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s
      project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
      autocomplete_file = project_dir + File.dirname(loom_file) + 'autocomplete_genes.json'
      return result unless File.exist?(autocomplete_file)

      payload = JSON.parse(File.read(autocomplete_file))
      result[:ensembl_release] = payload['ensembl_release']
      feature_names = payload['feature_names']
      return result unless feature_names.is_a?(Hash) && feature_names.any?

      stable_id = params[:stable_id].to_s.strip
      if stable_id.present? && feature_names[stable_id].present?
        result[:feature_name] = feature_names[stable_id].to_s.strip.presence
        return result
      end

      # Fallback: match Accession in search lines, then look up by stable.
      ens = gene&.ensembl_id.to_s.strip
      if ens.present?
        Array(payload['search']).each do |line|
          parsed = parse_loom_autocomplete_gene_entry(line)
          next unless parsed
          next unless parsed[:ensembl_id].to_s.casecmp(ens).zero?

          result[:feature_name] = feature_names[parsed[:stable_id]].to_s.strip.presence
          break
        end
      end
      result
    rescue StandardError
      { feature_name: nil, ensembl_release: nil }
    end

    def build_gene_set_collection_memberships_for_gene(gene, db_version)
      memberships = []
      return memberships if db_version.blank?

      current_user_id = current_user&.id
      gene_id = gene&.respond_to?(:id) ? gene.id.to_i : 0
      return memberships unless gene_id.positive?

      cache_key = [
        'search_gene_memberships/v2',
        db_version.to_s,
        @project.id.to_s,
        @project.organism_id.to_s,
        current_user_id.to_s,
        gene_id.to_s
      ]
      Rails.cache.fetch(cache_key, expires_in: GENE_MEMBERSHIPS_CACHE_TTL) do
        build_gene_set_collection_memberships_for_gene_uncached(gene_id, db_version, current_user_id)
      end
    rescue StandardError => e
      Rails.logger.error("[search_gene] Failed to build gene set memberships: #{e.class} - #{e.message}")
      []
    end

    def build_gene_set_collection_memberships_for_gene_uncached(gene_id, db_version, current_user_id)
      memberships = []
      global_type_presentation = gene_set_collection_type_presentation(GENE_SET_COLLECTION_TYPE_GLOBAL)
      imported_type_presentation = gene_set_collection_type_presentation(GENE_SET_COLLECTION_TYPE_IMPORTED)

      RemoteGene.with_remote(db_version) do
        conn = RemoteGene.connection
        where_sql = [
          "(gs.project_id IS NULL AND gs.ref_id IS NOT NULL)",
          "gs.project_id = #{@project.id}"
        ]
        if current_user_id.present?
          where_sql << "(gs.project_id IS NULL AND gs.user_id = #{current_user_id.to_i} AND gs.ref_id IS NULL)"
        end

        # content is CSV of gene ids with no whitespace in asap_data (verified); avoid REGEXP_REPLACE.
        escaped_gene_id = conn.quote_string(gene_id.to_s)
        gene_match_sql = "(',' || COALESCE(gsi.content, '') || ',') LIKE '%,#{escaped_gene_id},%'"

        rows = conn.select_all(<<~SQL)
          SELECT
            gs.id AS collection_id,
            gs.label AS collection_label,
            gs.ref_id,
            gs.project_id,
            ds.label AS database_name,
            gsi.id AS item_id,
            gsi.identifier AS item_identifier,
            gsi.name AS item_name
          FROM gene_sets gs
          JOIN gene_set_items gsi ON gsi.gene_set_id = gs.id
          LEFT JOIN db_sets ds ON ds.id = gs.ref_id
          WHERE gs.organism_id = #{@project.organism_id.to_i}
            AND COALESCE(gs.obsolete, FALSE) = FALSE
            AND (#{where_sql.join(' OR ')})
            AND #{gene_match_sql}
          ORDER BY LOWER(COALESCE(gs.label, '')), LOWER(COALESCE(gsi.name, gsi.identifier, ''))
        SQL

        by_collection = {}
        rows.each do |row|
          collection_id = row['collection_id'].to_i
          next if collection_id <= 0

          entry = by_collection[collection_id]
          unless entry
            project_id = row['project_id']&.to_i
            ref_id = row['ref_id']&.to_i
            type_data = project_id.blank? && ref_id.present? ? global_type_presentation : imported_type_presentation
            entry = {
              id: collection_id,
              label: row['collection_label'].to_s,
              database_name: row['database_name'].to_s,
              match_count: 0,
              gene_sets: []
            }.merge(type_data)
            by_collection[collection_id] = entry
          end

          item_label = row['item_name'].to_s.strip
          item_identifier = row['item_identifier'].to_s.strip
          entry[:gene_sets] << {
            id: row['item_id'].to_i,
            label: item_label.presence || item_identifier,
            identifier: item_identifier
          }
        end

        by_collection.each_value do |entry|
          entry[:match_count] = entry[:gene_sets].length
          memberships << entry
        end
      end

      local_collections = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).order(created_at: :desc)
      local_collections.each do |collection|
        payload = load_local_gene_set_collection_payload(collection.file_key, collection.name)
        matched_sets = []

        Array(payload['items']).each do |raw_item|
          item = normalize_manual_gene_set_item(raw_item)
          next unless item

          genes = Array(item[:genes])
          hit = genes.any? do |g|
            gid = g[:gene_id].to_i
            gid.positive? && gid == gene_id
          end
          next unless hit

          matched_sets << {
            id: item[:id].to_s,
            label: item[:name].presence || item[:identifier].to_s,
            identifier: item[:identifier].to_s
          }
        end
        next if matched_sets.empty?

        memberships << {
          id: local_gene_set_collection_id(collection),
          label: collection.name.to_s,
          database_name: '',
          match_count: matched_sets.length,
          gene_sets: matched_sets
        }.merge(gene_set_collection_type_presentation(gene_set_collection_type_key(collection)))
      end

      memberships.sort_by { |entry| entry[:label].to_s.downcase }
    end

    def apply_publication_snapshot_to_runs(relation)
      return relation unless @project && publication_snapshot_reader?(@project)

      relation.where("#{Run.table_name}.created_at < ?", @project.public_at)
    end

    def apply_publication_snapshot_to_annots(relation)
      return relation unless @project && publication_snapshot_reader?(@project)

      relation.where("#{Annot.table_name}.created_at < ?", @project.public_at)
    end

    # Lines from prediction.tool.2.R may be prefixed by Docker/R noise; JSON may use floats.
    def parse_prediction_script_output(text)
      text.to_s.each_line do |line|
        line = line.strip
        next if line.empty?

        h = Basic.safe_parse_json(line, nil)
        if h.is_a?(Hash) && prediction_script_json_hash?(h)
          return h
        end

        i = line.index('{')
        next unless i

        h = Basic.safe_parse_json(line[i..], nil)
        if h.is_a?(Hash) && prediction_script_json_hash?(h)
          return h
        end
      end
      nil
    end

    def prediction_script_json_hash?(h)
      h.key?('predicted_ram') || h.key?('predicted_time') || h.key?('displayed_error')
    end

    # True when R/JSON explicitly reports NA (including JSON null), not when the key was absent (:missing).
    def prediction_r_reports_na?(val)
      return false if val == :missing

      return true if val.nil?

      s = val.is_a?(String) ? val.strip : val.to_s.strip
      return true if s.empty?

      up = s.upcase
      return true if up == 'NA' || up == 'NAN' || up == 'NULL'

      false
    end

    def prediction_seconds(val)
      return nil if val == :missing
      return nil if prediction_r_reports_na?(val)

      return val.to_f.round if val.is_a?(Numeric)

      s = val.to_s.strip
      return nil unless s.match?(/\A-?\d+(\.\d+)?([eE][+-]?\d+)?\z/)

      s.to_f.round
    end

    def prediction_ram_kb(val)
      return nil if val == :missing
      return nil if prediction_r_reports_na?(val)

      return val.to_f.to_i if val.is_a?(Numeric)

      s = val.to_s.strip
      return nil unless s.match?(/\A-?\d+(\.\d+)?([eE][+-]?\d+)?\z/)

      s.to_f.to_i
    end

    def clear_stale_sandbox_parsing_output!(project_dir)
      output_json = project_dir + 'parsing' + 'output.json'
      return unless output_json.file?

      FileUtils.rm_f(output_json.to_s)
      Rails.logger.info("[ProjectsController#create] Removed stale sandbox parsing output at #{output_json}")
    end

    def set_sandbox_self_destruct_at!
      @sandbox_self_destruct_at = nil
      return unless @project.sandbox? && !current_user

      sandbox_idle_days = ENV.fetch('SANDBOX_DELETE_IDLE_DAYS', '1').to_i
      last_seen_at = @project.viewed_at || @project.updated_at || @project.created_at || Time.current
      @sandbox_self_destruct_at = last_seen_at + sandbox_idle_days.days
    end

    def track_project_view!
      return if admin?
      return if request_user_agent_indicates_bot?
      return unless @session_cookie_in_request

      ProjectViewTracker.track!(
        project: @project,
        current_user: current_user,
        session_id: session.id,
        viewed_at: Time.current
      )
    end

    def queue_unarchive_if_project_files_missing
      @project_being_archived = false
      @project_being_unarchived = false
      @project_archive_transitioning = false
      @project_unarchive_state = nil
      @project_files_missing = false

      if @project.reconcile_archive_status_with_filesystem!
        @project.reload
      end

      return if @project.being_cloned

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
      project_archive_file = Pathname.new("#{project_dir}.tgz")
      @project_files_missing = @project.filesystem_project_data_missing?
      @project_being_archived = @project.being_archived?
      @project_being_unarchived = @project.being_unarchived?
      # Unarchive overlay only — never treat "archiving" (status 2) as unarchive-in-progress.
      @project_archive_transitioning = @project_being_unarchived
      @integration_in_progress = @project.integration_in_progress?

      if @integration_in_progress
        return
      end

      # Archiving projects keep local files until the archive job finishes; do not
      # queue unarchive and do not map this state onto the unarchive overlay.
      return if @project_being_archived

      return unless @project_files_missing
      return if skip_project_unarchive_for_crawler?
      return if metadata_only_view_request?

      if @project.archived_on_s3? && !@project.archive_restore_expected?
        @project.update_archive_metadata!(archive_status_id: 1)
        @project_files_missing = @project.filesystem_project_data_missing?
        return
      end

      if @project.queue_unarchive_if_needed!
        @project_unarchive_state = 'queued'
        flash.now[:notice] = "Project files are archived. Unarchive has been queued and data will appear once extraction is complete."
      elsif @project.being_unarchived?
        @project_unarchive_state = if File.exist?(project_archive_file) && File.size(project_archive_file).to_i.positive?
          'unpacking'
        else
          'in_progress'
        end
        flash.now[:notice] = "Project files are currently being unarchived. If this state is stale, it will be re-queued automatically."
      elsif @project.archived_on_s3?
        @project_unarchive_state = 'queue_failed'
        flash.now[:alert] = "Project is archived on S3 but could not be restored automatically. Verify S3 settings and try again."
      elsif @project.disk_size_archived.present?
        @project_unarchive_state = 'archived_missing'
        flash.now[:notice] = "Project files are stored in archive and are being prepared."
      end
    rescue StandardError => e
      Rails.logger.error("[projects#show] Failed to queue unarchive for project #{@project.id}: #{e.message}")
      @project_unarchive_state = 'queue_failed'
      flash.now[:alert] = "Project files are archived and unarchive queueing failed."
    ensure
      if @project_being_unarchived && @project_unarchive_state.blank?
        @project_unarchive_state = if !@project_files_missing ||
            (File.exist?(project_archive_file) && File.size(project_archive_file).to_i.positive?)
          'unpacking'
        else
          'in_progress'
        end
      end
    end

    def authorize_project_read_access
      allowed = readable?(@project)
      return if allowed

      handle_project_unauthorized_access
    end

    def authorize_project_edit_access
      allowed = editable?(@project)
      return if allowed

      handle_project_unauthorized_access
    end

    def authorize_project_analyze_access
      allowed = analyzable?(@project)
      return if allowed

      handle_project_unauthorized_access
    end

    def authorize_project_owner_access
      return if owner?(@project)

      handle_project_unauthorized_access
    end

    def handle_project_unauthorized_access
      respond_to do |format|
        format.html { redirect_to unauthorized_path }
        format.json { render json: { error: 'Not authorized' }, status: :forbidden }
        format.any { render plain: 'Not authorized', status: :forbidden }
      end
    end

    def authorize_requested_view_access!(view_type)
      if view_type == 'access'
        return true if admin?

        handle_project_unauthorized_access
        return false
      end

      if view_type == 'compliance'
        return true if editable?(@project)

        handle_project_unauthorized_access
        return false
      end

      return true unless view_type == 'settings'
      return true if editable?(@project) || analyzable?(@project) || exportable?(@project)

      handle_project_unauthorized_access
      false
    end

    def selective_project_view_loading_enabled?
      ENV.fetch('PROJECT_SELECTIVE_VIEW_LOADING', '1') != '0'
    end

    # Whether the current request targets a metadata-only project view (summary,
    # settings, admin access analytics). Used to skip the unarchive overlay/queue
    # when the user just wants to read database-backed information.
    # The +force_unarchive+ query param overrides this so the explicit Unarchive
    # button on the summary page can still kick off the unarchive flow.
    def metadata_only_view_request?
      return false if force_unarchive_requested?
      metadata_only_view_param?
    end

    def force_unarchive_requested?
      ActiveModel::Type::Boolean.new.cast(params[:force_unarchive])
    end

    def resolve_project_view_type(requested_view)
      view = requested_view.to_s
      allowed_views = %w[summary visualization heatmap analysis data settings compliance access annotations]
      return view if allowed_views.include?(view)

      #project_has_embeddings? ? 'visualization' : 'summary'
      "summary"
    end

    def project_has_embeddings?
      Annot.light.where(project_id: @project.id)
           .where.not(filepath: nil)
           .where(dim: 1, nber_rows: 2)
           .exists?
    end

    def with_request_profile(endpoint, view: nil)
      sql_count = 0
      sql_duration_ms = 0.0
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, start, finish, _id, payload|
        next if payload[:name] == 'SCHEMA' || payload[:cached]
        sql_count += 1
        sql_duration_ms += (finish - start) * 1000.0
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0).round(1)
      Rails.logger.info("[perf] endpoint=#{endpoint} view=#{view || @view_type} duration_ms=#{elapsed_ms} sql_count=#{sql_count} sql_ms=#{sql_duration_ms.round(1)}")
    end

    def load_view_context_for(view_type)
      case view_type
      when 'visualization'
        load_visualization_context
      when 'heatmap'
        load_heatmap_viewer_context
      when 'summary'
        # Summary is metadata-only: do not load analysis loom/steps/pipeline context.
        load_summary_context
      when 'analysis'
        load_analysis_context
      when 'data'
        load_data_context
      when 'settings'
        load_settings_context
      when 'compliance'
        load_compliance_context
      when 'access'
        load_access_context
      when 'annotations'
        load_annotations_context
      else
        @view_type = 'summary'
        load_summary_context
      end
    end

    def load_heatmap_viewer_context
      asap_docker_image = Basic.get_asap_docker(@project.version)
      @h_std_methods = {}
      step_ids = []
      if asap_docker_image
        StdMethod.where(docker_image_id: asap_docker_image.id).each { |s| @h_std_methods[s.id] = s }
        heatmap_steps = Step.where(docker_image_id: asap_docker_image.id, name: 'heatmap')
        @step = heatmap_steps.first
        step_ids = heatmap_steps.pluck(:id)
      else
        @step = Step.find_by(name: 'heatmap')
        step_ids = @step ? [@step.id] : []
      end

      runs_scope = if step_ids.any?
                     @project.runs.where(step_id: step_ids, status_id: 3).includes(:std_method).order(created_at: :desc)
                   else
                     Run.none
                   end
      @heatmap_runs = apply_publication_snapshot_to_runs(runs_scope).to_a
      requested_id = params[:run_id].to_i
      @run = @heatmap_runs.find { |r| r.id == requested_id } || @heatmap_runs.first
      @heatmap_loom_file = @run ? heatmap_loom_file_for_run(@run) : nil
      @heatmap_gene_set_collections = heatmap_gene_set_collections_payload
      @heatmap_gene_set_collection_options = @heatmap_gene_set_collections.map do |collection|
        { id: collection[:id], label: collection[:label] }
      end
    end

    def heatmap_gene_set_collections_payload
      collections = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).order(created_at: :desc).select do |collection|
        gene_set_collection_from_heatmap?(collection)
      end
      collections.map do |collection|
        payload = load_local_gene_set_collection_payload(collection.file_key, collection.name)
        {
          id: local_gene_set_collection_id(collection),
          label: collection.name.to_s,
          database_name: '',
          nb_items: Array(payload['items']).length,
          custom: true,
          locked: immutable_since_publication?(collection)
        }.merge(gene_set_collection_type_presentation(gene_set_collection_type_key(collection)))
      end
    end

    def heatmap_gene_set_collections_for_dropdown
      heatmap_gene_set_collections_payload.map do |collection|
        {
          id: collection[:id],
          label: collection[:label]
        }
      end
    end

    def load_access_context
      @project_view_access_windows = [
        build_project_access_window(
          label: "Last 24 hours",
          range_start: 24.hours.ago,
          bucket_seconds: 1.hour
        ),
        build_project_access_window(
          label: "Last week",
          range_start: 7.days.ago,
          bucket_seconds: 1.day
        ),
        build_project_access_window(
          label: "Last month",
          range_start: 30.days.ago,
          bucket_seconds: 1.day
        ),
        build_project_access_window(
          label: "Last year",
          range_start: 365.days.ago,
          bucket_seconds: 7.days
        )
      ]
    end

    def build_project_access_window(label:, range_start:, bucket_seconds:)
      range_end = Time.current
      base = range_start.to_i

      bucket_counts = Hash.new(0)
      ProjectViewLog.where(project_id: @project.id, created_at: range_start..range_end).pluck(:created_at).each do |created_at|
        ts = created_at.to_i
        bucket_index = (ts - base) / bucket_seconds
        next if bucket_index.negative?

        bucket_start = Time.zone.at(base + (bucket_index * bucket_seconds))
        bucket_counts[bucket_start] += 1
      end

      points = []
      cursor = Time.zone.at(base)
      while cursor <= range_end
        points << { time: cursor, count: bucket_counts[cursor] || 0 }
        cursor += bucket_seconds
      end

      {
        label: label,
        total: points.sum { |entry| entry[:count] },
        max: points.map { |entry| entry[:count] }.max.to_i,
        points: points
      }
    end

    def load_visualization_context
      perf_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      perf_steps = {}
      timed_step = lambda do |name, &block|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = block.call
        perf_steps[name] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0).round(1)
        result
      end

      all_loom_files = timed_step.call('available_loom_files') { Annot.available_loom_files(@project.id) }
      available_metadata = timed_step.call('available_metadata') { Annot.available_metadata(@project.id) }

      @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
      existing_loom_files = timed_step.call('filter_existing_loom_files') do
        all_loom_files.select do |filepath|
        full_path = @project_dir + filepath
        exists = File.exist?(full_path)
        Rails.logger.debug "[show] Checking loom file existence: #{full_path} -> #{exists}"
        exists
      end
      end

      existing_metadata = timed_step.call('filter_existing_metadata') { available_metadata.select { |metadata| existing_loom_files.include?(metadata.filepath) } }
      @h_metadata = timed_step.call('organize_metadata') { organize_metadata(existing_metadata) }

      @available_loom_files = timed_step.call('filter_visualizable_loom_files') do
        existing_loom_files.select do |filepath|
          @h_metadata[filepath] &&
            @h_metadata[filepath]['cell'] &&
            @h_metadata[filepath]['cell']['NUMERIC'] &&
            @h_metadata[filepath]['cell']['NUMERIC'].any? { |m| m.nber_rows && (m.nber_rows == 2) }
        end
      end

      @default_loom_file = @available_loom_files.first || existing_loom_files.first
      @all_embeddings_by_loom = timed_step.call('build_embeddings_by_loom') do
        h_res = {}
        @available_loom_files.each do |filepath|
          numeric_metadata = @h_metadata.dig(filepath, 'cell', 'NUMERIC') || []
          h_res[filepath] = numeric_metadata.select do |metadata|
            metadata.nber_rows.present? && metadata.nber_rows == 2
          end
        end
        h_res
      end

      timed_step.call('resolve_default_embedding') do
        if params[:embedding_id].present?
          requested_embedding = Annot.find_by(id: params[:embedding_id], project_id: @project.id)
          if requested_embedding && requested_embedding.nber_rows.present? && requested_embedding.nber_rows == 2
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
      end

      @expression_matrices_by_loom = timed_step.call('load_expression_matrices') do
        Annot.light.where(project_id: @project.id, dim: 3)
             .order(id: :asc)
             .group_by(&:filepath)
      end

      categorical_metadata = timed_step.call('collect_categorical_metadata') do
        values = []
        @h_metadata.each_value do |dimension_hash|
          next unless dimension_hash
          discrete = dimension_hash.dig('cell', 'DISCRETE')
          values.concat(discrete) if discrete.present?
        end
        values
      end
      if @project.single_cell?
        timed_step.call('build_best_cla_category_map') { build_best_cla_category_map(categorical_metadata) }
      else
        @best_clas_by_metadata_category = {}
      end

      @initial_selection_items = []
      if @default_loom_file.present?
        timed_step.call('load_initial_selection_items') do
          @initial_selection_items = selection_cache_items_for_loom(@default_loom_file, cleanup_completed: true)
          @initial_selection_items.concat(selection_items_from_annots(@default_loom_file))
          @initial_selection_items.sort_by! { |entry| entry[:created_at].to_s }
          @initial_selection_items.reverse!
        end
      end

      timed_step.call('load_gene_set_collections') { load_gene_set_collections }
      timed_step.call('prepare_visualization_de_modal_context') { prepare_visualization_de_modal_context }

      total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - perf_started) * 1000.0).round(1)
      embedding_count = @all_embeddings_by_loom.values.sum { |entries| entries.size }
      max_embedding_cells = @all_embeddings_by_loom.values.flatten.map { |embedding| embedding.nber_cols.to_i }.max || 0
      steps_str = perf_steps.map { |name, duration| "#{name}=#{duration}" }.join(' ')
      Rails.logger.info(
        "[perf][visualization_context] project_id=#{@project.id} view=visualization total_ms=#{total_ms} " \
        "loom_files_total=#{all_loom_files.size} loom_files_existing=#{existing_loom_files.size} " \
        "metadata_total=#{available_metadata.size} metadata_existing=#{existing_metadata.size} " \
        "embedding_count=#{embedding_count} default_embedding_id=#{@default_embedding&.id} " \
        "default_embedding_cells=#{@default_embedding&.nber_cols.to_i} max_embedding_cells=#{max_embedding_cells} " \
        "initial_selection_items=#{@initial_selection_items.size} #{steps_str}"
      )
    end

    def load_gene_set_collections
      h_env = Basic.safe_parse_json(@project.version.env_json, {})
      db_version = asap_data_db_name_for_env(h_env, context: "load_gene_set_collections")
      current_user_id = current_user&.id
      global_type_presentation = gene_set_collection_type_presentation(GENE_SET_COLLECTION_TYPE_GLOBAL)
      imported_type_presentation = gene_set_collection_type_presentation(GENE_SET_COLLECTION_TYPE_IMPORTED)

      @gene_set_collections = []

      RemoteGene.with_remote(db_version) do
        conn = RemoteGene.connection
        where_sql = [
          "(gs.project_id IS NULL AND gs.ref_id IS NOT NULL)",
          "gs.project_id = #{@project.id}"
        ]
        if current_user_id.present?
          where_sql << "(gs.project_id IS NULL AND gs.user_id = #{current_user_id.to_i} AND gs.ref_id IS NULL)"
        end

        query = <<~SQL
          SELECT
            gs.id,
            gs.label,
            gs.ref_id,
            gs.project_id,
            gs.user_id,
            ds.label AS database_name,
            COALESCE(gsi_counts.item_count, 0) AS item_count
          FROM gene_sets gs
          LEFT JOIN db_sets ds ON ds.id = gs.ref_id
          LEFT JOIN (
            SELECT gene_set_id, COUNT(*) AS item_count
            FROM gene_set_items
            GROUP BY gene_set_id
          ) gsi_counts ON gsi_counts.gene_set_id = gs.id
          WHERE gs.organism_id = #{@project.organism_id.to_i}
            AND COALESCE(gs.obsolete, FALSE) = FALSE
            AND (#{where_sql.join(' OR ')})
          ORDER BY LOWER(COALESCE(ds.label, '')), LOWER(COALESCE(gs.label, ''))
        SQL

        rows = conn.select_all(query)
        @gene_set_collections = rows.map do |row|
          project_id = row['project_id']&.to_i
          owner_user_id = row['user_id']&.to_i
          ref_id = row['ref_id']&.to_i
          custom_for_project = project_id.present? && project_id == @project.id
          custom_for_user = current_user_id.present? &&
                            owner_user_id.present? &&
                            owner_user_id == current_user_id &&
                            project_id.blank? &&
                            ref_id.blank?
          is_custom = custom_for_project || custom_for_user
          {
            id: row['id'].to_i,
            label: row['label'].to_s,
            database_name: row['database_name'].to_s,
            nb_items: row['item_count'].to_i,
            custom: is_custom,
            locked: false
          }.merge(project_id.blank? && ref_id.present? ? global_type_presentation : imported_type_presentation)
        end
      end

      legacy_manual_payload_items = Array(load_manual_gene_set_collection_payload['items'])
      local_collections = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).order(created_at: :desc)
      manual_local_payloads = []
      non_manual_local_payloads = []

      local_collections.each do |collection|
        payload = load_local_gene_set_collection_payload(collection.file_key, collection.name)
        collection_payload = {
          id: local_gene_set_collection_id(collection),
          label: collection.name.to_s,
          database_name: '',
          nb_items: Array(payload['items']).length,
          custom: true,
          locked: immutable_since_publication?(collection)
        }.merge(gene_set_collection_type_presentation(gene_set_collection_type_key(collection)))
        if gene_set_collection_manual?(collection)
          manual_local_payloads << collection_payload
        else
          non_manual_local_payloads << collection_payload
        end
      end

      if non_manual_local_payloads.any?
        @gene_set_collections = non_manual_local_payloads + @gene_set_collections
      end
      if manual_local_payloads.any?
        @gene_set_collections = manual_local_payloads + @gene_set_collections
      elsif legacy_manual_payload_items.any?
        @gene_set_collections.unshift({
          id: MANUAL_GENE_SET_COLLECTION_ID,
          label: MANUAL_GENE_SET_COLLECTION_LABEL,
          database_name: '',
          nb_items: legacy_manual_payload_items.length,
          custom: true,
          locked: false
        }.merge(gene_set_collection_type_presentation(GENE_SET_COLLECTION_TYPE_MANUAL)))
      end

      @manual_gene_set_collection_options = manual_gene_set_collections_for_dropdown
      @de_gene_set_collection_options = de_gene_set_collections_for_dropdown
    end

    def manual_gene_set_collections_dir
      user_data_dir = ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s
      Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key + 'gene_set_collections'
    end

    def manual_gene_set_collection_file_path
      manual_gene_set_collections_dir + 'manual_gene_sets.json'
    end

    def ensure_default_manual_gene_set_collection_record!
      existing_manual = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).find do |collection|
        gene_set_collection_manual?(collection)
      end
      return existing_manual if existing_manual

      create_manual_gene_set_collection!(name: MANUAL_GENE_SET_COLLECTION_LABEL)
    end

    def create_manual_gene_set_collection!(name:)
      file_key = "manual_gene_sets_#{@project.id}_#{SecureRandom.hex(6)}"
      manual_collection = GeneSetCollection.create!(
        project_id: @project.id,
        user_id: current_user&.id,
        name: name.to_s.strip.presence || MANUAL_GENE_SET_COLLECTION_LABEL,
        file_key: file_key,
        source_kind: 'manual',
        gene_set_collection_type_id: gene_set_collection_type_id_for!(GENE_SET_COLLECTION_TYPE_MANUAL)
      )
      write_local_gene_set_collection_payload(manual_collection.file_key, {
        'collection' => manual_collection.name.to_s,
        'items' => [],
        'created_at' => Time.current.utc.iso8601,
        'updated_at' => Time.current.utc.iso8601
      })
      manual_collection
    end

    def resolve_target_manual_collection(collection_id_param, new_collection_name: nil)
      requested_id = collection_id_param.to_s.strip
      create_new = requested_id.blank? || requested_id == MANUAL_GENE_SET_COLLECTION_NEW_ID
      if create_new
        label = new_collection_name.to_s.strip.presence || MANUAL_GENE_SET_COLLECTION_LABEL
        return create_manual_gene_set_collection!(name: label)
      end

      return ensure_default_manual_gene_set_collection_record! if requested_id == MANUAL_GENE_SET_COLLECTION_ID

      local_collection_id = parse_local_gene_set_collection_id(requested_id)
      return nil unless local_collection_id

      collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      return nil unless collection
      return nil unless gene_set_collection_manual?(collection)

      collection
    end

    def manual_gene_set_collections_for_dropdown
      collections = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).order(created_at: :desc).select do |collection|
        gene_set_collection_manual?(collection)
      end
      collections.map do |collection|
        {
          id: local_gene_set_collection_id(collection),
          label: collection.name.to_s
        }
      end
    end

    def create_de_gene_set_collection!(name:)
      file_key = "gene_set_collection_de_#{SecureRandom.hex(12)}"
      collection = GeneSetCollection.create!(
        project_id: @project.id,
        user_id: current_user&.id,
        name: name.to_s.strip.presence || DE_GENE_SET_COLLECTION_LABEL,
        file_key: file_key,
        source_kind: 'from_de',
        gene_set_collection_type_id: gene_set_collection_type_id_for!(GENE_SET_COLLECTION_TYPE_FROM_DE)
      )
      write_local_gene_set_collection_payload(collection.file_key, {
        'collection' => collection.name.to_s,
        'items' => [],
        'created_at' => Time.current.utc.iso8601,
        'updated_at' => Time.current.utc.iso8601
      })
      collection
    end

    def resolve_target_de_collection(collection_id_param, new_collection_name: nil)
      requested_id = collection_id_param.to_s.strip
      create_new = requested_id.blank? || requested_id == DE_GENE_SET_COLLECTION_NEW_ID
      if create_new
        label = new_collection_name.to_s.strip.presence || DE_GENE_SET_COLLECTION_LABEL
        return create_de_gene_set_collection!(name: label)
      end

      local_collection_id = parse_local_gene_set_collection_id(requested_id)
      return nil unless local_collection_id

      collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      return nil unless collection
      return nil unless gene_set_collection_from_de?(collection)

      collection
    end

    def de_gene_set_collections_for_dropdown
      collections = GeneSetCollection.where(project_id: @project.id).includes(:gene_set_collection_type).order(created_at: :desc).select do |collection|
        gene_set_collection_from_de?(collection)
      end
      collections.map do |collection|
        {
          id: local_gene_set_collection_id(collection),
          label: collection.name.to_s
        }
      end
    end

    def create_heatmap_gene_set_collection!(name:)
      file_key = "gene_set_collection_heatmap_#{SecureRandom.hex(12)}"
      collection = GeneSetCollection.create!(
        project_id: @project.id,
        user_id: current_user&.id,
        name: name.to_s.strip.presence || HEATMAP_GENE_SET_COLLECTION_LABEL,
        file_key: file_key,
        source_kind: GENE_SET_COLLECTION_TYPE_FROM_HEATMAP,
        gene_set_collection_type_id: gene_set_collection_type_id_for!(GENE_SET_COLLECTION_TYPE_FROM_HEATMAP)
      )
      write_local_gene_set_collection_payload(collection.file_key, {
        'collection' => collection.name.to_s,
        'items' => [],
        'created_at' => Time.current.utc.iso8601,
        'updated_at' => Time.current.utc.iso8601
      })
      collection
    end

    def resolve_target_heatmap_collection(collection_id_param, new_collection_name: nil)
      requested_id = collection_id_param.to_s.strip
      create_new = requested_id.blank? || requested_id == HEATMAP_GENE_SET_COLLECTION_NEW_ID
      if create_new
        label = new_collection_name.to_s.strip.presence || HEATMAP_GENE_SET_COLLECTION_LABEL
        return create_heatmap_gene_set_collection!(name: label)
      end

      local_collection_id = parse_local_gene_set_collection_id(requested_id)
      return nil unless local_collection_id

      collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      return nil unless collection
      return nil unless gene_set_collection_from_heatmap?(collection)

      collection
    end

    def gene_set_collection_type_key(collection)
      type_key = collection&.gene_set_collection_type&.key.to_s.strip
      return type_key if type_key.present?
      legacy_kind = collection&.source_kind.to_s.strip
      return GENE_SET_COLLECTION_TYPE_MANUAL if legacy_kind == 'manual'
      return GENE_SET_COLLECTION_TYPE_FROM_DE if legacy_kind == 'from_de'
      return GENE_SET_COLLECTION_TYPE_FROM_HEATMAP if legacy_kind == 'from_heatmap'
      GENE_SET_COLLECTION_TYPE_IMPORTED
    end

    def gene_set_collection_manual?(collection)
      gene_set_collection_type_key(collection) == GENE_SET_COLLECTION_TYPE_MANUAL
    end

    def gene_set_collection_from_de?(collection)
      gene_set_collection_type_key(collection) == GENE_SET_COLLECTION_TYPE_FROM_DE
    end

    def gene_set_collection_from_heatmap?(collection)
      gene_set_collection_type_key(collection) == GENE_SET_COLLECTION_TYPE_FROM_HEATMAP
    end

    def gene_set_collection_type_id_for!(type_key)
      type = GeneSetCollectionType.find_by(key: type_key.to_s.strip)
      raise ArgumentError, "Unknown gene set collection type: #{type_key}" unless type
      type.id
    end

    def gene_set_collection_types_by_key
      @gene_set_collection_types_by_key ||= GeneSetCollectionType.all.index_by { |row| row.key.to_s }
    end

    def gene_set_collection_type_presentation(type_key)
      normalized_key = type_key.to_s.strip
      type_row = gene_set_collection_types_by_key[normalized_key]
      if type_row
        {
          type_key: type_row.key.to_s,
          type_label: type_row.label.to_s,
          type_icon: type_row.icon.to_s,
          type_icon_color: type_row.icon_color.to_s
        }
      else
        {
          type_key: GENE_SET_COLLECTION_TYPE_IMPORTED,
          type_label: 'Imported',
          type_icon: 'fas fa-file-import',
          type_icon_color: '#6b7280'
        }
      end
    end

    def collection_type_presentation_for_collection(collection)
      type_key = collection ? gene_set_collection_type_key(collection) : GENE_SET_COLLECTION_TYPE_MANUAL
      { collection: gene_set_collection_type_presentation(type_key) }
    end

    def gene_set_collection_imports_dir
      GeneSetCollection.imports_dir
    end

    def stage_gene_set_collection_upload!(source_path, import_id:)
      directory = gene_set_collection_imports_dir
      FileUtils.mkdir_p(directory) unless File.directory?(directory)
      staged_filename = "#{@project.id}_#{import_id}.gmt"
      staged_path = directory.join(staged_filename)
      FileUtils.cp(source_path, staged_path)
      staged_path.to_s
    end

    def load_manual_gene_set_collection_payload
      path = manual_gene_set_collection_file_path
      return { 'collection' => MANUAL_GENE_SET_COLLECTION_LABEL, 'items' => [] } unless File.exist?(path)
      parsed = Basic.safe_parse_json(File.read(path), {})
      parsed = {} unless parsed.is_a?(Hash)
      parsed['collection'] = MANUAL_GENE_SET_COLLECTION_LABEL
      parsed['items'] = Array(parsed['items'])
      parsed
    end

    def write_manual_gene_set_collection_payload(payload)
      directory = manual_gene_set_collections_dir
      FileUtils.mkdir_p(directory) unless File.directory?(directory)
      File.write(manual_gene_set_collection_file_path, JSON.pretty_generate(payload))
    end

    def local_gene_set_collection_id(collection_record)
      "#{LOCAL_GENE_SET_COLLECTION_ID_PREFIX}:#{collection_record.id}"
    end

    def parse_local_gene_set_collection_id(raw_id)
      match = raw_id.to_s.strip.match(/\A#{Regexp.escape(LOCAL_GENE_SET_COLLECTION_ID_PREFIX)}:(\d+)\z/)
      match ? match[1].to_i : nil
    end

    def parse_local_gene_set_collection_id_from_item_id(item_id)
      match = item_id.to_s.strip.match(/\A#{Regexp.escape(LOCAL_GENE_SET_COLLECTION_ID_PREFIX)}:(\d+):/)
      match ? match[1].to_i : nil
    end

    def local_gene_set_collection_file_path(file_key)
      normalized_key = file_key.to_s.strip
      raise ArgumentError, 'Invalid collection file key' unless normalized_key.match?(/\A[a-zA-Z0-9_-]+\z/)
      manual_gene_set_collections_dir + "#{normalized_key}.json"
    end

    def load_local_gene_set_collection_payload(file_key, collection_label)
      path = local_gene_set_collection_file_path(file_key)
      return { 'collection' => collection_label.to_s, 'items' => [] } unless File.exist?(path)
      parsed = Basic.safe_parse_json(File.read(path), {})
      parsed = {} unless parsed.is_a?(Hash)
      parsed['collection'] = collection_label.to_s
      parsed['items'] = Array(parsed['items'])
      parsed
    end

    def write_local_gene_set_collection_payload(file_key, payload)
      directory = manual_gene_set_collections_dir
      FileUtils.mkdir_p(directory) unless File.directory?(directory)
      File.write(local_gene_set_collection_file_path(file_key), JSON.pretty_generate(payload))
    end

    def parse_uploaded_gene_set_collection_items!(source_kind, file_content)
      case source_kind
      when 'gmt'
        parse_uploaded_gmt_items!(file_content)
      when 'json'
        parse_uploaded_json_items!(file_content)
      else
        raise ArgumentError, "Unsupported source kind: #{source_kind}"
      end
    end

    def parse_uploaded_gmt_items!(file_content)
      items = []
      lines = file_content.to_s.split(/\r?\n/)
      lines.each_with_index do |line, index|
        next if line.strip.blank?
        parts = line.split("\t")
        if parts.length < 3
          raise ArgumentError, "Invalid GMT format on line #{index + 1}: expected at least 3 tab-separated columns"
        end

        raw_name = parts[0].to_s.strip
        raw_description = parts[1].to_s.strip
        gene_tokens = parts[2..].map { |value| value.to_s.strip }.reject(&:blank?).uniq
        if raw_name.blank?
          raise ArgumentError, "Invalid GMT format on line #{index + 1}: missing gene set name"
        end
        if gene_tokens.empty?
          raise ArgumentError, "Invalid GMT format on line #{index + 1}: no genes provided"
        end

        items << {
          identifier: raw_name,
          name: raw_name,
          description: raw_description,
          genes: gene_tokens.map { |token| parse_uploaded_gene_token(token) }
        }
      end
      items
    end

    def parse_uploaded_json_items!(file_content)
      parsed = JSON.parse(file_content)
      raw_items = if parsed.is_a?(Hash)
        Array(parsed['items'])
      elsif parsed.is_a?(Array)
        parsed
      else
        raise ArgumentError, 'Invalid JSON format. Expected an array of gene sets or an object with an items array.'
      end

      raw_items.each_with_index.map do |raw_item, index|
        unless raw_item.is_a?(Hash)
          raise ArgumentError, "Invalid JSON format for gene set at index #{index}"
        end

        identifier = raw_item['identifier'].to_s.strip
        name = raw_item['name'].to_s.strip
        genes = raw_item['genes']
        unless genes.is_a?(Array)
          raise ArgumentError, "Invalid genes value for gene set at index #{index}. Expected an array."
        end

        parsed_genes = genes.map.with_index do |entry, gene_index|
          parse_uploaded_gene_entry(entry, index, gene_index)
        end.compact
        if parsed_genes.empty?
          raise ArgumentError, "Gene set at index #{index} has no valid genes"
        end

        {
          identifier: identifier,
          name: name,
          genes: parsed_genes
        }
      end
    end

    def parse_uploaded_gene_entry(entry, item_index, gene_index)
      if entry.is_a?(String)
        return parse_uploaded_gene_token(entry)
      end

      unless entry.is_a?(Hash)
        raise ArgumentError, "Invalid gene entry at gene set #{item_index}, gene #{gene_index}"
      end

      symbol = entry['symbol'].to_s.strip
      ensembl_id = entry['ensembl_id'].to_s.strip
      stable_id = entry['stable_id'].to_s.strip
      if symbol.blank? && ensembl_id.blank? && stable_id.blank?
        raise ArgumentError, "Invalid gene entry at gene set #{item_index}, gene #{gene_index}: empty symbol, ensembl_id and stable_id"
      end

      {
        symbol: symbol,
        ensembl_id: ensembl_id,
        stable_id: stable_id
      }
    end

    def parse_uploaded_gene_token(token)
      value = token.to_s.strip
      if value.blank?
        raise ArgumentError, 'Invalid gene token: empty value'
      end

      if token_looks_like_accession?(value)
        { symbol: '', ensembl_id: value, stable_id: '' }
      else
        { symbol: value, ensembl_id: '', stable_id: '' }
      end
    end

    def token_looks_like_accession?(value)
      token = value.to_s.strip
      return false if token.blank?
      return true if token.match?(/\AENS[A-Z0-9]+\z/i)
      token.match?(/\A(?=.{6,}$)(?=(?:.*\d){3,})[A-Za-z0-9_.-]+\z/)
    end

    def normalize_uploaded_collection_items_for_storage(parsed_items, db_version:, collection_id:, timestamp:)
      normalized_identifiers = Set.new
      all_genes = parsed_items.flat_map { |item| Array(item[:genes]) }
      ensembl_lookup, symbol_lookup = build_manual_gene_id_lookups(all_genes, db_version)
      parsed_items.each_with_index.map do |item, index|
        token_seed = item[:identifier].presence || item[:name].presence || "item_#{index + 1}"
        item_identifier = normalize_uploaded_item_identifier(token_seed)
        suffix_index = 2
        while normalized_identifiers.include?(item_identifier)
          item_identifier = "#{normalize_uploaded_item_identifier(token_seed)}_#{suffix_index}"
          suffix_index += 1
        end
        normalized_identifiers.add(item_identifier)

        item_name = item[:name].presence || item[:identifier].presence || "Gene set #{index + 1}"
        genes_with_ids = resolve_manual_gene_ids_with_lookups(Array(item[:genes]), ensembl_lookup, symbol_lookup)
        {
          'id' => "#{collection_id}:#{item_identifier}",
          'identifier' => item_identifier,
          'name' => item_name,
          'genes' => genes_with_ids,
          'created_at' => timestamp,
          'updated_at' => timestamp
        }
      end
    end

    def normalize_uploaded_item_identifier(raw_value)
      normalized = raw_value.to_s.strip.gsub(/[^a-zA-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '').downcase
      normalized.presence || "item_#{SecureRandom.hex(4)}"
    end

    def sanitize_collection_export_filename(label)
      normalized = label.to_s.strip.gsub(/[^a-zA-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '').downcase
      normalized.presence || 'gene_set_collection'
    end

    def build_gene_set_collection_gmt_export(collection_payload, mode:)
      lines = collection_payload[:items].map do |item|
        item_identifier = item[:identifier].to_s.strip
        item_name = item[:name].to_s.strip
        if item_identifier.blank? && item_name.blank?
          item_identifier = 'unnamed_gene_set'
          item_name = 'Unnamed gene set'
        elsif item_identifier.blank?
          item_identifier = item_name.gsub(/[^a-zA-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '').downcase
          item_identifier = 'unnamed_gene_set' if item_identifier.blank?
        elsif item_name.blank?
          item_name = item_identifier
        end
        gene_values = item[:genes].map do |gene|
          symbol = gene[:symbol].to_s.strip
          ensembl_id = gene[:ensembl_id].to_s.strip
          if mode == :symbol
            symbol.presence || ensembl_id
          else
            ensembl_id.presence || symbol
          end
        end.reject(&:blank?).uniq
        ([item_identifier, item_name] + gene_values).join("\t")
      end
      "#{lines.join("\n")}\n"
    end

    def load_gene_set_collection_for_export(collection_id_raw, db_version:, current_user_id:, dataset_stable_by_accession:, dataset_stable_by_symbol:)
      if collection_id_raw == MANUAL_GENE_SET_COLLECTION_ID
        manual_payload = load_manual_gene_set_collection_payload
        items = Array(manual_payload['items']).map { |raw_item| normalize_manual_gene_set_item(raw_item) }.compact
        return {
          id: MANUAL_GENE_SET_COLLECTION_ID,
          label: MANUAL_GENE_SET_COLLECTION_LABEL,
          items: items.map do |item|
            {
              id: item[:id],
              identifier: item[:identifier],
              name: item[:name],
              genes: enrich_export_genes_with_dataset_stable_id(
                item[:genes],
                dataset_stable_by_accession: dataset_stable_by_accession,
                dataset_stable_by_symbol: dataset_stable_by_symbol
              )
            }
          end
        }
      end

      local_collection_id = parse_local_gene_set_collection_id(collection_id_raw)
      if local_collection_id
        local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
        raise ArgumentError, 'Gene set collection not found' unless local_collection

        local_payload = load_local_gene_set_collection_payload(local_collection.file_key, local_collection.name)
        items = Array(local_payload['items']).map { |raw_item| normalize_manual_gene_set_item(raw_item) }.compact
        return {
          id: local_gene_set_collection_id(local_collection),
          label: local_collection.name.to_s,
          items: items.map do |item|
            {
              id: item[:id],
              identifier: item[:identifier],
              name: item[:name],
              genes: enrich_export_genes_with_dataset_stable_id(
                item[:genes],
                dataset_stable_by_accession: dataset_stable_by_accession,
                dataset_stable_by_symbol: dataset_stable_by_symbol
              )
            }
          end
        }
      end

      collection_id = collection_id_raw.to_i
      raise ArgumentError, 'Invalid gene set collection identifier' if collection_id <= 0

      payload = nil
      RemoteGene.with_remote(db_version) do
        conn = RemoteGene.connection
        where_sql = [
          "(project_id IS NULL AND ref_id IS NOT NULL)",
          "project_id = #{@project.id}"
        ]
        if current_user_id.present?
          where_sql << "(project_id IS NULL AND user_id = #{current_user_id.to_i} AND ref_id IS NULL)"
        end

        collection_row = conn.select_one(<<~SQL)
          SELECT id, label
          FROM gene_sets
          WHERE id = #{collection_id}
            AND organism_id = #{@project.organism_id.to_i}
            AND COALESCE(obsolete, FALSE) = FALSE
            AND (#{where_sql.join(' OR ')})
        SQL
        raise ArgumentError, 'Gene set collection not found' unless collection_row

        item_rows = conn.select_all(<<~SQL)
          SELECT id, identifier, name, content
          FROM gene_set_items
          WHERE gene_set_id = #{collection_id}
          ORDER BY LOWER(COALESCE(name, '')), LOWER(COALESCE(identifier, ''))
        SQL

        gene_ids = item_rows.flat_map do |row|
          row['content'].to_s.split(',').map { |value| value.to_i }.select { |value| value > 0 }
        end.uniq
        gene_lookup = {}
        if gene_ids.any?
          gene_rows = conn.select_all(<<~SQL)
            SELECT id, name, ensembl_id
            FROM genes
            WHERE id IN (#{gene_ids.join(',')})
          SQL
          gene_rows.each do |gene_row|
            gene_lookup[gene_row['id'].to_i] = {
              symbol: gene_row['name'].to_s,
              ensembl_id: gene_row['ensembl_id'].to_s,
              stable_id: resolve_dataset_stable_id_for_export(
                symbol: gene_row['name'].to_s,
                ensembl_id: gene_row['ensembl_id'].to_s,
                existing_stable_id: '',
                dataset_stable_by_accession: dataset_stable_by_accession,
                dataset_stable_by_symbol: dataset_stable_by_symbol
              ),
              gene_id: gene_row['id'].to_i
            }
          end
        end

        payload = {
          id: collection_row['id'].to_i,
          label: collection_row['label'].to_s,
          items: item_rows.map do |row|
            item_gene_ids = row['content'].to_s.split(',').map { |value| value.to_i }.select { |value| value > 0 }
            genes = item_gene_ids.map { |gene_id| gene_lookup[gene_id] }.compact
            {
              id: row['id'].to_i,
              identifier: row['identifier'].to_s,
              name: row['name'].to_s,
              genes: genes
            }
          end
        }
      end

      payload
    end

    def cached_dataset_stable_lookup(loom_path)
      mtime = File.mtime(loom_path).to_i
      cache_key = "projects:dataset_stable_lookup:#{@project.id}:#{loom_path}:#{mtime}"
      miss = false
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      autocomplete_file = loom_path.dirname + 'autocomplete_genes.json'
      result = Rails.cache.fetch(cache_key, expires_in: 6.hours) do
        miss = true
        parsed = AsapData::DatasetStableLookup.from_autocomplete_json_file(autocomplete_file.to_s)
        if parsed
          parsed.merge(source: :autocomplete_json)
        else
          stable_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/_StableID')
          accession_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/Accession')
          gene_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/Gene')
          size = [stable_values.length, accession_values.length, gene_values.length].min
          by_accession = {}
          by_symbol = {}
          stable_ids = Set.new

          size.times do |idx|
            stable_id = stable_values[idx].to_s.strip
            next if stable_id.blank?
            stable_ids.add(stable_id)
            accession = accession_values[idx].to_s.strip.downcase
            symbol = gene_values[idx].to_s.strip.downcase
            by_accession[accession] ||= stable_id if accession.present?
            by_symbol[symbol] ||= stable_id if symbol.present?
          end

          { by_accession: by_accession, by_symbol: by_symbol, stable_ids: stable_ids, source: :extract_metadata }
        end
      end
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
      Rails.logger.info(
        "[perf][dataset_stable_lookup] project_id=#{@project.id} loom=#{File.basename(loom_path.to_s)} " \
        "miss=#{miss} ms=#{elapsed_ms} source=#{result[:source]} rows=#{result[:stable_ids].size} " \
        "accession_keys=#{result[:by_accession].size} symbol_keys=#{result[:by_symbol].size}"
      )
      result
    end

    def build_dataset_stable_lookup_for_export(loom_file)
      user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
      project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
      loom_path = project_dir + loom_file
      raise ArgumentError, 'Loom file not found' unless File.exist?(loom_path)
      dataset_lookup = cached_dataset_stable_lookup(loom_path)
      [dataset_lookup[:by_accession], dataset_lookup[:by_symbol]]
    end

    def resolve_dataset_stable_id_for_export(symbol:, ensembl_id:, existing_stable_id:, dataset_stable_by_accession:, dataset_stable_by_symbol:)
      stable_id = existing_stable_id.to_s.strip
      return stable_id if stable_id.present?
      ensembl_key = ensembl_id.to_s.strip.downcase
      symbol_key = symbol.to_s.strip.downcase
      stable_id = dataset_stable_by_accession[ensembl_key] if ensembl_key.present?
      stable_id ||= dataset_stable_by_symbol[symbol_key] if symbol_key.present?
      stable_id.to_s
    end

    def enrich_export_genes_with_dataset_stable_id(genes, dataset_stable_by_accession:, dataset_stable_by_symbol:)
      Array(genes).map do |gene|
        next unless gene.is_a?(Hash)
        symbol = gene[:symbol].to_s
        ensembl_id = gene[:ensembl_id].to_s
        stable_id = resolve_dataset_stable_id_for_export(
          symbol: symbol,
          ensembl_id: ensembl_id,
          existing_stable_id: gene[:stable_id].to_s,
          dataset_stable_by_accession: dataset_stable_by_accession,
          dataset_stable_by_symbol: dataset_stable_by_symbol
        )
        {
          symbol: symbol,
          ensembl_id: ensembl_id,
          stable_id: stable_id,
          gene_id: (gene[:gene_id].to_i > 0 ? gene[:gene_id].to_i : nil)
        }
      end.compact
    end

    def normalize_manual_gene_set_item(raw_item)
      return nil unless raw_item.is_a?(Hash)
      item_id = raw_item['id'].to_s.strip
      item_identifier = raw_item['identifier'].to_s.strip
      item_name = raw_item['name'].to_s.strip
      item_id = "manual_local:#{item_identifier.presence || SecureRandom.hex(6)}" if item_id.blank?
      item_identifier = item_id.split(':', 2).last if item_identifier.blank?
      genes = Array(raw_item['genes']).filter_map do |gene|
        next unless gene.is_a?(Hash)
        symbol = gene['symbol'].to_s.strip
        ensembl_id = gene['ensembl_id'].to_s.strip
        stable_id = gene['stable_id'].to_s.strip
        next if symbol.blank? && ensembl_id.blank? && stable_id.blank?
        {
          symbol: symbol,
          ensembl_id: ensembl_id,
          stable_id: stable_id,
          gene_id: gene['gene_id'].to_i > 0 ? gene['gene_id'].to_i : nil
        }
      end
      {
        id: item_id,
        identifier: item_identifier,
        name: item_name,
        genes: genes,
        created_at: raw_item['created_at'].to_s,
        updated_at: raw_item['updated_at'].to_s
      }
    end

    def find_manual_gene_set_item(item_id)
      payload = load_manual_gene_set_collection_payload
      Array(payload['items']).each do |raw_item|
        normalized = normalize_manual_gene_set_item(raw_item)
        next unless normalized
        return normalized if normalized[:id].to_s == item_id.to_s
      end
      nil
    end

    def resolve_manual_gene_ids(genes, db_version)
      return [] unless genes.is_a?(Array)
      ensembl_lookup, symbol_lookup = build_manual_gene_id_lookups(
        genes,
        db_version,
        organism_id: @project&.organism_id
      )
      resolve_manual_gene_ids_with_lookups(genes, ensembl_lookup, symbol_lookup)
    end

    def build_manual_gene_id_lookups(genes, db_version, organism_id: nil)
      return [{}, {}] unless genes.is_a?(Array)
      ensembl_keys = genes.map { |gene| gene[:ensembl_id].to_s.strip.downcase }
                          .reject(&:blank?)
                          .uniq
      symbol_keys = genes.map { |gene| gene[:symbol].to_s.strip.downcase }
                         .reject(&:blank?)
                         .uniq

      ensembl_lookup = {}
      symbol_lookup = {}
      scoped_organism_id = organism_id.to_i

      RemoteGene.with_remote(db_version) do
        conn = RemoteGene.connection
        if ensembl_keys.any?
          if scoped_organism_id > 0
            quoted = ensembl_keys.map { |value| conn.quote(value) }.join(',')
            ensembl_rows = conn.select_all(
              "SELECT id, ensembl_id, name, LOWER(ensembl_id) AS key FROM genes " \
              "WHERE organism_id = #{scoped_organism_id} AND ensembl_id IS NOT NULL " \
              "AND LOWER(ensembl_id) IN (#{quoted})"
            )
          else
            query_values = ensembl_keys.flat_map { |value| [value, value.upcase, value.downcase] }.uniq
            quoted = query_values.map { |value| conn.quote(value) }.join(',')
            ensembl_rows = conn.select_all(
              "SELECT id, ensembl_id, name, ensembl_id AS key FROM genes WHERE ensembl_id IN (#{quoted})"
            )
          end
          ensembl_rows.each do |row|
            key = row['key'].to_s.downcase
            next if key.blank?
            ensembl_lookup[key] ||= {
              id: row['id'].to_i,
              ensembl_id: row['ensembl_id'].to_s,
              name: row['name'].to_s
            }
          end
        end

        if symbol_keys.any?
          if scoped_organism_id > 0
            quoted = symbol_keys.map { |value| conn.quote(value) }.join(',')
            symbol_rows = conn.select_all(
              "SELECT id, ensembl_id, name, LOWER(name) AS key FROM genes " \
              "WHERE organism_id = #{scoped_organism_id} AND name IS NOT NULL " \
              "AND LOWER(name) IN (#{quoted})"
            )
          else
            query_values = symbol_keys.flat_map { |value| [value, value.upcase, value.downcase, value.capitalize] }.uniq
            quoted = query_values.map { |value| conn.quote(value) }.join(',')
            symbol_rows = conn.select_all(
              "SELECT id, ensembl_id, name, name AS key FROM genes WHERE name IN (#{quoted})"
            )
          end
          symbol_rows.each do |row|
            key = row['key'].to_s.downcase
            next if key.blank?
            symbol_lookup[key] ||= {
              id: row['id'].to_i,
              ensembl_id: row['ensembl_id'].to_s,
              name: row['name'].to_s
            }
          end
        end
      end

      [ensembl_lookup, symbol_lookup]
    end

    def resolve_manual_gene_ids_with_lookups(genes, ensembl_lookup, symbol_lookup)
      genes.map do |gene|
        symbol = gene[:symbol].to_s.strip
        ensembl_id = gene[:ensembl_id].to_s.strip
        stable_id = gene[:stable_id].to_s.strip
        matched = nil

        if ensembl_id.present?
          matched = ensembl_lookup[ensembl_id.downcase]
          if matched.nil? && symbol.blank?
            matched = symbol_lookup[ensembl_id.downcase]
            if matched
              symbol = ensembl_id
              ensembl_id = ''
            end
          end
        end

        if matched.nil? && symbol.present?
          matched = symbol_lookup[symbol.downcase]
          if matched.nil?
            matched = ensembl_lookup[symbol.downcase]
            if matched
              ensembl_id = symbol
              symbol = ''
            end
          end
        end

        gene_id = matched.is_a?(Hash) ? matched[:id].to_i : matched.to_i
        gene_id = nil if gene_id <= 0

        # Backfill accession/symbol from the gene DB so downstream UIs can open details.
        if matched.is_a?(Hash)
          ensembl_id = matched[:ensembl_id].to_s if ensembl_id.blank? && matched[:ensembl_id].to_s.present?
          symbol = matched[:name].to_s if symbol.blank? && matched[:name].to_s.present?
        end

        {
          symbol: symbol,
          ensembl_id: ensembl_id,
          stable_id: stable_id,
          gene_id: gene_id
        }
      end
    end

    def manual_gene_in_dataset?(gene, dataset_stable_by_accession:, dataset_stable_by_symbol:, dataset_stable_ids:)
      resolve_manual_gene_stable_id(
        gene,
        dataset_stable_by_accession: dataset_stable_by_accession,
        dataset_stable_by_symbol: dataset_stable_by_symbol,
        dataset_stable_ids: dataset_stable_ids
      ).present?
    end

    def resolve_manual_gene_stable_id(gene, dataset_stable_by_accession:, dataset_stable_by_symbol:, dataset_stable_ids:)
      return nil unless gene.is_a?(Hash)
      symbol = gene[:symbol].to_s.strip
      ensembl_id = gene[:ensembl_id].to_s.strip
      stable_id = gene[:stable_id].to_s.strip
      return stable_id if stable_id.present? && dataset_stable_ids.include?(stable_id)
      selected = dataset_stable_by_accession[ensembl_id.downcase] if ensembl_id.present?
      selected ||= dataset_stable_by_symbol[symbol.downcase] if symbol.present?
      selected.presence
    end

    def find_local_or_manual_gene_set_item(item_id_raw)
      local_collection_id = parse_local_gene_set_collection_id_from_item_id(item_id_raw)
      if local_collection_id
        local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
        return nil unless local_collection
        local_payload = load_local_gene_set_collection_payload(local_collection.file_key, local_collection.name)
        return Array(local_payload['items']).map { |item| normalize_manual_gene_set_item(item) }.compact.find do |item|
          item[:id].to_s == item_id_raw
        end
      end

      return find_manual_gene_set_item(item_id_raw) if item_id_raw.start_with?("#{MANUAL_GENE_SET_COLLECTION_ID}:")
      nil
    end

    def compute_local_gene_set_expression_scores(item_id_raw:, loom_path:, dataset_path:)
      LocalGeneSetExpressionScores.new(@project).call(
        item_id_raw: item_id_raw,
        loom_path: loom_path,
        dataset_path: dataset_path
      )
    end

    def delete_related_manual_module_score_runs(removed_item)
      return 0 unless removed_item.is_a?(Hash)
      item_id = removed_item[:id].to_s.strip
      item_identifier = removed_item[:identifier].to_s.strip
      return 0 if item_id.blank? && item_identifier.blank?

      module_score_method_ids = StdMethod
        .where("LOWER(COALESCE(name, '')) LIKE ? OR LOWER(COALESCE(label, '')) LIKE ?", '%modulescore%', '%module score%')
        .pluck(:id)
      # Without ModuleScore methods, never fall back to scanning all project runs.
      return 0 if module_score_method_ids.empty?

      deletable_ids = []
      Run.where(project_id: @project.id, std_method_id: module_score_method_ids).find_each do |run|
        next if @project.locked_from_publication?(run)

        attrs = Basic.safe_parse_json(run.attrs_json, {})
        next unless module_score_run_references_gene_set?(attrs, item_id: item_id, item_identifier: item_identifier)

        deletable_ids << run.id
      end
      return 0 if deletable_ids.empty?

      deleted_count = 0
      Run.where(id: deletable_ids).find_each do |run|
        RunsController.destroy_run_call(@project, run)
        deleted_count += 1
      rescue PublicationLockedDeletionError
        next
      end
      deleted_count
    end

    def module_score_run_references_gene_set?(attrs, item_id:, item_identifier:)
      return false unless attrs.is_a?(Hash)

      candidates = [
        attrs['global_gene_set_item_id'],
        attrs['gene_set_item_id'],
        attrs['geneset'],
        attrs.dig('input_gene_set', 'item_id'),
        attrs.dig('input_gene_set', 'identifier')
      ].map { |value| value.to_s.strip }.reject(&:blank?)

      return false if candidates.empty?

      item_id_l = item_id.to_s.downcase
      item_identifier_l = item_identifier.to_s.downcase

      candidates.any? do |candidate|
        candidate_l = candidate.downcase
        (item_id_l.present? && candidate_l == item_id_l) ||
          (item_identifier_l.present? && (candidate_l == item_identifier_l || candidate_l.end_with?(":#{item_identifier_l}")))
      end
    end

    def prepare_visualization_de_modal_context
      @visualization_de_step_id = nil
      @visualization_de_methods = []
      @visualization_de_unavailable_methods = {}

      asap_docker_image = Basic.get_asap_docker(@project.version)
      return unless asap_docker_image

      de_step = Step.find_by(docker_image_id: asap_docker_image.id, name: 'de')
      return unless de_step

      @visualization_de_step_id = de_step.id
      project_type_tag = @project.project_type&.tag
      std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, obsolete: false, step_id: de_step.id).order(:name).to_a

      std_methods.each do |method|
        method_obj_attrs = Basic.safe_parse_json(method.obj_attrs_json, {})
        project_types = Array(method_obj_attrs['project_types'])
        is_project_type_compatible = project_types.empty? || (project_type_tag.present? && project_types.include?(project_type_tag))

        @visualization_de_methods << {
          id: method.id,
          label: method.label.presence || method.name,
          name: method.name,
          speed_id: method.speed_id,
          description: method.description,
          link: (method.respond_to?(:link) ? method.link : '')
        }
        @visualization_de_unavailable_methods[method.id] = true unless is_project_type_compatible
      end
    end

    def load_analysis_context
      @project_type = @project.project_type
      @integration_in_progress = @project.integration_in_progress?
      redirect_analysis_to_parsing_step_if_integration_in_progress!
      return if performed?

      # Load loom file list for contextual dropdowns in analysis views
      all_annots_for_loom = load_loom_file_list_context
      assign_analysis_loom_file_from_session!

      @selected_step_id = params[:step_id].present? ? params[:step_id].to_i : nil
      @selected_run_id = params[:run_id].present? ? params[:run_id].to_i : nil

      redirect_analysis_single_run_canonical_url!(all_annots_for_loom)
      return if performed?

      # Warning context for header: indicate when loom filter hides runs
      @loom_filter_hidden_runs_count = 0
      @loom_filter_total_runs_count = 0
      @loom_filter_visible_runs_count = 0
      @loom_filter_warning_message = nil
      @loom_filter_hidden_runs_by_step = {}
      @loom_filter_total_runs_by_step = {}
      @loom_filter_visible_runs_by_step = {}
      @loom_filter_hidden_runs_by_step_name = {}
      @loom_filter_total_runs_by_step_name = {}
      @loom_filter_visible_runs_by_step_name = {}
      @analysis_step_id_to_name = {}
      if @selected_loom_file.present?
        all_runs_scope = @project.runs
        @loom_filter_total_runs_count = all_runs_scope.count
        loom_run_ids = Annot.light.where(project_id: @project.id, filepath: @selected_loom_file)
                            .where.not(run_id: nil)
                            .distinct
                            .pluck(:run_id)
        visible_runs_scope = all_runs_scope.where(id: loom_run_ids)
        @loom_filter_visible_runs_count = visible_runs_scope.count
        @loom_filter_hidden_runs_count = [@loom_filter_total_runs_count - @loom_filter_visible_runs_count, 0].max
        @loom_filter_total_runs_by_step = all_runs_scope.group(:step_id).count
        @loom_filter_visible_runs_by_step = visible_runs_scope.group(:step_id).count
        @loom_filter_hidden_runs_by_step = {}
        @loom_filter_total_runs_by_step.each do |step_id, total_count|
          visible_count = @loom_filter_visible_runs_by_step[step_id].to_i
          @loom_filter_hidden_runs_by_step[step_id] = [total_count.to_i - visible_count, 0].max
        end

        step_ids_for_warning = (@loom_filter_total_runs_by_step.keys + @loom_filter_visible_runs_by_step.keys).compact.uniq
        step_names_by_id = {}
        step_aliases_by_id = {}
        if step_ids_for_warning.any?
          Step.where(id: step_ids_for_warning).pluck(:id, :name, :label).each do |sid, sname, slabel|
            normalized_name = sname.to_s.strip.downcase
            normalized_label = slabel.to_s.strip.downcase
            aliases = [normalized_name, normalized_label].reject(&:blank?).uniq
            step_names_by_id[sid] = normalized_name.presence || normalized_label
            step_aliases_by_id[sid] = aliases
          end
        end
        @analysis_step_id_to_name = step_names_by_id

        @loom_filter_total_runs_by_step.each do |step_id, total_count|
          aliases = step_aliases_by_id[step_id] || []
          aliases.each do |step_key|
            @loom_filter_total_runs_by_step_name[step_key] ||= 0
            @loom_filter_total_runs_by_step_name[step_key] += total_count.to_i
          end
        end
        @loom_filter_visible_runs_by_step.each do |step_id, visible_count|
          aliases = step_aliases_by_id[step_id] || []
          aliases.each do |step_key|
            @loom_filter_visible_runs_by_step_name[step_key] ||= 0
            @loom_filter_visible_runs_by_step_name[step_key] += visible_count.to_i
          end
        end
        @loom_filter_total_runs_by_step_name.each do |step_name, total_count|
          visible_count = @loom_filter_visible_runs_by_step_name[step_name].to_i
          @loom_filter_hidden_runs_by_step_name[step_name] = [total_count.to_i - visible_count, 0].max
        end
        if @loom_filter_hidden_runs_count > 0
          @loom_filter_warning_message = "#{@loom_filter_hidden_runs_count} run(s) are hidden by the current loom filter. Showing #{@loom_filter_visible_runs_count} of #{@loom_filter_total_runs_count} run(s)."
        end
      end

      @runs = apply_publication_snapshot_to_runs(@project.runs.includes(:annots))
      prepare_steps_with_status

      @parsing_step = parsing_step_for_project(@project)
      @parsing_step_id = @parsing_step&.id
      pipeline_step_names_by_id = @steps_with_status.each_with_object({}) do |entry, map|
        step = entry[:step]
        next unless step

        map[step.id.to_s] = step.name.to_s
      end
      @analysis_step_id_to_name = pipeline_step_names_by_id.merge(@analysis_step_id_to_name)

      @load_run_panel = false
      @run_panel_html = nil

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
            @runs = apply_publication_snapshot_to_runs(
              @project.runs.where(step_id: @selected_step_id).includes(:annots).order(created_at: :desc)
            )
            @project_step = ProjectStep.find_or_create_by(project_id: @project.id, step_id: @selected_step_id)
            @show_form = false
            @show_custom_form = false
            @show_dashboard = false
            @show_view = false

            params[:view] = params[:sub_view]
            @sub_view_html = render_to_string(partial: 'projects/views/step_results', layout: false)
            @load_sub_view = true

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
          de_aid = params[:gene_list_de_annot_id].presence
          @de_gene_list_annot_id = de_aid
          de_list_dir = Basic.de_filter_gene_list_dir(project_dir, gl_run.id, de_aid)

          filename = de_list_dir + "filtered.#{params[:type]}.json"
          list_filtered_rows = Basic.safe_parse_json(File.read(filename), [])
          @h_filtered_rows = {}
          list_filtered_rows.each { |e| @h_filtered_rows[e.to_i] = 1 }
          @nber_genes = list_filtered_rows.size

          output_txt = de_list_dir + 'output.txt'
          @tmp_data = File.readlines(output_txt)
          i = 0
          j = 0
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
              @data.push(e) if e[h_fields['fdr']] <= @h_ge_filters['fdr_cutoff'].to_f
            end
          end
          @nber_genesets = @data.size

          @sub_view_html = render_to_string(partial: 'runs/get_ge_geneset_list', layout: false)
        rescue => e
          Rails.logger.error("[show] Error preparing geneset_list sub_view: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.first(10).join("\n"))
        end
      end
    end

    def analysis_loom_file_candidate
      session[:analysis_loom_file] ||= {}
      project_session_key = @project.id.to_s
      param_loom = params[:loom_file]
      stored_loom = session[:analysis_loom_file][project_session_key] || session[:analysis_loom_file][@project.id]

      if param_loom.present?
        param_loom
      elsif stored_loom.present?
        stored_loom
      else
        '__all__'
      end
    end

    def assign_analysis_loom_file_from_session!
      session[:analysis_loom_file] ||= {}
      project_session_key = @project.id.to_s

      # One loom file: no contextual filter (matches analysis UI where the picker is hidden).
      if @available_loom_files&.one?
        @selected_loom_file = nil
        session[:analysis_loom_file][project_session_key] = '__all__'
        return
      end

      candidate_loom = analysis_loom_file_candidate

      if candidate_loom == '__all__'
        @selected_loom_file = nil
        session[:analysis_loom_file][project_session_key] = '__all__'
      elsif @available_loom_files&.include?(candidate_loom)
        @selected_loom_file = candidate_loom
        session[:analysis_loom_file][project_session_key] = @selected_loom_file
      else
        @selected_loom_file = nil
        session[:analysis_loom_file][project_session_key] = '__all__'
      end
    end

    def analysis_single_visible_run_id_for_step(step, all_annots_for_loom, selected_loom_file)
      step_ids_for_runs =
        if step.multiple_runs
          Step.where(docker_image_id: step.docker_image_id, name: step.name).pluck(:id)
        else
          [step.id]
        end
      runs_scope = @project.runs.where(step_id: step_ids_for_runs)
      if selected_loom_file.present? && all_annots_for_loom
        loom_run_ids = all_annots_for_loom.select { |a| a.filepath == selected_loom_file }.map(&:run_id).compact.uniq
        if loom_run_ids.any?
          run_ids_for_scope = loom_run_ids.dup
          unless step.multiple_runs
            active_ids = @project.runs.where(step_id: step_ids_for_runs, status_id: [1, 2, 6]).pluck(:id)
            run_ids_for_scope.concat(active_ids)
            run_ids_for_scope.uniq!
          end
          runs_scope = runs_scope.where(id: run_ids_for_scope)
        end
      end
      runs_scope = apply_publication_snapshot_to_runs(runs_scope)
      ids = runs_scope.order(created_at: :desc).limit(2).pluck(:id)
      return nil if ids.size != 1

      ids.first
    end

    def redirect_analysis_single_run_canonical_url!(all_annots_for_loom)
      return unless request.get?
      return unless request.format.html?
      return if params[:run_id].present?
      return if params[:step_id].blank?
      return if params[:show_form].to_s == '1'
      return if params[:prefer_runs_list].to_s == '1'
      return if params[:panel_mode].to_s == 'graph'
      return if params[:sub_view].present?

      step = Step.find_by(id: params[:step_id].to_i)
      return unless step && !step.multiple_runs
      # Parsing and other steps with a custom results view are rendered via
      # step_results; they must never be redirected to the generic run panel URL.
      return if step.name == 'parsing'
      return unless step.has_std_view

      run_id = analysis_single_visible_run_id_for_step(step, all_annots_for_loom, @selected_loom_file)
      return unless run_id

      loom_param = @selected_loom_file.present? ? @selected_loom_file : '__all__'
      target = project_path(
        @project,
        view: 'analysis',
        step_id: step.id,
        run_id: run_id,
        panel_mode: 'run_details',
        loom_file: loom_param
      )
      redirect_to target, status: :see_other
    end

    def load_loom_file_list_context
      all_annots = Annot.light.where(project_id: @project.id)
                        .where.not(filepath: nil)
                        .includes(:step, run: [:std_method])
                        .order(:name)

      filepath_info = build_filepath_info_from_matrix_annots(all_annots)

      @available_loom_files = filepath_info.keys.sort_by do |filepath|
        info = filepath_info[filepath]
        [info[:step_rank] || 9999, info[:run_id] || 999999]
      end
      @filepath_info = filepath_info
      run_ids = filepath_info.values.map { |info| info[:run_id] }.compact.uniq
      @loom_file_runs = Run.where(id: run_ids).includes(:step, :std_method).index_by(&:id) if run_ids.any?
      @loom_file_runs ||= {}

      all_annots
    end

    def load_data_context
      @project_type = @project.project_type
      all_annots = Annot.light.where(project_id: @project.id)
                        .where.not(filepath: nil)
                        .includes(:step, run: [:std_method])
                        .order(:name)

      filepath_info = build_filepath_info_from_matrix_annots(all_annots)

      @available_loom_files = filepath_info.keys.sort_by do |filepath|
        info = filepath_info[filepath]
        [info[:step_rank] || 9999, info[:run_id] || 999999]
      end
      @filepath_info = filepath_info
      run_ids = filepath_info.values.map { |info| info[:run_id] }.compact.uniq
      @loom_file_runs = Run.where(id: run_ids).includes(:step, :std_method).index_by(&:id) if run_ids.any?
      @loom_file_runs ||= {}
      @selected_loom_file = params[:loom_file].presence || @available_loom_files.first

      @annots_by_loom_and_type = {}
      @matrix_dims_by_loom = {}
      @available_loom_files.each do |filepath|
        @annots_by_loom_and_type[filepath] = { matrices: [], col_attrs: [], row_attrs: [], global: [] }
        file_annots = all_annots.select { |a| a.filepath == filepath }
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

      @selected_data_type = params[:data_type].presence || 'matrices'

      if @selected_loom_file.present? && @selected_data_type == 'global'
        load_global_attr_card_values!(
          @selected_loom_file,
          @annots_by_loom_and_type[@selected_loom_file]&.dig(:global) || []
        )
      end
    end

    # Short plain /attrs/* values for Global Metadata cards in the data view.
    # Skips JSON payloads and long strings; avoids per-attr docker calls via one batch read.
    GLOBAL_ATTR_CARD_MAX_CHARS = 200
    GLOBAL_ATTR_CARD_MAX_MEM = 1024

    def load_global_attr_card_values!(loom_filepath, global_annots)
      @global_attr_card_values = {}
      return if loom_filepath.blank?

      candidates = Array(global_annots).select { |annot| global_attr_card_value_candidate?(annot) }
      return if candidates.empty?

      user_data_dir = ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s
      loom_path = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key + loom_filepath
      return unless File.exist?(loom_path)

      @global_attr_card_values = H5DataService.read_short_global_attr_strings(
        loom_path.to_s,
        candidates.map(&:name),
        max_chars: GLOBAL_ATTR_CARD_MAX_CHARS
      )
    rescue StandardError => e
      Rails.logger.error("[load_global_attr_card_values!] #{e.class}: #{e.message}")
      @global_attr_card_values = {}
    end

    def global_attr_card_value_candidate?(annot)
      return false if annot.blank?
      return false unless annot.name.to_s.start_with?('/attrs/')
      return false if annot.nber_rows.to_i > 1
      return false unless annot.nber_cols.to_i <= 1 || annot.dim.to_i == 4

      mem = annot.mem_size.to_i
      return false if mem.positive? && mem > GLOBAL_ATTR_CARD_MAX_MEM

      true
    end

    # Build filepath metadata from /matrix annotations only, so each loom file
    # points to the run that produced its expression matrix.
    def build_filepath_info_from_matrix_annots(all_annots)
      filepath_info = {}

      all_annots.each do |annot|
        next unless annot.filepath.present?
        next unless annot.name == '/matrix'

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
          should_update = true if current_step_rank < existing_step_rank
          should_update = true if current_step_rank == existing_step_rank && current_run_id < existing_run_id
          if should_update
            existing[:step_rank] = step_rank
            existing[:run_id] = run_id
          end
        else
          filepath_info[filepath] = { step_rank: step_rank, run_id: run_id }
        end
      end

      filepath_info
    end

    def load_settings_context
      @shares = @project.shares.includes(:user).to_a
      @project_types = selectable_project_types if @project.project_type_id.nil? && @project.version_id.to_i < 8
    end

    # Assign / clear / create umbrella collection for this project (one collection max).
    # Admin: any collection + metadata. Owner: clear, create manual, or assign to own manuals only.
    def apply_project_collection_assignment!
      return unless params.key?(:project_collection_assignment)

      assignment = params.require(:project_collection_assignment).permit(
        :mode, :project_collection_id, :title, :description
      )
      mode = assignment[:mode].to_s.strip
      case mode
      when 'none', ''
        @project.project_collection_id = nil
      when 'existing'
        collection_id = assignment[:project_collection_id].to_i
        raise ArgumentError, 'Select a collection' if collection_id <= 0

        collection = ProjectCollection.find(collection_id)
        authorize_project_collection_assignment!(collection, editing_metadata: true)

        updates = {}
        if assignment.key?(:title)
          title = assignment[:title].to_s.strip
          raise ArgumentError, 'Collection title is required' if title.blank?

          updates[:title] = title
        end
        if assignment.key?(:description)
          updates[:description] = assignment[:description].to_s.presence
        end

        if updates.any? && (admin? || collection.owned_by?(current_user))
          collection.update!(updates)
        end
        @project.project_collection_id = collection.id
      when 'new'
        unless admin? || owner?(@project)
          raise ArgumentError, 'Only the project owner or an admin can create a collection'
        end

        title = assignment[:title].to_s.strip
        raise ArgumentError, 'Collection title is required' if title.blank?

        collection = ProjectCollection.create_manual!(
          title: title,
          description: assignment[:description],
          created_by_user: current_user
        )
        @project.project_collection_id = collection.id
      else
        raise ArgumentError, "Unknown collection assignment mode: #{mode}"
      end
      @project.save!
    end

    def authorize_project_collection_assignment!(collection, editing_metadata: false)
      return if admin?
      raise ArgumentError, 'Only the project owner or an admin can change collection membership' unless owner?(@project)

      if collection.catalog_backed?
        raise ArgumentError, 'Catalog collections can only be managed by an admin. Clear membership or create your own collection.'
      end
      unless collection.owned_by?(current_user)
        raise ArgumentError, 'You can only assign this project to a collection you created'
      end
    end

    def can_manage_project_collection?(collection)
      return false unless collection && editable?(@project)
      return true if admin?

      owner?(@project) && !collection.catalog_backed? && collection.owned_by?(current_user)
    end

    def summary_collection_project_payload(project, current: false)
      {
        id: project.id,
        name: project.display_name,
        key: project.key,
        public_id: project.public? ? project.public_id : nil,
        url: project_path(project, view: 'summary'),
        current: current
      }
    end

    def load_compliance_context
      if params[:validation_id].present?
        cv = ComplianceValidation.find_by(id: params[:validation_id], project_id: @project.id)
        @validation_result = cv&.result_data
        @viewing_historical = cv if @validation_result
      end
      @validation_result ||= load_validation_result(@project)

      @compliance_check_groups = resolve_compliance_check_groups(@validation_result) if @validation_result.present?
    end

    def load_annotations_context
      @annotations_can_export = owner?(@project)
      @annotations_default_scope = 'current'
      related = CloneRelatedProjectsQuery.call(
        project: @project,
        scope: @annotations_default_scope,
        user: current_user,
        readable_if: ->(project) { readable?(project) }
      )
      @annotations_related_projects = related[:ok] ? related[:projects] : [{ id: @project.id, key: @project.key, name: @project.name.presence || @project.key, is_current: true }]
      federated = FederatedAnnotationsQuery.call(
        project_ids: @annotations_related_projects.map { |row| row[:id] },
        readable_if: ->(project) { readable?(project) },
        current_project: @project
      )
      @annotations_payload = if federated[:ok]
                               federated
                             else
                               {
                                 annotations: [],
                                 annotation_type_options: [],
                                 annotation_metadata_by_type: {},
                                 consensus_metadata_by_type: {}
                               }
                             end
      support = ConsensusAnnotationSupportService.call(
        project: @project,
        user: current_user,
        readable_if: ->(project) { readable?(project) }
      )
      @annotations_consensus_support = support[:ok] ? support[:by_type] : {}
    end

    def load_summary_context
      @h_identifier_types = IdentifierType.all.index_by(&:id)
      @h_exp_entries = {}
      @project.exp_entries.includes(:identifier_type).each do |exp_entry|
        type_id = exp_entry.identifier_type_id
        @h_exp_entries[type_id] ||= []
        @h_exp_entries[type_id] << exp_entry
      end

      @h_articles = {}
      if @project.doi.present?
        dois = @project.doi.split(/\s*,\s*/).map(&:strip).reject(&:blank?)
        Article.where(doi: dois).each { |article| @h_articles[article.doi] = article } if dois.any?
      end

      @project_type = @project.project_type
      # Prefetch for the Source repository links card (collection title + provider URL)
      # and the optional ASAP collection card (details + sibling projects).
      assign_summary_collection_context!

      # One CLA load for counts, gene/ontology resolution, and the summary table.
      @summary_cla_records = Cla.active.where(project_id: @project.id)
                                .includes(:annot, :cell_set, :user, :cla_source, :ontology_term_type)
                                .order(created_at: :desc)
                                .to_a

      compute_summary_loom_overview(cla_records: @summary_cla_records)

      required_gene_ids = @summary_cla_records.flat_map do |cla|
        [
          parse_cla_field(cla.sorted_up_gene_ids.presence || cla.up_gene_ids),
          parse_cla_field(cla.sorted_down_gene_ids.presence || cla.down_gene_ids)
        ]
      end.flatten.map { |value| value.to_s.strip }.reject(&:blank?).uniq

      @summary_gene_info_by_stable_id = project_cla_gene_info_by_stable_id(@project, required_ids: required_gene_ids)
      @summary_gene_symbol_by_id = @summary_gene_info_by_stable_id.transform_values { |info| info[:symbol] }
      @summary_cot_info_by_id = build_summary_cot_info_map(cla_records: @summary_cla_records)
      @summary_cot_label_by_id = @summary_cot_info_by_id.transform_values { |info| info[:name].presence || info[:identifier] }

      assign_summary_submitted_file_link!
      assign_summary_scfair_metadata_context!
    end

    def assign_summary_scfair_metadata_context!
      @summary_scfair_metadata_cards = []
      validation = @project.cxg_validation_result
      return unless validation.present?
      return unless validation['valid'] == true || validation[:valid] == true

      ott_by_field_group = OntologyTermType.compliance_field_groups.index_by(&:field_group_id)
      @summary_scfair_metadata_cards = Scfair::SummaryMetadataCardsBuilder.call(
        validation_result: validation,
        ontology_term_types_by_field_group_id: ott_by_field_group
      )
    end

    def assign_summary_collection_context!
      @summary_collection = nil
      @summary_collection_projects = []
      @summary_collection_resource_links = []
      return if @project.project_collection_id.blank?

      @summary_collection = @project.project_collection
      return unless @summary_collection

      @summary_collection_projects = @summary_collection.projects
        .not_deleted
        .includes(:shares, :project_type, :organism)
        .order(Arel.sql("LOWER(COALESCE(name, '')) ASC"), :id)
        .to_a
        .select { |project| readable?(project) }

      @summary_collection_resource_links = summary_collection_resource_links_for(@project, @summary_collection)
    end

    # Distinct catalog/manual collection pages that present this project, keyed by source+url.
    # First entry is the project's primary ProjectCollection when it has a resolvable URL.
    def summary_collection_resource_links_for(project, primary_collection)
      links_by_key = {}

      add_link = lambda do |source, url|
        source = source.to_s
        url = url.to_s.presence
        return if source.blank? || url.blank?

        key = "#{source}|#{url}"
        links_by_key[key] ||= {
          source: source,
          url: url,
          label: ProjectCollection.source_label_for(source)
        }
      end

      if primary_collection
        add_link.call(primary_collection.source, primary_collection.resolved_source_page_url)
      end

      candidates = []
      candidates.concat(project.external_catalog_candidates.to_a)
      candidates.concat(project.matched_external_catalog_candidates.includes(:external_catalog_collection).to_a)
      project.provider_projects.includes(:provider).each do |pp|
        tag = pp.provider&.tag
        next if tag.blank? || pp.key.blank?

        candidates.concat(ExternalCatalogCandidate.where(provider_tag: tag, external_id: pp.key.to_s).to_a)
      end
      candidates.uniq!(&:id)

      candidates.each do |candidate|
        collection_id = candidate.collection_id.to_s.strip
        next if collection_id.blank?

        ecc = candidate.external_catalog_collection
        url = ecc&.source_page_url.presence ||
              ProjectCollection.catalog_collection_url(candidate.source, collection_id)
        add_link.call(candidate.source, url)
      end

      links = links_by_key.values
      primary_source = primary_collection&.source.to_s
      if primary_source.present?
        links.sort_by! { |link| link[:source] == primary_source ? 0 : 1 }
      end
      links
    end

    def dna_accessibility_download_entries(server_url)
      parsing_dir = @project.data_dir.join('parsing')
      DnaAccessibilityFinalizeService.download_assets(parsing_dir).map do |asset|
        {
          name: asset[:rel_path],
          label: asset[:label],
          file_size: asset[:present] ? helpers.display_mem(asset[:size]) : nil,
          present: asset[:present],
          url: "#{server_url}#{get_file_project_path(@project.key, filename: asset[:rel_path])}"
        }
      end
    end

    def summary_project_data_root(project)
      return unless project&.user_id.present?

      user_data_dir = ENV["USER_DATA_DIR"].to_s.chomp("/")
      return if user_data_dir.blank?

      base = user_data_dir.end_with?("/users") || user_data_dir.end_with?("users") ? Pathname.new(user_data_dir) : Pathname.new(user_data_dir) + "users"
      base + project.user_id.to_s + project.key
    end

    def assign_summary_submitted_file_link!
      @summary_show_submitted_file_link = false
      @summary_input_file_get_file_query_param = nil
      return unless exportable?(@project) && @project.fu_id.present?

      fu = Fu.find_by(id: @project.fu_id)
      return unless fu

      expected, = ProjectInputFinalizerService.canonical_input_filename_parts(fu.upload_file_name)

      basename =
        if @project.filesystem_project_data_missing?
          # Archived/missing data: rely on the canonical filename derived from
          # the Fu record. The summary view still surfaces the button (in a
          # disabled state) so the user can see the link exists, and it will
          # work transparently once the project has been unarchived.
          expected
        else
          fus_dir = nil
          project_dir = summary_project_data_root(@project)
          if project_dir && Dir.exist?(project_dir.to_s)
            candidate_dir = project_dir + "fus" + fu.id.to_s
            fus_dir = candidate_dir if Dir.exist?(candidate_dir.to_s)
          end

          if fus_dir
            expected_path = fus_dir + expected
            if File.file?(expected_path.to_s) || File.symlink?(expected_path.to_s)
              expected
            else
              candidates = Dir.children(fus_dir.to_s).select do |name|
                next false if name.include?("/") || name.start_with?(".")
                p = fus_dir + name
                next false unless File.file?(p.to_s) || File.symlink?(p.to_s)
                name == "input_file" || (name.start_with?("input_file.") && name.length > "input_file.".length)
              end
              candidates.max_by { |n| [n.length, n] }
            end
          end
        end
      return if basename.blank?

      @summary_input_file_get_file_query_param = "fus/#{fu.id}/#{basename}"
      @summary_show_submitted_file_link = true
    end

    def get_file_path_within_project_root?(project_root, filepath)
      root = Pathname.new(project_root.to_s).expand_path
      fp = Pathname.new(filepath.to_s).expand_path
      root_s = root.to_s
      fp_s = fp.to_s
      fp_s.start_with?(root_s + File::SEPARATOR) || fp_s == root_s
    end

    # Rebuild /attrs/analysis_pipeline and /attrs/anndata_mapping on the loom sibling before serving loom or converting to h5ad.
    def ensure_analysis_json_before_download!(project_root, filepath)
      abs = Pathname.new(filepath.to_s).expand_path
      root = Pathname.new(project_root.to_s).expand_path
      rel = abs.relative_path_from(root).to_s
      loom_rel = rel.sub(/\.h5ad\z/i, '.loom')
      return unless loom_rel.end_with?('.loom')

      loom_abs = root + loom_rel
      return unless File.exist?(loom_abs)

      result = AnalysisJsonPersistService.call(project: @project, loom_filepath: loom_rel)
      Rails.logger.info(
        "get_file: updated analysis_pipeline on #{loom_rel} " \
        "(annot_id=#{result[:annot_id]}, steps=#{result[:nber_steps]})"
      )
      mapping = Basic.refresh_anndata_mapping_for_loom(Rails.logger, @project, loom_rel)
      Rails.logger.info(
        "get_file: updated anndata_mapping on #{loom_rel} " \
        "(annot_id=#{mapping[:annot_id]}, x_path=#{mapping[:x_path]})"
      )
    end

    def compute_summary_loom_overview(cla_records: nil)
      @summary_loom_file_count = 0
      @summary_loom_content_counts = { matrices: 0, col_attrs: 0, row_attrs: 0, global: 0 }
      @summary_shared_users_count = @project.shares.count
      # Do not use Annot.light here: its multi-column select makes .count emit
      # COUNT(col1, col2, ...) which PostgreSQL rejects.
      embedding_scope = apply_publication_snapshot_to_annots(Annot.where(project_id: @project.id, nber_rows: 2))
      @summary_embedding_count = embedding_scope.count
      @summary_run_user_count = apply_publication_snapshot_to_runs(@project.runs)
                                 .where.not(user_id: nil)
                                 .distinct
                                 .count(:user_id)

      active_clas = cla_records
      active_clas = Cla.active.where(project_id: @project.id).to_a if active_clas.nil?
      @summary_visual_annotation_count = active_clas.size
      @summary_visual_vote_count = Cla.where(project_id: @project.id)
                                      .sum(Arel.sql('COALESCE(nber_agree, 0) + COALESCE(nber_disagree, 0)'))

      checkpoint_comments_json = @project.checkpoints.pluck(:comments_json)
      @summary_checkpoint_count = checkpoint_comments_json.size
      @summary_checkpoint_comment_count = checkpoint_comments_json.sum do |raw|
        Array(Basic.safe_parse_json(raw, [])).size
      end

      summary_annots = apply_publication_snapshot_to_annots(
        Annot.light.where(project_id: @project.id).where.not(filepath: [nil, ''])
      ).pluck(:filepath, :name, :dim)
      return if summary_annots.empty?

      @summary_loom_file_count = summary_annots.map(&:first).uniq.size
      summary_annots.each do |_filepath, name, dim|
        annot_name = name.to_s
        if annot_name == '/matrix' || (dim == 3 && annot_name.start_with?('/layers/'))
          @summary_loom_content_counts[:matrices] += 1
        elsif annot_name.start_with?('/col_attrs/')
          @summary_loom_content_counts[:col_attrs] += 1
        elsif annot_name.start_with?('/row_attrs/')
          @summary_loom_content_counts[:row_attrs] += 1
        else
          @summary_loom_content_counts[:global] += 1
        end
      end
    end

    def parsing_step_for_project(project)
      return nil unless project&.version
      asap_docker_image = Basic.get_asap_docker(project.version)
      return nil unless asap_docker_image
      Step.find_by(docker_image_id: asap_docker_image.id, version_id: project.version_id, name: 'parsing')
    end

    def redirect_analysis_to_parsing_step_if_integration_in_progress!
      return unless request.get?
      return unless request.format.html?
      return if params[:step_id].present?
      return unless @project.integration_in_progress?

      parsing_step = parsing_step_for_project(@project)
      return unless parsing_step

      redirect_to project_path(@project, view: 'analysis', step_id: parsing_step.id), status: :see_other
    end

    def step_scope_for_project(project)
      return Step.none unless project&.version
      asap_docker_image = Basic.get_asap_docker(project.version)
      return Step.none unless asap_docker_image

      Step.where(docker_image_id: asap_docker_image.id, version_id: project.version_id)
    end

    def std_method_scope_for_project(project)
      return StdMethod.none unless project&.version
      asap_docker_image = Basic.get_asap_docker(project.version)
      return StdMethod.none unless asap_docker_image

      StdMethod.where(docker_image_id: asap_docker_image.id, version_id: project.version_id)
    end

    def selection_cache_storage_key
      user_part = current_user&.id || 'anon'
      "selection_cache/project_#{@project.id}/user_#{user_part}"
    end

    def selection_session_cache
      cached = Rails.cache.read(selection_cache_storage_key)
      cache_data = cached.is_a?(Hash) ? cached.deep_dup : {}

      # One-time migration away from cookie session storage (avoids CookieOverflow).
      legacy_root = session[:selection_cache]
      legacy = legacy_root.is_a?(Hash) ? legacy_root[@project.id.to_s] : nil
      if legacy.is_a?(Hash) && legacy.any?
        cache_data = cache_data.merge(legacy)
        write_selection_session_cache(cache_data)
        legacy_root.delete(@project.id.to_s)
        session.delete(:selection_cache) if legacy_root.empty?
      end

      cache_data
    end

    def write_selection_session_cache(cache_data)
      payload = cache_data.is_a?(Hash) ? cache_data : {}
      Rails.cache.write(selection_cache_storage_key, payload, expires_in: 24.hours)
      # Ensure oversized selection payloads are not kept in the cookie session.
      if session[:selection_cache].is_a?(Hash)
        session[:selection_cache].delete(@project.id.to_s)
        session.delete(:selection_cache) if session[:selection_cache].empty?
      end
    end

    def remove_selection_from_cache_by_id(selection_id)
      cache_data = selection_session_cache
      cache_key, = cache_data.find do |key, entry|
        entry_id = entry['id'] || entry[:id] || key
        entry_id.to_s == selection_id.to_s
      end
      return false unless cache_key

      cache_data.delete(cache_key)
      write_selection_session_cache(cache_data)
      true
    end

    def cleanup_selection_cache_for_run_id(run_id)
      cache_data = selection_session_cache
      keys_to_remove = cache_data.keys.select do |key|
        entry = cache_data[key]
        (entry['run_id'] || entry[:run_id]).to_i == run_id.to_i
      end
      return if keys_to_remove.empty?

      keys_to_remove.each { |key| cache_data.delete(key) }
      write_selection_session_cache(cache_data)
    end

    def broadcast_selection_states_changed(loom_file: nil, reason: nil)
      return unless @project&.id

      ActionCable.server.broadcast(
        "project_#{@project.id}",
        {
          event: 'selection_states_changed',
          loom_file: loom_file.to_s,
          reason: reason.to_s
        }
      )
    rescue StandardError => e
      Rails.logger.warn("broadcast_selection_states_changed failed: #{e.class} - #{e.message}")
    end

    def selection_cache_items_for_loom(loom_file = nil, cleanup_completed: false)
      cache_data = selection_session_cache
      items = []
      to_remove = []

      cache_data.each do |key, entry|
        entry_loom_file = entry['loom_file'] || entry[:loom_file]
        next if loom_file.present? && entry_loom_file.to_s != loom_file.to_s

        run_id = (entry['run_id'] || entry[:run_id]).to_i
        run = @project.runs.find_by(id: run_id)
        status_id = run&.status_id
        status = case status_id
                 when 2 then 'running'
                 when 3 then 'completed'
                 when 4 then 'failed'
                 else 'queued'
                 end

        if status == 'completed'
          to_remove << key if cleanup_completed
          next
        end

        run_attrs = Basic.safe_parse_json(run&.attrs_json, {})
        items << {
          id: entry['id'] || entry[:id] || key,
          run_id: run_id,
          metadata_id: nil,
          name: entry['name'] || entry[:name],
          selected_count: (entry['selected_count'] || entry[:selected_count]).to_i,
          status: status,
          created_at: entry['created_at'] || entry[:created_at],
          loom_file: entry_loom_file,
          unselected_name: entry['unselected_name'] || entry[:unselected_name],
          selection_source: (entry['selection_source'] || entry[:selection_source] || run_attrs['selection_source'] || run_attrs[:selection_source] || 'lasso'),
          compose_steps: sanitize_compose_steps(entry['compose_steps'] || entry[:compose_steps]) || sanitize_compose_steps(run_attrs['compose_steps']),
          filter_components: sanitize_filter_components(entry['filter_components'] || entry[:filter_components]) || sanitize_filter_components(run_attrs['filter_components']),
          plot_context: selection_plot_context_with_heatmap_params(
            entry['plot_context'] || entry[:plot_context] || run_attrs['plot_context'],
            run_attrs
          ),
          selection_number: begin
            from_entry = entry['selection_number'] || entry[:selection_number]
            if from_entry.present?
              from_entry.to_i
            else
              selection_number_from_metadata_name(run_attrs['selection_metadata_name'] || run_attrs[:selection_metadata_name])
            end
          end,
          locked: immutable_since_publication?(run)
        }
      end

      if cleanup_completed && to_remove.any?
        to_remove.each { |key| cache_data.delete(key) }
        write_selection_session_cache(cache_data)
      end

      items
    end

    def selection_items_from_annots(loom_file = nil)
      scope = Annot.light.where(project_id: @project.id, dim: 1)
      scope = scope.where(filepath: loom_file) if loom_file.present?
      scope = scope.where("name LIKE ?", "%.sel_%")
      annots = scope.order(created_at: :desc).to_a
      run_attrs_by_run_id = {}
      run_ids = annots.map(&:run_id).compact.uniq
      if run_ids.any?
        Run.where(id: run_ids).pluck(:id, :attrs_json).each do |run_id, attrs_json|
          run_attrs_by_run_id[run_id] = Basic.safe_parse_json(attrs_json, {})
        end
      end

      annots.map do |annot|
        run_attrs = run_attrs_by_run_id[annot.run_id] || {}
        selected_name = (run_attrs['selected_name'] || '').to_s
        unselected_name = 'Not selected'
        if annot.cat_aliases_json.present?
          aliases = Basic.safe_parse_json(annot.cat_aliases_json, {})
          alias_selected_name = aliases.dig('names', '1')
          if selected_name.blank? && alias_selected_name != nil
            normalized_alias_name = alias_selected_name.to_s.strip
            selected_name = normalized_alias_name unless ['selected', 'selection'].include?(normalized_alias_name.downcase)
          end
          unselected_name = aliases.dig('names', '0').presence || unselected_name
        end

        selected_count = selection_selected_count_from_categories_json(annot.categories_json)

        {
          id: "annot-#{annot.id}",
          run_id: annot.run_id,
          metadata_id: annot.id,
          name: selected_name,
          selected_count: selected_count,
          status: 'completed',
          created_at: annot.created_at&.iso8601,
          loom_file: annot.filepath,
          unselected_name: unselected_name,
          selection_source: begin
            from_annot = Basic.safe_parse_json(annot.attrs_json, {})['selection_source']
            from_annot.presence || run_attrs_by_run_id.dig(annot.run_id, 'selection_source') || 'lasso'
          end,
          compose_steps: begin
            from_annot = sanitize_compose_steps(Basic.safe_parse_json(annot.attrs_json, {})['compose_steps'])
            from_annot.presence || sanitize_compose_steps(run_attrs_by_run_id.dig(annot.run_id, 'compose_steps'))
          end,
          filter_components: begin
            from_annot = sanitize_filter_components(Basic.safe_parse_json(annot.attrs_json, {})['filter_components'])
            from_annot.presence || sanitize_filter_components(run_attrs_by_run_id.dig(annot.run_id, 'filter_components'))
          end,
          plot_context: begin
            from_annot = Basic.safe_parse_json(annot.attrs_json, {})['plot_context']
            selection_plot_context_with_heatmap_params(
              from_annot.presence || run_attrs_by_run_id.dig(annot.run_id, 'plot_context'),
              run_attrs_by_run_id[annot.run_id] || {}
            )
          end,
          selection_number: selection_number_from_metadata_name(annot.name),
          locked: immutable_since_publication?(annot)
        }
      end
    end

    def immutable_since_publication?(record)
      return false unless @project
      @project.locked_from_publication?(record)
    end

    def selection_number_from_metadata_name(metadata_name)
      return nil if metadata_name.blank?
      match = metadata_name.to_s.match(/\.sel_(\d+)$/)
      match ? match[1].to_i : nil
    end

    def selection_selected_count_from_categories_json(categories_json)
      return nil if categories_json.blank?

      categories = Basic.safe_parse_json(categories_json, nil)
      return nil if categories.blank?

      if categories.is_a?(Array)
        return selection_selected_count_from_entry(categories[1])
      end

      if categories.is_a?(Hash)
        direct = categories['1'] || categories[1] || categories[:'1']
        direct_count = selection_selected_count_from_entry(direct)
        return direct_count unless direct_count.nil?

        counts = categories['counts'] || categories[:counts]
        if counts.is_a?(Array)
          return selection_selected_count_from_entry(counts[1])
        elsif counts.is_a?(Hash)
          return selection_selected_count_from_entry(counts['1'] || counts[1] || counts[:'1'])
        end
      end

      nil
    end

    def selection_selected_count_from_entry(entry)
      return nil if entry.nil?
      return entry.to_i if entry.is_a?(Numeric)

      if entry.is_a?(String)
        stripped = entry.strip
        return nil if stripped.blank?
        return stripped.to_i if stripped.match?(/\A\d+\z/)
        return nil
      end

      if entry.is_a?(Hash)
        %w[count n nber value size total].each do |key|
          value = entry[key] || entry[key.to_sym]
          next if value.nil?
          return value.to_i if value.is_a?(Numeric)
          return value.to_i if value.is_a?(String) && value.strip.match?(/\A\d+\z/)
        end
      end

      nil
    end

    def consensus_metadata_labels_would_change?(annot, loom_file, new_labels)
      return true unless new_labels.is_a?(Array)

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
      loom_path = project_dir + (loom_file.presence || annot.filepath).to_s
      return true unless File.exist?(loom_path)

      existing = H5DataService.get_metadata_vector(loom_path.to_s, annot.name.to_s)
      return true unless existing.is_a?(Array)
      return true unless existing.length == new_labels.length

      !existing.each_with_index.all? { |value, idx| value.to_s == new_labels[idx].to_s }
    rescue StandardError => e
      Rails.logger.warn("[consensus_metadata_labels_would_change?] Annot##{annot.id}: #{e.message}")
      true
    end

    def sanitize_compose_steps(raw_steps)
      return nil unless raw_steps.is_a?(Array)

      normalized = raw_steps.map do |step|
        step_hash = normalize_selection_nested_hash(step)
        next unless step_hash.is_a?(Hash)
        step_index = step_hash['step_index'] || step_hash[:step_index]
        operation = step_hash['operation'] || step_hash[:operation]
        operand_a = step_hash['operand_a'] || step_hash[:operand_a]
        operand_b = step_hash['operand_b'] || step_hash[:operand_b]
        result_count = step_hash['result_count'] || step_hash[:result_count]
        next unless step_index.present? && operation.present?

        payload = {
          step_index: step_index.to_i,
          operation: operation.to_s,
          operand_a: operand_a.to_s,
          operand_b: operand_b.to_s,
          result_count: result_count.to_i
        }
        payload.merge!(sanitize_compose_operand_identity_fields(step_hash, 'operand_a'))
        payload.merge!(sanitize_compose_operand_identity_fields(step_hash, 'operand_b'))
        payload
      end.compact

      normalized.any? ? normalized : nil
    end

    def normalize_batch_compose_basename(raw_name)
      basename = raw_name.to_s.strip
      basename = basename.sub(%r{\A/col_attrs/}, '')
      # Allow '.' as structural separators; '=' / '()' inside the operand field.
      basename = basename.gsub(/[^\w.\-=()]+/, '_').gsub(/_+/, '_').gsub(/\A[._=]+|[._=]+\z/, '')
      return '' if basename.blank?

      basename = "#{basename}.batch_compose" unless basename.end_with?('.batch_compose')
      basename
    end

    def suggest_batch_compose_rename_basename(canonical_basename)
      base = canonical_basename.to_s.sub(/\.batch_compose\z/, '')
      base = 'batch_compose_previous' if base.blank?
      # Keep a free name ending in .batch_compose; prefer inserting _previous on the operand field.
      if (m = base.match(/\A([^.]+)\.with\.(.+)\z/))
        candidate = normalize_batch_compose_basename("#{m[1]}.with.#{m[2]}_previous")
      else
        candidate = normalize_batch_compose_basename("#{base.gsub('.', '_')}_previous")
      end
      n = 2
      while @project.annots.exists?(name: "/col_attrs/#{candidate}")
        if (m = base.match(/\A([^.]+)\.with\.(.+)\z/))
          candidate = normalize_batch_compose_basename("#{m[1]}.with.#{m[2]}_previous#{n}")
        else
          candidate = normalize_batch_compose_basename("#{base.gsub('.', '_')}_previous#{n}")
        end
        n += 1
      end
      candidate
    end

    def sanitize_compose_operand_identity_fields(step_hash, prefix)
      return {} unless step_hash.is_a?(Hash) && prefix.present?

      metadata_name = step_hash["#{prefix}_metadata_name"] || step_hash[:"#{prefix}_metadata_name"]
      category_name = step_hash["#{prefix}_category_name"] || step_hash[:"#{prefix}_category_name"]
      annot_id = step_hash["#{prefix}_annot_id"] || step_hash[:"#{prefix}_annot_id"]
      cat_idx = if step_hash.key?("#{prefix}_cat_idx")
                  step_hash["#{prefix}_cat_idx"]
                elsif step_hash.key?(:"#{prefix}_cat_idx")
                  step_hash[:"#{prefix}_cat_idx"]
                end

      out = {}
      out[:"#{prefix}_metadata_name"] = metadata_name.to_s if metadata_name.present?
      out[:"#{prefix}_category_name"] = category_name.to_s if category_name.present?
      if annot_id.present?
        annot_id_i = annot_id.to_i
        out[:"#{prefix}_annot_id"] = annot_id_i if annot_id_i.positive?
      end
      unless cat_idx.nil? || cat_idx.to_s.strip == ''
        cat_idx_i = cat_idx.to_i
        out[:"#{prefix}_cat_idx"] = cat_idx_i if cat_idx_i >= 0
      end
      out
    end

    def sanitize_selection_source(raw_source)
      source = raw_source.to_s.strip
      return source if %w[visible lasso compose heatmap-rect].include?(source)
      'lasso'
    end

    def sanitize_plot_context(raw_context)
      context = normalize_selection_nested_hash(raw_context)
      return nil unless context.is_a?(Hash)

      plot = (context['plot'] || context[:plot]).to_s.strip.downcase
      return nil unless %w[main secondary heatmap].include?(plot)

      if plot == 'secondary'
        plot_type = (context['plot_type'] || context[:plot_type]).to_s.strip.downcase
        plot_type = 'scatter' unless %w[scatter violin].include?(plot_type)
        x_axis = sanitize_plot_axis(context['x_axis'] || context[:x_axis])
        y_axis = sanitize_plot_axis(context['y_axis'] || context[:y_axis])
        x_scale = sanitize_plot_scale(context['x_scale'] || context[:x_scale])
        y_scale = sanitize_plot_scale(context['y_scale'] || context[:y_scale])
        {
          plot: 'secondary',
          plot_type: plot_type,
          x_axis: x_axis,
          y_axis: y_axis,
          x_scale: x_scale,
          y_scale: y_scale
        }
      elsif plot == 'heatmap'
        heatmap_raw = normalize_selection_nested_hash(context['heatmap'] || context[:heatmap]) || {}
        run_id = (heatmap_raw['run_id'] || heatmap_raw[:run_id]).to_i
        parameters = sanitize_heatmap_parameters(heatmap_raw['parameters'] || heatmap_raw[:parameters])
        {
          plot: 'heatmap',
          heatmap: {
            run_id: run_id > 0 ? run_id : nil,
            run_num: (heatmap_raw['run_num'] || heatmap_raw[:run_num]).to_s,
            method_label: (heatmap_raw['method_label'] || heatmap_raw[:method_label]).to_s,
            loom_file: (heatmap_raw['loom_file'] || heatmap_raw[:loom_file]).to_s,
            parameters: parameters
          }.compact
        }
      else
        embedding_raw = normalize_selection_nested_hash(context['embedding'] || context[:embedding]) || {}
        axes_raw = normalize_selection_nested_hash(context['axes'] || context[:axes]) || {}
        {
          plot: 'main',
          embedding: {
            id: (embedding_raw['id'] || embedding_raw[:id]).to_s,
            name: (embedding_raw['name'] || embedding_raw[:name]).to_s,
            origin: (embedding_raw['origin'] || embedding_raw[:origin]).to_s,
            loom_file: (embedding_raw['loom_file'] || embedding_raw[:loom_file]).to_s
          },
          axes: {
            x: (axes_raw['x'] || axes_raw[:x]).presence || 'Dimension 1',
            y: (axes_raw['y'] || axes_raw[:y]).presence || 'Dimension 2'
          }
        }
      end
    end

    def sanitize_plot_axis(raw_axis)
      axis = normalize_selection_nested_hash(raw_axis) || {}
      {
        name: (axis['name'] || axis[:name]).to_s,
        metadata_id: (axis['metadata_id'] || axis[:metadata_id]).to_s,
        is_gene: ActiveModel::Type::Boolean.new.cast(axis['is_gene'] || axis[:is_gene]) == true
      }
    end

    def sanitize_plot_scale(raw_scale)
      scale = raw_scale.to_s.strip.downcase
      return scale if %w[normal log2 log10].include?(scale)
      'normal'
    end

    def sanitize_heatmap_parameters(raw_parameters)
      Array(raw_parameters).filter_map do |entry|
        row = normalize_selection_nested_hash(entry)
        next unless row.is_a?(Hash)

        label = (row['label'] || row[:label] || row['key'] || row[:key]).to_s.strip
        value = (row['value'] || row[:value]).to_s.strip
        next if label.blank? && value.blank?

        {
          label: label.presence || 'Parameter',
          value: value
        }
      end.first(50)
    end

    def enrich_heatmap_plot_context(plot_context, heatmap_run_id: nil)
      context = sanitize_plot_context(plot_context)
      return context unless context.is_a?(Hash) && context[:plot] == 'heatmap'

      heatmap = (context[:heatmap] || {}).dup
      run_id = heatmap_run_id.to_i
      run_id = heatmap[:run_id].to_i if run_id <= 0
      return context unless run_id > 0

      run = @project.runs.find_by(id: run_id)
      return context unless run

      heatmap[:run_id] = run.id
      heatmap[:run_num] = run.num.to_s if heatmap[:run_num].to_s.blank? && run.num.present?
      if heatmap[:method_label].to_s.blank?
        std_method = run.std_method
        heatmap[:method_label] = std_method&.label.presence || std_method&.name.presence || 'Heatmap'
      end
      if heatmap[:loom_file].to_s.blank?
        loom = heatmap_loom_file_for_run(run)
        heatmap[:loom_file] = loom.to_s if loom.present?
      end
      existing_parameters = Array(heatmap[:parameters])
      heatmap[:parameters] = heatmap_run_parameter_pairs(run) if existing_parameters.blank?

      context.merge(heatmap: heatmap.compact)
    end

    def heatmap_run_parameter_pairs(run)
      return [] unless run

      h_attrs = Basic.safe_parse_json(run.attrs_json, {})
      return [] unless h_attrs.is_a?(Hash)

      std_method = run.std_method
      step = run.step
      method_map = if std_method && step
                     Basic.get_std_method_attrs(std_method, step)[:h_attrs] || {}
                   elsif std_method
                     Basic.safe_parse_json(std_method.attrs_json, {})
                   else
                     {}
                   end
      method_map = {} unless method_map.is_a?(Hash)

      helpers.preload_gene_set_display_labels!(
        @project,
        collection_ids: [h_attrs['global_gene_set_collection_id'], h_attrs['gene_set_id']].compact,
        item_ids: [h_attrs['global_gene_set_item_id']].compact
      )

      h_steps = Step.where(id: @project.runs.select(:step_id)).index_by(&:id)
      attr_keys = helpers.prepare_run_attr_keys_for_display(run, h_attrs, method_map, [], false)
      pairs = []

      attr_keys.each do |attr|
        composite_cfg = helpers.run_display_composite_config(attr, method_map, h_attrs)
        if composite_cfg
          txt = helpers.composite_run_param_txt(h_attrs, composite_cfg)
          next if txt.blank?
          label, value = txt.split(':', 2)
          pairs << { label: label.to_s.strip.presence || attr.to_s, value: value.to_s.strip }
          next
        end

        value = h_attrs[attr]
        if value.is_a?(Hash) && value['run_id']
          tmp_run = Run.find_by(id: value['run_id'])
          tmp_step = tmp_run ? (h_steps[tmp_run.step_id] || tmp_run.step) : nil
          display_value = if tmp_run && tmp_step
                            "#{tmp_step.name}" + (tmp_step.multiple_runs? ? " ##{tmp_run.num}" : '')
                          else
                            'NA'
                          end
          pairs << {
            label: helpers.form_param_label(attr, method_map).presence || attr.to_s,
            value: display_value
          }
        elsif value.is_a?(Array) && value[0].is_a?(Hash) && value[0]['run_id']
          display_values = value.map do |entry|
            tmp_run = Run.find_by(id: entry['run_id'])
            tmp_step = tmp_run ? (h_steps[tmp_run.step_id] || tmp_run.step) : nil
            if tmp_run && tmp_step
              "#{tmp_step.name}" + (tmp_step.multiple_runs? ? " ##{tmp_run.num}" : '')
            else
              'NA'
            end
          end
          pairs << {
            label: helpers.form_param_label(attr, method_map).presence || attr.to_s,
            value: display_values.join(', ')
          }
        elsif method_map[attr]
          display_value = if value.is_a?(Array) || value.is_a?(Hash)
                            value.to_json
                          else
                            selected = helpers.resolve_select_param_display_value(attr, value, method_map)
                            if selected.to_s != value.to_s
                              selected
                            else
                              helpers.resolve_scalar_param_display_value(run, attr, value, method_map)
                            end
                          end
          pairs << {
            label: helpers.form_param_label(attr, method_map).presence || attr.to_s,
            value: display_value.to_s
          }
        end
      end

      sanitize_heatmap_parameters(pairs)
    rescue StandardError => e
      Rails.logger.warn("[heatmap_run_parameter_pairs] run##{run&.id}: #{e.class} - #{e.message}")
      []
    end

    def selection_plot_context_with_heatmap_params(raw_context, run_attrs = {})
      context = sanitize_plot_context(raw_context)
      heatmap_run_id = (run_attrs['heatmap_run_id'] || run_attrs[:heatmap_run_id]).to_i
      if context.nil? && heatmap_run_id > 0
        context = { plot: 'heatmap', heatmap: { run_id: heatmap_run_id } }
      end
      return context unless context.is_a?(Hash) && context[:plot] == 'heatmap'

      enrich_heatmap_plot_context(context, heatmap_run_id: heatmap_run_id)
    end

    def sanitize_filter_components(raw_components)
      return nil unless raw_components.is_a?(Array)

      normalized = raw_components.map do |entry|
        entry_hash = normalize_selection_nested_hash(entry)
        next unless entry_hash.is_a?(Hash)

        type = (entry_hash['type'] || entry_hash[:type]).to_s
        metadata_id = (entry_hash['metadata_id'] || entry_hash[:metadata_id]).to_s
        name = (entry_hash['name'] || entry_hash[:name]).to_s
        next if type.blank? || metadata_id.blank?

        if type == 'continuous'
          range_min = entry_hash['range_min'] || entry_hash[:range_min]
          range_max = entry_hash['range_max'] || entry_hash[:range_max]
          full_min = entry_hash['full_min'] || entry_hash[:full_min]
          full_max = entry_hash['full_max'] || entry_hash[:full_max]
          selection_ref_id = entry_hash['selection_ref_id'] || entry_hash[:selection_ref_id]
          selection_ref_name = entry_hash['selection_ref_name'] || entry_hash[:selection_ref_name]

          {
            type: 'continuous',
            metadata_id: metadata_id,
            name: name,
            range_min: range_min.nil? ? nil : range_min.to_f,
            range_max: range_max.nil? ? nil : range_max.to_f,
            full_min: full_min.nil? ? nil : full_min.to_f,
            full_max: full_max.nil? ? nil : full_max.to_f,
            selection_ref_id: selection_ref_id.to_s,
            selection_ref_name: selection_ref_name.to_s
          }
        else
          summary_mode = (entry_hash['summary_mode'] || entry_hash[:summary_mode]).to_s
          selected_count = (entry_hash['selected_count'] || entry_hash[:selected_count]).to_i
          total_count = (entry_hash['total_count'] || entry_hash[:total_count]).to_i
          summary_values = entry_hash['summary_values'] || entry_hash[:summary_values]
          hidden_value_count = (entry_hash['hidden_value_count'] || entry_hash[:hidden_value_count]).to_i
          selection_ref_id = entry_hash['selection_ref_id'] || entry_hash[:selection_ref_id]
          selection_ref_name = entry_hash['selection_ref_name'] || entry_hash[:selection_ref_name]

          {
            type: 'categorical',
            metadata_id: metadata_id,
            name: name,
            summary_mode: summary_mode,
            selected_count: selected_count,
            total_count: total_count,
            summary_values: Array(summary_values).map(&:to_s).first(50),
            hidden_value_count: hidden_value_count,
            selection_ref_id: selection_ref_id.to_s,
            selection_ref_name: selection_ref_name.to_s
          }
        end
      end.compact

      normalized.any? ? normalized : nil
    end

    def normalize_selection_nested_hash(value)
      return value if value.is_a?(Hash)
      return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      return value.to_h if value.respond_to?(:to_h)

      nil
    end

  def find_or_start_marker_run_for_annot(annot)
    marker_run = marker_run_for_annot(annot)
    started = false
    submitted = false
    resubmitted = false

    if marker_run.nil? || marker_run.status_id.to_i == 4
      user_id = current_user&.id || @project.user_id
      res = Basic.find_markers(Rails.logger, @project, annot, user_id)
      if res[:error].present?
        return { run: nil, started: false, submitted: false, resubmitted: false, error: res[:error].to_s }
      end
      marker_run = res[:run]
      started = marker_run.present?
    end

    if marker_run && marker_run.slurm_job_id.blank?
      unless slurm_controller_available?
        return {
          run: marker_run,
          started: started,
          submitted: false,
          resubmitted: false,
          error: 'FindMarkers cannot start because the SLURM scheduler is currently unavailable.'
        }
      end

      marker_run.reload
      if Basic.safe_parse_json(marker_run.command_json, {}).empty?
        res = Basic.find_markers(Rails.logger, @project, annot, current_user&.id || @project.user_id)
        if res[:error].present?
          return { run: nil, started: started, submitted: false, resubmitted: false, error: res[:error].to_s }
        end
        marker_run = res[:run]
        marker_run&.reload
        if marker_run && Basic.safe_parse_json(marker_run.command_json, {}).empty?
          return {
            run: marker_run,
            started: started,
            submitted: false,
            resubmitted: false,
            error: 'FindMarkers command could not be built. Please retry or contact support.'
          }
        end
      end

      if marker_run.status_id.to_i == 1
        Basic.exec_run(Rails.logger, marker_run)
        submitted = true
      elsif marker_run.status_id.to_i == 6
        # Recover stale "submitted" runs that never received a scheduler assignment.
        # Throttle retries to avoid enqueue storms from frequent UI polling.
        last_submit = marker_run.submitted_at || marker_run.updated_at || marker_run.created_at
        if last_submit && last_submit < 90.seconds.ago
          Basic.exec_run(Rails.logger, marker_run)
          submitted = true
          resubmitted = true
        end
      end
    end

    marker_run&.reload

    # If DB still says "running/submitted" but the SLURM job is gone,
    # trigger an immediate monitor sync so UI does not show a stale running state.
    if marker_run && marker_run.slurm_job_id.present? && [2, 6].include?(marker_run.status_id.to_i)
      unless slurm_job_still_active?(marker_run.slurm_job_id)
        SlurmJobMonitorJob.perform_now(marker_run.id, marker_run.slurm_job_id)
        marker_run.reload
      end
    end

    { run: marker_run, started: started, submitted: submitted, resubmitted: resubmitted, error: marker_run ? nil : 'Marker run could not be created.' }
  rescue StandardError => e
    Rails.logger.error("[get_annot_evidences] find_or_start_marker_run_for_annot failed: #{e.class} - #{e.message}")
    { run: nil, started: false, submitted: false, resubmitted: false, error: e.message }
  end

  def slurm_job_still_active?(job_id)
    output = `squeue -h -j #{job_id.to_i} -o '%i' 2>&1`
    $?.success? && output.present? && !output.downcase.include?('error')
  rescue StandardError
    false
  end

  # Compact state from squeue (e.g. PD pending, R running). Nil if job is absent or query failed.
  def slurm_job_compact_state(job_id)
    id = job_id.to_i
    return nil if id <= 0

    output = `squeue -h -j #{id} -o '%t' 2>&1`.strip
    return nil unless $?.success?
    return nil if output.blank?
    return nil if output.downcase.include?('invalid')

    output.lines.first&.strip
  rescue StandardError
    nil
  end

  def slurm_job_pending_in_scheduler?(job_id)
    slurm_job_compact_state(job_id) == 'PD'
  end

  def marker_slurm
    @marker_slurm ||= SlurmService.new(logger: Rails.logger)
  end

  # Slurm reports the batch step on a node (R) while Run.status_id can still be 1 until the next
  # SlurmJobMonitorJob tick (MONITOR_INTERVAL 30s). Without this check, get_annot_evidences and
  # status_only would keep returning queued even when the job is already executing.
  def marker_run_slurm_executing?(marker_run)
    jid = marker_run.slurm_job_id
    return false if jid.blank? || jid.to_i.zero?

    marker_slurm.get_job_status(jid.to_s, marker_run) == :running
  rescue StandardError => e
    Rails.logger.warn("[marker_run_slurm_executing?] Run##{marker_run&.id}: #{e.class} #{e.message}")
    false
  end

  # Run#error is set by SlurmJobMonitorJob / finish_run paths; expose it so the Identify tab is not opaque.
  def markers_failed_user_message(marker_run, fallback: 'FindMarkers failed for this category. Retry once the run issue is resolved.')
    text = marker_run&.error.to_s.strip
    return text if text.present?

    fallback
  end

  # Targeted ActionCable signal: Stimulus refreshes this metadata markers icon and the Identify markers tab.
  def broadcast_markers_run_status_changed(marker_run)
    return unless @project.respond_to?(:id)

    throttle_key = "markers_run_status_changed_sent:#{marker_run.id}"
    return if Rails.cache.read(throttle_key)

    Rails.cache.write(throttle_key, true, expires_in: 5.seconds)
    ActionCable.server.broadcast(
      "project_#{@project.id}",
      {
        event: 'markers_run_status_changed',
        project_id: @project.id,
        run_id: marker_run.id,
        annot_id: marker_run.marker_metadata_annot_id
      }
    )
  rescue StandardError => e
    Rails.logger.warn("[broadcast_markers_run_status_changed] #{e.class} #{e.message}")
  end

  def marker_queued_json_from_snapshot(snap, base_message)
    queue_note = MarkerQueueText.partition_pending_explanation(snap)
    base = base_message.to_s.strip
    return { message: base } if queue_note.blank?

    {
      message: "#{base} #{queue_note}",
      markers_queue_base: base,
      markers_queue_note: queue_note,
      slurm_queue_hover: MarkerQueueText.hover_summary(snap, snap[:position].to_i),
      queue_position: snap[:position].to_i,
      queue_pending_total: snap[:pending_count].to_i,
      queue_partition: snap[:partition].to_s
    }
  end

  def slurm_controller_available?
    # `scontrol ping` can report false DOWN in some container/client setups.
    # Use a read query against the controller instead.
    result = `sinfo -h -o '%P' 2>&1`
    $?.success? && result.present? && !result.downcase.include?('error')
  rescue StandardError
    false
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

  # Metadata panel badge when the user has read access but not analyze (guest, view-only share, etc.).
  # No Slurm reconciliation or job side effects.
  def marker_evidences_status_json_non_analyzable_peek(annot)
    marker_run = marker_run_for_annot(annot)
    unless marker_run
      return {
        state: 'idle',
        message: '',
        rows_up: [],
        rows_down: []
      }
    end

    status_id = marker_run.status_id.to_i
    status_name = marker_run.status&.name.to_s
    common = {
      run_id: marker_run.id,
      status_id: status_id,
      status_name: status_name,
      rows_up: [],
      rows_down: []
    }

    case status_id
    when 3
      common.merge(state: 'completed', message: '')
    when 4
      common.merge(
        state: 'failed',
        message: markers_failed_user_message(marker_run, fallback: 'FindMarkers failed for this category.')
      )
    else
      common.merge(
        state: 'analyze_forbidden',
        message: MARKER_EVIDENCES_ANALYZE_FORBIDDEN_MESSAGE
      )
    end
  end

  # Status for UI badges only. Never calls Basic.find_markers or exec_run.
  def marker_evidences_status_json_readonly(annot, cat_idx)
    marker_run = marker_run_for_annot(annot)
    unless marker_run
      Rails.logger.debug do
        "[marker_evidences_status_readonly] project_id=#{@project.id} annot_id=#{annot.id} annot_name=#{annot.name.inspect} " \
          "cat_idx=#{cat_idx} marker_run=none (idle)"
      end
      return {
        state: 'idle',
        message: '',
        rows_up: [],
        rows_down: []
      }
    end

    # DB says "running" but SLURM still has the job in PD (queue). Same fix as SlurmJobMonitorJob so status_only polls align.
    if marker_run.slurm_job_id.present? && marker_run.status_id.to_i == 2 && slurm_job_pending_in_scheduler?(marker_run.slurm_job_id)
      SlurmJobMonitorJob.perform_now(marker_run.id, marker_run.slurm_job_id)
      marker_run.reload
    end

    status_before = marker_run.status_id.to_i
    slurm_id = marker_run.slurm_job_id
    slurm_active_before = slurm_id.present? ? slurm_job_still_active?(slurm_id) : nil
    reconcile_ran = false

    # Same reconciliation as find_or_start_marker_run_for_annot: if the DB still says running but
    # the SLURM job is gone, sync so the UI does not stay on "running" when nothing is on the cluster.
    if slurm_id.present? && [2, 6].include?(status_before)
      unless slurm_job_still_active?(slurm_id)
        Rails.logger.info(
          "[marker_evidences_status_readonly] SLURM/DB mismatch before sync: project_id=#{@project.id} " \
            "annot_id=#{annot.id} annot_name=#{annot.name.inspect} cat_idx=#{cat_idx} run_id=#{marker_run.id} " \
            "status_id=#{status_before} slurm_job_id=#{slurm_id} slurm_job_still_active=false " \
            "calling SlurmJobMonitorJob.perform_now"
        )
        SlurmJobMonitorJob.perform_now(marker_run.id, slurm_id)
        marker_run.reload
        reconcile_ran = true
      end
    end

    status_id = marker_run.status_id.to_i
    status_name = marker_run.status&.name.to_s
    slurm_active_after = slurm_id.present? ? slurm_job_still_active?(slurm_id) : nil

    Rails.logger.info(
      "[marker_evidences_status_readonly] project_id=#{@project.id} annot_id=#{annot.id} annot_name=#{annot.name.inspect} " \
        "cat_idx=#{cat_idx} run_id=#{marker_run.id} status_id=#{status_id} status_name=#{status_name.inspect} " \
        "status_id_before=#{status_before} slurm_job_id=#{slurm_id.inspect} " \
        "slurm_job_still_active_before=#{slurm_active_before.inspect} slurm_job_still_active_after=#{slurm_active_after.inspect} " \
        "reconcile_ran=#{reconcile_ran}"
    )
    common = {
      run_id: marker_run.id,
      status_id: status_id,
      status_name: status_name,
      rows_up: [],
      rows_down: []
    }

    if marker_run_slurm_executing?(marker_run) && [1, 2, 6].include?(status_id)
      broadcast_markers_run_status_changed(marker_run) if [1, 6].include?(status_id)
      return common.merge(state: 'running', message: 'FindMarkers is running for this metadata.')
    end

    if status_id == 1 || (status_id == 6 && marker_run.slurm_job_id.blank?)
      msg = if marker_run.slurm_job_id.present?
              'FindMarkers is queued for execution.'
            else
              'FindMarkers is pending scheduling.'
            end
      details = { message: msg }
      if marker_run.slurm_job_id.present?
        snap = marker_slurm.pending_job_queue_snapshot(marker_run.slurm_job_id)
        details = marker_queued_json_from_snapshot(snap, msg) if snap
      end
      return common.merge({ state: 'queued' }.merge(details))
    end

    if status_id == 2 || (status_id == 6 && marker_run.slurm_job_id.present?)
      if slurm_id.present?
        snap = marker_slurm.pending_job_queue_snapshot(slurm_id)
        if snap
          base = 'FindMarkers is queued on the cluster. The job has not started on a compute node yet.'
          return common.merge({ state: 'queued' }.merge(marker_queued_json_from_snapshot(snap, base)))
        end

        if slurm_job_pending_in_scheduler?(slurm_id)
          return common.merge(
            state: 'queued',
            message: 'FindMarkers is queued on the cluster. The job has not started on a compute node yet.'
          )
        end
      end

      return common.merge(state: 'running', message: 'FindMarkers is running for this metadata.')
    end

    if status_id == 4
      return common.merge(
        state: 'failed',
        message: markers_failed_user_message(marker_run, fallback: 'FindMarkers failed for this category.')
      )
    end

    unless status_id == 3
      return common.merge(state: 'running', message: 'FindMarkers status is being updated. Please refresh in a few seconds.')
    end

    common.merge(
      state: 'completed',
      message: '',
      rows_up: [],
      rows_down: []
    )
  end

  def parse_marker_tsv_float(cell)
    s = cell.to_s.strip
    return nil if s.empty?
    return nil if s.casecmp('na').zero?

    Float(s)
  rescue ArgumentError
    nil
  end

  def parse_marker_tsv_normalize_header_token(cell)
    cell.to_s.strip.sub(/\A\uFEFF/, '').downcase.gsub(/[^a-z0-9]+/, '')
  end

  def parse_marker_tsv_looks_like_header_row?(cells)
    return false if cells.blank? || cells.size < 3

    norms = cells.map { |c| parse_marker_tsv_normalize_header_token(c) }
    return true if norms.any? { |n| %w[pval pvalue pvaladj padj fdr].include?(n) }
    return true if norms.any? { |n| n.include?('log2fc') || (n.include?('log') && n.include?('fc')) }

    norms.any? { |n| %w[gene genename symbol ensembl accession].include?(n) } &&
      norms.any? { |n| n.start_with?('pval') || n == 'fdr' || n == 'padj' }
  end

  def parse_marker_tsv_column_indices_from_header(header_cells)
    norms = header_cells.map { |c| parse_marker_tsv_normalize_header_token(c) }
    idx = {}
    norms.each_with_index { |n, i| idx[n] ||= i }

    pick = lambda do |*keys|
      keys.map { |k| idx[k] }.compact.first
    end

    {
      log2fc: pick.call('avglog2fc', 'avglogfc', 'log2fc', 'logfc', 'logfoldchange'),
      p_value: pick.call('pval', 'pvalue', 'pvalues'),
      fdr: pick.call('pvaladj', 'padj', 'fdr', 'adjpval', 'adjp'),
      gene_id: pick.call('ensembl', 'ensemblid', 'accession', 'geneid', 'stableid'),
      gene: pick.call('gene', 'genename', 'symbol', 'name')
    }
  end

  def marker_output_dir_for_run(marker_run)
    project_data_dir + 'markers' + marker_run.id.to_s
  end

  # Java FindMarkers used UI cat_idx + 1. de.v8.py FindAllMarkers uses 1-based index in
  # output.json list_cats_json (sorted unique loom labels). Resolve by category label when possible.
  def marker_category_tsv_path(marker_run, cat_idx, annot: nil)
    output_dir = marker_output_dir_for_run(marker_run)
    fallback = output_dir + "cat_#{cat_idx.to_i + 1}.tsv"

    annot ||= begin
      attrs = Basic.safe_parse_json(marker_run.attrs_json, {})
      groups_id = (attrs['groups_id'] || attrs[:groups_id]).to_i
      groups_id.positive? ? Annot.find_by(id: groups_id) : nil
    end
    annot ||= Annot.find_by(id: marker_run.try(:marker_metadata_annot_id))

    list_cats = Basic.safe_parse_json(annot&.list_cat_json, [])
    cat_label = list_cats[cat_idx.to_i]
    if cat_label.present?
      output_json_path = output_dir + 'output.json'
      if File.exist?(output_json_path)
        output = Basic.safe_parse_json(File.read(output_json_path), {})
        run_cats = output['list_cats_json']
        if run_cats.is_a?(Array)
          run_i = run_cats.index { |c| c.to_s == cat_label.to_s }
          if run_i
            mapped = output_dir + "cat_#{run_i + 1}.tsv"
            return mapped if File.exist?(mapped)
          end
        end
      end
    end

    fallback
  end

  def parse_marker_rows_for_category(marker_run, cat_idx, annot: nil)
    marker_file = marker_category_tsv_path(marker_run, cat_idx, annot: annot)
    return { error: 'FindMarkers output is not available yet. Please refresh shortly.' } unless File.exist?(marker_file)

    rows_up = []
    rows_down = []
    fdr_cutoff = 0.05
    fc_cutoff = Math.log2(2.0)
    max_rows_per_group = 100

    first_line = File.open(marker_file, 'r', &:gets)
    return { rows_up: rows_up, rows_down: rows_down } if first_line.blank?

    first_cells = first_line.rstrip.split("\t")
    col = nil
    skip_first = false
    if parse_marker_tsv_looks_like_header_row?(first_cells)
      col = parse_marker_tsv_column_indices_from_header(first_cells)
      skip_first = col[:log2fc].present? && col[:fdr].present?
    end

    File.foreach(marker_file).with_index do |line, line_idx|
      next if skip_first && line_idx.zero?

      cols = line.rstrip.split("\t")
      next if cols.size < 3

      log2fc = nil
      fdr = nil
      p_value = nil
      gene_id = ''
      gene = ''

      if col && col[:log2fc] && col[:fdr] && col[:log2fc] < cols.size && col[:fdr] < cols.size
        log2fc = parse_marker_tsv_float(cols[col[:log2fc]])
        fdr = parse_marker_tsv_float(cols[col[:fdr]])
        if col[:p_value] && col[:p_value] < cols.size
          p_value = parse_marker_tsv_float(cols[col[:p_value]])
        end
        gid_i = col[:gene_id]
        g_i = col[:gene]
        gene_id = (gid_i && gid_i < cols.size) ? cols[gid_i].to_s : ''
        gene = (g_i && g_i < cols.size) ? cols[g_i].to_s : ''
        if gene.blank? && cols[0].to_s.strip.present?
          gene = cols[0].to_s.strip
          gene_id = gene_id.presence || gene
        end
        gene_id = gene_id.presence || gene
      elsif cols.size >= 9
        log2fc = parse_marker_tsv_float(cols[4])
        p_value = parse_marker_tsv_float(cols[5])
        fdr = parse_marker_tsv_float(cols[6])
        gene_id = cols[0].to_s
        gene = cols[2].to_s
      elsif cols.size >= 8
        log2fc = parse_marker_tsv_float(cols[5])
        p_value = parse_marker_tsv_float(cols[6])
        fdr = parse_marker_tsv_float(cols[7])
        gene_id = cols[1].to_s
        gene = cols[2].to_s
      else
        next
      end

      next if log2fc.nil? || fdr.nil?
      next unless log2fc.finite? && fdr.finite?
      next if fdr > fdr_cutoff
      next if log2fc.abs < fc_cutoff

      row = {
        gene_id: gene_id,
        gene: gene.presence || gene_id,
        log2fc: log2fc.round(4),
        p_value: (p_value.nil? || !p_value.finite?) ? nil : p_value,
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

  def de_filter_cache_key
    return "u#{current_user.id}" if current_user

    sandbox_key = session[:sandbox].to_s
    return "g#{Zlib.crc32(sandbox_key).to_s(36)}" if sandbox_key.present?

    'g0'
  end

  def marker_compatible_metadata?(annot)
    return false unless annot

    data_type = annot.data_type
    return false unless data_type
    return false unless data_type.name.to_s == 'DISCRETE'
    return false if annot.nber_cats.to_i <= 1

    true
  end

  def run_de_filter(annots, h_de_filter, de_runs: nil)
    user_id = de_filter_cache_key
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key

    completed =
      if de_runs
        de_runs.select { |r| r.status_id == 3 }
      else
        Run.where(id: annots.map(&:run_id).uniq, status_id: 3).order(created_at: :desc).to_a
      end
    table_rows = Basic.de_table_rows_for_runs(completed)
    annots_union = (annots + table_rows.filter_map { |r| r[:annot] }).uniq(&:id)

    h_annots_by_loom_path = {}
    annots_to_do = annots_union.select do |annot|
      output_txt = Basic.de_annot_output_txt_path(project_dir, annot)
      next true unless File.exist?(output_txt) && File.size(output_txt).positive?

      first_line = File.open(output_txt, 'r', &:gets)
      ncol = first_line&.chomp&.split("\t")&.size.to_i
      ncol != 10 || Basic.de_output_txt_first_line_is_column_header?(first_line)
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
        output_file = Basic.de_annot_output_txt_path(project_dir, annot)
        next true unless File.exist?(output_file) && File.size(output_file).positive?

        first_line = File.open(output_file, 'r', &:gets)
        ncol = first_line&.chomp&.split("\t")&.size.to_i
        ncol != 10 || Basic.de_output_txt_first_line_is_column_header?(first_line)
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

    annots_to_do.select do |a|
      owner_run_id = Basic.de_attrs_de_output_matrix_match(a.name)&.first || a.run_id
      File.exist?(project_dir + 'de' + owner_run_id.to_s)
    end.each do |annot|
      loom_path = annot.filepath
      loom_file = project_dir + loom_path
      output_file = Basic.de_annot_output_txt_path(project_dir, annot)

      if File.exist?(output_file) && File.size(output_file).positive?
        first_line = File.open(output_file, 'r', &:gets)
        ncol = first_line&.chomp&.split("\t")&.size.to_i
        next if ncol == 10 && !Basic.de_output_txt_first_line_is_column_header?(first_line)
      end

      h_results = {}
      vals = nil
      attrs_via_h5py = false
      meta_name = annot.name.to_s
      meta_norm = meta_name.sub(/\Aattrs\//, '/attrs/')
      # v8 /attrs/ DE matrices: h5py is faster and returns the nested layout ExtractMetadata often skips.
      if meta_norm.start_with?('/attrs/')
        begin
          h_results = H5DataService.get_attrs_matrix_full_for_de_filter(loom_file.to_s, meta_norm, annot)
          vals = h_results['values']
          attrs_via_h5py = true
        rescue => e
          Rails.logger.error(
            "[run_de_filter] attrs_matrix_h5py_failed project_id=#{@project.id} run_id=#{annot.run_id} annot_id=#{annot.id} " \
            "loom=#{loom_file} meta=#{annot.name} error=#{e.class}: #{e.message}"
          )
        end
      end

      unless vals.is_a?(Array) && vals[0].is_a?(Array)
        cmd3 = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata --scientific -prec 5 -loom #{loom_file} -meta \"#{annot.name}\""
        h_results = Basic.safe_parse_json(`#{cmd3}`.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8), {})
        vals = h_results['values']
        attrs_via_h5py = false
        unless vals.is_a?(Array) && vals[0].is_a?(Array)
          if meta_norm.start_with?('/attrs/') && !attrs_via_h5py
            begin
              h_results = H5DataService.get_attrs_matrix_full_for_de_filter(loom_file.to_s, meta_norm, annot)
              vals = h_results['values']
              attrs_via_h5py = true
            rescue => e
              Rails.logger.error(
                "[run_de_filter] attrs_matrix_h5py_retry_failed project_id=#{@project.id} run_id=#{annot.run_id} annot_id=#{annot.id} " \
                "loom=#{loom_file} meta=#{annot.name} error=#{e.class}: #{e.message}"
              )
            end
          end
        end
      end
      json_nr = h_results['nber_rows'].to_i
      json_nc = h_results['nber_cols'].to_i
      vals, de_orient_note = Basic.de_attrs_values_to_column_major(vals, json_nr, json_nc, annot)
      n_cols = vals.is_a?(Array) ? vals.size : 0
      pack = Basic.de_metric_source_indices_for_extract_metadata(annot, n_cols)
      metric_idxs = pack[:indices]
      sort_col = pack[:sort_idx]

      ensembl_ids = h_ensembl_ids_by_loom_path[loom_path]
      gene_names = h_gene_names_by_loom_path[loom_path]

      sample_preview = nil
      FileUtils.mkdir_p(output_file.dirname)
      File.open(output_file, 'w') do |f|
        if vals.is_a?(Array) && vals[sort_col].is_a?(Array) && vals[sort_col].size.positive?
          sort_series = vals[sort_col]
          n_matrix = sort_series.size
          n_acc = ensembl_ids&.size.to_i
          n_gene = gene_names&.size.to_i
          loom_n = if n_acc.positive? && n_gene.positive?
                     [n_acc, n_gene].min
                   elsif n_acc.positive?
                     n_acc
                   elsif n_gene.positive?
                     n_gene
                   else
                     0
                   end
          n_use = loom_n.positive? && n_matrix > loom_n ? loom_n : n_matrix
          body = (0...n_use).to_a
            .select { |e| sort_series[e] }
            .sort { |a, b| sort_series[a].to_f <=> sort_series[b].to_f }
            .map { |i|
              if ensembl_ids && ensembl_ids[i] && (g = h_genes[ensembl_ids[i]])
                details = [i, g.ensembl_id, g.name, g.alt_names, g.description]
              else
                details = [i, nil, gene_names ? gene_names[i] : nil, nil, nil]
              end
              metric_cells = (0..4).map do |slot|
                ci = metric_idxs[slot]
                raw = vals[ci].is_a?(Array) ? vals[ci][i] : nil
                Basic.de_format_output_txt_metric_value(raw, slot)
              end
              (details + metric_cells).join("\t")
            }.join("\n") + "\n"
          f.write(body)
          sample_preview = body.lines.first&.chomp&.slice(0, 240)
        end
      end

      Rails.logger.info(
        "[run_de_filter] wrote_de_output_txt project_id=#{@project.id} run_id=#{annot.run_id} annot_id=#{annot.id} " \
        "attrs_h5py=#{attrs_via_h5py} orient=#{de_orient_note} n_cols=#{n_cols} metric_idxs=#{metric_idxs.inspect} sort_col=#{sort_col} " \
        "fdr_cutoff=#{h_de_filter['fdr_cutoff']} fc_cutoff=#{h_de_filter['fc_cutoff']} " \
        "sample_line=#{sample_preview.inspect}"
      )
    end

    filter_jobs = table_rows.filter_map do |row|
      p = Basic.de_annot_output_txt_path(project_dir, row[:annot], run_id: row[:run].id)
      next unless File.exist?(p) && File.size(p).positive?

      { key: row[:stats_key].to_s, path: p.to_s }
    end
    h_stats = Basic.de_filter_write_filtered_json_batch!(
      filter_jobs,
      h_de_filter['fdr_cutoff'],
      h_de_filter['fc_cutoff']
    )

    if h_stats.any?
      all_zero = h_stats.values.all? { |v| v['up'].to_i.zero? && v['down'].to_i.zero? }
      if all_zero
        sample_lines = table_rows.take(3).map do |row|
          p = Basic.de_annot_output_txt_path(project_dir, row[:annot], run_id: row[:run].id)
          rid = row[:run].id
          if !File.exist?(p)
            "#{rid}:missing"
          elsif File.size(p).to_i <= 0
            "#{rid}:empty"
          else
            File.open(p, 'r', &:readline)&.chomp&.slice(0, 400)
          end
        end
        Rails.logger.warn(
          "[run_de_filter] all_zero_up_down project_id=#{@project.id} cache_key=#{user_id} " \
          "fdr_cutoff=#{h_de_filter['fdr_cutoff']} fc_cutoff=#{h_de_filter['fc_cutoff']} " \
          "sample_output_txt_lines=#{sample_lines.inspect}"
        )
      end
    end

    filtered_stats_json = project_dir + 'tmp' + "#{user_id}_de_filtered_stats.json"
    FileUtils.mkdir_p(project_dir + 'tmp')
    File.open(filtered_stats_json, 'w') { |f| f.write(h_stats.to_json) }

    Rails.logger.info(
      "[run_de_filter] success project_id=#{@project.id} cache_key=#{user_id} table_rows=#{table_rows.size} stats=#{h_stats.size}"
    )

    h_stats
  rescue => e
    Rails.logger.error(
      "[run_de_filter] error project_id=#{@project.id} cache_key=#{user_id} " \
      "error=#{e.class}: #{e.message}"
    )
    raise
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
      
      std_methods = StdMethod.where(
        docker_image_id: asap_docker_image.id,
        version_id: @project.version_id,
        step_id: step.id,
        obsolete: false
      ).all
      
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
        Step.where(docker_image_id: asap_docker_image.id, version_id: @project.version_id)
            .each { |s| h_steps_by_name[s.name] = s if s.respond_to?(:name) }
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
                                        when 'spat' then 'spatial transcriptomics'
                                        when 'atac' then 'ATAC-seq'
                                        when 'multi' then 'multiomics'
                                        else project_type_tag || 'unknown'
                                        end
                   required_types_labels = all_required_project_types.map do |t|
                     case t
                     when 'sc' then 'single-cell'
                     when 'bulk' then 'bulk'
                     when 'spat' then 'spatial transcriptomics'
                     when 'atac' then 'ATAC-seq'
                     when 'multi' then 'multiomics'
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
                   
                   "Missing inputs: #{requirement_messages.join('; ')}"
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
                     "Missing inputs: #{required_inputs.uniq.join('; ')}"
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
      Annot.light.where(project_id: @project.id)
           .includes(:run)
           .all
    end
    
    # Input-data attrs marked optional (min_nber_items 0) do not gate step/method availability.
    def optional_std_method_input_attr?(attr_config)
      FormAttrConstraints.input_data_optional?(attr_config)
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
        Step.where(docker_image_id: asap_docker_image.id, version_id: @project.version_id)
            .each { |s| h_steps_by_name[s.name] = s if s.respond_to?(:name) }
      end
      
      # Check each parameter that requires a dataset
      combined_attrs.each do |attr_name, attr_config|
        next unless attr_config.is_a?(Hash)
        next unless attr_config['source_steps'].present? && attr_config['valid_types'].present?
        next if optional_std_method_input_attr?(attr_config)
        
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
          annot.matches_source_step_ids?(source_step_ids)
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
        next if optional_std_method_input_attr?(attr_config)
        
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
          annot.matches_source_step_ids?(source_step_ids)
        end

        # Apply source_methods / excluded_source_methods filtering
        source_methods_filter = attr_config['source_methods']
        excluded_source_methods_filter = attr_config['excluded_source_methods']
        if source_methods_filter.present? || excluded_source_methods_filter.present?
          h_steps_by_id = h_steps_by_name.values.index_by(&:id)
          source_annots = source_annots.select do |annot|
            run = annot.run_id ? (annot.run rescue Run.find_by(id: annot.run_id)) : nil
            run ||= Run.find_by(id: annot.ori_run_id) if annot.ori_run_id
            next true unless run&.std_method_id
            method_record = StdMethod.find_by(id: run.std_method_id)
            next true unless method_record
            source_step = h_steps_by_id[run.step_id]
            step_name = source_step&.name
            next true unless step_name
            if source_methods_filter.present? && source_methods_filter[step_name].present?
              next source_methods_filter[step_name].include?(method_record.name)
            end
            if excluded_source_methods_filter.present? && excluded_source_methods_filter[step_name].present?
              next !excluded_source_methods_filter[step_name].include?(method_record.name)
            end
            true
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
      if step.name == 'module_score' && !module_score_gene_set_input_available?(available_annots, h_steps_by_name)
        missing_requirements << {
          steps: ['global gene set database or loom gene set metadata'],
          valid_types: [['dataset'], ['row_mdata'], ['discrete_mdata']]
        }
        has_all = false
      end
      [has_all, missing_requirements]
    end

    def module_score_gene_set_input_available?(available_annots, h_steps_by_name)
      return true if pipeline_global_gene_set_collections.any?

      source_steps = %w[import_metadata parsing cell_filtering gene_filtering]
      valid_types = [['dataset'], ['row_mdata'], ['discrete_mdata']]
      source_step_ids = source_steps.map { |ssn| h_steps_by_name[ssn]&.id }.compact
      return false if source_step_ids.empty?

      h_data_classes = {}
      DataClass.all.each { |dc| h_data_classes[dc.id] = dc.name }

      source_annots = available_annots.select { |annot| annot.matches_source_step_ids?(source_step_ids) }
      source_annots.any? do |annot|
        next false if annot.data_class_ids.blank?

        annot_data_class_names = annot.data_class_ids.split(',').map { |dc_id| h_data_classes[dc_id.to_i] }.compact
        valid_types.all? do |or_group|
          or_group.any? { |valid_type| annot_data_class_names.include?(valid_type) }
        end
      end
    end

    # Heatmap form: list both global reference AND custom/local gene set collections,
    # since heatmap genes are resolved server-side (HeatmapGeneResolver) for either source.
    def inject_heatmap_gene_set_collection_options!(h_attrs)
      return unless h_attrs.is_a?(Hash)

      attr = h_attrs['global_gene_set_collection_id']
      return unless attr.is_a?(Hash)

      load_gene_set_collections
      list = Array(@gene_set_collections).map do |c|
        db = c[:database_name].to_s.strip
        lbl = c[:label].to_s.strip
        label = (db.present? && lbl.present? && !db.casecmp?(lbl)) ? "#{db} - #{lbl}" : (db.presence || lbl)
        [label.presence || lbl, c[:id].to_s]
      end

      attr['widget'] = 'select'
      attr['list'] = list
      attr['requires_message'] = 'No gene set collections are available for this organism' if list.empty?
    rescue StandardError => e
      Rails.logger.error("[inject_heatmap_gene_set_collection_options!] #{e.message}")
    end

    def heatmap_run_for_params
      run = Run.find_by(id: params[:run_id], project_id: @project.id)
      unless run
        render json: { error: 'Run not found' }, status: :not_found
        return nil
      end
      run
    end

    def heatmap_output_dir_for_run(run)
      step = run.step || Step.find_by(id: run.step_id)
      step_name = step&.name || 'heatmap'
      step_dir = @project_dir + step_name
      (step && step.multiple_runs == false) ? step_dir : (step_dir + run.id.to_s)
    end

    def heatmap_meta_for_run(run)
      meta_path = heatmap_output_dir_for_run(run) + 'heatmap_meta.json'
      return nil unless File.exist?(meta_path)

      meta = JSON.parse(File.read(meta_path), max_nesting: false)
      HeatmapMetaNormalizer.normalize!(meta)
      meta
    end

    def enrich_heatmap_selection_meta!(meta, loom_file)
      return unless meta.is_a?(Hash)

      if loom_file.present?
        embedding_id = Annot.light.where(project_id: @project.id, filepath: loom_file)
                            .where(nber_rows: 2)
                            .order(:id)
                            .pick(:id)
        meta['embedding_metadata_id'] = embedding_id if embedding_id
      end

      col_labels = Array(meta['col_labels'])
      existing = Array(meta['col_cell_indices'])
      return if col_labels.empty?
      return if existing.length == col_labels.length && existing.all? { |entry| entry.is_a?(Array) }
      # Group-mode columns already ship cell-index lists from the heatmap run.
      return if meta['column_mode'].to_s == 'group'
      return if loom_file.blank?

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
      loom_path = project_dir + loom_file
      return unless File.exist?(loom_path)

      cell_ids = H5DataService.get_metadata_vector(loom_path.to_s, '/col_attrs/CellID')
      return unless cell_ids.is_a?(Array)

      index = {}
      cell_ids.each_with_index do |cid, i|
        key = cid.to_s
        index[key] = i unless index.key?(key)
      end
      meta['col_cell_indices'] = col_labels.map do |label|
        idx = index[label.to_s]
        idx ? [idx] : []
      end
    end

    def heatmap_loom_file_for_run(run)
      attrs = Basic.safe_parse_json(run.attrs_json, {})
      item = attrs['input_matrix']
      item = item.first if item.is_a?(Array)
      return nil unless item.is_a?(Hash)

      item['output_filename'].presence || item['filepath'].presence
    end

    def heatmap_metadata_options_for(loom_file, dim:)
      # display_name is a Ruby method on Annot, not a DB column — order by name in SQL
      Annot.light.where(project_id: @project.id, filepath: loom_file, dim: dim)
           .includes(:data_type)
           .order(Arel.sql('LOWER(name)'))
           .map do |annot|
        {
          id: annot.id,
          name: annot.display_name.presence || annot.name,
          path: annot.name,
          data_type: annot.data_type&.name,
          nber_cats: annot.nber_cats.to_i
        }
      end
    end

    def inject_pipeline_gene_set_collection_options!(h_attrs)
      return unless h_attrs.is_a?(Hash)

      collections = pipeline_global_gene_set_collections
      list = collections.map { |c| [c[:label], c[:id].to_s] }
      requires_message = collections.empty? ? 'No global gene set collections are available for this organism' : nil

      %w[global_gene_set_collection_id gene_set_id].each do |attr_name|
        attr = h_attrs[attr_name]
        next unless attr.is_a?(Hash)

        attr['widget'] = 'select' if attr['widget'] == 'input_gene_set'
        attr['list'] = list
        attr['not_null'] = true if attr_name == 'gene_set_id'
        attr['requires_message'] = requires_message if requires_message
      end
    end

    def pipeline_global_gene_set_collections
      h_env = Basic.safe_parse_json(@project.version.env_json, {})
      db_version = asap_data_db_name_for_env(h_env, context: 'module_score_form')
      rows = []
      RemoteGene.with_remote(db_version) do
        conn = RemoteGene.connection
        rows = conn.select_all(<<~SQL)
          SELECT gs.id, gs.label, ds.label AS database_name
          FROM gene_sets gs
          LEFT JOIN db_sets ds ON ds.id = gs.ref_id
          WHERE gs.organism_id = #{@project.organism_id.to_i}
            AND gs.ref_id IS NOT NULL
            AND gs.project_id IS NULL
            AND COALESCE(gs.obsolete, FALSE) = FALSE
          ORDER BY LOWER(COALESCE(ds.label, '')), LOWER(COALESCE(gs.label, ''))
        SQL
      end
      rows.map do |row|
        db_label = row['database_name'].to_s.strip
        gs_label = row['label'].to_s.strip
        label = if db_label.present? && gs_label.present?
                  db_label.casecmp?(gs_label) ? db_label : "#{db_label} - #{gs_label}"
                else
                  db_label.presence || gs_label
                end
        {
          id: row['id'].to_i,
          label: label.presence || gs_label.to_s
        }
      end
    rescue StandardError => e
      Rails.logger.error("[pipeline_global_gene_set_collections] #{e.message}")
      []
    end

    def prepare_steps_with_status
      asap_docker_image = Basic.get_asap_docker(@project.version)
      @all_project_steps = if asap_docker_image
                             Step.where(docker_image_id: asap_docker_image.id, version_id: @project.version_id)
                                 .where.not(hidden: true)
                                 .order(:rank, :name)
                           else
                             Step.none
                           end

      # Get steps hash limited to current project's docker image.
      @h_steps = @all_project_steps.index_by(&:id)

      # Get statuses hash for looking up status names
      @h_statuses ||= {}
      Status.all.each { |s| @h_statuses[s.id] = s } if @h_statuses.empty?
      
      # Get project steps for availability checking
      @project_steps_hash = {}
      ProjectStep.where(project_id: @project.id).each do |ps|
        @project_steps_hash[ps.step_id] = ps
      end
      
      @pretreatment_steps = @all_project_steps.sort_by { |s| [s.rank || 9999, s.name] }
      
      # Filter steps based on project type
      # Steps can have a project_types array in attrs_json that specifies which project types they apply to
      # If project_types is empty or missing, the step applies to all project types (backward compatibility)
      # Also check std_methods - if ALL std_methods for a step require a different project type, exclude the step
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
            std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, version_id: @project.version_id, step_id: step.id, obsolete: false)
            
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
        latest_run = step_runs.max_by(&:created_at)
        if step_runs.any?
          # Use the most recent run's status (to show current/active status)
          status_id = latest_run&.status_id
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
        
        # Count runs by status using ProjectStep aggregate (single source of truth for icons/counters).
        # Stopped runs (status_id 5) are folded into the `failed` bucket so they render under the
        # shared failed/stopped icon in the pipeline left panel.
        if project_step&.nber_runs_json.present?
          json_counts = project_step.nber_runs_json.is_a?(String) ? JSON.parse(project_step.nber_runs_json) : project_step.nber_runs_json
          status_counts = {
            waiting: json_counts['1'].to_i,
            running: json_counts['2'].to_i,
            completed: json_counts['3'].to_i,
            failed: json_counts['4'].to_i + json_counts['5'].to_i
          }
        else
          status_counts = {
            waiting: step_runs.count { |r| r.status_id == 1 },
            running: step_runs.count { |r| r.status_id == 2 },
            completed: step_runs.count { |r| r.status_id == 3 },
            failed: step_runs.count { |r| r.status_id == 4 || r.status_id == 5 }
          }
        end
        
        @steps_with_status << {
          step: step,
          latest_run: latest_run,
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
          all_for_sets = Cla.active.where(cell_set_id: cell_set_ids).includes(:project).to_a
          readable_for_sets = all_for_sets.select { |cla| cla.project && readable?(cla.project) }
          readable_for_sets.group_by(&:cell_set_id)
        end

      best_clas = []
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

        best_clas << [metadata.id, category_label, best_cla, cla_candidates.size]
      end

      cot_ids = best_clas.flat_map do |_metadata_id, _category_label, cla, _nber|
        parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
      end.map { |v| v.to_s.to_i }.select(&:positive?).uniq
      cot_label_by_id = {}
      if cot_ids.any?
        CellOntologyTerm.where(id: cot_ids).pluck(:id, :identifier, :name).each do |id, identifier, name|
          label = name.to_s.strip.presence || identifier.to_s.strip.presence
          cot_label_by_id[id.to_s] = label if label.present?
        end
      end

      best_clas.each do |metadata_id, category_label, best_cla, nber_clas|
        entry = build_best_cla_entry(best_cla, cot_label_by_id: cot_label_by_id).merge(
          category_label: category_label,
          nber_clas: nber_clas
        )
        store_best_cla_entry(metadata_id, category_label, entry)
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

    def build_best_cla_entry(cla, cot_label_by_id: {})
      cot_ids = parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
      ontology_labels = cot_ids.filter_map { |cot_id| cot_label_by_id[cot_id.to_s].presence }
      display_name =
        if ontology_labels.any?
          ontology_labels.join(', ')
        else
          cla.name.presence || "Unnamed annotation"
        end

      {
        score: cla_consensus_score(cla),
        name: display_name,
        free_text_name: cla.name.presence,
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

    def normalize_cla_id_list(value)
      parse_cla_field(value)
        .map { |item| item.to_s.strip }
        .reject(&:blank?)
        .uniq
    end

    def build_summary_gene_symbol_map
      project_cla_gene_symbol_by_stable_id(@project)
    end

    def build_summary_cot_label_map
      build_summary_cot_info_map.transform_values { |info| info[:name].presence || info[:identifier] }
    end

    def build_summary_cot_info_map(cla_records: nil)
      records = cla_records
      records = Cla.active.where(project_id: @project.id).to_a if records.nil?

      cot_ids = records.flat_map do |cla|
        parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
      end.map { |value| value.to_s.to_i }.select(&:positive?).uniq
      return {} if cot_ids.empty?

      ontology_by_tag = AsapData::OntologyIdentifierUrl.ontology_by_tag_index
      cot_info_by_id = {}
      CellOntologyTerm.where(id: cot_ids).pluck(:id, :identifier, :name).each do |id, identifier, name|
        identifier_s = identifier.to_s.strip
        name_s = name.to_s.strip
        next if identifier_s.blank? && name_s.blank?

        cot_info_by_id[id.to_s] = {
          id: id,
          identifier: identifier_s,
          name: name_s,
          url: identifier_s.present? ? AsapData::OntologyIdentifierUrl.url_for(identifier_s, ontology_by_tag: ontology_by_tag) : nil
        }
      end
      cot_info_by_id
    rescue StandardError => e
      Rails.logger.warn("[summary_cot_info] Unable to resolve ontology terms for project #{@project&.id}: #{e.class} - #{e.message}")
      {}
    end

    # CLA up/down gene fields store loom /row_attrs/_StableID values (from gene autocomplete),
    # not asap_data genes.id. Resolve symbols from project autocomplete_genes.json files.
    # Do not call ExtractMetadata here: reading full Gene/Accession/_StableID vectors from
    # every loom is far too expensive for page loads. Callers that must resolve missing
    # symbols against a specific loom should use ensure_project_cla_gene_symbols_for_loom!.
    def project_cla_gene_symbol_by_stable_id(project, required_ids: nil)
      project_cla_gene_info_by_stable_id(project, required_ids: required_ids)
        .transform_values { |info| info[:symbol] }
    end

    def project_cla_required_gene_stable_ids(project)
      return [] unless project

      Cla.active.where(project_id: project.id)
         .pluck(:sorted_up_gene_ids, :up_gene_ids, :sorted_down_gene_ids, :down_gene_ids)
         .flat_map do |sorted_up, up, sorted_down, down|
        [
          parse_cla_field(sorted_up.presence || up),
          parse_cla_field(sorted_down.presence || down)
        ]
      end.flatten.map { |value| value.to_s.strip }.reject(&:blank?).uniq
    end

    def project_cla_gene_info_by_stable_id(project, required_ids: nil)
      return {} unless project

      ids = if required_ids.nil?
              project_cla_required_gene_stable_ids(project)
            else
              Array(required_ids).map { |value| value.to_s.strip }.reject(&:blank?).uniq
            end
      return {} if ids.empty?

      map = {}
      roots = project_data_roots_for_cla_genes(project)
      return map if roots.empty?

      roots.each do |root|
        Dir.glob(root.join("**/autocomplete_genes.json").to_s).each do |path|
          merge_autocomplete_genes_file_into_info_map!(map, path)
        end
      end

      map
    rescue StandardError => e
      Rails.logger.warn("[cla_gene_symbols] Unable to resolve loom gene symbols for project #{project&.id}: #{e.class} - #{e.message}")
      {}
    end

    def project_data_roots_for_cla_genes(project)
      return [] unless project&.user_id.present?

      roots = []
      summary_root = summary_project_data_root(project)
      roots << summary_root if summary_root

      user_data_dir = ENV["USER_DATA_DIR"].to_s.chomp("/")
      if user_data_dir.present?
        roots << (Pathname.new(user_data_dir) + project.user_id.to_s + project.key)
      end

      roots.compact.uniq.select { |path| path.exist? }
    end

    def merge_autocomplete_genes_file_into_symbol_map!(map, path)
      info_map = {}
      merge_autocomplete_genes_file_into_info_map!(info_map, path)
      info_map.each { |stable_id, info| map[stable_id] = info[:symbol] }
    end

    def merge_autocomplete_genes_file_into_info_map!(map, path)
      data = JSON.parse(File.read(path))
      Array(data["search"] || data[:search]).each do |entry|
        parsed = parse_loom_autocomplete_gene_entry(entry)
        next unless parsed

        map[parsed[:stable_id]] = {
          symbol: parsed[:symbol],
          ensembl_id: parsed[:ensembl_id].presence
        }
      end
    rescue StandardError => e
      Rails.logger.warn("[cla_gene_symbols] Failed reading #{path}: #{e.class} - #{e.message}")
    end

    def merge_loom_row_attrs_into_symbol_map!(map, loom_path)
      info_map = {}
      merge_loom_row_attrs_into_info_map!(info_map, loom_path)
      info_map.each { |stable_id, info| map[stable_id] = info[:symbol] }
    end

    def merge_loom_row_attrs_into_info_map!(map, loom_path)
      gene_values = H5DataService.get_metadata_vector(loom_path, "/row_attrs/Gene")
      accession_values = H5DataService.get_metadata_vector(loom_path, "/row_attrs/Accession")
      stable_values = H5DataService.get_metadata_vector(loom_path, "/row_attrs/_StableID")
      return unless gene_values.is_a?(Array) && stable_values.is_a?(Array)

      size = [gene_values.length, stable_values.length].min
      size.times do |i|
        gene = gene_values[i].to_s.strip
        stable = stable_values[i].to_s.strip
        next if gene.blank? || stable.blank?

        ensembl = accession_values.is_a?(Array) ? accession_values[i].to_s.strip.presence : nil
        map[stable] = { symbol: gene, ensembl_id: ensembl }
      end
    rescue StandardError => e
      Rails.logger.warn("[cla_gene_symbols] Failed reading loom row attrs #{loom_path}: #{e.class} - #{e.message}")
    end

    def parse_loom_autocomplete_gene_entry(entry)
      match = entry.to_s.strip.match(/\A(.+?)\s+(\S+)\s+\{([^}]+)\}\z/)
      return nil unless match

      symbol = match[1].to_s.strip
      ensembl_id = match[2].to_s.strip
      stable_id = match[3].to_s.strip
      return nil if symbol.blank? || stable_id.blank?

      { symbol: symbol, ensembl_id: ensembl_id, stable_id: stable_id }
    end

    def ensure_project_cla_gene_symbols_for_loom!(map, project, loom_file, required_ids: [])
      roots = project_data_roots_for_cla_genes(project)
      return map if roots.empty? || loom_file.blank?

      roots.each do |root|
        autocomplete_file = root + File.dirname(loom_file.to_s) + "autocomplete_genes.json"
        merge_autocomplete_genes_file_into_symbol_map!(map, autocomplete_file.to_s) if File.exist?(autocomplete_file)
      end

      still_missing = Array(required_ids).map(&:to_s).reject { |gid| map.key?(gid) }
      if still_missing.any? || map.empty?
        roots.each do |root|
          loom_path = root + loom_file.to_s
          merge_loom_row_attrs_into_symbol_map!(map, loom_path.to_s) if File.exist?(loom_path)
        end
      end

      map
    end

    def reproduction_run_short_txt(run)
      return 'NA' unless run && @h_steps && @h_steps[run.step_id]

      step = @h_steps[run.step_id]
      std_method = run.std_method_id ? @h_std_methods[run.std_method_id] : nil
      std_method_name = std_method&.name
      parts = step.label.to_s.dup
      parts += " ##{run.num}" if step.multiple_runs?
      if std_method_name.present? && std_method_name.downcase != step.label.to_s.downcase
        parts += " #{std_method_name}"
      end
      parts
    end

    def forbid_bot_html_access_to_public_project_show
      return unless request.get?
      return unless request.format.html?
      return unless @project&.public?
      return if search_engine_crawler?
      return unless request_user_agent_indicates_bot?
      return if bot_allowed_public_project_view?

      head :forbidden
    end

    def bot_allowed_public_project_view?
      view = params[:view].to_s
      view.blank? || METADATA_ONLY_PROJECT_VIEWS.include?(view)
    end

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
        # public_id might be numeric or in format like "ASAP48"
        if identifier.match?(/^ASAP\d+$/i)
          # Extract numeric part from "ASAP48" format
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

    def handle_project_not_found(exception)
      if request.format.json? || request.path.start_with?('/api/')
        render json: { error: 'Project not found', message: exception.message }, status: :not_found
      else
        raise exception
      end
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
        {
          data: nil,
          info: {
            type: 'error',
            code: 'unknown_data_type',
            message: "Unknown data type: #{data_type}",
            data_type: data_type
          }
        }
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
          return {
            data: nil,
            info: {
              type: 'error',
              code: 'failed_parse_categories',
              message: 'Failed to parse categories',
              cell_count: raw_vector.length
            }
          }
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
        return {
          data: nil,
          info: {
            type: 'error',
            code: 'no_categories',
            message: 'No categories available',
            cell_count: raw_vector.length
          }
        }
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
        # Hash only (no .to_json): render json: embeds this as a JSON object; clients must not JSON.parse a bare string.
        return {
          data: nil,
          info: {
            type: 'discrete',
            single_category: true,
            category_index: unique_indices.first || 0,
            length: indices.length,
            categories: categories,
            num_categories: num_categories
          }
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
        # Structured info so the client can JSON-parse and synthesize a constant vector (no binary payload).
        return {
          data: nil,
          info: {
            type: 'continuous',
            zero_range: true,
            min_val: min_val.to_f,
            max_val: max_val.to_f,
            cell_count: raw_vector.length,
            bit_width: 16,
            message: 'Zero range - no variation in data'
          }
        }
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
      debug_graph_edges = (@project&.key.to_s == 'eab0uvmrod')
      emit_graph_debug = lambda do |message|
        return unless debug_graph_edges
        Rails.logger.warn(message)
        puts(message)
      end
      
      # Only include runs that exist
      return data if @runs.blank?

      # Exclude runs that belong to hidden steps from pipeline graph rendering.
      visible_runs = @runs.reject do |run|
        step = run.step || @h_steps[run.step_id]
        step&.hidden?
      end
      return data if visible_runs.blank?
      
      # Group runs by step for better organization
      runs_by_step = visible_runs.group_by(&:step_id)
      
      # Add nodes for each run
      visible_runs.each do |run|
        step = run.step || @h_steps[run.step_id]
        
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
            run_num: run.num || run.id,
            step_id: run.step_id,
            step_rank: step&.rank,
            step_name: (step&.name.presence || step&.label.presence || run.step_id.to_s).to_s.strip.downcase
          }
        }
      end
      
      # Create a hash of run IDs for quick lookup
      run_ids_set = visible_runs.map(&:id).to_set
      runs_by_id = visible_runs.index_by(&:id)
      normalize_step_name = lambda do |raw_name|
        raw_name.to_s.strip.downcase
      end
      step_name_for_run = lambda do |run_obj|
        step = run_obj&.step || @h_steps[run_obj&.step_id]
        raw_name = step&.name.presence || step&.label.presence || run_obj&.step_id.to_s
        normalize_step_name.call(raw_name)
      end
      classify_edge_type = lambda do |parent_payload|
        input_attr = (parent_payload.is_a?(Hash) ? (parent_payload[:input_attr_name] || parent_payload['input_attr_name']) : nil).to_s.downcase
        output_attr = (parent_payload.is_a?(Hash) ? (parent_payload[:output_attr_name] || parent_payload['output_attr_name']) : nil).to_s.downcase
        combined = "#{input_attr} #{output_attr}"

        return 'expression_matrix' if combined.include?('matrix')

        # Cell metadata (covariates, clustering/groups and QC metadata)
        if combined.match?(/mdata|covariate|group|clust|metadata|cell|selection|depth|mito|ribo|protein_coding|detected_genes/)
          return 'cell_metadata'
        end

        # Gene metadata (gene sets, markers, HVG, gene lists)
        if combined.match?(/gene_set|hvg|variable_genes|marker|input_genes|output_genes|gene_list|row_attrs/)
          return 'gene_metadata'
        end

        'unknown'
      end
      
      # Add edges based on run_parents_json (most reliable source)
      edges_added = false
      visible_runs.each do |run|
        next if run.run_parents_json.blank?
        
        begin
          parents = Basic.safe_parse_json(run.run_parents_json, [])
          if parents.is_a?(Array) && parents.any?
            parents.each do |parent|
              parent_id = parent.is_a?(Hash) ? parent[:run_id] || parent['run_id'] : parent
              parent_id = parent_id.to_i if parent_id
              
              # Check if parent run exists in our runs list
              if parent_id && run_ids_set.include?(parent_id)
                parent_run = runs_by_id[parent_id]
                # Avoid same logical-step edges (e.g. scaling -> scaling)
                if parent_run && step_name_for_run.call(parent_run) == step_name_for_run.call(run)
                  emit_graph_debug.call("[graph_debug][run_parents_json][skip_same_step] parent_run=#{parent_id} child_run=#{run.id} parent_step_id=#{parent_run.step_id} child_step_id=#{run.step_id} parent_step_name=#{step_name_for_run.call(parent_run)} child_step_name=#{step_name_for_run.call(run)}")
                  next
                end

                data << {
                  data: {
                    id: "edge_#{parent_id}_#{run.id}",
                    source: "run_#{parent_id}",
                    target: "run_#{run.id}",
                    edge_type: classify_edge_type.call(parent)
                  }
                }
                parent_step_name = parent_run ? step_name_for_run.call(parent_run) : 'unknown'
                emit_graph_debug.call("[graph_debug][run_parents_json][add_edge] parent_run=#{parent_id} child_run=#{run.id} parent_step_id=#{parent_run&.step_id} child_step_id=#{run.step_id} parent_step_name=#{parent_step_name} child_step_name=#{step_name_for_run.call(run)}")
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
        visible_runs.each do |run|
          next if run.pipeline_parent_run_ids.blank?
          
          parent_ids = run.pipeline_parent_run_ids.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
          parent_ids.each do |parent_id|
            # Check if parent run exists in our runs list
            if run_ids_set.include?(parent_id)
              parent_run = runs_by_id[parent_id]
              # Avoid same logical-step edges (e.g. scaling -> scaling)
              if parent_run && step_name_for_run.call(parent_run) == step_name_for_run.call(run)
                emit_graph_debug.call("[graph_debug][pipeline_parent_run_ids][skip_same_step] parent_run=#{parent_id} child_run=#{run.id} parent_step_id=#{parent_run.step_id} child_step_id=#{run.step_id} parent_step_name=#{step_name_for_run.call(parent_run)} child_step_name=#{step_name_for_run.call(run)}")
                next
              end

              data << {
                data: {
                  id: "edge_#{parent_id}_#{run.id}",
                  source: "run_#{parent_id}",
                  target: "run_#{run.id}",
                  edge_type: 'unknown'
                }
              }
              parent_step_name = parent_run ? step_name_for_run.call(parent_run) : 'unknown'
              emit_graph_debug.call("[graph_debug][pipeline_parent_run_ids][add_edge] parent_run=#{parent_id} child_run=#{run.id} parent_step_id=#{parent_run&.step_id} child_step_id=#{run.step_id} parent_step_name=#{parent_step_name} child_step_name=#{step_name_for_run.call(run)}")
              edges_added = true
            end
          end
        end
      end
      
      # If still no edges, create edges based on step order and run creation time
      if !edges_added
        # Group runs by step and sort by step rank, then by creation time
        runs_by_step_id = runs_by_step.keys.sort_by { |step_id| @h_steps[step_id]&.rank || 9999 }
        step_name_for = lambda do |sid|
          step = @h_steps[sid]
          if step.nil?
            sample_run = (runs_by_step[sid] || []).first
            step = sample_run&.step
          end
          raw_name = step&.name.presence || step&.label.presence || sid.to_s
          normalize_step_name.call(raw_name)
        end
        
        runs_by_step_id.each_with_index do |step_id, index|
          next if index == 0

          current_step_name = step_name_for.call(step_id)

          # Find previous step with a different logical step name.
          # This avoids artificial links like scaling#1 -> scaling#2 when
          # multiple internal step IDs represent the same step.
          prev_idx = index - 1
          while prev_idx >= 0 && step_name_for.call(runs_by_step_id[prev_idx]) == current_step_name
            prev_idx -= 1
          end
          next if prev_idx < 0

          prev_step_id = runs_by_step_id[prev_idx]
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
                    target: "run_#{current_run.id}",
                    edge_type: 'unknown'
                  }
                }
                emit_graph_debug.call("[graph_debug][fallback][add_edge] parent_run=#{prev_run.id} child_run=#{current_run.id} parent_step_id=#{prev_run.step_id} child_step_id=#{current_run.step_id} parent_step_name=#{step_name_for_run.call(prev_run)} child_step_name=#{step_name_for_run.call(current_run)}")
              end
            end
          end
        end
      end

      edge_count = data.count { |item| item[:data] && item[:data][:source] && item[:data][:target] }
      emit_graph_debug.call("[graph_debug][summary] project=#{@project.key} total_nodes=#{visible_runs.size} total_edges=#{edge_count}")
      
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

      # Resolve the std method used by the cell filtering custom form.
      @h_step_attrs = Basic.safe_parse_json(@step.attrs_json, {}) if @step&.attrs_json.present?
      @h_step_attrs ||= {}
      available_cell_filtering_methods = StdMethod.where(
        docker_image_id: asap_docker_image.id,
        obsolete: false,
        step_id: @step.id
      ).order(:name).to_a
      h_std_methods_by_name = available_cell_filtering_methods.index_by(&:name)
      h_obj_attrs_by_std_method = available_cell_filtering_methods.to_h { |m| [m.id, Basic.safe_parse_json(m.obj_attrs_json, {})] }
      @cell_filtering_std_method =
        Basic.resolve_default_std_method(
          project: @project,
          default_method_names: @h_step_attrs['default_std_method'],
          std_methods_by_name: h_std_methods_by_name,
          h_obj_attrs_by_std_method: h_obj_attrs_by_std_method
        ) ||
        available_cell_filtering_methods.find { |m| Basic.std_method_project_type_compatible?(@project, std_method: m, obj_attrs: h_obj_attrs_by_std_method[m.id]) } ||
        available_cell_filtering_methods.first
      
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

      # Matrix selector for cell filtering:
      # default to /matrix and optionally allow imported layers from parsing output.
      @cell_filtering_matrix_options = ['/matrix']
      if @parsing_run
        layer_paths = Annot.light.where(project_id: @project.id, run_id: @parsing_run.id, dim: 3)
                           .pluck(:name)
                           .select { |name| name.to_s.start_with?('/layers/') }
                           .uniq
                           .sort
        @cell_filtering_matrix_options.concat(layer_paths)
      end
      @cell_filtering_matrix_options = @cell_filtering_matrix_options.uniq
      @cell_filtering_default_matrix = '/matrix'
      
      # Get annotations for metadata filtering, grouped by source run
      metadata_store_run_ids = ([@parsing_run&.id] + @cell_filtering_runs.map(&:id) + @gene_filtering_runs.map(&:id)).compact.uniq
      metadata_annots = if metadata_store_run_ids.any?
        Annot.light.where(project_id: @project.id, store_run_id: metadata_store_run_ids, data_type_id: 3, dim: 1).order(:name).to_a
      else
        []
      end
      @metadata_annots_by_run = {}
      metadata_annots.each do |annot|
        run_id = annot.store_run_id || annot.run_id
        next unless run_id
        @metadata_annots_by_run[run_id] ||= []
        @metadata_annots_by_run[run_id] << { id: annot.id, name: annot.name }
      end

      store_run_id = @parsing_run&.id
      @annots = (store_run_id && @metadata_annots_by_run[store_run_id]) ? @metadata_annots_by_run[store_run_id] : []
      
      @h_annots = {}
      @h_annot_runs = {}
      metadata_annots.each { |a| @h_annots[a.id] = { name: a.name } }
      annot_run_ids = metadata_annots.map(&:run_id).compact.uniq
      Run.where(id: annot_run_ids).each { |r| @h_annot_runs[r.id] = r } if annot_run_ids.any?
      
      # Prepare QC data from parsing output
      @h_float = { "mito" => 1, "ribo" => 1, "protein_coding" => 1 }
      @h_data = {}
      @h_data_json = nil
      @cell_filtering_discarded_indices = []
      
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

      # For completed cell filtering runs, derive discarded cell indices by comparing
      # parsing and filtered CellID vectors. This keeps result plots accurate even when
      # run attrs do not store discarded indices in a directly usable format.
      begin
        if @current_run && @current_run.status_id == 3 && @parsing_run
          parsing_loom = project_dir + 'parsing' + 'output.loom'
          filtered_loom = project_dir + 'cell_filtering' + 'output.loom'

          if File.exist?(parsing_loom) && File.exist?(filtered_loom)
            parsing_cells = H5DataService.get_metadata_vector(parsing_loom.to_s, '/col_attrs/CellID')
            filtered_cells = H5DataService.get_metadata_vector(filtered_loom.to_s, '/col_attrs/CellID')

            if parsing_cells.is_a?(Array) && filtered_cells.is_a?(Array) && parsing_cells.any?
              kept = Set.new(filtered_cells.map { |v| v.to_s })
              @cell_filtering_discarded_indices = []
              parsing_cells.each_with_index do |cell_id, idx|
                @cell_filtering_discarded_indices << idx unless kept.include?(cell_id.to_s)
              end
            end
          end
        end
      rescue => e
        Rails.logger.warn("[prepare_cell_filtering_data] Could not derive discarded indices from loom files: #{e.class} - #{e.message}")
        @cell_filtering_discarded_indices ||= []
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
      end
    end

    def prepare_doublet_calling_data
      run = @run || @current_run || @runs&.first
      unless run
        @doublet_loom_path = nil
        @doublet_score_path = nil
        @doublet_call_path = nil
        @doublet_score_histogram = {}
        @doublet_scores = []
        @std_method = nil
        @h_run_attrs = {}
        @h_std_method_attrs = {}
        @h_annots_for_params = {}
        @h_ori_runs_for_params = {}
        @h_steps_for_params = {}
        @doublet_method_attrs = {}
        @doublet_param_sections = []
        return
      end

      project_dir = Pathname.new(ENV.fetch("USER_DATA_DIR")) + @project.user_id.to_s + @project.key
      step_dir = project_dir + @step.name.to_s
      output_dir = @step.multiple_runs ? (step_dir + run.id.to_s) : step_dir
      output_json_path = output_dir + "output.json"
      @h_res = File.file?(output_json_path) ? Basic.safe_parse_json(File.read(output_json_path), {}) : (@h_res || {})

      ctx = DoubletCallingFilterService.context_for_run(@project, run, @step)
      @doublet_loom_path = ctx[:loom_path]
      @doublet_score_path = ctx[:input_score_meta]
      @doublet_call_path = ctx[:output_call_meta]

      @std_method = run.std_method
      @h_run_attrs = Basic.safe_parse_json(run.attrs_json, {})
      @doublet_method_attrs = {}
      @doublet_param_sections = []
      if @std_method
        sm_attrs = Basic.get_std_method_attrs(@std_method, @step)
        @h_std_method_attrs = { @std_method.id => sm_attrs[:h_attrs] }
        @doublet_method_attrs = sm_attrs[:h_attrs] || {}
        layout = Basic.safe_parse_json(@std_method.attr_layout_json, [])
        layout.each do |block|
          (block["horiz_elements"] || []).each do |el|
            keys = Array(el["attr_list"]).map(&:to_s).reject(&:blank?)
            next if keys.empty?

            header = el["card-header"].presence || el["card_header"].presence
            @doublet_param_sections << { header: header, keys: keys }
          end
        end
      else
        @h_std_method_attrs = {}
      end

      annot_ids = []
      run_ids = []
      @h_run_attrs.each_value do |v|
        if v.is_a?(Hash)
          annot_ids << v["annot_id"] if v["annot_id"].present?
          run_ids << v["run_id"] if v["run_id"].present?
        elsif v.is_a?(Array)
          v.each do |item|
            next unless item.is_a?(Hash)
            annot_ids << item["annot_id"] if item["annot_id"].present?
            run_ids << item["run_id"] if item["run_id"].present?
          end
        end
      end
      @h_annots_for_params = annot_ids.any? ? Annot.light.where(id: annot_ids.uniq).index_by(&:id) : {}
      @h_ori_runs_for_params = run_ids.any? ? Run.where(id: run_ids.uniq).index_by(&:id) : {}
      step_ids = @h_ori_runs_for_params.values.map(&:step_id).compact.uniq
      @h_steps_for_params = step_ids.any? ? Step.where(id: step_ids).index_by(&:id) : {}

      raw_scores = H5DataService.get_metadata_vector(@doublet_loom_path, @doublet_score_path)
      @doublet_score_histogram = DoubletCallingFilterService.score_histogram(raw_scores)
      @doublet_scores = Array(raw_scores).map { |v| (Float(v) rescue nil) }.compact
    rescue DoubletCallingFilterService::FilterError => e
      Rails.logger.warn("[prepare_doublet_calling_data] #{e.message}")
      @doublet_loom_path = nil
      @doublet_score_path = nil
      @doublet_call_path = nil
      @doublet_score_histogram = {}
      @doublet_scores = []
      @std_method = nil
      @h_run_attrs = {}
      @h_std_method_attrs = {}
      @h_annots_for_params = {}
      @h_ori_runs_for_params = {}
      @h_steps_for_params = {}
      @doublet_method_attrs = {}
      @doublet_param_sections = []
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
      @show_specific_view = false
      
      # Convert runs to array for consistent checking
      runs_array = @runs.to_a
      runs_count = runs_array.size
      # Total runs for this step without UI filtering (loom filter, etc.).
      # We only show the std form for multi-run steps when there are truly no runs at all.
      total_run_step_ids =
        if @step.multiple_runs
          Step.where(docker_image_id: @step.docker_image_id, name: @step.name).pluck(:id)
        else
          [@step.id]
        end
      total_runs_count = apply_publication_snapshot_to_runs(
        @project.runs.where(step_id: total_run_step_ids)
      ).count
      
      Rails.logger.info("[prepare_std_step_data] Step: #{@step.name}, multiple_runs: #{@step.multiple_runs}, has_std_dashboard: #{@step.has_std_dashboard}, has_std_view: #{@step.has_std_view}, runs_count: #{runs_count}")
      
      # Check if show_form parameter is set (for "New run" button)
      show_form_requested = params[:show_form].present? && params[:show_form].to_s == '1'
      explicit_show_form = params[:force_show_form].present? && params[:force_show_form].to_s == '1'
      force_show_form = show_form_requested && (explicit_show_form || !@step.multiple_runs || runs_count == 0)
      prefer_runs_list = params[:prefer_runs_list].present? && params[:prefer_runs_list].to_s == '1'
      # When multiple_runs step has existing runs and user did not explicitly request the form,
      # prefer showing the runs list (avoids stale show_form=1 in URL showing form instead of runs)
      prefer_runs_list = prefer_runs_list || (@step.multiple_runs && runs_count > 0 && !force_show_form)
      Rails.logger.info("[prepare_std_step_data][debug] step_id=#{@step.id} step_name=#{@step.name} multiple_runs=#{@step.multiple_runs} runs_count=#{runs_count} show_form_requested=#{show_form_requested} explicit_show_form=#{explicit_show_form} force_show_form=#{force_show_form} prefer_runs_list=#{prefer_runs_list} has_std_form=#{@step.has_std_form} has_std_dashboard=#{@step.has_std_dashboard} has_std_view=#{@step.has_std_view}")

      # Explicit override used when returning from Pipeline Graph:
      # for multi-run steps with existing runs, always show runs list/dashboard.
      if prefer_runs_list && @step.multiple_runs && runs_count > 0
        Rails.logger.info("[prepare_std_step_data][debug] prefer_runs_list override activated -> show_dashboard=true")
        @show_dashboard = true
        @h_cards = create_run_cards(runs_array, nil)
        return
      end
      
      # If show_form is requested and step has std_form, show form.
      # For single-run steps, only allow this when no run exists.
      if force_show_form && !prefer_runs_list && @step.has_std_form && (@step.multiple_runs || runs_count == 0)
        @show_form = true
        prepare_std_form_data
      # For steps with only one run authorized (multiple_runs == false) that are just unlocked (no runs yet)
      elsif !@step.multiple_runs && runs_count == 0
        if @selected_loom_file.present? && total_runs_count > 0
          # Run exists, but not in the selected loom context: keep empty-state panel.
          @show_dashboard = false
          @show_view = false
          @show_form = false
          @show_custom_form = false
        elsif @step.has_std_form
          # Show standard form if std_form option is activated
          @show_form = true
          prepare_std_form_data
        else
          # Show specific partial _<step_name>_form.html.erb if std_form == false
          @show_custom_form = true
        end
      # If no runs at all and has_std_form (for multiple_runs steps), show form.
      # If runs are merely filtered out in the current view, keep the runs list panel.
      elsif runs_count == 0 && total_runs_count == 0 && @step.has_std_form
        @show_form = true
        prepare_std_form_data
      # When multiple_runs == true, has_std_dashboard == true, and at least one run exists, show standard dashboard
      elsif @step.multiple_runs && @step.has_std_dashboard && runs_count > 0
        Rails.logger.info("[prepare_std_step_data] Setting show_dashboard = true for step: #{@step.name}")
        @show_dashboard = true
        # Prepare dashboard data
        @h_cards = create_run_cards(runs_array, nil)
      # For single-run steps with existing runs, always show a single-run panel.
      # If has_std_view is false, a step-specific _<step>_view partial can take over.
      elsif !@step.multiple_runs && runs_count > 0
        @show_view = true
        @show_specific_view = !@step.has_std_view
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
      all_std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, obsolete: false, step_id: @step.id).order(:name).to_a
      all_std_methods.each { |s| @h_std_methods[s.id] = s }
      
      @std_methods = all_std_methods
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

      # Get data classes for validation
      h_data_classes = {}
      DataClass.all.each { |dc| h_data_classes[dc.id] = dc; h_data_classes[dc.name] = dc }

      source_step_names = []
      @std_methods.each do |std_method|
        begin
          h_res = Basic.get_std_method_attrs(std_method, @step)
          combined_attrs = h_res[:h_attrs] || {}
        rescue
          combined_attrs = @h_obj_attrs_by_std_method[std_method.id] || {}
        end
        combined_attrs.each_value do |attr_config|
          next unless attr_config.is_a?(Hash)
          next unless attr_config['source_steps'].present? && attr_config['valid_types'].present?
          source_step_names.concat(Array(attr_config['source_steps']))
        end
      end
      source_step_ids = source_step_names.uniq.map { |ssn| @h_steps_by_name[ssn]&.id }.compact
      source_run_ids = if source_step_ids.any?
                         Run.where(project_id: @project.id, step_id: source_step_ids).pluck(:id)
                       else
                         []
                       end
      all_annots = if source_step_ids.any? || source_run_ids.any?
                     annots_scope = Annot.light.where(project_id: @project.id)
                     clause = []
                     values = []
                     if source_step_ids.any?
                       clause << "(step_id IN (?) OR ori_step_id IN (?) OR sim_step_id IN (?))"
                       values << source_step_ids << source_step_ids << source_step_ids
                     end
                     if source_run_ids.any?
                       clause << "(run_id IN (?) OR ori_run_id IN (?))"
                       values << source_run_ids << source_run_ids
                     end
                     annots_scope.where(clause.join(' OR '), *values).to_a
                   else
                     []
                   end
      runs_by_id = if source_run_ids.any?
                     Run.where(id: source_run_ids).index_by(&:id)
                   else
                     {}
                   end
      
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
          next if optional_std_method_input_attr?(attr_config)
          
          source_steps = attr_config['source_steps']
          valid_types = attr_config['valid_types']
          
          # Get source step IDs from project's docker_image_id
          source_step_ids = source_steps.map { |ssn| @h_steps_by_name[ssn]&.id }.compact
          next if source_step_ids.empty?
          
          # Filter annotations to only those from source steps
          source_annots = all_annots.select do |annot|
            annot.matches_source_step_ids?(source_step_ids)
          end

          # Apply source_methods / excluded_source_methods filtering
          source_methods_filter = attr_config['source_methods']
          excluded_source_methods_filter = attr_config['excluded_source_methods']
          if source_methods_filter.present? || excluded_source_methods_filter.present?
            h_std_methods_by_id = @h_std_methods_by_id_cache ||= StdMethod.where(id: runs_by_id.values.map(&:std_method_id).compact.uniq).index_by(&:id)
            h_steps_by_id = @h_steps_by_name.values.index_by(&:id)
            source_annots = source_annots.select do |annot|
              run = runs_by_id[annot.run_id] || runs_by_id[annot.ori_run_id]
              next true unless run&.std_method_id
              method_record = h_std_methods_by_id[run.std_method_id]
              next true unless method_record
              source_step = h_steps_by_id[run.step_id]
              next true unless source_step
              step_name = source_step.name
              if source_methods_filter.present? && source_methods_filter[step_name].present?
                next source_methods_filter[step_name].include?(method_record.name)
              end
              if excluded_source_methods_filter.present? && excluded_source_methods_filter[step_name].present?
                next !excluded_source_methods_filter[step_name].include?(method_record.name)
              end
              true
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
        Basic.ensure_clustering_nber_clusters_key!(@h_res) if @step&.name == 'clustering'
        @h_outputs = Basic.safe_parse_json(run.output_json, {}) if run.output_json.present? && run.output_json.match(/^\{/)
      rescue => e
        Rails.logger.error("[prepare_run_view_data] Error loading run data: #{e.message}")
      end
      
      # Get annotations
      @h_annots_by_dim = {}
      annots = Annot.light.where(run_id: run.id).all
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
      
      dataset_results_html = helpers.render_results_dataset_sections(
        @h_annots_by_dim,
        variant: :legacy_button,
        pluralize_all: false
      )
      
      # Set standard card elements
      @h_el = {
        "card-params" => {
          card_header: 'Parameters',
          card_body: display_run_attrs(
            run,
            @h_run_attrs,
            @h_std_method_attrs,
            {
              h_annots: (@h_annots_for_params || {}),
              h_runs: (@h_ori_runs_for_params || {}),
              h_steps: (@h_steps_for_params || {})
            }
          )
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
          }.join(" ") : '') + dataset_results_html
        }
      }

      if @step.name == 'heatmap' && run.status_id == 3
        open_heatmap_path = project_path(@project, view: 'heatmap', run_id: run.id)
        @h_el["card-heatmap"] = {
          card_header: 'Heatmap',
          card_body: %(<div class="py-4 px-2 text-center">
            <p class="text-sm text-gray-600 mb-3">Open the full-page heatmap viewer for this run.</p>
            <a href="#{open_heatmap_path}"
               class="inline-flex items-center gap-2 px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 text-white rounded-md font-medium text-xs transition-colors cursor-pointer border border-indigo-600 shadow-sm">
              <i class="fas fa-th"></i>
              <span>Open heatmap viewer</span>
            </a>
          </div>).html_safe
        }
      end
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
          Basic.ensure_clustering_nber_clusters_key!(h_res) if @h_steps[run.step_id]&.name == 'clustering'
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
        
        status_name = @h_statuses[run.status_id]&.ui_label || Status.find_by(id: run.status_id)&.ui_label || 'Unknown'
        status_badge_classes = case run.status_id
        when 1 then 'bg-yellow-100 text-yellow-800'
        when 2 then 'bg-blue-100 text-blue-800'
        when 3 then 'bg-green-100 text-green-800'
        when 4 then 'bg-red-100 text-red-800'
        else 'bg-gray-100 text-gray-800'
        end
        
        run_time = (run.start_time && run.duration) ? (run.start_time + run.duration) : Time.now
        estimated_time_txt = (run.pred_process_duration) ? "Estimated #{helpers.duration(run.pred_process_duration)} - " : ''
        
        card_body = [
          "<div class='flex items-center justify-between mb-2'><div class='font-semibold text-gray-900'>#{helpers.display_run(run)}</div><span class='inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium #{status_badge_classes}'>#{status_name}</span></div>",
          "<p class='text-xs font-semibold text-gray-600 uppercase tracking-wide mb-2'>Parameters</p>",
          helpers.display_run_attrs(run, h_attrs, h_std_method_attrs, {}),
          ((run.status_id == 3 && @h_dashboard_card && @h_dashboard_card[run.step_id] && @h_dashboard_card[run.step_id]["output_values"] && @h_dashboard_card[run.step_id]["output_values"].size > 0) ? ("<p class='text-xs font-semibold text-gray-600 uppercase tracking-wide mt-3 mb-2'>Output summary</p><div class='flex flex-wrap gap-1.5'>" + @h_dashboard_card[run.step_id]["output_values"].select { |e| h_res.key?(e["key"]) }.map { |e| v = h_res[e["key"]]; disp = v.nil? ? "NA" : v; "<span class='inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-700 border border-blue-200'>#{e["label"]}:#{disp}</span>" }.join(" ") + "</div>") : ''),
          ((h_files.keys.size > 0) ? ("<p class='text-xs font-semibold text-gray-600 uppercase tracking-wide mt-3 mb-2'>Results</p><div class='flex flex-wrap gap-1.5'>" + h_files.keys.map { |k| helpers.display_download_btn(run, h_files[k]) }.join(" ") + "</div>") : ""),
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
        
        card_footer = "<small class='text-gray-500'>" +
          "##{run.id}, " +
          [
            "<span class='nowrap'>#{run.created_at&.strftime("%Y-%m-%d %H:%M") || 'N/A'}</span>",
            ((run.waiting_duration && ![1, 6].include?(run.status_id)) ? "<span class='nowrap'>Wait #{helpers.duration(run.waiting_duration.to_i)}</span>" : (([1, 6].include?(run.status_id) && run.submitted_at) ? "<span id='ongoing_wait_#{run.id}' class='nowrap'>Wait #{helpers.duration((Time.now - run.submitted_at).to_i)}</span>" : nil)),
            ((run.duration && run.status_id != 2) ? "<span class='nowrap'>Run #{helpers.duration(run.duration.to_i)}</span>" : (([1, 2].include?(run.status_id)) ? "<br/>#{estimated_time_txt}<span id='ongoing_run_#{run.id}' class='nowrap'>Run #{helpers.duration((run.start_time) ? (Time.now - run.start_time).to_i : 0)}</span>" : nil)),
            ((run.max_ram) ? "<span class='nowrap'>Max. RAM #{helpers.display_mem(run.max_ram * 1000)}</span>" : nil),
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
      (@h_statuses && @h_statuses[status_id])&.ui_label || Status.find_by(id: status_id)&.ui_label || 'Unknown'
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
          Basic.ensure_clustering_nber_clusters_key!(@h_res) if step.name == 'clustering'
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
          Annot.light.where(run_id: run.id).each { |a| @h_annots_by_dim[a.dim] ||= []; @h_annots_by_dim[a.dim].push(a) }

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

          dataset_results_html = helpers.render_results_dataset_sections(
            @h_annots_by_dim,
            variant: :link_chip,
            pluralize_all: true
          )

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

          # Build parameter context before rendering card-params so badges are consistent
          # with the run list (same labels/colors for dataset-like values such as covariates).
          @h_annots_for_params = {}
          @h_ori_runs_for_params = {}
          @h_steps_for_params = {}
          annot_ids = []
          direct_run_ids = []
          @h_run_attrs.each_value do |v|
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
            Annot.light.where(id: annot_ids.uniq).each do |annot|
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

          @h_el = {
            "card-params" => {
              card_header: 'Parameters',
              card_body: helpers.display_run_attrs(
                run,
                @h_run_attrs,
                @h_std_method_attrs,
                {
                  h_annots: @h_annots_for_params,
                  h_runs: @h_ori_runs_for_params,
                  h_steps: @h_steps_for_params
                }
              )
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
              }.join(" ") : '') + dataset_results_html
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
          Annot.light.where(id: annot_ids.uniq).each do |annot|
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

