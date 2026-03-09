class ProjectUnarchiveJob < ApplicationJob
  queue_as :default

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    ok = Basic.unarchive(project.key, progress_callback: ->(stage) { broadcast_unarchive_status(project, stage) })
    if ok
      broadcast_unarchive_status(project, 'completed', project_unarchived: true)
    else
      Rails.logger.error("[ProjectUnarchiveJob] Unarchive failed for project #{project.id} (#{project.key})")
      project.update(archive_status_id: 3) if project.archive_status_id == 4
      broadcast_unarchive_status(project, 'failed', project_unarchived: false)
    end
  rescue StandardError => e
    Rails.logger.error("[ProjectUnarchiveJob] Error for project #{project_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    project.update(archive_status_id: 3) if project && project.archive_status_id == 4
    if project
      broadcast_unarchive_status(project, 'failed', project_unarchived: false)
    end
  end

  private

  def broadcast_unarchive_status(project, status, project_unarchived: nil)
    payload = {
      project_id: project.id,
      unarchive_status: status
    }
    payload[:project_unarchived] = project_unarchived unless project_unarchived.nil?
    ActionCable.server.broadcast("project_#{project.id}", payload)
  end
end
