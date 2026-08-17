# frozen_string_literal: true

class ProjectCloneJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(dest_project_id) { "clone-project-#{dest_project_id}" }, duration: 12.hours

  def perform(dest_project_id)
    dest = Project.find_by(id: dest_project_id)
    unless dest
      Rails.logger.error("[ProjectCloneJob] Project##{dest_project_id} not found")
      return
    end
    unless dest.being_cloned
      Rails.logger.info("[ProjectCloneJob] Project##{dest.id} is not being cloned, skipping")
      return
    end

    source = dest.cloned_project
    unless source
      Rails.logger.error("[ProjectCloneJob] Project##{dest.id} has no clone source, destroying incomplete clone")
      dest.destroy
      return
    end

    broadcast(dest, status: 'copying')
    service = ProjectCloneService.new(source, user: dest.user, session: {}, admin: false)
    service.complete_existing!(dest)
    dest.reload
    broadcast(dest, status: 'completed')
  rescue StandardError => e
    Rails.logger.error("[ProjectCloneJob] Project##{dest_project_id} failed: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    if dest
      broadcast(dest, status: 'failed', error: e.message)
      service ||= ProjectCloneService.new(source, user: dest.user, session: {}, admin: false) if source
      if service
        service.instance_variable_set(:@new_project, dest)
        service.send(:cleanup_failed_clone)
      else
        dest.destroy
      end
    end
  end

  private

  def broadcast(project, payload)
    ActionCable.server.broadcast(
      "project_#{project.id}",
      payload.merge(project_id: project.id, clone_status: payload[:status])
    )
  end
end
