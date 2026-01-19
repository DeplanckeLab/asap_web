import { Controller } from "@hotwired/stimulus"

// Test if this file is being loaded
console.log('🔵 [OrganismSelector] JavaScript file loaded!')

export default class extends Controller {
  static targets = ["dropdownButton", "dropdownMenu", "groupHeader", "groupContent", "groupChevron", "option", "hiddenInput", "selectedText", "chevron"]

  connect() {
    console.log('=== [OrganismSelector] Controller connecting... ===')
    console.log('[OrganismSelector] Element:', this.element)
    console.log('[OrganismSelector] Has dropdownMenu target:', this.hasDropdownMenuTarget)
    console.log('[OrganismSelector] Has dropdownButton target:', this.hasDropdownButtonTarget)
    console.log('[OrganismSelector] Has chevron target:', this.hasChevronTarget)
    
    if (this.hasDropdownMenuTarget) {
      console.log('[OrganismSelector] Dropdown menu element:', this.dropdownMenuTarget)
      console.log('[OrganismSelector] Dropdown menu classes:', this.dropdownMenuTarget.className)
    }
    
    if (this.hasDropdownButtonTarget) {
      console.log('[OrganismSelector] Dropdown button element:', this.dropdownButtonTarget)
      console.log('[OrganismSelector] Dropdown button has click handler:', this.dropdownButtonTarget.hasAttribute('data-action'))
    }
    
    this.isOpen = false
    this.ignoreNextClick = false
    
    // Expand group if it contains the selected organism
    if (this.hasHiddenInputTarget && this.hiddenInputTarget.value) {
      console.log('[OrganismSelector] Selected organism ID:', this.hiddenInputTarget.value)
      const selectedId = this.hiddenInputTarget.value
      this.optionTargets.forEach(option => {
        if (option.dataset.organismId === selectedId) {
          const groupContent = option.closest('[data-organism-selector-target="groupContent"]')
          if (groupContent) {
            groupContent.classList.remove('hidden')
            const header = groupContent.previousElementSibling
            const chevron = header?.querySelector('[data-organism-selector-target="groupChevron"]')
            if (chevron) {
              chevron.style.transform = 'rotate(90deg)'
            }
          }
        }
      })
    }
    
    // Add click outside listener after a delay to avoid immediate closure
    setTimeout(() => {
      console.log('[OrganismSelector] Adding outside click listener')
      this.boundCloseOnOutsideClick = this.closeOnOutsideClick.bind(this)
      document.addEventListener('click', this.boundCloseOnOutsideClick, true)
    }, 200)
    
    console.log('[OrganismSelector] Controller connected successfully')
  }

  disconnect() {
    if (this.boundCloseOnOutsideClick) {
      document.removeEventListener('click', this.boundCloseOnOutsideClick, true)
    }
  }

  toggleDropdown(event) {
    console.log('=== [OrganismSelector] toggleDropdown called ===')
    console.log('[OrganismSelector] Event type:', event.type)
    console.log('[OrganismSelector] Event target:', event.target)
    console.log('[OrganismSelector] Event currentTarget:', event.currentTarget)
    console.log('[OrganismSelector] Current isOpen state:', this.isOpen)
    
    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation()
    
    // Ignore this click for the outside click handler
    this.ignoreNextClick = true
    setTimeout(() => { this.ignoreNextClick = false }, 100)
    
    if (!this.hasDropdownMenuTarget) {
      console.error('[OrganismSelector] dropdownMenu target not found')
      return
    }
    
    console.log('[OrganismSelector] Dropdown menu element:', this.dropdownMenuTarget)
    console.log('[OrganismSelector] Dropdown menu has "hidden" class:', this.dropdownMenuTarget.classList.contains('hidden'))
    
    this.isOpen = !this.isOpen
    console.log('[OrganismSelector] New isOpen state:', this.isOpen)
    
    if (this.isOpen) {
      console.log('[OrganismSelector] Opening dropdown')
      this.dropdownMenuTarget.classList.remove('hidden')
      console.log('[OrganismSelector] Dropdown menu classes after remove:', this.dropdownMenuTarget.className)
      if (this.hasChevronTarget) {
        this.chevronTarget.classList.add('rotate-180')
      }
    } else {
      console.log('[OrganismSelector] Closing dropdown')
      this.dropdownMenuTarget.classList.add('hidden')
      if (this.hasChevronTarget) {
        this.chevronTarget.classList.remove('rotate-180')
      }
    }
  }

