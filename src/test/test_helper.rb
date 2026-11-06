ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

# [TEST SAFETY] Runs BEFORE rails/test_help, which may purge and reload the schema
# (maintain_test_schema). Every PostgreSQL database configured for this environment
# (primary, asap_data, asap_data_v*) must be a dedicated test database: its name must
# contain "test". This rejects the app's development/production databases (e.g. a
# DATABASE_URL pointing at asap2_development) and the shared asap_data_v* databases on
# the production PostgreSQL server.
unsafe_test_dbs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).filter_map do |cfg|
  next unless cfg.adapter.to_s.match?(/postg/i)

  name = cfg.database.to_s
  "#{cfg.name}=#{name.presence || '(none)'}@#{cfg.host}:#{cfg.configuration_hash[:port]}" unless name.match?(/test/i)
end
primary_db = ActiveRecord::Base.connection_db_config&.database.to_s
unsafe_test_dbs.unshift("primary(effective)=#{primary_db}") unless primary_db.match?(/test/i)

if unsafe_test_dbs.any?
  abort(
    "[TEST SAFETY] Refusing to run tests: these databases are not dedicated test databases " \
    "(name must contain 'test'): #{unsafe_test_dbs.uniq.join(', ')}. " \
    "Point DATABASE_URL / POSTGRES_TEST_DB and the asap_data test configs at test-only databases."
  )
end

require "rails/test_help"

# Suppress ActiveRecord SQL logging in tests
ActiveRecord::Base.logger = nil if ENV['SUPPRESS_SQL_LOGS'] != 'false'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    # Single worker by default: parallel workers create per-worker databases from
    # db/schema.rb, which cannot be loaded. Override with PARALLEL_WORKERS only if
    # those databases have been prepared.
    parallelize(workers: ENV.fetch("PARALLEL_WORKERS", 1).to_i)

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
