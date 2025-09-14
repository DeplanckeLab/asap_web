class Req < ApplicationRecord
  belongs_to :project
  belongs_to :step
  belongs_to :user, optional: true
  belongs_to :std_method, optional: true
  
  # Scopes
  scope :by_project, ->(project_id) { where(project_id: project_id) if project_id.present? }
  scope :by_step, ->(step_id) { where(step_id: step_id) if step_id.present? }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  
  # Instance methods
  def display_name
    "Req ##{num || id}"
  end
  
  def parsed_attrs
    return {} unless attrs_json.present?
    JSON.parse(attrs_json) rescue {}
  end
  
  def has_error?
    error.present?
  end
end
