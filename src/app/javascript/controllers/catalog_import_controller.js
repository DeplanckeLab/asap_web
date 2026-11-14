import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Overlay + ActionCable (with poll fallback) while an external-catalog dataset
// import downloads/preparses. When parsing starts (project_url from
// import_status), open the analysis view.
export default class extends Controller {
  static values = {
    statusUrl: String,
    watch: Boolean,
    pollIntervalMs: { type: Number, default: 2000 }
  }

  // Display order for overall progress. creating/linking share one slot.
  static STEP_ORDER = [
    "queued",
    "downloading",
    "preparsing",
    "creating_project",
    "opening"
  ]

  static STEP_WIDTHS = {
    queued: 8,
    downloading: 28,
    preparsing: 55,
    creating_project: 78,
    linking_project: 78,
    opening: 100,
    failed: 100
  }

  connect() {
    this.polling = false
    this.redirecting = false
    this.choiceShown = false
    this.subscription = null
    this.currentTransferProgress = 0
    this.overallProgress = 0
    this.highestStepRank = -1
    this.overlayEls = null
    this._onSubmitStart = this._onSubmitStart.bind(this)
    this.element.addEventListener("turbo:submit-start", this._onSubmitStart)

    if (this.watchValue || this._shouldResumeFromStorage()) {
      this.showOverlay()
      this.subscribe()
      this.startPolling()
    }
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-start", this._onSubmitStart)
    this.unsubscribe()
    this.stopPolling()
  }

  _onSubmitStart() {
    this._rememberCandidate()
    this.showOverlay()
    this.subscribe()
    this.startPolling()
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
    if (document.getElementById("catalog-import-overlay")) {
      this.cacheOverlayEls()
      return
    }

    const overlay = document.createElement("div")
    overlay.id = "catalog-import-overlay"
    overlay.setAttribute("role", "dialog")
    overlay.setAttribute("aria-modal", "true")
    overlay.setAttribute("aria-label", "Importing dataset")
    overlay.style.cssText =
      "position:fixed;top:0;left:0;right:0;bottom:0;background-color:rgba(0,0,0,0.5);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;"
    overlay.innerHTML = `
      <div style="background:white;border-radius:12px;padding:28px 36px;text-align:center;max-width:520px;width:92%;">
        <style>
          @keyframes catalog-import-spin {
            from { transform: rotate(0deg); }
            to { transform: rotate(360deg); }
          }
          @keyframes catalog-import-pulse {
            0%, 100% { opacity: 0.55; }
            50% { opacity: 1; }
          }
        </style>
        <div data-catalog-import-progress
             style="display:flex;align-items:center;justify-content:center;margin-bottom:14px;">
          <div style="width:22px;height:22px;border:3px solid #d1d5db;border-top-color:#3b82f6;border-radius:50%;animation:catalog-import-spin 1s linear infinite;"></div>
        </div>
        <p data-catalog-import-status
           style="font-size:16px;font-weight:500;color:#1f2937;margin:0 0 12px;">
          Importing dataset...
        </p>
        <div data-catalog-import-choice style="display:none;text-align:left;"></div>
        <div data-catalog-import-progress
             style="width:100%;height:10px;background-color:#e5e7eb;border-radius:9999px;overflow:hidden;margin-bottom:16px;">
          <div data-catalog-import-bar
               style="height:100%;width:8%;background-color:#3b82f6;transition:width 0.4s ease;"></div>
        </div>
        <div data-catalog-import-transfer-wrap style="display:none;margin-bottom:16px;text-align:left;">
          <div style="display:flex;justify-content:space-between;align-items:baseline;gap:8px;margin-bottom:6px;">
            <span data-catalog-import-transfer-label
                  style="font-size:12px;font-weight:500;color:#4b5563;">Download</span>
            <span data-catalog-import-transfer-detail
                  style="font-size:12px;color:#6b7280;"></span>
          </div>
          <div style="width:100%;height:8px;background-color:#e5e7eb;border-radius:9999px;overflow:hidden;">
            <div data-catalog-import-transfer-bar
                 style="height:100%;width:0%;background-color:#60a5fa;transition:width 0.35s ease;"></div>
          </div>
        </div>
        <div data-catalog-import-steps data-catalog-import-progress
             style="text-align:left;font-size:13px;color:#6b7280;line-height:1.7;">
          <div data-step-key="queued">1. Queued</div>
          <div data-step-key="downloading">2. Downloading dataset</div>
          <div data-step-key="preparsing">3. Preparsing file</div>
          <div data-step-key="creating_project">4. Creating project</div>
          <div data-step-key="opening">5. Opening analysis</div>
        </div>
      </div>
    `
    document.body.appendChild(overlay)
    document.body.classList.add("overflow-hidden")
    this.overallProgress = 0
    this.highestStepRank = -1
    this.currentTransferProgress = 0
    this.cacheOverlayEls()
  }

