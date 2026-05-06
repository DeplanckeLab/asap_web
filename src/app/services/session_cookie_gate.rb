# frozen_string_literal: true

require 'redis'
require 'json'
require 'securerandom'

# Tracks clients that hit the app without the Rails session cookie and blocks repeat abuse.
# Uses Redis so enforcement is shared across Puma workers.
class SessionCookieGate
  BLOCK_KEY_PREFIX = 'asap:session_cookie_gate:v1:block'
  STRIKE_KEY_PREFIX = 'asap:session_cookie_gate:v1:strikes'

  BAN_MESSAGE = 'This IP is banned due to repeated requests without a valid session cookie.'
  STRIKE_WINDOW_SECONDS = 1.hour.to_i
  CHALLENGE_TTL_SECONDS = 10.minutes.to_i
  CHALLENGE_KEY_PREFIX = 'asap:session_cookie_gate:v1:challenge'

  class << self
    def redis
      @redis ||= Redis.new(url: ENV.fetch('REDIS_URL'))
    end

    def blocked?(ip)
      redis.exists("#{BLOCK_KEY_PREFIX}:#{ip}").to_i.positive?
    end

    def block!(ip)
      redis.set("#{BLOCK_KEY_PREFIX}:#{ip}", '1')
    end

    def unban!(ip)
      redis.del("#{BLOCK_KEY_PREFIX}:#{ip}")
      clear_strikes!(ip)
    end

    def clear_strikes!(ip)
      redis.del("#{STRIKE_KEY_PREFIX}:#{ip}")
    end

    def challenge_for(ip)
      nonce = SecureRandom.hex(16)
      challenge_key = "#{CHALLENGE_KEY_PREFIX}:#{ip}:#{nonce}"

      # Simple graphical challenge: user must click the center of the target square.
      size = 420
      cell_size = 42
      columns = (size / cell_size)
      target_col = rand(columns)
      target_row = rand(columns)

      payload = {
        size: size,
        cell_size: cell_size,
        target_col: target_col,
        target_row: target_row
      }

      redis.setex(challenge_key, CHALLENGE_TTL_SECONDS, payload.to_json)

      payload.merge(
        nonce: nonce,
        ttl_seconds: CHALLENGE_TTL_SECONDS
      )
    end

    def solve_challenge!(ip, nonce:, click_x:, click_y:)
      challenge_key = "#{CHALLENGE_KEY_PREFIX}:#{ip}:#{nonce}"
      raw = redis.get(challenge_key)
      return false if raw.blank?

      payload = JSON.parse(raw)
      redis.del(challenge_key)

      cell_size = payload.fetch('cell_size').to_i
      target_col = payload.fetch('target_col').to_i
      target_row = payload.fetch('target_row').to_i
      target_x_min = target_col * cell_size
      target_x_max = target_x_min + cell_size
      target_y_min = target_row * cell_size
      target_y_max = target_y_min + cell_size

      x = click_x.to_i
      y = click_y.to_i

      inside_target = (x >= target_x_min && x <= target_x_max && y >= target_y_min && y <= target_y_max)
      return false unless inside_target

      unban!(ip)
      true
    rescue JSON::ParserError, KeyError
      false
    end

    # Increments consecutive cookieless strikes for ip and resets the rolling window TTL.
    def increment_strike(ip)
      key = "#{STRIKE_KEY_PREFIX}:#{ip}"
      redis.multi do |multi|
        multi.incr(key)
        multi.expire(key, STRIKE_WINDOW_SECONDS)
      end.first.to_i
    end
  end
end
