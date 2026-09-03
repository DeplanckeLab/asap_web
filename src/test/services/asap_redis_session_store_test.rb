# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class AsapRedisSessionStoreTest < TestBaseWithoutFixtures
  setup do
    @redis = Redis.new(url: ENV.fetch('REDIS_SESSION_URL'))
    @prefix = "asap:session:test:#{SecureRandom.hex(4)}:"
    @store = AsapRedisSessionStore.new(
      ->(_env) { [200, {}, ['ok']] },
      key: '_app_session',
      redis: {
        client: @redis,
        key_prefix: @prefix,
        ttl: 60
      }
    )
  end

  teardown do
    keys = @redis.keys("#{@prefix}*")
    @redis.del(*keys) if keys.any?
  end

  test 'reuses presented session id when redis key was deleted' do
    sid = Rack::Session::SessionId.new(SecureRandom.hex(16))
    env = {
      'rack.session' => {},
      'rack.session.options' => {}
    }

    @store.send(:set_session, env, sid, { 'sandbox' => 'abc123' }, { ttl: 60 })
    assert @redis.exists?("#{@prefix}#{sid.private_id}")

    @redis.del("#{@prefix}#{sid.private_id}")
    assert_not @redis.exists?("#{@prefix}#{sid.private_id}")

    returned_sid, session = @store.send(:get_session, env, sid)

    assert_equal sid.public_id, returned_sid.public_id
    assert_equal({}, session.to_hash)
  end

  test 'mints a new session id only when no sid is presented' do
    env = { 'rack.session' => {}, 'rack.session.options' => {} }
    returned_sid, session = @store.send(:get_session, env, nil)

    assert returned_sid.present?
    assert_equal({}, session.to_hash)
  end
end
