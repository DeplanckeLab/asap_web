require "test_helper"

class ComplianceChannelAuthTest < ActionCable::Channel::TestCase
  tests ComplianceChannel

  setup do
    @owner = register_for_test_cleanup(
      User.create!(email: "cc_owner_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(user_id: @owner.id, public: false)
  end

  test "rejects anonymous subscription to a private project's compliance stream" do
    stub_connection current_user: nil, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe project_id: @project.id
    assert subscription.rejected?
  end

  test "confirms owner" do
    stub_connection current_user: @owner, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe project_id: @project.id
    assert subscription.confirmed?
    assert_has_stream "compliance_#{@project.id}"
  end
end

class FuChannelAuthTest < ActionCable::Channel::TestCase
  tests FuChannel

  setup do
    @owner = register_for_test_cleanup(
      User.create!(email: "fu_owner_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @other = register_for_test_cleanup(
      User.create!(email: "fu_other_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @fu = register_for_test_cleanup(Fu.create!(user_id: @owner.id, upload_file_name: 'x.loom'))
  end

  test "rejects anonymous and other users" do
    stub_connection current_user: nil, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe fu_id: @fu.id
    assert subscription.rejected?

    stub_connection current_user: @other, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe fu_id: @fu.id
    assert subscription.rejected?
  end

  test "confirms owner" do
    stub_connection current_user: @owner, sandbox_key: nil, remote_ip: '127.0.0.1'
    subscribe fu_id: @fu.id
    assert subscription.confirmed?
    assert_has_stream "fu_#{@fu.id}"
  end

  test "confirms guest for sandbox upload with matching key only" do
    guest_fu = register_for_test_cleanup(Fu.create!(user_id: nil, project_key: 'sbx123', upload_file_name: 'x.loom'))
    stub_connection current_user: nil, sandbox_key: 'sbx123', remote_ip: '127.0.0.1'
    subscribe fu_id: guest_fu.id
    assert subscription.confirmed?

    stub_connection current_user: nil, sandbox_key: 'other1', remote_ip: '127.0.0.1'
    subscribe fu_id: guest_fu.id
    assert subscription.rejected?
  end
end
