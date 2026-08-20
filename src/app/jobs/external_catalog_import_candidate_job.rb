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

    accessible = candidate.asap_projects_accessible_to(user)
    if accessible.exists?
      project = accessible.order(id: :desc).first
      candidate.update!(import_status: 'idle', import_error: nil)
      candidate.link_matched_project!(project, link_kind: 'provider_match') if project
      Rails.logger.info(
        "[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} already accessible in ASAP " \
        "project=#{project&.key} user=#{user.id} (matched, import_project_id unchanged)"
      )
      return
    end

    importer = ExternalCatalog::ProjectImporter.new(
      user: user,
      version: version,
      dry_run: false,
      skip_archive: skip_archive,
      strict: true,
      allow_scfair_warnings: ActiveModel::Type::Boolean.new.cast(
        ENV.fetch('ALLOW_SCFAIR_WARNINGS', '0')
      ),
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

    created = importer.last_import_outcome == :created
    attrs = { import_status: 'idle', import_error: nil }
    attrs[:import_project_id] = result.id if created
    candidate.update!(attrs)
    candidate.link_matched_project!(
      result,
      link_kind: created ? 'import' : 'content_match'
    )
    Rails.logger.info(
      "[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} " \
      "outcome=#{importer.last_import_outcome} project=#{result.id} key=#{result.key} " \
      "import_project_id=#{candidate.import_project_id}"
    )
  rescue ExternalCatalog::ProjectImporter::SkipEntry => e
    project = candidate&.asap_projects&.order(id: :desc)&.first
    if project
      candidate.update!(import_status: 'idle', import_error: nil)
      candidate.link_matched_project!(project, link_kind: 'provider_match')
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
