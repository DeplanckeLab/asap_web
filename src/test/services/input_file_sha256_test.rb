# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "digest"

class InputFileSha256Test < ActiveSupport::TestCase
  setup do
    @tmp = Dir.mktmpdir("input-file-sha256")
    @upload_dir = Pathname.new(@tmp).join("fu_dir")
    FileUtils.mkdir_p(@upload_dir)
    @file_path = @upload_dir.join("input_file.bin")
  end

  teardown do
    FileUtils.rm_rf(@tmp) if @tmp.present?
  end

  test "incremental chunk updates match full-file digest" do
    chunk0 = "a" * (1024 * 1024)
    chunk1 = "b" * (512 * 1024)
    expected = Digest::SHA256.hexdigest(chunk0 + chunk1)
    fu_id = 9_900_001

    File.open(@file_path, "wb") { |f| f.write(chunk0) }
    digest = InputFileSha256.update_after_chunk!(
      upload_dir: @upload_dir,
      chunk_index: 0,
      chunk_data: chunk0,
      file_path: @file_path,
      fu_id: fu_id
    )
    File.open(@file_path, "ab") { |f| f.write(chunk1) }
    digest = InputFileSha256.update_after_chunk!(
      upload_dir: @upload_dir,
      chunk_index: 1,
      chunk_data: chunk1,
      file_path: @file_path,
      fu_id: fu_id
    )

    assert_equal expected, digest.hexdigest
    assert_equal expected, InputFileSha256.hexdigest_file(@file_path)
    InputFileSha256.clear_state!(fu_id)
  end

  test "rebuilds digest from file when state is missing" do
    chunk0 = "hello-"
    chunk1 = "world"
    File.write(@file_path, chunk0 + chunk1)
    fu_id = 9_900_002
    InputFileSha256.clear_state!(fu_id)

    digest = InputFileSha256.update_after_chunk!(
      upload_dir: @upload_dir,
      chunk_index: 1,
      chunk_data: chunk1,
      file_path: @file_path,
      fu_id: fu_id
    )

    assert_equal Digest::SHA256.hexdigest(chunk0 + chunk1), digest.hexdigest
    InputFileSha256.clear_state!(fu_id)
  end

  test "public_project_warning lists matching public ASAP projects only" do
    sha = Digest::SHA256.hexdigest("shared-input")
    other_sha = Digest::SHA256.hexdigest("other-input")

    public_match = create_test_project!(
      name: "Public match",
      key: "pub#{SecureRandom.hex(3)}",
      public: true,
      public_id: 9_001_001,
      being_deleted: false,
      input_content_sha256: sha
    )
    create_test_project!(
      name: "Private same hash",
      key: "prv#{SecureRandom.hex(3)}",
      public: false,
      being_deleted: false,
      input_content_sha256: sha
    )
    create_test_project!(
      name: "Public other hash",
      key: "oth#{SecureRandom.hex(3)}",
      public: true,
      public_id: 9_001_002,
      being_deleted: false,
      input_content_sha256: other_sha
    )

    warning = InputFileSha256.public_project_warning(sha)
    assert_includes warning, "ASAP#{public_match.public_id}"
    assert_includes warning, "Public match"
    assert_includes warning, "Creating another project from it is allowed"
    assert_includes warning, "cloning an existing public project is faster"
    assert_nil InputFileSha256.public_project_warning(other_sha + "x")
    private_only = InputFileSha256.public_project_warning(Digest::SHA256.hexdigest("no-public"))
    assert_nil private_only
  end

  test "project input finalizer copies content_sha256 onto the project" do
    previous_upload_dir = ENV["UPLOAD_DATA_DIR"]
    ENV["UPLOAD_DATA_DIR"] = @tmp

    user = register_for_test_cleanup(
      User.create!(email: "sha_finalizer_#{SecureRandom.hex(4)}@example.com", password: "password123")
    )
    project = create_test_project!(
      name: "Finalize hash",
      key: "fin#{SecureRandom.hex(3)}",
      user_id: user.id
    )
    content = "finalizer-bytes-#{SecureRandom.hex(8)}"
    sha = Digest::SHA256.hexdigest(content)
    fu = register_for_test_cleanup(
      Fu.create!(
        user_id: user.id,
        upload_file_name: "input_file.txt",
        upload_file_size: content.bytesize,
        status: "preparsed",
        content_sha256: sha
      )
    )
    FileUtils.mkdir_p(fu.upload_dir)
    File.write(fu.file_path, content)
    File.write(fu.upload_dir.join("output.json"), { "detected_format" => "RAW_TEXT" }.to_json)

    project_dir = Pathname.new(@tmp).join("projects", user.id.to_s, project.key)
    FileUtils.mkdir_p(project_dir)

    ProjectInputFinalizerService.call(
      project: project,
      project_dir: project_dir,
      input_file: fu,
      formats_by_name: {}
    )

    project.reload
    assert_equal sha, project.input_content_sha256
    assert_equal fu.id, project.fu_id
  ensure
    if previous_upload_dir
      ENV["UPLOAD_DATA_DIR"] = previous_upload_dir
    else
      ENV.delete("UPLOAD_DATA_DIR")
    end
  end
end
