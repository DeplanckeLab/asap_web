# frozen_string_literal: true

require Rails.root.join('app/middleware/server_error_tracker_middleware')

# Place inside ActionDispatch::ShowExceptions so uncaught exceptions still reach this
# middleware, can be recorded, then re-raised for the normal 500 page.
Rails.application.config.middleware.insert_before(
  ActionDispatch::Cookies,
  ServerErrorTrackerMiddleware
)
