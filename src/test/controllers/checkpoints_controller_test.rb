# frozen_string_literal: true

require 'test_helper'

class CheckpointsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = register_for_test_cleanup(
      User.create!(email: "ckpt_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Checkpoint current',
      key: "ckp#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: false
    )
    sign_in @user
  end

  def create_current_checkpoint!
    register_for_test_cleanup(
      Checkpoint.create!(
        project: @project,
        user: @user,
        title: Checkpoint::CURRENT_VISUALIZATION_TITLE,
        kind: Checkpoint::KIND_VISUALIZATION,
        state: { 'version' => 1, 'coloring' => { 'metadataId' => 'zika' } }
      )
    )
  end

  test 'index includes current auto checkpoint separately from named checkpoints' do
    current = create_current_checkpoint!
    named = register_for_test_cleanup(
      Checkpoint.create!(
        project: @project,
        user: @user,
        title: 'Named view',
        kind: Checkpoint::KIND_VISUALIZATION,
        state: { 'version' => 1 }
      )
    )

    get project_checkpoints_path(@project), as: :json
    assert_response :success
    body = JSON.parse(response.body)
    ids = body.fetch('checkpoints').map { |row| row['id'] }
    refute_includes ids, current.id
    assert_includes ids, named.id
    assert_equal current.id, body.dig('current_checkpoint', 'id')
    assert_equal Checkpoint::CURRENT_VISUALIZATION_TITLE, body.dig('current_checkpoint', 'title')
  end

  test 'destroy_current removes the auto-saved visualization checkpoint' do
    current = create_current_checkpoint!
    delete current_project_checkpoints_path(@project), as: :json
    assert_response :success
    assert_nil Checkpoint.find_by(id: current.id)
  end

  test 'destroy_current succeeds when no current checkpoint exists' do
    delete current_project_checkpoints_path(@project), as: :json
    assert_response :success
  end

  test 'owner can update another users uncommented checkpoint state' do
    colleague = register_for_test_cleanup(
      User.create!(email: "ckpt_col_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    checkpoint = register_for_test_cleanup(
      Checkpoint.create!(
        project: @project,
        user: colleague,
        title: 'Shared draft',
        kind: Checkpoint::KIND_VISUALIZATION,
        state: { 'version' => 1, 'coloring' => { 'metadataId' => 'old' } }
      )
    )

    patch project_checkpoint_path(@project, checkpoint),
          params: { checkpoint: { state: { 'version' => 2, 'coloring' => { 'metadataId' => 'new' } } } },
          as: :json

    assert_response :success
    checkpoint.reload
    assert_equal 2, checkpoint.state['version']
    assert_equal 'new', checkpoint.state.dig('coloring', 'metadataId')
    assert_equal colleague.id, checkpoint.user_id
  end

  test 'cannot update checkpoint state when comments exist' do
    checkpoint = register_for_test_cleanup(
      Checkpoint.create!(
        project: @project,
        user: @user,
        title: 'Discussed view',
        kind: Checkpoint::KIND_VISUALIZATION,
        state: { 'version' => 1 }
      )
    )
    checkpoint.comments = [{
      'id' => SecureRandom.uuid,
      'user_id' => @user.id,
      'user_name' => @user.email,
      'body' => 'Keep this view',
      'created_at' => Time.current.iso8601
    }]
    checkpoint.save!

    patch project_checkpoint_path(@project, checkpoint),
          params: { checkpoint: { state: { 'version' => 2 } } },
          as: :json

    assert_response :unprocessable_entity
    assert_equal 1, checkpoint.reload.state['version']
  end

  test 'can add a comment to a checkpoint that already has comments' do
    checkpoint = register_for_test_cleanup(
      Checkpoint.create!(
        project: @project,
        user: @user,
        title: 'Discussed view',
        kind: Checkpoint::KIND_VISUALIZATION,
        state: { 'version' => 1 }
      )
    )
    checkpoint.comments = [{
      'id' => SecureRandom.uuid,
      'user_id' => @user.id,
      'user_name' => @user.email,
      'body' => 'First',
      'created_at' => Time.current.iso8601
    }]
    checkpoint.save!

    patch project_checkpoint_path(@project, checkpoint),
          params: { checkpoint: { comment_body: 'Second' } },
          as: :json

    assert_response :success
    assert_equal 2, checkpoint.reload.comments.length
    assert_equal 1, checkpoint.state['version']
  end
end
