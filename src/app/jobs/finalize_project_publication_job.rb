# frozen_string_literal: true

# Continues publication after an export_h5ad run finishes (success or failure).
class FinalizeProjectPublicationJob < ApplicationJob
  queue_as :default

  def perform(project_id)
    project = Project.find_by(id: project_id)
    unless project
      Rails.logger.error("[FinalizeProjectPublicationJob] Project##{project_id} not found")
      return
    end

    unless project.publishing?
      Rails.logger.info(
        "[FinalizeProjectPublicationJob] skip project=#{project.key}: not being_published"
      )
      return
    end

    ProjectPublicationService.continue!(project, logger: Rails.logger)
  rescue StandardError => e
    Rails.logger.error(
      "[FinalizeProjectPublicationJob] project_id=#{project_id} #{e.class}: #{e.message}"
    )
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    project&.abort_publishing!(reason: "Publication failed: #{e.message}") if project&.publishing?
  end
end
