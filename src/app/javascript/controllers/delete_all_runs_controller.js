import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { 
    stepId: Number,
    projectId: Number
  }

  connect() {
    // Values are optional and will be checked in deleteAllRuns() method
  }

  refreshStepResults(showForm = false) {
    // Find the step selector controller and refresh the step results
    const stepSelectorElement = document.querySelector('[data-controller*="step-selector"]')
    if (stepSelectorElement && window.Stimulus) {
      const stepSelectorController = window.Stimulus.getControllerForElementAndIdentifier(stepSelectorElement, 'step-selector')
      if (stepSelectorController && typeof stepSelectorController.loadStepResults === 'function') {
        const stepIdString = this.hasStepIdValue ? this.stepIdValue.toString() : null
        if (stepIdString) {
          const stepElement = stepSelectorElement.querySelector('[data-step-id="' + stepIdString + '"]')
          if (stepElement) {
            console.log('[DeleteAllRunsController] Runs deleted successfully, refreshing step results, showForm:', showForm)
            
            // If showForm is true, load the form directly
            if (showForm) {
              const cacheBuster = new Date().getTime()
              const url = `/projects/${this.projectIdValue}/step_results.html?step_id=${stepIdString}&show_form=1&_t=${cacheBuster}`
              
              // Update UI states
              if (stepSelectorController.hasLoadingStateTarget) {
                stepSelectorController.loadingStateTarget.style.display = 'block'
              }
              if (stepSelectorController.hasEmptyStateTarget) {
                stepSelectorController.emptyStateTarget.style.display = 'none'
              }
              if (stepSelectorController.hasContentTarget) {
                stepSelectorController.contentTarget.style.display = 'none'
              }
              
              // Load the form
              fetch(url, {
                method: 'GET',
                headers: {
                  'Accept': 'text/html',
                  'X-Requested-With': 'XMLHttpRequest',
                  'Cache-Control': 'no-cache'
                },
                credentials: 'same-origin',
                cache: 'no-store'
              })
              .then(response => {
                if (!response.ok) {
                  throw new Error(`HTTP error! status: ${response.status}`)
                }
                return response.text()
              })
              .then(html => {
                if (stepSelectorController.hasContentTarget) {
                  stepSelectorController.contentTarget.innerHTML = html
                  stepSelectorController.contentTarget.style.display = 'block'
                  if (stepSelectorController.hasLoadingStateTarget) {
                    stepSelectorController.loadingStateTarget.style.display = 'none'
                  }
                  
                  // Trigger Stimulus scan
                  if (window.Stimulus && window.Stimulus.router) {
                    setTimeout(() => {
                      if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
                        window.Stimulus.router.scan()
                      }
                    }, 0)
                    setTimeout(() => {
                      if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
                        window.Stimulus.router.scan()
                      }
                    }, 100)
                  }
                }
              })
              .catch(error => {
                console.error('[DeleteAllRunsController] Error loading form:', error)
                if (stepSelectorController.hasLoadingStateTarget) {
                  stepSelectorController.loadingStateTarget.style.display = 'none'
                }
                alert('Error loading form. Please refresh the page.')
              })
            } else {
              // Normal refresh without form - show updated list of runs
              stepSelectorController.loadStepResults(stepIdString, stepElement, false)
            }
            
            return true
          }
        }
      }
    }
    return false
  }

  deleteAllRuns(event) {
    event.preventDefault()
    event.stopPropagation()

    // The controller is attached to the form element
    const form = this.element
    if (form.tagName !== 'FORM') {
      console.error('[DeleteAllRunsController] Controller must be attached to a form element')
      alert('Error: Invalid form element.')
      return
    }

    const url = form.action || form.getAttribute('action')
    if (!url) {
      console.error('[DeleteAllRunsController] No URL found for delete form')
      alert('Error: Could not find delete URL.')
      return
    }

    // Get selected run IDs from run-selection controller
    let selectedRunIds = []
    const tableElement = document.querySelector('[data-controller*="run-selection"]')
    if (tableElement && window.Stimulus) {
      const runSelectionController = window.Stimulus.getControllerForElementAndIdentifier(tableElement, 'run-selection')
      if (runSelectionController && typeof runSelectionController.getSelectedRunIds === 'function') {
        selectedRunIds = runSelectionController.getSelectedRunIds()
      }
    }

    // Show confirmation (data-confirm is already handled by Rails, but we'll double-check)
    const confirmMessage = form.getAttribute('data-confirm') || 'Are you sure you want to delete all runs from this step? This will delete all subsequent analyses down the pipeline. This action cannot be undone.'
    if (!confirm(confirmMessage)) {
      return
    }

    // Make AJAX request
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''

    // Prepare request body
    const body = {}
    if (selectedRunIds.length > 0) {
      body.run_ids = selectedRunIds
    }

    fetch(url, {
      method: 'POST',
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken,
        'X-Requested-With': 'XMLHttpRequest'
      },
      body: Object.keys(body).length > 0 ? JSON.stringify(body) : undefined,
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
        // Check if we should show the form (no runs left and step has std_form)
        const showForm = data.show_form === true
        // Always refresh the step results to show updated list
        if (!this.refreshStepResults(showForm)) {
          console.log('[DeleteAllRunsController] Refreshing page')
          if (showForm) {
            window.location.href = `/projects/${this.projectIdValue}/step_results?step_id=${this.stepIdValue}&show_form=1`
          } else {
            // Reload the step results to show updated list
            window.location.href = `/projects/${this.projectIdValue}/step_results?step_id=${this.stepIdValue}`
          }
        }
      } else {
        console.error('[DeleteAllRunsController] Unexpected response:', data)
        alert('Error deleting runs. Unexpected response.')
      }
    })
    .catch(error => {
      console.error('[DeleteAllRunsController] Error deleting runs:', error)
      alert('Error deleting runs. Please try again.')
    })
  }
}

