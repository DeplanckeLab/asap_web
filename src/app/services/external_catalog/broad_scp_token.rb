# frozen_string_literal: true

require 'net/http'
require 'json'
require 'cgi'
require 'uri'

module ExternalCatalog
  # Resolves a Google OAuth access token for Broad Single Cell Portal downloads.
  #
  # Preferred durable setup (refresh token):
  #   SCP_GOOGLE_CLIENT_ID
  #   SCP_GOOGLE_CLIENT_SECRET
  #   SCP_GOOGLE_REFRESH_TOKEN
  #
  # Optional short-lived override (debugging):
  #   SCP_ACCESS_TOKEN
  #
  # The Google account behind the refresh token must have accepted Terra ToS and
  # signed into SCP at least once.
  class BroadScpToken
    TOKEN_URL = 'https://oauth2.googleapis.com/token'.freeze
    AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'.freeze
    CACHE_KEY = 'external_catalog/broad_scp_access_token'.freeze
    DEFAULT_REDIRECT_URI = 'http://127.0.0.1'.freeze
    SCOPES = %w[openid email profile].freeze
    EXPIRY_SKEW_SEC = 60

    class Error < StandardError; end
    class MissingCredentials < Error; end
    class RefreshFailed < Error; end

    def self.access_token!
      new.access_token!
    end

    def self.oauth_authorization_url(client_id: nil, redirect_uri: nil)
      new(client_id: client_id, redirect_uri: redirect_uri).oauth_authorization_url
    end

    def self.exchange_authorization_code!(code, client_id: nil, client_secret: nil, redirect_uri: nil)
      new(
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: redirect_uri
      ).exchange_authorization_code!(code)
    end

    def self.clear_cache!
      Rails.cache.delete(CACHE_KEY)
    end

    def initialize(client_id: nil, client_secret: nil, refresh_token: nil, redirect_uri: nil)
      @client_id = client_id.to_s.strip.presence || ENV['SCP_GOOGLE_CLIENT_ID'].to_s.strip.presence
      @client_secret = client_secret.to_s.strip.presence || ENV['SCP_GOOGLE_CLIENT_SECRET'].to_s.strip.presence
      @refresh_token = refresh_token.to_s.strip.presence || ENV['SCP_GOOGLE_REFRESH_TOKEN'].to_s.strip.presence
      @redirect_uri =
        redirect_uri.to_s.strip.presence ||
        ENV['SCP_GOOGLE_REDIRECT_URI'].to_s.strip.presence ||
        DEFAULT_REDIRECT_URI
    end

    def access_token!
      cached = Rails.cache.read(CACHE_KEY).to_s.strip.presence
      return cached if cached.present?

      if refresh_credentials?
        token, expires_in = refresh_access_token!
        ttl = [expires_in.to_i - EXPIRY_SKEW_SEC, 60].max
        Rails.cache.write(CACHE_KEY, token, expires_in: ttl)
        return token
      end

      manual = ENV['SCP_ACCESS_TOKEN'].to_s.strip.presence
      return manual if manual.present?

      raise MissingCredentials,
            'Broad SCP downloads need SCP_GOOGLE_CLIENT_ID, SCP_GOOGLE_CLIENT_SECRET, ' \
            'and SCP_GOOGLE_REFRESH_TOKEN (or a short-lived SCP_ACCESS_TOKEN override). ' \
            'See docs/external-catalog-import.md (Broad SCP auth).'
    end

    def oauth_authorization_url
      raise MissingCredentials, 'SCP_GOOGLE_CLIENT_ID is required' if @client_id.blank?

      params = {
        client_id: @client_id,
        redirect_uri: @redirect_uri,
        response_type: 'code',
        scope: SCOPES.join(' '),
        access_type: 'offline',
        prompt: 'consent',
        include_granted_scopes: 'true'
      }
      "#{AUTH_URL}?#{URI.encode_www_form(params)}"
    end

    def exchange_authorization_code!(code)
      auth_code = code.to_s.strip
      raise MissingCredentials, 'authorization CODE is blank' if auth_code.blank?
      raise MissingCredentials, 'SCP_GOOGLE_CLIENT_ID is required' if @client_id.blank?
      raise MissingCredentials, 'SCP_GOOGLE_CLIENT_SECRET is required' if @client_secret.blank?

      payload = post_token_form(
        code: auth_code,
        client_id: @client_id,
        client_secret: @client_secret,
        redirect_uri: @redirect_uri,
        grant_type: 'authorization_code'
      )
      refresh = payload['refresh_token'].to_s.strip.presence
      access = payload['access_token'].to_s.strip.presence
      raise RefreshFailed, 'Google response missing refresh_token (revoke prior consent and retry with prompt=consent)' if refresh.blank?
      raise RefreshFailed, 'Google response missing access_token' if access.blank?

      {
        refresh_token: refresh,
        access_token: access,
        expires_in: payload['expires_in'].to_i,
        token_type: payload['token_type'].to_s,
        scope: payload['scope'].to_s
      }
    end

    private

    def refresh_credentials?
      @client_id.present? && @client_secret.present? && @refresh_token.present?
    end

    def refresh_access_token!
      payload = post_token_form(
        client_id: @client_id,
        client_secret: @client_secret,
        refresh_token: @refresh_token,
        grant_type: 'refresh_token'
      )
      token = payload['access_token'].to_s.strip.presence
      raise RefreshFailed, 'Google refresh response missing access_token' if token.blank?

      expires_in = payload['expires_in'].to_i
      expires_in = 3600 if expires_in <= 0
      [token, expires_in]
    end

    def post_token_form(form)
      uri = URI.parse(TOKEN_URL)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/x-www-form-urlencoded'
        request['Accept'] = 'application/json'
        request.body = URI.encode_www_form(form)
        http.request(request)
      end

      body = response.body.to_s
      payload =
        begin
          JSON.parse(body)
        rescue JSON::ParserError
          {}
        end

      unless response.is_a?(Net::HTTPSuccess)
        detail = payload['error_description'].presence || payload['error'].presence || body.truncate(300)
        raise RefreshFailed, "Google token endpoint HTTP #{response.code}: #{detail}"
      end

      payload
    end
  end
end
