require 'open3'

class AnnotsController < ApplicationController
  helper_method :metadata_type_editable?

  before_action :set_annot, only: [:show, :download, :categories, :edit, :update]

  # GET /annots/:id
  def show
    @project = @annot.project
    @project_type = @project.project_type
    @run = @annot.run
    @view_type = 'data'
    @from = params[:from] || 'data'
    @back_run_id = params[:run_id]
    @back_step_id = params[:step_id]
    
    # Get filepath info for loom_file_label helper
    if @annot.filepath.present?
      filepath_info = {}
      all_annots = Annot.where(project_id: @project.id, filepath: @annot.filepath)
                        .includes(:step, run: [:std_method])
      
      all_annots.each do |a|
        next unless a.filepath.present?
        filepath = a.filepath
        step_rank = a.step&.rank
        run_id = a.run_id
        
        if filepath_info[filepath]
          existing = filepath_info[filepath]
          existing_step_rank = existing[:step_rank] || 9999
          existing_run_id = existing[:run_id] || 999999
          
          current_step_rank = step_rank || 9999
          current_run_id = run_id || 999999
          
          if current_step_rank < existing_step_rank || (current_step_rank == existing_step_rank && current_run_id < existing_run_id)
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
      
      @filepath_info = filepath_info
      run_ids = filepath_info.values.map { |info| info[:run_id] }.compact.uniq
      @loom_file_runs = Run.where(id: run_ids).includes(:step, :std_method).index_by(&:id) if run_ids.any?
      @loom_file_runs ||= {}
    end
    
    # Get matrix dimensions for metadata annotations
    if @annot.name.start_with?('/col_attrs/') || @annot.name.start_with?('/row_attrs/')
      matrix_annot = Annot.where(project_id: @project.id, filepath: @annot.filepath, name: '/matrix').first
      if matrix_annot
        @matrix_nber_cols = matrix_annot.nber_cols
        @matrix_nber_rows = matrix_annot.nber_rows
      end
    end
    
    # For expression matrices (dim == 3), get gene and cell annotations
    if @annot.dim == 3
      @genes_annot = Annot.where(name: '/row_attrs/Gene', filepath: @annot.filepath, project_id: @project.id).first
      @cells_annot = Annot.where(name: '/col_attrs/CellID', filepath: @annot.filepath, project_id: @project.id).first
    end
    
    # Get project directory
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    @project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
    loom_path = @project_dir + @annot.filepath
    
    # Get annotation data for preview
    @h_results = {}
    @preview_data = []
    @h_counts = {}
    @bin_counts = []
    @bin_size = nil
    @min = nil
    @h_sums = {}
    
    if @annot.dim == 3
      # Expression matrix - extract sample and compute distributions
      begin
        # Check if file exists
        if File.exist?(loom_path)
          # Get sample of matrix (10x10) using ExtractRow
          sample_cmd = H5DataService.asap_command(
            '-T', 'ExtractRow',
            '-loom', loom_path.to_s,
            '-iAnnot', @annot.name,
            '-start', '0',
            '-nber', '10'
          )
          stdout, stderr, status = Open3.capture3(*sample_cmd)
          if status.success?
            begin
              sample_data = JSON.parse(stdout)
              @preview_data = sample_data['rows'] || []
            rescue JSON::ParserError => e
              Rails.logger.error("Failed to parse expression matrix sample: #{e.message}")
              @preview_data = []
            end
          else
            Rails.logger.error("Failed to extract expression matrix sample: #{stderr}")
            @preview_data = []
          end
        else
          Rails.logger.error("Loom file not found: #{loom_path}")
          @preview_data = []
        end
        
        # Get distribution data for expression matrices
        h_sum_names = {
          sum: "/row_attrs/_Sum",
          depth: "/col_attrs/_Depth"
        }
        h_nber_bins = {
          sum: (@annot.nber_rows > 10000) ? 1000 : 100,
          depth: (@annot.nber_cols > 10000) ? 1000 : 100
        }
        
        h_sum_names.each_key do |k|
          begin
            sum_annot = Annot.where(project_id: @project.id, filepath: @annot.filepath, name: h_sum_names[k]).first
            if sum_annot
              values = H5DataService.get_metadata_vector(loom_path.to_s, h_sum_names[k])
              if values.any?
                numeric_values = values.map { |v| v.to_f rescue nil }.compact
                if numeric_values.any?
                  @h_sums[k] = compute_bins(numeric_values, h_nber_bins[k].to_i)
                end
              end
            end
          rescue => e
            Rails.logger.error("Error computing distribution for #{k}: #{e.message}")
          end
        end
      rescue => e
        Rails.logger.error("Error extracting expression matrix data: #{e.message}")
      end
    else
      # Metadata annotation - extract values
      begin
        if File.exist?(loom_path)
          values = H5DataService.get_metadata_vector(loom_path.to_s, @annot.name)
          @h_results['values'] = values
          
          # Get preview (first 100 values)
          @preview_data = values.first(100)
          
          # Determine number of columns
          nber_cols = ((@annot.dim == 1) ? @annot.nber_rows : @annot.nber_cols)
          
          if nber_cols == 1 && @annot.data_type
            if @annot.data_type.name == 'CATEGORICAL' || @annot.data_type_id == 3
              # Categorical data - count categories
              @h_results['values'].each do |e|
                e = (e == '' || e.nil?) ? 'Empty' : e.to_s
                @h_counts[e] ||= 0
                @h_counts[e] += 1
              end
            elsif @annot.data_type.name == 'NUMERIC' || @annot.data_type_id == 1
              # Numerical data - compute bins for histogram
              numeric_values = @h_results['values'].map { |v| v.to_f rescue nil }.compact
              if numeric_values.any?
                h_res_bins = compute_bins(numeric_values, 100)
                @bin_size = h_res_bins[:bin_size]
                @min = h_res_bins[:min]
                @bin_counts = h_res_bins[:bin_counts]
              end
            end
          end
        else
          Rails.logger.error("Loom file not found: #{loom_path}")
          @h_results['values'] = []
        end
      rescue => e
        Rails.logger.error("Error extracting metadata: #{e.message}")
        @h_results['values'] = []
      end
    end
    
    # Get categories if available
    @categories = {}
    if @annot.categories_json.present?
      begin
        @categories = JSON.parse(@annot.categories_json)
      rescue
        @categories = {}
      end
    end

    if editable?(@project) && metadata_type_editable?(@annot)
      @data_type_options = DataType.order(:id).map { |dt| [dt.label.presence || dt.name, dt.id] }
    end
  end

  # GET /annots/:id/categories.json
  def categories
    project = @annot.project
    unless project && (admin? || readable?(project))
      render json: { error: 'Not authorized' }, status: :forbidden
      return
    end

    unless @annot.data_type_id == 3
      render json: { categories: [] }
      return
    end

    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key
    loom_path = project_dir + @annot.filepath.to_s
    unless File.exist?(loom_path)
      render json: { error: "Loom file not found for annotation #{@annot.id}" }, status: :not_found
      return
    end

    values = H5DataService.get_metadata_vector(loom_path.to_s, @annot.name)
    h_indexes_by_cat = Hash.new { |h, k| h[k] = [] }
    values.each_with_index do |value, idx|
      cat = (value.nil? || value.to_s.empty?) ? 'NA' : value.to_s
      h_indexes_by_cat[cat] << idx
    end

    categories = h_indexes_by_cat.keys.sort.map do |cat|
      {
        name: cat,
        count: h_indexes_by_cat[cat].size,
        indices: h_indexes_by_cat[cat]
      }
    end

    render json: { categories: categories }
  rescue => e
    Rails.logger.error("[annots#categories] Error for annot #{@annot&.id}: #{e.class} - #{e.message}")
    render json: { error: 'Failed to load annotation categories' }, status: :internal_server_error
  end

  # GET /annots/:id/download?format_type=tsv|json
  def download
    project = @annot.project
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key
    loom_path = project_dir + @annot.filepath
    format_type = params[:format_type] || 'tsv'

    annot_label = @annot.name.split('/').last || @annot.name

    unless File.exist?(loom_path)
      render plain: 'Loom file not found', status: :not_found
      return
    end

    if @annot.dim == 3
      cmd = H5DataService.asap_command(
        '-T', 'ExtractRow',
        '-loom', loom_path.to_s,
        '-iAnnot', @annot.name,
        '-start', '0',
        '-nber', (@annot.nber_rows || 100).to_s
      )
      stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        render plain: "Failed to extract data: #{stderr}", status: :internal_server_error
        return
      end

      data = JSON.parse(stdout) rescue {}
      rows = data['rows'] || []

      if format_type == 'json'
        send_data data.to_json,
                  filename: "#{annot_label}.json",
                  type: 'application/json',
                  disposition: 'attachment'
      else
        tsv_lines = []
        rows.each do |row|
          if row.is_a?(Array)
            tsv_lines << row.join("\t")
          else
            tsv_lines << row.to_s
          end
        end
        send_data tsv_lines.join("\n"),
                  filename: "#{annot_label}.tsv",
                  type: 'text/tab-separated-values',
                  disposition: 'attachment'
      end
    else
      values = H5DataService.get_metadata_vector(loom_path.to_s, @annot.name)

      if format_type == 'json'
        json_output = { name: @annot.name, values: values }.to_json
        send_data json_output,
                  filename: "#{annot_label}.json",
                  type: 'application/json',
                  disposition: 'attachment'
      else
        tsv_lines = [annot_label]
        values.each { |v| tsv_lines << v.to_s }
        send_data tsv_lines.join("\n"),
                  filename: "#{annot_label}.tsv",
                  type: 'text/tab-separated-values',
                  disposition: 'attachment'
      end
    end
  end

  def edit
    @project = @annot.project
    unless editable?(@project)
      redirect_to annot_path(@annot, annot_back_params), alert: 'You cannot edit this project.' and return
    end
    unless metadata_type_editable?(@annot)
      redirect_to annot_path(@annot, annot_back_params), alert: 'This annotation does not support changing data type.' and return
    end
    redirect_to "#{annot_path(@annot, annot_back_params)}#annot-data-type"
  end

  def update
    @project = @annot.project
    unless editable?(@project)
      redirect_to annot_path(@annot, annot_back_params), alert: 'You cannot edit this project.' and return
    end
    unless metadata_type_editable?(@annot)
      redirect_to annot_path(@annot, annot_back_params), alert: 'This annotation does not support changing data type.' and return
    end

    permitted = annot_params
    new_type_id = permitted[:data_type_id].presence&.to_i
    unless new_type_id.positive? && DataType.exists?(id: new_type_id)
      redirect_to annot_path(@annot, annot_back_params), alert: 'Invalid data type.' and return
    end

    h_annot = {
      data_type_id: new_type_id,
      data_class_ids: (new_type_id != @annot.data_type_id ? '' : permitted[:data_class_ids].to_s)
    }

    h_data_types = {}
    DataType.find_each { |dt| h_data_types[dt.name] = dt; h_data_types[dt.id] = dt }
    h_data_classes = {}
    DataClass.find_each { |dc| h_data_classes[dc.name] = dc; h_data_classes[dc.id] = dc }

    ori_annot = Annot.where(project_id: @project.id, name: @annot.name).order(:id).first
    unless ori_annot
      redirect_to annot_path(@annot, annot_back_params), alert: 'Annotation not found.' and return
    end

    all_annots = Annot.where(project_id: @project.id, name: @annot.name).order(:id)
    if all_annots.any? { |a| a.run_id.blank? }
      redirect_to annot_path(@annot, annot_back_params), alert: 'Cannot update: a related row is missing its run.' and return
    end

    old_type_label = @annot.data_type&.then { |dt| dt.label.presence || dt.name } || 'none'
    new_dt = h_data_types[new_type_id]
    new_type_label = new_dt ? (new_dt.label.presence || new_dt.name) : 'unknown'
    instances = all_annots.size
    instance_word = (instances == 1) ? 'instance' : 'instances'
    notice =
      "Data type of all metadata named #{@annot.name} in the different loom files " \
      "(#{instances} #{instance_word}) were changed from #{old_type_label} to #{new_type_label}."

    ActiveRecord::Base.transaction do
      ori_annot.update!(h_annot)
      all_annots.each do |annot|
        meta = {
          'name' => annot.name,
          'forced_type_id' => h_annot[:data_type_id]
        }
        Basic.load_annot(annot.run, meta, annot.filepath, h_data_types, h_data_classes, logger, {})
      end
    end

    redirect_to annot_path(@annot, annot_back_params), notice: notice
  rescue StandardError => e
    Rails.logger.error("[annots#update] #{e.class}: #{e.message}\n#{e.backtrace&.first(12)&.join("\n")}")
    redirect_to annot_path(@annot, annot_back_params), alert: "Update failed: #{e.message}"
  end

  def annot_back_params
    { from: params[:from], run_id: params[:run_id], step_id: params[:step_id] }.compact
  end

  private

  def annot_params
    params.require(:annot).permit(:data_type_id, :data_class_ids)
  end

  def metadata_type_editable?(annot)
    return false if annot.blank?
    return false if annot.dim == 3
    return false if annot.name == '/matrix'
    return false if annot.filepath.blank?

    user_data_dir = ENV.fetch('USER_DATA_DIR', Rails.root.join('storage', 'user_data').to_s)
    loom = Pathname.new(user_data_dir) + annot.project.user_id.to_s + annot.project.key + annot.filepath
    File.exist?(loom)
  end

  def set_annot
    @annot = Annot.find(params[:id])
    unless readable?(@annot.project)
      redirect_to unauthorized_path and return
    end
    unless annot_visible_under_publication_rules?(@annot.project, @annot)
      redirect_to unauthorized_path and return
    end
  end

  # Compute bins for histogram
  def compute_bins(values, nber_bins)
    return { bin_counts: [], min: 0, max: 0, bin_size: 0 } if values.empty?
    
    min = values.min
    max = values.max
    return { bin_counts: [], min: min, max: max, bin_size: 0 } if min == max
    
    h = { bin_counts: [], min: min, max: max }
    (0..nber_bins - 1).each { |bin_i| h[:bin_counts][bin_i] = 0 }
    bin_size = (max - min).to_f / nber_bins
    
    values.each do |e|
      if bin_size > 0
        bin_i = ((e - min) / bin_size).to_i
        bin_i = nber_bins - 1 if bin_i >= nber_bins
        bin_i = 0 if bin_i < 0
        h[:bin_counts][bin_i] ||= 0
        h[:bin_counts][bin_i] += 1
      end
    end
    
    h[:bin_size] = bin_size
    h
  end
end

