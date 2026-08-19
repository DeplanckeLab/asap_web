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
    step = Step.first
    skip 'No Step available' unless step
    run = register_for_test_cleanup(
      Run.create!(project_id: @project.id, user_id: @owner.id, step_id: step.id, status_id: 1, num: 1)
    )

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
    assert_equal @new_owner.id, run.reload.user_id
  end

  test 'admin can leave owned records with the previous owner' do
    previous_admin_emails = ENV['ADMIN_EMAILS']
    ENV['ADMIN_EMAILS'] = @owner.email
    step = Step.first
    skip 'No Step available' unless step
    run = register_for_test_cleanup(
      Run.create!(project_id: @project.id, user_id: @owner.id, step_id: step.id, status_id: 1, num: 1)
    )

    post transfer_ownership_project_path(@project),
         params: {
           email: @new_owner.email,
           confirm: true,
           transfer: { runs: false }
         },
         as: :json

    assert_response :success
    assert_equal @new_owner.id, @project.reload.user_id
    assert_equal @owner.id, run.reload.user_id
  ensure
    if previous_admin_emails.nil?
      ENV.delete('ADMIN_EMAILS')
    else
      ENV['ADMIN_EMAILS'] = previous_admin_emails
    end
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
