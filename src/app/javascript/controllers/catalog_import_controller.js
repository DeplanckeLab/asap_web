import { Controller } from "@hotwired/stimulus"

// Overlay + poll while an external-catalog dataset import downloads/preparses.
// When parsing starts (project_url from import_status), open the analysis view.
export default class extends Controller {
  static values = {
    statusUrl: String,
    watch: Boolean,
    pollIntervalMs: { type: Number, default: 2000 }
  }

  connect() {
    this.polling = false
    this.redirecting = false
    this._onSubmitStart = this._onSubmitStart.bind(this)
    this.element.addEventListener("turbo:submit-start", this._onSubmitStart)

    if (this.watchValue || this._shouldResumeFromStorage()) {
      this.showOverlay()
      this.startPolling()
    }
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-start", this._onSubmitStart)
    this.stopPolling()
  }

  _onSubmitStart() {
    this._rememberCandidate()
    this.showOverlay()
  }

  _storageKey() {
    return "asapCatalogImportCandidateId"
  }

  _candidateIdFromStatusUrl() {
    const match = (this.statusUrlValue || "").match(/external_catalog_candidates\/(\d+)/)
    return match ? match[1] : null
  }

  _rememberCandidate() {
    const id = this._candidateIdFromStatusUrl()
    if (id) sessionStorage.setItem(this._storageKey(), id)
  }

  _shouldResumeFromStorage() {
    const id = this._candidateIdFromStatusUrl()
    if (!id) return false
    return sessionStorage.getItem(this._storageKey()) === id
  }

  _clearRemembered() {
    const id = this._candidateIdFromStatusUrl()
    if (!id) return
    if (sessionStorage.getItem(this._storageKey()) === id) {
      sessionStorage.removeItem(this._storageKey())
    }
  }

  showOverlay() {
    if (document.getElementById("catalog-import-overlay")) return

    const overlay = document.createElement("div")
    overlay.id = "catalog-import-overlay"
    overlay.setAttribute("role", "dialog")
    overlay.setAttribute("aria-modal", "true")
    overlay.setAttribute("aria-label", "Importing dataset")
    overlay.style.cssText =
      "position:fixed;top:0;left:0;right:0;bottom:0;background-color:rgba(0,0,0,0.5);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;"
    overlay.innerHTML = `
      <div style="background:white;border-radius:12px;padding:32px 48px;text-align:center;max-width:480px;">
        <svg style="width:48px;height:48px;margin:0 auto 16px;color:#3b82f6;" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="2" opacity="0.2"/>
          <path d="M12 2a10 10 0 0 1 10 10" stroke="currentColor" stroke-width="2" stroke-linecap="round">
            <animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="1s" repeatCount="indefinite"/>
          </path>
        </svg>
        <p style="font-size:16px;font-weight:500;color:#1f2937;margin:0;">Importing dataset ...</p>
      </div>
    `
    document.body.appendChild(overlay)
    document.body.classList.add("overflow-hidden")
  }

  hideOverlay() {
    const existing = document.getElementById("catalog-import-overlay")
    if (existing) existing.remove()
    document.body.classList.remove("overflow-hidden")
  }

  startPolling() {
    if (this.polling || !this.statusUrlValue) return
    this.polling = true
    this.pollStatus()
    this.pollTimer = setInterval(() => this.pollStatus(), this.pollIntervalMsValue)
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
    this.polling = false
  }

  pollStatus() {
    if (this.redirecting) return

    fetch(this.statusUrlValue, {
      method: "GET",
      headers: {
        Accept: "application/json",
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then((data) => this.handleStatus(data))
      .catch((error) => {
        console.warn("[CatalogImport] poll failed:", error)
      })
  }

  handleStatus(data) {
    if (!data) return

    if (data.project_url) {
      this.redirecting = true
      this.stopPolling()
      this._clearRemembered()
      window.location.href = data.project_url
      return
    }

    if (data.import_status === "failed") {
      this.stopPolling()
      this._clearRemembered()
      this.hideOverlay()
      const message = data.import_error || "Import failed."
      window.alert(message)
      window.location.reload()
      return
    }

    if (data.import_status === "idle" && !data.project_url) {
      // Import finished without a readable project (should be rare); stop waiting.
      this.stopPolling()
      this._clearRemembered()
      this.hideOverlay()
    }
  }
}
