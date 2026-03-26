class FusController < ApplicationController
  # POST /fus/upload_chunk
  def upload_chunk
    filename = params[:filename].presence || 'uploaded_file'
    chunk = params[:chunk]
    chunk_index = params[:chunk_index].to_i
    total_chunks = params[:total_chunks].to_i
    file_size = params[:file_size].to_i
    fu_id = params[:fu_id]
    
    # Clean filename
    filename.gsub!(/[()\[\]#?$]/, '')
    
    # Extract file extension and create input filename
    input_filename = nil
    if filename.present?
      file_ext = File.extname(filename)
      input_filename = "input_file#{file_ext}"
    end
    
    # Find or create Fu record for tracking resumable upload
    # Project key will be set later when project is created
    fu = if fu_id.present?
           fu_scope_for_current_actor.find_by(id: fu_id)
         else
           # Create new Fu record on first chunk
           Fu.new(
            user_id: current_user&.id,
            project_key: current_user ? nil : session[:sandbox],
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
    
    # Upload to global fus until a project exists.
    upload_base_dir = Pathname.new(Fu.global_upload_root)
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
    filename = params[:filename]
    fu_id = params[:fu_id]
    
    unless filename.present? || fu_id.present?
      render json: { exists: false, size: 0, total_size: 0, complete: false }
      return
    end
    
    # Find existing Fu record for this upload
    # If fu_id provided, use it; otherwise find most recent upload for this user/filename
    input_filename = nil
    if filename.present?
      file_ext = File.extname(filename)
      input_filename = "input_file#{file_ext}"
    end
    
    fu = if fu_id.present?
           fu_scope_for_current_actor.find_by(id: fu_id)
         else
           # Find most recent incomplete upload for this user and filename
           fu_scope_for_current_actor.where(
             upload_file_name: input_filename,
             status: ['uploading', 'downloading', 'uploaded'],
             project_id: nil
           ).order(created_at: :desc).first
         end
    
    if fu
      current_size = (fu.file_path && File.exist?(fu.file_path)) ? File.size(fu.file_path) : 0
      total_size = fu.upload_file_size || 0
      is_complete = fu.status == 'uploaded' || fu.status == 'preparsing' || fu.status == 'preparsed' || fu.complete?

      # Only mark as resumable if we have valid size information
      resumable = fu.resumable? && total_size > 0 && current_size >= 0 && current_size <= total_size

      render json: {
        exists: true,
        fu_id: fu.id,
        size: current_size,
        total_size: total_size,
        status: fu.status,
        complete: is_complete,
        resumable: resumable,
        filename: fu.name,
        input_filename: fu.upload_file_name
      }
    else
      render json: { exists: false, size: 0, total_size: 0, complete: false }
    end
  end

  # POST /fus/download_from_url
  def download_from_url
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
      normalized_url = uri_obj.to_s

      # Extract filename from URL or use default
      filename = uri_obj.path.split('/').last.presence || 'downloaded_file'
      filename.gsub!(/[()\[\]#?$]/, '') # Clean filename
      
      # Extract file extension and create input filename
      file_ext = File.extname(filename)
      file_ext = '.txt' if file_ext.blank? # Default extension if none found
      input_filename = "input_file#{file_ext}"

      # Temporary reuse optimization: if same URL was already downloaded by this user, reuse it.
      reusable_fu = fu_scope_for_current_actor.where(url: normalized_url)
                      .where(status: %w[downloading uploaded preparsing preparsed completed])
                      .order(updated_at: :desc)
                      .detect do |candidate|
        if candidate.status == 'downloading'
          # Reuse only fresh in-progress downloads; stale records should not block new attempts.
          candidate.updated_at && candidate.updated_at > 30.minutes.ago
        else
          path = candidate.file_path
          path && File.exist?(path) && File.size(path) > 0
        end
      end

      if reusable_fu
        upload_path = reusable_fu.file_path
        size = (upload_path && File.exist?(upload_path)) ? File.size(upload_path) : 0
        status = reusable_fu.status == 'completed' ? 'uploaded' : reusable_fu.status
        is_complete = %w[uploaded preparsing preparsed completed].include?(reusable_fu.status)

        session[:file_upload] = {
          fu_id: reusable_fu.id,
          original_filename: reusable_fu.name.presence || filename,
          input_filename: reusable_fu.upload_file_name,
          path: upload_path&.to_s,
          size: size,
          total_size: reusable_fu.upload_file_size || size,
          complete: is_complete,
          organism_id: request_body['organism_id'] || safe_integer_param(:organism_id),
          version_id: request_body['version_id'] || safe_integer_param(:version_id)
        }

        render json: {
          success: true,
          fu_id: reusable_fu.id,
          filename: reusable_fu.name.presence || filename,
          size: size,
          status: status,
          reused: true
        }
        return
      end

      fu = Fu.create!(
        user_id: current_user&.id,
        project_key: current_user ? nil : session[:sandbox],
        upload_file_name: input_filename,
        upload_file_size: 0,
        status: 'downloading',
        name: filename,
        url: normalized_url
      )

      # Get organism_id and version_id from request body (already parsed) or params
      organism_id = request_body['organism_id'] || safe_integer_param(:organism_id)
      version_id = request_body['version_id'] || safe_integer_param(:version_id)

      upload_dir = Pathname.new(Fu.global_upload_root).join(fu.id.to_s)
      upload_file_path = upload_dir.join(input_filename)

      # Store upload info in session for project creation (completion checked through Fu status)
      session[:file_upload] = {
        fu_id: fu.id,
        original_filename: filename,
        input_filename: input_filename,
        path: upload_file_path.to_s,
        size: 0,
        total_size: 0,
        complete: false,
        organism_id: organism_id,
        version_id: version_id
      }

      FuDownloadFromUrlJob.perform_later(
        fu.id,
        normalized_url,
        organism_id: organism_id,
        version_id: version_id
      )

      render json: {
        success: true,
        fu_id: fu.id,
        filename: filename,
        status: 'downloading'
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
    fu = fu_scope_for_current_actor.find_by(id: params[:id])
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
    
    # Prefer project-bound values for reruns when request does not pass them.
    # This avoids using stale session values from a different flow.
    if organism_id.blank? || version_id.blank?
      project = fu.project
      if project
        organism_id ||= project.organism_id
        version_id ||= project.version_id
      end
      Rails.logger.info("[FusController#rerun_preparsing] After project fallback - organism_id: #{organism_id.inspect}, version_id: #{version_id.inspect}")
    end

    # Fallback to getting from session if still missing.
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
    enqueued_at = Time.current
    options[:enqueued_at] = enqueued_at.iso8601
    fu.update!(status: 'preparsing')
    job = FuPreparsingJob.perform_later(fu.id, options.compact)
    Rails.logger.info("[FusController#rerun_preparsing] Enqueued FuPreparsingJob for Fu##{fu.id} job_id=#{job.job_id} enqueued_at=#{enqueued_at.utc.iso8601}")

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
    fu = fu_scope_for_current_actor.find_by(id: params[:id])
    unless fu
      render json: { error: 'Upload record not found' }, status: :not_found
      return
    end

    if fu.status == 'uploaded' && fu.complete?
      enqueue_preparsing_job(fu)
      fu.reload
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
      project = fu.project
      if project
        organism_id ||= project.organism_id
        version_id ||= project.version_id
      end
    end
    
    if organism_id.blank? || version_id.blank?
      session_data = session[:file_upload] || {}
      organism_id ||= session_data[:organism_id]
      version_id ||= session_data[:version_id]
    end
    
    enqueue_started_at = Time.current
    Rails.logger.info("[FusController#enqueue_preparsing_job] Enqueueing preparsing for Fu##{fu.id} at=#{enqueue_started_at.utc.iso8601}")
    Rails.logger.info("[FusController#enqueue_preparsing_job] organism_id: #{organism_id.inspect}, version_id: #{version_id.inspect}")
    
    options = {}
    options[:organism_id] = organism_id if organism_id.present?
    options[:version_id] = version_id if version_id.present?
    options[:enqueued_at] = enqueue_started_at.iso8601
    
    Rails.logger.info("[FusController#enqueue_preparsing_job] Options hash: #{options.inspect}")
    
    fu.update!(status: 'preparsing')
    job = FuPreparsingJob.perform_later(fu.id, options)
    
    enqueue_elapsed_ms = ((Time.current - enqueue_started_at) * 1000).round
    Rails.logger.info("[FusController#enqueue_preparsing_job] Job enqueued successfully job_id=#{job.job_id} enqueue_elapsed_ms=#{enqueue_elapsed_ms}")
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

  def fu_scope_for_current_actor
    if user_signed_in?
      Fu.where(user_id: current_user.id)
    else
      Fu.where(user_id: nil, project_key: session[:sandbox])
    end
  end
end
