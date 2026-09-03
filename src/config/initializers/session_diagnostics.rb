# frozen_string_literal: true

# Opt-in cookie/session diagnostics. Enable with SESSION_DIAGNOSTICS=1.
require Rails.root.join('app/middleware/session_diagnostics_middleware')

Rails.application.config.middleware.insert_before(
  ActionDispatch::Cookies,
  SessionDiagnosticsMiddleware
)
