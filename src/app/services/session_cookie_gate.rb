# frozen_string_literal: true

require 'redis'
require 'json'
require 'securerandom'

# Human check used only when a request would restore an archived project from S3.
# Ordinary pages are not challenged. Google/Bing never see this gate.
class SessionCookieGate
  BLOCK_KEY_PREFIX = 'asap:session_cookie_gate:v2:block'
  STRIKE_KEY_PREFIX = 'asap:session_cookie_gate:v2:strikes'
  CHALLENGE_KEY_PREFIX = 'asap:session_cookie_gate:v2:challenge'

  STRIKE_WINDOW_SECONDS = 1.hour.to_i
  CHALLENGE_TTL_SECONDS = 10.minutes.to_i
  BOARD_COLS = 5
  BOARD_ROWS = 4
  CELL_SIZE = 80

  class << self
    def redis
      @redis ||= Redis.new(url: ENV.fetch('REDIS_URL'))
    end

    def enabled?
      flag = ENV['SESSION_COOKIE_UNARCHIVE_CHALLENGE']
      return ActiveModel::Type::Boolean.new.cast(flag) unless flag.nil? || flag == ''

      Rails.env.production?
    end

    def challenge_required?(archived:, project_show:, metadata_only:, force_unarchive:, search_engine: false, enabled: nil)
      return false unless enabled.nil? ? self.enabled? : enabled
      return false if search_engine
      return false unless archived
      return false unless project_show
      return true if force_unarchive

      !metadata_only
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
      cell_count = BOARD_COLS * BOARD_ROWS
      target_index = rand(cell_count)
      piece_index = rand(cell_count - 1)
      piece_index += 1 if piece_index >= target_index

      payload = {
        board_cols: BOARD_COLS,
        board_rows: BOARD_ROWS,
        cell_size: CELL_SIZE,
        target_col: target_index % BOARD_COLS,
        target_row: target_index / BOARD_COLS,
        piece_col: piece_index % BOARD_COLS,
        piece_row: piece_index / BOARD_COLS
      }

      redis.setex(challenge_key, CHALLENGE_TTL_SECONDS, payload.to_json)

      payload.merge(
        nonce: nonce,
        ttl_seconds: CHALLENGE_TTL_SECONDS
      )
    end

    def solve_challenge!(ip, nonce:, drop_col:, drop_row:)
      return false unless drop_col.present? && drop_row.present?

      challenge_key = "#{CHALLENGE_KEY_PREFIX}:#{ip}:#{nonce}"
      raw = redis.get(challenge_key)
      return false if raw.blank?

      payload = JSON.parse(raw)

      placed =
        drop_col.to_i == payload.fetch('target_col').to_i &&
        drop_row.to_i == payload.fetch('target_row').to_i
      return false unless placed

      redis.del(challenge_key)
      unban!(ip)
      true
    rescue JSON::ParserError, KeyError
      false
    end

    def increment_strike(ip)
      key = "#{STRIKE_KEY_PREFIX}:#{ip}"
      redis.multi do |multi|
        multi.incr(key)
        multi.expire(key, STRIKE_WINDOW_SECONDS)
      end.first.to_i
    end
  end
end
