require "test_helper"

# Regression tests for unauthenticated analysis launch (reqs#create) and
# integration of projects the user cannot export.
class AnalysisAndIntegrateAuthorizationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = register_for_test_cleanup(
      User.create!(email: "authz_owner_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @attacker = register_for_test_cleanup(
      User.create!(email: "authz_attacker_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @private_a = create_test_project!(user_id: @owner.id, public: false)
    @private_b = create_test_project!(user_id: @owner.id, public: false)
  end

  test "anonymous cannot launch an analysis on a private project" do
    assert_no_difference -> { Req.count } do
      post reqs_path(format: :json), params: { project_key: @private_a.key, req: { step_id: 1, std_method_id: 1 } }
    end
    assert_response :forbidden
  end

  test "other user cannot launch an analysis on a private project" do
    sign_in @attacker
    assert_no_difference -> { Req.count } do
      post reqs_path(format: :json), params: { project_key: @private_a.key, req: { step_id: 1, std_method_id: 1 } }
    end
    assert_response :forbidden
  end

  test "anonymous cannot list reqs" do
    get reqs_path(format: :json)
    assert_response :redirect
  end

  test "prepare_integrate refuses projects the user cannot export" do
    sign_in @attacker
    post prepare_integrate_projects_path, params: { project_ids: [@private_a.id, @private_b.id] }, as: :json
    assert_response :forbidden
    refute_includes response.body, @private_a.key
  end

  test "new integrate form hides source projects the user cannot export" do
    sign_in @attacker
    get new_project_path(integrate: 1, source_keys: [@private_a.key, @private_b.key].join(','))
    # (Navigation links echo the request's own query string, so check the form fields.)
    assert_select "input[name='integrate_source_keys[]']", 0
    refute_includes response.body, @private_a.name
    refute_includes response.body, @private_b.name
  end

  test "create refuses integration of projects the user cannot export" do
    sign_in @attacker
    assert_no_difference -> { Project.count } do
      post projects_path, params: {
        integrate: '1',
        integrate_method: 'harmony',
        integrate_source_keys: [@private_a.key, @private_b.key],
        project: { name: 'stolen' }
      }
    end
    assert_response :forbidden
  end
end
