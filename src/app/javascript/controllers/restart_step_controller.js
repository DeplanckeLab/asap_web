import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { 
    projectId: Number,
    stepId: Number,
    restartUrl: String
  }

  connect() {
    // Silently connect - don't log unless debugging
    // Values are optional and will be checked in restart() method
  }

  showLoadingOverlay() {
    // Remove any existing overlay
    const existingOverlay = document.getElementById('restart-loading-overlay')
    if (existingOverlay) {
      existingOverlay.remove()
    }

    // Create overlay element
    const overlay = document.createElement('div')
    overlay.id = 'restart-loading-overlay'
    overlay.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background-color: rgba(0, 0, 0, 0.5);
      z-index: 9999;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-start;
      padding-top: 100px;
    `

    // Create message container
    const messageContainer = document.createElement('div')
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

    // Create spinner
    const spinner = document.createElement('div')
    spinner.innerHTML = `
      <svg class="animate-spin" style="width: 32px; height: 32px; color: #f97316;" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
      </svg>
    `

    // Create message text
    const message = document.createElement('div')
    message.textContent = 'Resetting...'
    message.style.cssText = `
      font-size: 18px;
      font-weight: 500;
      color: #374151;
    `

    messageContainer.appendChild(spinner)
    messageContainer.appendChild(message)
    overlay.appendChild(messageContainer)

    // Add spinner animation CSS if not already present
    if (!document.getElementById('restart-spinner-styles')) {
      const style = document.createElement('style')
      style.id = 'restart-spinner-styles'
      style.textContent = `
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
        .animate-spin {
          animation: spin 1s linear infinite;
        }
      `
      document.head.appendChild(style)
    }

    // Disable page interactions
    document.body.style.pointerEvents = 'none'
    document.body.style.userSelect = 'none'

    // Add overlay to body
    document.body.appendChild(overlay)
  }

  hideLoadingOverlay() {
    const overlay = document.getElementById('restart-loading-overlay')
    if (overlay) {
      overlay.remove()
    }
    document.body.style.pointerEvents = ''
    document.body.style.userSelect = ''
  }

  restart(event) {
    event.preventDefault()
    event.stopPropagation()

    // Validate required values
    if (!this.hasRestartUrlValue || !this.hasStepIdValue) {
      console.error('[RestartStepController] Missing required values')
      return
    }

    if (confirm('Restarting this step will remove all subsequent analyses. Are you sure you want to proceed?')) {
      // Show loading overlay
      this.showLoadingOverlay()

      // Disable the restart button
      this.element.disabled = true
      this.element.style.opacity = '0.6'
      this.element.style.cursor = 'not-allowed'

      const form = document.createElement('form')
      form.method = 'POST'
      form.action = this.restartUrlValue

      const csrfToken = document.querySelector('meta[name="csrf-token"]')
      if (csrfToken) {
        const csrfInput = document.createElement('input')
        csrfInput.type = 'hidden'
        csrfInput.name = 'authenticity_token'
        csrfInput.value = csrfToken.getAttribute('content')
        form.appendChild(csrfInput)
      }

      const stepIdInput = document.createElement('input')
      stepIdInput.type = 'hidden'
      stepIdInput.name = 'step_id'
      stepIdInput.value = this.stepIdValue
      form.appendChild(stepIdInput)

      document.body.appendChild(form)
      form.submit()
    }
  }
}

