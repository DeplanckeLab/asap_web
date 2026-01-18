import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "icon"]

  connect() {
    document.addEventListener("click", this.closeOnClickOutside.bind(this))
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnClickOutside.bind(this))
  }

  toggle(event) {
    event.stopPropagation()
    const isHidden = this.menuTarget.classList.contains("hidden")
    this.menuTarget.classList.toggle("hidden")
    this.menuTarget.style.display = isHidden ? "block" : "none"
    
    if (this.hasIconTarget) {
      if (isHidden) {
        this.iconTarget.classList.add("rotate-180")
      } else {
        this.iconTarget.classList.remove("rotate-180")
      }
    }
    
    // When opening the dropdown, ensure the correct step is highlighted
    if (isHidden && typeof window.Stimulus !== 'undefined') {
      const stepSelectorElement = document.querySelector('[data-controller~="step-selector"]')
      if (stepSelectorElement) {
        try {
          const stepSelectorController = window.Stimulus.getControllerForElementAndIdentifier(stepSelectorElement, 'step-selector')
          if (stepSelectorController && typeof stepSelectorController.updateDropdownListSelection === 'function') {
            // Get the selected step ID from data attribute (set by ERB), controller, or dropdown element
            const selectedStepId = this.element.getAttribute('data-selected-step-id') ||
                                  stepSelectorController.currentStepId || 
                                  stepSelectorElement.getAttribute('data-current-step-id')
            if (selectedStepId) {
              stepSelectorController.updateDropdownListSelection(selectedStepId)
            }
          }
        } catch(e) {
          console.warn('[DropdownController] Could not update dropdown list selection:', e)
        }
      }
    }
  }

  close(event) {
    if (event) event.stopPropagation()
    this.menuTarget.classList.add("hidden")
    this.menuTarget.style.display = "none"
    if (this.hasIconTarget) {
      this.iconTarget.classList.remove("rotate-180")
    }
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }
} 