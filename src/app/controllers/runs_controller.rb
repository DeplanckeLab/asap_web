class RunsController < ApplicationController
  before_action :set_run, only: [:get_de_gene_list, :get_ge_geneset_list, :show, :edit, :update, :destroy]
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
    list_filtered_rows = []
    if params[:from]== 'ge_form'
      filename = @project_dir + "tmp" + "#{(current_user) ? current_user.id : 1}_#{@run.id}_filtered.json"
      tmp_h = Basic.safe_parse_json(File.read(filename), {})
      list_filtered_rows = tmp_h[params[:type]] if tmp_h[params[:type]]
    else
      filename = @project_dir + "de" + @run.id.to_s + "filtered.#{params[:type]}.json"
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
    
    filename = @project_dir + "de" + @run.id.to_s + "output.txt"
    i = 0
    j = 0

    @tmp_data = File.readlines(filename)
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
      
      # Build dataset results
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
            annot_path = Rails.application.routes.url_helpers.annot_path(annot)
            "<a href='#{annot_path}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors'>#{annot.name} <span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{annot.nber_cols} #{col_name}</span> <span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{annot.nber_rows} #{row_name}</span></a>"
          }.join(" ") + "</p>"
      end
      
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
          }.join(" ") : '') + dataset_results.join("<br/>\n")
        }
      }
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
    return log

  end

  def destroy_run_call project, run
    RunsController.destroy_run_call(project, run)
  end

  # DELETE /runs/1
  # DELETE /runs/1.json
  def destroy
    @log = ''
    start_time = Time.now
    @log += (Time.now - start_time).to_s + " start</br>"
    if editable?(@project)

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
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def run_params
      params.fetch(:run, {})
    end
end
