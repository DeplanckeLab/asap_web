ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Suppress ActiveRecord SQL logging in tests
ActiveRecord::Base.logger = nil if ENV['SUPPRESS_SQL_LOGS'] != 'false'

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # No YAML fixtures (db:fixtures:load replaces entire tables).

    def create_test_project!(**attrs)
      Project.create!(
        {
          name: "Test project",
          key: "t#{SecureRandom.hex(8)}",
          public: false,
          sandbox: true
        }.merge(attrs)
      )
    end
  end
end
