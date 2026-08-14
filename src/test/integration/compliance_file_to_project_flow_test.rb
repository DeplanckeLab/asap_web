require "test_helper"
require "tmpdir"
require "fileutils"

class ComplianceFileToProjectFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs

    @tmp_root = Dir.mktmpdir("compliance-file-to-project")
    @previous_upload_data_dir = ENV["UPLOAD_DATA_DIR"]
    @previous_user_data_dir = ENV["USER_DATA_DIR"]

    ENV["UPLOAD_DATA_DIR"] = File.join(@tmp_root, "fus")
    ENV["USER_DATA_DIR"] = File.join(@tmp_root, "projects")
    FileUtils.mkdir_p(ENV["UPLOAD_DATA_DIR"])
    FileUtils.mkdir_p(ENV["USER_DATA_DIR"])

    @upload_type_id = UploadType.id_for("compliance_file_check")
    @project_input_type_id = UploadType.id_for("project_input")
    skip "compliance_file_check upload type missing" if @upload_type_id.blank?
    skip "project_input upload type missing" if @project_input_type_id.blank?
  end

  teardown do
    destroy_registered_test_records!
    ENV["UPLOAD_DATA_DIR"] = @previous_upload_data_dir
    ENV["USER_DATA_DIR"] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "new project form adopts a standalone compliance Fu instead of asking for a new upload" do
    get new_project_path
    assert_response :success
    sandbox = session[:sandbox]
    assert sandbox.present?

    source_url = "https://example.com/datasets/demo.h5ad"
    fu = create_compliance_fu!(
      project_key: sandbox,
      url: source_url,
      filename: "demo.h5ad"
    )

    get new_project_path, params: { from: "scfair_validation", fu_id: fu.id }
    assert_response :success
    assert_includes response.body, "data-file-upload-existing-fu-id-value=\"#{fu.id}\""
    assert_includes response.body, "data-file-upload-existing-filename-value=\"demo.h5ad\""
    assert_not_includes response.body, "data-file-upload-prefill-file-url-value"

    fu.reload
    assert_equal "uploaded", fu.status
    assert_equal @project_input_type_id, fu.upload_type
    assert_equal fu.id, session[:file_upload][:fu_id]
    assert_equal true, session[:file_upload][:complete]
  end

  test "download_from_url reuses a validated compliance Fu for the same URL" do
    version = Version.order(:id).first
    skip "no versions available" if version.blank?

    get new_project_path
    assert_response :success
    sandbox = session[:sandbox]
    source_url = "https://example.com/datasets/reuse.h5ad"

    fu = create_compliance_fu!(
      project_key: sandbox,
      url: source_url,
      filename: "reuse.h5ad"
    )

    assert_no_enqueued_jobs only: FuDownloadFromUrlJob do
      assert_enqueued_with(job: FuPreparsingJob) do
        post download_from_url_fus_path, params: {
          url: source_url,
          version_id: version.id
        }, as: :json
      end
    end

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal fu.id, payload["fu_id"]
    assert_equal "reuse.h5ad", payload["filename"]

    fu.reload
    assert_equal @project_input_type_id, fu.upload_type
    assert_equal "preparsing", fu.status
    assert_equal fu.id, session[:file_upload][:fu_id]
  end

  private

  def create_compliance_fu!(project_key:, url:, filename:)
    fu = register_for_test_cleanup(
      Fu.create!(
        user_id: nil,
        project_key: project_key,
        upload_file_name: "input_file.h5ad",
        upload_file_size: 12,
        name: filename,
        status: "validated",
        upload_type: @upload_type_id,
        url: url
      )
    )
    upload_dir = fu.upload_dir
    FileUtils.mkdir_p(upload_dir)
    File.write(upload_dir + fu.upload_file_name, "h5ad-bytes\n")
    fu.update!(upload_file_size: File.size(upload_dir + fu.upload_file_name))
    fu
  end
end
