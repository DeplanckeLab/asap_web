# frozen_string_literal: true

# Redis sessions where a missing key for a still-presented cookie id must not
# mint a new id. Login calls reset_session and deletes the prior Redis key; an
# in-flight tab still sending that cookie would otherwise get a new guest id
# and Set-Cookie over the post-login session.
class AsapRedisSessionStore < RedisSessionStore
  private

  def get_session(env, sid)
    if sid
      session = load_session_with_fallback(sid)
      return [sid, session] if session

      empty = USE_INDIFFERENT_ACCESS ? {}.with_indifferent_access : {}
      return [sid, empty]
    end

    session_default_values
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, env, sid) if on_redis_down
    session_default_values
  end
  alias find_session get_session
end