  toggleGroup(event) {
    event.stopPropagation()
    const header = event.currentTarget
    const groupContent = header.nextElementSibling
    const chevron = header.querySelector('[data-organism-selector-target="groupChevron"]')
    
    if (groupContent && groupContent.hasAttribute('data-organism-selector-target')) {
      const isExpanding = chevron && (chevron.style.transform === '' || chevron.style.transform === 'rotate(0deg)')
      
      if (isExpanding) {
        // Expanding - rotate chevron to point down
        if (chevron) {
          chevron.style.transform = 'rotate(90deg)'
        }
        groupContent.classList.remove('hidden')
      } else {
        // Collapsing - rotate chevron back to right
        if (chevron) {
          chevron.style.transform = 'rotate(0deg)'
        }
        groupContent.classList.add('hidden')
      }
    }
  }

  selectOrganism(event) {
    event.stopPropagation()
    const clickedOption = event.currentTarget
    const organismId = clickedOption.dataset.organismId
    const organismName = clickedOption.textContent.trim()

    // Update hidden input
    if (this.hasHiddenInputTarget) {
      this.hiddenInputTarget.value = organismId
      // Trigger change event
      this.hiddenInputTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }

    // Update selected text
    if (this.hasSelectedTextTarget) {
      this.selectedTextTarget.textContent = organismName
    }

    // Update option styles
    this.optionTargets.forEach(option => {
      if (option.dataset.organismId === organismId) {
        option.classList.add("bg-blue-50", "dark:bg-blue-900/30", "font-medium")
      } else {
        option.classList.remove("bg-blue-50", "dark:bg-blue-900/30", "font-medium")
      }
    })

    // Close dropdown
    if (this.hasDropdownMenuTarget) {
      this.dropdownMenuTarget.classList.add('hidden')
      if (this.hasChevronTarget) {
        this.chevronTarget.classList.remove('rotate-180')
      }
    }
  }

