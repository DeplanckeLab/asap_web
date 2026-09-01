# frozen_string_literal: true

require 'test_helper'

class EnvHelpersTest < ActiveSupport::TestCase
  setup do
    @previous_host = ENV['HOST']
    @previous_instance_name = ENV['ASAP_INSTANCE_NAME']
  end

  teardown do
    set_or_delete_env('HOST', @previous_host)
    set_or_delete_env('ASAP_INSTANCE_NAME', @previous_instance_name)
  end

  test 'instance_kind is production when HOST is asap.epfl.ch' do
    ENV['HOST'] = 'asap.epfl.ch'
    ENV['ASAP_INSTANCE_NAME'] = 'asap'
    assert_equal 'production', EnvHelpers.instance_kind
    assert_equal 'asap.epfl.ch', EnvHelpers.instance_host
    assert_equal 'asap', EnvHelpers.instance_name
  end

  test 'instance_kind is dev/test when HOST is asap-test.epfl.ch' do
    ENV['HOST'] = 'asap-test.epfl.ch'
    ENV['ASAP_INSTANCE_NAME'] = 'asap_dev'
    assert_equal 'dev/test', EnvHelpers.instance_kind
    assert_equal 'asap-test.epfl.ch', EnvHelpers.instance_host
    assert_equal 'asap_dev', EnvHelpers.instance_name
  end

  test 'instance_host raises when HOST is missing' do
    ENV.delete('HOST')
    assert_raises(KeyError) { EnvHelpers.instance_host }
  end

  test 'instance_name raises when ASAP_INSTANCE_NAME is missing' do
    ENV.delete('ASAP_INSTANCE_NAME')
    assert_raises(KeyError) { EnvHelpers.instance_name }
  end

  test 'public_base_url uses https and HOST' do
    ENV['HOST'] = 'asap-test.epfl.ch'
    assert_equal 'https://asap-test.epfl.ch', EnvHelpers.public_base_url
  end

  test 'openapi_api_base appends /api to public_base_url' do
    ENV['HOST'] = 'asap.epfl.ch'
    assert_equal 'https://asap.epfl.ch/api', EnvHelpers.openapi_api_base

    ENV['HOST'] = 'asap-test.epfl.ch'
    assert_equal 'https://asap-test.epfl.ch/api', EnvHelpers.openapi_api_base
  end

  test 'email_in_list? matches stripped case-insensitive addresses' do
    previous = ENV['ADMIN_REPORT_EMAILS']
    ENV['ADMIN_REPORT_EMAILS'] = 'one@example.com, Two@Example.com'
    assert EnvHelpers.email_in_list?('ADMIN_REPORT_EMAILS', ' one@example.com ')
    assert EnvHelpers.email_in_list?('ADMIN_REPORT_EMAILS', 'two@example.com')
    refute EnvHelpers.email_in_list?('ADMIN_REPORT_EMAILS', 'other@example.com')
    refute EnvHelpers.email_in_list?('ADMIN_REPORT_EMAILS', '')
  ensure
    set_or_delete_env('ADMIN_REPORT_EMAILS', previous)
  end

  private

  def set_or_delete_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
