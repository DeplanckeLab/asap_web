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
end

class IntegrationTestWithoutFixtures < ActionDispatch::IntegrationTest
  def self.fixtures(*names)
    @fixtures = []
  end

  def setup_fixtures
    # Skip fixture loading
  end

  def teardown_fixtures
    # Skip fixture teardown
  end
end

