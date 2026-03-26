class Fu < ApplicationRecord
  # Model for tracking file uploads with resumable capability
  # Used to store temporary upload information before project creation
  
  belongs_to :project, optional: true
  belongs_to :user, optional: true
  
  validates :upload_file_name, presence: true
  # project_key can be nil until project is created
  
  def self.global_upload_root
    if ENV["UPLOAD_DATA_DIR"]
      ENV["UPLOAD_DATA_DIR"]
    elsif ENV["DATA_DIR"]
      Pathname.new(ENV["DATA_DIR"]).join('fus').to_s
    else
      '/data/asap2/fus'
    end
  end

  def global_upload_dir
    Pathname.new(self.class.global_upload_root) + id.to_s
  end

  def project_upload_root
    return nil unless project_id.present?

    project_record = project || Project.find_by(id: project_id)
    return nil unless project_record && project_record.user_id.present? && project_record.key.present?

    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    Pathname.new(user_data_dir) + project_record.user_id.to_s + project_record.key + 'fus'
  end

  # Use global fus before attachment, project-local fus after project exists.
  def upload_dir
    root = project_upload_root || Pathname.new(self.class.global_upload_root)
    root + id.to_s
  end

  # Get the file path for this upload.
  def file_path
    return nil unless id && upload_file_name

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

