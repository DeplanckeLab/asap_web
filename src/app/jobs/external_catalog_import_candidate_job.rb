# frozen_string_literal: true

# Imports one ExternalCatalogCandidate into ASAP via ProjectImporter.
class ExternalCatalogImportCandidateJob < ApplicationJob
  queue_as :default

  def perform(candidate_id, user_id, version_id: nil, skip_archive: true, sandbox_key: nil)
    sandbox_key = sandbox_key.to_s.strip.presence
    guest_import = sandbox_key.present?

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

    importer = nil

    unless guest_import
      accessible = candidate.asap_projects_accessible_to(user)
      if accessible.exists?
        project = accessible.order(id: :desc).first
        candidate.update!(import_status: 'idle', import_error: nil)
        candidate.link_matched_project!(project, link_kind: 'provider_match') if project
        ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(project: project) if project
        Rails.logger.info(
          "[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} already accessible in ASAP " \
          "project=#{project&.key} user=#{user.id} (matched, import_project_id unchanged)"
        )
        return
      end
    end

    importer = ExternalCatalog::ProjectImporter.new(
      user: user,
      version: version,
      dry_run: false,
      skip_archive: skip_archive,
      skip_publish: guest_import,
      strict: true,
      allow_scfair_warnings: ActiveModel::Type::Boolean.new.cast(
        ENV.fetch('ALLOW_SCFAIR_WARNINGS', '0')
      ),
      archiver: nil,
      sandbox: guest_import,
      sandbox_key: sandbox_key
    )

    project_ready = false
    result = importer.import_one(
      candidate.to_entry,
      on_project_ready: lambda { |project, outcome|
        project_ready = true
        if outcome == :created
          candidate.update!(import_project_id: project.id)
          candidate.link_matched_project!(project, link_kind: 'import')
        else
          candidate.link_matched_project!(project, link_kind: 'content_match')
        end
        Rails.logger.info(
          "[ExternalCatalogImportCandidateJob] project ready candidate=#{candidate.id} " \
          "outcome=#{outcome} project=#{project.id} key=#{project.key}"
        )
      }
    )
    if result == :dry_run
      candidate.update!(import_status: 'failed', import_error: 'dry_run unexpected')
      return
    end

    unless result.is_a?(Project)
      candidate.update!(import_status: 'failed', import_error: 'Import returned no project')
      return
    end

    created = importer.last_import_outcome == :created
    attrs = { import_status: 'idle', import_error: nil }
    attrs[:import_project_id] = result.id if created
    candidate.update!(attrs)
    unless project_ready
      candidate.link_matched_project!(
        result,
        link_kind: created ? 'import' : 'content_match'
      )
    end
    ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(project: result, importer: importer)
    Rails.logger.info(
      "[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} " \
      "outcome=#{importer.last_import_outcome} project=#{result.id} key=#{result.key} " \
      "sandbox=#{guest_import} import_project_id=#{candidate.import_project_id}"
    )
  rescue ExternalCatalog::ProjectImporter::SkipEntry => e
    project = candidate&.asap_projects&.order(id: :desc)&.first
    if project && !guest_import
      candidate.update!(import_status: 'idle', import_error: nil)
      candidate.link_matched_project!(project, link_kind: 'provider_match')
      ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(project: project)
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
    failed_project = candidate&.import_project.presence || candidate&.asap_projects&.order(id: :desc)&.first
    ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(project: failed_project, importer: importer) if failed_project
  ensure
    ExternalCatalog::ImportRateLimit.release_inflight!(session_key: sandbox_key) if sandbox_key.present?
  end
end
