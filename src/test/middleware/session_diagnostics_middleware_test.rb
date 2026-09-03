# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'minitest/mock'

class SessionDiagnosticsMiddlewareTest < TestBaseWithoutFixtures
  class FakeWarden
    def initialize(user)
      @user = user
    end

    def user
      @user
    end
  end

  class FakeUser
    attr_reader :id

    def initialize(id)
      @id = id
    end
  end

  setup do
    @previous = ENV['SESSION_DIAGNOSTICS']
    ENV['SESSION_DIAGNOSTICS'] = '1'
    store, mutex = SessionDiagnosticsMiddleware.recent_by_client
    mutex.synchronize { store.clear }
    intents, intent_mutex = SessionDiagnosticsMiddleware.sign_out_intents
    intent_mutex.synchronize { intents.clear }
  end

  teardown do
    if @previous.nil?
      ENV.delete('SESSION_DIAGNOSTICS')
    else
      ENV['SESSION_DIAGNOSTICS'] = @previous
    end
    store, mutex = SessionDiagnosticsMiddleware.recent_by_client
    mutex.synchronize { store.clear }
    intents, intent_mutex = SessionDiagnosticsMiddleware.sign_out_intents
    intent_mutex.synchronize { intents.clear }
  end

  test 'enabled? follows SESSION_DIAGNOSTICS' do
    ENV['SESSION_DIAGNOSTICS'] = '0'
    assert_not SessionDiagnosticsMiddleware.enabled?
    ENV['SESSION_DIAGNOSTICS'] = '1'
    assert SessionDiagnosticsMiddleware.enabled?
  end

  test 'detects signed_in to guest flip when cookie fingerprint changes' do
    middleware = SessionDiagnosticsMiddleware.new(->(_env) { [200, {}, ['ok']] })
    session_key = Rails.application.config.session_options.fetch(:key)

    env_login = Rack::MockRequest.env_for(
      '/users/sign_in',
      method: 'POST',
      'REMOTE_ADDR' => '203.0.113.10',
      'HTTP_USER_AGENT' => 'SessionDiagTestAgent'
    )
    env_login['HTTP_COOKIE'] = "#{session_key}=login-cookie-value"
    env_login['warden'] = FakeWarden.new(FakeUser.new(42))
    env_login['action_dispatch.request_id'] = 'req-login'

    logged = []
    SessionDiagnosticsLogger.stub(:request!, ->(event) { logged << event }) do
      SessionDiagnosticsLogger.stub(:sign_out!, ->(*) {}) do
        req = ActionDispatch::Request.new(env_login)
        middleware.send(
          :remember_client,
          req,
          { cookie_bytes: 20, cookie_fp: 'aaa111aaa111', has_cookie: true },
          { signed_in: true, user_id: 42, set_cookie: true, cookie_fp: 'aaa111aaa111' }
        )

        env_poll = Rack::MockRequest.env_for(
          '/projects/abc123/unarchive_status',
          method: 'GET',
          'REMOTE_ADDR' => '203.0.113.10',
          'HTTP_USER_AGENT' => 'SessionDiagTestAgent',
          'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
        )
        env_poll['HTTP_COOKIE'] = "#{session_key}=older-guest-cookie"
        env_poll['warden'] = FakeWarden.new(nil)
        env_poll['action_dispatch.request_id'] = 'req-poll'

        middleware.call(env_poll)
      end
    end

    flip_events = logged.select { |event| event[:flip] }
    assert_equal 1, flip_events.size
    assert_equal 'signed_in_to_guest', flip_events.first[:flip][:kind]
    assert flip_events.first[:flip][:fp_changed]
  end

  test 'marks sign_out without button intent as suspicious' do
    middleware = SessionDiagnosticsMiddleware.new(->(_env) { [303, {}, []] })
    events = []
    sign_outs = []

    SessionDiagnosticsLogger.stub(:request!, ->(event) { events << event }) do
      SessionDiagnosticsLogger.stub(:sign_out!, ->(event) { sign_outs << event }) do
        env = Rack::MockRequest.env_for(
          '/users/sign_out',
          method: 'DELETE',
          'REMOTE_ADDR' => '203.0.113.12',
          'HTTP_USER_AGENT' => 'SessionDiagTestAgent',
          'HTTP_REFERER' => 'https://asap-test.epfl.ch/projects/59uxrc?view=analysis',
          'HTTP_SEC_FETCH_USER' => '?1'
        )
        middleware.call(env)
      end
    end

    assert_equal 1, sign_outs.size
    assert sign_outs.first[:sign_out_suspicious]
    assert_equal false, sign_outs.first[:sign_out_button_intent]
    assert_equal 'https://asap-test.epfl.ch/projects/59uxrc?view=analysis', sign_outs.first[:referer]
    assert_equal '?1', sign_outs.first[:sec_fetch_user]
  end

  test 'sign_out with prior button intent is not suspicious' do
    middleware = SessionDiagnosticsMiddleware.new(->(_env) { [303, {}, []] })
    env = Rack::MockRequest.env_for(
      '/users/sign_out',
      method: 'DELETE',
      'REMOTE_ADDR' => '203.0.113.13',
      'HTTP_USER_AGENT' => 'SessionDiagTestAgent'
    )
    request = ActionDispatch::Request.new(env)
    SessionDiagnosticsMiddleware.record_sign_out_intent!(request, source: 'pointerdown')

    sign_outs = []
    SessionDiagnosticsLogger.stub(:request!, ->(*) {}) do
      SessionDiagnosticsLogger.stub(:sign_out!, ->(event) { sign_outs << event }) do
        middleware.call(env)
      end
    end

    assert_equal 1, sign_outs.size
    assert_not sign_outs.first[:sign_out_suspicious]
    assert sign_outs.first[:sign_out_button_intent]
  end

  test 'logs cookie overflow' do
    app = lambda do |_env|
      raise ActionDispatch::Cookies::CookieOverflow, 'cookie overflow'
    end
    middleware = SessionDiagnosticsMiddleware.new(app)

    overflow_logs = []
    SessionDiagnosticsLogger.stub(:overflow!, ->(**kwargs) { overflow_logs << kwargs }) do
      assert_raises(ActionDispatch::Cookies::CookieOverflow) do
        env = Rack::MockRequest.env_for('/projects/abc123', 'REMOTE_ADDR' => '203.0.113.11')
        middleware.call(env)
      end
    end

    assert_equal 1, overflow_logs.size
  end
end
