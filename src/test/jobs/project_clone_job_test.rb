# frozen_string_literal: true

require 'test_helper'

class ProjectCloneJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test 'perform no-ops when destination is not being cloned' do
    user = register_for_test_cleanup(
      User.create!(email: "clonejob_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom', being_cloned: false)
    called = false
    ProjectCloneService.stub(:new, ->(*) { called = true; raise 'should not build service' }) do
      ProjectCloneJob.perform_now(project.id)
    end
    refute called
  end
end
