# frozen_string_literal: true

require 'json'
require 'redis'

class IsolatedComplianceStatusStore
  CACHE_PREFIX = 'isolated_compliance'.freeze
  DEFAULT_TTL = 12.hours

  class << self
    def key(task_id)
      "#{CACHE_PREFIX}:#{task_id}"
    end

    def write(task_id, payload, expires_in: DEFAULT_TTL)
      if redis_available?
        redis.setex(key(task_id), expires_in.to_i, payload.to_json)
      else
        Rails.cache.write(key(task_id), payload, expires_in: expires_in)
      end
    end

    def read(task_id)
      if redis_available?
        raw = redis.get(key(task_id))
        raw ? JSON.parse(raw) : nil
      else
        Rails.cache.read(key(task_id))
      end
    rescue JSON::ParserError
      nil
    end

    private

    def redis_available?
      redis.present?
    rescue StandardError
      false
    end

    def redis
      @redis ||= Redis.new(url: ENV.fetch('REDIS_URL'))
    end
  end
end

