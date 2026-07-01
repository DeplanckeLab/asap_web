import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = ["statusText", "progressBar", "unarchiveStep", "integrateStep", "parseStep", "errorText"]
  static values = {
    projectId: Number,
    method: String,
    sourceKeys: Array,
    initialError: String
  }

  connect() {
    if (this.hasInitialErrorValue && this.initialErrorValue) {
      this.applyState("failed", null, this.initialErrorValue)
    } else {
      this.applyState("queued")
    }
    this.subscribe()
  }

  disconnect() {
    this.unsubscribe()
  }

  subscribe() {
    if (!this.projectIdValue) return

    this.subscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectIdValue },
      {
        received: (data) => this.received(data)
      }
    )
  }

  unsubscribe() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  received(data) {
    if (!data) return
    if (data.project_id !== undefined && Number(data.project_id) !== this.projectIdValue) return

    if (data.initial_snapshot && data.parsing_status) {
      if (data.parsing_status === "running") {
        this.applyState("integrating")
      } else if (data.parsing_status === "pending") {
        this.applyState("queued")
      }
    }

    if (data.integration_status) {
      this.applyState(data.integration_status, data.integration_source_key, data.integration_error)
    }

    if (data.parsing_complete === true || data.parsing_status === "success") {
      setTimeout(() => window.location.reload(), 600)
    }

    if (data.parsing_status === "failed" || data.integration_status === "failed") {
      this.applyState("failed", null, data.integration_error)
      this.reloadParsingPanel()
    }
  }

  applyState(state, sourceKey, errorMessage) {
    this.hideError()
    this.resetSteps()

    if (state === "unarchiving") {
      const key = sourceKey || "source project"
      this.statusTextTarget.textContent = `Restoring source project ${key}...`
      this.progressBarTarget.style.width = "25%"
      this.unarchiveStepTarget.style.fontWeight = "600"
      return
    }

    if (state === "queued" || state === "pending") {
      this.statusTextTarget.textContent = "Waiting for integration to start..."
      this.progressBarTarget.style.width = "15%"
      return
    }

    if (state === "integrating") {
      this.statusTextTarget.textContent = `Integrating datasets (${this.methodValue})...`
      this.progressBarTarget.style.width = "55%"
      this.unarchiveStepTarget.style.fontWeight = "600"
      this.integrateStepTarget.style.fontWeight = "600"
      return
    }

    if (state === "parsing") {
      this.statusTextTarget.textContent = "Parsing integrated project..."
      this.progressBarTarget.style.width = "85%"
      this.unarchiveStepTarget.style.fontWeight = "600"
      this.integrateStepTarget.style.fontWeight = "600"
      this.parseStepTarget.style.fontWeight = "600"
      return
    }

    if (state === "completed") {
      this.statusTextTarget.textContent = "Integration complete. Loading project..."
      this.progressBarTarget.style.width = "100%"
      this.unarchiveStepTarget.style.fontWeight = "600"
      this.integrateStepTarget.style.fontWeight = "600"
      this.parseStepTarget.style.fontWeight = "600"
      return
    }

    if (state === "failed") {
      this.statusTextTarget.textContent = "Integration failed."
      this.progressBarTarget.style.width = "100%"
      if (errorMessage) {
        this.showError(errorMessage)
      }
      return
    }

    this.statusTextTarget.textContent = "Preparing integration..."
    this.progressBarTarget.style.width = "15%"
  }

  reloadParsingPanel() {
    const el = document.querySelector('[data-controller*="step-selector"]')
    if (!el || !window.Stimulus) return

    const controller = window.Stimulus.getControllerForElementAndIdentifier(el, "step-selector")
    if (!controller || !controller.currentStepId) return
    if (typeof controller.loadParsingStepResults === "function") {
      controller.loadParsingStepResults(controller.currentStepId, "integration_status:failed")
    }
  }

  resetSteps() {
    this.unarchiveStepTarget.style.fontWeight = "400"
    this.integrateStepTarget.style.fontWeight = "400"
    this.parseStepTarget.style.fontWeight = "400"
  }

  showError(message) {
    this.errorTextTarget.textContent = message
    this.errorTextTarget.classList.remove("hidden")
    this.errorTextTarget.style.display = "block"
  }

  hideError() {
    this.errorTextTarget.textContent = ""
    this.errorTextTarget.classList.add("hidden")
    this.errorTextTarget.style.display = "none"
  }
}
