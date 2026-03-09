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

    parsing_status = 'complete'
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
        parsing_status = case project_step.status_id
                         when 1 then 'waiting'
                         when 2 then 'running'
                         when 3 then 'complete'
                         when 4 then 'failed'
                         else 'complete'
                         end
        parsing_complete = (project_step.status_id == 3)
      end
    end

    payload = {
      project_id: project.id,
      step_id: parsing_step_id,
      step_name: 'parsing',
      parsing_status: parsing_status,
      parsing_complete: parsing_complete,
      project_run_totals: {
        waiting: run_totals[1],
        running: run_totals[2],
        completed: run_totals[3],
        failed: run_totals[4]
      },
      project_updated_at: project.updated_at&.to_f,
      initial_snapshot: true
    }

    transmit(payload)
  rescue => e
    Rails.logger.warn("[ProjectChannel] failed to transmit initial snapshot for project #{project_id}: #{e.class} - #{e.message}")
  end
end
