import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  deleteSelected(event) {
    event.preventDefault()

    // Get selected project IDs from the project-selection controller
    const selectionElement = document.querySelector('[data-controller*="project-selection"]')
    if (!selectionElement || !window.Stimulus) {
      return
    }

    const selectionController = window.Stimulus.getControllerForElementAndIdentifier(selectionElement, 'project-selection')
    if (!selectionController || typeof selectionController.getSelectedProjectIds !== 'function') {
      return
    }

    const selectedIds = typeof selectionController.getSelectedProjectIdsOnPage === 'function'
      ? selectionController.getSelectedProjectIdsOnPage()
      : []
    if (selectedIds.length === 0) {
      return
    }

    const confirmMessage = `Are you sure you want to delete ${selectedIds.length} selected project(s) on this page? Projects you don't have permission to delete will be skipped. This action cannot be undone.`
    if (!confirm(confirmMessage)) {
      return
    }

    // Get CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')

    fetch(this.urlValue, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken,
        'X-Requested-With': 'XMLHttpRequest'
      },
      body: JSON.stringify({ project_ids: selectedIds })
    })
      .then(response => response.json())
      .then(data => {
        if (data.success) {
          // Clear stored selection
          if (typeof selectionController.clearStorage === 'function') {
            selectionController.clearStorage()
          }
          // Reload the page to reflect changes
          window.location.reload()
        } else {
          alert(data.error || 'An error occurred while deleting projects.')
        }
      })
      .catch(error => {
        console.error('Error deleting projects:', error)
        alert('An error occurred while deleting projects.')
      })
  }
}