  cacheOverlayEls() {
    const root = document.getElementById("catalog-import-overlay")
    if (!root) {
      this.overlayEls = null
      return
    }
    this.overlayEls = {
      status: root.querySelector("[data-catalog-import-status]"),
      bar: root.querySelector("[data-catalog-import-bar]"),
      transferWrap: root.querySelector("[data-catalog-import-transfer-wrap]"),
      transferLabel: root.querySelector("[data-catalog-import-transfer-label]"),
      transferDetail: root.querySelector("[data-catalog-import-transfer-detail]"),
      transferBar: root.querySelector("[data-catalog-import-transfer-bar]"),
      steps: root.querySelector("[data-catalog-import-steps]")
    }
  }

  hideOverlay() {
    const existing = document.getElementById("catalog-import-overlay")
    if (existing) existing.remove()
    document.body.classList.remove("overflow-hidden")
    this.overlayEls = null
  }

  subscribe() {
    const candidateId = this._candidateIdFromStatusUrl()
    if (!candidateId || this.subscription) return

    this.subscription = consumer.subscriptions.create(
      { channel: "ExternalCatalogImportChannel", candidate_id: Number(candidateId) },
      {
        received: (data) => this.handleProgress(data)
      }
    )
  }

  unsubscribe() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
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

    if (data.import_status === "awaiting_matrix") {
      this.unsubscribe()
      this.stopPolling()
      if (data.can_choose_matrix && Array.isArray(data.matrix_choices) && data.matrix_choices.length > 0) {
        this.showMatrixChoice(data)
      } else {
        // Someone else's import is waiting for their choice: leave this page usable.
        this._clearRemembered()
        this.hideOverlay()
      }
      return
    }

    this.handleProgress(data)

    if (data.project_url) {
      this.redirecting = true
      this.unsubscribe()
      this.stopPolling()
      this._clearRemembered()
      window.location.href = data.project_url
      return
    }

    if (data.import_status === "failed") {
      this.unsubscribe()
      this.stopPolling()
      this._clearRemembered()
      this.hideOverlay()
      const message = data.import_error || "Import failed."
      window.alert(message)
      window.location.reload()
      return
    }

