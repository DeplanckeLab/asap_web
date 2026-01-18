import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { 
    stepId: Number,
    runNum: String
  }

  connect() {
    // Values are optional and will be checked in deleteRun() method
  }

  refreshStepResults() {
    // Find the step selector controller and refresh the step results
    const stepSelectorElement = document.querySelector('[data-controller*="step-selector"]')
    if (stepSelectorElement && window.Stimulus) {
      const stepSelectorController = window.Stimulus.getControllerForElementAndIdentifier(stepSelectorElement, 'step-selector')
      if (stepSelectorController && typeof stepSelectorController.loadStepResults === 'function') {
        const stepIdString = this.hasStepIdValue ? this.stepIdValue.toString() : null
        if (stepIdString) {
          const stepElement = stepSelectorElement.querySelector('[data-step-id="' + stepIdString + '"]')
          if (stepElement) {
            console.log('[DeleteRunController] Run deleted successfully, refreshing step results')
            stepSelectorController.loadStepResults(stepIdString, stepElement, false)
            return true
          }
        }
      }
    }
    return false
  }

  deleteRun(event) {
    event.preventDefault()
    event.stopPropagation()

    // The controller is attached to the form element
    const form = this.element
    if (form.tagName !== 'FORM') {
      console.error('[DeleteRunController] Controller must be attached to a form element')
      alert('Error: Invalid form element.')
      return
    }

    const url = form.action || form.getAttribute('action')
    if (!url) {
      console.error('[DeleteRunController] No URL found for delete form')
      alert('Error: Could not find delete URL.')
      return
    }

    // Get run number for confirmation message
    let runNum = this.hasRunNumValue ? this.runNumValue : 'N/A'
    if (runNum === 'N/A') {
      // Find the table row that contains this form
      const tr = this.element.closest('tr')
      if (tr) {
        const numElement = tr.querySelector('td:first-child .text-sm')
        if (numElement) {
          runNum = numElement.textContent.replace('#', '') || 'N/A'
        }
      } else {
        // Fallback: try to find the row from the button inside the form
        const button = this.element.querySelector('button')
        if (button) {
          const tr2 = button.closest('tr')
          if (tr2) {
            const numElement = tr2.querySelector('td:first-child .text-sm')
            if (numElement) {
              runNum = numElement.textContent.replace('#', '') || 'N/A'
            }
          }
        }
      }
    }

    // Show confirmation
    const confirmMessage = 'Are you sure you want to delete Run #' + runNum + '? This action cannot be undone and will delete associated files and metadata.'
    if (!confirm(confirmMessage)) {
      return
    }

    // Make AJAX request
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''

    fetch(url, {
      method: 'DELETE',
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken,
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
    .then(response => {
      if (!response.ok) {
        throw new Error('HTTP error! status: ' + response.status)
      }
      return response.json()
    })
    .then(data => {
      if (data && data.status === 'success') {
        if (!this.refreshStepResults()) {
          console.log('[DeleteRunController] Refreshing page')
          window.location.reload()
        }
      } else {
        console.error('[DeleteRunController] Unexpected response:', data)
        alert('Error deleting run. Unexpected response.')
      }
    })
    .catch(error => {
      console.error('[DeleteRunController] Error deleting run:', error)
      alert('Error deleting run. Please try again.')
    })
  }
}