  closeOnOutsideClick(event) {
    // Ignore if we just toggled the dropdown
    if (this.ignoreNextClick) {
      console.log('[OrganismSelector] Ignoring outside click (just toggled)')
      return
    }
    
    // Don't close if clicking inside the dropdown element or the button
    if (this.element.contains(event.target)) {
      console.log('[OrganismSelector] Click inside element, not closing')
      return
    }
    
    if (this.isOpen && this.hasDropdownMenuTarget) {
      console.log('[OrganismSelector] Closing dropdown from outside click')
      this.isOpen = false
      this.dropdownMenuTarget.classList.add('hidden')
      if (this.hasChevronTarget) {
        this.chevronTarget.classList.remove('rotate-180')
      }
    }
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  reloadOrganisms(event) {
    const versionId = event.target.value
    if (!versionId) {
      return
    }

    console.log('[OrganismSelector] Reloading organisms for version:', versionId)
    
    // Remember the currently selected organism before resetting
    const previouslySelectedOrganismId = this.hasHiddenInputTarget ? this.hiddenInputTarget.value : null
    console.log('[OrganismSelector] Previously selected organism ID:', previouslySelectedOrganismId)
    
    // Show loading state
    if (this.hasSelectedTextTarget) {
      this.selectedTextTarget.textContent = 'Loading organisms...'
    }
    
    // Fetch organisms for this version
    fetch(`/projects/organisms_for_version?version_id=${encodeURIComponent(versionId)}`, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest'
      }
    })
      .then(response => response.json())
      .then(data => {
        console.log('[OrganismSelector] Received organisms data:', data)
        this.updateOrganismDropdown(data.organisms)
        
        // Try to reapply the previously selected organism if it exists in the new list
        if (previouslySelectedOrganismId) {
          const organismExists = this.trySelectOrganismById(previouslySelectedOrganismId)
          if (organismExists) {
            console.log('[OrganismSelector] Successfully reapplied previously selected organism:', previouslySelectedOrganismId)
            return
          } else {
            console.log('[OrganismSelector] Previously selected organism not found in new list, resetting selection')
          }
        }
        
        // Reset selection if organism wasn't found or wasn't previously selected
        if (this.hasHiddenInputTarget) {
          this.hiddenInputTarget.value = ''
        }
        if (this.hasSelectedTextTarget) {
          this.selectedTextTarget.textContent = 'Please select an organism'
        }
      })
      .catch(error => {
        console.error('[OrganismSelector] Error loading organisms:', error)
        if (this.hasSelectedTextTarget) {
          this.selectedTextTarget.textContent = 'Error loading organisms'
        }
      })
  }

  trySelectOrganismById(organismId) {
    // Find the option with the matching organism ID
    // Query DOM directly to ensure we get the updated elements after dropdown rebuild
    const option = this.dropdownMenuTarget?.querySelector(`[data-organism-id="${organismId}"]`)
    
    if (!option) {
      return false
    }
    
    // Get the organism name from the option
    const organismName = option.textContent.trim()
    
    // Update hidden input
    if (this.hasHiddenInputTarget) {
      this.hiddenInputTarget.value = organismId
      // Trigger change event
      this.hiddenInputTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
    
    // Update selected text
    if (this.hasSelectedTextTarget) {
      this.selectedTextTarget.textContent = organismName
    }
    
    // Update option styles
    // Query all options directly from the DOM
    const allOptions = this.dropdownMenuTarget?.querySelectorAll('[data-organism-id]') || []
    allOptions.forEach(opt => {
      if (opt.dataset.organismId === organismId) {
        opt.classList.add("bg-blue-50", "dark:bg-blue-900/30", "font-medium")
      } else {
        opt.classList.remove("bg-blue-50", "dark:bg-blue-900/30", "font-medium")
      }
    })
    
    // Expand the group containing this organism
    const groupContent = option.closest('[data-organism-selector-target="groupContent"]')
    if (groupContent) {
      groupContent.classList.remove('hidden')
      const header = groupContent.previousElementSibling
      const chevron = header?.querySelector('[data-organism-selector-target="groupChevron"]')
      if (chevron) {
        chevron.style.transform = 'rotate(90deg)'
      }
    }
    
    return true
  }

  updateOrganismDropdown(groups) {
    if (!this.hasDropdownMenuTarget) {
      return
    }

    // Clear existing content
    this.dropdownMenuTarget.innerHTML = ''

    // Build new content
    groups.forEach(group => {
      const groupDiv = document.createElement('div')
      groupDiv.className = 'organism-group'

      // Group header
      const header = document.createElement('button')
      header.type = 'button'
      header.className = 'w-full px-4 py-2 text-left text-sm font-semibold text-gray-700 dark:text-gray-300 bg-gray-50 dark:bg-gray-900 hover:bg-gray-100 dark:hover:bg-gray-800 flex items-center'
      header.setAttribute('data-organism-selector-target', 'groupHeader')
      header.setAttribute('data-action', 'click->organism-selector#toggleGroup')

      const chevronDiv = document.createElement('div')
      chevronDiv.className = 'mr-3'
      chevronDiv.style.color = '#9ca3af'
      const chevron = document.createElement('i')
      chevron.className = 'fas fa-chevron-right'
      chevron.style.fontSize = '14px'
      chevron.style.transition = 'transform 0.3s ease-out'
      chevron.setAttribute('data-organism-selector-target', 'groupChevron')
      chevronDiv.appendChild(chevron)

      const domainSpan = document.createElement('span')
      domainSpan.className = 'flex-1'
      domainSpan.textContent = group.domain

      const countSpan = document.createElement('span')
      countSpan.className = 'inline-flex items-center justify-center px-2 py-1 text-xs font-semibold rounded-full bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 ml-2'
      countSpan.textContent = group.count

      header.appendChild(chevronDiv)
      header.appendChild(domainSpan)
      header.appendChild(countSpan)

      // Group content
      const content = document.createElement('div')
      content.className = 'hidden'
      content.setAttribute('data-organism-selector-target', 'groupContent')

      group.organisms.forEach(org => {
        const option = document.createElement('button')
        option.type = 'button'
        option.className = 'w-full px-6 py-2 text-left text-sm text-gray-700 dark:text-gray-300 hover:bg-blue-50 dark:hover:bg-blue-900/30 transition-colors'
        option.setAttribute('data-organism-id', org.id)
        option.setAttribute('data-organism-selector-target', 'option')
        option.setAttribute('data-action', 'click->organism-selector#selectOrganism')

        const nameSpan = document.createElement('span')
        nameSpan.textContent = org.display_name

        option.appendChild(nameSpan)
        if (org.tax_id) {
          const taxSpan = document.createElement('span')
          taxSpan.className = 'text-gray-500 dark:text-gray-400 ml-2 text-xs italic'
          taxSpan.textContent = `(${org.tax_id})`
          option.appendChild(taxSpan)
        }

        content.appendChild(option)
      })

      groupDiv.appendChild(header)
      groupDiv.appendChild(content)
      this.dropdownMenuTarget.appendChild(groupDiv)
    })

    console.log('[OrganismSelector] Updated organism dropdown with', groups.length, 'groups')
  }
}

