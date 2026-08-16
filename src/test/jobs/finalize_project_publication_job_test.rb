# frozen_string_literal: true

require 'test_helper'

class FinalizeProjectPublicationJobTest < ActiveSupport::TestCase
  def with_replaced_singleton(mod, method_name, impl)
    original = mod.method(method_name)
    mod.define_singleton_method(method_name, &impl)
    yield
  ensure
    mod.define_singleton_method(method_name, original)
  end

  test 'perform no-ops when project is not being_published' do
    user = register_for_test_cleanup(
      User.create!(email: "finpub_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom', public: false)

    called = false
    with_replaced_singleton(ProjectPublicationService, :continue!, lambda { |*|
      called = true
      { status: 'noop' }
    }) do
      FinalizeProjectPublicationJob.perform_now(project.id)
    end

    refute called
  end

  test 'perform continues publication when being_published' do
    user = register_for_test_cleanup(
      User.create!(email: "finpub2_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom', public: false)
    project.start_publishing!

    continued_ids = []
    with_replaced_singleton(ProjectPublicationService, :continue!, lambda { |proj, **|
      continued_ids << proj.id
      { status: 'waiting' }
    }) do
      FinalizeProjectPublicationJob.perform_now(project.id)
    end

    assert_equal [project.id], continued_ids
  end
end
