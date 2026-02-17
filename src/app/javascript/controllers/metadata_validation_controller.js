import { Controller } from "@hotwired/stimulus"

// Handles metadata schema validation for projects
export default class extends Controller {
  static targets = ["result", "loading", "validateButton"]
  static values = {
    projectId: Number,
    statusUrl: String,
    validateUrl: String
  }

  connect() {
    this.pollingInterval = null
  }

  disconnect() {
    this.stopPolling()
  }

  async runValidation(event) {
    event.preventDefault()
    
    // Show loading state
    this.showLoading()
    
    try {
      // Trigger validation
      const response = await fetch(this.validateUrlValue, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': this.getCSRFToken()
        }
      })

      if (response.ok) {
        // Start polling for results
        this.startPolling()
      } else {
        const error = await response.json()
        this.showError(error.error || 'Failed to start validation')
      }
    } catch (error) {
      console.error('Validation error:', error)
      this.showError('Failed to start validation. Please try again.')
    }
  }

  startPolling() {
    // Poll every 2 seconds
    this.pollingInterval = setInterval(() => {
      this.checkStatus()
    }, 2000)
    
    // Also check immediately
    this.checkStatus()
  }

  stopPolling() {
    if (this.pollingInterval) {
      clearInterval(this.pollingInterval)
      this.pollingInterval = null
    }
  }

  async checkStatus() {
    try {
      const response = await fetch(this.statusUrlValue, {
        headers: {
          'Accept': 'application/json'
        }
      })

      if (response.ok) {
        const data = await response.json()
        
        if (data.has_result) {
          // Validation complete - reload the page to show results
          this.stopPolling()
          window.location.reload()
        }
      }
    } catch (error) {
      console.error('Status check error:', error)
    }
  }

  showLoading() {
    if (this.hasResultTarget) {
      this.resultTarget.classList.add('hidden')
    }
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.remove('hidden')
    }
    if (this.hasValidateButtonTarget) {
      this.validateButtonTarget.disabled = true
      this.validateButtonTarget.classList.add('opacity-50', 'cursor-not-allowed')
    }
  }

  showError(message) {
    this.stopPolling()

    if (this.hasResultTarget) {
      if (this.hasLoadingTarget) {
        this.loadingTarget.classList.add('hidden')
      }
      this.resultTarget.classList.remove('hidden')
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
      // Modal overlay mode (compliance page): show error inside the modal
      var modal = this.loadingTarget.querySelector('.relative')
      if (modal) {
        modal.innerHTML = `
          <div class="text-center">
            <svg class="mx-auto h-8 w-8 text-red-500 mb-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
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
      this.validateButtonTarget.classList.remove('opacity-50', 'cursor-not-allowed')
    }
  }

  dismissModal() {
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.add('hidden')
    }
  }

  getCSRFToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute('content') : ''
  }
}
