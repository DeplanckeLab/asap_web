class IsolatedComplianceChannel < ApplicationCable::Channel
  def subscribed
    task_id = params[:task_id].to_s
    if task_id.present?
      stream_from "isolated_compliance_#{task_id}"
    else
      reject
    end
  end

  def unsubscribed
    # no-op
  end
end

