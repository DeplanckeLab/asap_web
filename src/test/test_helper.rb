ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Refuse production only. Shared/dev DBs are allowed solely under the create-then-destroy
# policy below (no ActiveRecord fixtures, no touching pre-existing projects).
db_name = ActiveRecord::Base.connection_db_config&.database.to_s
if db_name.match?(/production/i)
  abort(
    "[TEST SAFETY] Refusing to run tests against production database '#{db_name}'. " \
    "Set POSTGRES_TEST_DB (and DATABASE_URL) to a dedicated test database."
  )
end

# Suppress ActiveRecord SQL logging in tests
ActiveRecord::Base.logger = nil if ENV['SUPPRESS_SQL_LOGS'] != 'false'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Policy: never load ActiveRecord fixtures (they DELETE all rows in fixture tables).
    # Tests may only touch projects they create via create_test_project!, and those
    # records are destroyed in teardown.
    def self.fixtures(*_names)
      @fixtures = []
    end

    def setup_fixtures
    end

    def teardown_fixtures
    end

    setup do
      @records_for_test_cleanup = []
    end

    teardown do
      destroy_registered_test_records!
    end

    # Track an ActiveRecord object created by this test for teardown destroy only.
    def register_for_test_cleanup(*records)
      flattened = records.flatten.compact
      @records_for_test_cleanup.concat(flattened)
      records.one? ? records.first : records
    end

    # Create a project owned by this test. Always registered for teardown destroy.
    # Never use fixtures or look up existing projects for mutation/destroy.
    def create_test_project!(**attrs)
      attrs = attrs.symbolize_keys
      attrs[:name] ||= "Test project #{SecureRandom.hex(4)}"
      attrs[:key] ||= "tst#{SecureRandom.hex(5)}"
      project = Project.create!(**attrs)
      register_for_test_cleanup(project)
      project
    end

    def destroy_registered_test_records!
      records = Array(@records_for_test_cleanup)
      @records_for_test_cleanup = []
      records.reverse_each do |record|
        next unless record&.persisted?

        record.destroy!
      rescue ActiveRecord::InvalidForeignKey, ActiveRecord::DeleteRestrictionError
        record.delete
      end
    end
  end
end
