# frozen_string_literal: true

require 'test_helper'

class ProjectTransferOwnershipTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = register_for_test_cleanup(
      User.create!(email: "xfer_int_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @new_owner = register_for_test_cleanup(
      User.create!(email: "xfer_new_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @other = register_for_test_cleanup(
      User.create!(email: "xfer_oth_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(user_id: @owner.id, name: 'Transfer integration')
    sign_in @owner
  end

  test 'owner can transfer the project after confirmation' do
    post transfer_ownership_project_path(@project),
         params: {
           email: @new_owner.email,
           confirm: true,
           transfer: { runs: false }
         },
         as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body['success']
    assert_equal @new_owner.email, body['new_owner_email']
    assert_equal @new_owner.id, @project.reload.user_id
  end

  test 'rejects transfer without confirmation' do
    post transfer_ownership_project_path(@project),
         params: { email: @new_owner.email, confirm: false },
         as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    refute body['success']
    assert_match(/not confirmed/, body['error'])
    assert_equal @owner.id, @project.reload.user_id
  end

  test 'shared user cannot transfer ownership' do
    register_for_test_cleanup(
      Share.create!(
        project_id: @project.id,
        user_id: @other.id,
        email: @other.email,
        view_perm: true,
        analyze_perm: true,
        export_perm: true
      )
    )
    sign_in @other

    post transfer_ownership_project_path(@project),
         params: { email: @new_owner.email, confirm: true },
         as: :json

    assert_response :forbidden
    assert_equal @owner.id, @project.reload.user_id
  end
end
