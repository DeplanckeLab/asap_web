require_relative "../services/test_base_without_fixtures"
require "fileutils"

class FuRehydrateTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir("fu-rehydrate")
    @previous_user_data_dir = ENV["USER_DATA_DIR"]
    ENV["USER_DATA_DIR"] = File.join(@tmp_root, "projects")
    FileUtils.mkdir_p(ENV["USER_DATA_DIR"])
  end

  teardown do
    ENV["USER_DATA_DIR"] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test "resolve_for_project rehydrates missing fu row from project fus directory" do
    user = register_for_test_cleanup(User.create!(email: "rehydrate_#{SecureRandom.hex(4)}@example.com", password: "password123"))
    fu_id = 900_000 + SecureRandom.random_number(99_999)
    project = create_test_project!(
      name: "Rehydrate project",
      key: "reh#{SecureRandom.hex(3)}",
      user_id: user.id,
      fu_id: fu_id
    )

    upload_dir = project.data_dir + "fus" + fu_id.to_s
    FileUtils.mkdir_p(upload_dir)
    File.write(upload_dir + "input_file.rds", "x" * 1024)

    assert_equal ["input_file.rds"], Dir.children(upload_dir.to_s)

    fu = Fu.resolve_for_project(project)
    assert fu, "Expected Fu to be rehydrated"
    register_for_test_cleanup(fu)
    assert_equal fu_id, fu.id
    assert_equal "input_file.rds", fu.upload_file_name
    assert_equal project.id, fu.project_id
  end
end
