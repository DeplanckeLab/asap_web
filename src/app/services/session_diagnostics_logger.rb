# frozen_string_literal: true

require 'fileutils'
require 'logger'

class SessionDiagnosticsLogger
  LOG_FILENAME = 'session_diagnostics.log'

  class << self
    def request!(event)
      line = "session_diag #{format_event(event)}"
      logger.info(line)
      Rails.logger.info(line)
    end

    def sign_out!(event)
      level = event[:sign_out_suspicious] ? :warn : :info
      line = "session_diag_sign_out #{format_event(event)}"
      logger.public_send(level, line)
      Rails.logger.public_send(level, line)
    end

    def sign_out_intent!(payload)
      line = "session_diag_sign_out_intent #{format_event(payload)}"
      logger.info(line)
      Rails.logger.info(line)
    end

    def overflow!(request:, incoming:, error:)
      line =
        "session_diag_cookie_overflow " \
        "method=#{request[:method]} path=#{request[:path]} ip=#{request[:ip]} " \
        "request_id=#{request[:request_id]} incoming_cookie_bytes=#{incoming[:cookie_bytes]} " \
        "incoming_cookie_fp=#{incoming[:cookie_fp]} error=#{error}"
      logger.error(line)
      Rails.logger.error(line)
    end

    private

    def format_event(event)
      event.map { |key, value| "#{key}=#{stringify(value)}" }.join(' ')
    end

    def stringify(value)
      case value
      when Hash
        value.map { |k, v| "#{k}:#{stringify(v)}" }.join(',')
      when true, false, nil
        value.inspect
      else
        value.to_s.gsub(/\s+/, '_')
      end
    end

    def logger
      @logger ||= begin
        path = Rails.root.join('log', LOG_FILENAME)
        FileUtils.mkdir_p(path.dirname)
        ::Logger.new(path.to_s)
      rescue StandardError => error
        Rails.logger.warn("session_diag_file_unavailable error=#{error.class}:#{error.message}")
        Rails.logger
      end
    end
  end
end
