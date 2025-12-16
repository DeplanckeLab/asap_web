// Action Cable provides the framework to deal with WebSockets in Rails.
// You can generate new channels where WebSocket features live using the `bin/rails generate channel` command.

import { createConsumer } from "@rails/actioncable"

// Use /websocket instead of the default /cable
// This matches the mount path in config/routes.rb and config/application.rb
const consumer = createConsumer("/websocket")

// Log consumer creation for debugging
console.log('[ActionCable] Consumer created with URL: /websocket', consumer)

export default consumer
