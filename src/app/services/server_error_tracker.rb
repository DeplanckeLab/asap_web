# frozen_string_literal: true

# Persists HTTP 500 / uncaught exceptions for the admin server-errors page.
# Never raises into the request lifecycle.
class ServerErrorTracker
  MAX_MESSAGE_BYTES = 8_192
  MAX_BACKTRACE_BYTES = 32_768
  MAX_PARAMS_BYTES = 8_192
  MAX_USER_AGENT_BYTES = 512
  MAX_PATH_BYTES = 500
  BACKTRACE_LINE_LIMIT = 80

  class << self
    def record_exception!(env:, exception:, status: 500)
      request = ActionDispatch::Request.new(env)
      record!(
        exception_class: exception.class.name,
        message: exception.message.to_s,
        backtrace: Array(exception.backtrace),
        request: request,
        env: env,
        status: status
      )
    end

    def record_response!(env:, status:)
      request = ActionDispatch::Request.new(env)
      exception = env['action_dispatch.exception']
      if exception
        record_exception!(env: env, exception: exception, status: status)
        return
      end

      record!(
        exception_class: 'HttpError',
        message: "HTTP #{status}",
        backtrace: [],
        request: request,
        env: env,
        status: status
      )
    end

    def record!(exception_class:, message:, backtrace:, request:, env:, status:)
      ServerError.create!(
        exception_class: truncate_string(exception_class.to_s.presence || 'UnknownError', 255),
        message: truncate_string(message.to_s, MAX_MESSAGE_BYTES),
        backtrace: truncate_string(Array(backtrace).first(BACKTRACE_LINE_LIMIT).join("\n"), MAX_BACKTRACE_BYTES),
        path: truncate_string(request.fullpath.to_s.presence || request.path.to_s, MAX_PATH_BYTES),
        http_method: truncate_string(request.request_method.to_s.presence || 'GET', 16),
        status: status.to_i,
        request_id: truncate_string(request.request_id.to_s, 64),
        ip: truncate_string(request.remote_ip.to_s, 64),
        user_id: current_user_id(env),
        user_agent: truncate_string(request.user_agent.to_s, MAX_USER_AGENT_BYTES),
        filtered_params: truncate_string(filtered_params_json(request), MAX_PARAMS_BYTES)
      )
    rescue StandardError => error
      Rails.logger.error("[ServerErrorTracker] failed to persist server error: #{error.class}: #{error.message}")
      nil
    end

    private

    def current_user_id(env)
      warden = env['warden']
      user = warden&.user
      user.respond_to?(:id) ? user.id : nil
    rescue StandardError
      nil
    end

    def filtered_params_json(request)
      params = request.filtered_parameters
      params = params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
      JSON.generate(params)
    rescue StandardError
      '{}'
    end

    def truncate_string(value, max_bytes)
      text = value.to_s
      return text if text.bytesize <= max_bytes

      text.byteslice(0, max_bytes).force_encoding(text.encoding).scrub
    end
  end
end
