# frozen_string_literal: true

# Imports one ExternalCatalogCandidate into ASAP via ProjectImporter.
class ExternalCatalogImportCandidateJob < ApplicationJob
  queue_as :default

  # project_id: the import paused for the user (NeedsUserChoice), who created this project in the project form
  # from the kept download; finish the import on it (catalog metadata, analysis pipeline, exports...).
  def perform(candidate_id, user_id, version_id: nil, skip_archive: true, sandbox_key: nil, project_id: nil)
    sandbox_key = sandbox_key.to_s.strip.presence
    guest_import = sandbox_key.present?

    candidate = ExternalCatalogCandidate.find_by(id: candidate_id)
    unless candidate
      Rails.logger.error("[ExternalCatalogImportCandidateJob] candidate=#{candidate_id} not found")
      return
    end

    user = User.find_by(id: user_id)
    unless user
      fail_import!(candidate, "User #{user_id} not found")
      return
    end

    # Cancelled while still queued (the guest started another sandbox project).
    return if cancelled!(candidate)

    version =
      if version_id.present?
        Version.find_by(id: version_id)
      else
        Version.activated.where('id > 3').order(id: :desc).first
      end
    unless version
      fail_import!(candidate, 'No activated Version (id > 3) found')
      return
    end

    form_project = project_id.present? ? Project.find_by(id: project_id) : nil
    if project_id.present? && (form_project.nil? || form_project.being_deleted)
      fail_import!(candidate, 'The project created in the form no longer exists.')
      return
    end

    candidate.update!(
      import_status: 'importing',
      import_error: nil,
      import_user_id: user.id,
      # The job marker tells the web UI this run can be declared dead once its job is gone (rake runs have none).
      import_resume_json: {
        ExternalCatalogCandidate::IMPORT_JOB_MARKER => true,
        'sandbox_key_digest' => ExternalCatalogCandidate.sandbox_key_digest(sandbox_key),
        'started_at' => Time.current.iso8601(3)
      }.to_json
    )
    ExternalCatalog::ImportProgress.report(candidate.id, step: 'queued') unless form_project

    importer = nil

    unless guest_import || form_project
      accessible = candidate.asap_projects_accessible_to(user)
      if accessible.exists?
        project = accessible.order(id: :desc).first
        candidate.update!(import_status: 'idle', import_error: nil)
        candidate.link_matched_project!(project, link_kind: 'provider_match') if project
        ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(project: project) if project
        ExternalCatalog::ImportProgress.report(
          candidate.id,
          step: 'opening',
          project_key: project&.key
        )
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
      sandbox_key: sandbox_key,
      progress_candidate_id: candidate.id,
      ask_user_choice: true
    )

    project_ready = false
    on_project_ready = lambda { |project, outcome|
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
    result =
      if form_project
        importer.complete_form_import(candidate.to_entry, form_project, on_project_ready: on_project_ready)
      else
        importer.import_one(candidate.to_entry, on_project_ready: on_project_ready)
      end
    if result == :dry_run
      fail_import!(candidate, 'dry_run unexpected')
      return
    end

    unless result.is_a?(Project)
      fail_import!(candidate, 'Import returned no project')
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
  rescue ExternalCatalog::ProjectImporter::NeedsUserChoice => e
    return if cancelled!(candidate, discard_fu: e.fu)

    # Not a failure: keep the download; whoever started the import continues in the project form (species,
    # matrix, text parsing parameters...), which creates the project, then a run with project_id finishes it.
    candidate.await_form_choice!(
      fu: e.fu,
      reason: e.reason,
      version_id: version.id,
      skip_archive: skip_archive,
      sandbox_key: sandbox_key,
      organism_id: e.organism_id,
      suggested_organism_id: e.suggested_organism_id,
      suggestion: e.suggestion,
      tax_id: e.tax_id,
      organism_label: e.organism_label
    )
    ExternalCatalog::ImportProgress.report(candidate.id, step: 'choose_in_form')
    Rails.logger.info(
      "[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} waiting for the project form " \
      "(#{e.reason}): #{e.message} fu=#{e.fu&.id.inspect} suggested_organism=#{e.suggested_organism_id.inspect}"
    )
  rescue ExternalCatalog::ProjectImporter::SkipEntry => e
    return if cancelled!(candidate)

    project = candidate&.asap_projects&.order(id: :desc)&.first
    if project && !guest_import
      candidate.update!(import_status: 'idle', import_error: nil)
      candidate.link_matched_project!(project, link_kind: 'provider_match')
      ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(project: project)
      ExternalCatalog::ImportProgress.report(
        candidate.id,
        step: 'opening',
        project_key: project.key
      )
    else
      fail_import!(candidate, e.message.to_s.truncate(2000))
    end
    Rails.logger.warn("[ExternalCatalogImportCandidateJob] skip candidate=#{candidate_id}: #{e.message}")
  rescue StandardError => e
    # Cancelled (or broken by the guest replacing the sandbox mid-import): not a failure.
    return if cancelled!(candidate)

    Rails.logger.error(
      "[ExternalCatalogImportCandidateJob] fail candidate=#{candidate_id}: #{e.class} #{e.message}"
    )
    Rails.logger.error(e.backtrace.first(20).join("\n")) if e.backtrace
    fail_import!(candidate, "#{e.class}: #{e.message}".truncate(2000))
    failed_project = candidate&.import_project.presence || candidate&.asap_projects&.order(id: :desc)&.first
    ExternalCatalog::ImportSuccessRegistry.record_import_attempt!(project: failed_project, importer: importer) if failed_project
  ensure
    if sandbox_key.present?
      ExternalCatalog::ImportRateLimit.release_inflight!(session_key: sandbox_key, candidate_id: candidate_id)
    end
    clear_job_marker!(candidate_id)
  end

  private

  # Acknowledge a cancellation (ExternalCatalogCandidate#cancel_for_new_sandbox!): back to idle, no error shown.
  def cancelled!(candidate, discard_fu: nil)
    return false unless candidate && ExternalCatalog::ImportProgress.cancel_requested?(candidate.id)

    ExternalCatalogCandidate.discard_unused_download!(discard_fu.id, user_id: candidate.import_user_id) if discard_fu
    candidate.update!(import_status: 'idle', import_error: nil)
    ExternalCatalog::ImportProgress.clear(candidate.id)
    ExternalCatalog::ImportProgress.clear_cancel(candidate.id)
    Rails.logger.info("[ExternalCatalogImportCandidateJob] candidate=#{candidate.id} import cancelled")
    true
  end

  # Run over: drop the job marker (awaiting_matrix keeps its own resume state).
  def clear_job_marker!(candidate_id)
    candidate = ExternalCatalogCandidate.find_by(id: candidate_id)
    return if candidate.nil? || candidate.awaiting_matrix? || candidate.import_resume_json.blank?

    candidate.update_column(:import_resume_json, nil)
  rescue StandardError => e
    Rails.logger.warn("[ExternalCatalogImportCandidateJob] could not clear resume state candidate=#{candidate_id}: #{e.class} #{e.message}")
  end

  def fail_import!(candidate, message)
    return unless candidate

    candidate.update!(import_status: 'failed', import_error: message)
    ExternalCatalog::ImportProgress.report(
      candidate.id,
      step: 'failed',
      import_error: message,
      message: message
    )
  end
end
