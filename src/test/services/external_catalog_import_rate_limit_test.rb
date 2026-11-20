# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ExternalCatalogImportRateLimitTest < TestBaseWithoutFixtures
  class MemoryRedis
    def initialize
      @store = {}
    end

    def setex(key, _ttl, value)
      @store[key] = value.to_s
    end

    def get(key)
      @store[key]
    end

    def del(key)
      @store.delete(key)
    end

    def exists(key)
      @store.key?(key) ? 1 : 0
    end

    def multi
      replies = []
      multi = Object.new
      store = @store
      multi.define_singleton_method(:incr) do |key|
        store[key] = (store[key].to_i + 1).to_s
        replies << store[key].to_i
      end
      multi.define_singleton_method(:expire) do |_key, _ttl|
        replies << true
      end
      yield multi
      replies
    end
  end

  setup do
    @previous_redis = ExternalCatalog::ImportRateLimit.instance_variable_get(:@redis)
    ExternalCatalog::ImportRateLimit.instance_variable_set(:@redis, MemoryRedis.new)
  end

  teardown do
    ExternalCatalog::ImportRateLimit.instance_variable_set(:@redis, @previous_redis)
  end

  test 'allows first guest start and blocks concurrent inflight' do
    first = ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.10', session_key: 'abc123')
    assert first.allowed?

    second = ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.10', session_key: 'abc123')
    assert_not second.allowed?
    assert_match(/already running/i, second.reason)

    ExternalCatalog::ImportRateLimit.release_inflight!(session_key: 'abc123')
    third = ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.10', session_key: 'abc123')
    assert third.allowed?
  end

  test 'blocks when session hourly limit is exceeded' do
    limit = ExternalCatalog::ImportRateLimit::SESSION_LIMIT
    limit.times do |i|
      key = 'sess-limit'
      result = ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: "203.0.113.#{30 + i}", session_key: key)
      assert result.allowed?, "expected allow ##{i + 1}: #{result.reason}"
      ExternalCatalog::ImportRateLimit.release_inflight!(session_key: key)
    end

    denied = ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.99', session_key: 'sess-limit')
    assert_not denied.allowed?
    assert_match(/session/i, denied.reason)
  end

  test 'a start replacing the session ongoing import is not blocked by its lock' do
    first = ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.20', session_key: 'swap', candidate_id: 11)
    assert first.allowed?

    other = ExternalCatalog::ImportRateLimit.allow_guest_start!(
      ip: '203.0.113.20', session_key: 'swap', candidate_id: 12, replacing_candidate_id: 99
    )
    refute other.allowed?

    replacing = ExternalCatalog::ImportRateLimit.allow_guest_start!(
      ip: '203.0.113.20', session_key: 'swap', candidate_id: 12, replacing_candidate_id: 11
    )
    assert replacing.allowed?
  end

  test 'the cancelled import finishing does not release the lock of the import that replaced it' do
    ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.21', session_key: 'swap2', candidate_id: 11)
    ExternalCatalog::ImportRateLimit.allow_guest_start!(
      ip: '203.0.113.21', session_key: 'swap2', candidate_id: 12, replacing_candidate_id: 11
    )

    ExternalCatalog::ImportRateLimit.release_inflight!(session_key: 'swap2', candidate_id: 11)
    refute ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.21', session_key: 'swap2', candidate_id: 13).allowed?

    ExternalCatalog::ImportRateLimit.release_inflight!(session_key: 'swap2', candidate_id: 12)
    assert ExternalCatalog::ImportRateLimit.allow_guest_start!(ip: '203.0.113.21', session_key: 'swap2', candidate_id: 13).allowed?
  end
end
