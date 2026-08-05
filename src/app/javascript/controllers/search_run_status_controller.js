import { Controller } from "@hotwired/stimulus"

// Adaptive batch polling for run status icons on the search projects page.
// Polls only projects whose DOM counts currently show pending+running > 0,
// pauses while the tab is hidden, and stops entirely when nothing is active.
export default class extends Controller {
  static targets = ["statusCell", "statusCount", "statusIcon"]

  static POLL_INTERVAL_MS = 5000

  connect() {
    this.pollTimer = null
    this.inFlight = false
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
    if (document.hidden) return
    if (this.activeProjectIds().length === 0) {
      this.stopPolling()
      return
    }
    if (this.pollTimer) return

    this.poll()
    this.pollTimer = setInterval(() => this.poll(), this.constructor.POLL_INTERVAL_MS)
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  activeProjectIds() {
    const ids = []
    this.statusCellTargets.forEach((cell) => {
      const projectId = cell.dataset.projectId
      if (!projectId) return
      const pending = this.countFor(cell, "pending")
      const running = this.countFor(cell, "running")
      if (pending + running > 0) {
        ids.push(projectId)
      }
    })
    return ids
  }

  countFor(cell, statusKey) {
    const el = cell.querySelector(`[data-search-run-status-target="statusCount"][data-status-key="${statusKey}"]`)
    if (!el) return 0
    return parseInt(el.textContent, 10) || 0
  }

  poll() {
    if (document.hidden || this.inFlight) return

    const ids = this.activeProjectIds()
    if (ids.length === 0) {
      this.stopPolling()
      return
    }

    this.inFlight = true
    const url = `/projects/run_counts_batch?ids=${ids.join(",")}`
    fetch(url, {
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
        this.applyCounts(data)
        if (this.activeProjectIds().length === 0) {
          this.stopPolling()
        }
      })
      .catch((error) => {
        console.warn("[SearchRunStatus] Failed to poll run counts:", error)
      })
      .finally(() => {
        this.inFlight = false
      })
  }

  applyCounts(data) {
    if (!data || typeof data !== "object") return

    this.statusCellTargets.forEach((cell) => {
      const projectId = cell.dataset.projectId
      if (!projectId) return
      const counts = data[projectId]
      if (!counts) return

      ;["pending", "running", "success", "failed"].forEach((statusKey) => {
        const newCount = parseInt(counts[statusKey], 10) || 0
        const countEl = cell.querySelector(
          `[data-search-run-status-target="statusCount"][data-status-key="${statusKey}"]`
        )
        if (countEl) {
          const oldCount = parseInt(countEl.textContent, 10) || 0
          if (oldCount !== newCount) {
            countEl.textContent = newCount
          }
        }
        this.updateIconState(cell, statusKey, newCount)
      })
    })
  }

  updateIconState(cell, statusKey, count) {
    const iconEl = cell.querySelector(
      `[data-search-run-status-target="statusIcon"][data-status-key="${statusKey}"]`
    )
    if (!iconEl) return

    const isActive = count > 0
    const iconBase = iconEl.dataset.iconBase || ""
    const iconSpin = iconEl.dataset.iconSpin || ""
    const activeColor = iconEl.dataset.activeColor || ""
    const inactiveColor = iconEl.dataset.inactiveColor || "text-gray-300"
    const colorClass = isActive ? activeColor : inactiveColor
    const spinClass = isActive && iconSpin ? ` ${iconSpin}` : ""
    const nextClassName = `${iconBase}${spinClass} text-sm ${colorClass}`
    if (iconEl.className !== nextClassName) {
      iconEl.className = nextClassName
    }
  }
}
