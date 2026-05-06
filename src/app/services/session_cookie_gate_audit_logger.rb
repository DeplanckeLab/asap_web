# frozen_string_literal: true

require 'fileutils'
require 'logger'

class SessionCookieGateAuditLogger
  LOG_FILENAME = 'session_cookie_gate.log'

  class << self
    def ban!(ip:, strikes:, reason:)
      logger.warn("session_cookie_gate_ban ip=#{ip} strikes=#{strikes} reason=#{reason}")
    end

    def unban!(ip:, source:)
      logger.info("session_cookie_gate_unban ip=#{ip} source=#{source}")
    end

    private

    def logger
      @logger ||= begin
        path = Rails.root.join('log', LOG_FILENAME)
        FileUtils.mkdir_p(path.dirname)
        ::Logger.new(path.to_s)
      end
    end
  end
end
