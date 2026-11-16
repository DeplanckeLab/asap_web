# frozen_string_literal: true

require 'test_helper'

# Deleting an account whose finished runs were archived to del_runs (foreign key del_runs.user_id).
class UserDestroyTest < ActiveSupport::TestCase
  test 'a user with finished runs can be destroyed and the archived runs are kept unlinked' do
    step = Step.find_by(name: 'parsing')
    skip 'parsing step missing' unless step
    skip 'success status missing' unless Status.exists?(id: 3)

    user = register_for_test_cleanup(
      User.create!(email: "udestroy_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id)
    run = Run.create!(
      project_id: project.id,
      step_id: step.id,
      status_id: 3,
      user_id: user.id,
      submitted_at: Time.now,
      attrs_json: '{}',
      command_json: '{}'
    )

    user.destroy!

    refute User.exists?(user.id)
    refute Project.exists?(project.id)
    archived = DelRun.where(run_id: run.id)
    assert archived.exists?, 'expected the finished run to be archived in del_runs'
    assert archived.all? { |row| row.user_id.nil? }
  ensure
    DelRun.where(run_id: run.id).delete_all if run
  end
end
