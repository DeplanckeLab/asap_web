import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    console.log('[RunParamsToggle] Controller connected', this.element)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    
    console.log('[RunParamsToggle] Toggle called')
    const button = event.currentTarget
    const runId = button.getAttribute('data-run-id')
    
    console.log('[RunParamsToggle] Run ID:', runId)
    
    if (!runId) {
      console.warn('[RunParamsToggle] No run-id found on button')
      return
    }
    
    // Use this.element which is the container (the element with data-controller)
    const container = this.element
    
    // Get all badges for this run, in order
    const allBadges = Array.from(container.querySelectorAll(`.run-param-badge[data-run-id="${runId}"]`))
    const hiddenBadges = allBadges.filter(badge => badge.classList.contains('hidden'))
    const maxVisible = 3
    
    if (hiddenBadges.length === 0) {
      // All parameters are visible, hide the ones beyond max_visible
      allBadges.forEach((badge, index) => {
        if (index >= maxVisible) {
          badge.classList.add('hidden')
        }
      })
      const hiddenCount = allBadges.length - maxVisible
      button.textContent = hiddenCount > 0 ? `+${hiddenCount} more` : ''
    } else {
      // Show all hidden parameters
      hiddenBadges.forEach(badge => {
        badge.classList.remove('hidden')
      })
      button.textContent = 'Show less'
    }
  }
}

