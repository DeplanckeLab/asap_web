# frozen_string_literal: true

require 'test_helper'

class ProjectTogglePublicPublicationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def with_replaced_singleton(mod, method_name, impl)
    original = mod.method(method_name)
    mod.define_singleton_method(method_name, &impl)
    yield
  ensure
    mod.define_singleton_method(method_name, original)
  end

  setup do
    @user = register_for_test_cleanup(
      User.create!(email: "togpub_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(user_id: @user.id, input_filename: 'input_file.loom', public: false)
    sign_in @user
  end

  test 'toggle_public start does not set public immediately when waiting on exports' do
    original = Project.instance_method(:can_be_public?)
    Project.define_method(:can_be_public?) { [true, nil] }
    begin
      with_replaced_singleton(
        ProjectPublicationService,
        :start!,
        lambda { |project, **|
          project.start_publishing!
          { status: 'waiting' }
        }
      ) do
        post toggle_public_project_path(@project),
             params: { public: true },
             as: :json
      end
    ensure
      Project.define_method(:can_be_public?, original)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body['success']
    assert body['being_published']
    refute body['public']

    @project.reload
    refute @project.public?
    assert @project.publishing?
  end

  test 'toggle_public cancel clears being_published' do
    @project.start_publishing!

    post toggle_public_project_path(@project),
         params: { public: false },
         as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body['success']
    refute body['being_published']
    refute body['public']

    @project.reload
    refute @project.publishing?
    refute @project.public?
  end
end
