ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Hard safety stop: never allow test fixtures to run against a production DB.
if Rails.env.test?
  db_name = ActiveRecord::Base.connection_db_config&.database.to_s
  if db_name.match?(/production/i)
    abort("[TEST SAFETY] Refusing to run tests against production database '#{db_name}'. Set POSTGRES_TEST_DB to a dedicated test DB.")
  end
end

# Suppress ActiveRecord SQL logging in tests
ActiveRecord::Base.logger = nil if ENV['SUPPRESS_SQL_LOGS'] != 'false'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
