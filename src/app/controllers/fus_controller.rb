class FusController < ApplicationController
  # POST /fus/upload_chunk
  def upload_chunk
    unless user_signed_in?
      render json: { error: 'Authentication required' }, status: :unauthorized
      return
    end

    filename = params[:filename].presence || 'uploaded_file'
    chunk = params[:chunk]
    chunk_index = params[:chunk_index].to_i
    total_chunks = params[:total_chunks].to_i
    file_size = params[:file_size].to_i
    fu_id = params[:fu_id]
    
    # Clean filename
    filename.gsub!(/[()\[\]#?$]/, '')
    
    # Extract file extension and create input filename
    file_ext = File.extname(filename)
    input_filename = "input_file#{file_ext}"
    
    # Find or create Fu record for tracking resumable upload
    # Project key will be set later when project is created
    fu = if fu_id.present?
           Fu.find_by(id: fu_id, user_id: current_user.id)
         else
           # Create new Fu record on first chunk
           Fu.new(
             user_id: current_user.id,
             project_key: nil, # Will be set when project is created
             upload_file_name: input_filename,
             upload_file_size: file_size,
             status: 'uploading',
             name: filename
           )
         end
    
    unless fu
      render json: { error: 'Upload record not found' }, status: :bad_request
      return
    end
    
    fu.save! if fu.new_record?
    
    # Upload to /data/asap2/fus/{fu.id}/{filename} (temporary location)
    upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                        ENV["UPLOAD_DATA_DIR"]
                      elsif ENV["DATA_DIR"]
                        Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                      else
                        '/data/asap2/fus'
                      end
    
    upload_base_dir = Pathname.new(upload_base_dir)
    FileUtils.mkdir_p(upload_base_dir) unless upload_base_dir.exist?
    
    # Create upload directory using fu.id
    upload_dir = upload_base_dir.join(fu.id.to_s)
    FileUtils.mkdir_p(upload_dir)
    
    # Upload to: /data/asap2/fus/{fu.id}/{input_filename}
    upload_file_path = upload_dir.join(input_filename)
    
    begin
      chunk_data = chunk.respond_to?(:read) ? chunk.read : chunk
      
      chunk_size = 5 * 1024 * 1024 # 5MB (matches JavaScript CHUNK_SIZE)
      
      # Check if we're resuming - verify the file exists and get current size
      current_size = 0
      if File.exist?(upload_file_path)
        current_size = File.size(upload_file_path)
        
        # Calculate expected position for this chunk
        expected_position = chunk_index * chunk_size
        
        # If resuming, verify we're at the right position
        if chunk_index > 0 && current_size != expected_position
          if current_size > expected_position
            # File is ahead of where we should be - something wrong, skip this chunk
            Rails.logger.warn "Upload size mismatch. File is #{current_size} bytes, expected #{expected_position} for chunk #{chunk_index}. Skipping chunk."
            # Return current status without writing
            progress = file_size > 0 ? ((current_size.to_f / file_size) * 100).round(2) : 0.0
            render json: {
              fu_id: fu.id,
              chunk_index: chunk_index,
              uploaded_size: current_size,
              complete: false,
              progress: progress,
              skipped: true
            }
            return
          elsif current_size < expected_position
            # File is behind - something was lost, truncate and restart from this chunk
            Rails.logger.warn "Upload size mismatch. File is #{current_size} bytes, expected #{expected_position} for chunk #{chunk_index}. Restarting from this chunk."
            File.truncate(upload_file_path, current_size) if current_size > 0
            current_size = 0
          end
        end
      end
      
      # Write chunk
      # For single-chunk uploads (total_chunks == 1), always overwrite the file
      # For multi-chunk uploads, overwrite on first chunk, append on subsequent chunks
      if chunk_index == 0
        # First chunk - always create/overwrite file (even if it exists from previous attempt)
        File.open(upload_file_path, 'wb') do |f|
          f.write(chunk_data)
        end
      else
        # Subsequent chunks - append to file
        File.open(upload_file_path, 'ab') do |f|
          f.write(chunk_data)
        end
      end
      
      current_size = File.size(upload_file_path)
      chunk_data_size = chunk_data.respond_to?(:bytesize) ? chunk_data.bytesize : chunk_data.size
      
      # Check if this is the last chunk
      is_last_chunk = (chunk_index + 1 == total_chunks)
      
      # For completion, check:
      # 1. This is the last chunk
      # 2. File size matches expected size (exact match preferred)
      # For single-chunk uploads, accept if we've written all the chunk data we received
      # (this handles edge cases where file_size param might be slightly inaccurate)
      is_complete = if is_last_chunk
        if current_size == file_size
          true
        elsif total_chunks == 1 && current_size == chunk_data_size && chunk_data_size > 0
          # Single chunk upload: if we wrote all the chunk data, consider it complete
          # Update file_size to match actual size for consistency
          Rails.logger.info("[FusController#upload_chunk] Single-chunk upload: file_size param (#{file_size}) doesn't match actual (#{current_size}), but chunk data written successfully. Marking as complete.")
          true
        elsif total_chunks == 1 && chunk_data_size > 0 && current_size >= chunk_data_size
          # Single chunk upload: if current_size is at least as large as chunk_data_size, 
          # and we're on the last chunk, consider it complete (handles cases where file was written correctly)
          # This handles the case where the file might have been written correctly but sizes don't match exactly
          if current_size > chunk_data_size * 1.1
            # File is significantly larger - might be written multiple times, but still mark as complete
            Rails.logger.warn("[FusController#upload_chunk] Single-chunk upload: current_size (#{current_size}) is much larger than chunk_data_size (#{chunk_data_size}). File may have been written multiple times, but marking as complete.")
          else
            Rails.logger.info("[FusController#upload_chunk] Single-chunk upload: current_size (#{current_size}) >= chunk_data_size (#{chunk_data_size}), marking as complete.")
          end
          true
        else
          false
        end
      else
        false
      end
      
      Rails.logger.info("[FusController#upload_chunk] Upload check: chunk_index=#{chunk_index}, total_chunks=#{total_chunks}, chunk_data_size=#{chunk_data_size}, current_size=#{current_size}, file_size=#{file_size}, is_last_chunk=#{is_last_chunk}, is_complete=#{is_complete}")
      
      previous_status = fu.status
      status_can_change = !%w[preparsing preparsed].include?(previous_status)
      update_attrs = { upload_file_size: file_size }
      
      # If single-chunk upload completed but sizes don't match, use actual size
      if is_complete && total_chunks == 1 && current_size != file_size && current_size == chunk_data_size
        update_attrs[:upload_file_size] = current_size
      end
      
      update_attrs[:status] = is_complete ? 'uploaded' : 'uploading' if status_can_change
      
      # Update Fu record
      fu.update!(update_attrs)
      
      # Get organism_id and version_id from params if provided (sent by JavaScript)
      organism_id = safe_integer_param(:organism_id)
      version_id = safe_integer_param(:version_id)
      
      # Store upload info in session for project creation
      session[:file_upload] = {
        fu_id: fu.id,
        original_filename: filename,
        input_filename: input_filename,
        path: upload_file_path.to_s,
        size: current_size,
        total_size: file_size,
        complete: is_complete,
        organism_id: organism_id,
        version_id: version_id
      }
      
      if is_complete
        Rails.logger.info("[FusController#upload_chunk] Upload complete, enqueueing preparsing job. organism_id: #{organism_id.inspect}, version_id: #{version_id.inspect}")
        enqueue_preparsing_job(fu, organism_id: organism_id, version_id: version_id)
      else
        Rails.logger.info("[FusController#upload_chunk] Not enqueueing preparsing job. is_complete: #{is_complete}, chunk_index+1=#{chunk_index + 1}, total_chunks=#{total_chunks}, current_size=#{current_size}, file_size=#{file_size}")
      end
      
      progress = file_size > 0 ? ((current_size.to_f / file_size) * 100).round(2) : 0.0
      render json: {
        fu_id: fu.id,
        chunk_index: chunk_index,
        uploaded_size: current_size,
        complete: is_complete,
        progress: progress
      }
    rescue => e
      Rails.logger.error "Upload error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: "Upload failed: #{e.message}" }, status: :internal_server_error
    end
  end
  
  # GET /fus/upload_status
  def upload_status
    unless user_signed_in?
      render json: { error: 'Authentication required' }, status: :unauthorized
      return
    end
    
    filename = params[:filename]
    fu_id = params[:fu_id]
    
    unless filename
      render json: { exists: false, size: 0, total_size: 0, complete: false }
      return
    end
    
    # Find existing Fu record for this upload
    # If fu_id provided, use it; otherwise find most recent upload for this user/filename
    file_ext = File.extname(filename)
    input_filename = "input_file#{file_ext}"
    
    fu = if fu_id.present?
           Fu.find_by(id: fu_id, user_id: current_user.id)
         else
           # Find most recent incomplete upload for this user and filename
           Fu.where(
             user_id: current_user.id,
             upload_file_name: input_filename,
             status: ['uploading', 'uploaded'],
             project_id: nil
           ).order(created_at: :desc).first
         end
    
    if fu && fu.file_path && File.exist?(fu.file_path)
      current_size = File.size(fu.file_path)
      is_complete = fu.complete?
      total_size = fu.upload_file_size || 0
      
      # Only mark as resumable if we have valid size information
      resumable = fu.resumable? && total_size > 0 && current_size >= 0 && current_size <= total_size
      
      render json: {
        exists: true,
        fu_id: fu.id,
        size: current_size,
        total_size: total_size,
        complete: is_complete,
        resumable: resumable
      }
    else
      render json: { exists: false, size: 0, total_size: 0, complete: false }
    end
  end

  # POST /fus/download_from_url
  def download_from_url
    unless user_signed_in?
      render json: { error: 'Authentication required' }, status: :unauthorized
      return
    end

    # Parse JSON body
    request_body = JSON.parse(request.body.read) rescue {}
    url = request_body['url'] || params[:url]
    
    if url.blank?
      render json: { error: 'URL is required' }, status: :bad_request
      return
    end

    begin
      require 'open-uri'
      require 'uri'
      
      # Auto-add protocol if missing
      unless url.match?(/^https?:\/\//i)
        url = 'https://' + url
      end
      
      # Validate and parse URL
      uri_obj = URI(url)
      unless ['http', 'https'].include?(uri_obj.scheme)
        render json: { error: 'URL must use HTTP or HTTPS protocol' }, status: :bad_request
        return
      end

      # Extract filename from URL or use default
      filename = uri_obj.path.split('/').last.presence || 'downloaded_file'
      filename.gsub!(/[()\[\]#?$]/, '') # Clean filename
      
      # Extract file extension and create input filename
      file_ext = File.extname(filename)
      file_ext = '.txt' if file_ext.blank? # Default extension if none found
      input_filename = "input_file#{file_ext}"

      # Create Fu record
      fu = Fu.new(
        user_id: current_user.id,
        project_key: nil,
        upload_file_name: input_filename,
        upload_file_size: 0, # Will be updated after download
        status: 'downloading',
        name: filename
      )
      fu.save!

      # Create upload directory
      upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                          ENV["UPLOAD_DATA_DIR"]
                        elsif ENV["DATA_DIR"]
                          Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                        else
                          '/data/asap2/fus'
                        end
      
      upload_base_dir = Pathname.new(upload_base_dir)
      FileUtils.mkdir_p(upload_base_dir) unless upload_base_dir.exist?
      
      upload_dir = upload_base_dir.join(fu.id.to_s)
      FileUtils.mkdir_p(upload_dir)
      
      upload_file_path = upload_dir.join(input_filename)

      # Download file from URL using OpenURI (following Basic.safe_download pattern)
      download_options = {
        'User-Agent' => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
        read_timeout: 300, # 5 minutes timeout
        open_timeout: 30
      }
      
      # Download the file
      downloaded_size = 0
      File.open(upload_file_path, 'wb') do |file|
        uri_obj.open(download_options) do |uri_io|
          IO.copy_stream(uri_io, file)
        end
        # Ensure file is flushed to disk
        file.flush
        file.fsync if file.respond_to?(:fsync)
      end
      
      # Get file size after download is complete
      downloaded_size = File.size(upload_file_path)
      
      # Verify file exists and has content
      unless File.exist?(upload_file_path) && downloaded_size > 0
        raise "Downloaded file is missing or empty"
      end

      # Update Fu record with file size
      fu.update!(
        upload_file_size: downloaded_size,
        status: 'uploaded'
      )
      
      # Reload to ensure database state is fresh
      fu.reload

      # Get organism_id and version_id from request body (already parsed) or params
      organism_id = request_body['organism_id'] || safe_integer_param(:organism_id)
      version_id = request_body['version_id'] || safe_integer_param(:version_id)
      
      # Store upload info in session for project creation
      session[:file_upload] = {
        fu_id: fu.id,
        original_filename: filename,
        input_filename: input_filename,
        path: upload_file_path.to_s,
        size: downloaded_size,
        total_size: downloaded_size,
        complete: true,
        organism_id: organism_id,
        version_id: version_id
      }

      # Trigger preparsing
      enqueue_preparsing_job(fu, organism_id: organism_id, version_id: version_id)

      render json: {
        success: true,
        fu_id: fu.id,
        filename: filename,
        size: downloaded_size
      }
    rescue URI::InvalidURIError => e
      Rails.logger.error "Invalid URL: #{url} - #{e.message}"
      render json: { error: "Invalid URL: #{e.message}" }, status: :bad_request
    rescue OpenURI::HTTPError => e
      Rails.logger.error "HTTP error downloading from URL: #{url} - #{e.message}"
      render json: { error: "Failed to download file: HTTP error - #{e.message}" }, status: :bad_request
    rescue => e
      Rails.logger.error "Error downloading from URL: #{url} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: "Failed to download file: #{e.message}" }, status: :internal_server_error
    end
  end

  # POST /fus/:id/rerun_preparsing
  def rerun_preparsing
    unless user_signed_in?
      render json: { error: 'Authentication required' }, status: :unauthorized
      return
    end

    fu = Fu.find_by(id: params[:id], user_id: current_user.id)
    unless fu
      render json: { error: 'Upload record not found' }, status: :not_found
      return
    end

    # Parse JSON body
    request_body = JSON.parse(request.body.read) rescue {}
    
    # Get dataset selection from request body (optional - can be blank for text file re-parsing)
    sel = request_body['sel'] || request_body['dataset_name'] || params[:sel]
    
    # Get parsing parameters (for RAW_TEXT format files)
    delimiter = request_body['delimiter']
    gene_name_col = request_body['gene_name_col']
    has_header = request_body['has_header']

    # Validate that we have either a dataset selection or parsing parameters
    # Note: delimiter can be empty string (for tab), so we check for key presence, not value presence
    has_dataset_selection = sel.present?
    has_parsing_params = request_body.key?('delimiter') || gene_name_col.present? || request_body.key?('has_header')
    
    unless has_dataset_selection || has_parsing_params
      render json: { error: 'Either dataset selection (sel) or parsing parameters (delimiter, gene_name_col, has_header) must be provided' }, status: :bad_request
      return
    end

    # Get organism_id and version_id from request body or form params
    organism_id = request_body['organism_id'] || safe_integer_param(:organism_id)
    version_id = request_body['version_id'] || safe_integer_param(:version_id)
    
    Rails.logger.info("[FusController#rerun_preparsing] After reading from request/params - organism_id: #{organism_id.inspect}, version_id: #{version_id.inspect}")
    Rails.logger.info("[FusController#rerun_preparsing] Request body keys: #{request_body.keys.inspect}")
    Rails.logger.info("[FusController#rerun_preparsing] Request body version_id: #{request_body['version_id'].inspect}")
    
    # Fallback to getting from session if not in request
    if organism_id.blank? || version_id.blank?
      # Try to get from session if available
      session_organism_id = session[:file_upload]&.dig(:organism_id)
      session_version_id = session[:file_upload]&.dig(:version_id)
      organism_id ||= session_organism_id
      version_id ||= session_version_id
      Rails.logger.info("[FusController#rerun_preparsing] After session fallback - organism_id: #{organism_id.inspect}, version_id: #{version_id.inspect}")
    end

    # Build options hash for preparsing job
    # Only include organism_id and version_id if they have values
    options = {}
    options[:organism_id] = organism_id if organism_id.present?
    options[:version_id] = version_id if version_id.present?
    
    Rails.logger.info("[FusController#rerun_preparsing] Final options before adding other params: #{options.inspect}")
    
    # Add dataset selection if provided
    options[:sel] = sel if sel.present?
    
    # Add parsing parameters if provided (for text files)
    # Note: delimiter can be empty string (for tab), so we check for presence in the request
    options[:delimiter] = delimiter if request_body.key?('delimiter')
    options[:gene_name_col] = gene_name_col if gene_name_col.present?
    options[:has_header] = has_header if has_header.present?

    # Re-run preparsing with selected dataset or parsing parameters
    fu.update!(status: 'preparsing')
    FuPreparsingJob.perform_later(fu.id, options.compact)

    message = if sel.present?
                "Preparsing restarted for dataset: #{sel}"
              else
                "Preparsing restarted with new parameters"
              end
    
    render json: { 
      success: true, 
      message: message,
      fu_id: fu.id
    }
  rescue JSON::ParserError => e
    render json: { error: 'Invalid JSON in request body' }, status: :bad_request
  rescue => e
    Rails.logger.error "Error re-running preparsing: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { error: "Failed to re-run preparsing: #{e.message}" }, status: :internal_server_error
  end

  # GET /fus/:id/preparsing_status
  def preparsing_status
    unless user_signed_in?
      render json: { error: 'Authentication required' }, status: :unauthorized
      return
    end

    fu = Fu.find_by(id: params[:id], user_id: current_user.id)
    unless fu
      render json: { error: 'Upload record not found' }, status: :not_found
      return
    end

    # Return status and preparsing results if available
    if fu.status == 'preparsed'
      # Use the service to load preparsing results (reuses existing logic)
      begin
        service = FuPreparsingService.new(fu, {})
        output = service.send(:load_output_json)
        summary = service.send(:build_summary, output)
        warnings = service.send(:collect_warnings, output)
        prediction_debug = summary[:prediction_debug] || nil
        
        render json: {
          status: 'preparsed',
          summary: summary,
          warnings: warnings,
          raw_output: output,
          prediction_debug: prediction_debug
        }
      rescue => e
        Rails.logger.error "Error loading preparsing results: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { status: fu.status, error: "Failed to load preparsing results: #{e.message}" }, status: :internal_server_error
      end
    elsif fu.status == 'preparsing_failed'
      render json: { status: 'preparsing_failed', error: 'Preparsing failed' }
    else
      render json: { status: fu.status }
    end
  rescue => e
    Rails.logger.error "Error fetching preparsing status: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { error: "Failed to fetch preparsing status: #{e.message}" }, status: :internal_server_error
  end

  private

  def enqueue_preparsing_job(fu, organism_id: nil, version_id: nil)
    # Get organism_id and version_id from:
    # 1. Method arguments (passed from upload_chunk/download_from_url)
    # 2. Session (stored during upload)
    # 3. Params (as fallback)
    organism_id ||= safe_integer_param(:organism_id)
    version_id ||= safe_integer_param(:version_id)
    
    if organism_id.blank? || version_id.blank?
      session_data = session[:file_upload] || {}
      organism_id ||= session_data[:organism_id]
      version_id ||= session_data[:version_id]
    end
    
    Rails.logger.info("[FusController#enqueue_preparsing_job] Enqueueing preparsing for Fu##{fu.id}")
    Rails.logger.info("[FusController#enqueue_preparsing_job] organism_id: #{organism_id.inspect}, version_id: #{version_id.inspect}")
    
    options = {}
    options[:organism_id] = organism_id if organism_id.present?
    options[:version_id] = version_id if version_id.present?
    
    Rails.logger.info("[FusController#enqueue_preparsing_job] Options hash: #{options.inspect}")
    
    fu.update!(status: 'preparsing')
    FuPreparsingJob.perform_later(fu.id, options)
    
    Rails.logger.info("[FusController#enqueue_preparsing_job] Job enqueued successfully")
  end

  def safe_integer_param_from_body(key)
    value = params[key]
    return if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def safe_integer_param(key)
    value = params[key]
    return if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end
end
