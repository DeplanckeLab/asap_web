require "test_helper"

class ProjectChannelTest < ActionCable::Channel::TestCase
  setup do
    @owner = register_for_test_cleanup(
      User.create!(email: "chan_owner_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @other = register_for_test_cleanup(
      User.create!(email: "chan_other_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @private_project = create_test_project!(user_id: @owner.id, public: false)
  end

  test "rejects anonymous subscription to a private project" do
    stub_connection current_user: nil, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe project_id: @private_project.id
    assert subscription.rejected?
  end

  test "rejects another user's subscription to a private project" do
    stub_connection current_user: @other, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe project_id: @private_project.id
    assert subscription.rejected?
  end

  test "confirms owner subscription" do
    stub_connection current_user: @owner, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe project_id: @private_project.id
    assert subscription.confirmed?
    assert_has_stream "project_#{@private_project.id}"
  end

  test "confirms anonymous subscription to a public project" do
    public_project = create_test_project!(user_id: @owner.id, public: true)
    stub_connection current_user: nil, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe project_id: public_project.id
    assert subscription.confirmed?
  end

  test "confirms guest subscription to their own sandbox only" do
    sandbox = create_test_project!(user_id: 1, public: false, sandbox: true)
    stub_connection current_user: nil, sandbox_key: sandbox.key, remote_ip: '127.0.0.1'
    subscribe project_id: sandbox.id
    assert subscription.confirmed?

    stub_connection current_user: nil, sandbox_key: 'zzzzzz', remote_ip: '127.0.0.1'
    subscribe project_id: sandbox.id
    assert subscription.rejected?
  end

  test "rejects unknown project id" do
    stub_connection current_user: @owner, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe project_id: 0
    assert subscription.rejected?
  end
end
