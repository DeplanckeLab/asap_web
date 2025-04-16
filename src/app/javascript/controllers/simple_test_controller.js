import { Controller } from '@hotwired/stimulus'
// Adjust this path based on how solid-cable JS is pinned/imported
import { subscribe } from '@rails/solid-cable'

export default class extends Controller {
  // Define expected data attributes (passed from HTML)
  static values = {
    streamName: String, // e.g., "my_test_stream"
    channel: String    // e.g., "SolidCable::Channel"
  }

  connect() {
    // Log for debugging connection
    console.log(`SimpleTestController connecting to channel: ${this.channelValue}, stream: ${this.streamNameValue}`)

    // Subscribe to the stream specified in the HTML
    this.subscription = subscribe(this, { // 'this' allows calling cableReceived
      channel: this.channelValue,
      signed_stream_name: this.streamNameValue // NOTE: Using non-signed name here for simplicity
                                                // Solid Cable handles both signed/unsigned if configured
    })

    if (this.subscription) {
        console.log("SimpleTestController: Subscription potentially successful (check server/WS logs).");
    } else {
        console.error("SimpleTestController: Failed to initiate subscription.");
    }
  }

  disconnect() {
    // Unsubscribe when the element is removed
    if (this.subscription) {
      console.log(`SimpleTestController disconnecting from stream: ${this.streamNameValue}`)
      this.subscription.unsubscribe()
    }
  }

  // This method will be called by Solid Cable when a message arrives
  // on the subscribed stream. The controller instance ('this') was passed
  // during the subscribe() call.
  cableReceived(data) {
    console.log("#  SOLID CABLE RECEIVED:", data);
    // In a real app, you'd update the DOM here or trigger other actions.
    // For this test, just logging is enough.
    this.element.textContent = `Received: ${JSON.stringify(data)}` // Update element content
  }
}
