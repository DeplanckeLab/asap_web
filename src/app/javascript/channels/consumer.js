// Action Cable provides the framework to deal with WebSockets in Rails.
// You can generate new channels where WebSocket features live using the `bin/rails generate channel` command.

import { createConsumer } from "@rails/actioncable"

const consumer = createConsumer()

// Log consumer creation for debugging
console.log('[ActionCable] Consumer created', consumer)

export default consumer