    if (data.import_status === "idle" && !data.project_url) {
      this.unsubscribe()
      this.stopPolling()
      this._clearRemembered()
      this.hideOverlay()
    }
  }

  handleProgress(data) {
    if (!data) return
    if (!this.overlayEls) this.cacheOverlayEls()
    if (!this.overlayEls) return

    const step = (data.step || "").toString()
    if (step === "choose_matrix") {
      // The broadcast is the same for every viewer; the status endpoint says whether this one may choose.
      if (!this.choiceShown) this.pollStatus()
      return
    }
    const rank = this.stepRank(step)
    // Ignore stale websocket/poll payloads that would move the overall UI backwards.
    if (step !== "failed" && rank >= 0 && rank < this.highestStepRank) {
      return
    }
    if (rank > this.highestStepRank) this.highestStepRank = rank

    const message = data.message || this.defaultMessageForStep(step)
    if (this.overlayEls.status && message) {
      this.overlayEls.status.textContent = message
    }

    this.updateSteps(step, data.steps_completed)
    this.updateOverallBar(step)
    this.updateTransferBar(step, data)
  }

  // H5AD with several matrices: radio list in the overlay. Plain form POSTs (the server redirects back to this
  // page, which resumes the overlay). Paths come from the uploaded file, so text is set with textContent only.
  showMatrixChoice(data) {
    if (this.choiceShown) return
    if (!document.getElementById("catalog-import-overlay")) this.showOverlay()
    this.cacheOverlayEls()
    const root = document.getElementById("catalog-import-overlay")
    const panel = root && root.querySelector("[data-catalog-import-choice]")
    if (!panel) return
    this.choiceShown = true

    root.querySelectorAll("[data-catalog-import-progress], [data-catalog-import-transfer-wrap]").forEach((el) => {
      el.style.display = "none"
    })
    root.setAttribute("aria-label", "Choose the expression matrix")
    if (this.overlayEls && this.overlayEls.status) {
      this.overlayEls.status.textContent = "Choose the expression matrix"
      this.overlayEls.status.style.fontWeight = "600"
    }

    const el = (tag, text, css) => {
      const node = document.createElement(tag)
      if (text != null) node.textContent = text
      if (css) node.style.cssText = css
      return node
    }

    panel.replaceChildren()
    panel.appendChild(el(
      "p",
      "This file contains several matrices. The one you pick becomes the main matrix of the project; " +
        "the others are kept as extra layers.",
      "font-size:13px;color:#4b5563;margin:0 0 14px;"
    ))

    const form = this.buildPostForm(data.choose_matrix_url)
    const choices = data.matrix_choices
    const recommended = data.recommended_matrix || choices[0].path
    choices.forEach((choice) => {
      const label = el(
        "label",
        null,
        "display:flex;gap:10px;align-items:flex-start;padding:8px 10px;border:1px solid #e5e7eb;" +
          "border-radius:8px;margin-bottom:8px;cursor:pointer;"
      )
      const input = document.createElement("input")
      input.type = "radio"
      input.name = "sel"
      input.value = choice.path
      input.checked = choice.path === recommended
      input.style.marginTop = "3px"
      const text = el("div", null, "min-width:0;")
      const title = el("div", null, "display:flex;flex-wrap:wrap;gap:6px;align-items:center;")
      title.appendChild(el(
        "span",
        choice.path,
        "font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;color:#111827;word-break:break-all;"
      ))
      if (choice.path === recommended) {
        title.appendChild(el(
          "span",
          "Recommended",
          "font-size:11px;font-weight:600;color:#1e40af;background:#dbeafe;border-radius:9999px;padding:1px 8px;"
        ))
      }
      text.appendChild(title)
      text.appendChild(el("div", this.describeMatrix(choice), "font-size:12px;color:#6b7280;margin-top:2px;"))
      label.appendChild(input)
      label.appendChild(text)
      form.appendChild(label)
    })

    const submit = el(
      "button",
      "Import with this matrix",
      "background:#111827;color:white;border:0;border-radius:6px;padding:8px 16px;font-size:14px;" +
        "font-weight:500;cursor:pointer;margin-top:6px;"
    )
    submit.type = "submit"
    form.addEventListener("submit", () => { submit.disabled = true })
    form.appendChild(submit)
    panel.appendChild(form)

    if (data.cancel_import_url) {
      const cancelForm = this.buildPostForm(data.cancel_import_url)
      const cancel = el(
        "button",
        "Cancel import",
        "background:none;border:0;color:#6b7280;font-size:13px;text-decoration:underline;cursor:pointer;" +
          "padding:0;margin-top:12px;"
      )
      cancel.type = "submit"
      cancelForm.appendChild(cancel)
      cancelForm.addEventListener("submit", () => this._clearRemembered())
      panel.appendChild(cancelForm)
    }

    panel.style.display = "block"
  }

  buildPostForm(action) {
    const form = document.createElement("form")
    form.method = "post"
    form.action = action
    form.setAttribute("data-turbo", "false")
    const token = document.querySelector('meta[name="csrf-token"]')
    const param = document.querySelector('meta[name="csrf-param"]')
    if (token) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = (param && param.content) || "authenticity_token"
      input.value = token.content
      form.appendChild(input)
    }
    return form
  }

  describeMatrix(choice) {
    const parts = []
    const fmt = (n) => Number(n).toLocaleString()
    if (choice.nber_rows != null && choice.nber_cols != null) {
      parts.push(`${fmt(choice.nber_rows)} genes × ${fmt(choice.nber_cols)} cells`)
    }
    if (choice.is_count === true) parts.push("integer counts")
    else if (choice.is_count === false) parts.push("non-integer values (e.g. normalized)")
    if (choice.dtype) parts.push(choice.dtype)
    return parts.join(" · ")
  }

  stepRank(step) {
    if (step === "linking_project") return this.constructor.STEP_ORDER.indexOf("creating_project")
    if (step === "failed") return this.constructor.STEP_ORDER.length
    return this.constructor.STEP_ORDER.indexOf(step)
  }

  defaultMessageForStep(step) {
    const messages = {
      queued: "Import queued...",
      downloading: "Downloading dataset...",
      preparsing: "Preparsing file...",
      creating_project: "Creating project...",
      linking_project: "Linking existing project...",
      opening: "Opening analysis...",
      failed: "Import failed."
    }
    return messages[step] || "Importing dataset..."
  }

  updateSteps(currentStep, completedRaw) {
    if (!this.overlayEls.steps) return

    const completed = new Set((completedRaw || []).map((s) => String(s)))
    if (currentStep === "linking_project") {
      this.ensureLinkingStepLabel()
    }

    const nodes = this.overlayEls.steps.querySelectorAll("[data-step-key]")
    nodes.forEach((node) => {
      const key = node.getAttribute("data-step-key")
      const isCurrent = key === currentStep ||
        (currentStep === "linking_project" && key === "creating_project")
      const isDone = completed.has(key) ||
        (currentStep === "linking_project" && key === "creating_project" && completed.has("linking_project"))
      node.style.fontWeight = isCurrent || isDone ? "600" : "400"
      node.style.color = isCurrent || isDone ? "#374151" : "#6b7280"
    })
  }

  ensureLinkingStepLabel() {
    const node = this.overlayEls.steps.querySelector('[data-step-key="creating_project"]')
    if (node) node.textContent = "4. Linking existing project"
  }

  updateOverallBar(step) {
    if (!this.overlayEls.bar) return

    const widths = this.constructor.STEP_WIDTHS
    const target = widths[step] != null ? widths[step] : 12
    this.overallProgress = Math.max(this.overallProgress || 0, target)
    this.overlayEls.bar.style.width = `${this.overallProgress}%`
  }

  updateTransferBar(step, data) {
    if (!this.overlayEls.transferWrap) return

    if (step !== "downloading") {
      this.hideTransferBar()
      return
    }

    this.overlayEls.transferWrap.style.display = "block"
    if (this.overlayEls.transferLabel) {
      this.overlayEls.transferLabel.textContent = "Download"
    }

    const downloaded = Number(data.transfer_downloaded) || 0
    const total = Number(data.transfer_total) || 0
    const transfer = data.transfer_progress
    const hasPercent = transfer != null && !Number.isNaN(Number(transfer))

    if (hasPercent) {
      const pct = Math.max(0, Math.min(100, Math.round(Number(transfer))))
      this.currentTransferProgress = Math.max(this.currentTransferProgress || 0, pct)
      if (this.overlayEls.transferBar) {
        this.overlayEls.transferBar.style.animation = ""
        this.overlayEls.transferBar.style.width = `${this.currentTransferProgress}%`
      }
      if (this.overlayEls.transferDetail) {
        this.overlayEls.transferDetail.textContent = total > 0
          ? `${this.currentTransferProgress}% (${this.formatBytes(downloaded)} / ${this.formatBytes(total)})`
          : `${this.currentTransferProgress}%`
      }
      return
    }

    // Unknown Content-Length: keep the bar at 0% (bytes shown in the label).
    // Do not use 100% here — width transition would animate from full to the first real %.
    if (this.overlayEls.transferBar) {
      this.overlayEls.transferBar.style.animation = ""
      this.overlayEls.transferBar.style.width = "0%"
    }
    if (this.overlayEls.transferDetail) {
      this.overlayEls.transferDetail.textContent = downloaded > 0
        ? this.formatBytes(downloaded)
        : "Starting download..."
    }
  }

  hideTransferBar() {
    if (!this.overlayEls.transferWrap) return
    this.overlayEls.transferWrap.style.display = "none"
    if (this.overlayEls.transferBar) {
      this.overlayEls.transferBar.style.width = "0%"
      this.overlayEls.transferBar.style.animation = ""
    }
    if (this.overlayEls.transferDetail) {
      this.overlayEls.transferDetail.textContent = ""
    }
    this.currentTransferProgress = 0
  }

  formatBytes(bytes) {
    const value = Number(bytes) || 0
    if (value < 1024) return `${value} B`
    if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
    if (value < 1024 * 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(2)} MB`
    return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GB`
  }
}
