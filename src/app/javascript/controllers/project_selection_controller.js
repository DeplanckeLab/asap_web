import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = 'selectedProjectIds'
const SC_STORAGE_KEY = 'selectedSingleCellProjectIds'

export default class extends Controller {
  static targets = ["checkbox", "selectAll", "deleteButton", "deleteButtonText", "selectedCount", "clearButton", "integrateButton", "integrateButtonText"]

  connect() {
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
    sessionStorage.removeItem(SC_STORAGE_KEY)
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
    const scSelected = this.getStoredSingleCellIds().length
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
      btn.disabled = scSelected < 2
    })

    if (this.hasIntegrateButtonTextTarget) {
      this.integrateButtonTextTarget.textContent = scSelected >= 2
        ? `Integrate selected (${scSelected})`
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

  syncToStorage() {
    const stored = new Set(this.getStoredIds())
    const scStored = new Set(this.getStoredSingleCellIds())

    this.checkboxTargets.forEach(checkbox => {
      const isSingleCell = checkbox.dataset.singleCell === 'true'
      if (checkbox.checked) {
        stored.add(checkbox.value)
        if (isSingleCell) scStored.add(checkbox.value)
      } else {
        stored.delete(checkbox.value)
        scStored.delete(checkbox.value)
      }
    })

    sessionStorage.setItem(STORAGE_KEY, JSON.stringify([...stored]))
    sessionStorage.setItem(SC_STORAGE_KEY, JSON.stringify([...scStored]))
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

  getStoredSingleCellIds() {
    try {
      const raw = sessionStorage.getItem(SC_STORAGE_KEY)
      if (!raw) return []
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }

  getSelectedProjectIds() {
    return this.getStoredIds()
  }

  getSelectedProjectIdsOnPage() {
    return this.checkboxTargets
      .filter((checkbox) => checkbox.checked)
      .map((checkbox) => checkbox.value)
  }

  getSingleCellSelectedProjectIds() {
    return this.getStoredSingleCellIds()
  }

  clearStorage() {
    sessionStorage.removeItem(STORAGE_KEY)
    sessionStorage.removeItem(SC_STORAGE_KEY)
  }
}
