class RunsController < ApplicationController
  skip_before_action :authenticate_user!, only: [:report_error], raise: false
  before_action :set_run, only: [:get_de_gene_list, :get_ge_geneset_list, :show, :edit, :update, :destroy, :restart, :stop, :report_error]
  before_action :authorize_publication_snapshot_run_access, only: [:get_de_gene_list, :get_ge_geneset_list, :show, :report_error]
  before_action :get_base_data, only: [:get_de_gene_list, :get_ge_geneset_list]
  include ApplicationHelper
  
  def get_base_data 
    @h_dashboard_card = {}
    @h_dashboard_card[@step.id] = JSON.parse(@step.dashboard_card_json)
    @h_attrs = (@step.attrs_json and !@step.attrs_json.empty?) ? JSON.parse(@step.attrs_json) : {}
    @h_nber_runs = JSON.parse(@ps.nber_runs_json)
    @h_steps = {}
    #    Step.where(:version_id => @project.version_id).all.map{|s| @h_steps[s.id] = s}
    Step.where(:docker_image_id => @asap_docker_image.id).all.map{|s| @h_steps[s.id] = s}
    @h_statuses = {}
    Status.all.map{|s| @h_statuses[s.id] = s}
    #    @h_std_methods = {}
    #    StdMethod.all.map{|s| @h_std_methods[s.id] = s}
  end

  def get_ge_geneset_list
    params[:from] ||= 'ge_results'
    @h_ge_filters = Basic.safe_parse_json(@project.ge_filter_json, {})
    @limit = 3000
    @data = []
    @h_run_attrs = (@run.attrs_json) ? JSON.parse(@run.attrs_json) : {}

    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    filename =  @project_dir + "ge" + @run.id.to_s + "output.json"
    h_output = Basic.safe_parse_json(File.read(filename), {})
    @fields = h_output["headers"]
    h_fields = {}
    @fields.each_index do |i|
      h_fields[@fields[i]] = i
    end
#    h_fields['genes'] = h_fields.keys.size

#    @h_gsis = {}
#    res = Basic.sql_query2(:asap_data, @h_env['asap_data_db_version'], 'gene_set_items', '', '*', "gene_set_id = #{@h_run_attrs['gene_set_id']} and identifier IN (#{h_output[params[:type]].map{|e| e[0]}})")
#    res.each do |gs|
#      @h_gene_set_items[gsi.name] = gsi
#    end

#    h_genes = Basic.safe_parse_json(params[:genes_json], {})
    
    if  h_output[params[:type]]
      h_output[params[:type]].sort{|a, b| b[h_fields['effect size']].to_f <=> a[h_fields['effect size']].to_f}.each do |e|
        #      h_output[params[:type]].each do |e|
        if e[h_fields['fdr']] <= @h_ge_filters['fdr_cutoff'].to_f
   #       e['genes'] =  @h_gene_set_items[e['name']].content.split(",").map{|gid| gid.to_i}.select{|gid| h_genes[gid]}.map{|g| h_genes[gid]}]  
          @data.push e
        end
      end
    end
    @nber_genesets = @data.size
    
    if !params[:download]
      if params[:from] == 'ge_results'
        render :partial => 'get_ge_geneset_list'
      elsif params[:from] == 'markers'
        render :partial => 'get_simple_ge_geneset_list'
      end
    else
      run_label = "run#{@run.num}#{@std_method ? "_#{@std_method.name}" : ""}"
      ext = (params[:format] == 'json') ? 'json' : 'txt'
      content = (params[:format] == 'json') ? @data.to_json : @data.map { |e| e.join("\t") }.join("\n")
      send_data content, type: 'text', disposition: "attachment; filename=#{@project.key}_#{run_label}_ge_#{params[:type]}.#{ext}"
    end
        
  end
  
  def get_de_gene_list
    params[:from] ||= 'de_results'
    @fields = ["Gene index", "EnsemblID", "Gene name", "Alt names", "Description", "logFC", "P-value", "FDR", "Avg group1", "Avg group2"]
    @limit = 3000
    @h_std_method_attrs = {
      @std_method.id => Basic.get_std_method_attrs(@std_method, @step)[:h_attrs]
    }
    @h_run_attrs = (@run.attrs_json) ? JSON.parse(@run.attrs_json) : {}
    @data = []
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    @de_gene_list_annot_id = params[:de_annot_id].presence
    de_list_dir = Basic.de_filter_gene_list_dir(@project_dir, @run.id, @de_gene_list_annot_id)
    list_filtered_rows = []
    if params[:from]== 'ge_form'
      filename = @project_dir + "tmp" + "#{de_filter_cache_key}_#{@run.id}_filtered.json"
      tmp_h = Basic.safe_parse_json(File.read(filename), {})
      list_filtered_rows = tmp_h[params[:type]] if tmp_h[params[:type]]
    else
      filename = de_list_dir + "filtered.#{params[:type]}.json"
      list_filtered_rows = Basic.safe_parse_json(File.read(filename), [])
    end
    @h_filtered_rows = {}
