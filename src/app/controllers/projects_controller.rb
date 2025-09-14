class ProjectsController < ApplicationController
  before_action :set_project, only: %i[ show edit update destroy ]

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
    @available_metadata = Annot.available_metadata(@project.id)
    
    @h_metadata = organize_metadata(@available_metadata)

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

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_project
      @project = Project.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def project_params
      params.fetch(:project, {})
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
