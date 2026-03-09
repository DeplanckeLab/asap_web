import consumer from "channels/consumer"

// Intentionally no side-effect subscription here.
// Project subscriptions must always include a concrete `project_id`.
export function subscribeToProjectChannel(projectId, callbacks = {}) {
  if (!projectId) {
    throw new Error("subscribeToProjectChannel requires projectId")
  }

  return consumer.subscriptions.create(
    { channel: "ProjectChannel", project_id: projectId },
    callbacks
  )
}
