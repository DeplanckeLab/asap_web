# frozen_string_literal: true

require 'redis'

module ExternalCatalog
  # Redis-backed limits for guest catalog imports (anti-bot companion to the session puzzle).
  class ImportRateLimit
    IP_KEY_PREFIX = 'asap:ext_catalog_import:ip'
    SESSION_KEY_PREFIX = 'asap:ext_catalog_import:session'
    INFLIGHT_KEY_PREFIX = 'asap:ext_catalog_import:inflight'

    # The IP limit stays above the session one: it is checked first, and guests on one network share it.
    IP_LIMIT = Integer(ENV.fetch('EXT_CATALOG_IMPORT_IP_LIMIT', '10'))
    SESSION_LIMIT = Integer(ENV.fetch('EXT_CATALOG_IMPORT_SESSION_LIMIT', '5'))
    WINDOW_SECONDS = Integer(ENV.fetch('EXT_CATALOG_IMPORT_WINDOW_SEC', 1.hour.to_i.to_s))
    INFLIGHT_TTL_SECONDS = Integer(ENV.fetch('EXT_CATALOG_IMPORT_INFLIGHT_TTL_SEC', 2.hours.to_i.to_s))

    Result = Struct.new(:allowed, :reason, keyword_init: true) do
      def allowed?
        allowed
      end
    end

    class << self
      def redis
        @redis ||= Redis.new(url: ENV.fetch('REDIS_URL'))
      end

      # Reserve a guest import start. Call +release_inflight!+ when the job finishes.
      # The lock holds the id of the import that took it (+candidate_id+). +replacing_candidate_id+ is the
      # session's ongoing import that this start cancels: its lock does not block the new one.
      def allow_guest_start!(ip:, session_key:, candidate_id: nil, replacing_candidate_id: nil)
        ip = ip.to_s.strip
        session_key = session_key.to_s.strip
        return Result.new(allowed: false, reason: 'Missing session.') if session_key.blank?
        return Result.new(allowed: false, reason: 'Missing client address.') if ip.blank?

        inflight_key = "#{INFLIGHT_KEY_PREFIX}:#{session_key}"
        holder = redis.get(inflight_key)
        replaced = replacing_candidate_id.present? && holder.to_s == replacing_candidate_id.to_s
        if holder.present? && !replaced
          return Result.new(
            allowed: false,
            reason: 'An import is already running for this browser session. Wait for it to finish.'
          )
        end

        ip_count = incr_window!("#{IP_KEY_PREFIX}:#{ip}")
        if ip_count > IP_LIMIT
          return Result.new(
            allowed: false,
            reason: "Import limit reached for this network (#{IP_LIMIT} per hour). Try again later."
          )
        end

        session_count = incr_window!("#{SESSION_KEY_PREFIX}:#{session_key}")
        if session_count > SESSION_LIMIT
          return Result.new(
            allowed: false,
            reason: "Import limit reached for this session (#{SESSION_LIMIT} per hour). Try again later."
          )
        end

        redis.setex(inflight_key, INFLIGHT_TTL_SECONDS, (candidate_id.presence || '1').to_s)
        Result.new(allowed: true, reason: nil)
      rescue Redis::BaseError => e
        Rails.logger.error("[ExternalCatalog::ImportRateLimit] redis error: #{e.class} #{e.message}")
        Result.new(allowed: false, reason: 'Import temporarily unavailable. Try again shortly.')
      end

      # With +candidate_id+, only releases the lock that import holds (or an old lock without an id): a
      # cancelled job finishing after the guest started another import must not free the new import's lock.
      def release_inflight!(session_key:, candidate_id: nil)
        key = session_key.to_s.strip
        return if key.blank?

        inflight_key = "#{INFLIGHT_KEY_PREFIX}:#{key}"
        if candidate_id.present?
          holder = redis.get(inflight_key).to_s
          return unless holder == candidate_id.to_s || holder == '1'
        end
        redis.del(inflight_key)
      rescue Redis::BaseError => e
        Rails.logger.warn("[ExternalCatalog::ImportRateLimit] release failed: #{e.class} #{e.message}")
      end

      private

      def incr_window!(key)
        count = nil
        redis.multi do |multi|
          multi.incr(key)
          multi.expire(key, WINDOW_SECONDS)
        end.tap do |replies|
          count = replies.first.to_i
        end
        count
      end
    end
  end
end
