# frozen_string_literal: true

# Imports one ExternalCatalogCandidate into ASAP via ProjectImporter.
class ExternalCatalogImportCandidateJob < ApplicationJob
  queue_as :default

  def perform(candidate_id, user_id, version_id: nil, skip_archive: true)
    candidate = ExternalCatalogCandidate.find_by(id: candidate_id)
    unless candidate
      Rails.logger.error("[ExternalCatalogImportCandidateJob] candidate=#{candidate_id} not found")
      return
    end

    user = User.find_by(id: user_id)
    unless user
      candidate.update!(import_status: 'failed', import_error: "User #{user_id} not found")
      return
    end

    version =
      if version_id.present?
        Version.find_by(id: version_id)
      else
        Version.activated.where('id > 3').order(id: :desc).first
      end
    unless version
      candidate.update!(import_status: 'failed', import_error: 'No activated Version (id > 3) found')
      return
    end

    candidate.update!(
      import_status: 'importing',
      import_error: nil,
      import_user_id: user.id
    )

    if candidate.already_in_asap?
      project = candidate.asap_projects.order(id: :desc).first
      candidate.update!(
        import_status: 'idle',
        import_error: nil,
        import_project_id: project&.id
      )
      Rails.logger.info(
        "[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} already in ASAP " \
        "project=#{project&.key}"
      )
      return
    end

    importer = ExternalCatalog::ProjectImporter.new(
      user: user,
      version: version,
      dry_run: false,
      skip_archive: skip_archive,
      strict: true,
      archiver: nil
    )

    result = importer.import_one(candidate.to_entry)
    if result == :dry_run
      candidate.update!(import_status: 'failed', import_error: 'dry_run unexpected')
      return
    end

    unless result.is_a?(Project)
      candidate.update!(import_status: 'failed', import_error: 'Import returned no project')
      return
    end

    candidate.update!(
      import_status: 'idle',
      import_error: nil,
      import_project_id: result.id
    )
    Rails.logger.info(
      "[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} done " \
      "project=#{result.id} key=#{result.key}"
    )
  rescue ExternalCatalog::ProjectImporter::SkipEntry => e
    project = candidate&.asap_projects&.order(id: :desc)&.first
    if project
      candidate.update!(import_status: 'idle', import_error: nil, import_project_id: project.id)
    else
      candidate&.update!(import_status: 'failed', import_error: e.message.to_s.truncate(2000))
    end
    Rails.logger.warn("[ExternalCatalogImportCandidateJob] skip candidate=#{candidate_id}: #{e.message}")
  rescue StandardError => e
    Rails.logger.error(
      "[ExternalCatalogImportCandidateJob] fail candidate=#{candidate_id}: #{e.class} #{e.message}"
    )
    Rails.logger.error(e.backtrace.first(20).join("\n")) if e.backtrace
    candidate&.update!(import_status: 'failed', import_error: "#{e.class}: #{e.message}".truncate(2000))
  end
end
