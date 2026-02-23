require 'open3'

class AnnotsController < ApplicationController
  before_action :set_annot, only: [:show, :download]

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

  private

  def set_annot
    @annot = Annot.find(params[:id])
    unless readable?(@annot.project)
      redirect_to projects_path, alert: 'Not authorized'
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

