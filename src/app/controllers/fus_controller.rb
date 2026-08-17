class FusController < ApplicationController
  # POST /fus/upload_chunk
  def upload_chunk
    filename = params[:filename].presence || 'uploaded_file'
    chunk = params[:chunk]
    chunk_index = params[:chunk_index].to_i
    total_chunks = params[:total_chunks].to_i
    file_size = params[:file_size].to_i
    fu_id = params[:fu_id]
    upload_type = resolved_upload_type
    compliance_upload = compliance_upload?(upload_type)
    dna_accessibility_upload = dna_accessibility_upload?(upload_type)
    
    # Clean filename
    filename.gsub!(/[()\[\]#?$]/, '')

    if compliance_upload
      ComplianceFileCheckQueueService.validate_upload!(filename: filename, file_size: file_size)
    end
    if dna_accessibility_upload
      DnaAccessibilityFinalizeService.validate_filename!(
        filename,
        upload_type_name: UploadType.name_for(upload_type)
      )
    end
    
    # Extract file extension and create input filename.
    # Preserve compound archive extensions like .tar.gz / .tsv.gz.
    input_filename = build_input_filename(filename)
    
    # Find or create Fu record for tracking resumable upload
    # Project key will be set later when project is created
    fu = if fu_id.present?
           find_fu_for_current_actor(fu_id)
         else
           resetting_project = resetting_parsing_project_for_current_actor
           dna_project = dna_accessibility_upload ? resolve_dna_accessibility_project! : nil
           attached_project = dna_project || resetting_project
           # Create new Fu record on first chunk
           Fu.new(
            user_id: current_user&.id,
            project_id: attached_project&.id,
            project_key: if attached_project
                           attached_project.key
                         elsif current_user
                           nil
                         else
                           session[:sandbox]
                         end,
             upload_file_name: input_filename,
             upload_file_size: file_size,
             status: 'uploading',
             name: filename,
             upload_type: upload_type
           )
         end
    
    unless fu
      render json: { error: 'Upload record not found' }, status: :bad_request
      return
    end
    
    fu.save! if fu.new_record?
    
    # Upload directory is project-local when Fu is attached to a project
    # (e.g. parsing reset flow), otherwise global fus staging.
    upload_dir = fu.upload_dir
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

      content_digest = InputFileSha256.update_after_chunk!(
        upload_dir: upload_dir,
        chunk_index: chunk_index,
        chunk_data: chunk_data,
        file_path: upload_file_path,
        fu_id: fu.id
      )
      
      current_size = File.size(upload_file_path)
      chunk_data_size = chunk_data.respond_to?(:bytesize) ? chunk_data.bytesize : chunk_data.size
      
      # Check if this is the last chunk
      is_last_chunk = (chunk_index + 1 == total_chunks)
      
      # For completion, check:
      # 1. This is the last chunk
      # 2. File size matches expected size
      # For single-chunk uploads, accept only when the written bytes exactly
      # match the received chunk payload size (client file_size can be off).
      is_complete = if is_last_chunk
        if current_size == file_size
          true
        elsif total_chunks == 1 && current_size == chunk_data_size && chunk_data_size > 0
          # Single-chunk upload with accurate bytes written.
          Rails.logger.info("[FusController#upload_chunk] Single-chunk upload: file_size param (#{file_size}) doesn't match actual (#{current_size}), but chunk data written successfully. Marking as complete.")
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
      if is_complete && content_digest
        update_attrs[:content_sha256] = content_digest.hexdigest
        InputFileSha256.clear_state!(fu.id)
      end
      
      # Update Fu record
      fu.update!(update_attrs)
      
      # Get organism_id and version_id from params if provided (sent by JavaScript)
      organism_id = safe_integer_param(:organism_id)
      version_id = safe_integer_param(:version_id)
      
      # Store upload info in session for project creation
      unless compliance_upload?(fu.upload_type) || dna_accessibility_upload?(fu.upload_type)
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
      end
      
      if is_complete
        if compliance_upload?(fu.upload_type)
          schema_id = params[:schema_id].presence || 'scfair_7_1_0'
          queue_result = ComplianceFileCheckQueueService.call(fu: fu, schema_id: schema_id)
          progress = 100.0
          render json: {
            fu_id: fu.id,
            chunk_index: chunk_index,
            uploaded_size: current_size,
            complete: true,
            progress: progress,
            task_id: queue_result[:task_id],
            status: queue_result[:status],
            schema_id: queue_result[:schema_id]
          }
          return
        end

        if dna_accessibility_upload?(fu.upload_type)
          project = fu.project || resolve_dna_accessibility_project!
          finalize_result = DnaAccessibilityFinalizeService.new(fu: fu, project: project).call
          progress = 100.0
          render json: {
            fu_id: fu.id,
            chunk_index: chunk_index,
            uploaded_size: current_size,
            complete: true,
            progress: progress,
            status: 'completed',
            saved_path: finalize_result[:path],
            saved_filename: finalize_result[:filename],
            saved_size: finalize_result[:size]
          }
          return
        end

        if version_id.blank?
          render json: { error: 'Select an ASAP release before finishing the upload' }, status: :unprocessable_entity
          return
        end

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
    rescue ComplianceFileCheckQueueService::UnsupportedFormatError => e
      render json: {
        error: e.message,
        error_code: ComplianceFileCheckQueueService::UNSUPPORTED_FORMAT_ERROR_CODE
      }, status: :unprocessable_entity
    rescue ArgumentError, DnaAccessibilityFinalizeService::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
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
    input_filename = build_input_filename(filename)
    
    fu = if fu_id.present?
           find_fu_for_current_actor(fu_id)
         else
           scope = fu_scope_for_current_actor.where(
             upload_file_name: input_filename,
             status: ['uploading', 'downloading', 'uploaded', 'validating', 'validated', 'validation_failed'],
             project_id: nil
           )
           upload_type_id = upload_type_id_from_name_param
           scope = scope.where(upload_type: upload_type_id) if upload_type_id.present?
           scope.order(created_at: :desc).first
         end
    
    if fu
      current_size = (fu.file_path && File.exist?(fu.file_path)) ? File.size(fu.file_path) : 0
      total_size = fu.upload_file_size || 0
      # Do not treat size match alone as complete while URL download job is still running;
      # otherwise the UI hands off to preparsing before FuDownloadFromUrlJob updates status.
      is_complete = if compliance_upload?(fu.upload_type)
                      %w[validating validated validation_failed].include?(fu.status) ||
                        (fu.status != 'downloading' && fu.complete?)
                    elsif dna_accessibility_upload?(fu.upload_type)
                      %w[uploaded completed].include?(fu.status) ||
                        (fu.status != 'downloading' && fu.complete?)
                    else
                      %w[uploaded preparsing preparsed completed].include?(fu.status) ||
                        (fu.status != 'downloading' && fu.complete?)
                    end

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

      upload_type_name = (request_body['upload_type_name'] || params[:upload_type_name]).to_s.strip
      upload_type_id = if upload_type_name.present?
                         id = UploadType.id_for(upload_type_name)
                         raise ArgumentError, "Unknown upload type: #{upload_type_name}" unless id

                         id
                       else
                         UploadType.id_for('project_input')
                       end
      dna_accessibility_upload = dna_accessibility_upload?(upload_type_id)
      dna_project = dna_accessibility_upload ? resolve_dna_accessibility_project!(request_body) : nil
      
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

      if dna_accessibility_upload
        upload_type_name_for_ext = UploadType.name_for(upload_type_id)
        ext = DnaAccessibilityFinalizeService.extension_for(filename)
        config = DnaAccessibilityFinalizeService.asset_config_for(upload_type_name_for_ext)
        unless config && config[:allowed_extensions].include?(ext)
          filename = DnaAccessibilityFinalizeService.default_filename_for(upload_type_name_for_ext) ||
                     'dna_accessibility.tsv.bgz'
        end
      end
      
      # Extract file extension and create input filename.
      # Preserve compound archive extensions like .tar.gz / .tsv.bgz / .tsv.bgz.tbi.
      file_ext = extract_upload_extension(filename)
      file_ext = '.txt' if file_ext.blank?
      input_filename = "input_file#{file_ext}"

      # Temporary reuse optimization: if same URL was already downloaded by this user, reuse it.
      # Only unattached uploads: a Fu already linked to a project must not be reused for a new project.
      # Include standalone compliance-check statuses so a file already fetched for
      # /compliance/file-check can be moved into a new project without a second download.
      # DNA accessibility uploads are project-scoped and never reuse project_input Fus.
      unless dna_accessibility_upload
        reusable_fu = fu_scope_for_current_actor.where(url: normalized_url, project_id: nil)
                        .where(status: %w[downloading uploaded preparsing preparsed completed validated validation_failed])
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
          reusable_fu.adopt_as_project_input!
          reusable_fu.reload
          upload_path = reusable_fu.file_path
          size = (upload_path && File.exist?(upload_path)) ? File.size(upload_path) : 0
          organism_id = request_body['organism_id'] || safe_integer_param(:organism_id)
          version_id = request_body['version_id'] || safe_integer_param(:version_id)

          if preparsing_result_stale?(reusable_fu, requested_version_id: version_id)
            Rails.logger.info(
              "[FusController#download_from_url] Re-preparsing reused Fu##{reusable_fu.id} " \
              "(stale output or version #{version_id} != #{reusable_fu.preparsing_version_id})"
            )
            enqueue_preparsing_job(reusable_fu, organism_id: organism_id, version_id: version_id)
            reusable_fu.reload

            session[:file_upload] = {
              fu_id: reusable_fu.id,
              original_filename: reusable_fu.name.presence || filename,
              input_filename: reusable_fu.upload_file_name,
              path: upload_path&.to_s,
              size: size,
              total_size: reusable_fu.upload_file_size || size,
              complete: false,
              organism_id: organism_id,
              version_id: version_id
            }

            render json: {
              success: true,
              fu_id: reusable_fu.id,
              filename: reusable_fu.name.presence || filename,
              size: size,
              status: reusable_fu.status,
              reused: false
            }
            return
          end

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
            organism_id: organism_id,
            version_id: version_id
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
      end

      # Get organism_id and version_id from request body (already parsed) or params
      organism_id = request_body['organism_id'] || safe_integer_param(:organism_id)
      version_id = request_body['version_id'] || safe_integer_param(:version_id)

      fu = Fu.create!(
        user_id: current_user&.id,
        project_id: dna_project&.id,
        project_key: dna_project&.key || (current_user ? nil : session[:sandbox]),
        upload_file_name: input_filename,
        upload_file_size: 0,
        status: 'downloading',
        name: filename,
        url: normalized_url,
        upload_type: upload_type_id,
        preparsing_version_id: version_id
      )

      upload_dir = fu.upload_dir
      FileUtils.mkdir_p(upload_dir)
      upload_file_path = upload_dir.join(input_filename)

      unless dna_accessibility_upload
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
      end

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
    rescue ArgumentError, DnaAccessibilityFinalizeService::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
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
    fu = find_fu_for_current_actor(params[:id])
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
    has_parsing_params = request_body.key?('delimiter') || gene_name_col.present? || request_body.key?('has_header') ||
                         request_body.key?('rowname_metadata') || request_body.key?('colname_metadata')
    
    has_version_rerun = request_body.key?('version_id') && request_body['version_id'].present?

    unless has_dataset_selection || has_parsing_params || has_version_rerun
      render json: { error: 'Either dataset selection (sel), parsing parameters (delimiter, gene_name_col, has_header), or version_id must be provided' }, status: :bad_request
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
    
    if version_id.blank?
      render json: { error: 'version_id is required to re-run preparsing' }, status: :bad_request
      return
    end

    Rails.logger.info("[FusController#rerun_preparsing] Final options before adding other params: #{options.inspect}")
    
    # Add dataset selection if provided
    options[:sel] = sel if sel.present?
    
    # Add parsing parameters if provided (for text files)
    # Note: delimiter can be empty string (for tab), so we check for presence in the request
    options[:delimiter] = delimiter if request_body.key?('delimiter')
    options[:gene_name_col] = gene_name_col if gene_name_col.present?
    options[:has_header] = has_header if has_header.present?
    if request_body.key?('rowname_metadata')
      options[:rowname_metadata] = H5adPreparsingMetadata.java_metadata_path(
        request_body['rowname_metadata'],
        :row
      )
    end
    if request_body.key?('colname_metadata')
      options[:colname_metadata] = H5adPreparsingMetadata.java_metadata_path(
        request_body['colname_metadata'],
        :col
      )
    end

    # Re-run preparsing with selected dataset or parsing parameters
    enqueued_at = Time.current
    options[:enqueued_at] = enqueued_at.iso8601
    fu.update!(status: 'preparsing', preparsing_version_id: version_id)
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
    fu = find_fu_for_current_actor(params[:id])
    unless fu
      render json: { error: 'Upload record not found' }, status: :not_found
      return
    end

    if fu.status == 'uploaded' && fu.complete?
      version_id = preparsing_version_id_from_request
      organism_id = safe_integer_param(:organism_id) || session[:file_upload]&.dig(:organism_id)
      enqueue_preparsing_job(fu, organism_id: organism_id, version_id: version_id)
      fu.reload
    end

    # Return status and preparsing results if available
    if fu.status == 'preparsed' || fu.status == 'completed'
      if preparsing_result_stale?(fu)
        version_id = preparsing_version_id_from_request || fu.preparsing_version_id
        organism_id = safe_integer_param(:organism_id) || session[:file_upload]&.dig(:organism_id)
        Rails.logger.info("[FusController#preparsing_status] Re-preparsing Fu##{fu.id}: stale preparsing result")
        fu.update!(status: 'preparsing')
        enqueue_preparsing_job(fu, organism_id: organism_id, version_id: version_id)
        fu.reload
        render json: { status: fu.status }
        return
      end

      # Use the service to load preparsing results (reuses existing logic)
      begin
        service = FuPreparsingService.new(fu, preparsing_status_service_options(fu))
        output = service.send(:load_output_with_enrichment)
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
      render json: { status: 'preparsing_failed', error: preparsing_failure_message_for(fu) }
    else
      render json: { status: fu.status }
    end
  rescue => e
    Rails.logger.error "Error fetching preparsing status: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { error: "Failed to fetch preparsing status: #{e.message}" }, status: :internal_server_error
  end

  private

  def preparsing_version_id_from_request
    safe_integer_param(:version_id) || session[:file_upload]&.dig(:version_id)
  end

  def preparsing_status_service_options(fu)
    version_id = preparsing_version_id_from_request || fu.preparsing_version_id
    opts = {}
    opts[:version_id] = version_id if version_id.present?
    opts
  end

  def preparsing_result_stale?(fu, requested_version_id: nil)
    requested_version_id ||= preparsing_version_id_from_request

    if requested_version_id.present? && fu.preparsing_version_id.present?
      return true if requested_version_id.to_i != fu.preparsing_version_id.to_i
    end

    output_path = fu.upload_dir + 'output.json'
    return true unless output_path.exist?

    output = JSON.parse(output_path.read)

    version_id = requested_version_id || fu.preparsing_version_id
    return false unless version_id.present? && version_id.to_i < 8

    name = fu.upload_file_name.to_s.downcase

    if name.end_with?('.h5ad')
      host_path = (fu.upload_dir + fu.upload_file_name).to_s
      return false unless File.file?(host_path)

      return H5adJavaPrep.has_legacy_categories?(host_path, workdir: fu.upload_dir)
    end

    return false unless name.end_with?('.rds')

    format = output['detected_format'].to_s
    return true if format == 'COMPRESSED'

    format == 'RDS' && !(fu.upload_dir + 'input.loom').exist?
  rescue JSON::ParserError
    true
  end

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

    if version_id.blank?
      raise ArgumentError,
            'version_id is required to enqueue preparsing (select a release on the upload form)'
    end

    Rails.logger.info("[FusController#enqueue_preparsing_job] Options hash: #{options.inspect}")
    
    fu.update!(status: 'preparsing', preparsing_version_id: version_id)
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

  # Project-local paths use Project#user_id (USER_DATA_DIR/<owner>/<key>/fus/<fu_id>/).
  # fus.user_id is not always set, so signed-in scope also includes rows linked to projects
  # owned by the current user.
  def fu_scope_for_current_actor
    if user_signed_in?
      uid = current_user.id
      fu_t = Fu.arel_table
      projects_t = Project.arel_table
      Fu.left_joins(:project).where(
        fu_t[:user_id].eq(uid).or(projects_t[:user_id].eq(uid))
      )
    else
      Fu.where(user_id: nil, project_key: session[:sandbox])
    end
  end

  # Covers sandbox and admin cases not matched by fu_scope_for_current_actor alone.
  # Never return a Fu loaded through fu_scope_for_current_actor when signed in: that scope
  # uses left_joins(:project) and those rows are readonly, so update! would raise.
  def find_fu_for_current_actor(fu_id)
    return nil if fu_id.blank?

    if fu_scope_for_current_actor.where(id: fu_id).exists?
      return Fu.find_by(id: fu_id)
    end

    fu = Fu.find_by(id: fu_id)
    return nil unless fu

    project = fu.project
    return fu if project.present? && editable?(project)

    nil
  end

  def build_input_filename(filename)
    "input_file#{extract_upload_extension(filename)}"
  end

  def resolved_upload_type
    upload_type_id_from_name_param || UploadType.id_for('project_input')
  end

  def compliance_upload?(upload_type_id)
    UploadType.name_for(upload_type_id) == 'compliance_file_check'
  end

  def dna_accessibility_upload?(upload_type_id)
    DnaAccessibilityFinalizeService.dna_accessibility_upload_type?(UploadType.name_for(upload_type_id))
  end

  def resolve_dna_accessibility_project!(request_body = nil)
    raw_id = params[:project_id].presence
    raw_id ||= request_body['project_id'] if request_body.is_a?(Hash)
    raise ArgumentError, 'project_id is required for DNA accessibility upload' if raw_id.blank?

    project = Project.find_by(id: raw_id) || Project.find_by(key: raw_id.to_s)
    raise ArgumentError, 'Project not found' unless project
    raise ArgumentError, 'Not authorized for this project' unless editable?(project)

    project
  end

  def upload_type_id_from_name_param
    name = params[:upload_type_name].to_s.strip
    return if name.blank?

    id = UploadType.id_for(name)
    raise ArgumentError, "Unknown upload type: #{name}" unless id

    id
  end

  def extract_upload_extension(filename)
    normalized = filename.to_s.downcase
    multi_part_extension = %w[
      .tsv.bgz.tbi
      .tsv.bgz
      .tsv.gz
      .tar.gz
      .tar.bz2
      .tar.xz
      .tar.zst
      .tgz
      .tbz2
      .txz
    ].find { |ext| normalized.end_with?(ext) }

    multi_part_extension || File.extname(filename.to_s)
  end

  def resetting_parsing_project_for_current_actor
    project_id = session[:resetting_parsing_project_id]
    return nil if project_id.blank?

    project = Project.find_by(id: project_id)
    return nil unless project

    if user_signed_in?
      return nil unless project.user_id == current_user&.id || admin?
    else
      return nil unless project.sandbox? && session[:sandbox].present? && project.key == session[:sandbox]
    end

    project
  end

  def preparsing_failure_message_for(fu)
    output_json_path = fu.upload_dir + 'output.json'
    if output_json_path.exist?
      begin
        output = FuPreparsingService.parse_preparsing_output_json(output_json_path.read)
        displayed_error = output['displayed_error']
        if displayed_error.is_a?(Array)
          first_error = displayed_error.find { |entry| entry.present? }
          return normalize_preparsing_error_message(first_error.to_s) if first_error.present?
        elsif displayed_error.present?
          return normalize_preparsing_error_message(displayed_error.to_s)
        end
      rescue JSON::ParserError, RuntimeError => e
        return "Preparsing produced invalid output JSON: #{e.message}"
      end
    end

    output_err_path = fu.upload_dir + 'output.err'
    if output_err_path.exist?
      err_text = output_err_path.read.to_s.strip
      return normalize_preparsing_error_message(err_text) if err_text.present?
    end

    'Input file format is not recognized. Please upload a supported format.'
  end

  def normalize_preparsing_error_message(message)
    text = message.to_s.strip
    return text if text.blank?

    if text.downcase.include?('file format not detected')
      return 'Input file format is not recognized. Please upload a supported format.'
    end

    text
  end
end
