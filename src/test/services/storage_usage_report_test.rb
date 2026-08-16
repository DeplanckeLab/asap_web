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
end
