class ProjectChannel < ApplicationCable::Channel
  def subscribed
    project_id = params[:project_id]
    if project_id.present?
      Rails.logger.info("[ProjectChannel] subscribed stream=project_#{project_id}")
      stream_from "project_#{project_id}"
      transmit_initial_snapshot(project_id)
    else
      Rails.logger.warn("[ProjectChannel] rejected missing project_id params=#{params.inspect}")
      reject
    end
  end

  def unsubscribed
    Rails.logger.info("[ProjectChannel] unsubscribed params=#{params.inspect}")
  end

  private

  def transmit_initial_snapshot(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    run_totals = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
    json_data = project.nber_runs_json.is_a?(String) ? JSON.parse(project.nber_runs_json) : project.nber_runs_json
    json_data ||= {}
    json_data.each do |sid, count|
      key = sid.to_i
      run_totals[key] = count.to_i if run_totals.key?(key)
    end

    parsing_status = 'success'
    parsing_complete = true
    parsing_step_id = nil

    asap_docker_image = Basic.get_asap_docker(project.version)
    parsing_step = if asap_docker_image
                     Step.where(docker_image_id: asap_docker_image.id, name: 'parsing').first
                   else
                     Step.where(name: 'parsing').order(:id).last
                   end

    if parsing_step
      parsing_step_id = parsing_step.id
      project_step = ProjectStep.find_by(project_id: project.id, step_id: parsing_step.id)
      if project_step
        parsing_status = project_step.status&.name.to_s.downcase
        parsing_status = 'success' unless %w[pending running success failed].include?(parsing_status)
        parsing_complete = (parsing_status == 'success')
      end
    end

    payload = {
      project_id: project.id,
      step_id: parsing_step_id,
      step_name: 'parsing',
      parsing_status: parsing_status,
      parsing_complete: parsing_complete,
      project_run_totals: {
        pending: run_totals[1],
        running: run_totals[2],
        success: run_totals[3],
        failed: run_totals[4]
      },
      project_updated_at: project.updated_at&.to_f,
      initial_snapshot: true
    }

    # Only the unarchive pending overlay subscribes with unarchive_watch. Including
    # the current unarchive state in its snapshot lets the overlay recover when the
    # job completed before the browser was subscribed (missed one-shot broadcast).
    # Deliberately no :project_unarchived key: header_run_status_controller reloads
    # on it, which would loop on every subscribe.
    # Computed only on demand because it can shell out to `du` on the project dir.
    payload[:unarchive_status] = project.unarchive_client_state if params[:unarchive_watch]

    transmit(payload)
  rescue => e
    Rails.logger.warn("[ProjectChannel] failed to transmit initial snapshot for project #{project_id}: #{e.class} - #{e.message}")
  end
end
