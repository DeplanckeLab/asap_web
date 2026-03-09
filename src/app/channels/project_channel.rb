class ProjectChannel < ApplicationCable::Channel
  def subscribed
    project_id = params[:project_id]
    if project_id.present?
      Rails.logger.info("[ProjectChannel] subscribed stream=project_#{project_id}")
      stream_from "project_#{project_id}"
    else
      Rails.logger.warn("[ProjectChannel] rejected missing project_id params=#{params.inspect}")
      reject
    end
  end

  def unsubscribed
    Rails.logger.info("[ProjectChannel] unsubscribed params=#{params.inspect}")
  end
end
