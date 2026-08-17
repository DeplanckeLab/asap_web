# frozen_string_literal: true

require 'test_helper'
require 'fileutils'

class GeneSetItemModuleScoreJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test 'perform writes scores and marks request completed' do
    user = register_for_test_cleanup(
      User.create!(email: "msjob_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom')
    request = register_for_test_cleanup(
      ModuleScoreRequest.create!(
        request_id: SecureRandom.uuid,
        project_id: project.id,
        user_id: user.id,
        item_id: 'local_collection:1:item',
        loom_file: 'parsing/output.loom',
        dataset: '/matrix',
        status: 'pending'
      )
    )

    calculator = Object.new
    def calculator.call
      [1.0, 2.0, 3.0]
    end

    GeneSetItemModuleScore.stub(:new, ->(_request) { calculator }) do
      GeneSetItemModuleScoreJob.perform_now(request.id)
    end

    request.reload
    assert_equal 'completed', request.status
    assert_equal [1.0, 2.0, 3.0], request.read_scores
  ensure
    FileUtils.rm_f(request.result_path) if request&.result_path.present?
  end

  test 'perform skips canceled requests' do
    user = register_for_test_cleanup(
      User.create!(email: "mscancel_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom')
    request = register_for_test_cleanup(
      ModuleScoreRequest.create!(
        request_id: SecureRandom.uuid,
        project_id: project.id,
        user_id: user.id,
        item_id: '1',
        loom_file: 'parsing/output.loom',
        dataset: '/matrix',
        status: 'canceled'
      )
    )

    called = false
    GeneSetItemModuleScore.stub(:new, ->(*) { called = true }) do
      GeneSetItemModuleScoreJob.perform_now(request.id)
    end
    refute called
    assert_equal 'canceled', request.reload.status
  end
end
