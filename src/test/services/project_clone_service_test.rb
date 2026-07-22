require_relative "test_base_without_fixtures"
require "fileutils"

class ProjectCloneServiceTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir("project-clone-service")
    @previous_user_data_dir = ENV["USER_DATA_DIR"]
    ENV["USER_DATA_DIR"] = File.join(@tmp_root, "projects")
    FileUtils.mkdir_p(ENV["USER_DATA_DIR"])
  end

  teardown do
    ENV["USER_DATA_DIR"] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test "clone keeps shared fu_id and copies fus directory under new project key" do
    user = User.create!(email: "clone_fu_#{SecureRandom.hex(4)}@example.com", password: "password123")
    source = Project.create!(
      name: "Source project",
      key: "src#{SecureRandom.hex(3)}",
      user_id: user.id
    )
    source_fu = Fu.create!(
      project_id: source.id,
      project_key: source.key,
      user_id: user.id,
      upload_file_name: "input_file.rds",
      upload_file_size: 4,
      status: "completed"
    )
    source.update_columns(fu_id: source_fu.id)

    source_upload_dir = source_fu.upload_dir
    FileUtils.mkdir_p(source_upload_dir)
    File.write(source_upload_dir + source_fu.upload_file_name, "test")

    source_dir = Pathname.new(ENV["USER_DATA_DIR"]) + user.id.to_s + source.key
    FileUtils.mkdir_p(source_dir + "fus" + source_fu.id.to_s)
    File.write(source_dir + "input_file.rds", "canonical")

    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.call
    assert clone, "Expected clone to succeed: #{service.errors.inspect}"

    assert_equal source_fu.id, clone.fu_id
    clone_upload_dir = source_fu.upload_dir_for_project(clone)
    assert File.exist?(clone_upload_dir + source_fu.upload_file_name),
           "Expected cloned upload file at #{clone_upload_dir}"
  end

  test "clone assigns a unique key even when source and clone share an owner" do
    user = User.create!(email: "clone_key_#{SecureRandom.hex(4)}@example.com", password: "password123")
    source = Project.create!(
      name: "Source project",
      key: "src#{SecureRandom.hex(3)}",
      user_id: user.id
    )

    source_dir = Pathname.new(ENV["USER_DATA_DIR"]) + user.id.to_s + source.key
    FileUtils.mkdir_p(source_dir)

    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.call
    assert clone, "Expected clone to succeed: #{service.errors.inspect}"

    assert_not_equal source.key, clone.key
    assert_not Project.where(key: source.key).where.not(id: source.id).exists?
  end

  test "upload_dir_for_project uses clone path when fu row points at source project" do
    user = User.create!(email: "fu_scope_#{SecureRandom.hex(4)}@example.com", password: "password123")
    source = Project.create!(name: "Scope source", key: "scp#{SecureRandom.hex(3)}", user_id: user.id)
    fu = Fu.create!(
      project_id: source.id,
      project_key: source.key,
      upload_file_name: "input_file.rds"
    )
    clone = Project.create!(
      name: "Scope clone",
      key: "cln#{SecureRandom.hex(3)}",
      user_id: user.id,
      fu_id: fu.id,
      cloned_project_id: source.id
    )

    source_dir = fu.upload_dir
    clone_dir = fu.upload_dir_for_project(clone)
    assert_includes source_dir.to_s, "/#{source.key}/fus/#{fu.id}"
    assert_includes clone_dir.to_s, "/#{clone.key}/fus/#{fu.id}"
    assert_not_equal source_dir.to_s, clone_dir.to_s
  end
end
