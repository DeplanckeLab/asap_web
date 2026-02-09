import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = 'selectedProjectIds'

export default class extends Controller {
  static targets = ["checkbox", "selectAll", "deleteButton", "deleteButtonText", "selectedCount", "clearButton", "integrateButton", "integrateButtonText"]

  connect() {
    // Restore checkbox state from sessionStorage
    const stored = this.getStoredIds()
    this.checkboxTargets.forEach(checkbox => {
      if (stored.includes(checkbox.value)) {
        checkbox.checked = true
      }
    })
    this.updateSelectAllState()
    this.updateUI()
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.checkboxTargets.forEach(checkbox => {
      checkbox.checked = checked
    })
    this.syncToStorage()
    this.updateSelectAllState()
    this.updateUI()
  }

  updateSelection() {
    this.syncToStorage()
    this.updateSelectAllState()
    this.updateUI()
  }

  clearSelection() {
    sessionStorage.removeItem(STORAGE_KEY)
    this.checkboxTargets.forEach(checkbox => {
      checkbox.checked = false
    })
    this.updateSelectAllState()
    this.updateUI()
  }

  updateSelectAllState() {
    const allChecked = this.checkboxTargets.length > 0 &&
                       this.checkboxTargets.every(checkbox => checkbox.checked)
    const someChecked = this.checkboxTargets.some(checkbox => checkbox.checked)

    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked = allChecked
      this.selectAllTarget.indeterminate = someChecked && !allChecked
    }
  }

  updateUI() {
    const totalSelected = this.getStoredIds().length
    const pageSelected = this.checkboxTargets.filter(cb => cb.checked).length
    const otherPages = totalSelected - pageSelected

    this.deleteButtonTargets.forEach(btn => {
      btn.disabled = totalSelected === 0
    })

    this.clearButtonTargets.forEach(btn => {
      if (totalSelected > 0) {
        btn.classList.remove('hidden')
      } else {
        btn.classList.add('hidden')
      }
    })

    if (this.hasDeleteButtonTextTarget) {
      this.deleteButtonTextTarget.textContent = totalSelected > 0
        ? `Delete selected (${totalSelected})`
        : 'Delete selected'
    }

    this.integrateButtonTargets.forEach(btn => {
      btn.disabled = totalSelected < 2
    })

    if (this.hasIntegrateButtonTextTarget) {
      this.integrateButtonTextTarget.textContent = totalSelected >= 2
        ? `Integrate selected (${totalSelected})`
        : 'Integrate selected'
    }

    if (this.hasSelectedCountTarget) {
      if (totalSelected > 0) {
        let text = `${totalSelected} selected`
        if (otherPages > 0) {
          text += ` (${otherPages} on other pages)`
        }
        this.selectedCountTarget.textContent = text
      } else {
        this.selectedCountTarget.textContent = ''
      }
    }
  }

  // Sync current page checkboxes into sessionStorage
  syncToStorage() {
    const stored = new Set(this.getStoredIds())
    // Update stored set based on current page checkboxes
    this.checkboxTargets.forEach(checkbox => {
      if (checkbox.checked) {
        stored.add(checkbox.value)
      } else {
        stored.delete(checkbox.value)
      }
    })
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify([...stored]))
  }

  getStoredIds() {
    try {
      const raw = sessionStorage.getItem(STORAGE_KEY)
      if (!raw) return []
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }

  // Public method used by delete-projects controller
  getSelectedProjectIds() {
    return this.getStoredIds()
  }

  // Called after successful deletion to clear storage
  clearStorage() {
    sessionStorage.removeItem(STORAGE_KEY)
  }
}
