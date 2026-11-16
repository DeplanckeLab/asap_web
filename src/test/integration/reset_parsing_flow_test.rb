require "test_helper"
require "tmpdir"
require "fileutils"

class ResetParsingFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include Devise::Test::IntegrationHelpers

  setup do
    clear_enqueued_jobs
    clear_performed_jobs

    @tmp_root = Dir.mktmpdir("reset-parsing-flow")
    @previous_upload_data_dir = ENV["UPLOAD_DATA_DIR"]
    @previous_user_data_dir = ENV["USER_DATA_DIR"]

    ENV["UPLOAD_DATA_DIR"] = File.join(@tmp_root, "fus")
    ENV["USER_DATA_DIR"] = File.join(@tmp_root, "projects")
    FileUtils.mkdir_p(ENV["UPLOAD_DATA_DIR"])
    FileUtils.mkdir_p(ENV["USER_DATA_DIR"])

    # reset_parsing needs edit access: run it as the project owner.
    @owner = register_for_test_cleanup(
      User.create!(email: "reset_parsing_#{SecureRandom.hex(4)}@example.com", password: "password123")
    )
    @project = create_test_project!(
      name: "Reset parsing integration project",
      key: "reset_project_#{SecureRandom.hex(4)}",
      user_id: @owner.id,
      organism_id: nil,
      version_id: nil
    )
    sign_in @owner
  end

  teardown do
    # Destroy test-created DB rows while temp USER_DATA_DIR / UPLOAD_DATA_DIR are still set.
    destroy_registered_test_records!
    ENV["UPLOAD_DATA_DIR"] = @previous_upload_data_dir
    ENV["USER_DATA_DIR"] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
    clear_enqueued_jobs
    clear_performed_jobs
  end

  # Fu with a stale upload and preparsing output in fus/, and the canonical copy at the project root.
  def stage_reset_files
    fu = register_for_test_cleanup(
      Fu.create!(
        user_id: @owner.id,
        project_id: @project.id,
        project_key: @project.key,
        upload_file_name: "input_file.txt",
        upload_file_size: 3,
        status: "completed"
      )
    )
    @project.update_columns(fu_id: fu.id)

    project_dir = Pathname.new(ENV["USER_DATA_DIR"]) + @project.user_id.to_s + @project.key
    FileUtils.mkdir_p(project_dir)
    File.write(project_dir + fu.upload_file_name, "abc\n")

    FileUtils.mkdir_p(fu.upload_dir)
    File.write(fu.upload_dir + fu.upload_file_name, "stale\n")
    File.write(fu.upload_dir + "output.json", "{\"old\":true}\n")
    fu
  end

  test "reset parsing restores canonical input file and restarts preparsing" do
    v8 = Version.where("id >= 8").order(:id).first
    skip "No v8 Version row" unless v8
    @project.update_columns(version_id: v8.id)
    fu = stage_reset_files
    upload_dir = fu.upload_dir

    assert_enqueued_with(job: FuPreparsingJob, args: [fu.id, { version_id: v8.id, project_id: @project.id }]) do
      get reset_parsing_project_path(@project)
      assert_response :success
    end

    restored_upload_file = upload_dir + fu.upload_file_name
    assert File.exist?(restored_upload_file), "Expected restored upload file at #{restored_upload_file}"
    assert_equal "abc\n", File.read(restored_upload_file)
    assert_not File.exist?(upload_dir + "output.json"), "Expected stale preparsing output to be removed"

    fu.reload
    assert_equal "preparsing", fu.status
    assert_equal File.size(restored_upload_file), fu.upload_file_size
  end

  test "reset parsing of a pre-v8 project keeps the original upload in fus" do
    # Legacy parsing rewrites files at the project root: fus/ holds the original upload.
    fu = stage_reset_files
    upload_dir = fu.upload_dir

    assert_enqueued_with(job: FuPreparsingJob, args: [fu.id, { project_id: @project.id }]) do
      get reset_parsing_project_path(@project)
      assert_response :success
    end

    assert_equal "stale\n", File.read(upload_dir + fu.upload_file_name)
    assert_not File.exist?(upload_dir + "output.json"), "Expected stale preparsing output to be removed"
    assert_equal "preparsing", fu.reload.status
  end
end
