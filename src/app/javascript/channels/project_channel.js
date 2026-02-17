import consumer from "channels/consumer"

consumer.subscriptions.create("ProjectChannel", {
  connected() {
    console.log('[ProjectChannel] Connected (generic)')
  },

  disconnected() {
    console.log('[ProjectChannel] Disconnected (generic)')
  },

  rejected() {
    console.log('[ProjectChannel] Rejected (generic, no project_id)')
  },

  received(data) {
    console.log('[ProjectChannel] Received (generic):', data)
  }
});
