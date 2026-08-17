# frozen_string_literal: true

require 'test_helper'

class ArchiveProjectJobTest < ActiveSupport::TestCase
  def with_replaced_singleton(mod, method_name, impl)
    original = mod.method(method_name)
    mod.define_singleton_method(method_name, &impl)
    yield
  ensure
    mod.define_singleton_method(method_name, original)
  end

  test 'perform no-ops when project is missing' do
    called = false
    with_replaced_singleton(ProjectS3Archive, :archive!, lambda { |*|
      called = true
      :archived
    }) do
      ArchiveProjectJob.perform_now(-1)
    end

    refute called
  end

  test 'perform archives the project' do
    user = register_for_test_cleanup(
      User.create!(email: "archjob_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom')
    archived_ids = []

    with_replaced_singleton(ProjectS3Archive, :archive!, lambda { |proj, **|
      archived_ids << proj.id
      :archived
    }) do
      ArchiveProjectJob.perform_now(project.id)
    end

    assert_equal [project.id], archived_ids
  end
end
