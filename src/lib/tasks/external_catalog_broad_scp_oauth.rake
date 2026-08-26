# frozen_string_literal: true

namespace :external_catalog do
  namespace :broad_scp do
    desc 'Print Google OAuth consent URL for durable Broad SCP download credentials'
    task oauth_url: :environment do
      client_id = ENV['SCP_GOOGLE_CLIENT_ID'].to_s.strip
      raise 'Set SCP_GOOGLE_CLIENT_ID first (Google Cloud OAuth Desktop client)' if client_id.blank?

      redirect_uri =
        ENV['SCP_GOOGLE_REDIRECT_URI'].to_s.strip.presence ||
        ExternalCatalog::BroadScpToken::DEFAULT_REDIRECT_URI
      url = ExternalCatalog::BroadScpToken.oauth_authorization_url

      puts <<~MSG
        Broad SCP durable OAuth setup
        -----------------------------
        1. Use a Google account that has accepted Terra ToS (https://app.terra.bio)
           and signed into SCP once (https://singlecell.broadinstitute.org).
        2. Open this URL in a browser (laptop is fine):

        #{url}

        3. After consent, the browser redirects to #{redirect_uri}?code=...
           (the page may fail to load; that is expected). Copy the `code` query value.
        4. Exchange it:

           docker compose exec website bundle exec rails external_catalog:broad_scp:oauth_exchange CODE='PASTE_CODE_HERE'

        Ensure the OAuth client redirect URI includes: #{redirect_uri}
      MSG
    end

    desc 'Exchange Google OAuth authorization CODE for a refresh token (prints env lines)'
    task oauth_exchange: :environment do
      code = ENV['CODE'].to_s.strip
      raise 'Set CODE=... from the OAuth redirect URL' if code.blank?

      client_id = ENV['SCP_GOOGLE_CLIENT_ID'].to_s.strip
      client_secret = ENV['SCP_GOOGLE_CLIENT_SECRET'].to_s.strip
      raise 'Set SCP_GOOGLE_CLIENT_ID' if client_id.blank?
      raise 'Set SCP_GOOGLE_CLIENT_SECRET' if client_secret.blank?

      result = ExternalCatalog::BroadScpToken.exchange_authorization_code!(code)
      ExternalCatalog::BroadScpToken.clear_cache!

      puts <<~MSG
        Success. Add these to .env (then recreate website):

        SCP_GOOGLE_CLIENT_ID=#{client_id}
        SCP_GOOGLE_CLIENT_SECRET=#{client_secret}
        SCP_GOOGLE_REFRESH_TOKEN=#{result[:refresh_token]}

        Optional redirect URI override (must match the OAuth client):
        SCP_GOOGLE_REDIRECT_URI=#{ENV['SCP_GOOGLE_REDIRECT_URI'].presence || ExternalCatalog::BroadScpToken::DEFAULT_REDIRECT_URI}

        Then:
          docker compose up -d --force-recreate website

        SCP_ACCESS_TOKEN is no longer required for normal imports.
        Access token expires_in=#{result[:expires_in]}s (cached automatically after refresh).
      MSG
    end
  end
end
