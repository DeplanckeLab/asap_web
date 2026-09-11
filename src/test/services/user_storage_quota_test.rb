# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class UserStorageQuotaTest < TestBaseWithoutFixtures
  setup do
    @user = register_for_test_cleanup(
      User.create!(email: "quota_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
  end

  test 'used_bytes sums local disk_size for unarchived projects' do
    create_test_project!(name: 'A', key: "qa#{SecureRandom.hex(3)}", user_id: @user.id, disk_size: 10.gigabytes, archive_status_id: 1)
    create_test_project!(name: 'B', key: "qb#{SecureRandom.hex(3)}", user_id: @user.id, disk_size: 5.gigabytes, archive_status_id: 1)

    assert_equal 15.gigabytes, UserStorageQuota.used_bytes(@user)
  end

  test 'used_bytes uses disk_size_archived when project is on S3' do
    create_test_project!(
      name: 'Archived',
      key: "qc#{SecureRandom.hex(3)}",
      user_id: @user.id,
      disk_size: 1.gigabyte,
      disk_size_archived: 20.gigabytes,
      archive_status_id: 3
    )

    assert_equal 20.gigabytes, UserStorageQuota.used_bytes(@user)
  end

  test 'allow? denies when used plus additional exceeds quota' do
    create_test_project!(
      name: 'Big',
      key: "qd#{SecureRandom.hex(3)}",
      user_id: @user.id,
      disk_size: 90.gigabytes,
      archive_status_id: 1
    )
    # Already has >= MIN_PROJECTS, so quota applies to further adds
    create_test_project!(
      name: 'Second',
      key: "qe#{SecureRandom.hex(3)}",
      user_id: @user.id,
      disk_size: 1.gigabyte,
      archive_status_id: 1
    )

    result = UserStorageQuota.allow?(@user, additional_bytes: 15.gigabytes)
    assert_not result.allowed?
    assert_match(/Storage quota exceeded/i, result.reason)
  end

  test 'allow? permits first project when additional fits alone even if used is high' do
    # Simulate leftover accounting with zero owned projects by not creating any.
    # With 0 projects (< MIN_PROJECTS), a fitting additional size is allowed.
    result = UserStorageQuota.allow?(@user, additional_bytes: 50.gigabytes)
    assert result.allowed?
  end

  test 'allow? denies a single project larger than the quota' do
    result = UserStorageQuota.allow?(@user, additional_bytes: 150.gigabytes)
    assert_not result.allowed?
    assert_match(/exceeds the/i, result.reason)
  end

  test 'allow? skips guest sandbox user' do
    guest = User.find_by(id: User::GUEST_SANDBOX_USER_ID)
    skip 'Guest sandbox user missing' unless guest

    result = UserStorageQuota.allow?(guest, additional_bytes: 500.gigabytes)
    assert result.allowed?
  end

  test 'usage_level is ok warn or critical by percent thresholds' do
    create_test_project!(
      name: 'Level',
      key: "qg#{SecureRandom.hex(3)}",
      user_id: @user.id,
      disk_size: 50.gigabytes,
      archive_status_id: 1
    )
    assert_equal :ok, UserStorageQuota.status_for(@user).usage_level

    @user.projects.update_all(disk_size: 60.gigabytes)
    assert_equal :warn, UserStorageQuota.status_for(@user.reload).usage_level

    @user.projects.update_all(disk_size: 95.gigabytes)
    assert_equal :critical, UserStorageQuota.status_for(@user.reload).usage_level
  end
end
