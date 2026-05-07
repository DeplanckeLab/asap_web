# frozen_string_literal: true

require "test_helper"
require_relative "../services/test_base_without_fixtures"
require_relative "../support/session_cookie_gate_test_redis"

class SessionCookieChallengeTest < IntegrationTestWithoutFixtures
  setup do
    SessionCookieGate.remove_instance_variable(:@redis) if SessionCookieGate.instance_variable_defined?(:@redis)
    SessionCookieGate.instance_variable_set(:@redis, SessionCookieGateTestRedis.new)
  end

  teardown do
    SessionCookieGate.remove_instance_variable(:@redis) if SessionCookieGate.instance_variable_defined?(:@redis)
  end

  test "solve returns JSON ok when puzzle is correct" do
    ip = "127.0.0.1"
    challenge = SessionCookieGate.challenge_for(ip)
    SessionCookieGate.block!(ip)

    cell = challenge.fetch(:cell_size)
    xc = challenge.fetch(:target_col) * cell
    yc = challenge.fetch(:target_row) * cell

    assert SessionCookieGate.blocked?(ip)

    post "/security/session_cookie_challenge/solve",
      params: { nonce: challenge[:nonce], x: xc, y: yc },
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]

    assert_not SessionCookieGate.blocked?(ip)
  end

  test "solve returns JSON failure when puzzle is wrong" do
    ip = "127.0.0.1"
    challenge = SessionCookieGate.challenge_for(ip)

    cell = challenge.fetch(:cell_size)
    off_x = challenge.fetch(:target_col) * cell + cell + 1
    off_y = challenge.fetch(:target_row) * cell + cell + 1

    post "/security/session_cookie_challenge/solve",
      params: { nonce: challenge[:nonce], x: off_x, y: off_y },
      as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["ok"]
  end
end
