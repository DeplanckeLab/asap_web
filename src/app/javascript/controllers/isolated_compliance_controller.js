import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = [
    "schemaSelect",
    "dropzone",
    "fileInput",
    "fileInfo",
    "statusText",
    "runButton",
    "progressWrap",
    "progressBar",
    "progressDetail",
    "resultWrap",
    "resultBody"
  ]

  connect() {
    this.subscription = null
    this.file = null
    this.taskId = null
    this.setupDropzone()
  }

  disconnect() {
    if (this.subscription) this.subscription.unsubscribe()
  }

  openPicker() {
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
      if (file) this.setFile(file)
    })
  }

  setFile(file) {
    this.file = file
    this.fileInfoTarget.classList.remove("hidden")
    this.fileInfoTarget.innerHTML = `
      <div class="bg-blue-50 rounded-md p-3 text-sm text-blue-900">
        <strong>${this.escape(file.name)}</strong><br/>
        ${(file.size / (1024 * 1024)).toFixed(2)} MB
      </div>
    `
    this.runButtonTarget.disabled = false
    this.statusTextTarget.textContent = "Ready to run validation"
  }

  async run() {
    if (!this.file) return
    this.runButtonTarget.disabled = true
    this.resultWrapTarget.classList.add("hidden")
    this.progressWrapTarget.classList.remove("hidden")
    this.updateProgress(2, "Queueing validation task...")

    const form = new FormData()
    form.append("data_file", this.file)
    form.append("schema_id", this.schemaSelectTarget.value)

    try {
      const token = document.querySelector("[name='csrf-token']")?.content
      const response = await fetch("/compliance/file-check", {
        method: "POST",
        headers: { "X-CSRF-Token": token },
        body: form
      })
      const payload = await response.json()
      if (!response.ok) throw new Error(payload.error || "Unable to queue validation")

      this.taskId = payload.task_id
      this.statusTextTarget.textContent = "Validation queued"
      this.subscribeToTask(this.taskId)
    } catch (error) {
      this.statusTextTarget.textContent = `Error: ${error.message}`
      this.runButtonTarget.disabled = false
    }
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
      this.updateProgress(100, data.message || "Completed")
      this.renderResult(data.result)
      this.runButtonTarget.disabled = false
      return
    }
    if (data.status === "failed") {
      this.statusTextTarget.textContent = data.message || "Validation failed"
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
    this.progressBarTarget.style.width = `${Math.max(0, Math.min(100, value))}%`
    this.progressDetailTarget.textContent = text
    this.statusTextTarget.textContent = text
  }

  renderResult(result) {
    const errors = result.errors || []
    const warnings = result.warnings || []
    const checks = result.valid_checks || []
    const valid = result.valid

    this.resultWrapTarget.classList.remove("hidden")
    this.resultBodyTarget.innerHTML = `
      <div class="mb-4 p-4 rounded border ${valid ? "border-green-300 bg-green-50" : "border-red-300 bg-red-50"}">
        <div class="font-semibold ${valid ? "text-green-800" : "text-red-800"}">
          ${valid ? "Compliant" : "Not compliant"} (${result.format?.toUpperCase() || "FILE"})
        </div>
        <div class="text-sm text-gray-700 mt-1">
          ${errors.length} error(s), ${warnings.length} warning(s), ${checks.length} passed check(s)
        </div>
      </div>
      ${this.renderList("Errors", errors, "red")}
      ${this.renderList("Warnings", warnings, "yellow")}
      ${this.renderList("Passed checks", checks, "green")}
    `
  }

  renderList(title, items, color) {
    if (!items || items.length === 0) return ""
    const palette = {
      red: { code: "bg-red-100", box: "border-red-200 bg-red-50" },
      yellow: { code: "bg-yellow-100", box: "border-yellow-200 bg-yellow-50" },
      green: { code: "bg-green-100", box: "border-green-200 bg-green-50" }
    }
    const style = palette[color] || palette.red
    const lines = items.map((it) => {
      const field = this.escape(it.field || "-")
      const msg = this.escape(it.message || "")
      return `<li class="text-sm"><code class="px-1 rounded ${style.code}">${field}</code> ${msg}</li>`
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

