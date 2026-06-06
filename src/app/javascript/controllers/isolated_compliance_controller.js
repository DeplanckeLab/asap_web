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

  static values = {
    chunkSize: { type: Number, default: 5 * 1024 * 1024 },
    uploadTypeName: String
  }

  connect() {
    this.subscription = null
    this.file = null
    this.urlValue = ""
    this.taskId = null
    this.fuId = null
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
    this.fuId = null
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
    const file = this.file
    const chunkSize = this.chunkSizeValue
    const totalChunks = Math.ceil(file.size / chunkSize)
    let startChunkIndex = 0

    const resumeInfo = await this.checkUploadStatus(file.name)
    if (resumeInfo && resumeInfo.exists && resumeInfo.fu_id) {
      this.fuId = resumeInfo.fu_id
      const uploadedSize = resumeInfo.size || 0
      startChunkIndex = Math.floor(uploadedSize / chunkSize)
      if (startChunkIndex >= totalChunks) {
        startChunkIndex = totalChunks - 1
      }
    }

    for (let chunkIndex = startChunkIndex; chunkIndex < totalChunks; chunkIndex += 1) {
      const start = chunkIndex * chunkSize
      const end = Math.min(start + chunkSize, file.size)
      const chunk = file.slice(start, end)
      const result = await this.uploadChunk(chunk, chunkIndex, totalChunks, file.size)

      if (result.fu_id) this.fuId = result.fu_id

      const uploadedSize = result.uploaded_size || end
      const pct = Math.round((uploadedSize / file.size) * 100)
      const mapped = Math.max(2, Math.min(40, Math.round(2 + (pct * 38) / 100)))
      this.updateProgress(mapped, `Uploading file... ${pct}%`)

      if (result.complete && result.task_id) {
        this.updateProgress(45, "Upload completed. Queueing validation...")
        return result
      }
    }

    throw new Error("Upload finished without validation task id")
  }

  async checkUploadStatus(filename) {
    const params = new URLSearchParams({ filename })
    if (this.fuId) params.append("fu_id", this.fuId)
    if (this.hasUploadTypeNameValue) {
      params.append("upload_type_name", this.uploadTypeNameValue)
    }

    const token = document.querySelector("[name='csrf-token']")?.content
    const response = await fetch(`/fus/upload_status?${params.toString()}`, {
      method: "GET",
      headers: {
        "X-CSRF-Token": token,
        Accept: "application/json"
      }
    })

    if (!response.ok) return null
    return response.json()
  }

  async uploadChunk(chunk, chunkIndex, totalChunks, fileSize) {
    const token = document.querySelector("[name='csrf-token']")?.content
    const form = new FormData()
    form.append("chunk", chunk)
    form.append("chunk_index", chunkIndex)
    form.append("total_chunks", totalChunks)
    form.append("file_size", fileSize)
    form.append("filename", this.file.name)
    form.append("schema_id", this.schemaSelectTarget.value)
    if (this.hasUploadTypeNameValue) {
      form.append("upload_type_name", this.uploadTypeNameValue)
    }
    if (this.fuId) form.append("fu_id", this.fuId)

    const response = await fetch("/fus/upload_chunk", {
      method: "POST",
      headers: { "X-CSRF-Token": token },
      body: form
    })

    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || "Unable to queue validation")
    }
    return payload
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
    const errors = this.dedupeIssues(result.errors || [])
    const warnings = this.dedupeIssues(result.warnings || [])
    const valid = result.valid
    const groups = result.check_groups || []
    const issueContext = { baseWarnings: warnings, baseErrors: errors }

    this.resultWrapTarget.classList.remove("hidden")
    this.resultBodyTarget.innerHTML = `
      <div class="mb-4 p-4 rounded border ${valid ? "border-green-300 bg-green-50" : "border-red-300 bg-red-50"}">
        <div class="font-semibold ${valid ? "text-green-800" : "text-red-800"}">
          ${valid ? "Compliant" : "Not compliant"} (${result.format?.toUpperCase() || "FILE"})
        </div>
        <div class="text-sm text-gray-700 mt-1">
          ${errors.length} error(s), ${warnings.length} warning(s)
        </div>
      </div>
      ${this.renderList("Errors", errors, "red", { defaultStatus: "failed" })}
      ${this.renderList("Warnings", warnings, "yellow", { defaultStatus: "warning" })}
      ${groups.map((group) => this.renderDetailList(group.label, group.items || [], issueContext)).join("")}
    `
  }

  promoteCheckIssues(checks, baseWarnings = [], baseErrors = []) {
    const errors = []
    const warnings = []
    checks.forEach((it) => {
      const status = this.resolveCheckStatus(it, { baseWarnings, baseErrors })
      const item = { field: it.field, message: it.message, status }
      if (status === "failed") errors.push(item)
      else if (status === "warning") warnings.push(item)
    })
    return { errors, warnings }
  }

  resolveCheckStatus(item, { defaultStatus = null, baseWarnings = [], baseErrors = [] } = {}) {
    const explicit = String(item?.status || "").trim().toLowerCase()
    if (explicit) return explicit

    const field = String(item?.field || "")
    if (field && baseWarnings.some((w) => w.field === field)) return "warning"
    if (field && baseErrors.some((e) => e.field === field)) return "failed"
    if (defaultStatus) return defaultStatus

    return "passed"
  }

  dedupeIssues(items) {
    const seen = new Set()
    return items.filter((it) => {
      const key = `${it.field || ""}|${it.message || ""}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
  }

  renderDetailList(title, items, context = {}) {
    if (!items || items.length === 0) {
      return `
        <div class="mb-4 p-3 rounded border border-slate-200 bg-slate-50">
          <div class="font-medium mb-2">${this.escape(title)} (0)</div>
          <p class="text-sm text-gray-600">No checks recorded for this category.</p>
        </div>
      `
    }
    return this.renderList(title, items, "detail", context)
  }

  renderList(title, items, color, context = {}) {
    if (!items || items.length === 0) return ""
    const defaultStatus = color === "yellow" ? "warning" : color === "red" ? "failed" : null
    const resolveOptions = { defaultStatus, ...context }
    const palette = {
      red: { code: "bg-red-100", box: "border-red-200 bg-red-50" },
      yellow: { code: "bg-yellow-100", box: "border-yellow-200 bg-yellow-50" },
      green: { code: "bg-green-100", box: "border-green-200 bg-green-50" },
      detail: { code: "bg-slate-100", box: "border-slate-200 bg-slate-50" }
    }
    const statusPalette = {
      passed: { code: "bg-green-100", badge: "bg-green-100 text-green-800", label: "Passed" },
      warning: { code: "bg-yellow-100", badge: "bg-yellow-100 text-yellow-800", label: "Warning" },
      failed: { code: "bg-red-100", badge: "bg-red-100 text-red-800", label: "Failed" },
      skipped: { code: "bg-gray-100", badge: "bg-gray-100 text-gray-700", label: "Not applicable" }
    }
    const style = palette[color] || palette.detail
    const failedCount = items.filter((it) => this.resolveCheckStatus(it, resolveOptions) === "failed").length
    const warningCount = items.filter((it) => this.resolveCheckStatus(it, resolveOptions) === "warning").length
    const summaryParts = []
    if (failedCount > 0) summaryParts.push(`${failedCount} failed`)
    if (warningCount > 0) summaryParts.push(`${warningCount} warning(s)`)
    const summary = summaryParts.length > 0 ? ` - ${summaryParts.join(", ")}` : ""
    const lines = items.map((it) => {
      const field = this.escape(it.field || "-")
      const msg = this.escape(it.message || "")
      const statusKey = this.resolveCheckStatus(it, resolveOptions)
      const st = statusPalette[statusKey] || statusPalette.passed
      const codeClass = st.code
      const badge = `<span class="ml-2 px-1.5 py-0.5 rounded text-xs ${st.badge}">${st.label}</span>`
      return `<li class="text-sm"><code class="px-1 rounded ${codeClass}">${field}</code>${badge} ${msg}</li>`
    }).join("")
    return `
      <div class="mb-4 p-3 rounded border ${style.box}">
        <div class="font-medium mb-2">${title} (${items.length})${summary}</div>
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

