# frozen_string_literal: true

require 'cgi'
require 'digest'

# Temporary instrumentation for cookie-session races and unexpected sign-outs.
# Enable with SESSION_DIAGNOSTICS=1. Writes to log/session_diagnostics.log and Rails.logger.
class SessionDiagnosticsMiddleware
  COOKIE_WARN_BYTES = 3000
  COOKIE_CRITICAL_BYTES = 3900
  FLIP_WINDOW_SECONDS = 60
  SIGN_OUT_INTENT_WINDOW_SECONDS = 10

  SKIP_PATH_PREFIXES = [
    '/up',
    '/assets',
    '/vite',
    '/websocket',
    '/cable'
  ].freeze

  class << self
    def enabled?
      ActiveModel::Type::Boolean.new.cast(ENV['SESSION_DIAGNOSTICS'])
    end

    def recent_by_client
      @recent_by_client ||= {}
      @recent_mutex ||= Mutex.new
      [@recent_by_client, @recent_mutex]
    end

    def sign_out_intents
      @sign_out_intents ||= {}
      @sign_out_intents_mutex ||= Mutex.new
      [@sign_out_intents, @sign_out_intents_mutex]
    end

    def client_key_for(request)
      ua = Digest::SHA256.hexdigest(request.user_agent.to_s)[0, 8]
      "#{request.remote_ip}:#{ua}"
    end

    def record_sign_out_intent!(request, source:)
      intents, mutex = sign_out_intents
      key = client_key_for(request)
      now = Time.now.to_f
      mutex.synchronize do
        intents[key] = {
          at: now,
          source: source.to_s,
          path: request.referer.to_s[0, 300],
          request_id: request.request_id
        }
        intents.delete_if { |_k, value| (now - value[:at]) > SIGN_OUT_INTENT_WINDOW_SECONDS }
      end
      key
    end

    def consume_sign_out_intent(request)
      intents, mutex = sign_out_intents
      key = client_key_for(request)
      now = Time.now.to_f
      mutex.synchronize do
        intents.delete_if { |_k, value| (now - value[:at]) > SIGN_OUT_INTENT_WINDOW_SECONDS }
        intent = intents.delete(key)
        return nil unless intent

        intent.merge(age_s: (now - intent[:at]).round(3))
      end
    end
  end

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless self.class.enabled?

    request = ActionDispatch::Request.new(env)
    return @app.call(env) if skip?(request)

    session_key = session_cookie_key
    incoming = incoming_session_snapshot(request, session_key)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sign_out_request = sign_out_request?(request)
    sign_out_intent = sign_out_request ? self.class.consume_sign_out_intent(request) : nil

    begin
      status, headers, body = @app.call(env)
    rescue ActionDispatch::Cookies::CookieOverflow => error
      SessionDiagnosticsLogger.overflow!(
        request: request_fields(request),
        incoming: incoming,
        error: error.message
      )
      raise
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    outgoing = outgoing_session_snapshot(env, headers, session_key)
    event = build_event(request, status, duration_ms, incoming, outgoing)
    flip = detect_flip(request, incoming, outgoing)
    event[:flip] = flip if flip
    if event[:incoming_cookie_bytes].to_i >= COOKIE_CRITICAL_BYTES ||
       event[:set_cookie_bytes].to_i >= COOKIE_CRITICAL_BYTES
      event[:cookie_size_level] = 'critical'
    elsif event[:incoming_cookie_bytes].to_i >= COOKIE_WARN_BYTES ||
          event[:set_cookie_bytes].to_i >= COOKIE_WARN_BYTES
      event[:cookie_size_level] = 'warn'
    end

    if sign_out_request
      event[:sign_out] = true
      event[:sign_out_button_intent] = sign_out_intent.present?
      event[:sign_out_intent] = sign_out_intent if sign_out_intent
      event[:sign_out_suspicious] = !sign_out_intent.present?
    end

    if interesting?(event)
      SessionDiagnosticsLogger.request!(event)
      if sign_out_request
        SessionDiagnosticsLogger.sign_out!(event)
      end
    end

    remember_client(request, incoming, outgoing)
    [status, headers, body]
  end

  private

  def skip?(request)
    path = request.path.to_s
    return true if path.empty?
    return true if path == '/security/sign_out_intent'

    SKIP_PATH_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
  end

  def sign_out_request?(request)
    path = request.path.to_s
    return true if path == '/users/sign_out'
    return true if request.request_method == 'DELETE' && path.start_with?('/users/sign_out')

    false
  end

  def session_cookie_key
    Rails.application.config.session_options.fetch(:key)
  end

  def incoming_session_snapshot(request, session_key)
    raw = request.cookies[session_key].to_s
    {
      cookie_bytes: raw.bytesize,
      cookie_fp: fingerprint(raw),
      has_cookie: raw.present?
    }
  end

  def outgoing_session_snapshot(env, headers, session_key)
    set_cookies = Array(headers['Set-Cookie'] || headers['set-cookie'])
    set_cookies = set_cookies.join("\n").split(/\n+/).map(&:strip).reject(&:blank?) if set_cookies.size == 1
    session_set = set_cookies.find { |line| line.start_with?("#{session_key}=") }

    warden = env['warden']
    user = begin
      warden&.user
    rescue StandardError
      nil
    end

    # During destroy, warden.user may already be cleared; prefer env marker if present.
    signed_in = !user.nil?
    user_id = user.respond_to?(:id) ? user.id : nil

    out = {
      signed_in: signed_in,
      user_id: user_id,
      set_cookie: session_set.present?
    }

    if session_set
      value = session_set.split(';', 2).first.to_s.split('=', 2).last.to_s
      out[:set_cookie_bytes] = session_set.bytesize
      out[:cookie_fp] = fingerprint(CGI.unescape(value))
    end

    out
  end

  def build_event(request, status, duration_ms, incoming, outgoing)
    {
      method: request.request_method,
      path: request.fullpath.to_s[0, 300],
      status: status,
      duration_ms: duration_ms,
      ip: request.remote_ip.to_s,
      request_id: request.request_id,
      xhr: request.xhr?,
      referer: request.referer.to_s[0, 300].presence,
      origin: request.get_header('HTTP_ORIGIN').to_s.presence,
      accept: request.get_header('HTTP_ACCEPT').to_s[0, 120].presence,
      turbo_frame: request.get_header('HTTP_TURBO_FRAME').to_s.presence,
      sec_fetch_site: request.get_header('HTTP_SEC_FETCH_SITE').to_s.presence,
      sec_fetch_mode: request.get_header('HTTP_SEC_FETCH_MODE').to_s.presence,
      sec_fetch_dest: request.get_header('HTTP_SEC_FETCH_DEST').to_s.presence,
      sec_fetch_user: request.get_header('HTTP_SEC_FETCH_USER').to_s.presence,
      ua: Digest::SHA256.hexdigest(request.user_agent.to_s)[0, 8],
      incoming_cookie_bytes: incoming[:cookie_bytes],
      incoming_cookie_fp: incoming[:cookie_fp],
      has_cookie: incoming[:has_cookie],
      signed_in: outgoing[:signed_in],
      user_id: outgoing[:user_id],
      set_cookie: outgoing[:set_cookie],
      set_cookie_bytes: outgoing[:set_cookie_bytes],
      outgoing_cookie_fp: outgoing[:cookie_fp]
    }
  end

  def interesting?(event)
    return true if event[:flip]
    return true if event[:sign_out]
    return true if event[:path].to_s.start_with?('/users/sign_')
    return true if event[:incoming_cookie_bytes].to_i >= COOKIE_WARN_BYTES
    return true if event[:set_cookie_bytes].to_i >= COOKIE_WARN_BYTES
    return true if event[:signed_in]

    path = event[:path].to_s
    path.start_with?('/projects') && (event[:method] != 'GET' || event[:xhr] || path.include?('unarchive') || path.include?('run_'))
  end

  def detect_flip(request, incoming, outgoing)
    path = request.path.to_s
    return nil if path.start_with?('/users/sign_out')

    store, mutex = self.class.recent_by_client
    client_key = self.class.client_key_for(request)
    now = Time.now.to_f
    previous = nil

    mutex.synchronize do
      prune_recent!(store, now)
      previous = store[client_key]
    end

    return nil unless previous
    return nil if (now - previous[:at]) > FLIP_WINDOW_SECONDS
    return nil unless previous[:signed_in]
    return nil if outgoing[:signed_in]

    fp_changed = previous[:cookie_fp].present? &&
                 incoming[:cookie_fp].present? &&
                 previous[:cookie_fp] != incoming[:cookie_fp]
    cookie_lost = previous[:has_cookie] && !incoming[:has_cookie]
    return nil unless fp_changed || cookie_lost

    {
      kind: 'signed_in_to_guest',
      window_s: (now - previous[:at]).round(2),
      prev_path: previous[:path],
      prev_fp: previous[:cookie_fp],
      prev_user_id: previous[:user_id],
      now_fp: incoming[:cookie_fp],
      now_path: request.fullpath.to_s[0, 300],
      fp_changed: fp_changed,
      cookie_lost: cookie_lost
    }
  end

  def remember_client(request, incoming, outgoing)
    store, mutex = self.class.recent_by_client
    client_key = self.class.client_key_for(request)
    now = Time.now.to_f
    fp = outgoing[:cookie_fp].presence || incoming[:cookie_fp]

    mutex.synchronize do
      store[client_key] = {
        at: now,
        signed_in: outgoing[:signed_in],
        user_id: outgoing[:user_id],
        cookie_fp: fp,
        has_cookie: outgoing[:set_cookie] ? true : incoming[:has_cookie],
        path: request.fullpath.to_s[0, 300]
      }
      prune_recent!(store, now)
    end
  end

  def prune_recent!(store, now)
    store.delete_if { |_key, value| (now - value[:at]) > FLIP_WINDOW_SECONDS }
  end

  def fingerprint(raw)
    return nil if raw.blank?

    Digest::SHA256.hexdigest(raw)[0, 12]
  end

  def request_fields(request)
    {
      method: request.request_method,
      path: request.fullpath.to_s[0, 300],
      ip: request.remote_ip.to_s,
      request_id: request.request_id
    }
  end
end
