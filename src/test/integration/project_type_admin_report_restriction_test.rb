# frozen_string_literal: true

require 'test_helper'

class ProjectTypeAdminReportRestrictionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @previous_admin_report_emails = ENV['ADMIN_REPORT_EMAILS']
    ProjectType::CANONICAL.each_key { |tag| ProjectType.ensure_for_tag!(tag) }
    ProjectType.where(tag: %w[spat atac multi]).update_all(admin_report_only: true)
    ProjectType.where(tag: %w[sc bulk]).update_all(admin_report_only: false)
    @restricted_names = ProjectType.where(admin_report_only: true).pluck(:name)
    @public_names = ProjectType.where(admin_report_only: false).pluck(:name)
    @spat = ProjectType.find_by!(tag: 'spat')
  end

  teardown do
    set_or_delete_env('ADMIN_REPORT_EMAILS', @previous_admin_report_emails)
  end

  test 'new project form hides spat atac multi for guests' do
    get new_project_path
    assert_response :success
    assert_public_project_types_visible
    assert_restricted_project_types_hidden
  end

  test 'new project form hides spat atac multi for signed-in users not in ADMIN_REPORT_EMAILS' do
    user = register_for_test_cleanup(
      User.create!(email: "ptype_user_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    ENV['ADMIN_REPORT_EMAILS'] = 'admin-report@example.com'
    sign_in user

    get new_project_path
    assert_response :success
    assert_public_project_types_visible
    assert_restricted_project_types_hidden
  end

  test 'new project form shows spat atac multi for ADMIN_REPORT_EMAILS users' do
    email = "ptype_admin_#{SecureRandom.hex(4)}@example.com"
    user = register_for_test_cleanup(
      User.create!(email: email, password: 'password123')
    )
    ENV['ADMIN_REPORT_EMAILS'] = email
    sign_in user

    get new_project_path
    assert_response :success
    assert_public_project_types_visible
    assert_restricted_project_types_visible
  end

  test 'create rejects restricted project type for users not in ADMIN_REPORT_EMAILS' do
    user = register_for_test_cleanup(
      User.create!(email: "ptype_create_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    ENV['ADMIN_REPORT_EMAILS'] = 'admin-report@example.com'
    sign_in user
    name = "Restricted type #{SecureRandom.hex(4)}"

    assert_no_difference('Project.count') do
      post projects_path, params: { project: { name: name, project_type_id: @spat.id } }
    end

    assert_response :unprocessable_entity
    assert_match(/Project type is not available/, response.body)
  end

  test 'clone of admin_report_only project is rejected for other users' do
    owner = register_for_test_cleanup(
      User.create!(email: "clone_owner_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    user = register_for_test_cleanup(
      User.create!(email: "clone_user_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    ENV['ADMIN_REPORT_EMAILS'] = 'admin-report@example.com'
    project = create_test_project!(
      name: "Clone deny #{SecureRandom.hex(4)}",
      key: "cdn#{SecureRandom.hex(3)}",
      user_id: owner.id,
      project_type_id: @spat.id,
      public: true
    )
    sign_in user

    assert_no_difference('Project.count') do
      post clone_project_path(project)
    end

    assert_redirected_to project_path(project)
    assert_equal "You don't have permission to clone this project.", flash[:alert]
  end

  test 'clone of admin_report_only project is not permission-denied for ADMIN_REPORT_EMAILS users' do
    email = "clone_admin_#{SecureRandom.hex(4)}@example.com"
    user = register_for_test_cleanup(
      User.create!(email: email, password: 'password123')
    )
    ENV['ADMIN_REPORT_EMAILS'] = email
    version = Version.where('id >= 4').order(:id).first
    skip 'no version >= 4' unless version
    project = create_test_project!(
      name: "Clone allow #{SecureRandom.hex(4)}",
      key: "cal#{SecureRandom.hex(3)}",
      user_id: user.id,
      project_type_id: @spat.id,
      public: true,
      version_id: version.id
    )
    sign_in user

    post clone_project_path(project)
    assert_not_equal "You don't have permission to clone this project.", flash[:alert]
    clone = Project.where(cloned_project_id: project.id).order(:id).last
    register_for_test_cleanup(clone) if clone
  end

  private

  def assert_public_project_types_visible
    @public_names.each do |name|
      assert_select 'select[name="project[project_type_id]"] option', text: name
    end
  end

  def assert_restricted_project_types_hidden
    @restricted_names.each do |name|
      assert_select 'select[name="project[project_type_id]"] option', text: name, count: 0
    end
  end

  def assert_restricted_project_types_visible
    @restricted_names.each do |name|
      assert_select 'select[name="project[project_type_id]"] option', text: name
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