#    list_filtered_rows = []
#    begin
#      list_filtered_rows = JSON.parse(File.read(filename))
#    rescue
#    end
    list_filtered_rows.map{|e| @h_filtered_rows[e.to_i] = 1}
    @nber_genes = list_filtered_rows.size
    
    output_txt = de_list_dir + 'output.txt'
    i = 0
    j = 0

    @tmp_data = File.readlines(output_txt)
    if params[:type] == 'up'
      #File.open(filename, 'r') do |f|
      @tmp_data.reverse.each do |l|     
        #      while (l = f.gets  and (params[:download] or j < @limit) 
        if @h_filtered_rows[@tmp_data.size-1-i]
          t = l.chomp.split("\t")
          t[2] = t[2].split(",").join(", ")
          @data.push t
          j+=1
        end
        i+=1
        if j == @limit and !params[:download]
          break
        end
      end
    else
      
      @tmp_data.each do |l|
        if @h_filtered_rows[i]
          t = l.chomp.split("\t")
          t[2] = t[2].split(",").join(", ")
          @data.push t
          j+=1
        end
        i+=1
        if j == @limit and !params[:download]
          break
        end
      end
    end
    #end
    #    @data.reverse! if params[:type] == 'up'
    if !params[:download]
      render :partial => 'get_de_gene_list'
    else
      run_label = "run#{@run.num}#{@std_method ? "_#{@std_method.name}" : ""}"
      ext = (params[:format] == 'json') ? 'json' : 'txt'
      content = (params[:format] == 'json') ? @data.to_json : @data.map { |e| e.join("\t") }.join("\n")
      send_data content, type: 'text', disposition: "attachment; filename=#{@project.key}_#{run_label}_de_table_#{params[:type]}.#{ext}"
    end
  end

  # GET /runs
  # GET /runs.json
  def index
    @runs = Run.all
  end

  # GET /runs/1
  # GET /runs/1.json
  def show
    # Prepare data for displaying the run
    prepare_run_show_data
    
    # If panel parameter is present, render panel partial instead of full page
    if params[:panel] == '1'
      render partial: 'panel', layout: false
      return
    end
  end
  
  def prepare_run_show_data
    # Get status
    @status = Status.find_by(id: @run.status_id)
    
    # Parse run attributes
    @h_run_attrs = {}
    if @run.attrs_json.present?
      @h_run_attrs = Basic.safe_parse_json(@run.attrs_json, {})
    end
    
    # Get standard method attributes using the helper method
    @h_std_method_attrs = {}
    if @std_method && @step
      h_res = Basic.get_std_method_attrs(@std_method, @step)
      @h_std_method_attrs = h_res[:h_attrs] || {}
    elsif @std_method && @std_method.attrs_json.present?
      @h_std_method_attrs = Basic.safe_parse_json(@std_method.attrs_json, {})
    end
    
    # Get dashboard card configuration
    @h_dashboard_card = {}
    if @step.dashboard_card_json.present?
      @h_dashboard_card[@step.id] = Basic.safe_parse_json(@step.dashboard_card_json, {})
    end
    
    # Load output data
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    step_dir = @project_dir + @step.name
    output_dir = (@step.multiple_runs) ? (step_dir + @run.id.to_s) : step_dir
    output_json_file = output_dir + "output.json"
    
    @h_res = {}
    @h_outputs = {}
    
    begin
      @h_res = Basic.safe_parse_json(File.read(output_json_file), {}) if File.exist?(output_json_file)
      @h_outputs = Basic.safe_parse_json(@run.output_json, {}) if @run.output_json.present? && @run.output_json.match(/^\{/)
    rescue => e
      Rails.logger.error("[prepare_run_show_data] Error loading run data: #{e.message}")
    end
    
    # Get steps hash for display helpers
    @h_steps = {}
    Step.where(docker_image_id: @asap_docker_image.id).each { |s| @h_steps[s.id] = s }
    
    # Get statuses hash
    @h_statuses = {}
    Status.all.each { |s| @h_statuses[s.id] = s }
    
    # Prepare std_view data if step has std_view enabled
    if @step && @step.has_std_view
      # Get annotations by dimension
      @h_annots_by_dim = {}
      annots = Annot.where(run_id: @run.id).all
      annots.each { |a| @h_annots_by_dim[a.dim] ||= []; @h_annots_by_dim[a.dim].push(a) }
      
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
        h_links = {}
        output_links_config = @h_dashboard_card[@step.id]["output_links"]
        if @h_outputs && output_links_config
          output_links_config.each do |link_config|
            key = link_config["key"]
            if @h_outputs[key]
              h_links[key] = @h_outputs[key]
            end
          end
        end
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
        variant: :link_chip,
        pluralize_all: true
      )
      
      # Add exec.out and exec.err files for admin
      exec_files_html = ""
      if admin?
        step_dir = @project_dir + @step.name
        output_dir = (@step.multiple_runs) ? (step_dir + @run.id.to_s) : step_dir
        exec_out_path = output_dir + "exec.out"
        exec_err_path = output_dir + "exec.err"
        
        exec_files = []
        if File.exist?(exec_out_path)
          file_size = File.size(exec_out_path)
          file_size_display = display_mem(file_size)
          exec_files << "<a href='#{get_file_project_path(@project, filename: 'exec.out', step: @step.name, run_id: @run.id)}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors'><span>exec.out</span><span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{file_size_display}</span></a>"
        end
        if File.exist?(exec_err_path)
          file_size = File.size(exec_err_path)
          file_size_display = display_mem(file_size)
          exec_files << "<a href='#{get_file_project_path(@project, filename: 'exec.err', step: @step.name, run_id: @run.id)}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors'><span>exec.err</span><span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{file_size_display}</span></a>"
        end
        
        exec_files_html = exec_files.any? ? exec_files.join("") : ""
      end
      
      # Set standard card elements (will be overridden with improved content in view)
      @h_el = {
        "card-params" => {
          card_header: 'Parameters',
          card_body: display_run_attrs(@run, @h_run_attrs, @h_std_method_attrs, {})
        },
        "card-downloads" => {
          card_header: 'Downloads',
          card_body: ((h_files.keys.size > 0) ? ("<div class='flex flex-wrap gap-1 items-start'>" + h_files.keys.map { |k| display_download_btn(@run, h_files[k]) }.join("") + "</div>") : "") + (exec_files_html.present? ? "<div class='flex flex-wrap gap-1 items-start mt-1'>" + exec_files_html.strip + "</div>" : "")
        },
        "card-results" => {
          card_header: 'Results',
          card_body: ((@run.status_id == 3 && @h_res['warnings']) ? @h_res['warnings'].map { |e|
            if e.is_a?(Hash)
              "<p class='text-warning text-truncate' title=\"#{e['name']}. #{e['description']}\">#{e['name']}</p>"
            else
              "<p class='text-warning text-truncate' title='#{e}'>#{e}</p>"
            end
          }.join(" ") : '') + dataset_results_html
        }
      }

      if @step.name == 'heatmap' && @run.status_id == 3
        open_heatmap_path = project_path(@project, view: 'heatmap', run_id: @run.id)
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
    
    # Pre-load annots and their associated runs/steps for dataset parameters
    @h_annots_for_params = {}
    @h_ori_runs_for_params = {}
    @h_steps_for_params = {}
    annot_ids = []
    direct_run_ids = []
    h_attrs = @run.attrs_json.present? ? Basic.safe_parse_json(@run.attrs_json, {}) : {}
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
  end

  # GET /runs/new
  def new
    @run = Run.new
  end

  # GET /runs/1/edit
  def edit
  end

  # POST /runs
  # POST /runs.json
  def create
    @run = Run.new(run_params)

    respond_to do |format|
      if admin? and @run.save
        format.html { redirect_to @run, notice: 'Run was successfully created.' }
        format.json { render :show, status: :created, location: @run }
      else
        format.html { render :new }
        format.json { render json: @run.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /runs/1
  # PATCH/PUT /runs/1.json
  def update
    if @project.locked_from_publication?(@run)
      respond_to do |format|
        format.html { redirect_to project_path(@project), alert: 'This run was created before publication and cannot be edited.' }
        format.json { render json: { status: 'error', message: 'This run was created before publication and cannot be edited.' }, status: :forbidden }
      end
      return
    end

    respond_to do |format|
      if admin? and  @run.update(run_params)
        format.html { redirect_to @run, notice: 'Run was successfully updated.' }
        format.json { render :show, status: :ok, location: @run }
      else
        format.html { render :edit }
        format.json { render json: @run.errors, status: :unprocessable_entity }
      end
    end
  end

  def self.destroy_run project, step, run
    if project.locked_from_publication?(run)
      raise PublicationLockedDeletionError, 'This run was created before publication and cannot be deleted.'
    end

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    step_dir = project_dir + step.name
    output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    
    tmp_dir = project_dir + 'tmp'
    FileUtils.mkdir_p(tmp_dir)
    ## kill run if necessary
    Basic.kill_run run
    
    ## remove potential annotations
    ### from the loom
    #run.annots.each do |annot|
    h_outputs = JSON.parse(run.output_json)
    logger.debug(h_outputs.to_json)
    
    annots1 = run.annots 
    annots2 = Annot.where(:ori_run_id => run.id).all
    #store_run_annots = Annot.where(:store_run_id => run.id).all
    now = Time.now.to_i
    h_annots= {}
    all_annots = (annots1 | annots2)
    all_annots.each do |annot|
      h_annots[annot.filepath]||=[] 
      h_annots[annot.filepath].push annot
    end
    h_annots.each_key do |filepath|
      if File.exist? (project_dir + filepath) and !["gene_filtering", "cell_filtering"].include? step.name
        tmp_file = project_dir + "tmp" + ("remove_metadata_#{now}.json")
        tmp_data = {:meta => h_annots[filepath].map{|a| a.name}}
        File.open(tmp_file, 'w') do |f|
          f.write tmp_data.to_json
        end
        cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T RemoveMetaData -loom #{project_dir + filepath} -metaJSON '#{tmp_file}' 2>&1 > tmp/remove_metadata_output_#{now}.json"
        File.open(project_dir + "tmp" + "toto.txt", "w") do |f|
          f.write("CMD: " + cmd)
          `#{cmd}`
        end
      end
    end
    ## delete loom file if it's a filtering 
    #    if ["gene_filtering", "cell_filtering"].include? step.name
    #      h_annots.each_key do |filepath|
    #        File.delete(project_dir + filepath) if 
    #      end
    #    end
    #    (annots1 | annots2).each do |annot|
    #      if File.exist? (project_dir + annot.filepath)
    #        cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T RemoveMetaData -o #{tmp_dir} -loom #{project_dir + annot.filepath} -meta '#{annot.name}' 2>&1 > tmp/bla.txt"
    #        logger.debug("CMD: " + cmd)
    #        `#{cmd}`
    #      end
    #    end
    
    #    if h_outputs
    #      h_outputs.each_key do |k|
    #        h_outputs[k].each_key do |output_key|
    #          t = output_key.split(":")
    #          if t.size == 2 
    #            if File.exist? (project_dir + t[0])
    #              cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T RemoveMetaData -o #{tmp_dir} -loom #{project_dir + t[0]} -meta #{t[1]} 2>&1 > tmp/bla.txt"
    #              logger.debug("CMD: " + cmd)
    #              `#{cmd}`
    #            end
    #            #        elsif t.size == 1
    #            #          if File.exist? (project_dir + t[0])
    #            #            logger.debug("DEL_FILE: " + t.to_json + '---' + (project_dir + t[0]).to_s)
    #            #            File.delete (project_dir + t[0]) 
    #            #          end
    #          end
    #        end
    #      end
    #    end
    
    #    logger.debug()
    FileUtils.rm_r output_dir if File.exist? output_dir
    
    ### from the database
    all_annots.map do |annot| 
    #  cell_sets = CellSet.where(:id => annot.clas.map{|e| e.cell_set_id}).all
    #  cell_sets.each do |cell_set|
    #    other_clas = Cla.
    #  end
      annot.clas.map{|c| c.cla_votes.destroy_all}
      annot.clas.destroy_all
      annot.annot_cell_sets.destroy_all
    end
    annots1.destroy_all
    annots2.destroy_all
 
#    all_annots.destroy_all
    store_run_annots = Annot.where(:store_run_id => run.id).all
    store_run_annots.map{|annot| 
      annot.clas.map{|c| c.cla_votes.destroy_all}
      annot.clas.destroy_all
      annot.annot_cell_sets.destroy_all
    }
    store_run_annots.destroy_all ## shouldn't need to add this line if everything happens normally...
    run.fos.destroy_all
    
    ## remove the run
    active_run = run.active_run
    active_run.destroy if active_run
    
    ## move run in the deleted_runs if it finished or failed                                                                                                                    
    if [3, 4].include? run.status_id
      h_run = run.as_json
      # Remove slurm_job_id as it doesn't exist in del_runs table
      h_run.delete("slurm_job_id")
      if ! DelRun.where(h_run).first
        del_run = DelRun.new(h_run)
        del_run.run_id = h_run["id"]
        del_run.save!        
      end
    end
    
    run.destroy  
    
      
  end

  def self.destroy_children project, step, run #, h_step_ids
    if run.children_run_ids
      run_children = run.children_run_ids.split(",")
      if run_children.size > 0
        @log += "children: " + run_children.to_json + ". "
        runs = Run.where(:project_id => project.id, :id => run_children).all
        runs.each do |run|
          @h_step_ids[run.step_id] = 1
          @log += "call destroy_children on #{run.id}. "
          h_step_ids = destroy_children project, step, run
        end
      end
    end
    # else
    @h_step_ids[run.step_id] = 1
    @log += "destroy #{run.id}. "
    destroy_run project, step, run

    #return h_step_ids
    #  end
  end
  
  def self.destroy_run_call project, run
    if project.locked_from_publication?(run)
      raise PublicationLockedDeletionError, 'This run was created before publication and cannot be deleted.'
    end

    start_time = Time.now
    @log = ""
    log = ''
    log += (Time.now - start_time).to_s + " step 2</br>"

    step = run.step

    ActiveRecord::Base.transaction do

      ## edit parent's children_run_ids                                                                                                                                  
      parents = (run.run_parents_json) ? JSON.parse(run.run_parents_json) : []
      if parents
        parent_runs = Run.where(:project_id => project.id, :id => parents.map{|p| p['run_id']}).all
        parent_runs.each do |parent_run|
          children_run_ids = parent_run.children_run_ids.split(",").reject{|e| e == run.id}
          parent_run.update_attribute(:children_run_ids, children_run_ids.join(","))
        end
      end
      
      log += (Time.now - start_time).to_s + " step 3</br>"
      ## destroy run and descendants                                                                                                                                                                                    
      log += "call destroy_children on #{run.id}. "
      @h_step_ids = {}
      destroy_children project, step, run
      
      log += (Time.now - start_time).to_s + " step 4</br>"
      ### update project_step for each step affected                                                                                                                                                                    
      @h_step_ids.each_key do |step_id|
        Basic.upd_project_step project, step_id
      end
      
      log += (Time.now - start_time).to_s + " step 5</br>"
      Basic.upd_project_size project
    end

    ## Broadcast project/step updates so subscribed clients refresh the
    ## header status summary (project_run_totals) and the left pipeline
    ## steps panel (h_nber_analyses). Done after the transaction so the
    ## background job reads committed data.
    @h_step_ids.each_key do |step_id|
      project.broadcast(step_id)
    end

    return log

  end

  def destroy_run_call project, run
    RunsController.destroy_run_call(project, run)
  end

  # DELETE /runs/1
  # DELETE /runs/1.json
  # POST /runs/:id/restart
  # Re-submit an existing run without going through the form.
  # Intended for steps with multiple_runs == true (steps with a single run are
  # handled by the Reset button, which deletes the run and redirects to the
  # form).
  #
  # The command is rebuilt from the run's stored attrs_json via Basic.set_run
  # so that any fix applied to the command-building code (or to referenced
  # annotations/datasets) is picked up on restart. Only runs in a terminal
  # non-success state can be restarted (failed or stopped); pending or
  # running runs must be stopped first via the Stop button.
  def restart
    unless editable?(@project) && analyzable?(@project)
      render json: { status: 'error', message: 'You do not have permission to restart runs on this project.' }, status: :forbidden
      return
    end

    if @project.locked_from_publication?(@run)
      render json: { status: 'error', message: 'This run was created before publication and cannot be restarted.' }, status: :forbidden
      return
    end

    unless @step && @step.multiple_runs
      render json: { status: 'error', message: 'Restart is only available for steps that allow multiple runs.' }, status: :unprocessable_entity
      return
    end

    unless [4, 5].include?(@run.status_id.to_i)
      render json: { status: 'error', message: 'Only failed or stopped runs can be restarted. Stop the run first if it is pending or running.' }, status: :unprocessable_entity
      return
    end

    unless @std_method
      render json: { status: 'error', message: 'Run has no associated std_method; cannot rebuild command.' }, status: :unprocessable_entity
      return
    end

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    step_dir = project_dir + @step.name
    output_dir = Basic.run_output_dir(@run)
    Basic.clear_step_run_output_files!(@run, logger: Rails.logger)
    FileUtils.mkdir_p(output_dir) unless File.directory?(output_dir.to_s)

    # Kill any running container associated with the run.
    Basic.kill_run(@run) rescue nil

    # Cancel any live SLURM job; the run may be queued or running.
    if @run.slurm_job_id.present?
      begin
        SlurmService.new(logger: Rails.logger).cancel_job(@run.slurm_job_id)
      rescue => e
        Rails.logger.warn("[runs#restart] scancel failed for Run##{@run.id} slurm_job_id=#{@run.slurm_job_id}: #{e.class} - #{e.message}")
      end
    end

    @run.update(
      status_id: 1,
      error: nil,
      pid: nil,
      slurm_job_id: nil,
      start_time: nil,
      duration: nil,
      process_duration: nil,
      max_ram: nil,
      submitted_at: Time.current,
      waiting_duration: nil
    )

    # Rebuild command_json from the persisted attrs_json using the current
    # code path (same as ReqsController#create_runs -> Req#set_runs). This
    # ensures any recent fix to Basic.set_run (or to referenced annotations /
    # datasets) is applied on restart.
    h_cmd_params = JSON.parse(@step.command_json)
    std_method_cmd = JSON.parse(@std_method.command_json)
    std_method_cmd.each { |k, v| h_cmd_params[k] = v }

    h_res_attrs = Basic.get_std_method_attrs(@std_method, @step)
    h_attrs = h_res_attrs[:h_attrs]

    h_data_classes = {}
    DataClass.all.each { |dc| h_data_classes[dc.id] = dc }

    h_annots = {}
    Annot.where(project_id: @project.id).each { |a| h_annots[a.id] = a }

    # Flatten group_pairs into group_ref / group_comp, mirroring the
    # pre-set_run massaging done in ReqsController#create_runs.
    h_run_attrs = Basic.safe_parse_json(@run.attrs_json, {})
    if (gp = h_run_attrs['group_pairs']) && gp.is_a?(Array) && gp.size >= 2
      h_run_attrs['group_ref'] = gp[0]
      h_run_attrs['group_comp'] = gp[1]
    end

    h_p = {
      project: @project,
      h_cmd_params: h_cmd_params,
      run: @run,
      p: h_run_attrs,
      h_attrs: h_attrs,
      step: @step,
      h_data_classes: h_data_classes,
      std_method: @std_method,
      h_env: @h_env,
      h_annots: h_annots,
      el_time: Time.now,
      user_id: (current_user ? current_user.id : @run.user_id)
    }

    begin
      h_set = Basic.set_run(Rails.logger, h_p)
    rescue => e
      Rails.logger.error("[runs#restart] Basic.set_run failed for Run##{@run.id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(20).join("\n")) if e.backtrace
      Basic.upd_run(@project, @run, { status_id: 4, error: "Failed to rebuild command: #{e.message}" }, true)
      render json: { status: 'error', message: "Failed to rebuild run command: #{e.message}" }, status: :internal_server_error
      return
    end

    if h_set.is_a?(Hash) && h_set[:error]
      Basic.upd_run(@project, @run, { status_id: 4, error: h_set[:error].to_s }, true)
      render json: { status: 'error', message: "Failed to rebuild run command: #{h_set[:error]}" }, status: :unprocessable_entity
      return
    end

    # Basic.set_run persists a fresh command_json and resets status_id to 1.
    @run.reload

    Basic.upd_project_step(@project, @step.id)
    @project.broadcast(@step.id)

    Basic.exec_run(Rails.logger, @run)

    render json: { status: 'ok', run_id: @run.id, step_id: @step.id }
  rescue => e
    Rails.logger.error("[runs#restart] Run##{@run&.id} failed: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(20).join("\n")) if e.backtrace
    render json: { status: 'error', message: e.message }, status: :internal_server_error
  end

  # POST /runs/:id/stop
  # Stop a pending, queued or running run. Cancels the SLURM job (if any),
  # kills the Docker container (if any), and marks the run + its enclosing
  # project_step + project with status_id = 5 (stopped).
  def stop
    unless editable?(@project) && analyzable?(@project)
      render json: { status: 'error', message: 'You do not have permission to stop runs on this project.' }, status: :forbidden
      return
    end

    if @project.locked_from_publication?(@run)
      render json: { status: 'error', message: 'This run was created before publication and cannot be stopped.' }, status: :forbidden
      return
    end

    unless [1, 2, 6].include?(@run.status_id.to_i)
      render json: { status: 'error', message: 'Only pending, waiting or running runs can be stopped.' }, status: :unprocessable_entity
      return
    end

    if @run.slurm_job_id.present?
      begin
        SlurmService.new(logger: Rails.logger).cancel_job(@run.slurm_job_id)
      rescue => e
        Rails.logger.warn("[runs#stop] scancel failed for Run##{@run.id} slurm_job_id=#{@run.slurm_job_id}: #{e.class} - #{e.message}")
      end
    end

    begin
      Basic.kill_run(@run)
    rescue => e
      Rails.logger.warn("[runs#stop] kill_run failed for Run##{@run.id}: #{e.class} - #{e.message}")
    end

    if @run.pid.present? && @run.slurm_job_id.blank?
      # Only attempt process kill for direct (non-SLURM) runs; slurm_job_id
      # reuses the pid column and must not be signaled as a local PID.
      begin
        Process.kill('TERM', @run.pid.to_i)
      rescue Errno::ESRCH, Errno::EPERM
        # Already gone or not permitted; status update still proceeds.
      end
    end

    duration = @run.start_time ? (Time.now - @run.start_time).to_f : @run.duration

    @run.update(
      status_id: 5,
      error: 'Stopped by user',
      duration: duration
    )

    if @project_step
      @project_step.update(status_id: 5, error_message: 'Stopped by user')
    end
    Basic.upd_project_step(@project, @step.id)
    @project.update(status_id: 5)
    @project.broadcast(@step.id) if @project.respond_to?(:broadcast)

    render json: { status: 'ok', run_id: @run.id, step_id: @step.id }
  rescue => e
    Rails.logger.error("[runs#stop] Run##{@run&.id} failed: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(20).join("\n")) if e.backtrace
    render json: { status: 'error', message: e.message }, status: :internal_server_error
  end

  def report_error
    unless @run.status_id == 4
      redirect_back fallback_location: project_path(@project), alert: 'This run is not in a failed state.'
      return
    end

    sender_email = if current_user
                     current_user.email
                   else
                     params[:email].to_s.strip
                   end
    message = params[:message].to_s.strip

    if sender_email.blank? || !sender_email.match?(URI::MailTo::EMAIL_REGEXP)
      redirect_back fallback_location: project_path(@project), alert: 'Please provide a valid email address.'
      return
    end

    begin
      RunErrorMailer.user_report(
        run: @run,
        sender_email: sender_email,
        message: message.presence
      ).deliver_now

      redirect_back fallback_location: project_path(@project), notice: 'Thank you for reporting this issue. We will get back to you shortly.'
    rescue KeyError, ArgumentError => e
      Rails.logger.error("[RunsController#report_error] Invalid mail configuration: #{e.class} - #{e.message}")
      redirect_back fallback_location: project_path(@project), alert: 'Report form is temporarily unavailable. Please try again later.'
    rescue StandardError => e
      Rails.logger.error("[RunsController#report_error] Failed to send report for Run##{@run.id}: #{e.class} - #{e.message}")
      redirect_back fallback_location: project_path(@project), alert: 'Failed to send your report. Please try again later.'
    end
  end

  def destroy
    @log = ''
    start_time = Time.now
    @log += (Time.now - start_time).to_s + " start</br>"
    if editable?(@project)
      if @project.locked_from_publication?(@run)
        respond_to do |format|
          format.html { redirect_to project_path(@project), alert: 'This run was created before publication and cannot be deleted.' }
          format.json { render json: { status: 'error', message: 'This run was created before publication and cannot be deleted.' }, status: :forbidden }
        end
        return
      end

      @log += RunsController.destroy_run_call(@project, @run)
      
      respond_to do |format|
        format.json { #redirect_to runs_url, notice: 'Run was successfully destroyed.' }
          render :json => {:status => 'success', :log => @log}
          #redirect_to {:controller => :projects, :action => :get_step, :key => @project.key, :step_id => @step.id, "_method" => :get}, {:turbolinks => false}
        }
        #      format.json { head :no_content }
      end
    end
  end

  private

    def authorize_publication_snapshot_run_access
      return unless @run && @project

      unless readable?(@project)
        head :forbidden
        return
      end

      return unless publication_snapshot_reader?(@project)
      return if @project.locked_from_publication?(@run)

      head :forbidden
    end

    def de_filter_cache_key
      return "u#{current_user.id}" if current_user

      sandbox_key = session[:sandbox].to_s
      return "g#{Zlib.crc32(sandbox_key).to_s(36)}" if sandbox_key.present?

      'g0'
    end

    # Use callbacks to share common setup or constraints between actions.
    def set_run
      @run = Run.find(params[:id])
      @project = @run.project
      @version =@project.version
      @h_env = Basic.safe_parse_json(@version.env_json, {})
      @list_docker_image_names = @h_env['docker_images'].keys.map{|k| @h_env['docker_images'][k]["name"] + ":" + @h_env['docker_images'][k]["tag"]}
      @docker_images = DockerImage.where("full_name in (#{@list_docker_image_names.map{|e| "'#{e}'"}.join(",")})").all
      @asap_docker_image = @docker_images.select{|e| e.name == ENV.fetch('ASAP_DOCKER_NAME')}.first

      @step = @run.step
      @std_method = @run.std_method
      @ps = ProjectStep.where(:project_id => @project.id, :step_id => @step.id).first
      @project_step = @ps
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def run_params
      params.fetch(:run, {})
    end
end
