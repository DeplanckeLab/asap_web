require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "update_archive_metadata does not touch updated_at" do
    project = projects(:one)
    original_updated_at = project.updated_at

    travel 1.second do
      project.update_archive_metadata!(archive_status_id: 3, disk_size_archived: 1234)
    end

    project.reload
    assert_equal 3, project.archive_status_id
    assert_equal 1234, project.disk_size_archived
    assert_equal original_updated_at, project.updated_at
  end

  test "update_archive_metadata rejects non-archive fields" do
    project = projects(:one)

    error = assert_raises(ArgumentError) do
      project.update_archive_metadata!(archive_status_id: 3, name: "bad")
    end

    assert_match(/Unsupported archive metadata fields/, error.message)
  end
end
