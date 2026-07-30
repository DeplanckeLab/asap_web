import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Handles metadata schema validation for projects
export default class extends Controller {
  static targets = [
    "result",
    "loading",
    "validateButton",
    "progressBar",
    "progressDetail",
    "progressPercent"
  ]
  static values = {
    projectId: Number,
    statusUrl: String,
    validateUrl: String
  }

  connect() {
    this.pollingInterval = null
    this.subscription = null
    this.currentProgress = 0
    this.completed = false
  }

  disconnect() {
    this.stopPolling()
    this.unsubscribe()
  }

  async runValidation(event) {
    event.preventDefault()

    this.completed = false
    this.currentProgress = 0
    this.showLoading()
    await this.subscribeToCompliance()

    try {
      const response = await fetch(this.validateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.getCSRFToken()
        }
      })

      // Websocket may already have completed and started reload while fetch was in flight.
      if (this.completed) return

      if (!response.ok) {
        const error = await response.json().catch(() => ({}))
        this.showError(error.error || "Failed to start validation")
        return
      }

      const data = await response.json().catch(() => ({}))
      if (this.completed) return

      if (data.status === "completed" || data.status === "error") {
        this.finishAndReload(data)
        return
      }

      this.startPolling()
    } catch (error) {
      if (this.completed) return
      console.error("Validation error:", error)
      this.showError("Failed to start validation. Please try again.")
    }
  }

  subscribeToCompliance() {
    if (!this.hasProjectIdValue || !this.projectIdValue) return Promise.resolve()
    if (!consumer || !consumer.subscriptions) return Promise.resolve()

    this.unsubscribe()

    return new Promise((resolve) => {
      let settled = false
      const settle = () => {
        if (settled) return
        settled = true
        resolve()
      }

      this.subscription = consumer.subscriptions.create(
        { channel: "ComplianceChannel", project_id: this.projectIdValue },
        {
          connected: () => settle(),
          received: (data) => this.handleComplianceUpdate(data)
        }
      )

      setTimeout(settle, 1000)
    })
  }

  unsubscribe() {
    if (!this.subscription) return
    this.subscription.unsubscribe()
    this.subscription = null
  }

  handleComplianceUpdate(data) {
    if (!data || this.completed) return

    switch (data.status) {
      case "started":
      case "validating":
      case "progress":
        this.updateProgress(data.progress || this.currentProgress || 1, data.message || "Validation in progress...")
        break
      case "completed":
        this.finishAndReload(data)
        break
      case "failed":
        this.showError(data.message || data.error || "Validation failed")
        break
    }
  }

  startPolling() {
    this.stopPolling()
    this.pollingInterval = setInterval(() => {
      this.checkStatus()
    }, 2000)
  }

  stopPolling() {
    if (!this.pollingInterval) return
    clearInterval(this.pollingInterval)
    this.pollingInterval = null
  }

  async checkStatus() {
    if (!this.hasStatusUrlValue || this.completed) return

    try {
      const response = await fetch(this.statusUrlValue, {
        headers: { Accept: "application/json" }
      })
      if (!response.ok) return

      const data = await response.json()
      if (data.has_result && data.validated_at && this.validationStartedAt) {
        const validatedAt = Date.parse(data.validated_at)
        if (!Number.isNaN(validatedAt) && validatedAt >= this.validationStartedAt) {
          this.finishAndReload(data)
        }
      }
    } catch (error) {
      console.error("Status check error:", error)
    }
  }

  finishAndReload(data) {
    if (this.completed) return
    this.completed = true
    this.stopPolling()
    this.unsubscribe()
    this.updateProgress(100, data?.message || "Validation complete. Reloading...")
    window.location.reload()
  }

  updateProgress(value, text) {
    const nextValue = Math.max(0, Math.min(100, Math.round(Number(value) || 0)))
    this.currentProgress = Math.max(this.currentProgress || 0, nextValue)

    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${this.currentProgress}%`
    }
    if (this.hasProgressPercentTarget) {
      this.progressPercentTarget.textContent = `${this.currentProgress}%`
    }
    if (this.hasProgressDetailTarget && text) {
      this.progressDetailTarget.textContent = text
    }
  }

  showLoading() {
    this.validationStartedAt = Date.now()
    this.ensureLoadingModalMarkup()
    this.resetProgressUi()

    if (this.hasResultTarget) {
      this.resultTarget.classList.add("hidden")
    }
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.remove("hidden")
    }
    if (this.hasValidateButtonTarget) {
      this.validateButtonTarget.disabled = true
      this.validateButtonTarget.classList.add("opacity-50", "cursor-not-allowed")
    }
  }

  ensureLoadingModalMarkup() {
    if (!this.hasLoadingTarget) return
    if (this.hasProgressBarTarget && this.hasProgressDetailTarget && this.hasProgressPercentTarget) return

    this.loadingTarget.innerHTML = `
      <div class="absolute inset-0 bg-gray-900 bg-opacity-50"></div>
      <div class="relative bg-white rounded-xl shadow-xl px-8 py-6 w-full max-w-md">
        <div class="flex items-center gap-3 mb-4">
          <svg class="animate-spin h-6 w-6 text-blue-600 shrink-0" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          <div class="min-w-0 flex-1">
            <div class="flex items-center justify-between gap-3">
              <span class="text-gray-700 font-medium">Validation in progress</span>
              <span class="text-sm text-gray-500 tabular-nums" data-metadata-validation-target="progressPercent">0%</span>
            </div>
          </div>
        </div>
        <div class="h-2 bg-gray-200 rounded">
          <div class="h-2 bg-blue-600 rounded transition-all duration-300" style="width: 0%" data-metadata-validation-target="progressBar"></div>
        </div>
        <p class="text-sm text-gray-600 mt-3" data-metadata-validation-target="progressDetail">Starting validation...</p>
        <p class="text-xs text-gray-400 mt-2">The page will reload when complete.</p>
      </div>
    `
  }

  resetProgressUi() {
    this.currentProgress = 0
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = "0%"
    }
    if (this.hasProgressPercentTarget) {
      this.progressPercentTarget.textContent = "0%"
    }
    if (this.hasProgressDetailTarget) {
      this.progressDetailTarget.textContent = "Starting validation..."
    }
  }

  showError(message) {
    this.completed = true
    this.stopPolling()
    this.unsubscribe()

    if (this.hasResultTarget) {
      if (this.hasLoadingTarget) {
        this.loadingTarget.classList.add("hidden")
      }
      this.resultTarget.classList.remove("hidden")
      this.resultTarget.innerHTML = `
        <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-4">
          <p class="text-red-800 text-sm">${message}</p>
        </div>
        <button type="button"
                data-action="click->metadata-validation#runValidation"
                class="inline-flex items-center px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-md hover:bg-blue-700 transition-colors">
          Try Again
        </button>
      `
    } else if (this.hasLoadingTarget) {
      const modal = this.loadingTarget.querySelector(".relative")
      if (modal) {
        modal.innerHTML = `
          <div class="text-center">
            <p class="text-red-700 font-medium mb-1">Validation failed</p>
            <p class="text-red-600 text-sm mb-4">${message}</p>
            <button type="button"
                    data-action="click->metadata-validation#dismissModal"
                    class="px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700">
              Close
            </button>
          </div>
        `
      }
    }
    if (this.hasValidateButtonTarget) {
      this.validateButtonTarget.disabled = false
      this.validateButtonTarget.classList.remove("opacity-50", "cursor-not-allowed")
    }
  }

  dismissModal() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.add("hidden")
    }
  }

  getCSRFToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute("content") : ""
  }
}
