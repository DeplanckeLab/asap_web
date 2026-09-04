# frozen_string_literal: true

# Captures uncaught exceptions and HTTP 5xx responses for admin review.
class ServerErrorTrackerMiddleware
  SKIP_PATH_PREFIXES = [
    '/up',
    '/assets',
    '/vite',
    '/websocket',
    '/cable',
    '/server_errors'
  ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    return @app.call(env) if skip?(request)

    begin
      status, headers, body = @app.call(env)
    rescue Exception => exception
      ServerErrorTracker.record_exception!(env: env, exception: exception)
      raise
    end

    if status.to_i >= 500
      ServerErrorTracker.record_response!(env: env, status: status)
    end

    [status, headers, body]
  end

  private

  def skip?(request)
    path = request.path.to_s
    return true if path.empty?

    SKIP_PATH_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
  end
end
