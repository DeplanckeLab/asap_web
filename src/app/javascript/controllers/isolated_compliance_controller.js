import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"
import { complianceCheckReportMixin } from "controllers/concerns/compliance_check_report_mixin"

class IsolatedComplianceController extends Controller {
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
    "transferProgressWrap",
    "transferProgressLabel",
    "transferProgressBar",
    "transferProgressDetail",
    "resultWrap",
    "resultBody",
    "detailModal",
    "detailDialog",
    "detailSplit",
    "detailTitle",
    "detailStatusBadge",
    "detailBody",
    "detailYamlPanel",
    "detailYamlContent",
    "detailYamlHighlight"
  ]

  static values = {
    chunkSize: { type: Number, default: 5 * 1024 * 1024 },
    uploadTypeName: String,
    rulesSnippetUrl: String,
    rulesYamlUrl: String,
    schemaId: String,
    fileFormatsUrl: String,
    newProjectUrl: String,
    statusUrlTemplate: { type: String, default: "/compliance/file-check/__TASK_ID__/status" }
  }

  connect() {
    this.subscription = null
    this.statusPollInterval = null
    this.file = null
    this.urlValue = ""
    this.taskId = null
    this.fuId = null
    this.currentProgress = 0
    this.currentTransferProgress = 0
    this.initComplianceCheckReportState()
    this.setupDropzone()
    this.applySourceMode()
  }

  disconnect() {
    this.stopStatusPoll()
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
    this.renderSourceInfo()
    this.runButtonTarget.disabled = !this.canRun()
    this.setStatusMessage(uploadMode ? "Waiting for file selection" : "Enter a download URL")
  }

  urlChanged(event) {
    this.urlValue = (event.target.value || "").trim()
    this.file = null
    this.fileInputTarget.value = ""
    this.renderSourceInfo()
    this.runButtonTarget.disabled = !this.canRun()
    if (!this.sourceUrlTarget.checked) return

    this.setStatusMessage(this.urlValue ? "Ready to run validation" : "Enter a download URL")
  }

  setFile(file) {
    if (!this.allowedComplianceExtension(file.name)) {
      this.file = null
      this.fuId = null
      this.fileInputTarget.value = ""
      this.fileInfoTarget.classList.add("hidden")
      this.fileInfoTarget.innerHTML = ""
      this.runButtonTarget.disabled = true
      this.showUnsupportedFormatError()
      return
    }

    this.file = file
    this.fuId = null
    this.urlValue = ""
    if (this.hasUrlInputTarget) this.urlInputTarget.value = ""
    this.renderSourceInfo()
    this.runButtonTarget.disabled = !this.canRun()
    this.setStatusMessage("Ready to run validation")
  }

  renderSourceInfo() {
    if (this.sourceUploadTarget.checked) {
      if (this.file) {
        this.fileInfoTarget.classList.remove("hidden")
        this.fileInfoTarget.innerHTML = `
          <div class="bg-blue-50 rounded-md p-3 text-sm text-blue-900">
            <strong>${this.escape(this.file.name)}</strong><br/>
            ${(this.file.size / (1024 * 1024)).toFixed(2)} MB
          </div>
        `
        return
      }

      this.fileInfoTarget.classList.add("hidden")
      this.fileInfoTarget.innerHTML = ""
      return
    }

    if (this.urlValue) {
      this.fileInfoTarget.classList.remove("hidden")
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
    if (this.sourceUploadTarget.checked) {
      return !!this.file && this.allowedComplianceExtension(this.file.name)
    }
    return !!this.urlValue
  }

  allowedComplianceExtension(filenameOrUrl) {
    const value = (filenameOrUrl || "").trim().toLowerCase()
    return value.endsWith(".loom") || value.endsWith(".h5ad")
  }

  unsupportedFormatErrorHtml() {
    const fileFormatsUrl = this.hasFileFormatsUrlValue
      ? this.fileFormatsUrlValue
      : "/home/file_format"
    const newProjectUrl = this.newProjectLinkUrl()
    return `
      <span class="text-red-700">
        This tool supports only Loom (.loom) and H5AD (.h5ad) file formats.
        For other file formats supported by ASAP, you can
        <a href="${this.escape(newProjectUrl)}" class="text-blue-600 hover:underline" data-new-project-link data-action="click->isolated-compliance#openNewProject">create an ASAP project</a>
        and then run the compliance tool on the project
        (Loom file generated by ASAP). See
        <a href="${this.escape(fileFormatsUrl)}" class="text-blue-600 hover:underline" target="_blank" rel="noopener">supported file formats</a>.
      </span>
    `
  }

  newProjectLinkUrl() {
    const base = this.hasNewProjectUrlValue ? this.newProjectUrlValue : "/projects/new"
    const params = new URLSearchParams()
    if (this.sourceUrlTarget?.checked && this.urlValue) {
      params.set("file_url", this.urlValue)
    } else if (this.fuId) {
      params.set("fu_id", String(this.fuId))
    }
    const query = params.toString()
    return query ? `${base}?${query}` : base
  }

  showUnsupportedFormatError() {
    this.setStatusMessage(this.unsupportedFormatErrorHtml(), { asHtml: true })
  }

  openNewProject(event) {
    if (document.body.dataset.newProjectFormLoading === "true") {
      event.preventDefault()
      event.stopImmediatePropagation()
      return
    }

    const link = event.currentTarget
    const href = link?.getAttribute("href")
    if (!href) return

    event.preventDefault()
    document.body.dataset.newProjectFormLoading = "true"
    this.showNewProjectLoadingOverlay()

    link.classList.add("opacity-60", "cursor-not-allowed", "pointer-events-none")
    link.setAttribute("aria-disabled", "true")
    link.tabIndex = -1

    window.setTimeout(() => {
      window.location.assign(href)
    }, 0)
  }

  showNewProjectLoadingOverlay() {
    const existingOverlay = document.getElementById("new-project-form-loading-overlay")
    if (existingOverlay) existingOverlay.remove()

    const overlay = document.createElement("div")
    overlay.id = "new-project-form-loading-overlay"
    overlay.style.cssText = `
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background-color: rgba(0, 0, 0, 0.5);
      z-index: 9999;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-start;
      padding-top: 100px;
    `

    const messageContainer = document.createElement("div")
    messageContainer.style.cssText = `
      background-color: white;
      padding: 24px 32px;
      border-radius: 8px;
      box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 16px;
    `

    const spinner = document.createElement("div")
    spinner.innerHTML = `
      <svg class="animate-spin" style="width: 32px; height: 32px; color: #2563eb;" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
      </svg>
    `

    const message = document.createElement("div")
    message.textContent = "Loading new project form"
    message.style.cssText = `
      font-size: 18px;
      font-weight: 500;
      color: #374151;
    `

    messageContainer.appendChild(spinner)
    messageContainer.appendChild(message)
    overlay.appendChild(messageContainer)

    if (!document.getElementById("new-project-form-spinner-styles")) {
      const style = document.createElement("style")
      style.id = "new-project-form-spinner-styles"
      style.textContent = `
        @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
        .animate-spin { animation: spin 1s linear infinite; }
      `
      document.head.appendChild(style)
    }

    document.body.appendChild(overlay)
  }

  renderNonCompliantSolutionHint() {
    const newProjectUrl = this.newProjectLinkUrl()
    return `
      <div class="text-sm text-gray-700 mt-3 pt-3 border-t border-red-200">
        A solution to create a compliant file is to
        <a href="${this.escape(newProjectUrl)}" class="text-blue-600 hover:underline" data-new-project-link data-action="click->isolated-compliance#openNewProject">create a new ASAP project</a>,
        which includes an editor to help reach scFAIR compliance.
      </div>
    `
  }

  setStatusMessage(message, { asHtml = false } = {}) {
    if (!this.hasStatusTextTarget) return
    this.statusTextTarget.classList.remove("invisible")
    if (asHtml) {
      this.statusTextTarget.innerHTML = message
    } else {
      this.statusTextTarget.textContent = message
    }
  }

  async run() {
    if (!this.canRun()) return
    this.runButtonTarget.disabled = true
    this.clearStatusText()
    this.resultWrapTarget.classList.add("hidden")
    this.progressWrapTarget.classList.remove("hidden")
    this.currentProgress = 0
    this.currentTransferProgress = 0
    this.progressBarTarget.style.width = "0%"
    this.clearProgressDetail()
    this.setProgressTitle("Validation in progress...", { showSpinner: true })

    const transferLabel = this.sourceUploadTarget.checked
      ? "Uploading file..."
      : "Downloading file..."
    this.showTransferProgress(transferLabel)

    try {
      const payload = this.sourceUploadTarget.checked
        ? await this.uploadWithProgress()
        : await this.queueFromUrl()

      this.taskId = payload.task_id
      this.subscribeToTask(this.taskId)
    } catch (error) {
      this.hideTransferProgress()
      this.setProgressSpinner(false)
      this.clearProgressDetail()
      if (error.unsupportedFormat) {
        this.showUnsupportedFormatError()
      } else {
        this.setStatusMessage(`Error: ${error.message}`)
      }
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
      this.updateTransferProgress(
        pct,
        `${this.formatBytes(uploadedSize)} / ${this.formatBytes(file.size)}`
      )

      if (result.complete && result.task_id) {
        this.hideTransferProgress()
        this.updateProgress(5, "Upload completed. Queueing validation...")
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
      if (payload.error_code === "unsupported_file_format") {
        const err = new Error(payload.error || "Unsupported file format")
        err.unsupportedFormat = true
        throw err
      }
      throw new Error(payload.error || "Unable to queue validation")
    }
    return payload
  }

  async parseJsonResponse(response) {
    const text = await response.text()
    if (!text) return {}
    try {
      return JSON.parse(text)
    } catch (_error) {
      throw new Error(text.slice(0, 200).trim() || "Unexpected server response")
    }
  }

  async queueFromUrl() {
    const token = document.querySelector("[name='csrf-token']")?.content
    const form = new FormData()
    form.append("source", "url")
    form.append("data_url", this.urlValue)
    form.append("schema_id", this.schemaSelectTarget.value)

    const response = await fetch("/compliance/file-check", {
      method: "POST",
      headers: { "X-CSRF-Token": token, Accept: "application/json" },
      body: form
    })
    const payload = await this.parseJsonResponse(response)
    if (!response.ok) {
      if (payload.error_code === "unsupported_file_format") {
        const err = new Error(payload.error || "Unsupported file format")
        err.unsupportedFormat = true
        throw err
      }
      throw new Error(payload.error || "Unable to queue validation")
    }
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
    this.checkTaskStatus(taskId)
    this.startStatusPoll(taskId)
  }

  statusUrl(taskId) {
    return this.statusUrlTemplateValue.replace("__TASK_ID__", encodeURIComponent(taskId))
  }

  async checkTaskStatus(taskId) {
    if (!taskId || taskId !== this.taskId) return

    try {
      const token = document.querySelector("[name='csrf-token']")?.content
      const response = await fetch(this.statusUrl(taskId), {
        method: "GET",
        headers: {
          "X-CSRF-Token": token,
          Accept: "application/json"
        }
      })
      if (!response.ok) return

      const data = await response.json()
      this.handleUpdate(data)
    } catch (_error) {
      // Polling will retry.
    }
  }

  startStatusPoll(taskId) {
    this.stopStatusPoll()
    this.statusPollInterval = setInterval(() => {
      if (taskId !== this.taskId) {
        this.stopStatusPoll()
        return
      }
      this.checkTaskStatus(taskId)
    }, 2000)
  }

  stopStatusPoll() {
    if (!this.statusPollInterval) return
    clearInterval(this.statusPollInterval)
    this.statusPollInterval = null
  }

  handleUpdate(data) {
    if (!data) return
    if (data.status === "downloading") {
      this.showTransferProgress("Downloading file...")
      this.updateTransferProgress(
        data.transfer_progress,
        this.transferProgressDetailText(data)
      )
      return
    }
    if (data.status === "queued") {
      this.hideTransferProgress()
      this.updateProgress(data.progress || 5, data.message || "Validation queued...")
      return
    }
    if (data.status === "progress" || data.status === "started") {
      this.hideTransferProgress()
      const message = this.progressMessage(data)
      this.updateProgress(data.progress || 5, message)
      return
    }
    if (data.status === "completed") {
      this.stopStatusPoll()
      if (data.fu_id && !this.fuId) this.fuId = data.fu_id
      const valid = data.result?.valid
      const title = valid
        ? "Validation complete: Compliant"
        : "Validation complete: Not compliant"
      this.finishProgress(title, valid ? "success" : "warning")
      this.restoreStatusText()
      this.renderResult(data.result, {
        showResultBanner: true,
        revealResultWrap: true
      })
      if (data.result?.schema_id && this.hasSchemaIdValue) {
        this.schemaIdValue = data.result.schema_id
      }
      this.runButtonTarget.disabled = false
      return
    }
    if (data.status === "failed") {
      this.stopStatusPoll()
      this.hideTransferProgress()
      if (data.error_code === "unsupported_file_format") {
        this.showUnsupportedFormatError()
      } else {
        this.setStatusMessage(`Error: ${data.message || data.error || "Validation failed"}`)
      }
      this.finishProgress(data.message || "Validation failed", "error")
      this.restoreStatusText()
      this.runButtonTarget.disabled = false
    }
  }

  transferProgressDetailText(data) {
    const downloaded = Number(data.transfer_downloaded) || 0
    const total = Number(data.transfer_total) || 0
    if (total > 0) {
      const pct = data.transfer_progress != null
        ? data.transfer_progress
        : Math.round((downloaded / total) * 100)
      return `${pct}% (${this.formatBytes(downloaded)} / ${this.formatBytes(total)})`
    }
    if (downloaded > 0) {
      return this.formatBytes(downloaded)
    }
    return ""
  }

  showTransferProgress(label) {
    if (!this.hasTransferProgressWrapTarget) return
    this.currentTransferProgress = 0
    this.transferProgressWrapTarget.classList.remove("hidden")
    if (this.hasTransferProgressLabelTarget) {
      this.transferProgressLabelTarget.textContent = label
    }
    if (this.hasTransferProgressBarTarget) {
      this.transferProgressBarTarget.style.width = "0%"
    }
    if (this.hasTransferProgressDetailTarget) {
      this.transferProgressDetailTarget.textContent = ""
    }
  }

  updateTransferProgress(value, detail = "") {
    if (!this.hasTransferProgressWrapTarget) return

    const hasPercent = value != null && !Number.isNaN(Number(value))
    const nextValue = hasPercent
      ? Math.max(0, Math.min(100, Math.round(Number(value))))
      : null

    if (nextValue != null) {
      this.currentTransferProgress = Math.max(this.currentTransferProgress || 0, nextValue)
      if (this.hasTransferProgressBarTarget) {
        this.transferProgressBarTarget.classList.remove("animate-pulse")
        this.transferProgressBarTarget.style.width = `${this.currentTransferProgress}%`
      }
    } else if (this.hasTransferProgressBarTarget) {
      this.transferProgressBarTarget.style.width = "100%"
      this.transferProgressBarTarget.classList.add("animate-pulse")
    }

    if (this.hasTransferProgressDetailTarget) {
      this.transferProgressDetailTarget.textContent = detail
    }
  }

  hideTransferProgress() {
    if (!this.hasTransferProgressWrapTarget) return
    this.transferProgressWrapTarget.classList.add("hidden")
    if (this.hasTransferProgressBarTarget) {
      this.transferProgressBarTarget.style.width = "0%"
      this.transferProgressBarTarget.classList.remove("animate-pulse")
    }
    if (this.hasTransferProgressDetailTarget) {
      this.transferProgressDetailTarget.textContent = ""
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
      this.setStatusMessage("Ready to run validation")
      return
    }
    if (this.sourceUploadTarget.checked) {
      this.setStatusMessage("Waiting for file selection")
      return
    }
    this.setStatusMessage(
      this.urlValue ? "Ready to run validation" : "Enter a download URL"
    )
  }

  finishProgress(title, variant = "info") {
    this.hideTransferProgress()
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
}

Object.assign(IsolatedComplianceController.prototype, complianceCheckReportMixin)

export default IsolatedComplianceController

