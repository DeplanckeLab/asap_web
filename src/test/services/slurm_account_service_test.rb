require 'test_helper'

class SlurmAccountServiceTest < ActiveSupport::TestCase
  setup do
    @prev_container = ENV['SLURMDB_CONTAINER']
    @prev_compose = ENV['COMPOSE_PROJECT_NAME']
  end

  teardown do
    set_env('SLURMDB_CONTAINER', @prev_container)
    set_env('COMPOSE_PROJECT_NAME', @prev_compose)
  end

  test 'slurmdb_container uses SLURMDB_CONTAINER when set' do
    ENV['SLURMDB_CONTAINER'] = 'my-slurmdb'
    ENV['COMPOSE_PROJECT_NAME'] = 'ignored'
    assert_equal 'my-slurmdb', SlurmAccountService.slurmdb_container
  end

  test 'slurmdb_container derives from COMPOSE_PROJECT_NAME' do
    ENV.delete('SLURMDB_CONTAINER')
    ENV['COMPOSE_PROJECT_NAME'] = 'asap'
    assert_equal 'asap-slurmdb-1', SlurmAccountService.slurmdb_container
  end

  test 'slurmdb_container raises when neither env is set' do
    ENV.delete('SLURMDB_CONTAINER')
    ENV.delete('COMPOSE_PROJECT_NAME')
    assert_raises(ArgumentError) { SlurmAccountService.slurmdb_container }
  end

  private

  def set_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
