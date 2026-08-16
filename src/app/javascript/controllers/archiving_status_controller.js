import { Controller } from "@hotwired/stimulus"

// Polls archive state while a project is being archived (archive_status_id=2).
// Reloads when archiving finishes so the page can show archived/unarchive UI
// or the restored project view.
export default class extends Controller {
  static targets = ["statusText", "progressBar"]
  static values = { projectId: Number }

  connect() {
    this.reloadScheduled = false
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
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
