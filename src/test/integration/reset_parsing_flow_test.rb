require "test_helper"
require "tmpdir"
require "fileutils"

class ResetParsingFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  self.fixture_paths = []

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

    @project = Project.create!(
      name: "Reset parsing integration project",
      key: "reset_project_#{SecureRandom.hex(4)}",
      user_id: nil,
      organism_id: nil,
      version_id: nil
    )
  end

  teardown do
    ENV["UPLOAD_DATA_DIR"] = @previous_upload_data_dir
    ENV["USER_DATA_DIR"] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "reset parsing restores canonical input file and restarts preparsing" do
    fu = Fu.create!(
      project_id: @project.id,
      project_key: @project.key,
      upload_file_name: "input_file.txt",
      upload_file_size: 3,
      status: "completed"
    )
    @project.update_columns(fu_id: fu.id)

    project_dir = Pathname.new(ENV["USER_DATA_DIR"]) + @project.user_id.to_s + @project.key
    canonical_project_copy = project_dir + fu.upload_file_name
    FileUtils.mkdir_p(project_dir)
    File.write(canonical_project_copy, "abc\n")

    upload_dir = fu.upload_dir
    FileUtils.mkdir_p(upload_dir)
    File.write(upload_dir + fu.upload_file_name, "stale\n")
    File.write(upload_dir + "output.json", "{\"old\":true}\n")

    assert_enqueued_with(job: FuPreparsingJob, args: [fu.id, {}]) do
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
end
