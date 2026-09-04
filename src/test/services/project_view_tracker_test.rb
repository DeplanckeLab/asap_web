# frozen_string_literal: true

require 'digest'
require 'test_helper'

class ProjectViewTrackerTest < ActiveSupport::TestCase
  test 'user token is short and stable' do
    user = Object.new
    def user.id
      42
    end

    assert_equal 'u:42', ProjectViewTracker.build_viewer_token(current_user: user, session_id: nil)
  end

  test 'guest token fits varchar 128 even when session id is huge' do
    huge_sid = "x" * 4000
    token = ProjectViewTracker.build_viewer_token(current_user: nil, session_id: huge_sid)

    assert token.start_with?('s:')
    assert_operator token.length, :<=, 128
    assert_equal 66, token.length
    assert_equal "s:#{Digest::SHA256.hexdigest(huge_sid)}", token
  end

  test 'guest token is stable for the same session id' do
    sid = SecureRandom.hex(64)
    a = ProjectViewTracker.build_viewer_token(current_user: nil, session_id: sid)
    b = ProjectViewTracker.build_viewer_token(current_user: nil, session_id: sid)
    assert_equal a, b
  end

  test 'guest token uses Rack session public_id when present' do
    sid = Rack::Session::SessionId.new(SecureRandom.hex(16))
    token = ProjectViewTracker.build_viewer_token(current_user: nil, session_id: sid)

    assert_equal "s:#{Digest::SHA256.hexdigest(sid.public_id)}", token
  end

  test 'blank guest session id raises' do
    assert_raises(ArgumentError) do
      ProjectViewTracker.build_viewer_token(current_user: nil, session_id: '')
    end
  end
end
