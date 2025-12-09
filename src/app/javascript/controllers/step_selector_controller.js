import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["resultsContainer", "emptyState", "loadingState", "content"]
  static values = { projectId: Number }

  connect() {
    console.log('[StepSelectorController] Connected')
    // Select the first available step by default if available
    this.selectFirstAvailableStep()
  }

  selectFirstAvailableStep() {
    // Find the first available step (not disabled)
    const firstStep = this.element.querySelector('[data-step-id]:not(.disabled)')
    if (firstStep) {
      const stepId = firstStep.getAttribute('data-step-id')
      this.loadStepResults(stepId, firstStep)
    }
  }

  selectStep(event) {
    const stepElement = event.currentTarget
    const stepId = stepElement.getAttribute('data-step-id')
    
    // Don't proceed if step is disabled
    if (stepElement.classList.contains('disabled')) {
      return
    }

    this.loadStepResults(stepId, stepElement)
  }

  loadStepResults(stepId, stepElement) {
    console.log('[StepSelectorController] Loading results for step:', stepId)
    
    // Update UI states
    this.emptyStateTarget.style.display = 'none'
    this.loadingStateTarget.style.display = 'block'
    this.contentTarget.style.display = 'none'

    // Update active step highlighting
    this.updateActiveStep(stepElement)

    // Load step results via AJAX
    const url = `/projects/${this.projectIdValue}/step_results?step_id=${stepId}`
    
    fetch(url, {
      method: 'GET',
      headers: {
        'Accept': 'text/html',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.text()
    })
    .then(html => {
      this.contentTarget.innerHTML = html
      this.loadingStateTarget.style.display = 'none'
      this.contentTarget.style.display = 'block'
    })
    .catch(error => {
      console.error('[StepSelectorController] Error loading step results:', error)
      this.loadingStateTarget.style.display = 'none'
      this.contentTarget.innerHTML = `
        <div class="alert alert-danger">
          <i class="fas fa-exclamation-triangle me-2"></i>
          Error loading step results. Please try again.
        </div>
      `
      this.contentTarget.style.display = 'block'
    })
  }

  updateActiveStep(activeElement) {
    // Remove active class from all steps
    const allSteps = this.element.querySelectorAll('[data-step-id]')
    allSteps.forEach(step => {
      step.classList.remove('active')
      step.style.backgroundColor = ''
      step.style.borderLeft = ''
      const textElements = step.querySelectorAll('strong, small, span')
      textElements.forEach(el => {
        if (!el.classList.contains('badge')) {
          el.classList.remove('text-white')
        }
      })
    })

    // Add active class to selected step
    if (activeElement) {
      activeElement.classList.add('active')
      activeElement.style.backgroundColor = '#007bff'
      activeElement.style.borderLeft = '4px solid #0056b3'
      const textElements = activeElement.querySelectorAll('strong, small, span:not(.badge)')
      textElements.forEach(el => {
        el.classList.add('text-white')
      })
    }
  }
}

