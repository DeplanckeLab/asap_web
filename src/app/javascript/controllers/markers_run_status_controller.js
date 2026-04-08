import { Controller } from "@hotwired/stimulus"

// Listens for asap:markers-run-status-changed (from ActionCable via channels/consumer.js).
// Refreshes the metadata markers badge for that annot and the Identify markers tab when open.
export default class extends Controller {
  static values = { projectId: Number }

  connect() {
    this._onMarkersRunStatus = this._onMarkersRunStatus.bind(this)
    this._onMarkersQueuePosition = this._onMarkersQueuePosition.bind(this)
    document.addEventListener("asap:markers-run-status-changed", this._onMarkersRunStatus)
    document.addEventListener("asap:markers-queue-position-changed", this._onMarkersQueuePosition)
  }

  disconnect() {
    document.removeEventListener("asap:markers-run-status-changed", this._onMarkersRunStatus)
    document.removeEventListener("asap:markers-queue-position-changed", this._onMarkersQueuePosition)
  }

  _onMarkersRunStatus(ev) {
    const d = ev.detail || {}
    if (Number(d.projectId) !== this.projectIdValue) return

    if (d.annotId == null || d.annotId === "") {
      if (typeof window.prefetchMarkersStatusForVisibleMetadata === "function") {
        window.prefetchMarkersStatusForVisibleMetadata()
      }
      return
    }

    const annotIdStr = String(d.annotId)
    const btn = document.querySelector(
      `.category-annot-btn[data-metadata-id="${annotIdStr.replace(/"/g, "")}"]`
    )
    const evidencesUrl = btn?.dataset?.annotEvidencesUrl || this._firstEvidencesUrlOnPage()
    if (!evidencesUrl) return

    let catIdx = 0
    if (btn?.dataset?.catIdx != null) {
      const n = parseInt(btn.dataset.catIdx, 10)
      if (!Number.isNaN(n)) catIdx = n
    }

    if (typeof window.peekAnnotationMarkersStatus === "function") {
      window.peekAnnotationMarkersStatus(annotIdStr, catIdx, evidencesUrl)
    }

    const overlay = document.getElementById("annotation-popup-overlay")
    const visible =
      overlay &&
      overlay.style.display !== "none" &&
      window.getComputedStyle(overlay).display !== "none"
    if (!visible) return

    const apd = window._annotPopupData
    if (!apd || apd.metadataId == null || String(apd.metadataId) !== annotIdStr) return

    if (apd.activeTab === "evidences" && typeof window.loadAnnotationEvidences === "function") {
      window.loadAnnotationEvidences(true)
    }
  }

  _firstEvidencesUrlOnPage() {
    const any = document.querySelector(".category-annot-btn[data-annot-evidences-url]")
    return any?.dataset?.annotEvidencesUrl || ""
  }

  _onMarkersQueuePosition(ev) {
    const d = ev.detail || {}
    if (Number(d.projectId) !== this.projectIdValue) return

    const note = d.markersQueueNote
    if (note == null || note === "") return

    const annotIdStr = String(d.annotId)
    const runIdStr = d.runId != null ? String(d.runId) : ""
    const selector = runIdStr
      ? `[data-markers-queue-live][data-annot-id="${annotIdStr}"][data-run-id="${runIdStr}"]`
      : `[data-markers-queue-live][data-annot-id="${annotIdStr}"]`
    const el = document.querySelector(selector)
    if (!el) return

    el.textContent = note

    const hover = d.slurmQueueHover
    if (hover != null && hover !== "") {
      window._annotSlurmQueueHover = window._annotSlurmQueueHover || {}
      window._annotSlurmQueueHover[annotIdStr] = hover
      const badge = document.querySelector(`.metadata-markers-status[data-metadata-id="${annotIdStr}"]`)
      if (badge && badge.dataset.markersState === "queued") {
        badge.setAttribute("title", hover)
        badge.setAttribute("aria-label", hover)
      }
      const apd = window._annotPopupData
      if (apd && apd.evidences && String(apd.metadataId) === annotIdStr) {
        apd.evidences.slurmQueueHover = hover
      }
      if (typeof window.refreshAnnotPopupTitle === "function") {
        window.refreshAnnotPopupTitle()
      }
    }
  }
}
