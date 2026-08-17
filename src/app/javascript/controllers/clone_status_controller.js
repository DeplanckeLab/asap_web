import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = ["statusText", "errorText"]
  static values = { projectId: Number, sourceUrl: String }

  connect() {
    this.reloadScheduled = false
    this.subscribe()
    this.startPolling()
  }

  disconnect() {
    this.unsubscribe()
    this.stopPolling()
  }

  subscribe() {
    if (!this.projectIdValue) return

    this.subscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectIdValue },
      {
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
    if (data.project_id !== undefined && Number(data.project_id) !== this.projectIdValue) return

    if (data.clone_status === "completed") {
      this.scheduleReload()
    }
    if (data.clone_status === "failed") {
      this.showError(data.error || "Clone failed.")
    }
  }

  scheduleReload() {
    if (this.reloadScheduled) return
    this.reloadScheduled = true
    this.stopPolling()
    setTimeout(() => window.location.reload(), 600)
  }

  startPolling() {
    if (!this.projectIdValue) return
    this.pollTimer = setInterval(() => this.pollStatus(), 2000)
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  pollStatus() {
    if (this.reloadScheduled) return

    fetch(`/projects/${this.projectIdValue}/clone_status`, {
      method: "GET",
      headers: {
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    })
      .then((response) => {
        if (response.status === 404) {
          this.showError("Clone failed. Returning to the source project.")
          this.stopPolling()
          setTimeout(() => {
            window.location.href = this.sourceUrlValue || "/projects"
          }, 1200)
          return null
        }
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then((data) => {
        if (!data) return
        if (data.being_cloned === false || data.clone_status === "completed") {
          this.scheduleReload()
        }
      })
      .catch((error) => {
        console.warn(`[CloneStatus] poll failed project=${this.projectIdValue}:`, error)
      })
  }

  showError(message) {
    this.statusTextTarget.textContent = "Clone failed."
    this.errorTextTarget.textContent = message
    this.errorTextTarget.style.display = "block"
  }
}
