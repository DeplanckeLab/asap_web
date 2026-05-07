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
  helper_method :admin?, :authorized?, :readable?, :exportable?, :exportable_item?, :editable?, :owner?, :owner_or_admin?, :owner_or_admin_obj?, :read_only?, :clonable?, :analyzable?, :analyzable_item?, :annotable?, :annotable_item?, :cla_votable?, :downloadable?, :publication_snapshot_reader?, :annot_visible_under_publication_rules?, :run_visible_under_publication_rules?

  protected

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

    if SessionCookieGate.blocked?(ip)
      render_ip_ban_challenge(ip)
      return
    end

    if session_clearance_cookie_present?
      @session_cookie_in_request = session_cookie_name_in_request?
      return
    end

    @session_cookie_in_request = false
    return unless should_enforce_session_cookie_challenge?
    render_ip_ban_challenge(ip)
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

  def render_ip_ban_challenge(ip)
    @session_cookie_in_request = false
    @ip_ban_challenge = SessionCookieGate.challenge_for(ip)
    @banned_ip = ip

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

end

