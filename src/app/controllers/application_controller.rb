class ApplicationController < ActionController::Base
  include AdminAuthorization
  include ProjectAuthorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Skip authentication for certain actions that can be accessed publicly
  # Authentication will be checked at the action level via readable?/exportable? methods
  skip_before_action :authenticate_user!, only: [:index, :show, :metadata_coordinates, :metadata_vectors, :gene_expression, :get_file], raise: false
  before_action :configure_permitted_parameters, if: :devise_controller?

  prepend_before_action :enforce_session_cookie_policy

  # Initialize session for sandbox projects
  before_action :init_session

  # Make authorization methods available to views
  helper_method :admin?, :uab?, :authorized?, :readable?, :exportable?, :exportable_item?, :editable?, :owner?, :owner_or_admin?, :owner_or_admin_obj?, :read_only?, :clonable?, :analyzable?, :analyzable_item?, :annotable?, :annotable_item?, :cla_votable?, :downloadable?, :publication_snapshot_reader?, :annot_visible_under_publication_rules?, :run_visible_under_publication_rules?, :guest_sandbox_project, :synced_reference_data_writable?, :can_edit_synced_reference_data?

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

  def enforce_session_cookie_policy
    unless Rails.env.production?
      @session_cookie_in_request = true
      return
    end

    return if skip_session_cookie_policy?

    ip = request.remote_ip.to_s
    if ip.blank?
      head :forbidden
      return
    end

    strict_validation = strict_session_validation_required?

    if SessionCookieGate.blocked?(ip) && strict_validation
      render_ip_ban_challenge(ip, strict: true)
      return
    end

    if session_clearance_cookie_present?
      @session_cookie_in_request = session_cookie_name_in_request?
      return
    end

    @session_cookie_in_request = false
    return unless should_enforce_session_cookie_challenge?
    return if challenge_bypass_requested? && !strict_validation

    render_ip_ban_challenge(ip, strict: strict_validation)
    return
  end

  def skip_session_cookie_policy?
    return true if request.request_method_symbol == :options
    return true if request.path == '/up'
    return true if request.path == '/security/session_cookie_challenge/solve'

    false
  end

  # Enforce challenge on all HTML page requests.
  # API polling and assets are excluded by format/method checks.
  def should_enforce_session_cookie_challenge?
    return false unless request.get?
    format = request.format
    return false unless format.html? || format.to_s == '*/*'
    true
  end

  def strict_session_validation_required?
    project_key = project_key_from_path
    return false if project_key.blank?

    project = Project.find_by(key: project_key)
    project&.archived_on_s3? || false
  end

  def project_key_from_path
    path = request.path.to_s
    match = path.match(%r{\A/projects/([^/]+)})
    return nil unless match

    key = match[1].to_s
    return nil if key.blank? || key == 'new'

    key
  end

  def challenge_bypass_requested?
    params[:challenge_bypass].to_s == '1'
  end

  def challenge_auto_continue_url
    uri = URI.parse(request.original_fullpath)
    current_params = Rack::Utils.parse_nested_query(uri.query)
    current_params['challenge_bypass'] = '1'
    uri.query = current_params.to_query
    uri.to_s
  end

  def render_ip_ban_challenge(ip, strict:)
    @session_cookie_in_request = false
    @project = Project.find_by(key: project_key_from_path) if @project.nil?
    @ip_ban_challenge = SessionCookieGate.challenge_for(ip)
    @banned_ip = ip
    @ip_ban_challenge_strict = strict
    @ip_ban_challenge_auto_continue_url = strict ? nil : challenge_auto_continue_url

    render 'shared/ip_ban_challenge', status: :forbidden
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

  def session_clearance_cookie_present?
    cookies.signed[session_clearance_cookie_name].to_s == 'ok'
  end

  def grant_session_clearance!
    cookies.signed[session_clearance_cookie_name] = {
      value: 'ok',
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production?,
      expires: 24.hours.from_now
    }
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

