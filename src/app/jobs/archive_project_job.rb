# frozen_string_literal: true

class ArchiveProjectJob < ApplicationJob
  queue_as :archive

  limits_concurrency to: 1, key: ->(project_id) { "archive-project-#{project_id}" }, duration: 12.hours

  def perform(project_id)
    project = Project.find_by(id: project_id)
    unless project
      Rails.logger.error("[ArchiveProjectJob] Project##{project_id} not found")
      return
    end

    result = ProjectS3Archive.archive!(project)
    Rails.logger.info("[ArchiveProjectJob] project=#{project.key} result=#{result}")
  end
end
