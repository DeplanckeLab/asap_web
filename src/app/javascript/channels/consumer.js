// Action Cable provides the framework to deal with WebSockets in Rails.
// You can generate new channels where WebSocket features live using the `bin/rails generate channel` command.

import { createConsumer } from "@rails/actioncable"

// Use the URL exposed by action_cable_meta_tag so env/config controls the endpoint.
const consumer = createConsumer()

console.log('[ActionCable] Consumer created from meta tag URL', consumer)

// Notify inline views (e.g. annotation FindMarkers evidences tab) when run counts change.
// Dispatched from header-run-status so it runs on every project page with a websocket,
// not only when step-selector is active.
export function dispatchProjectStepRunsChangedFromCable(data) {
  if (!data || data.initial_snapshot) return
  if (data.event === 'queue_position_changed') return
  const stepName = (data.step_name || '').toString().toLowerCase()
  if (!stepName) return
  document.dispatchEvent(
    new CustomEvent('asap:project-step-runs-changed', {
      bubbles: true,
      detail: {
        step_id: data.step_id,
        step_name: stepName,
        h_nber_analyses: data.h_nber_analyses
      }
    })
  )
}

export default consumer
