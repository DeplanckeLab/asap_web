# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class SessionCookieGateTest < TestBaseWithoutFixtures
  class MemoryRedis
    def initialize
      @store = {}
    end

    def setex(key, _ttl, value)
      @store[key] = value
    end

    def get(key)
      @store[key]
    end

    def del(key)
      @store.delete(key)
    end

    def set(key, value)
      @store[key] = value
    end

    def exists(key)
      @store.key?(key) ? 1 : 0
    end
  end

  setup do
    @previous_redis = SessionCookieGate.instance_variable_get(:@redis)
    @previous_flag = ENV['SESSION_COOKIE_UNARCHIVE_CHALLENGE']
    SessionCookieGate.instance_variable_set(:@redis, MemoryRedis.new)
  end

  teardown do
    SessionCookieGate.instance_variable_set(:@redis, @previous_redis)
    if @previous_flag.nil?
      ENV.delete('SESSION_COOKIE_UNARCHIVE_CHALLENGE')
    else
      ENV['SESSION_COOKIE_UNARCHIVE_CHALLENGE'] = @previous_flag
    end
  end

  test 'challenge_required is false for search engines even on archived file views' do
    assert_not SessionCookieGate.challenge_required?(
      enabled: true,
      search_engine: true,
      archived: true,
      project_show: true,
      metadata_only: false,
      force_unarchive: true
    )
  end

  test 'challenge_required is false for archived summary without force_unarchive' do
    assert_not SessionCookieGate.challenge_required?(
      enabled: true,
      search_engine: false,
      archived: true,
      project_show: true,
      metadata_only: true,
      force_unarchive: false
    )
  end

  test 'challenge_required is true when a human would unarchive' do
    assert SessionCookieGate.challenge_required?(
      enabled: true,
      search_engine: false,
      archived: true,
      project_show: true,
      metadata_only: false,
      force_unarchive: false
    )
    assert SessionCookieGate.challenge_required?(
      enabled: true,
      search_engine: false,
      archived: true,
      project_show: true,
      metadata_only: true,
      force_unarchive: true
    )
  end

  test 'challenge_required is false for non-archived projects' do
    assert_not SessionCookieGate.challenge_required?(
      enabled: true,
      search_engine: false,
      archived: false,
      project_show: true,
      metadata_only: false,
      force_unarchive: true
    )
  end

  test 'enabled? follows SESSION_COOKIE_UNARCHIVE_CHALLENGE' do
    ENV['SESSION_COOKIE_UNARCHIVE_CHALLENGE'] = '0'
    assert_not SessionCookieGate.enabled?

    ENV['SESSION_COOKIE_UNARCHIVE_CHALLENGE'] = '1'
    assert SessionCookieGate.enabled?
  end

  test 'solve_challenge accepts a drop on the target cell and rejects other cells' do
    ip = '203.0.113.9'
    challenge = SessionCookieGate.challenge_for(ip)

    assert_not SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      drop_col: challenge[:target_col] + 1,
      drop_row: challenge[:target_row]
    )

    challenge = SessionCookieGate.challenge_for(ip)
    assert SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      drop_col: challenge[:target_col],
      drop_row: challenge[:target_row]
    )
  end

  test 'solve_challenge rejects missing coordinates and spent nonces' do
    ip = '203.0.113.10'
    challenge = SessionCookieGate.challenge_for(ip)

    assert_not SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      drop_col: nil,
      drop_row: nil
    )

    assert SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      drop_col: challenge[:target_col],
      drop_row: challenge[:target_row]
    )

    assert_not SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      drop_col: challenge[:target_col],
      drop_row: challenge[:target_row]
    )
  end

  test 'piece start cell is never the drop target' do
    20.times do
      challenge = SessionCookieGate.challenge_for('203.0.113.11')
      assert_not_equal(
        [challenge[:target_col], challenge[:target_row]],
        [challenge[:piece_col], challenge[:piece_row]]
      )
    end
  end
end
