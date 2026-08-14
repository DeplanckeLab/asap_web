class ComplianceValidation < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :compliance_schema, optional: true

  scope :for_project, ->(project_id) { where(project_id: project_id).order(validated_at: :desc) }
  scope :latest_for_project, ->(project_id) { for_project(project_id).first }

  # Latest validation outcome per project for list views.
  # Returns { project_id => true/false }; missing keys mean not yet validated.
  def self.latest_passed_by_project_id(project_ids)
    ids = Array(project_ids).compact.uniq
    return {} if ids.empty?

    result = {}
    where(project_id: ids).order(validated_at: :desc).each do |cv|
      result[cv.project_id] ||= cv.passed
    end
    result
  end

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
