import { Controller } from "@hotwired/stimulus"

// Polls a lightweight search fingerprint so the browse/search page picks up
// newly submitted (or removed) projects without a manual refresh.
export default class extends Controller {
  static values = {
    url: String,
    totalCount: Number,
    ids: String,
    interval: { type: Number, default: 10000 }
  }

  connect() {
    this.pollTimer = null
    this.inFlight = false
    this.reloading = false
    this.knownTotalCount = this.totalCountValue
    this.knownIds = this.normalizeIds(this.idsValue)
    this.boundVisibilityChange = this.handleVisibilityChange.bind(this)
    document.addEventListener("visibilitychange", this.boundVisibilityChange)
    this.schedulePoll()
  }

  disconnect() {
    this.stopPolling()
    if (this.boundVisibilityChange) {
      document.removeEventListener("visibilitychange", this.boundVisibilityChange)
      this.boundVisibilityChange = null
    }
  }

  handleVisibilityChange() {
    if (document.hidden) {
      this.stopPolling()
    } else {
      this.schedulePoll()
    }
  }

  schedulePoll() {
    if (document.hidden || this.reloading) return
    if (this.pollTimer) return

    this.poll()
    this.pollTimer = setInterval(() => this.poll(), this.intervalValue)
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  normalizeIds(value) {
    if (Array.isArray(value)) {
      return value.map((id) => String(id))
    }
    return String(value || "")
      .split(",")
      .map((id) => id.trim())
      .filter((id) => id.length > 0)
  }

  idsEqual(a, b) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i += 1) {
      if (a[i] !== b[i]) return false
    }
    return true
  }

  poll() {
    if (document.hidden || this.inFlight || this.reloading) return
    if (!this.urlValue) return

    this.inFlight = true
    fetch(this.urlValue, {
      method: "GET",
      headers: {
        Accept: "application/json",
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`)
        }
        return response.json()
      })
      .then((data) => {
        this.applySnapshot(data)
      })
      .catch((error) => {
        console.warn("[SearchProjectsRefresh] Failed to poll search snapshot:", error)
      })
      .finally(() => {
        this.inFlight = false
      })
  }

  applySnapshot(data) {
    if (!data || typeof data !== "object") return

    const nextTotalCount = parseInt(data.total_count, 10) || 0
    const nextIds = this.normalizeIds(data.ids)

    if (
      nextTotalCount === this.knownTotalCount &&
      this.idsEqual(nextIds, this.knownIds)
    ) {
      return
    }

    this.reloading = true
    this.stopPolling()
    window.location.reload()
  }
}
