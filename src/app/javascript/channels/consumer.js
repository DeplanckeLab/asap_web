// Action Cable provides the framework to deal with WebSockets in Rails.
// You can generate new channels where WebSocket features live using the `bin/rails generate channel` command.

import { createConsumer } from "@rails/actioncable"

// Use the URL exposed by action_cable_meta_tag so env/config controls the endpoint.
const consumer = createConsumer()

console.log('[ActionCable] Consumer created from meta tag URL', consumer)

export default consumer
