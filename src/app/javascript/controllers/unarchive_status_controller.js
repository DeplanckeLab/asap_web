import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = ["statusText", "progressBar", "retrievingStep", "unpackingStep", "completedStep", "errorText"]
  static values = { projectId: Number, initialState: String, statusUrl: String }

  connect() {
    this.applyState(this.initialStateValue || "queued")
    this.startStatusPolling()
    this.subscribe()
  }

  disconnect() {
    this.stopStatusPolling()
    this.unsubscribe()
  }

  subscribe() {
    if (!this.projectIdValue) return

    this.subscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectIdValue },
      {
        connected: () => this.syncCurrentStatus(),
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

  startStatusPolling() {
    this.syncCurrentStatus()
    this.statusPollTimer = setInterval(() => this.syncCurrentStatus(), 2000)
  }

  stopStatusPolling() {
    if (this.statusPollTimer) {
      clearInterval(this.statusPollTimer)
      this.statusPollTimer = null
    }
  }

  received(data) {
    if (!data) return

    // ActionCable payloads can carry project_id as string or number.
    if (data.project_id !== undefined && Number(data.project_id) !== this.projectIdValue) return

    if (data.unarchive_status) {
      this.applyState(data.unarchive_status)
    }

    if (data.project_unarchived === true || data.unarchive_status === "completed") {
      setTimeout(() => window.location.reload(), 600)
    }
  }

  async syncCurrentStatus() {
    if (!this.hasStatusUrlValue || !this.statusUrlValue) return

    try {
      const response = await fetch(this.statusUrlValue, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })

      if (!response.ok) return

      const data = await response.json()
      this.received(data)
    } catch (_error) {
      // Ignore sync errors and keep live updates via ActionCable.
    }
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
