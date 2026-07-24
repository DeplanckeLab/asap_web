import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  integrateSelected(event) {
    event.preventDefault()

    const selectionController = this.getSelectionController()
    if (!selectionController) return

    const unknownProjects = selectionController.getUnknownTypeSelectedProjects()
    if (unknownProjects.length > 0) {
      this.showUnknownTypeModal(unknownProjects)
      return
    }

    const selectedIds = selectionController.getSingleCellSelectedProjectIds()
    if (selectedIds.length < 2) {
      alert('Integration requires at least 2 single-cell transcriptomics projects.')
      return
    }

    this.sendPrepareRequest(selectedIds)
  }

  sendPrepareRequest(selectedIds, organismId) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
    const body = { project_ids: selectedIds }
    if (organismId) body.organism_id = organismId

    fetch(this.urlValue, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken,
        'X-Requested-With': 'XMLHttpRequest'
      },
      body: JSON.stringify(body)
    })
      .then(response => response.json())
      .then(data => {
        if (data.success) {
          const selectionController = this.getSelectionController()
          if (selectionController) selectionController.clearStorage()
          window.location.href = data.redirect_url
        } else if (data.unknown_project_type) {
          this.showUnknownTypeModal(
            data.projects.map(project => ({
              id: project.id,
              name: project.name,
              settingsUrl: project.settings_url
            }))
          )
        } else if (data.species_selection_required) {
          this.showSpeciesModal(data.species_groups, selectedIds)
        } else {
          alert(data.error || 'An error occurred while preparing integration.')
        }
      })
      .catch(error => {
        console.error('Error preparing integration:', error)
        alert('An error occurred while preparing integration.')
      })
  }

  showUnknownTypeModal(projects) {
    this.closeModal()

    const modal = document.createElement('div')
    modal.id = 'unknown-project-type-modal'
    modal.className = 'fixed inset-0 z-[9999] flex items-center justify-center'

    const backdrop = document.createElement('div')
    backdrop.className = 'fixed inset-0 bg-black/50'
    backdrop.addEventListener('click', () => this.closeModal())
    modal.appendChild(backdrop)

    const panel = document.createElement('div')
    panel.className = 'relative bg-white rounded-lg shadow-xl max-w-lg w-full mx-4 max-h-[80vh] overflow-y-auto'

    const header = document.createElement('div')
    header.className = 'px-6 py-4 border-b border-gray-200'
    header.innerHTML = `
      <h3 class="text-lg font-semibold text-gray-900">Unknown project type</h3>
      <p class="mt-1 text-sm text-gray-500">
        Projects with an unknown project type cannot be integrated.
        Set the project type on the settings page of each project listed below, then try again.
      </p>
    `
    panel.appendChild(header)

    const body = document.createElement('div')
    body.className = 'px-6 py-4 space-y-2'

    const list = document.createElement('ul')
    list.className = 'space-y-2'

    projects.forEach(project => {
      const item = document.createElement('li')
      item.className = 'flex items-center justify-between gap-3 p-3 rounded-lg border border-amber-200 bg-amber-50'

      const name = document.createElement('span')
      name.className = 'text-sm font-medium text-gray-900'
      name.textContent = project.name

      item.appendChild(name)

      const settingsUrl = project.settingsUrl
      if (settingsUrl) {
        const link = document.createElement('a')
        link.href = settingsUrl
        link.target = '_blank'
        link.rel = 'noopener noreferrer'
        link.className = 'text-sm font-medium text-blue-600 hover:text-blue-800 whitespace-nowrap'
        link.textContent = 'Open settings'
        item.appendChild(link)
      }

      list.appendChild(item)
    })

    body.appendChild(list)
    panel.appendChild(body)

    const footer = document.createElement('div')
    footer.className = 'px-6 py-4 border-t border-gray-200 flex justify-end'
    const closeBtn = document.createElement('button')
    closeBtn.type = 'button'
    closeBtn.className = 'px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md transition-colors'
    closeBtn.textContent = 'Close'
    closeBtn.addEventListener('click', () => this.closeModal())
    footer.appendChild(closeBtn)
    panel.appendChild(footer)

    modal.appendChild(panel)
    document.body.appendChild(modal)
  }

  showSpeciesModal(speciesGroups, selectedIds) {
    // Remove any existing modal
    this.closeModal()

    this._pendingSelectedIds = selectedIds

    const modal = document.createElement('div')
    modal.id = 'species-select-modal'
    modal.className = 'fixed inset-0 z-[9999] flex items-center justify-center'

    // Build modal HTML
    const backdrop = document.createElement('div')
    backdrop.className = 'fixed inset-0 bg-black/50'
    backdrop.addEventListener('click', () => this.closeModal())
    modal.appendChild(backdrop)

    const panel = document.createElement('div')
    panel.className = 'relative bg-white rounded-lg shadow-xl max-w-lg w-full mx-4 max-h-[80vh] overflow-y-auto'

    // Header
    const header = document.createElement('div')
    header.className = 'px-6 py-4 border-b border-gray-200'
    header.innerHTML = `
      <h3 class="text-lg font-semibold text-gray-900">Select species to integrate</h3>
      <p class="mt-1 text-sm text-gray-500">The selected projects belong to different species. Choose which group to integrate.</p>
    `
    panel.appendChild(header)

    // Body with species buttons
    const body = document.createElement('div')
    body.className = 'px-6 py-4 space-y-3'

    speciesGroups.forEach(group => {
      const btn = document.createElement('button')
      btn.type = 'button'
      btn.className = 'w-full text-left p-4 rounded-lg border border-gray-200 hover:border-blue-500 hover:bg-blue-50 transition-colors'
      btn.innerHTML = `
        <div class="flex items-center justify-between">
          <div>
            <span class="font-medium text-gray-900">${this.escapeHtml(group.organism_name)}</span>
            <span class="ml-2 text-sm text-gray-500">${group.project_count} projects</span>
          </div>
        </div>
        <div class="mt-2 text-xs text-gray-500">
          ${group.projects.map(p => this.escapeHtml(p.name)).join(', ')}
        </div>
      `
      btn.addEventListener('click', () => {
        this.closeModal()
        this.sendPrepareRequest(this._pendingSelectedIds, group.organism_id)
      })
      body.appendChild(btn)
    })

    panel.appendChild(body)

    // Footer
    const footer = document.createElement('div')
    footer.className = 'px-6 py-4 border-t border-gray-200 flex justify-end'
    const cancelBtn = document.createElement('button')
    cancelBtn.type = 'button'
    cancelBtn.className = 'px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md transition-colors'
    cancelBtn.textContent = 'Cancel'
    cancelBtn.addEventListener('click', () => this.closeModal())
    footer.appendChild(cancelBtn)
    panel.appendChild(footer)

    modal.appendChild(panel)
    document.body.appendChild(modal)
  }

  closeModal() {
    ;['species-select-modal', 'unknown-project-type-modal'].forEach(id => {
      const modal = document.getElementById(id)
      if (modal) modal.remove()
    })
  }

  getSelectionController() {
    const selectionElement = document.querySelector('[data-controller*="project-selection"]')
    if (!selectionElement || !window.Stimulus) return null
    return window.Stimulus.getControllerForElementAndIdentifier(selectionElement, 'project-selection')
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}
