require 'test_helper'

# Base test class that doesn't load fixtures
class TestBaseWithoutFixtures < ActiveSupport::TestCase
  # Override the fixtures class method to prevent loading
  def self.fixtures(*names)
    @fixtures = []
  end

  # Override setup_fixtures to do nothing
  def setup_fixtures
    # Skip fixture loading
  end

  def teardown_fixtures
    # Skip fixture teardown
  end

  setup do
    @records_for_test_cleanup = []
  end

  teardown do
    destroy_test_records(@records_for_test_cleanup)
  end

  def register_for_test_cleanup(*records)
    flattened = records.flatten.compact
    @records_for_test_cleanup.concat(flattened)
    records.one? ? records.first : records
  end

  def create_test_project!(**attrs)
    project = Project.create!(**attrs)
    register_for_test_cleanup(project)
    project
  end

  private

  def destroy_test_records(records)
    records.reverse_each do |record|
      next unless record&.persisted?

      record.destroy!
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::DeleteRestrictionError
      record.delete
    end
  end
end

