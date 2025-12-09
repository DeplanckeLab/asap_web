class Fu < ApplicationRecord
  # Model for tracking file uploads with resumable capability
  # Used to store temporary upload information before project creation
  
  belongs_to :project, optional: true
  belongs_to :user, optional: true
  
  validates :upload_file_name, presence: true
  # project_key can be nil until project is created
  
  # Get the file path for this upload (stored in /data/asap2/fus/{id}/)
  def file_path
    return nil unless id && upload_file_name
    
    upload_base_dir = if ENV["UPLOAD_DATA_DIR"]
                        ENV["UPLOAD_DATA_DIR"]
                      elsif ENV["DATA_DIR"]
                        Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
                      else
                        '/data/asap2/fus'
                      end
    
    upload_dir = Pathname.new(upload_base_dir) + id.to_s
    upload_dir.join(upload_file_name)
  end
  
  # Check if upload is complete
  def complete?
    return false unless file_path && File.exist?(file_path)
    File.size(file_path) == upload_file_size
  end
  
  # Get current uploaded size
  def current_size
    return 0 unless file_path && File.exist?(file_path)
    File.size(file_path)
  end
  
  # Check if we can resume this upload
  def resumable?
    return false unless status == 'uploading' && file_path && File.exist?(file_path) && !complete?
    return false unless upload_file_size && upload_file_size > 0
    
    current_size = File.size(file_path)
    # Validate that current size is reasonable (not larger than expected)
    current_size >= 0 && current_size <= upload_file_size
  end
end

