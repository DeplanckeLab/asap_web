require 'open3'

class AnnotsController < ApplicationController
  helper_method :data_type_editable?, :metadata_type_editable?

  before_action :set_annot, only: [:show, :download, :categories, :edit, :update]

  # GET /annots/:id
  def show
    @project = @annot.project
    @project_type = @project.project_type
    @run = @annot.run
    @view_type = 'data'
    @from = params[:from] || 'data'
    @embedded = params[:embedded].to_s == '1'
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
    @histogram = nil
    @h_sums = {}
    @matrix_preview = nil
    @json_preview = nil

    # 2D metadata: col_attrs/row_attrs (e.g. PCA) or /attrs/ tables (e.g. DE) when
    # ExtractMetadata returns a matrix of values.
    is_2d_metadata = @annot.dim != 3 &&
                     @annot.nber_rows.to_i > 1 &&
                     @annot.nber_cols.to_i > 1 &&
                     (@annot.name.start_with?('/col_attrs/') || @annot.name.start_with?('/row_attrs/') ||
                      @annot.name.start_with?('/attrs/'))

    scalar_global_attr = @annot.name.start_with?('/attrs/') &&
                         @annot.nber_rows.to_i <= 1 &&
                         (@annot.nber_cols.to_i <= 1 || @annot.dim.to_i == 4)

    if @annot.dim == 3
      # Expression matrix - extract sample and compute distributions
      begin
        # Check if file exists
        if File.exist?(loom_path)
          # ExtractRow requires -indexes (or -names / -stable_ids), not -start/-nber.
          begin
            n_sample = 10
            n_total = @annot.nber_rows.to_i
            n_sample = [n_sample, n_total].min if n_total.positive?
            n_sample = 1 if n_sample < 1
            sample_data = H5DataService.extract_row_by_indexes(loom_path.to_s, @annot.name, (0...n_sample).to_a)
            @preview_data = sample_data['rows'] || sample_data['values'] || []
          rescue StandardError => e
            Rails.logger.error("Failed to extract expression matrix sample: #{e.message}")
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
                  @h_sums[k] = compute_histogram_pair(numeric_values, h_nber_bins[k].to_i)
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
    elsif is_2d_metadata
      # 2D metadata: /col_attrs|/row_attrs via ExtractMetadata; /attrs/* (e.g. DE) via h5py in asap_run (ExtractDataset only allows /matrix and /layers).
      if File.exist?(loom_path)
        max_preview_rows = 10
        max_preview_cols = 10
        matrix = if @annot.name.start_with?('/attrs/')
          # Do not pass total_cols: Annot nber_cols can lag the HDF5 compound; cap width only here.
          attrs_col_cap = 128
          H5DataService.get_attrs_matrix_sample_for_preview(
            loom_path.to_s,
            @annot.name,
            max_preview_rows: max_preview_rows,
            max_preview_cols: attrs_col_cap,
            total_rows: @annot.nber_rows,
            total_cols: nil
          )
        else
          m = H5DataService.get_metadata_matrix(loom_path.to_s, @annot.name)
          {
            nber_rows: m[:nber_rows],
            nber_cols: m[:nber_cols],
            values: m[:values].first(max_preview_rows).map { |row| row.first(max_preview_cols) }
          }
        end
        sample_rows = matrix[:values]
        h5_col_names = if @annot.name.start_with?('/attrs/') && matrix[:column_names].is_a?(Array) && matrix[:column_names].any?
          matrix[:column_names].map(&:to_s)
        end

        output_json_headers = nil
        headers_json_raw = @annot.headers_json_value
        if headers_json_raw.present?
          begin
            parsed = JSON.parse(headers_json_raw)
            output_json_headers = parsed.map(&:to_s) if parsed.is_a?(Array) && parsed.any?
          rescue JSON::ParserError
            output_json_headers = nil
          end
        end
        output_json_headers ||= annot_metadata_headers_from_run_output_json(@annot, @project_dir)

        # Table headers: same labels as output.json "metadata" entry (headers), not HDF5 dtype names.
        column_headers = output_json_headers
        column_headers = h5_col_names if column_headers.nil? && h5_col_names

        rw = sample_rows.first&.size.to_i
        # /attrs/: HDF5 compound may include Gene not listed in output.json "headers".
        # Leading Gene, or EnsemblID then Gene when first header is Ensembl-like (no separate Gene column needed).
        if @annot.name.start_with?('/attrs/') && sample_rows.first.is_a?(Array) && h5_col_names.is_a?(Array) && h5_col_names.any? &&
           output_json_headers.is_a?(Array) && output_json_headers.any? &&
           rw == output_json_headers.size + 1
          drop_idx = nil
          if preview_attrs_matrix_column_name_gene_like?(h5_col_names.first)
            drop_idx = 0
          elsif preview_attrs_matrix_header_ensembl_id_like?(h5_col_names.first) &&
                h5_col_names.size >= 2 && preview_attrs_matrix_column_name_gene_like?(h5_col_names[1]) &&
                preview_attrs_matrix_header_ensembl_id_like?(output_json_headers.first)
            drop_idx = 1
          elsif preview_attrs_matrix_h5_column_names_numeric?(h5_col_names)
            # 2D /attrs/ preview: Python uses "0","1",… not compound dtype names; first column is still Gene in file.
            drop_idx = 0
          end
          if drop_idx
            sample_rows = sample_rows.map do |row|
              next row unless row.is_a?(Array) && row.size > drop_idx
              row[0...drop_idx] + row[(drop_idx + 1)..]
            end
          end
        end

        # Preview: omit leading Gene column when output.json (or HDF5) labels include Gene at same width.
        if column_headers.is_a?(Array) && column_headers.any? &&
           preview_attrs_matrix_column_name_gene_like?(column_headers.first) &&
           sample_rows.first.is_a?(Array) && sample_rows.first.size.positive? &&
           sample_rows.first.size == column_headers.size
          column_headers = column_headers.drop(1)
          sample_rows = sample_rows.map do |row|
            next row unless row.is_a?(Array)
            row.size > 1 ? row.drop(1) : []
          end
        end

        # First column is Ensembl-like id: drop redundant Gene as second column (same width as headers).
        if column_headers.is_a?(Array) && column_headers.size >= 2 &&
           preview_attrs_matrix_header_ensembl_id_like?(column_headers.first) &&
           preview_attrs_matrix_column_name_gene_like?(column_headers[1]) &&
           sample_rows.first.is_a?(Array) && sample_rows.first.size == column_headers.size
          column_headers = [column_headers[0]] + column_headers[2..]
          sample_rows = sample_rows.map do |row|
            next row unless row.is_a?(Array) && row.size >= 2
            [row[0]] + row[2..]
          end
        end

        full_nr = @annot.nber_rows.to_i.positive? ? @annot.nber_rows.to_i : matrix[:nber_rows].to_i
        file_nc = matrix[:nber_cols].to_i
        full_nc = if @annot.name.start_with?('/attrs/') && file_nc.positive?
          file_nc
        elsif @annot.nber_cols.to_i.positive?
          @annot.nber_cols.to_i
        else
          file_nc
        end
        @matrix_preview = {
          nber_rows: full_nr.to_i,
          nber_cols: full_nc.to_i,
          shown_rows: sample_rows.size,
          shown_cols: sample_rows.first&.size.to_i,
          rows: sample_rows,
          column_headers: column_headers,
          attrs_global: @annot.name.start_with?('/attrs/')
        }
      else
        Rails.logger.error("Loom file not found: #{loom_path}")
      end
    else
      # Metadata annotation - extract values
      begin
        if File.exist?(loom_path)
          if scalar_global_attr
            # Length-1 /attrs/* strings (including nested JSON) via h5py: ASAP.jar
            # ExtractMetadata wraps values in JSON and breaks on nested JSON payloads.
            raw = H5DataService.read_global_attr_string(loom_path.to_s, @annot.name)
            values = [raw]
            @h_results['values'] = values
            @preview_data = values
            @json_preview = parse_annot_json_preview(raw)
          else
            values = H5DataService.get_metadata_vector(loom_path.to_s, @annot.name)
            @h_results['values'] = values

            # Get preview (first 100 values)
            @preview_data = values.first(100)
            if @annot.name.start_with?('/attrs/') && values.size == 1
              @json_preview = parse_annot_json_preview(values.first)
            end
          end

          # Determine number of columns
          nber_cols = ((@annot.dim == 1) ? @annot.nber_rows : @annot.nber_cols)

          if nber_cols == 1 && @annot.data_type && @json_preview.nil?
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
                @histogram = compute_histogram_pair(numeric_values, 100)
                @bin_counts = @histogram[:linear][:bin_counts]
                @bin_size = @histogram[:linear][:bin_size]
                @min = @histogram[:linear][:min]
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

    if editable?(@project) && data_type_editable?(@annot)
      allowed_type_names = allowed_data_type_names_for(@annot)
      @data_type_options = DataType.order(:id)
                                   .select { |dt| allowed_type_names.include?(dt.name) }
                                   .map { |dt| [dt.label.presence || dt.name, dt.id] }

      # Disable unsafe target data types in the select. Switching a DISCRETE
      # (categorical) annotation to NUMERIC is unsafe when its category names
      # are not all numeric-coercible, so we disable NUMERIC in that case.
      @disabled_data_type_ids = []
      if @annot.data_type_id == 3 && !@annot.categorical_numeric_coercible?
        numeric_id = DataType.find_by(name: 'NUMERIC')&.id
        @disabled_data_type_ids << numeric_id if numeric_id
      end
    elsif editable?(@project) && annot_loom_file_present?(@annot)
      @data_type_edit_blocked = annot_referenced_by_runs?(@annot)
    end

    load_sim_step_options if editable?(@project) && @annot.imported?

    render :show, layout: false if @embedded
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

  # GET /annots/:id/download?format_type=tsv|tsv.gz|json
  def download
    project = @annot.project
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key
    loom_path = project_dir + @annot.filepath
    format_type = params[:format_type].presence || 'tsv'
    want_gzip = format_type.to_s.in?(%w[tsv.gz tsv_gz gzip])

    annot_label = @annot.name.split('/').last || @annot.name
    safe_label = annot_label.to_s.gsub(/[^\w.\-]+/, '_')

    unless File.exist?(loom_path)
      render plain: 'Loom file not found', status: :not_found
      return
    end

    if @annot.dim == 3
      total_rows = @annot.nber_rows.to_i
      if total_rows <= 0
        render plain: 'Cannot download: row count is missing for this matrix.', status: :unprocessable_entity
        return
      end

      begin
        data = H5DataService.extract_matrix_rows_chunked(loom_path.to_s, @annot.name, total_rows, chunk_size: 1000)
      rescue StandardError => e
        render plain: "Failed to extract data: #{e.message}", status: :internal_server_error
        return
      end

      rows = data['rows'] || []

      if format_type == 'json'
        send_data data.to_json,
                  filename: "#{safe_label}.json",
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
        send_tsv_download(tsv_lines.join("\n"), safe_label, want_gzip: want_gzip)
      end
    else
      begin
        values = H5DataService.get_metadata_vector(loom_path.to_s, @annot.name)
      rescue StandardError => e
        render plain: "Failed to extract data: #{e.message}", status: :internal_server_error
        return
      end

      if format_type == 'json'
        json_output = { name: @annot.name, values: values }.to_json
        send_data json_output,
                  filename: "#{safe_label}.json",
                  type: 'application/json',
                  disposition: 'attachment'
      else
        tsv_content = build_annot_vector_tsv(loom_path.to_s, values, annot_label)
        send_tsv_download(tsv_content, safe_label, want_gzip: want_gzip)
      end
    end
  end

  def edit
    @project = @annot.project
    unless editable?(@project)
      redirect_to annot_path(@annot, annot_back_params), alert: 'You cannot edit this project.' and return
    end
    unless data_type_editable?(@annot)
      redirect_to annot_path(@annot, annot_back_params), alert: data_type_edit_blocked_message(@annot) and return
    end
    redirect_to "#{annot_path(@annot, annot_back_params)}#annot-data-type"
  end

  def update
    @project = @annot.project
    unless editable?(@project)
      redirect_to annot_path(@annot, annot_back_params), alert: 'You cannot edit this project.' and return
    end

    if params[:annot]&.key?(:sim_step_id)
      return update_sim_step_mapping
    end

    unless data_type_editable?(@annot)
      redirect_to annot_path(@annot, annot_back_params), alert: data_type_edit_blocked_message(@annot) and return
    end

    permitted = annot_params
    new_type_id = permitted[:data_type_id].presence&.to_i
    unless new_type_id.positive? && DataType.exists?(id: new_type_id)
      redirect_to annot_path(@annot, annot_back_params), alert: 'Invalid data type.' and return
    end

    # Guard: forbid DISCRETE -> NUMERIC conversion when categories are not
    # all numeric-coercible. Prevents creating NUMERIC data with non-numeric
    # category names, which would corrupt downstream numeric interpretation.
    numeric_type_id = DataType.find_by(name: 'NUMERIC')&.id
    if numeric_type_id && @annot.data_type_id == 3 && new_type_id == numeric_type_id && !@annot.categorical_numeric_coercible?
      redirect_to annot_path(@annot, annot_back_params),
                  alert: "Cannot change data type to NUMERIC: some category names are not numeric values." and return
    end

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
    type_changed = new_type_id != @annot.data_type_id
    keep_matrix_storage =
      if @annot.integer_storage?
        'int_matrix'
      elsif @annot.float_storage?
        'num_matrix'
      end
    new_class_names =
      if type_changed
        Basic.data_class_names_for_data_type(@annot.name, new_dt.name, keep_matrix_storage: keep_matrix_storage)
      else
        []
      end
    new_class_ids =
      if type_changed
        new_class_names.filter_map { |n| h_data_classes[n]&.id || DataClass.find_by(name: n)&.id }.uniq.sort.join(',')
      else
        permitted[:data_class_ids].to_s
      end

    h_annot = {
      data_type_id: new_type_id,
      data_class_ids: new_class_ids
    }
    new_type_label = new_dt ? (new_dt.label.presence || new_dt.name) : 'unknown'
    instances = all_annots.size
    instance_word = (instances == 1) ? 'instance' : 'instances'
    notice =
      "Data type of all entries named #{@annot.name} in the different loom files " \
      "(#{instances} #{instance_word}) were changed from #{old_type_label} to #{new_type_label}."

    ActiveRecord::Base.transaction do
      ori_annot.update!(h_annot)
      all_annots.each do |annot|
        meta = {
          'name' => annot.name,
          'forced_type_id' => h_annot[:data_type_id]
        }
        meta['data_class_names'] = new_class_names if type_changed && new_class_names.any?
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

  def send_tsv_download(tsv_content, label, want_gzip:)
    if want_gzip
      send_data ActiveSupport::Gzip.compress(tsv_content),
                filename: "#{label}.tsv.gz",
                type: 'application/gzip',
                disposition: 'attachment'
    else
      send_data tsv_content,
                filename: "#{label}.tsv",
                type: 'text/tab-separated-values',
                disposition: 'attachment'
    end
  end

  def build_annot_vector_tsv(loom_path, values, annot_label)
    values = Array(values)
    header = ['index']
    extra_columns = []

    if @annot.name.to_s.start_with?('/col_attrs/')
      begin
        cell_ids = H5DataService.get_metadata_vector(loom_path, '/col_attrs/CellID')
      rescue StandardError
        cell_ids = nil
      end
      if cell_ids.is_a?(Array) && cell_ids.length == values.length
        header << 'cell_barcode'
        extra_columns << cell_ids
      end
    elsif @annot.name.to_s.start_with?('/row_attrs/')
      begin
        gene_symbols = H5DataService.get_metadata_vector(loom_path, '/row_attrs/Gene')
      rescue StandardError
        gene_symbols = nil
      end
      begin
        accessions = H5DataService.get_metadata_vector(loom_path, '/row_attrs/Accession')
      rescue StandardError
        accessions = nil
      end
      if gene_symbols.is_a?(Array) && gene_symbols.length == values.length
        header << 'gene_symbol'
        extra_columns << gene_symbols
      end
      if accessions.is_a?(Array) && accessions.length == values.length
        header << 'ensembl_id'
        extra_columns << accessions
      end
    end

    header << annot_label.to_s
    lines = [header.join("\t")]
    values.each_with_index do |value, i|
      row = [i.to_s]
      extra_columns.each do |col|
        cell = col[i]
        row << (cell.nil? ? '' : cell.to_s)
      end
      row << (value.nil? ? '' : value.to_s)
      lines << row.join("\t")
    end
    lines.join("\n")
  end

  def update_sim_step_mapping
    unless @annot.imported?
      respond_to do |format|
        format.html { redirect_to annot_path(@annot, annot_back_params), alert: 'Only imported metadata and matrices can be mapped to an ASAP step.' }
        format.json { render json: { error: 'Only imported metadata and matrices can be mapped to an ASAP step.' }, status: :unprocessable_entity }
      end
      return
    end

    raw_sim_step_id = params.require(:annot).permit(:sim_step_id)[:sim_step_id]
    sim_step_id = raw_sim_step_id.presence&.to_i

    if sim_step_id.present?
      asap_docker_image = Basic.get_asap_docker(@project.version)
      valid_step_ids = if asap_docker_image
                         Step.where(docker_image_id: asap_docker_image.id, version_id: @project.version_id).pluck(:id)
                       else
                         []
                       end
      unless valid_step_ids.include?(sim_step_id)
        respond_to do |format|
          format.html { redirect_to annot_path(@annot, annot_back_params), alert: 'Invalid step selected.' }
          format.json { render json: { error: 'Invalid step selected.' }, status: :unprocessable_entity }
        end
        return
      end
    end

    @annot.update!(sim_step_id: sim_step_id.presence)

    step_label = @annot.sim_step&.label.presence || @annot.sim_step&.name&.humanize

    respond_to do |format|
      format.html do
        redirect_to annot_path(@annot, annot_back_params), notice: 'ASAP step mapping updated.'
      end
      format.json do
        render json: {
          sim_step_id: @annot.sim_step_id,
          step_label: step_label,
          effective_source_step_id: @annot.effective_source_step_id
        }
      end
    end
  rescue StandardError => e
    Rails.logger.error("[annots#update_sim_step_mapping] #{e.class}: #{e.message}")
    respond_to do |format|
      format.html { redirect_to annot_path(@annot, annot_back_params), alert: "Update failed: #{e.message}" }
      format.json { render json: { error: e.message }, status: :internal_server_error }
    end
  end

  private

  def load_sim_step_options
    @sim_step_options = helpers.sim_step_options_for_project(@project)
  end

  def annot_params
    params.require(:annot).permit(:data_type_id, :data_class_ids)
  end

  def metadata_type_editable?(annot)
    data_type_editable?(annot)
  end

  def data_type_editable?(annot)
    return false if annot.blank?
    return false if annot.filepath.blank?
    return false unless annot_loom_file_present?(annot)
    return false if annot_referenced_by_runs?(annot)

    true
  end

  def annot_loom_file_present?(annot)
    user_data_dir = ENV.fetch('USER_DATA_DIR', Rails.root.join('storage', 'user_data').to_s)
    loom = Pathname.new(user_data_dir) + annot.project.user_id.to_s + annot.project.key + annot.filepath
    File.exist?(loom)
  end

  def annot_referenced_by_runs?(annot)
    Annot.where(project_id: annot.project_id, name: annot.name).any? do |a|
      RunAnnotReferenceScanner.run_ids_referencing_annot(annot.project_id, a).any?
    end
  end

  def data_type_edit_blocked_message(annot)
    if annot_referenced_by_runs?(annot)
      'Cannot change data type: this data is used as input for one or more pipeline runs.'
    else
      'This annotation does not support changing data type.'
    end
  end

  def allowed_data_type_names_for(annot)
    if annot.expression_matrix?
      %w[NUMERIC]
    else
      %w[NUMERIC DISCRETE STRING]
    end
  end

  def set_annot
    @annot = Annot.includes(:data_transformation, :data_type, :sim_step, :user, run: :user).find(params[:id])
    unless readable?(@annot.project)
      redirect_to unauthorized_path and return
    end
    unless annot_visible_under_publication_rules?(@annot.project, @annot)
      redirect_to unauthorized_path and return
    end
  end

  # Parse a scalar global-attr value into a Hash/Array when it is JSON; otherwise nil.
  def parse_annot_json_preview(raw)
    return raw if raw.is_a?(Hash) || raw.is_a?(Array)

    s = raw.to_s.strip
    return nil if s.empty?
    return nil unless s.start_with?('{', '[')

    JSON.parse(s)
  rescue JSON::ParserError
    nil
  end

  # Redundant HDF5 / header column titled exactly "Gene" or "Genes" (compound id column).
  # Do not match gene_name, GeneName, gene_symbol, etc. those stay in the preview.
  def preview_attrs_matrix_column_name_gene_like?(s)
    t = s.to_s.strip
    return false if t.empty?

    t.casecmp?('gene') || t.casecmp?('genes')
  end

  def preview_attrs_matrix_h5_column_names_numeric?(names)
    names.is_a?(Array) && names.any? && names.all? { |x| x.to_s.match?(/\A\d+\z/) }
  end

  # Matches EnsemblID, ensembl_id, Ensembl gene id, etc. (output.json / HDF5 compound labels).
  def preview_attrs_matrix_header_ensembl_id_like?(s)
    t = s.to_s.strip.downcase.gsub(/[^a-z0-9]/, '')
    return true if t == 'ensemblid' || t == 'ensemblids'
    return true if t.start_with?('ensembl') && (t.include?('id') || t.end_with?('ids'))

    false
  end

  # Column titles from the run's output.json "metadata" array (same source as finish_run / headers_json).
  def annot_metadata_headers_from_run_output_json(annot, project_dir)
    run = annot.run
    return nil unless run&.step

    step_dir = project_dir + run.step.name
    output_dir = run.step.multiple_runs == true ? step_dir + run.id.to_s : step_dir
    outp = output_dir + 'output.json'
    return nil unless File.exist?(outp)

    h_out = Basic.safe_parse_json(File.read(outp), {})
    meta = h_out['metadata']
    return nil unless meta.is_a?(Array)

    entry = meta.find { |m| m.is_a?(Hash) && m['name'].to_s == annot.name.to_s }
    return nil unless entry.is_a?(Hash)

    raw = entry['headers']
    return nil unless raw.is_a?(Array) && raw.any?

    raw.map(&:to_s)
  end

  # Compute histogram bins (linear or log10-spaced), matching visualization buildHistogramBins.
  def compute_bins(values, nber_bins, scale: :linear, ignore_zeros: true)
    numeric_values = Array(values).map { |v|
      begin
        Float(v)
      rescue ArgumentError, TypeError
        nil
      end
    }.compact.select { |v| v.finite? }

    numeric_values = numeric_values.reject { |v| v == 0.0 } if ignore_zeros

    if scale.to_sym == :log
      numeric_values = numeric_values.select { |v| v > 0.0 }
    end

    return { bin_counts: [], bin_ranges: [], min: nil, max: nil, bin_size: 0, scale: scale.to_s } if numeric_values.empty?

    min = numeric_values.min
    max = numeric_values.max
    nber_bins = [nber_bins.to_i, 1].max

    if min == max
      return {
        bin_counts: [numeric_values.length],
        bin_ranges: [{ min: min, max: max }],
        min: min,
        max: max,
        bin_size: 0,
        scale: scale.to_s
      }
    end

    bin_counts = Array.new(nber_bins, 0)
    bin_ranges = Array.new(nber_bins)

    if scale.to_sym == :log && min > 0 && max > 0
      log_min = Math.log10(min)
      log_max = Math.log10(max)
      span = log_max - log_min
      if span > 0
        nber_bins.times do |i|
          t0 = log_min + (i.to_f / nber_bins) * span
          t1 = log_min + ((i + 1).to_f / nber_bins) * span
          bin_ranges[i] = { min: 10.0**t0, max: 10.0**t1 }
        end
        inv_span = nber_bins / span
        numeric_values.each do |value|
          next if value <= 0
          bin_i = ((Math.log10(value) - log_min) * inv_span).floor
          bin_i = 0 if bin_i.negative?
          bin_i = nber_bins - 1 if bin_i >= nber_bins
          bin_counts[bin_i] += 1
        end
      else
        bin_ranges[0] = { min: min, max: max }
        bin_counts[0] = numeric_values.length
      end
      bin_size = 0
    else
      bin_size = (max - min).to_f / nber_bins
      nber_bins.times do |i|
        bin_ranges[i] = {
          min: min + i * bin_size,
          max: min + (i + 1) * bin_size
        }
      end
      if bin_size.positive?
        inv_bin_size = 1.0 / bin_size
        numeric_values.each do |value|
          bin_i = ((value - min) * inv_bin_size).floor
          bin_i = 0 if bin_i.negative?
          bin_i = nber_bins - 1 if bin_i >= nber_bins
          bin_counts[bin_i] += 1
        end
      end
    end

    {
      bin_counts: bin_counts,
      bin_ranges: bin_ranges,
      min: min,
      max: max,
      bin_size: bin_size,
      scale: scale.to_s
    }
  end

  def compute_histogram_pair(values, nber_bins)
    {
      linear: compute_bins(values, nber_bins, scale: :linear, ignore_zeros: true),
      log: compute_bins(values, nber_bins, scale: :log, ignore_zeros: true)
    }
  end
end

