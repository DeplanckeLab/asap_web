class ComplianceValidation < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :compliance_schema, optional: true

  scope :for_project, ->(project_id) { where(project_id: project_id).order(validated_at: :desc) }
  scope :latest_for_project, ->(project_id) { for_project(project_id).first }

  # Convention: result files are stored as cxg_validation_result_<id>.json
  # in the project directory.
  def result_file_path
    return nil unless project&.key.present? && project&.user_id.present?
    File.join(
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      project.user_id.to_s,
      project.key,
      "cxg_validation_result_#{id}.json"
    )
  end

  def result_data
    path = result_file_path
    return nil unless path && File.exist?(path)
    JSON.parse(File.read(path)).with_indifferent_access
  rescue JSON::ParserError
    nil
  end
end
