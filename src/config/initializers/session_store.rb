# frozen_string_literal: true

require_relative '../../lib/asap_redis_session_store'

# Server-side sessions: cookie holds only the session id; data lives in Redis.
# Deliberately set Redis TTL via :ttl and do NOT set :expire_after. With
# expire_after, Rack re-emits Set-Cookie on every request (sliding cookie
# expiry), which lets an older in-flight guest tab overwrite a post-login
# session id. With :ttl only, Set-Cookie is sent when the session id changes.
#
# AsapRedisSessionStore also reuses a presented session id when its Redis key
# was deleted (e.g. reset_session on login in another tab), so in-flight
# requests do not mint a new id and Set-Cookie over the login session.
Rails.application.config.session_store AsapRedisSessionStore,
  key: '_app_session',
  redis: {
    client: Redis.new(url: ENV.fetch('REDIS_SESSION_URL')),
    key_prefix: 'asap:session:',
    ttl: 14.days.to_i
  },
  httponly: true,
  same_site: :lax,
  secure: Rails.env.production?,
  on_redis_down: ->(error, *) { raise error }
