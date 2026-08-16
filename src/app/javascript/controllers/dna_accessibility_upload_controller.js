import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = [
    "sourceUpload",
    "sourceUrl",
    "dropzone",
    "fileInput",
    "urlWrap",
    "urlInput",
    "fileInfo",
    "statusText",
    "submitButton",
    "progressWrap",
    "progressBar",
    "progressDetail",
    "existingWrap",
    "existingText"
  ]

  static values = {
    chunkSize: { type: Number, default: 5 * 1024 * 1024 },
    projectId: Number,
    uploadTypeName: { type: String, default: "dna_accessibility" },
    acceptLabel: { type: String, default: ".tsv.bgz" },
    storedName: { type: String, default: "dna_accessibility.tsv.bgz" },
    present: { type: Boolean, default: false }
  }

  connect() {
    this.file = null
    this.urlValue = ""
    this.fuId = null
    this.subscription = null
    this.pollInterval = null
    this.setupDropzone()
    this.applySourceMode()
    this.updateSubmitState()
    if (this.presentValue) {
      this.setStatus("File is already saved. You can replace it with a new upload.")
    }
  }

  disconnect() {
    this.teardownWatchers()
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
    const zone = this.dropzoneTarget
    ;["dragenter", "dragover"].forEach((eventName) => {
      zone.addEventListener(eventName, (event) => {
        event.preventDefault()
        event.stopPropagation()
        if (!this.sourceUploadTarget.checked) return
        zone.classList.add("border-blue-500")
      })
    })
    ;["dragleave", "drop"].forEach((eventName) => {
      zone.addEventListener(eventName, (event) => {
        event.preventDefault()
        event.stopPropagation()
        zone.classList.remove("border-blue-500")
      })
    })
    zone.addEventListener("drop", (event) => {
      if (!this.sourceUploadTarget.checked) return
      const file = event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files[0]
      if (!file) return
      this.setFile(file)
    })
  }

  sourceChanged() {
    this.applySourceMode()
    this.updateSubmitState()
  }

  applySourceMode() {
    const uploadMode = this.sourceUploadTarget.checked
    this.dropzoneTarget.classList.toggle("hidden", !uploadMode)
    this.urlWrapTarget.classList.toggle("hidden", uploadMode)
  }

  urlChanged() {
    this.urlValue = this.urlInputTarget.value.trim()
    this.file = null
    if (this.hasFileInfoTarget) {
      this.fileInfoTarget.classList.add("hidden")
      this.fileInfoTarget.textContent = ""
    }
    this.updateSubmitState()
  }

  setFile(file) {
    const error = this.validateFilename(file.name)
    if (error) {
      this.setStatus(error, true)
      this.file = null
      this.updateSubmitState()
      return
    }

    this.file = file
    this.urlValue = ""
    if (this.hasUrlInputTarget) this.urlInputTarget.value = ""
    if (this.hasFileInfoTarget) {
      this.fileInfoTarget.classList.remove("hidden")
      this.fileInfoTarget.textContent = `${file.name} (${this.formatBytes(file.size)})`
    }
    this.setStatus("File selected. Click Save to upload.")
    this.updateSubmitState()
  }

  validateFilename(name) {
    const lower = (name || "").toLowerCase()
    const expected = (this.acceptLabelValue || "").toLowerCase()
    if (expected && lower.endsWith(expected)) return null
    return `File must end with ${this.acceptLabelValue}`
  }

  updateSubmitState() {
    const ready = this.sourceUploadTarget.checked
      ? !!this.file
      : this.urlValue.length > 0
    this.submitButtonTarget.disabled = !ready
  }

  async submit() {
    this.submitButtonTarget.disabled = true
    this.showProgress(0, "Starting...")
    try {
      if (this.sourceUploadTarget.checked) {
        await this.uploadFile()
      } else {
        await this.downloadFromUrl()
      }
    } catch (error) {
      this.setStatus(error.message || "Upload failed", true)
      this.hideProgress()
      this.updateSubmitState()
    }
  }

  async uploadFile() {
    if (!this.file) throw new Error("No file selected")

    this.fuId = null
    const totalChunks = Math.max(1, Math.ceil(this.file.size / this.chunkSizeValue))
    for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex += 1) {
      const start = chunkIndex * this.chunkSizeValue
      const end = Math.min(start + this.chunkSizeValue, this.file.size)
      const chunk = this.file.slice(start, end)
      const result = await this.uploadChunk(chunk, chunkIndex, totalChunks, this.file.size)
      if (result.fu_id) this.fuId = result.fu_id

      const uploadedSize = result.uploaded_size || end
      const pct = Math.round((uploadedSize / this.file.size) * 100)
      this.showProgress(pct, `${this.formatBytes(uploadedSize)} / ${this.formatBytes(this.file.size)}`)

      if (result.complete) {
        this.markSaved(result.saved_size)
        return
      }
    }

    throw new Error("Upload finished without completion")
  }

  async uploadChunk(chunk, chunkIndex, totalChunks, fileSize) {
    const token = document.querySelector("[name='csrf-token']")?.content
    const form = new FormData()
    form.append("chunk", chunk)
    form.append("chunk_index", chunkIndex)
    form.append("total_chunks", totalChunks)
    form.append("file_size", fileSize)
    form.append("filename", this.file.name)
    form.append("upload_type_name", this.uploadTypeNameValue)
    form.append("project_id", this.projectIdValue)
    if (this.fuId) form.append("fu_id", this.fuId)

    const response = await fetch("/fus/upload_chunk", {
      method: "POST",
      headers: { "X-CSRF-Token": token },
      body: form
    })
    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || "Upload failed")
    }
    return payload
  }

  async downloadFromUrl() {
    const url = this.urlValue
    if (!url) throw new Error("URL is required")

    const token = document.querySelector("[name='csrf-token']")?.content
    const response = await fetch("/fus/download_from_url", {
      method: "POST",
      headers: {
        "X-CSRF-Token": token,
        "Content-Type": "application/json",
        Accept: "application/json"
      },
      body: JSON.stringify({
        url,
        upload_type_name: this.uploadTypeNameValue,
        project_id: this.projectIdValue
      })
    })
    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      throw new Error(payload.error || "Unable to start download")
    }

    this.fuId = payload.fu_id
    this.showProgress(5, "Downloading file...")
    await this.watchFuCompletion(this.fuId)
  }

  watchFuCompletion(fuId) {
    return new Promise((resolve, reject) => {
      this.teardownWatchers()
      let settled = false

      const finish = (ok, detail) => {
        if (settled) return
        settled = true
        this.teardownWatchers()
        if (ok) {
          this.markSaved(detail && detail.saved_size)
          resolve()
        } else {
          reject(new Error((detail && detail.error) || "Download failed"))
        }
      }

      if (consumer && consumer.subscriptions) {
        this.subscription = consumer.subscriptions.create(
          { channel: "FuChannel", fu_id: fuId },
          {
            received: (data) => {
              if (!data || (data.fu_id && data.fu_id.toString() !== fuId.toString())) return
              if (data.status === "completed") {
                finish(true, data)
              } else if (data.status === "failed" || data.status === "download_failed") {
                finish(false, data)
              } else if (typeof data.progress === "number") {
                this.showProgress(data.progress, data.message || "Downloading file...")
              }
            }
          }
        )
      }

      this.pollInterval = window.setInterval(async () => {
        try {
          const status = await this.fetchUploadStatus(fuId)
          if (!status || !status.exists) return
          if (status.status === "completed" || (status.complete && status.status === "uploaded")) {
            finish(true, status)
          } else if (["download_failed", "preparsing_failed", "failed"].includes(status.status)) {
            finish(false, { error: `Download failed (${status.status})` })
          } else if (status.total_size > 0) {
            const pct = Math.min(99, Math.round((status.size / status.total_size) * 100))
            this.showProgress(pct, `${this.formatBytes(status.size)} / ${this.formatBytes(status.total_size)}`)
          }
        } catch (_error) {
          // Keep polling; websocket may still deliver completion.
        }
      }, 1500)
    })
  }

  async fetchUploadStatus(fuId) {
    const params = new URLSearchParams({
      fu_id: fuId,
      upload_type_name: this.uploadTypeNameValue
    })
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

  markSaved(savedSize) {
    this.hideProgress()
    this.presentValue = true
    if (this.hasExistingWrapTarget) this.existingWrapTarget.classList.remove("hidden")
    if (this.hasExistingTextTarget) {
      const sizePart = savedSize ? ` (${this.formatBytes(savedSize)})` : ""
      this.existingTextTarget.innerHTML =
        `Saved file present${sizePart}: <code>parsing/${this.storedNameValue}</code>`
    }
    this.setStatus("File saved.")
    this.file = null
    this.urlValue = ""
    if (this.hasUrlInputTarget) this.urlInputTarget.value = ""
    if (this.hasFileInputTarget) this.fileInputTarget.value = ""
    if (this.hasFileInfoTarget) {
      this.fileInfoTarget.classList.add("hidden")
      this.fileInfoTarget.textContent = ""
    }
    this.updateSubmitState()
    this.dispatch("saved", {
      detail: { uploadTypeName: this.uploadTypeNameValue }
    })
  }

  teardownWatchers() {
    if (this.pollInterval) {
      window.clearInterval(this.pollInterval)
      this.pollInterval = null
    }
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  showProgress(pct, detail) {
    this.progressWrapTarget.classList.remove("hidden")
    this.progressBarTarget.style.width = `${Math.max(0, Math.min(100, pct))}%`
    this.progressDetailTarget.textContent = detail || ""
    this.setStatus(detail || "Working...")
  }

  hideProgress() {
    this.progressWrapTarget.classList.add("hidden")
    this.progressBarTarget.style.width = "0%"
    this.progressDetailTarget.textContent = ""
  }

  setStatus(message, isError = false) {
    this.statusTextTarget.textContent = message
    this.statusTextTarget.classList.toggle("text-red-600", !!isError)
    this.statusTextTarget.classList.toggle("text-gray-700", !isError)
  }

  formatBytes(bytes) {
    const value = Number(bytes) || 0
    if (value < 1024) return `${value} B`
    if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
    if (value < 1024 * 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`
    return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GB`
  }
}
