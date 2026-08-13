# frozen_string_literal: true

require 'test_helper'

class HomeControllerAtlasGroupingTest < ActionDispatch::IntegrationTest
  test 'atlas projects are grouped by project collection with ungrouped fallback' do
    collection = register_for_test_cleanup(
      ProjectCollection.create_manual!(
        title: "Fly Cell Atlas Demo #{SecureRandom.hex(3)}",
        description: 'Grouped for atlas hierarchy test'
      )
    )
    grouped = create_test_project!(
      name: "FCA grouped #{SecureRandom.hex(3)}",
      key: "fca#{SecureRandom.hex(3)}",
      public: true,
      being_deleted: false,
      project_collection_id: collection.id
    )
    ungrouped = create_test_project!(
      name: "Fly Cell Atlas ungrouped #{SecureRandom.hex(3)}",
      key: "fcu#{SecureRandom.hex(3)}",
      public: true,
      being_deleted: false,
      project_collection_id: nil
    )

    get atlas_projects_path(atlas: 'fca')
    assert_response :success
    assert_match collection.title, response.body
    assert_match grouped.display_name, response.body
    assert_match 'Ungrouped', response.body
    assert_match ungrouped.display_name, response.body
  end
end
