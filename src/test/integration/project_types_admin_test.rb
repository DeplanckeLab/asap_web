# frozen_string_literal: true

require 'test_helper'

class ProjectTypesAdminTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @previous_admin_emails = ENV['ADMIN_EMAILS']
    @admin_email = "ptype_admin_#{SecureRandom.hex(4)}@example.com"
    ENV['ADMIN_EMAILS'] = @admin_email
    @admin = register_for_test_cleanup(
      User.create!(email: @admin_email, password: 'password123')
    )
    @user = register_for_test_cleanup(
      User.create!(email: "ptype_user_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @ptype = register_for_test_cleanup(
      ProjectType.create!(
        name: "Admin list type #{SecureRandom.hex(4)}",
        tag: "al#{SecureRandom.hex(3)}",
        row_label: 'genes',
        col_label: 'cells',
        admin_report_only: false
      )
    )
  end

  teardown do
    set_or_delete_env('ADMIN_EMAILS', @previous_admin_emails)
  end

  test 'admin menu includes project types' do
    sign_in @admin
    get project_types_path
    assert_response :success
    assert_select "a[href='#{project_types_path}']", text: /Project types/
  end

  test 'admin on writable instance sees public and private counts plus edit and delete' do
    2.times { create_test_project!(project_type_id: @ptype.id, public: true) }
    create_test_project!(project_type_id: @ptype.id, public: false)
    unused = register_for_test_cleanup(
      ProjectType.create!(
        name: "Unused type #{SecureRandom.hex(4)}",
        tag: "un#{SecureRandom.hex(3)}"
      )
    )

    sign_in @admin
    get project_types_path
    assert_response :success

    assert_select "tr[data-project-type-id='#{@ptype.id}']" do
      assert_select "[data-role='public-projects-count']", text: '2'
      assert_select "[data-role='private-projects-count']", text: '1'
      assert_select "a[href='#{edit_project_type_path(@ptype)}']", text: 'Edit details'
      assert_select "form[action='#{project_type_path(@ptype)}']", count: 0
    end

    assert_select "tr[data-project-type-id='#{unused.id}']" do
      assert_select "[data-role='public-projects-count']", text: '0'
      assert_select "[data-role='private-projects-count']", text: '0'
      assert_select "a[href='#{edit_project_type_path(unused)}']", text: 'Edit details'
      assert_select "form[action='#{project_type_path(unused)}']"
    end
  end

  test 'non-admin does not see counts or mutation buttons and cannot edit' do
    create_test_project!(project_type_id: @ptype.id, public: false)

    sign_in @user
    get project_types_path
    assert_response :success
    assert_select "[data-role='public-projects-count']", count: 0
    assert_select "[data-role='private-projects-count']", count: 0
    assert_select "a[href='#{edit_project_type_path(@ptype)}']", count: 0
    assert_select "form[action='#{project_type_path(@ptype)}']", count: 0

    get edit_project_type_path(@ptype)
    assert_redirected_to unauthorized_path
  end

  test 'admin on production cannot see or use edit and delete' do
    unused = register_for_test_cleanup(
      ProjectType.create!(
        name: "Prod unused #{SecureRandom.hex(4)}",
        tag: "pu#{SecureRandom.hex(3)}"
      )
    )

    with_synced_reference_data_writable(false) do
      sign_in @admin
      get project_types_path
      assert_response :success
      assert_select "tr[data-project-type-id='#{unused.id}']" do
        assert_select "[data-role='public-projects-count']", text: '0'
        assert_select "a[href='#{edit_project_type_path(unused)}']", count: 0
        assert_select "form[action='#{project_type_path(unused)}']", count: 0
      end

      get edit_project_type_path(unused)
      assert_response :redirect

      patch project_type_path(unused), params: { project_type: { name: 'Should not save' } }
      assert_response :redirect
      unused.reload
      refute_equal 'Should not save', unused.name

      assert_no_difference('ProjectType.count') do
        delete project_type_path(unused)
      end
    end
  end

  test 'admin can delete an unused type and cannot delete a type with projects' do
    unused = register_for_test_cleanup(
      ProjectType.create!(
        name: "Deletable type #{SecureRandom.hex(4)}",
        tag: "dl#{SecureRandom.hex(3)}"
      )
    )
    create_test_project!(project_type_id: @ptype.id, public: false)

    sign_in @admin
    assert_no_difference('ProjectType.count') do
      delete project_type_path(@ptype)
    end
    assert_redirected_to project_types_path
    follow_redirect!
    assert_match(/projects still use this type/, response.body)
    assert ProjectType.exists?(@ptype.id)

    assert_difference('ProjectType.count', -1) do
      delete project_type_path(unused)
    end
    assert_redirected_to project_types_path
    refute ProjectType.exists?(unused.id)
  end

  private

  def with_synced_reference_data_writable(value)
    ApplicationController.class_eval do
      alias_method :__orig_synced_reference_data_writable?, :synced_reference_data_writable?
      define_method(:synced_reference_data_writable?) { value }
    end
    yield
  ensure
    ApplicationController.class_eval do
      alias_method :synced_reference_data_writable?, :__orig_synced_reference_data_writable?
      remove_method :__orig_synced_reference_data_writable?
    end
  end

  def set_or_delete_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
