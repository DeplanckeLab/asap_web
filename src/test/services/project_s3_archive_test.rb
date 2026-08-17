# frozen_string_literal: true

require 'test_helper'

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
end
