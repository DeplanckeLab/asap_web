class ProjectChannel < ApplicationCable::Channel
  def subscribed
    project_id = params[:project_id]
    if project_id.present?
      stream_from "project_#{project_id}"
    else
      reject
    end
  end

  def unsubscribed
    # Cleanup is handled automatically by ActionCable streams
  end
end
