# frozen_string_literal: true

require "test_helper"
require_relative "test_base_without_fixtures"
require_relative "../support/session_cookie_gate_test_redis"

class SessionCookieGateTest < TestBaseWithoutFixtures
  include ActiveSupport::Testing::TimeHelpers

  setup do
    SessionCookieGate.remove_instance_variable(:@redis) if SessionCookieGate.instance_variable_defined?(:@redis)
    @redis = SessionCookieGateTestRedis.new
    SessionCookieGate.instance_variable_set(:@redis, @redis)
  end

  teardown do
    SessionCookieGate.remove_instance_variable(:@redis) if SessionCookieGate.instance_variable_defined?(:@redis)
  end

  test "strike reaches two after debounce gap parallel burst does not double count" do
    ip = "198.51.100.42"
    strike_key = "#{SessionCookieGate::STRIKE_KEY_PREFIX}:#{ip}"
    tick_key = "#{SessionCookieGate::STRIKE_KEY_PREFIX}:tick:#{ip}"

    assert_equal 1, SessionCookieGate.increment_strike(ip)
    assert_equal 1, @redis.exists(strike_key)

    assert_equal 1, SessionCookieGate.increment_strike(ip),
                 "immediate second cookieless burst should reuse first strike score"

    travel (SessionCookieGate::STRIKE_DEBOUNCE_SECONDS + 1) do
      assert_equal 2, SessionCookieGate.increment_strike(ip)
    end

    SessionCookieGate.block!(ip)
    SessionCookieGate.clear_strikes!(ip)

    block_key = "#{SessionCookieGate::BLOCK_KEY_PREFIX}:#{ip}"
    assert_equal 1, @redis.exists(block_key), "blocked key missing"
    assert_equal 0, @redis.exists(strike_key), "strikes key should have been cleared"
    assert_equal 0, @redis.exists(tick_key), "strike tick key should have been cleared"
  end

  test "solve_challenge unbans inside target rectangle" do
    ip = "2001:db8::1"

    challenge = SessionCookieGate.challenge_for(ip)
    assert challenge[:nonce].present?
    SessionCookieGate.block!(ip)

    cell = challenge.fetch(:cell_size)
    xc = challenge.fetch(:target_col) * cell
    yc = challenge.fetch(:target_row) * cell

    assert SessionCookieGate.blocked?(ip)

    solved = SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      click_x: xc,
      click_y: yc
    )
    assert solved, "solve should succeed for click inside tile"
    assert_not SessionCookieGate.blocked?(ip), "solve should remove block"

    assert_equal 1, SessionCookieGate.increment_strike(ip), "strike counter resets after solve path unban"
  end

  test "solve_challenge fails outside target and consumes challenge" do
    ip = "192.0.2.77"

    challenge = SessionCookieGate.challenge_for(ip)
    cell = challenge.fetch(:cell_size)
    off_x = challenge.fetch(:target_col) * cell + cell + 5
    off_y = challenge.fetch(:target_row) * cell + cell + 5

    solved = SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      click_x: off_x,
      click_y: off_y
    )
    assert_equal false, solved

    solved_again = SessionCookieGate.solve_challenge!(
      ip,
      nonce: challenge[:nonce],
      click_x: off_x,
      click_y: off_y
    )
    assert_equal false, solved_again, "challenge should be consumed after failure"
  end
end
