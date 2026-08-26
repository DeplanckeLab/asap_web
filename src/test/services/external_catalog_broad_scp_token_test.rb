# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogBroadScpTokenTest < ActiveSupport::TestCase
  setup do
    @previous = {
      'SCP_ACCESS_TOKEN' => ENV['SCP_ACCESS_TOKEN'],
      'SCP_GOOGLE_CLIENT_ID' => ENV['SCP_GOOGLE_CLIENT_ID'],
      'SCP_GOOGLE_CLIENT_SECRET' => ENV['SCP_GOOGLE_CLIENT_SECRET'],
      'SCP_GOOGLE_REFRESH_TOKEN' => ENV['SCP_GOOGLE_REFRESH_TOKEN'],
      'SCP_GOOGLE_REDIRECT_URI' => ENV['SCP_GOOGLE_REDIRECT_URI']
    }
    %w[
      SCP_ACCESS_TOKEN
      SCP_GOOGLE_CLIENT_ID
      SCP_GOOGLE_CLIENT_SECRET
      SCP_GOOGLE_REFRESH_TOKEN
      SCP_GOOGLE_REDIRECT_URI
    ].each { |key| ENV.delete(key) }
    ExternalCatalog::BroadScpToken.clear_cache!
  end

  teardown do
    @previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    ExternalCatalog::BroadScpToken.clear_cache!
  end

  test 'access_token! falls back to SCP_ACCESS_TOKEN when refresh credentials are absent' do
    ENV['SCP_ACCESS_TOKEN'] = 'manual-token'
    assert_equal 'manual-token', ExternalCatalog::BroadScpToken.access_token!
  end

  test 'access_token! raises MissingCredentials when nothing is configured' do
    assert_raises(ExternalCatalog::BroadScpToken::MissingCredentials) do
      ExternalCatalog::BroadScpToken.access_token!
    end
  end

  test 'access_token! refreshes and caches Google access token' do
    ENV['SCP_GOOGLE_CLIENT_ID'] = 'client-id'
    ENV['SCP_GOOGLE_CLIENT_SECRET'] = 'client-secret'
    ENV['SCP_GOOGLE_REFRESH_TOKEN'] = 'refresh-token'

    call_count = 0
    stub_refresh = lambda do |_form|
      call_count += 1
      { 'access_token' => 'fresh-access', 'expires_in' => 3600 }
    end

    ExternalCatalog::BroadScpToken.class_eval do
      alias_method :__orig_post_token_form, :post_token_form
      define_method(:post_token_form) { |form| stub_refresh.call(form) }
    end

    begin
      assert_equal 'fresh-access', ExternalCatalog::BroadScpToken.access_token!
      assert_equal 'fresh-access', ExternalCatalog::BroadScpToken.access_token!
      assert_equal 1, call_count
    ensure
      ExternalCatalog::BroadScpToken.class_eval do
        alias_method :post_token_form, :__orig_post_token_form
        remove_method :__orig_post_token_form
      end
    end
  end

  test 'oauth_authorization_url includes offline consent params' do
    ENV['SCP_GOOGLE_CLIENT_ID'] = 'client-id'
    url = ExternalCatalog::BroadScpToken.oauth_authorization_url
    assert_includes url, 'accounts.google.com'
    assert_includes url, 'client_id=client-id'
    assert_includes url, 'access_type=offline'
    assert_includes url, 'prompt=consent'
  end

  test 'exchange_authorization_code! returns refresh_token' do
    ENV['SCP_GOOGLE_CLIENT_ID'] = 'client-id'
    ENV['SCP_GOOGLE_CLIENT_SECRET'] = 'client-secret'

    ExternalCatalog::BroadScpToken.class_eval do
      alias_method :__orig_post_token_form, :post_token_form
      define_method(:post_token_form) do |_form|
        {
          'access_token' => 'a',
          'refresh_token' => 'r',
          'expires_in' => 3600,
          'token_type' => 'Bearer'
        }
      end
    end

    begin
      result = ExternalCatalog::BroadScpToken.exchange_authorization_code!('auth-code')
      assert_equal 'r', result[:refresh_token]
      assert_equal 'a', result[:access_token]
    ensure
      ExternalCatalog::BroadScpToken.class_eval do
        alias_method :post_token_form, :__orig_post_token_form
        remove_method :__orig_post_token_form
      end
    end
  end
end
