# frozen_string_literal: true

class ExternalCatalogCandidatesController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[index show create_project], raise: false
  before_action :authenticate_user!, only: %i[destroy]
  before_action :authorize_admin, only: %i[destroy]
  before_action :ensure_synced_reference_data_writable!, only: %i[destroy]
  before_action :set_candidate, only: %i[show create_project destroy]

  PER_PAGE = 25
  # Same technical owner as projects#create for guest sandboxes.
  GUEST_SANDBOX_USER_ID = 1

  def index
    @source = params[:source].to_s.presence
    @project_type = params[:project_type].to_s.presence
    @in_asap = params[:in_asap].to_s.presence
    @q = params[:q].to_s.strip.presence
    @page = [params[:page].to_i, 1].max
    @per_page = PER_PAGE

    scope = ExternalCatalogCandidate.current
    scope = scope.for_source(@source) if @source.present?
    scope = scope.for_project_type(@project_type) if @project_type.present?
    scope = scope.search_q(@q) if @q.present?
    scope = filter_in_asap(scope, @in_asap)

    @total_count = scope.count
    @candidates = scope.ordered_for_catalog
                       .offset((@page - 1) * @per_page)
                       .limit(@per_page)
                       .to_a

    @asap_projects_by_candidate_id = preload_asap_projects(@candidates)
  end

  def show
    if @candidate.obsolete?
      redirect_to external_catalog_candidates_path, alert: 'This candidate is obsolete and no longer listed.'
      return
    end

    if guest_import_challenge_requested?
      session[:pending_external_catalog_import_id] = @candidate.id
      @session_cookie_challenge_context = :catalog_import
      render_session_cookie_challenge(request.remote_ip.to_s)
      return
    end

    @asap_projects = @candidate.asap_projects.order(id: :desc).select { |project| readable?(project) }
    @auto_start_guest_import =
      !user_signed_in? &&
      session_unarchive_cleared? &&
      session[:pending_external_catalog_import_id].to_i == @candidate.id
    session.delete(:pending_external_catalog_import_id) if @auto_start_guest_import
  end

  def create_project
    accessible = accessible_asap_projects_for(@candidate)
    unless @candidate.can_create_project?(accessible_asap_projects: accessible)
      redirect_back(
        fallback_location: external_catalog_candidate_path(@candidate),
        alert: create_blocked_message(accessible)
      )
      return
    end

    if user_signed_in?
      start_signed_in_import!
    else
      start_guest_import!
    end
  end

  def destroy
    unless @candidate.can_mark_obsolete?
      redirect_back(
        fallback_location: external_catalog_candidate_path(@candidate),
        alert: 'This candidate is already obsolete.'
      )
      return
    end

    @candidate.mark_obsolete!
    redirect_to external_catalog_candidates_path,
                notice: 'Candidate marked obsolete. Sync to production to apply there.'
  end

  private

  def set_candidate
    @candidate = ExternalCatalogCandidate.find(params[:id])
  end

  def guest_import_challenge_requested?
    return false if user_signed_in?
    return false unless ActiveModel::Type::Boolean.new.cast(params[:verify_session])
    return false unless SessionCookieGate.enabled?
    return false if session_unarchive_cleared?

    true
  end

  def start_signed_in_import!
    @candidate.update!(
      import_status: 'importing',
      import_error: nil,
      import_user_id: current_user.id
    )

    ExternalCatalogImportCandidateJob.perform_later(@candidate.id, current_user.id)

    redirect_to external_catalog_candidate_path(@candidate),
                notice: 'Import started. Refresh this page to see progress.'
  end

  def start_guest_import!
    if SessionCookieGate.enabled? && !session_unarchive_cleared?
      session[:pending_external_catalog_import_id] = @candidate.id
      redirect_to external_catalog_candidate_path(@candidate, verify_session: 1)
      return
    end

    session[:sandbox] ||= create_sandbox_key
    rate = ExternalCatalog::ImportRateLimit.allow_guest_start!(
      ip: request.remote_ip.to_s,
      session_key: session[:sandbox]
    )
    unless rate.allowed?
      redirect_to external_catalog_candidate_path(@candidate), alert: rate.reason
      return
    end

    guest_user = User.find_by(id: GUEST_SANDBOX_USER_ID)
    unless guest_user
      ExternalCatalog::ImportRateLimit.release_inflight!(session_key: session[:sandbox])
      redirect_to external_catalog_candidate_path(@candidate),
                  alert: 'Guest import is temporarily unavailable.'
      return
    end

    @candidate.update!(
      import_status: 'importing',
      import_error: nil,
      import_user_id: guest_user.id
    )

    ExternalCatalogImportCandidateJob.perform_later(
      @candidate.id,
      guest_user.id,
      sandbox_key: session[:sandbox]
    )

    redirect_to external_catalog_candidate_path(@candidate),
                notice: 'Import started into your sandbox project. Refresh this page to see progress.'
  end

  def create_blocked_message(accessible = nil)
    accessible ||= accessible_asap_projects_for(@candidate)
    if @candidate.obsolete?
      'This candidate is obsolete and no longer listed.'
    elsif @candidate.importing? && @candidate.import_job_in_flight?
      'Import already in progress for this candidate.'
    elsif accessible.any?
      'An ASAP project you can access already exists for this dataset.'
    else
      'Cannot create a project for this candidate.'
    end
  end

  def accessible_asap_projects_for(candidate)
    candidate.asap_projects.select { |project| readable?(project) }
  end

  def filter_in_asap(scope, flag)
    case flag.to_s
    when 'yes'
      scope.where(id: asap_candidate_ids)
    when 'no'
      scope.where.not(id: asap_candidate_ids)
    else
      scope
    end
  end

  def asap_candidate_ids
    ExternalCatalogCandidate
      .joins(
        "INNER JOIN providers ON providers.tag = external_catalog_candidates.provider_tag
         INNER JOIN provider_projects ON provider_projects.provider_id = providers.id
           AND provider_projects.key = external_catalog_candidates.external_id
         INNER JOIN projects_provider_projects
           ON projects_provider_projects.provider_project_id = provider_projects.id
         INNER JOIN projects ON projects.id = projects_provider_projects.project_id"
      )
      .where('projects.being_deleted IS NULL OR projects.being_deleted = ?', false)
      .distinct
      .pluck(:id)
  end

  def preload_asap_projects(candidates)
    return {} if candidates.empty?

    by_key = candidates.group_by { |c| [c.provider_tag, c.external_id.to_s] }
    tags = candidates.map(&:provider_tag).uniq
    keys = candidates.map { |c| c.external_id.to_s }.uniq

    providers = Provider.where(tag: tags).index_by(&:tag)
    provider_ids = providers.values.map(&:id)
    pps = ProviderProject.where(provider_id: provider_ids, key: keys).includes(:projects, :provider)

    result = Hash.new { |h, k| h[k] = [] }
    pps.each do |pp|
      tag = pp.provider&.tag
      next if tag.blank?

      matching = by_key[[tag, pp.key.to_s]] || []
      projects = pp.projects.select { |p| !p.being_deleted }
      matching.each do |candidate|
        result[candidate.id] = projects.select { |project| readable?(project) }
      end
    end
    result
  end
end
