require 'digest'

class ProjectBroadcastJob < ApplicationJob
  queue_as :default
  include Rails.application.routes.url_helpers

  def perform(project_id, step_id)
    project = Project.find(project_id)
    h_data = get_results(project, step_id)
    
    # Determine stage based on step_id - parsing step means we're in creation/parsing stage
    parsing_step = Step.where(name: 'parsing').first
    stage = (parsing_step && step_id == parsing_step.id) ? 'creation' : 'normal'
    
    # Aggregate run counts across all project steps for header display
    run_totals = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
    json_data = project.nber_runs_json.is_a?(String) ? JSON.parse(project.nber_runs_json) : project.nber_runs_json
    json_data ||= {}
    json_data.each do |sid, count|
      k = sid.to_i
      run_totals[k] = count.to_i if run_totals.key?(k)
    end

    h_data.merge!({
      project_id: project.id,
      step_id: step_id,
      new_status: project.status_id,
      # Include a monotonic-ish marker so repeated lifecycle transitions
      # on the same project/step are not dropped as "duplicates".
      project_updated_at: project.updated_at&.to_f,
      stage: stage,
      cell_count: project.cell_count,
      gene_count: project.gene_count,
      project_run_totals: {
        pending: run_totals[1],
        running: run_totals[2],
        success: run_totals[3],
        failed: run_totals[4]
      }
    })
    
    # Always include parsing status information (useful for summary page)
    h_data.merge!(get_parsing_status(project, step_id))
    
    # Add creation status information if in creation stage
    if stage == 'creation'
      h_data.merge!(get_creation_status(project, step_id))
    end
    
    if should_broadcast_payload?(project.id, step_id, h_data)
      ActionCable.server.broadcast "project_#{project.id}", h_data
    else
      Rails.logger.debug("[ProjectBroadcastJob] Skip duplicate broadcast for project=#{project.id} step=#{step_id}")
    end
  end

  private

  def should_broadcast_payload?(project_id, step_id, payload)
    key = "project_broadcast_signature:#{project_id}:#{step_id}"
    signature = Digest::SHA256.hexdigest(JSON.generate(payload.as_json))
    previous_signature = Rails.cache.read(key)
    return false if previous_signature == signature

    Rails.cache.write(key, signature, expires_in: 12.hours)
    true
  end

  def get_results(project, step_id)
    step = Step.find(step_id)
    h_status = {}
    Status.all.map{|s| h_status[s.id]=s}
#    summary_step = Step.where(:version_id => project.version_id, :name => 'summary').first
    asap_docker_image = Basic.get_asap_docker(project.version)
    summary_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'summary').first

    step_header_callback =
      if respond_to?(:get_step_header_project_path)
        get_step_header_project_path(project, :nolayout => 1, :step_id => step_id)
      end

    h_res = {
      :step_name => step.name,
      :h_nber_analyses => {},
      #      :h_statuses_json => h_status.to_json, 
      #      :summary_step_id => Step.find_by_name("summary").id,
      :url_base_callback => get_step_project_path(project, :nolayout => 1, :step_id => step_id),
      :url_step_header_callback => step_header_callback,
      :url_dim_reduction_callback => get_step_project_path(project, :nolayout => 1, :step_id => step_id, :partial => 'dim_reduction_form'),
      :summary_step_id => summary_step&.id
    }

   # parsing_status = nil
   # h_nber_analyses = nil

    js_cmds = []
    if step.name == 'parsing'
      # Use Run object to get parsing status (Job object is no longer used)
      parsing_run = Run.where(:project_id => project.id, :step_id => step_id).first
      h_res[:parsing_status_id] = parsing_run.status_id if parsing_run
    else ## update the nbers
      project_step = ProjectStep.find_by(project_id: project.id, step_id: step_id)
      if project_step&.nber_runs_json.present?
        json_counts = project_step.nber_runs_json.is_a?(String) ? JSON.parse(project_step.nber_runs_json) : project_step.nber_runs_json
        [1, 2, 3, 4, 5].each do |status_id|
          h_res[:h_nber_analyses][status_id] = json_counts[status_id.to_s].to_i
        end
      else
        [1, 2, 3, 4, 5].each do |status_id|
          tmp_nber = Run.where(:project_id => project.id, :step_id => step_id, :status_id => status_id).count
          h_res[:h_nber_analyses][status_id] = tmp_nber
        end
      end
    end

    #    h_nber_analyses = {}
    #    step_names = ['filtering', 'normalization', 'imputation', 'visualization', 'clustering, ''de', 'gene_enrichment']
    #    steps = Step.where(:name => step_names).all.each do |step|
    #      obj = step.obj_name.classify.constantize
    #      [1, 2, 3, 4, 5].each do |status_id|
    #      obj.where(:status_id => status_id).count()
    #    end
 
    ## check if need to get step
    
#   return js_cmds.join "\n"
    return h_res
  end

  def get_parsing_status(project, current_step_id = nil)
    status_info = {
      parsing_status: 'success',
      parsing_complete: true
    }
    
    # Resolve the parsing step for this project/version context.
    # Prefer the currently broadcasted step when it is parsing, otherwise find
    # the parsing step tied to the project's ASAP docker image.
    parsing_step = Step.find_by(id: current_step_id)
    unless parsing_step&.name == 'parsing'
      asap_docker_image = Basic.get_asap_docker(project.version)
      parsing_step = if asap_docker_image
                       Step.where(docker_image_id: asap_docker_image.id, name: 'parsing').first
                     else
                       Step.where(name: 'parsing').order(:id).last
                     end
    end

    # Check parsing step status
    if parsing_step
      project_step = ProjectStep.find_by(project_id: project.id, step_id: parsing_step.id)
      if project_step
        status_info[:parsing_status] = case project_step.status_id
        when 1
          'waiting'
        when 2
          'running'
        when 3
          'success'
        when 4
          'failed'
        else
          'success'
        end
        status_info[:parsing_complete] = (project_step.status_id == 3)
      end
    end
    
    status_info
  end

  def get_creation_status(project, step_id)
    status_info = {
      project_created: true,
      project_key: project.key,
      metadata_status: 'waiting',
      metadata_complete: false,
      all_complete: false,
      redirect_url: nil
    }
    
    # Get parsing status from dedicated method
    parsing_status_info = get_parsing_status(project)
    status_info.merge!(parsing_status_info)
    
    # Check metadata status
    # Metadata copying happens after parsing completes
    # We check if parsing is complete to determine metadata status
    if status_info[:parsing_complete]
      # If parsing is complete, check if we're still copying metadata
      # This is determined by checking if there's metadata to copy and if it's been copied
      # For now, we'll mark as complete when parsing is done
      # The parse.rake task will broadcast 'running' status when metadata copying starts
      # and 'complete' when it finishes
      status_info[:metadata_status] = 'complete'
      status_info[:metadata_complete] = true
    elsif status_info[:parsing_status] == 'running'
      status_info[:metadata_status] = 'waiting'
    end
    
    # Check if project is fully ready
    if status_info[:parsing_complete] && status_info[:metadata_complete]
      status_info[:all_complete] = true
      status_info[:redirect_url] = Rails.application.routes.url_helpers.project_path(project)
    end
    
    status_info
  end

end
