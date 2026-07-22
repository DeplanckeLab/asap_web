require_relative "../services/test_base_without_fixtures"

class ProjectTest < TestBaseWithoutFixtures
  test "update_archive_metadata does not touch updated_at" do
    project = Project.create!(name: "Archive metadata", key: "arc#{SecureRandom.hex(3)}")
    original_updated_at = project.updated_at

    travel 1.second do
      project.update_archive_metadata!(archive_status_id: 3, disk_size_archived: 1234)
    end

    project.reload
    assert_equal 3, project.archive_status_id
    assert_equal 1234, project.disk_size_archived
    assert_equal original_updated_at.to_i, project.updated_at.to_i
  end

  test "update_archive_metadata rejects non-archive fields" do
    project = Project.create!(name: "Archive reject", key: "rej#{SecureRandom.hex(3)}")

    error = assert_raises(ArgumentError) do
      project.update_archive_metadata!(archive_status_id: 3, name: "bad")
    end

    assert_match(/Unsupported archive metadata fields/, error.message)
  end

  test "archive_availability_state distinguishes archived from plain missing data" do
    project = Project.create!(name: "Archive state", key: "sta#{SecureRandom.hex(3)}")

    project.archive_status_id = 1
    project.define_singleton_method(:filesystem_project_data_missing?) { true }
    project.define_singleton_method(:archive_restore_expected?) { false }
    assert_equal :missing, project.archive_availability_state

    project.archive_status_id = 1
    project.define_singleton_method(:filesystem_project_data_missing?) { true }
    project.define_singleton_method(:archive_restore_expected?) { true }
    assert_equal :archived, project.archive_availability_state

    project.archive_status_id = 3
    project.define_singleton_method(:filesystem_project_data_missing?) { false }
    project.define_singleton_method(:archive_restore_expected?) { false }
    assert_equal :archived, project.archive_availability_state

    project.archive_status_id = 4
    assert_equal :unarchiving, project.archive_availability_state

    project.archive_status_id = 2
    assert_equal :archiving, project.archive_availability_state
  end

  test "key must be unique" do
    key = "uniq#{SecureRandom.hex(3)}"
    Project.create!(name: "First", key: key, user_id: 1)
    duplicate = Project.new(name: "Second", key: key, user_id: 1)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "generate_unique_key returns an unused key" do
    taken_key = "taken#{SecureRandom.hex(3)}"
    Project.create!(name: "Taken", key: taken_key, user_id: 1)

    key = Project.generate_unique_key

    assert_not Project.exists?(key: key)
    assert_equal 6, key.length
  end
end
