# frozen_string_literal: true

class ExternalCatalogCandidatesController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[index show create_project import_status], raise: false
  before_action :authenticate_user!, only: %i[destroy]
  before_action :authorize_admin, only: %i[destroy]
  before_action :ensure_synced_reference_data_writable!, only: %i[destroy]
  before_action :set_candidate, only: %i[show create_project destroy import_status]

  PER_PAGE = 25
  # Same technical owner as projects#create for guest sandboxes.
  GUEST_SANDBOX_USER_ID = 1

  def index
    @source = params[:source].to_s.presence
    @project_type = params[:project_type].to_s.presence
    @in_asap = params[:in_asap].to_s.presence
    @q = params[:q].to_s.strip.presence
    @n_obs_bounds = ExternalCatalogCandidate.n_obs_bounds
    @min_n_obs, @max_n_obs = parse_n_obs_range_params
    @page = [params[:page].to_i, 1].max
    @per_page = PER_PAGE

    scope = ExternalCatalogCandidate.current
    scope = scope.for_source(@source) if @source.present?
    scope = scope.for_project_type(@project_type) if @project_type.present?
    scope = scope.search_q(@q) if @q.present?
    scope = filter_in_asap(scope, @in_asap)
    scope = filter_n_obs(scope)

    @total_count = scope.count
    total_pages = [(@total_count.to_f / @per_page).ceil, 1].max
    @page = [@page, total_pages].min
    @candidates = scope.ordered_by_size
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
    @watch_import =
      ActiveModel::Type::Boolean.new.cast(params[:importing]) ||
      @auto_start_guest_import
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

  def import_status
    if @candidate.obsolete?
      render json: { import_status: 'failed', import_error: 'This candidate is obsolete.', project_url: nil }
      return
    end

    project = import_redirect_project
    project_url =
      if project
        project_path(project, view: 'analysis', **analysis_step_params(project))
      end

    error =
      if @candidate.failed?
        if admin? || !@candidate.scfair_validation_error?
          @candidate.import_error
        else
          'Import failed.'
        end
      end

    render json: {
      import_status: @candidate.import_status,
      import_error: error,
      project_url: project_url,
      project_key: project&.key
    }
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

    redirect_to external_catalog_candidate_path(@candidate, importing: 1),
                notice: 'Import started. Opening the project when parsing begins.'
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

    redirect_to external_catalog_candidate_path(@candidate, importing: 1),
                notice: 'Import started into your sandbox project. Opening the project when parsing begins.'
  end

  # Prefer the project created by this import (parsing started). While importing,
  # also accept a just-linked content match. When idle, any readable ASAP project.
  def import_redirect_project
    if @candidate.import_project_id.present?
      project = @candidate.import_project
      return project if project && !project.being_deleted && readable?(project)
    end

    matched = @candidate.external_catalog_candidate_projects
                        .includes(:project)
                        .order(id: :desc)
                        .filter_map(&:project)
                        .find { |project| project && !project.being_deleted && readable?(project) }
    return matched if matched

    return nil if @candidate.importing?

    accessible_asap_projects_for(@candidate).max_by(&:id)
  end

  def analysis_step_params(project)
    step = parsing_step_for_catalog_project(project)
    step ? { step_id: step.id } : {}
  end

  def parsing_step_for_catalog_project(project)
    return nil unless project&.version

    asap_docker_image = Basic.get_asap_docker(project.version)
    return nil unless asap_docker_image

    Step.find_by(
      docker_image_id: asap_docker_image.id,
      version_id: project.version_id,
      name: 'parsing'
    )
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

  def parse_n_obs_range_params
    return [nil, nil] unless @n_obs_bounds

    bound_min = @n_obs_bounds[:min]
    bound_max = @n_obs_bounds[:max]
    min_raw = params[:min_n_obs].presence
    max_raw = params[:max_n_obs].presence
    return [bound_min, bound_max] if min_raw.blank? && max_raw.blank?

    min_v = min_raw.present? ? [[min_raw.to_i, bound_min].max, bound_max].min : bound_min
    max_v = max_raw.present? ? [[max_raw.to_i, bound_min].max, bound_max].min : bound_max
    min_v, max_v = max_v, min_v if min_v > max_v
    [min_v, max_v]
  end

  # Apply range only when the user narrowed it; full span keeps unknown n_obs rows.
  def filter_n_obs(scope)
    return scope unless @n_obs_bounds && @min_n_obs && @max_n_obs
    return scope if @min_n_obs <= @n_obs_bounds[:min] && @max_n_obs >= @n_obs_bounds[:max]

    scope.for_n_obs_between(@min_n_obs, @max_n_obs)
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
