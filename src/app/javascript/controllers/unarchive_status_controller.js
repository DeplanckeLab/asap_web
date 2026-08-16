import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = ["statusText", "progressBar", "retrievingStep", "unpackingStep", "completedStep", "errorText"]
  static values = { projectId: Number, initialState: String }

  connect() {
    this.reloadScheduled = false
    this.applyState(this.initialStateValue || "queued")
    this.subscribe()
    this.startPolling()
  }

  disconnect() {
    this.unsubscribe()
    this.stopPolling()
  }

  subscribe() {
    if (!this.projectIdValue) return

    // unarchive_watch tells ProjectChannel to include the current unarchive
    // state in its initial snapshot, so a completion that happened before the
    // subscription was established is not lost.
    this.subscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectIdValue, unarchive_watch: true },
      {
        connected: () => {
          console.log(`[UnarchiveStatus] subscribed project=${this.projectIdValue}`)
        },
        disconnected: () => {
          console.log(`[UnarchiveStatus] disconnected project=${this.projectIdValue}`)
        },
        rejected: () => {
          console.warn(`[UnarchiveStatus] rejected project=${this.projectIdValue}`)
        },
        received: (data) => this.received(data)
      }
    )
  }

  unsubscribe() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  received(data) {
    if (!data) return

    // ActionCable payloads can carry project_id as string or number.
    if (data.project_id !== undefined && Number(data.project_id) !== this.projectIdValue) return

    console.log(`[UnarchiveStatus] received project=${this.projectIdValue}`, data)

    if (data.unarchive_status) {
      this.applyState(data.unarchive_status)
    }

    if (data.project_unarchived === true || data.unarchive_status === "completed") {
      this.scheduleReload()
    }
  }

  scheduleReload() {
    if (this.reloadScheduled) return
    this.reloadScheduled = true
    this.stopPolling()
    setTimeout(() => window.location.reload(), 600)
  }

  // Slow polling fallback: the WebSocket broadcast is the fast path, but it is
  // a one-shot message. If it is missed (job finished before the subscription
  // was up, dropped connection, rejected subscription), this poll detects the
  // terminal state from the server and recovers.
  startPolling() {
    if (!this.projectIdValue) return

    this.pollTimer = setInterval(() => this.pollStatus(), 5000)
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  pollStatus() {
    if (this.reloadScheduled) return

    fetch(`/projects/${this.projectIdValue}/unarchive_status`, {
      method: "GET",
      headers: {
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then((data) => {
        console.log(`[UnarchiveStatus] poll project=${this.projectIdValue}`, data)
        if (data.unarchive_status === "completed") {
          this.applyState("completed")
          this.scheduleReload()
        }
      })
      .catch((error) => {
        console.warn(`[UnarchiveStatus] poll failed project=${this.projectIdValue}:`, error)
      })
  }

  applyState(state) {
    const effectiveState = (state || "").toString()

    this.hideError()
    this.resetSteps()

    if (effectiveState === "retrieving" || effectiveState === "queued" || effectiveState === "in_progress" || effectiveState === "archived_missing") {
      this.statusTextTarget.textContent = "Retrieving archive from S3 storage..."
      this.progressBarTarget.style.width = "35%"
      this.retrievingStepTarget.style.fontWeight = "600"
      return
    }

    if (effectiveState === "unpacking") {
      this.statusTextTarget.textContent = "Unpacking archive on server..."
      this.progressBarTarget.style.width = "75%"
      this.retrievingStepTarget.style.fontWeight = "600"
      this.unpackingStepTarget.style.fontWeight = "600"
      return
    }

    if (effectiveState === "completed") {
      this.statusTextTarget.textContent = "Archive restored. Loading project..."
      this.progressBarTarget.style.width = "100%"
      this.retrievingStepTarget.style.fontWeight = "600"
      this.unpackingStepTarget.style.fontWeight = "600"
      this.completedStepTarget.style.fontWeight = "600"
      return
    }

    if (effectiveState === "failed" || effectiveState === "queue_failed") {
      this.statusTextTarget.textContent = "Archive restore failed."
      this.progressBarTarget.style.width = "100%"
      this.showError("Please retry opening this project. If the problem persists, contact support.")
      return
    }

    // Archiving must never look like an unarchive-in-progress UI. Reload so the
    // page can render the dedicated archiving overlay (or the next real state).
    if (effectiveState === "archiving") {
      this.statusTextTarget.textContent = "Project is being archived. Reloading..."
      this.progressBarTarget.style.width = "45%"
      this.scheduleReload()
      return
    }

    this.statusTextTarget.textContent = "Preparing archive retrieval..."
    this.progressBarTarget.style.width = "20%"
  }

  resetSteps() {
    this.retrievingStepTarget.style.fontWeight = "400"
    this.unpackingStepTarget.style.fontWeight = "400"
    this.completedStepTarget.style.fontWeight = "400"
  }

  showError(message) {
    this.errorTextTarget.textContent = message
    this.errorTextTarget.style.display = "block"
  }

  hideError() {
    this.errorTextTarget.textContent = ""
    this.errorTextTarget.style.display = "none"
  }
}
