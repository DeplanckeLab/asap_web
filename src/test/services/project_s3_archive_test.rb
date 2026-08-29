# frozen_string_literal: true

require 'test_helper'
require 'shellwords'

class ProjectS3ArchiveTest < ActiveSupport::TestCase
  test 'archive returns missing_local_dir when the project directory is absent and S3 has no object' do
    user = register_for_test_cleanup(
      User.create!(email: "s3arch_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(
      user_id: user.id,
      input_filename: 'input_file.loom',
      archive_status_id: 2
    )

    ProjectS3Archive.singleton_class.class_eval do
      alias_method :__orig_mark_archived_from_s3_if_present!, :mark_archived_from_s3_if_present!
      define_method(:mark_archived_from_s3_if_present!) { |*| false }
    end

    result = ProjectS3Archive.archive!(project, s3b: ProjectS3Archive.bucket_config, dry_run: false)
    assert_equal :missing_local_dir, result
    assert_equal 2, project.reload.archive_status_id
  ensure
    ProjectS3Archive.singleton_class.class_eval do
      alias_method :mark_archived_from_s3_if_present!, :__orig_mark_archived_from_s3_if_present!
      remove_method :__orig_mark_archived_from_s3_if_present!
    end
  end

  test 'extract_member_to! pulls one archive member then deletes the temp tgz' do
    user = register_for_test_cleanup(
      User.create!(email: "s3mem_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, key: "sm#{SecureRandom.hex(3)}")

    tmp_pack = Pathname.new(Dir.mktmpdir('asap_s3_member_pack'))
    project_tree = tmp_pack.join(project.key, 'parsing')
    FileUtils.mkdir_p(project_tree)
    File.binwrite(project_tree.join('output.loom'), "loom-bytes-#{SecureRandom.hex(8)}")
    archive_src = tmp_pack.join("#{project.key}.tgz")
    cmd = "tar -cf - -C #{Shellwords.escape(tmp_pack.to_s)} #{Shellwords.escape(project.key)} | pigz -9 > #{Shellwords.escape(archive_src.to_s)}"
    `#{cmd}`
    assert $?.success?, 'failed to build test archive'
    assert File.size(archive_src).positive?

    dest = Pathname.new(Dir.mktmpdir('asap_s3_member_dest')).join('out.loom')
    holder = { archive_src: archive_src.to_s, seen: [] }

    Basic.singleton_class.class_eval do
      alias_method :__orig_get_s3_settings, :get_s3_settings
      alias_method :__orig_connect_s3, :connect_s3
      alias_method :__orig_write_file_from_s3, :write_file_from_s3
    end
    Basic.define_singleton_method(:get_s3_settings) { {} }
    Basic.define_singleton_method(:connect_s3) { |*| Object.new }
    Basic.define_singleton_method(:write_file_from_s3) do |_s3, _bucket, _project, filepath|
      FileUtils.cp(holder[:archive_src], filepath)
      holder[:seen] << filepath.to_s
      true
    end

    ProjectS3Archive.extract_member_to!(
      project,
      member_rel: 'parsing/output.loom',
      dest_path: dest
    )

    assert File.exist?(dest)
    assert_equal File.binread(project_tree.join('output.loom')), File.binread(dest)
    holder[:seen].each do |path|
      refute File.exist?(path), "temp archive should be deleted: #{path}"
    end
  ensure
    Basic.singleton_class.class_eval do
      alias_method :get_s3_settings, :__orig_get_s3_settings if method_defined?(:__orig_get_s3_settings) || private_method_defined?(:__orig_get_s3_settings)
      alias_method :connect_s3, :__orig_connect_s3 if method_defined?(:__orig_connect_s3) || private_method_defined?(:__orig_connect_s3)
      alias_method :write_file_from_s3, :__orig_write_file_from_s3 if method_defined?(:__orig_write_file_from_s3) || private_method_defined?(:__orig_write_file_from_s3)
      remove_method :__orig_get_s3_settings if method_defined?(:__orig_get_s3_settings) || private_method_defined?(:__orig_get_s3_settings)
      remove_method :__orig_connect_s3 if method_defined?(:__orig_connect_s3) || private_method_defined?(:__orig_connect_s3)
      remove_method :__orig_write_file_from_s3 if method_defined?(:__orig_write_file_from_s3) || private_method_defined?(:__orig_write_file_from_s3)
    end
    FileUtils.rm_rf(tmp_pack) if defined?(tmp_pack) && tmp_pack
    FileUtils.rm_rf(dest.dirname) if defined?(dest) && dest
  end
end
