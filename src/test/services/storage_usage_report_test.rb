# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class StorageUsageReportTest < TestBaseWithoutFixtures
  test 'classify_s3_objects partitions total into unarchived deleted and archived' do
    objects = [
      { key: 'alive_local', bytes: 100 },
      { key: 'alive_archived', bytes: 200 },
      { key: 'gone', bytes: 50 },
      { key: 'archiving', bytes: 25 },
      { key: 'skip/', bytes: 999 }
    ]
    archive_status_by_key = {
      'alive_local' => 1,
      'alive_archived' => 3,
      'archiving' => 2
    }

    result = StorageUsageReport.classify_s3_objects(objects, archive_status_by_key)
    by_category = result[:categories].index_by { |row| row[:category] }

    assert_equal '20000-af8a16d143d9920a26869b30700c3da4', result[:bucket]
    assert_equal 4, by_category['total'][:count]
    assert_equal 375, by_category['total'][:bytes]
    assert_equal 2, by_category['unarchived'][:count]
    assert_equal 125, by_category['unarchived'][:bytes]
    assert_equal 1, by_category['deleted'][:count]
    assert_equal 50, by_category['deleted'][:bytes]
    assert_equal 1, by_category['archived'][:count]
    assert_equal 200, by_category['archived'][:bytes]
  end

  test 'entry_to_h includes last_active_at from project viewed_at updated_at created_at' do
    viewed_at = Time.zone.parse('2024-06-01 10:00:00')
    updated_at = Time.zone.parse('2024-05-01 10:00:00')
    created_at = Time.zone.parse('2024-01-01 10:00:00')
    project = Struct.new(:viewed_at, :updated_at, :created_at).new(viewed_at, updated_at, created_at)
    report = StorageUsageReport.new

    entry = StorageUsageReport::Entry.new(
      bytes: 1,
      category: :unarchived_project,
      path: '/tmp/p',
      project_id: 42,
      last_active_at: report.send(:project_last_active_at, project)
    )

    assert_equal viewed_at.iso8601, report.send(:entry_to_h, entry)[:last_active_at]

    project_without_view = Struct.new(:viewed_at, :updated_at, :created_at).new(nil, updated_at, created_at)
    entry2 = StorageUsageReport::Entry.new(
      bytes: 1,
      category: :unarchived_project,
      path: '/tmp/p',
      project_id: 42,
      last_active_at: report.send(:project_last_active_at, project_without_view)
    )
    assert_equal updated_at.iso8601, report.send(:entry_to_h, entry2)[:last_active_at]
  end
end
