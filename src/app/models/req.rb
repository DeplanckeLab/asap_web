class Req < ApplicationRecord
  belongs_to :project
  belongs_to :step
  belongs_to :std_method, optional: true
  belongs_to :user, optional: true
  has_many :runs, dependent: :destroy

  scope :by_project, ->(project_id) { where(project_id: project_id) if project_id.present? }
  scope :by_step, ->(step_id) { where(step_id: step_id) if step_id.present? }
  scope :by_status, ->(status) { where(status: status) if status.present? }

  def display_name
    "Req ##{num || id}"
  end

  def parsed_attrs
    return {} unless attrs_json.present?
    JSON.parse(attrs_json)
  rescue JSON::ParserError
    {}
  end

  def has_error?
    error.present?
  end

  # Legacy helper invoked by ReqsController#create_runs to kick off run execution.
  def set_runs(list_of_runs, list_of_h_p)
    project = self.project
    step = self.step

    list_of_runs.each_with_index do |(run, _attrs), idx|
      h_p = list_of_h_p[idx]
      h_res = Basic.set_run(Rails.logger, h_p)

      if h_res[:error]
        Basic.upd_run(project, run, { status_id: 4 }, true)
      elsif run.async == false
        Basic.exec_run(run)
    end
  end
  
    Basic.upd_project_step(project, step.id) if project && step
  end
end
