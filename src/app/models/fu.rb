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
  # Pass +project+ when the Fu is shared across clones (same fu_id, different project dirs).
  def upload_dir(project: nil)
    root = if project
             project_scoped_upload_root(project)
           else
             project_upload_root || Pathname.new(self.class.global_upload_root)
           end
    root + id.to_s
  end

  # Get the file path for this upload.
  def file_path(project: nil)
    return nil unless id && upload_file_name

    upload_dir(project: project).join(upload_file_name)
  end

  def project_scoped_upload_root(project)
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join('storage', 'user_data').to_s
    Pathname.new(user_data_dir) + project.user_id.to_s + project.key + 'fus'
  end

  # Use the project-local fus path when the Fu row still points at another project
  # (typical for cloned projects that share fu_id with the source).
  def upload_dir_for_project(project)
    return upload_dir unless project

    if project_id.present? && project_id.to_i != project.id.to_i
      upload_dir(project: project)
    else
      upload_dir
    end
  end

  def self.resolve_for_project(project)
    return nil unless project

    if project.fu_id.present?
      fu = find_by(id: project.fu_id)
      return fu if fu
    end

    fu = where(project_id: project.id).order(id: :desc).first
    return fu if fu

    rehydrate_for_project(project)
  end

  def self.rehydrate_for_project(project)
    fus_root = project.data_dir + 'fus'
    return nil unless fus_root.directory?

    fu_id = if project.fu_id.present? && (fus_root + project.fu_id.to_s).directory?
              project.fu_id
            else
              Dir.children(fus_root.to_s)
                 .select { |name| name.match?(/\A\d+\z/) && (fus_root + name).directory? }
                 .map(&:to_i)
                 .max
            end
    return nil unless fu_id

    upload_dir = fus_root + fu_id.to_s
    upload_name = detect_upload_file_name(upload_dir)
    return nil unless upload_name

    upload_path = upload_dir + upload_name
    attrs = {
      project_id: project.id,
      project_key: project.key,
      user_id: project.user_id,
      upload_file_name: upload_name,
      upload_file_size: File.size(upload_path),
      status: 'completed'
    }

    fu = if project.fu_id.present? && project.fu_id.to_i == fu_id && !exists?(fu_id)
           create!(attrs.merge(id: fu_id))
         else
           create!(attrs)
         end

    project.update_column(:fu_id, fu.id) if project.fu_id != fu.id
    Rails.logger.info("[Fu] Rehydrated Fu##{fu.id} for project #{project.key} from #{upload_dir}")
    fu
  rescue StandardError => e
    Rails.logger.error("[Fu] Failed to rehydrate Fu for project #{project.key}: #{e.class} - #{e.message}")
    nil
  end

  PREPARSING_ARTIFACTS = %w[output.json output.err clipboard.txt].freeze

  def self.detect_upload_file_name(upload_dir)
    candidates = Dir.children(upload_dir.to_s).select do |name|
      path = upload_dir + name
      File.file?(path) && !PREPARSING_ARTIFACTS.include?(name)
    end
    candidates.max_by { |name| File.size(upload_dir + name) }
  end
  
  # Convert a standalone compliance-check Fu into a project-input Fu so the
  # already downloaded file can be attached to a new project without a second fetch.
  def adopt_as_project_input!
    project_input_type = UploadType.id_for('project_input')
    updates = {}
    updates[:upload_type] = project_input_type if project_input_type.present? && upload_type != project_input_type
    if status.in?(%w[validating validated validation_failed])
      updates[:status] = 'uploaded'
    end
    update!(updates) if updates.present?
    self
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

