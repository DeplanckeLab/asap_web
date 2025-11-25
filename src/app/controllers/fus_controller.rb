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
            render json: {
              fu_id: fu.id,
              chunk_index: chunk_index,
              uploaded_size: current_size,
              complete: false,
              progress: ((current_size.to_f / file_size) * 100).round(2),
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
      if chunk_index == 0 && current_size == 0
        # First chunk - create new file
        File.open(upload_file_path, 'wb') do |f|
          f.write(chunk_data)
        end
      else
        # Subsequent chunks or resume - append to file
        File.open(upload_file_path, 'ab') do |f|
          f.write(chunk_data)
        end
      end
      
      current_size = File.size(upload_file_path)
      is_complete = (chunk_index + 1 == total_chunks) && (current_size == file_size)
      
      # Update Fu record
      fu.update!(
        upload_file_size: file_size,
        status: is_complete ? 'uploaded' : 'uploading'
      )
      
      # Store upload info in session for project creation
      session[:file_upload] = {
        fu_id: fu.id,
        original_filename: filename,
        input_filename: input_filename,
        path: upload_file_path.to_s,
        size: current_size,
        total_size: file_size,
        complete: is_complete
      }
      
      render json: {
        fu_id: fu.id,
        chunk_index: chunk_index,
        uploaded_size: current_size,
        complete: is_complete,
        progress: ((current_size.to_f / file_size) * 100).round(2)
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
      
      render json: {
        exists: true,
        fu_id: fu.id,
        size: current_size,
        total_size: fu.upload_file_size || 0,
        complete: is_complete,
        resumable: fu.resumable?
      }
    else
      render json: { exists: false, size: 0, total_size: 0, complete: false }
    end
  end
end

