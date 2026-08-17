import { Controller } from "@hotwired/stimulus"

const IDLE_TITLE = "Refresh the project list"
const LIST_CHANGED_TITLE = "The list of projects changed. Reload the page to see the updates."

// Polls a search fingerprint so the browse/search page can:
// - flash a refresh control when projects appear, disappear, or reorder
// - patch displayed fields in place when only already-visible rows changed
export default class extends Controller {
  static targets = ["refreshButton", "row"]

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

    const nextTotalCount = parseInt(data.total_count, 10)
    const nextIds = this.normalizeIds(data.ids)
    const listChanged =
      nextTotalCount !== this.knownTotalCount ||
      !this.idsEqual(nextIds, this.knownIds)

    if (listChanged) {
      this.offerListRefresh()
      return
    }

    this.clearListRefresh()
    this.applyProjectDetails(data.projects)
  }

  offerListRefresh() {
    if (!this.hasRefreshButtonTarget) return
    this.refreshButtonTarget.classList.add("subview-refresh-available")
    this.refreshButtonTarget.title = LIST_CHANGED_TITLE
  }

  clearListRefresh() {
    if (!this.hasRefreshButtonTarget) return
    this.refreshButtonTarget.classList.remove("subview-refresh-available")
    this.refreshButtonTarget.title = IDLE_TITLE
  }

  reloadPage() {
    if (this.reloading) return
    this.reloading = true
    this.stopPolling()
    window.location.reload()
  }

  applyProjectDetails(projects) {
    if (!Array.isArray(projects)) return

    const runCountsById = {}
    projects.forEach((project) => {
      const row = this.rowFor(project.id)
      if (!row) return

      this.setField(row, "display_name", project.display_name)
      this.syncCheckbox(row, project)
      this.updateArchiveStatus(row, project)
      this.updateOptionalText(row, "key", project.key)
      this.updateOptionalText(
        row,
        "public_id",
        project.public_id == null || project.public_id === "" ? "" : `ASAP${project.public_id}`
      )
      this.updateOptionalText(
        row,
        "version_id",
        project.version_id == null || project.version_id === "" ? "" : `v${project.version_id}`
      )
      this.updateProjectType(row, project)
      this.updateTermBadges(row, "organism", project.organism)
      this.updateTermBadges(row, "technology", project.technology)
      this.setField(row, "cell_count", project.cell_count)
      this.setField(row, "col_label", project.col_label)
      this.setField(row, "gene_count", project.gene_count)
      this.setField(row, "row_label", project.row_label)
      this.setField(row, "updated_at", project.updated_at)
      if (Object.prototype.hasOwnProperty.call(project, "user_email")) {
        this.setField(row, "user_email", project.user_email || "-")
      }
      if (project.run_counts) {
        runCountsById[String(project.id)] = project.run_counts
      }
    })

    this.applyRunCounts(runCountsById)
  }

  rowFor(projectId) {
    const id = String(projectId)
    return this.rowTargets.find((row) => row.dataset.projectId === id)
  }

  field(row, name) {
    return row.querySelector(`[data-search-projects-refresh-field="${name}"]`)
  }

  setField(row, name, value) {
    const el = this.field(row, name)
    if (!el) return
    const next = value == null ? "" : String(value)
    if (el.textContent !== next) {
      el.textContent = next
    }
  }

  updateOptionalText(row, name, value) {
    const el = this.field(row, name)
    if (!el) return
    const next = value == null ? "" : String(value)
    const visibleDisplay = el.dataset.searchProjectsRefreshVisibleDisplay
    if (next) {
      el.classList.remove("hidden")
      if (visibleDisplay) el.classList.add(visibleDisplay)
      if (el.textContent !== next) el.textContent = next
    } else {
      el.classList.add("hidden")
      if (visibleDisplay) el.classList.remove(visibleDisplay)
    }
  }

  updateArchiveStatus(row, project) {
    const wrap = this.field(row, "archive_status")
    if (!wrap) return
    const iconClass = project.archive_status_icon
    if (!iconClass) {
      wrap.classList.add("hidden")
      return
    }

    wrap.classList.remove("hidden")
    wrap.title = `Archive status: ${project.archive_status_label || ""}`
    const icon = wrap.querySelector("i")
    if (icon) {
      const nextClass = `${iconClass} text-xs`
      if (icon.className !== nextClass) icon.className = nextClass
    }
  }

  updateProjectType(row, project) {
    const el = this.field(row, "project_type")
    if (!el) return
    const tag = project.project_type_tag
    if (tag) {
      if (el.dataset.setClass) el.className = el.dataset.setClass
      el.title = project.project_type_name || ""
      if (el.textContent !== tag) el.textContent = tag
    } else {
      if (el.dataset.unsetClass) el.className = el.dataset.unsetClass
      el.title = "Project type not set"
      if (el.textContent !== "?") el.textContent = "?"
    }
  }

  updateTermBadges(row, fieldName, payload) {
    const el = this.field(row, fieldName)
    if (!el) return

    let terms = []
    let color = "#64748B"
    if (payload && typeof payload === "object" && !Array.isArray(payload)) {
      if (payload.color) color = String(payload.color)
      if (Array.isArray(payload.terms) && payload.terms.length > 0) {
        terms = payload.terms
      } else if (Array.isArray(payload.labels)) {
        terms = payload.labels
      }
    } else if (typeof payload === "string" && payload.length > 0 && payload !== "Unknown") {
      terms = payload.split(",").map((part) => part.trim()).filter(Boolean)
    }

    const entries = this.normalizeTermEntries(terms)
    const displayEntries = entries.length > 0 ? entries : [{ label: "Unknown", identifier: "", url: "" }]
    const limit = fieldName === "technology" ? 2 : null
    const visible = limit != null ? displayEntries.slice(0, limit) : displayEntries
    const remaining = limit != null ? Math.max(displayEntries.length - visible.length, 0) : 0
    const nextKey = `${color}|${displayEntries.map((entry) => `${entry.label}\u0002${entry.identifier}\u0002${entry.url}`).join("\u0001")}|${limit || ""}`
    if (el.dataset.badgeKey === nextKey) return
    el.dataset.badgeKey = nextKey

    const wrap = document.createElement("span")
    wrap.className = "flex flex-wrap gap-1"
    visible.forEach((entry) => {
      const badge = document.createElement("span")
      badge.className = "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium"
      badge.style.backgroundColor = `${color}22`
      badge.style.color = color
      badge.textContent = entry.label
      wrap.appendChild(badge)
    })
    if (remaining > 0) {
      const more = document.createElement("button")
      more.type = "button"
      more.className = "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium hover:opacity-80 cursor-pointer"
      more.style.backgroundColor = `${color}22`
      more.style.color = color
      more.textContent = `+${remaining} more`
      more.dataset.action = "click->search-terms-modal#open:prevent:stop:capture"
      more.dataset.searchTermsModalTrigger = "true"
      more.dataset.cardLabel = "Technology"
      more.dataset.cardColor = color
      more.dataset.cardTerms = JSON.stringify(displayEntries)
      more.setAttribute("aria-label", `Show all ${displayEntries.length} technologies`)
      wrap.appendChild(more)
    }
    el.replaceChildren(wrap)
  }

  normalizeTermEntries(terms) {
    return (Array.isArray(terms) ? terms : []).map((term) => {
      if (term && typeof term === "object") {
        const label = String(term.label == null ? "" : term.label).trim()
        const identifier = String(term.identifier == null ? "" : term.identifier).trim()
        const url = String(term.url == null ? "" : term.url).trim()
        return {
          label: label || identifier,
          identifier,
          url
        }
      }
      const text = String(term == null ? "" : term).trim()
      return { label: text, identifier: "", url: "" }
    }).filter((entry) => entry.label || entry.identifier)
  }

  syncCheckbox(row, project) {
    const checkbox = row.querySelector('[data-project-selection-target="checkbox"]')
    if (!checkbox) return
    if (project.display_name) checkbox.dataset.projectName = project.display_name
    checkbox.dataset.projectTypeUnknown = project.project_type_tag ? "false" : "true"
  }

  applyRunCounts(countsById) {
    const ids = Object.keys(countsById)
    if (ids.length === 0) return

    const runStatus = this.application.getControllerForElementAndIdentifier(
      this.element,
      "search-run-status"
    )
    if (!runStatus) return
    if (typeof runStatus.applyCounts === "function") {
      runStatus.applyCounts(countsById)
    }
    if (typeof runStatus.schedulePoll === "function") {
      runStatus.schedulePoll()
    }
  }
}
