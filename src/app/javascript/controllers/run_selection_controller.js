import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "selectAll", "deleteButton", "deleteButtonText"]

  connect() {
    console.log('[RunSelectionController] Connected!')
    console.log('[RunSelectionController] Checkboxes found:', this.checkboxTargets.length)
    console.log('[RunSelectionController] Select all found:', this.hasSelectAllTarget)
    console.log('[RunSelectionController] Element:', this.element)
    this.updateSelectAllState()
    this.updateButtonText()
  }

  toggleAll(event) {
    console.log('[RunSelectionController] toggleAll called, checked:', event.target.checked)
    const checked = event.target.checked
    this.checkboxTargets.forEach(checkbox => {
      if (checkbox.disabled) return
      checkbox.checked = checked
    })
    this.updateSelectAllState()
    this.updateButtonText()
  }

  updateSelection(event) {
    console.log('[RunSelectionController] updateSelection called')
    console.log('[RunSelectionController] Event target:', event.target)
    console.log('[RunSelectionController] Checked:', event.target.checked)
    this.updateSelectAllState()
    this.updateButtonText()
  }

  updateSelectAllState() {
    const selectableCheckboxes = this.checkboxTargets.filter((checkbox) => !checkbox.disabled)
    const allChecked = selectableCheckboxes.length > 0 &&
                       selectableCheckboxes.every((checkbox) => checkbox.checked)
    const someChecked = selectableCheckboxes.some((checkbox) => checkbox.checked)
    
    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked = allChecked
      this.selectAllTarget.indeterminate = someChecked && !allChecked
    }
  }

  updateButtonText() {
    const selectedCount = this.getSelectedRunIds().length
    
    // Find all delete button text elements within the controller scope using querySelector
    // This works even if Stimulus targets aren't found
    const buttonTextElements = this.element.querySelectorAll('[data-run-selection-target="deleteButtonText"]')
    buttonTextElements.forEach(target => {
      if (selectedCount > 0) {
        target.textContent = `Delete selected (${selectedCount})`
      } else {
        target.textContent = "Delete all"
      }
    })

    // Update confirmation message for all delete buttons
    const deleteButtonElements = this.element.querySelectorAll('[data-run-selection-target="deleteButton"]')
    deleteButtonElements.forEach(target => {
      const form = target.tagName === 'FORM' ? target : target.closest('form')
      if (form) {
        if (selectedCount > 0) {
          form.setAttribute('data-confirm', 
            `Are you sure you want to delete ${selectedCount} selected run(s)? This will delete all subsequent analyses down the pipeline. This action cannot be undone.`)
        } else {
          form.setAttribute('data-confirm', 
            "Are you sure you want to delete all runs from this step? This will delete all subsequent analyses down the pipeline. This action cannot be undone.")
        }
      }
    })
  }

  getSelectedRunIds() {
    return this.checkboxTargets
      .filter((checkbox) => checkbox.checked && !checkbox.disabled)
      .map(checkbox => checkbox.value)
  }
}

