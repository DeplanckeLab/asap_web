class ComplianceChannel < ApplicationCable::Channel
  def subscribed
    project = Project.find_by(id: params[:project_id]) if params[:project_id].present?
    if project && readable?(project)
      stream_from "compliance_#{project.id}"
    else
      reject
    end
  end

  def unsubscribed
    # Cleanup is handled automatically by ActionCable streams
  end
end
