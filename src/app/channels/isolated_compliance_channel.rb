class IsolatedComplianceChannel < ApplicationCable::Channel
  def subscribed
    task_id = params[:task_id].to_s
    # task_id is an unguessable UUID capability (same as the HTTP status endpoint).
    if task_id.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      stream_from "isolated_compliance_#{task_id}"
    else
      reject
    end
  end

  def unsubscribed
    # no-op
  end
end

