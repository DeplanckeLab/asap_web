import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = [
    "schemaSelect",
    "sourceUpload",
    "sourceUrl",
    "dropzone",
    "fileInput",
    "urlWrap",
    "urlInput",
    "fileInfo",
    "statusText",
    "runButton",
    "progressWrap",
    "progressSpinner",
    "progressTitle",
    "progressBar",
    "progressDetail",
    "resultWrap",
    "resultBody"
  ]

  connect() {
    this.subscription = null
    this.file = null
    this.urlValue = ""
    this.taskId = null
    this.currentProgress = 0
    this.setupDropzone()
    this.applySourceMode()
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
  }

  openPicker() {
    if (!this.sourceUploadTarget.checked) return
    this.fileInputTarget.click()
  }

  fileSelected(event) {
    const file = event.target.files && event.target.files[0]
    if (!file) return
    this.setFile(file)
  }

  setupDropzone() {
    const dz = this.dropzoneTarget
    dz.addEventListener("dragover", (e) => {
      e.preventDefault()
      dz.classList.add("border-blue-500", "bg-blue-50")
    })
    dz.addEventListener("dragleave", () => {
      dz.classList.remove("border-blue-500", "bg-blue-50")
    })
    dz.addEventListener("drop", (e) => {
      e.preventDefault()
      dz.classList.remove("border-blue-500", "bg-blue-50")
      const file = e.dataTransfer.files && e.dataTransfer.files[0]
      if (file && this.sourceUploadTarget.checked) this.setFile(file)
    })
  }

  sourceChanged() {
    this.applySourceMode()
  }

  applySourceMode() {
    const uploadMode = this.sourceUploadTarget.checked
    this.dropzoneTarget.classList.toggle("hidden", !uploadMode)
    this.urlWrapTarget.classList.toggle("hidden", uploadMode)
    this.runButtonTarget.disabled = !this.canRun()
    this.statusTextTarget.textContent = uploadMode ? "Waiting for file selection" : "Enter a .loom or .h5ad URL"
  }

  urlChanged(event) {
    this.urlValue = (event.target.value || "").trim()
    this.file = null
    this.fileInputTarget.value = ""
    this.renderSourceInfo()
    this.runButtonTarget.disabled = !this.canRun()
    if (this.sourceUrlTarget.checked) {
      this.statusTextTarget.textContent = this.urlValue ? "Ready to run validation" : "Enter a .loom or .h5ad URL"
    }
  }

  setFile(file) {
    this.file = file
    this.urlValue = ""
    if (this.hasUrlInputTarget) this.urlInputTarget.value = ""
    this.renderSourceInfo()
    this.runButtonTarget.disabled = !this.canRun()
    this.statusTextTarget.textContent = "Ready to run validation"
  }

  renderSourceInfo() {
    this.fileInfoTarget.classList.remove("hidden")
    if (this.file) {
      this.fileInfoTarget.innerHTML = `
        <div class="bg-blue-50 rounded-md p-3 text-sm text-blue-900">
          <strong>${this.escape(this.file.name)}</strong><br/>
          ${(this.file.size / (1024 * 1024)).toFixed(2)} MB
        </div>
      `
      return
    }

    if (this.urlValue) {
      this.fileInfoTarget.innerHTML = `
        <div class="bg-blue-50 rounded-md p-3 text-sm text-blue-900">
          <strong>Server URL source</strong><br/>
          ${this.escape(this.urlValue)}
        </div>
      `
      return
    }

    this.fileInfoTarget.classList.add("hidden")
    this.fileInfoTarget.innerHTML = ""
  }

  canRun() {
    if (this.sourceUploadTarget.checked) return !!this.file
    return !!this.urlValue
  }

  async run() {
    if (!this.canRun()) return
    this.runButtonTarget.disabled = true
    this.clearStatusText()
    this.resultWrapTarget.classList.add("hidden")
    this.progressWrapTarget.classList.remove("hidden")
    this.currentProgress = 0
    this.progressBarTarget.style.width = "0%"
    if (this.hasProgressDetailTarget) this.progressDetailTarget.classList.remove("hidden")
    this.setProgressTitle("Validation in progress...", { showSpinner: true })
    this.updateProgress(2, this.sourceUploadTarget.checked ? "Uploading file..." : "Downloading file from URL...")

    try {
      const payload = this.sourceUploadTarget.checked
        ? await this.uploadWithProgress()
        : await this.queueFromUrl()

      this.taskId = payload.task_id
      this.subscribeToTask(this.taskId)
    } catch (error) {
      this.setProgressSpinner(false)
      this.clearProgressDetail()
      this.statusTextTarget.classList.remove("invisible")
      this.statusTextTarget.textContent = `Error: ${error.message}`
      this.runButtonTarget.disabled = false
    }
  }

  async uploadWithProgress() {
    const token = document.querySelector("[name='csrf-token']")?.content
    const form = new FormData()
    form.append("source", "upload")
    form.append("data_file", this.file)
    form.append("schema_id", this.schemaSelectTarget.value)

    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest()
      xhr.open("POST", "/compliance/file-check")
      if (token) xhr.setRequestHeader("X-CSRF-Token", token)
      xhr.responseType = "json"

      xhr.upload.onprogress = (event) => {
        if (!event.lengthComputable) return
        const pct = Math.round((event.loaded / event.total) * 100)
        const mapped = Math.max(2, Math.min(40, Math.round(2 + (pct * 38) / 100)))
        this.updateProgress(mapped, `Uploading file... ${pct}%`)
      }

      xhr.onload = () => {
        const payload = xhr.response || {}
        if (xhr.status >= 200 && xhr.status < 300) {
          this.updateProgress(45, "Upload completed. Queueing validation...")
          resolve(payload)
          return
        }
        reject(new Error(payload.error || "Unable to queue validation"))
      }

      xhr.onerror = () => reject(new Error("Network error during upload"))
      xhr.send(form)
    })
  }

  async queueFromUrl() {
    const token = document.querySelector("[name='csrf-token']")?.content
    const form = new FormData()
    form.append("source", "url")
    form.append("data_url", this.urlValue)
    form.append("schema_id", this.schemaSelectTarget.value)
    this.updateProgress(8, "Downloading file from URL...")

    const response = await fetch("/compliance/file-check", {
      method: "POST",
      headers: { "X-CSRF-Token": token },
      body: form
    })
    const payload = await response.json()
    if (!response.ok) throw new Error(payload.error || "Unable to queue validation")
    this.updateProgress(45, "Download completed. Queueing validation...")
    return payload
  }

  subscribeToTask(taskId) {
    if (this.subscription) this.subscription.unsubscribe()
    this.subscription = consumer.subscriptions.create(
      { channel: "IsolatedComplianceChannel", task_id: taskId },
      {
        received: (data) => this.handleUpdate(data)
      }
    )
  }

  handleUpdate(data) {
    if (!data) return
    if (data.status === "progress" || data.status === "started") {
      const message = this.progressMessage(data)
      this.updateProgress(data.progress || 5, message)
      return
    }
    if (data.status === "completed") {
      const valid = data.result?.valid
      const title = valid
        ? "Validation complete: Compliant"
        : "Validation complete: Not compliant"
      this.finishProgress(title, valid ? "success" : "warning")
      this.restoreStatusText()
      this.renderResult(data.result)
      this.runButtonTarget.disabled = false
      return
    }
    if (data.status === "failed") {
      this.finishProgress(data.message || "Validation failed", "error")
      this.restoreStatusText()
      this.runButtonTarget.disabled = false
    }
  }

  progressMessage(data) {
    const base = data.message || "Running..."
    if (data.current && data.total && !base.includes("(")) {
      return `${base} (${data.current}/${data.total})`
    }
    return base
  }

  updateProgress(value, text) {
    const nextValue = Math.max(0, Math.min(100, value))
    this.currentProgress = Math.max(this.currentProgress || 0, nextValue)
    this.progressBarTarget.style.width = `${this.currentProgress}%`
    if (this.hasProgressDetailTarget) {
      this.progressDetailTarget.classList.remove("hidden")
      this.progressDetailTarget.textContent = text
    }
  }

  clearStatusText() {
    if (!this.hasStatusTextTarget) return
    this.statusTextTarget.classList.add("invisible")
  }

  restoreStatusText() {
    if (!this.hasStatusTextTarget) return
    this.statusTextTarget.classList.remove("invisible")
    if (this.canRun()) {
      this.statusTextTarget.textContent = "Ready to run validation"
      return
    }
    if (this.sourceUploadTarget.checked) {
      this.statusTextTarget.textContent = "Waiting for file selection"
      return
    }
    this.statusTextTarget.textContent = this.urlValue
      ? "Ready to run validation"
      : "Enter a .loom or .h5ad URL"
  }

  finishProgress(title, variant = "info") {
    this.currentProgress = 100
    this.progressBarTarget.style.width = "100%"
    this.clearProgressDetail()
    this.setProgressSpinner(false)
    this.setProgressTitle(title, { variant })
  }

  clearProgressDetail() {
    if (!this.hasProgressDetailTarget) return
    this.progressDetailTarget.textContent = ""
    this.progressDetailTarget.classList.add("hidden")
  }

  setProgressSpinner(visible) {
    if (!this.hasProgressSpinnerTarget) return
    const el = this.progressSpinnerTarget
    if (visible) {
      el.classList.remove("hidden")
      el.style.removeProperty("display")
    } else {
      el.classList.add("hidden")
      el.style.display = "none"
    }
  }

  setProgressTitle(message, { showSpinner = false, variant = "info" } = {}) {
    this.setProgressSpinner(showSpinner)
    if (!this.hasProgressTitleTarget) return

    const variants = {
      info: ["text-gray-700"],
      success: ["text-green-700"],
      warning: ["text-yellow-700"],
      error: ["text-red-700"]
    }
    this.progressTitleTarget.textContent = message
    this.progressTitleTarget.classList.remove("text-gray-700", "text-green-700", "text-yellow-700", "text-red-700")
    this.progressTitleTarget.classList.add(...(variants[variant] || variants.info))
  }

  renderResult(result) {
    const errors = result.errors || []
    const warnings = result.warnings || []
    const checks = result.valid_checks || []
    const valid = result.valid
    const crossFieldChecks = checks.filter((it) => String(it.field || "").startsWith("cross-field."))
    const organismChecks = checks.filter((it) => String(it.field || "").startsWith("ontology.organism_dev_stage"))
    const semanticsChecks = checks.filter((it) => String(it.field || "").startsWith("ontology.semantics."))
    const extensionChecks = checks.filter((it) => String(it.field || "").startsWith("extension."))
    const otherChecks = checks.filter((it) => {
      const field = String(it.field || "")
      return !field.startsWith("cross-field.") &&
        !field.startsWith("ontology.organism_dev_stage") &&
        !field.startsWith("ontology.semantics.") &&
        !field.startsWith("extension.")
    })

    this.resultWrapTarget.classList.remove("hidden")
    this.resultBodyTarget.innerHTML = `
      <div class="mb-4 p-4 rounded border ${valid ? "border-green-300 bg-green-50" : "border-red-300 bg-red-50"}">
        <div class="font-semibold ${valid ? "text-green-800" : "text-red-800"}">
          ${valid ? "Compliant" : "Not compliant"} (${result.format?.toUpperCase() || "FILE"})
        </div>
        <div class="text-sm text-gray-700 mt-1">
          ${errors.length} error(s), ${warnings.length} warning(s), ${checks.length} check result(s)
        </div>
      </div>
      ${this.renderList("Errors", errors, "red")}
      ${this.renderList("Warnings", warnings, "yellow")}
      ${this.renderList("Cross-field rules", crossFieldChecks, "green")}
      ${this.renderList("Ontology semantics", semanticsChecks, "green")}
      ${this.renderList("Extension schemas", extensionChecks, "green")}
      ${this.renderList("Organism-specific rules", organismChecks, "green")}
      ${this.renderList("Other checks", otherChecks, "green")}
    `
  }

  renderList(title, items, color) {
    if (!items || items.length === 0) return ""
    const palette = {
      red: { code: "bg-red-100", box: "border-red-200 bg-red-50" },
      yellow: { code: "bg-yellow-100", box: "border-yellow-200 bg-yellow-50" },
      green: { code: "bg-green-100", box: "border-green-200 bg-green-50" }
    }
    const statusPalette = {
      passed: { code: "bg-green-100", badge: "bg-green-100 text-green-800", label: "Passed" },
      warning: { code: "bg-yellow-100", badge: "bg-yellow-100 text-yellow-800", label: "Warning" },
      failed: { code: "bg-red-100", badge: "bg-red-100 text-red-800", label: "Failed" },
      skipped: { code: "bg-gray-100", badge: "bg-gray-100 text-gray-700", label: "Not applicable" }
    }
    const style = palette[color] || palette.red
    const lines = items.map((it) => {
      const field = this.escape(it.field || "-")
      const msg = this.escape(it.message || "")
      const statusKey = String(it.status || "").toLowerCase()
      const st = statusPalette[statusKey]
      const codeClass = st ? st.code : style.code
      const badge = st ? `<span class="ml-2 px-1.5 py-0.5 rounded text-xs ${st.badge}">${st.label}</span>` : ""
      return `<li class="text-sm"><code class="px-1 rounded ${codeClass}">${field}</code>${badge} ${msg}</li>`
    }).join("")
    return `
      <div class="mb-4 p-3 rounded border ${style.box}">
        <div class="font-medium mb-2">${title} (${items.length})</div>
        <ul class="space-y-1">${lines}</ul>
      </div>
    `
  }

  escape(value) {
    return String(value ?? "").replace(/[&<>"']/g, (m) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[m]
    ))
  }
}

