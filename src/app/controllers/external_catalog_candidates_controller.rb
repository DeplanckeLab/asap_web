# frozen_string_literal: true

class ExternalCatalogCandidatesController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_uab
  before_action :set_candidate, only: %i[show create_project]

  PER_PAGE = 25

  def index
    @source = params[:source].to_s.presence
    @project_type = params[:project_type].to_s.presence
    @in_asap = params[:in_asap].to_s.presence
    @q = params[:q].to_s.strip.presence
    @page = [params[:page].to_i, 1].max
    @per_page = PER_PAGE

    scope = ExternalCatalogCandidate.all
    scope = scope.for_source(@source) if @source.present?
    scope = scope.for_project_type(@project_type) if @project_type.present?
    scope = scope.search_q(@q) if @q.present?
    scope = filter_in_asap(scope, @in_asap)

    @total_count = scope.count
    @candidates = scope.order(Arel.sql('LOWER(COALESCE(title, \'\')) ASC'), id: :asc)
                       .offset((@page - 1) * @per_page)
                       .limit(@per_page)
                       .to_a

    @asap_projects_by_candidate_id = preload_asap_projects(@candidates)
  end

  def show
    @asap_projects = @candidate.asap_projects.order(id: :desc).to_a
  end

  def create_project
    unless @candidate.can_create_project?
      redirect_back(
        fallback_location: external_catalog_candidate_path(@candidate),
        alert: create_blocked_message
      )
      return
    end

    @candidate.update!(
      import_status: 'importing',
      import_error: nil,
      import_user_id: current_user.id
    )

    ExternalCatalogImportCandidateJob.perform_later(@candidate.id, current_user.id)

    redirect_to external_catalog_candidate_path(@candidate),
                notice: 'Import started. Refresh this page to see progress.'
  end

  private

  def set_candidate
    @candidate = ExternalCatalogCandidate.find(params[:id])
  end

  def create_blocked_message
    if @candidate.importing?
      'Import already in progress for this candidate.'
    elsif @candidate.already_in_asap?
      'An ASAP project already exists for this dataset.'
    else
      'Cannot create a project for this candidate.'
    end
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
        result[candidate.id] = projects
      end
    end
    result
  end
end
