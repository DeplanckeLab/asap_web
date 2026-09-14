import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"
import { showProjectArchiveOverlay } from "lib/project_archive_overlay"

// Polls archive state while a project is being archived (archive_status_id=2).
// Also listens on ProjectChannel so completion can update the page without waiting
// for the next poll tick. Reloads when archiving finishes so the page can show
// archived/unarchive UI or the restored project view.
export default class extends Controller {
  static targets = ["statusText", "progressBar"]
  static values = { projectId: Number }

  connect() {
    this.reloadScheduled = false
    this.startPolling()
    this.subscribeToProject()
  }

  disconnect() {
    this.stopPolling()
    this.unsubscribeFromProject()
  }

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

  subscribeToProject() {
    if (!this.projectIdValue) return

    this.subscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectIdValue },
      {
        received: (data) => this.handleBroadcast(data)
      }
    )
  }

  unsubscribeFromProject() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  handleBroadcast(data) {
    if (!data || this.reloadScheduled) return
    if (data.project_id != null && Number(data.project_id) !== Number(this.projectIdValue)) return

    if (data.project_archived === true || data.archive_status === "archived") {
      // Stay on this URL: inject archived overlay instead of reload (avoids auto-unarchive).
      this.reloadScheduled = true
      this.stopPolling()
      if (this.hasStatusTextTarget) {
        this.statusTextTarget.textContent = "Archiving finished."
      }
      showProjectArchiveOverlay(this.projectIdValue, "archived")
      return
    }

    if (data.archive_status === "failed") {
      this.scheduleReload()
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
        if (data.unarchive_status === "archived") {
          this.reloadScheduled = true
          this.stopPolling()
          showProjectArchiveOverlay(this.projectIdValue, "archived")
          return
        }
        if (data.unarchive_status !== "archiving") {
          this.scheduleReload()
        }
      })
      .catch((error) => {
        console.warn(`[ArchivingStatus] poll failed project=${this.projectIdValue}:`, error)
      })
  }

  scheduleReload() {
    if (this.reloadScheduled) return
    this.reloadScheduled = true
    this.stopPolling()
    if (this.hasStatusTextTarget) {
      this.statusTextTarget.textContent = "Archiving finished. Reloading project..."
    }
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = "100%"
    }
    setTimeout(() => window.location.reload(), 600)
  }
}
