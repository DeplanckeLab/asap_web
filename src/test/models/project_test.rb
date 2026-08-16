require_relative "../services/test_base_without_fixtures"
require "fileutils"

class ProjectTest < TestBaseWithoutFixtures
  test "destroy removes project directory and local archive tgz under USER_DATA_DIR" do
    tmp_root = Dir.mktmpdir("project-destroy-fs")
    previous_user_data_dir = ENV["USER_DATA_DIR"]
    ENV["USER_DATA_DIR"] = File.join(tmp_root, "projects")
    FileUtils.mkdir_p(ENV["USER_DATA_DIR"])

    begin
      user = register_for_test_cleanup(
        User.create!(email: "proj_destroy_fs_#{SecureRandom.hex(4)}@example.com", password: "password123")
      )
      project = create_test_project!(
        name: "Destroy filesystem",
        key: "dfs#{SecureRandom.hex(3)}",
        user_id: user.id
      )

      project_dir = project.data_dir
      archive_file = Pathname.new("#{project_dir}.tgz")
      FileUtils.mkdir_p(project_dir + "fus" + "1")
      File.write(project_dir + "input_file", "data")
      File.write(archive_file, "tgz")

      assert File.directory?(project_dir.to_s)
      assert File.exist?(archive_file.to_s)

      project.destroy!
      @records_for_test_cleanup.delete(project)

      assert_not File.exist?(project_dir.to_s), "Expected project dir to be removed: #{project_dir}"
      assert_not File.exist?(archive_file.to_s), "Expected archive tgz to be removed: #{archive_file}"
    ensure
      ENV["USER_DATA_DIR"] = previous_user_data_dir
      FileUtils.rm_rf(tmp_root) if tmp_root.present?
    end
  end

  test "update_archive_metadata does not touch updated_at" do
    project = create_test_project!(name: "Archive metadata", key: "arc#{SecureRandom.hex(3)}")
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
    project = create_test_project!(name: "Archive reject", key: "rej#{SecureRandom.hex(3)}")

    error = assert_raises(ArgumentError) do
      project.update_archive_metadata!(archive_status_id: 3, name: "bad")
    end

    assert_match(/Unsupported archive metadata fields/, error.message)
  end

  test "archive_availability_state distinguishes archived from plain missing data" do
    project = create_test_project!(name: "Archive state", key: "sta#{SecureRandom.hex(3)}")

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
    assert project.being_unarchived?
    assert_not project.being_archived?

    project.archive_status_id = 2
    assert_equal :archiving, project.archive_availability_state
    assert project.being_archived?
    assert_not project.being_unarchived?
    assert_equal "archiving", project.unarchive_client_state
  end

  test "key must be unique" do
    key = "uniq#{SecureRandom.hex(3)}"
    create_test_project!(name: "First", key: key, user_id: 1)
    duplicate = Project.new(name: "Second", key: key, user_id: 1)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "generate_unique_key returns an unused key" do
    taken_key = "taken#{SecureRandom.hex(3)}"
    create_test_project!(name: "Taken", key: taken_key, user_id: 1)

    key = Project.generate_unique_key

    assert_not Project.exists?(key: key)
    assert_equal 6, key.length
  end
end
