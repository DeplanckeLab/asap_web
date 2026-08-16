# frozen_string_literal: true

# Orchestrates async project publication:
# start (being_published) -> ensure H5AD exports -> validate H5ADs -> finalize (public).
class ProjectPublicationService
  class Error < StandardError; end

  def self.start!(project, user_id:, logger: Rails.logger)
    new(project, user_id: user_id, logger: logger).start!
  end

  def self.continue!(project, logger: Rails.logger)
    new(project, user_id: project.user_id, logger: logger).continue!
  end

  def self.cancel!(project, logger: Rails.logger)
    new(project, user_id: project.user_id, logger: logger).cancel!
  end

  def initialize(project, user_id:, logger: Rails.logger)
    @project = project
    @user_id = user_id
    @logger = logger
  end

  def start!
    raise Error, 'Project is already public' if @project.public?
    raise Error, 'Publication is already in progress' if @project.publishing?
    raise Error, 'Sandbox projects cannot be published' if @project.sandbox?

    can_publish, reason = @project.can_be_public?
    raise Error, reason if !can_publish

    if @project.input_content_sha256.blank?
      sha = InputFileSha256.ensure_for_project!(@project)
      @project.update!(input_content_sha256: sha) if sha.present?
    end

    @project.start_publishing!
    @logger.info("[ProjectPublicationService] start project=#{@project.key}")

    results = Basic.ensure_h5ad_exports_for_project(@logger, @project, @user_id)
    if results.empty?
      abort_and_raise!('No matrix loom files found to export for publication')
    end

    continue!
  end

  # Re-evaluate export status / H5AD validation for a project that is being_published.
  def continue!
    @project.reload
    return { status: 'noop' } unless @project.publishing?
    return { status: 'noop' } if @project.public?

    loom_rels = Basic.project_matrix_loom_rels(@project)
    if loom_rels.empty?
      @project.abort_publishing!(reason: 'No matrix loom files found to export for publication')
      return { status: 'aborted', error: @project.publication_error }
    end

    statuses = loom_rels.map do |loom_rel|
      run = Basic.latest_h5ad_export_run(@project, loom_rel)
      status = Basic.h5ad_export_status(@project, loom_rel, run: run)
      { loom_rel: loom_rel, run: run, h5ad_status: status }
    end

    if statuses.any? { |s| %w[pending running].include?(s[:h5ad_status]) }
      @logger.info(
        "[ProjectPublicationService] waiting for exports project=#{@project.key} " \
        "statuses=#{statuses.map { |s| "#{s[:loom_rel]}=#{s[:h5ad_status]}" }.join(',')}"
      )
      return { status: 'waiting', looms: statuses }
    end

    failed = statuses.select { |s| %w[failed missing stale].include?(s[:h5ad_status]) }
    if failed.any?
      detail = failed.map { |s| "#{s[:loom_rel]}:#{s[:h5ad_status]}" }.join(', ')
      reason = "H5AD export incomplete for publication (#{detail})"
      @project.abort_publishing!(reason: reason)
      @logger.warn("[ProjectPublicationService] abort project=#{@project.key} #{reason}")
      return { status: 'aborted', error: reason }
    end

    validation_error = validate_all_h5ads!(loom_rels)
    if validation_error
      @project.abort_publishing!(reason: validation_error)
      @logger.warn("[ProjectPublicationService] abort project=#{@project.key} #{validation_error}")
      return { status: 'aborted', error: validation_error }
    end

    @project.finalize_publication!
    ExternalCatalogCandidate.sync_catalog_links_for_public_project!(@project)
    @logger.info(
      "[ProjectPublicationService] finalized project=#{@project.key} public_id=#{@project.public_id}"
    )
    { status: 'finalized', public_id: @project.public_id }
  end

  def cancel!
    raise Error, 'Project is not being published' unless @project.publishing?

    @project.cancel_publishing!
    @logger.info("[ProjectPublicationService] cancelled project=#{@project.key}")
    { status: 'cancelled' }
  end

  private

  def abort_and_raise!(reason)
    @project.abort_publishing!(reason: reason)
    raise Error, reason
  end

  def validate_all_h5ads!(loom_rels)
    project_dir = Basic.project_user_dir(@project)
    loom_rels.each do |loom_rel|
      h5ad_abs = project_dir + Basic.h5ad_rel_path_for_loom(loom_rel)
      unless h5ad_abs.exist? && h5ad_abs.size.positive?
        return "H5AD not found for validation: #{Basic.h5ad_rel_path_for_loom(loom_rel)}"
      end

      @logger.info(
        "[ProjectPublicationService] scFAIR h5ad validation project=#{@project.key} path=#{h5ad_abs}"
      )
      result = ScfairH5adValidatorService.new(h5ad_abs.to_s, logger: @logger).validate
      next if result.valid?

      sample = Array(result.errors).first(5).map { |e| format_validation_issue(e) }.join('; ')
      return (
        "scFAIR H5AD validation failed for #{Basic.h5ad_rel_path_for_loom(loom_rel)} " \
        "(#{Array(result.errors).size} error(s)): #{sample}"
      )
    end
    nil
  end

  def format_validation_issue(issue)
    case issue
    when Hash
      field = issue[:field] || issue['field']
      message = issue[:message] || issue['message'] || issue.inspect
      field.present? ? "#{field}: #{message}" : message.to_s
    else
      issue.to_s
    end
  end
end
