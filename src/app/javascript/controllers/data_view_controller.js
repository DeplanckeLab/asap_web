import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "loading"]
  static values = {
    projectId: Number
  }

  connect() {
    console.log('[DataViewController] Connected')
  }

  // Helper method to get project identifier from URL (supports ID or key)
  getProjectIdentifier() {
    if (this.projectIdValue) {
      return this.projectIdValue
    }
    const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
    return pathMatch ? pathMatch[1] : null
  }

  loadContent(loomFile, dataType, event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    console.log('[DataViewController] Loading content:', { loomFile, dataType })

    // Show loading state
    if (this.hasLoadingTarget) {
      this.loadingTarget.style.display = 'block'
    }
    if (this.hasContentTarget) {
      this.contentTarget.style.display = 'none'
    }

    // Build URL
    const projectIdentifier = this.getProjectIdentifier()
    const url = `/projects/${projectIdentifier}/data_content?loom_file=${encodeURIComponent(loomFile)}&data_type=${encodeURIComponent(dataType)}`

    // Load content via AJAX
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
      if (this.hasContentTarget) {
        this.contentTarget.innerHTML = html
        this.contentTarget.style.display = 'block'
      }
      if (this.hasLoadingTarget) {
        this.loadingTarget.style.display = 'none'
      }

      // Update left panel selection
      this.updateLeftPanelSelection(loomFile)

      // Update URL without reload
      const newUrl = new URL(window.location)
      newUrl.searchParams.set('loom_file', loomFile)
      newUrl.searchParams.set('data_type', dataType)
      window.history.pushState({}, '', newUrl)
    })
    .catch(error => {
      console.error('[DataViewController] Error loading content:', error)
      if (this.hasContentTarget) {
        this.contentTarget.innerHTML = `<div class="p-6 text-center text-red-600">Error loading content: ${error.message}</div>`
        this.contentTarget.style.display = 'block'
      }
      if (this.hasLoadingTarget) {
        this.loadingTarget.style.display = 'none'
      }
    })
  }

  selectLoomFile(event) {
    console.log('[DataViewController] selectLoomFile called', event.currentTarget)
    const loomFile = event.currentTarget.dataset.loomFile || event.currentTarget.getAttribute('data-loom-file')
    let dataType = event.currentTarget.dataset.dataType || event.currentTarget.getAttribute('data-data-type')
    
    // If no data type in attributes, try to get it from the active tab button
    if (!dataType) {
      const activeTab = this.element.querySelector('[data-data-view-data-type-param].bg-blue-600')
      if (activeTab) {
        dataType = activeTab.dataset.dataTypeParam || activeTab.getAttribute('data-data-view-data-type-param')
      }
    }
    
    // Default to matrices if still not found
    dataType = dataType || 'matrices'
    
    console.log('[DataViewController] Extracted:', { loomFile, dataType })
    if (!loomFile) {
      console.error('[DataViewController] No loom file found in data attributes')
      return
    }
    this.loadContent(loomFile, dataType, event)
  }

  selectDataType(event) {
    console.log('[DataViewController] selectDataType called', event.currentTarget)
    const dataType = event.currentTarget.dataset.dataTypeParam || event.currentTarget.getAttribute('data-data-view-data-type-param')
    const loomFile = event.currentTarget.dataset.loomFileParam || event.currentTarget.getAttribute('data-data-view-loom-file-param')
    console.log('[DataViewController] Extracted:', { loomFile, dataType })
    if (!loomFile || !dataType) {
      console.error('[DataViewController] Missing loom file or data type', { loomFile, dataType })
      return
    }
    this.loadContent(loomFile, dataType, event)
  }

  updateLeftPanelSelection(selectedLoomFile) {
    // Update selection in left panel (both desktop and mobile)
    const leftPanelItems = this.element.querySelectorAll('[data-loom-file]')
    leftPanelItems.forEach(item => {
      const itemLoomFile = item.dataset.loomFile || item.getAttribute('data-loom-file')
      const isSelected = itemLoomFile === selectedLoomFile
      
      if (isSelected) {
        item.classList.remove('bg-white', 'hover:bg-gray-50')
        item.classList.add('bg-blue-50')
        item.style.borderLeft = '4px solid #007bff'
        const strong = item.querySelector('strong')
        if (strong) {
          strong.classList.remove('text-gray-900')
          strong.classList.add('text-blue-900')
        }
      } else {
        item.classList.remove('bg-blue-50')
        item.classList.add('bg-white', 'hover:bg-gray-50')
        item.style.borderLeft = '4px solid transparent'
        const strong = item.querySelector('strong')
        if (strong) {
          strong.classList.remove('text-blue-900')
          strong.classList.add('text-gray-900')
        }
      }
    })

    // Update mobile dropdown selection
    const mobileDropdownItems = this.element.querySelectorAll('[data-dropdown-target="menu"] [data-loom-file]')
    mobileDropdownItems.forEach(item => {
      const itemLoomFile = item.dataset.loomFile || item.getAttribute('data-loom-file')
      const isSelected = itemLoomFile === selectedLoomFile
      
      if (isSelected) {
        item.classList.remove('bg-white', 'hover:bg-gray-50')
        item.classList.add('bg-blue-50')
        item.style.borderLeft = '4px solid #007bff !important'
        const span = item.querySelector('span')
        if (span) {
          span.classList.remove('text-gray-900')
          span.classList.add('text-blue-900', 'font-semibold')
        }
      } else {
        item.classList.remove('bg-blue-50')
        item.classList.add('bg-white', 'hover:bg-gray-50')
        item.style.borderLeft = '4px solid transparent'
        const span = item.querySelector('span')
        if (span) {
          span.classList.remove('text-blue-900', 'font-semibold')
          span.classList.add('text-gray-900')
        }
      }
    })

    // Update mobile dropdown button text
    const dropdownButton = this.element.querySelector('[data-dropdown-target="button"]')
    if (dropdownButton) {
      const labelSpan = dropdownButton.querySelector('span')
      if (labelSpan) {
        // Get the label from the selected item
        const selectedItem = Array.from(leftPanelItems).find(item => {
          const itemLoomFile = item.dataset.loomFile || item.getAttribute('data-loom-file')
          return itemLoomFile === selectedLoomFile
        })
        if (selectedItem) {
          const itemLabel = selectedItem.querySelector('strong')?.textContent || selectedLoomFile
          labelSpan.textContent = itemLabel
        }
      }
    }
  }
}

