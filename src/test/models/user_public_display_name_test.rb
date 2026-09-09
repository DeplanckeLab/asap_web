# frozen_string_literal: true

require 'test_helper'

class UserPublicDisplayNameTest < ActiveSupport::TestCase
  test 'guest sandbox account public_display_name is guest' do
    guest = User.find_by(id: User::GUEST_SANDBOX_USER_ID)
    skip 'guest sandbox user missing' unless guest

    assert guest.guest_account?
    assert_equal 'guest', guest.public_display_name
    assert_equal 'me', guest.public_display_name(viewer: guest)
  end

  test 'non-guest public_display_name uses displayed_name' do
    user = User.new(
      email: 'someone@example.com',
      displayed_name: 'Someone',
      password: 'password123',
      password_confirmation: 'password123'
    )
    user.id = User::GUEST_SANDBOX_USER_ID + 100

    refute user.guest_account?
    assert_equal 'Someone', user.public_display_name
    assert_equal 'me', user.public_display_name(viewer: user)
  end
end
