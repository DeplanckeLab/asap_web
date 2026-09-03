class ApplicationController < ActionController::Base
  include AdminAuthorization
  include ProjectAuthorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Search-engine crawlers must receive the real HTML, including older crawler user agents.
  allow_browser versions: :modern, unless: :search_engine_crawler?

  # Skip authentication for certain actions that can be accessed publicly
  # Authentication will be checked at the action level via readable?/exportable? methods
  skip_before_action :authenticate_user!, only: [:index, :show, :metadata_coordinates, :metadata_vectors, :gene_expression, :get_file, :search_snapshot], raise: false
  before_action :configure_permitted_parameters, if: :devise_controller?

  prepend_before_action :enforce_session_cookie_policy

  # Initialize session for sandbox projects
  before_action :init_session

  # Make authorization methods available to views
  helper_method :admin?, :uab?, :admin_report?, :authorized?, :readable?, :exportable?, :exportable_item?, :editable?, :owner?, :owner_or_admin?, :owner_or_admin_obj?, :read_only?, :clonable?, :analyzable?, :analyzable_item?, :annotable?, :annotable_item?, :cla_votable?, :downloadable?, :publication_snapshot_reader?, :annot_visible_under_publication_rules?, :run_visible_under_publication_rules?, :guest_sandbox_project, :synced_reference_data_writable?, :can_edit_synced_reference_data?, :search_engine_crawler?

  protected

  # Reference data authored on development and synced to production is read-only in the prod UI.
  def synced_reference_data_writable?
    !Rails.env.production?
  end

  def can_edit_synced_reference_data?
    admin? && synced_reference_data_writable?
  end

  def ensure_synced_reference_data_writable!
    return if synced_reference_data_writable?

    redirect_back(
      fallback_location: root_path,
      alert: "Reference data synced from development cannot be edited on production. " \
             "Edit on the development instance, then run the sync task."
    )
  end

  def search_engine_crawler?
    SearchEngineCrawler.match?(request.user_agent)
  end

  def skip_project_unarchive_for_crawler?
    search_engine_crawler? || request_user_agent_indicates_bot?
  end

  def enforce_session_cookie_policy
    if search_engine_crawler?
      @session_cookie_in_request = false
      return
    end

    unless SessionCookieGate.enabled?
      @session_cookie_in_request = session_cookie_name_in_request?
      return
    end

    return if skip_session_cookie_policy?

    ip = request.remote_ip.to_s
    if ip.blank?
      head :forbidden
      return
    end

    if session_unarchive_cleared?
      @session_cookie_in_request = session_cookie_name_in_request?
      return
    end

    @session_cookie_in_request = session_cookie_name_in_request?
    return unless html_get_request?
    return unless unarchive_challenge_required?

    render_session_cookie_challenge(ip)
  end

  def skip_session_cookie_policy?
    return true if request.request_method_symbol == :options
    return true if request.path == '/up'
    return true if request.path == '/security/session_cookie_challenge/solve'
    return true if request.path == '/security/sign_out_intent'

    false
  end

  def html_get_request?
    return false unless request.get?

    format = request.format
    format.html? || format.to_s == '*/*'
  end

  def unarchive_challenge_required?
    project_key = project_key_from_path
    return false if project_key.blank?
    return false unless project_show_path?

    project = Project.find_by(key: project_key)
    SessionCookieGate.challenge_required?(
      archived: project&.archived_on_s3? || false,
      project_show: true,
      metadata_only: metadata_only_view_param? && !force_unarchive_param?,
      force_unarchive: force_unarchive_param?,
      search_engine: false,
      signed_in: user_signed_in?,
      enabled: true
    )
  end

  def project_show_path?
    request.path.to_s.match?(%r{\A/projects/[^/]+/?\z})
  end

  def metadata_only_view_param?
    view = params[:view].to_s
    view.blank? || %w[summary settings access annotations].include?(view)
  end

  def force_unarchive_param?
    ActiveModel::Type::Boolean.new.cast(params[:force_unarchive])
  end

  def project_key_from_path
    path = request.path.to_s
    match = path.match(%r{\A/projects/([^/]+)})
    return nil unless match

    key = match[1].to_s
    return nil if key.blank? || key == 'new'

    key
  end

  def render_session_cookie_challenge(ip)
    @session_cookie_in_request = false
    @session_cookie_challenge = SessionCookieGate.challenge_for(ip)
    @banned_ip = ip

    render 'shared/session_cookie_challenge', layout: 'session_challenge', status: :ok
  end

  def session_cookie_key
    Rails.application.config.session_options.fetch(:key)
  end

  def session_cookie_name_in_request?
    request.cookies.key?(session_cookie_key)
  end

  def session_clearance_cookie_name
    :asap_session_clearance
  end

  # One successful challenge clears unarchive for every project in this browser session.
  def session_unarchive_cleared?
    session[:asap_unarchive_cleared] == true || cookies.signed[session_clearance_cookie_name].to_s == 'ok'
  end

  def grant_session_clearance!
    session[:asap_unarchive_cleared] = true
    cookies.signed[session_clearance_cookie_name] = {
      value: 'ok',
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production?
    }
  end

  def crawler_archived_summary_only?
    search_engine_crawler? && @project&.archived_on_s3?
  end

  def get_real_ip
    real_ip = request.remote_ip

    Rails.logger.debug(
      "[get_real_ip] X-Forwarded-For=#{request.headers['X-Forwarded-For'].inspect} " \
      "X-Real-IP=#{request.headers['X-Real-IP'].inspect} " \
      "remote_ip=#{real_ip.inspect}"
    )

    real_ip
  end

  # Prefer nginx X-Real-IP; fall back to Rack remote_ip (same as project.creator_ip).
  def request_creator_ip
    request.headers['X-Real-IP'].to_s.strip.presence || get_real_ip.to_s.strip.presence
  end

  # Same signal as ActionController::AllowBrowser (useragent gem): known crawlers/preview bots.
  def request_user_agent_indicates_bot?
    ua = request.user_agent
    return false if ua.blank?

    require 'useragent'
    UserAgent.parse(ua).bot?
  rescue StandardError
    false
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:displayed_name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:displayed_name])
  end

  # Initialize session for sandbox projects
  def init_session
    session[:sandbox] ||= create_sandbox_key
  end

  # Generate a random key for sandbox sessions
  def create_sandbox_key
    Array.new(6) { [*'0'..'9', *'a'..'z'].sample }.join
  end

  # Current guest sandbox project for this browser session, if any.
  def guest_sandbox_project
    return nil if user_signed_in?
    return nil if session[:sandbox].blank?

    @guest_sandbox_project ||= Project.not_deleted.find_by(key: session[:sandbox], sandbox: true)
  end

end

