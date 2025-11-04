/**
 * UI Manager Module
 * Handles UI elements, tooltips, and settings
 */

export class UIManager {
  constructor(controller) {
    this.controller = controller
  }

  // Tooltip management
  initializeTooltip() {
    //console.log('🔧 Initializing tooltip system')
    this.controller.tooltip = document.getElementById('point-tooltip')
    this.controller.tooltipContent = document.getElementById('tooltip-content')
    
    if (!this.controller.tooltip || !this.controller.tooltipContent) {
      console.warn('Tooltip elements not found, creating dynamically:', {
        tooltip: !!this.controller.tooltip,
        tooltipContent: !!this.controller.tooltipContent,
        tooltipElement: this.controller.tooltip,
        contentElement: this.controller.tooltipContent
      })
      
      // Create tooltip dynamically
      this.createTooltipDynamically()
      return
    }
  }

  createTooltipDynamically() {
    console.log('🎯 [Tooltip] Creating tooltip dynamically')
    
    // Remove existing tooltip if it exists
    const existingTooltip = document.getElementById('point-tooltip')
    if (existingTooltip) {
      console.log('🎯 [Tooltip] Removing existing tooltip')
      existingTooltip.remove()
    }
    
    // Create tooltip element
    this.controller.tooltip = document.createElement('div')
    this.controller.tooltip.id = 'point-tooltip'
    
    // Set styles individually for better compatibility
    this.controller.tooltip.style.position = 'fixed'
    this.controller.tooltip.style.backgroundColor = 'red'
    this.controller.tooltip.style.color = 'white'
    this.controller.tooltip.style.padding = '12px 16px'
    this.controller.tooltip.style.borderRadius = '6px'
    this.controller.tooltip.style.fontSize = '16px'
    this.controller.tooltip.style.pointerEvents = 'none'
    this.controller.tooltip.style.zIndex = '999999'
    this.controller.tooltip.style.display = 'none'
    this.controller.tooltip.style.maxWidth = '200px'
    this.controller.tooltip.style.wordWrap = 'break-word'
    this.controller.tooltip.style.boxShadow = '0 4px 6px rgba(0, 0, 0, 0.3)'
    this.controller.tooltip.style.border = '3px solid yellow'
    this.controller.tooltip.style.left = '50px'
    this.controller.tooltip.style.top = '50px'
    
    // Create content element
    this.controller.tooltipContent = document.createElement('div')
    this.controller.tooltipContent.id = 'tooltip-content'
    this.controller.tooltip.appendChild(this.controller.tooltipContent)
    
    // Add to body
    document.body.appendChild(this.controller.tooltip)
    
    console.log('🎯 [Tooltip] Tooltip created dynamically:', {
      tooltip: this.controller.tooltip,
      tooltipContent: this.controller.tooltipContent,
      parentNode: this.controller.tooltip.parentNode,
      tooltipId: this.controller.tooltip.id
    })
  }

  showTooltip(x, y, content) {
    return this.controller.showTooltip(x, y, content)
  }

  hideTooltip() {
    return this.controller.hideTooltip()
  }

  updateTooltipContent(content) {
    return this.controller.updateTooltipContent(content)
  }

  // Loading spinners and indicators
  showLoadingSpinner(metadataId) {
    // Show spinner in place of the metadata checkbox
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    if (metadataCheckbox) {
      // Store original content if not already stored
      if (!metadataCheckbox.dataset.originalContent) {
        metadataCheckbox.dataset.originalContent = metadataCheckbox.innerHTML
      }
      
      // Show the checkbox container and replace content with spinner
      metadataCheckbox.style.display = 'flex'
      metadataCheckbox.innerHTML = `
        <svg style="width: 12px; height: 12px; animation: spin 1s linear infinite;" fill="none" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566" opacity="0.25"/>
          <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566">
            <animate attributeName="stroke-dashoffset" dur="1.5s" values="12.566;0;12.566" repeatCount="indefinite"/>
          </circle>
        </svg>
      `
      
      // Disable checkbox during loading
      metadataCheckbox.style.pointerEvents = 'none'
      metadataCheckbox.style.opacity = '0.7'
    }
    
    // Also show spinner on water drop button for consistency
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-action*="waterDropClicked"]`)
    if (button) {
      // Store original content
      if (!button.dataset.originalContent) {
        button.dataset.originalContent = button.innerHTML
      }
      
      // Replace with spinner
      button.innerHTML = `
        <svg style="width: 16px; height: 16px; animation: spin 1s linear infinite;" fill="none" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566" opacity="0.25"/>
          <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566">
            <animate attributeName="stroke-dashoffset" dur="1.5s" values="12.566;0;12.566" repeatCount="indefinite"/>
          </circle>
        </svg>
      `
      
      // Disable button during loading
      button.disabled = true
      button.style.cursor = 'not-allowed'
    }
    
    // Add CSS for spinner animation if not already added
    if (!document.getElementById('spinner-animation-css')) {
      const style = document.createElement('style')
      style.id = 'spinner-animation-css'
      style.textContent = `
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `
      document.head.appendChild(style)
    }
  }

  hideLoadingSpinner(metadataId) {
    // Restore the metadata checkbox
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    if (metadataCheckbox) {
      // Restore original content
      if (metadataCheckbox.dataset.originalContent) {
        metadataCheckbox.innerHTML = metadataCheckbox.dataset.originalContent
      }
      
      // Re-enable checkbox
      metadataCheckbox.style.pointerEvents = 'auto'
      metadataCheckbox.style.opacity = '1'
      
      // Keep the checkbox visible since metadata is now loaded
      metadataCheckbox.style.display = 'flex'
    }
    
    // Restore the water drop button
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-action*="waterDropClicked"]`)
    if (button) {
      // Restore original content
      if (button.dataset.originalContent) {
        button.innerHTML = button.dataset.originalContent
      }
      
      // Re-enable button
      button.disabled = false
      button.style.cursor = 'pointer'
    } else {
      console.log(`Could not find water drop button for metadata ID: ${metadataId}`)
    }
  }

  showMetadataDropdownSpinner() {
    return this.controller.showMetadataDropdownSpinner()
  }

  hideMetadataDropdownSpinner() {
    return this.controller.hideMetadataDropdownSpinner()
  }

  // Metadata preloading
  preloadMetadataVector(event) {
    return this.controller.dataManager.preloadMetadataVector(event)
  }

  cancelPreload(event) {
    return this.controller.dataManager.cancelPreload(event)
  }

  // Diagnostic and debugging
  runEmergencyDiagnostic() {
    return this.controller.runEmergencyDiagnostic()
  }

  createDiagnosticButton() {
    return this.controller.createDiagnosticButton()
  }

  // UI state management
  updateButtonStates(activeMode) {
    return this.controller.updateButtonStates(activeMode)
  }

  updateControlInstructions() {
    return this.controller.updateControlInstructions()
  }

  // Settings and toggles (actual implementations are further down in the file)

  toggleCategoryLabels() {
    return this.controller.toggleCategoryLabels()
  }

  // Label management
  renderCategoryLabels() {
    return this.controller.renderCategoryLabels()
  }

  renderContinuousColorLegend() {
    return this.controller.renderContinuousColorLegend()
  }

  // Point size management
  updatePointSize(newSize) {
    return this.controller.rendererManager.updateAllPointSizes(newSize)
  }

  // Selection display
  updateSelectedCellsCount() {
    return this.controller.updateSelectedCellsCount()
  }

  // Show spinner next to metadata dropdown
  showMetadataDropdownSpinner() {
    const dropdown = document.getElementById('metadata-select-dropdown')
    const spinner = document.getElementById('metadata-loading-spinner')
    
    if (dropdown) {
      dropdown.disabled = true
      dropdown.style.opacity = '0.6'
    }
    if (spinner) {
      spinner.style.display = 'block'
    }
  }

  // Hide spinner and re-enable metadata dropdown
  hideMetadataDropdownSpinner() {
    const dropdown = document.getElementById('metadata-select-dropdown')
    const spinner = document.getElementById('metadata-loading-spinner')
    
    if (dropdown) {
      dropdown.disabled = false
      dropdown.style.opacity = '1'
    }
    if (spinner) {
      spinner.style.display = 'none'
    }
  }

  // Show loading spinner for a specific metadata ID
  showLoadingSpinner(metadataId) {
    // Show spinner in place of the metadata checkbox
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    if (metadataCheckbox) {
      const spinner = metadataCheckbox.querySelector('.loading-spinner')
      if (spinner) {
        spinner.style.display = 'inline-block'
      }
      metadataCheckbox.disabled = true
    }
  }

  // Hide loading spinner for a specific metadata ID
  hideLoadingSpinner(metadataId) {
    // Restore the metadata checkbox
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    if (metadataCheckbox) {
      const spinner = metadataCheckbox.querySelector('.loading-spinner')
      if (spinner) {
        spinner.style.display = 'none'
      }
      metadataCheckbox.disabled = false
    }
  }

  // Show checkboxes for metadata
  showCheckboxesForMetadata(metadataId) {
    console.log(`🔍 [UI] showCheckboxesForMetadata called for ${metadataId}`)
    
    const metadataVector = this.controller.dataManager.getMetadataVectorById(metadataId)
    console.log(`🔍 [UI] getMetadataVectorById result for ${metadataId}:`, metadataVector ? 'found' : 'not found')
    
    const isCategorical = metadataVector?.data_type === 'DISCRETE'
    const isContinuous = metadataVector?.data_type === 'NUMERIC'
    
    if (isCategorical) {
      // For categorical metadata, show the new UI elements
      console.log(`🔍 [UI] Processing categorical metadata ${metadataId}`)
      
      // Status icon updates should be handled by data loading logic, not UI display logic
      
      // Show select all/none checkbox
      const selectAllCheckbox = document.querySelector(`.metadata-select-all-checkbox[data-metadata-id="${metadataId}"]`)
      if (selectAllCheckbox) {
        selectAllCheckbox.style.display = 'flex'
        // Initialize as checked with white background
        selectAllCheckbox.style.backgroundColor = 'white'
        selectAllCheckbox.style.borderColor = '#d1d5db'
        const icon = selectAllCheckbox.querySelector('i')
        if (icon) {
          icon.style.display = 'block'
          icon.style.color = '#10b981' // green checkmark
        }
        
        // Check if there's only one category - if so, disable the checkbox
        if (metadataVector && metadataVector.values) {
          const uniqueCategories = new Set(metadataVector.values)
          if (uniqueCategories.size === 1) {
            selectAllCheckbox.style.opacity = '0.5'
            selectAllCheckbox.style.cursor = 'not-allowed'
            selectAllCheckbox.style.pointerEvents = 'none'
            selectAllCheckbox.title = 'Cannot deselect - only one category available'
          }
        }
      }
      
      // Show ON/OFF switch only if there are selected categories
      const filterSwitch = document.querySelector(`.metadata-filter-switch[data-metadata-id="${metadataId}"]`)
      if (filterSwitch) {
        const hasSelection = this.controller.selectedCategories && 
                            this.controller.selectedCategories[metadataId] &&
                            this.controller.selectedCategories[metadataId].size > 0
        
        if (hasSelection) {
          filterSwitch.style.display = 'flex'
          // Initialize as ON (enabled)
          filterSwitch.dataset.filterEnabled = 'true'
          filterSwitch.style.backgroundColor = '#10b981'
          const switchToggle = filterSwitch.querySelector('div')
          if (switchToggle) {
            switchToggle.style.transform = 'translateX(14px)'
          }
        } else {
          // Hide switch if no selection
          filterSwitch.style.display = 'none'
        }
      }
      
      // Note: Don't initialize selectedCategories here!
      // The HTML only shows a subset of categories, not all of them.
      // selectedCategories will be initialized when the user unfolds the metadata
      // (in initializeCheckboxesForMetadata), which loads the full metadata vector.
    } else if (isContinuous) {
      // For continuous metadata, show the new UI elements (status icon, filter state icon, and filter switch)
      console.log(`🔍 [UI] Processing continuous metadata ${metadataId}`)
      
      // Status icon updates should be handled by data loading logic, not UI display logic
      
      // Show filter state icon
      const filterStateIcon = document.querySelector(`.metadata-filter-state-icon[data-metadata-id="${metadataId}"]`)
      if (filterStateIcon) {
        filterStateIcon.style.display = 'flex'
        // Initialize as white (no filter) - will be updated by range slider controller
        filterStateIcon.style.backgroundColor = 'white'
        filterStateIcon.style.borderColor = '#d1d5db'
        const icon = filterStateIcon.querySelector('i')
        if (icon) {
          icon.style.color = '#9ca3af'
        }
      }
      
      // Show ON/OFF filter switch only if there's a selected range
      const filterSwitch = document.querySelector(`.metadata-filter-switch[data-metadata-id="${metadataId}"]`)
      if (filterSwitch) {
        const hasSelection = this.controller.selectedRanges && this.controller.selectedRanges[metadataId]
        
        if (hasSelection) {
          filterSwitch.style.display = 'flex'
          // Default to ON when first showing the switch
          filterSwitch.dataset.filterEnabled = 'true'
          filterSwitch.style.backgroundColor = '#10b981' // green
          const switchToggle = filterSwitch.querySelector('div')
          if (switchToggle) {
            switchToggle.style.transform = 'translateX(14px)'
          }
        } else {
          // Hide switch if no selection
          filterSwitch.style.display = 'none'
        }
      }
    } else {
      console.log(`🔍 [DEBUG] No metadata checkbox found for metadata ${metadataId}`)
    }
    
    // Show all category checkboxes for this metadata
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    // console.log(`🔍 [DEBUG] Found ${categoryCheckboxes.length} category checkboxes for metadata ${metadataId}`)
    
    // Check if there's only one category - if so, disable all category checkboxes
    // (reuse metadataVector from line 311)
    const hasOnlyOneCategory = metadataVector && metadataVector.values && 
                               new Set(metadataVector.values).size === 1
    
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.display = 'flex'
      
      if (hasOnlyOneCategory) {
        // Disable checkbox for single-category metadata
        checkbox.style.opacity = '0.5'
        checkbox.style.cursor = 'not-allowed'
        checkbox.style.pointerEvents = 'none'
        checkbox.title = 'Cannot deselect - only one category available'
      }
    })
    
    // console.log(`🔍 [DEBUG] Showed ${categoryCheckboxes.length} category checkboxes for metadata ${metadataId}`)
  }

  // Show or hide the filter switch based on whether there's a selection
  updateFilterSwitchVisibility(metadataId) {
    const filterSwitch = document.querySelector(`.metadata-filter-switch[data-metadata-id="${metadataId}"]`)
    if (!filterSwitch) return
    
    // Check if this is categorical or continuous metadata
    const metadataVector = this.controller.dataManager.getMetadataVectorById(metadataId)
    const isCategorical = metadataVector?.data_type === 'DISCRETE'
    const isContinuous = metadataVector?.data_type === 'NUMERIC'
    
    let hasActiveFilter = false
    
    if (isCategorical) {
      // For categorical: check if there are selected categories AND not all are selected
      if (this.controller.selectedCategories && 
          this.controller.selectedCategories[metadataId] &&
          this.controller.selectedCategories[metadataId].size > 0) {
        
        // Get total number of categories from metadata vector
        let totalCount = 0
        
        if (metadataVector) {
          if (metadataVector.values) {
            // Normal case: count unique values
            const allCategories = new Set(metadataVector.values)
            totalCount = allCategories.size
          } else if (metadataVector.compression_info?.single_category) {
            // Single category compression: only 1 category
            totalCount = 1
          } else if (metadataVector.compression_info?.categories) {
            // Compressed data: use categories array
            totalCount = metadataVector.compression_info.categories.length
          }
          
          const selectedCount = this.controller.selectedCategories[metadataId].size
          
          // Only show switch if not all categories are selected (i.e., there's actual filtering)
          hasActiveFilter = selectedCount < totalCount
        }
      }
    } else if (isContinuous) {
      // For continuous: check if there's a selected range
      hasActiveFilter = this.controller.selectedRanges && this.controller.selectedRanges[metadataId]
    }
    
    if (hasActiveFilter) {
      // Show the switch
      filterSwitch.style.display = 'flex'
      // Ensure it's ON by default when first showing
      if (filterSwitch.dataset.filterEnabled !== 'false') {
        filterSwitch.dataset.filterEnabled = 'true'
        filterSwitch.style.backgroundColor = '#10b981'
        const switchToggle = filterSwitch.querySelector('div')
        if (switchToggle) {
          switchToggle.style.transform = 'translateX(14px)'
        }
      }
    } else {
      // Hide the switch
      filterSwitch.style.display = 'none'
    }
  }

  // Update gene filter switch visibility (similar to updateFilterSwitchVisibility but for genes)
  updateGeneFilterSwitchVisibility(geneId, geneMetadataId) {
    const filterSwitch = document.querySelector(`.gene-filter-switch[data-gene-id="${geneId}"]`)
    if (!filterSwitch) return
    
    // Check if there's a selected range for this gene
    const hasActiveFilter = this.controller.selectedRanges && this.controller.selectedRanges[geneMetadataId]
    
    if (hasActiveFilter) {
      // Show the switch
      filterSwitch.style.display = 'flex'
      // Ensure it's ON by default when first showing
      if (filterSwitch.dataset.filterEnabled !== 'false') {
        filterSwitch.dataset.filterEnabled = 'true'
        filterSwitch.style.backgroundColor = '#10b981' // green
        const switchToggle = filterSwitch.querySelector('div')
        if (switchToggle) {
          switchToggle.style.transform = 'translateX(14px)'
        }
      }
    } else {
      // Hide switch if no selection
      filterSwitch.style.display = 'none'
    }
  }

  // Update metadata status icon based on loading state
  // States: 'not-loaded', 'downloading', 'in-db', 'in-memory'
  updateMetadataStatusIcon(metadataId, state) {
    const statusIcon = document.querySelector(`.metadata-status-icon[data-metadata-id="${metadataId}"]`)
    if (!statusIcon) return
    
    const icon = statusIcon.querySelector('i')
    if (!icon) return
    
    // Show the icon
    statusIcon.style.display = 'flex'
    
    switch (state) {
      case 'not-loaded':
        // Gray circle with animated spinner
        statusIcon.style.backgroundColor = '#9ca3af'
        icon.className = 'fas fa-spinner fa-spin'
        icon.style.color = 'white'
        statusIcon.title = 'Waiting...'
        break
        
      case 'downloading':
        // Blue circle with spinner
        statusIcon.style.backgroundColor = '#3b82f6'
        icon.className = 'fas fa-spinner fa-spin'
        icon.style.color = 'white'
        statusIcon.title = 'Downloading from server...'
        break
        
      case 'in-db':
        // Orange circle with check
        statusIcon.style.backgroundColor = '#f59e0b'
        icon.className = 'fas fa-check'
        icon.style.color = 'white'
        statusIcon.title = 'Metadata in database (on disk)'
        break
        
      case 'in-memory':
        // Green circle with check
        statusIcon.style.backgroundColor = '#10b981'
        icon.className = 'fas fa-check'
        icon.style.color = 'white'
        statusIcon.title = 'Metadata in memory (fast access)'
        break
        
      default:
        console.warn(`Unknown status icon state: ${state}`)
    }
  }

  // Update gene status icon based on loading state
  // States: 'not-loaded', 'downloading', 'in-db', 'in-memory', 'error'
  updateGeneStatusIcon(geneId, state, errorMessage = null) {
    const statusIcon = document.querySelector(`.gene-status-icon[data-gene-id="${geneId}"]`)
    if (!statusIcon) return
    
    const icon = statusIcon.querySelector('i')
    if (!icon) return
    
    // Show the icon
    statusIcon.style.display = 'flex'
    
    switch (state) {
      case 'not-loaded':
        // Gray circle with animated spinner
        statusIcon.style.backgroundColor = '#9ca3af'
        icon.className = 'fas fa-spinner fa-spin'
        icon.style.color = 'white'
        statusIcon.title = 'Waiting...'
        break
        
      case 'downloading':
        // Blue circle with spinner
        statusIcon.style.backgroundColor = '#3b82f6'
        icon.className = 'fas fa-spinner fa-spin'
        icon.style.color = 'white'
        statusIcon.title = 'Downloading from server...'
        break
        
      case 'in-db':
        // Orange circle with check
        statusIcon.style.backgroundColor = '#f59e0b'
        icon.className = 'fas fa-check'
        icon.style.color = 'white'
        statusIcon.title = 'Gene expression in database (on disk)'
        break
        
      case 'in-memory':
        // Green circle with check
        statusIcon.style.backgroundColor = '#10b981'
        icon.className = 'fas fa-check'
        icon.style.color = 'white'
        statusIcon.title = 'Gene expression in memory (fast access)'
        break
        
      case 'error':
        // Red circle with exclamation
        statusIcon.style.backgroundColor = '#dc2626'
        icon.className = 'fas fa-exclamation-circle'
        icon.style.color = 'white'
        statusIcon.title = errorMessage ? `Error: ${errorMessage}` : 'Error loading expression data'
        break
        
      default:
        console.warn(`Unknown gene status icon state: ${state}`)
    }
  }

  // Initialize all checkboxes for the current metadata
  initializeAllCheckboxes() {
    // Initialize checkboxes only for the currently loaded metadata
    const metadataId = this.controller.currentMetadataId
    if (!metadataId) {
      console.log('⚠️ No current metadata ID - skipping checkbox initialization')
      return
    }

    this.controller.initializeCheckboxesForMetadata(metadataId)
  }

  // Update categories checkbox state based on current metadata
  updateCategoriesCheckboxState() {
    const checkbox = document.getElementById('show-categories-checkbox')
    if (!checkbox) return
    
    // Check if current metadata is discrete
    const isDiscreteMetadata = this.controller.currentMetadataVector && this.controller.currentMetadataVector.data_type === 'DISCRETE'
    
    // Always keep checkbox enabled so users can set preference before selecting categorical metadata
    checkbox.disabled = false
    
    if (isDiscreteMetadata) {
      checkbox.title = 'Toggle category legend visibility'
    } else {
      checkbox.title = 'Category labels will appear when categorical metadata is selected'
    }
  }

  // Enable range slider for continuous metadata
  enableRangeSliderForMetadata(metadataId) {
    const metadataItem = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataItem) return
    
    const rangeSection = metadataItem.querySelector('.metadata-range-section')
    if (!rangeSection) return
    
    // Find all interactive elements in the range slider
    const minInput = rangeSection.querySelector('.range-min-input')
    const maxInput = rangeSection.querySelector('.range-max-input')
    const minHandle = rangeSection.querySelector('.range-slider-min-handle')
    const maxHandle = rangeSection.querySelector('.range-slider-max-handle')
    const adaptButton = rangeSection.querySelector('[data-range-slider-target="adaptColorRangeButton"]')
    
    // Enable all controls
    if (minInput) minInput.disabled = false
    if (maxInput) maxInput.disabled = false
    if (minHandle) minHandle.style.pointerEvents = 'auto'
    if (maxHandle) maxHandle.style.pointerEvents = 'auto'
    if (adaptButton) adaptButton.disabled = false
    
    // Remove visual disabled state
    if (rangeSection) rangeSection.style.opacity = '1'
  }

  // Disable range slider for continuous metadata
  disableRangeSliderForMetadata(metadataId) {
    const metadataItem = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataItem) return
    
    const rangeSection = metadataItem.querySelector('.metadata-range-section')
    if (!rangeSection) return
    
    // Find all interactive elements in the range slider
    const minInput = rangeSection.querySelector('.range-min-input')
    const maxInput = rangeSection.querySelector('.range-max-input')
    const minHandle = rangeSection.querySelector('.range-slider-min-handle')
    const maxHandle = rangeSection.querySelector('.range-slider-max-handle')
    const adaptButton = rangeSection.querySelector('[data-range-slider-target="adaptColorRangeButton"]')
    
    // Disable all controls
    if (minInput) minInput.disabled = true
    if (maxInput) maxInput.disabled = true
    if (minHandle) minHandle.style.pointerEvents = 'none'
    if (maxHandle) maxHandle.style.pointerEvents = 'none'
    if (adaptButton) adaptButton.disabled = true
    
    // Add visual disabled state
    if (rangeSection) rangeSection.style.opacity = '0.5'
  }

  // Enable category checkboxes for a metadata
  enableCategoryCheckboxesForMetadata(metadataId) {
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.pointerEvents = 'auto'
      checkbox.style.opacity = '1'
      checkbox.style.cursor = 'pointer'
    })
  }

  // Disable category checkboxes for a metadata
  disableCategoryCheckboxesForMetadata(metadataId) {
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.pointerEvents = 'none'
      checkbox.style.opacity = '0.5'
      checkbox.style.cursor = 'not-allowed'
    })
  }

  // Update point count display
  updatePointCountDisplay(filteredIndices) {
    const pointCountElement = document.getElementById('point-count')
    if (!pointCountElement) return

    const totalPoints = this.controller.currentCoordinates?.length || 0
    
    // Handle undefined or null filteredIndices
    if (!filteredIndices || filteredIndices === undefined) {
      // No filtering applied - show total points
      pointCountElement.textContent = `${totalPoints.toLocaleString()} points`
      pointCountElement.title = 'All points visible (no filtering applied)'
      pointCountElement.style.color = '' // Reset to default
      pointCountElement.style.fontWeight = ''
    } else {
      // Filtering applied - show filtered count and percentage
      const filteredCount = filteredIndices.length || 0
      const percentage = totalPoints > 0 ? ((filteredCount / totalPoints) * 100).toFixed(1) : 0
      const filteringSummary = this.controller.dataManager.getFilteringSummary()
      
      pointCountElement.textContent = `${filteredCount.toLocaleString()} points`
      
      // Create detailed tooltip
      let tooltip = `${filteredCount.toLocaleString()} of ${totalPoints.toLocaleString()} points visible (${percentage}%)`
      if (filteringSummary) {
        tooltip += `\n\nActive filters: ${filteringSummary}`
      }
      pointCountElement.title = tooltip
      
      // Add visual indicator if filtering is applied
      if (filteredCount < totalPoints) {
        pointCountElement.style.color = '#f59e0b' // Orange to indicate filtering
        pointCountElement.style.fontWeight = '600'
      } else {
        pointCountElement.style.color = '' // Reset to default
        pointCountElement.style.fontWeight = ''
      }
    }

    // Ensure the plot info panel is visible
    this.showPlotInfoPanel()
  }

  // Show the plot info panel
  showPlotInfoPanel() {
    const plotInfo = document.getElementById('plot-info')
    if (plotInfo) {
      plotInfo.style.display = 'block'
    }
  }

  // Update all range slider counts
  updateAllRangeSliderCounts() {
    // Find all range slider controllers and trigger their count updates
    // Only update sliders that have been initialized (have data in inlineRangeSliderData)
    const rangeSliderElements = document.querySelectorAll('[data-controller~="range-slider"]')
    rangeSliderElements.forEach(element => {
      // Get the metadata ID from the element
      const metadataId = element.getAttribute('data-range-slider-metadata-id-value')
      if (!metadataId) return
      
      // Check if slider data is available before trying to update
      const hasSliderData = this.controller.inlineRangeSliderData && 
                           this.controller.inlineRangeSliderData[metadataId] &&
                           this.controller.inlineRangeSliderData[metadataId].values
      
      if (!hasSliderData) {
        // Skip sliders that haven't been initialized yet
        return
      }
      
      // Get the Stimulus controller instance
      const controller = this.controller.application?.getControllerForElementAndIdentifier(element, 'range-slider')
      if (controller && typeof controller.updateSelectedCellsCount === 'function') {
        controller.updateSelectedCellsCount()
      }
    })
  }

  // Update sidebar category counts with visual indicators for ALL categorical metadata
  updateSidebarCategoryCounts() {
    // PERFORMANCE: This function can be very slow with many metadata loaded
    // Only update counts for VISIBLE (expanded) metadata to avoid blocking the UI
    
    const perfStart = performance.now()
    
    // DEBUG: Log who's calling this function
    console.log(`⏱️ [PERF] updateSidebarCategoryCounts called from:`)
    console.trace()
    
    // Find all category checkboxes that are currently visible (display !== 'none')
    const allCategoryCheckboxes = document.querySelectorAll('.category-checkbox')
    const visibleCheckboxes = Array.from(allCategoryCheckboxes).filter(cb => {
      // Check if the checkbox's parent container is visible
      const container = cb.closest('[data-metadata-item]')
      if (!container) return false
      
      // Find the categories div (sibling of the header)
      const header = container.querySelector('[data-action*="toggleMetadata"]')
      if (!header) return false
      
      const categoriesDiv = header.nextElementSibling
      if (!categoriesDiv) return false
      
      // Only process if categories are expanded (visible)
      return categoriesDiv.style.display !== 'none'
    })
    
    console.log(`⏱️ [PERF] updateSidebarCategoryCounts: Processing ${visibleCheckboxes.length}/${allCategoryCheckboxes.length} visible checkboxes`)
    
    // Convert currentVisibleCells to Set once for O(1) lookups
    const visibleSet = this.controller.currentVisibleCells ? new Set(this.controller.currentVisibleCells) : null
    
    visibleCheckboxes.forEach(checkbox => {
      const metadataId = checkbox.dataset.metadataId
      const category = checkbox.dataset.category
      
      // Get the metadata vector for this metadata ID (only if already loaded in memory)
      const metadataVector = this.controller.loadedMetadataVectors[metadataId]
      if (!metadataVector || !metadataVector.values) return
      
      // Find the count span - it's the second span in the parent container
      const parentContainer = checkbox.parentElement.parentElement
      const spans = parentContainer.querySelectorAll('span')
      const countSpan = spans[spans.length - 1] // Last span is the count
      
      if (countSpan) {
        // Count total and visible cells for this category
        let totalCount = 0
        let visibleCount = 0
        
        for (let i = 0; i < metadataVector.values.length; i++) {
          if (metadataVector.values[i] === category) {
            totalCount++
            // O(1) lookup with Set instead of array iteration
            if (!visibleSet || visibleSet.has(i)) {
              visibleCount++
            }
          }
        }
        
        // Update the count display
        countSpan.textContent = visibleCount.toLocaleString()
        
        // Add visual indicators
        if (totalCount > visibleCount) {
          // Some cells are filtered out - show in red
          countSpan.style.color = '#dc2626'
          countSpan.style.fontWeight = '600'
          
          // Add hover tooltip
          const percentage = ((visibleCount / totalCount) * 100).toFixed(1)
          countSpan.title = `${visibleCount.toLocaleString()} of ${totalCount.toLocaleString()} cells (${percentage}% visible after filtering)`
        } else {
          // No filtering - normal appearance
          countSpan.style.color = '#6b7280'
          countSpan.style.fontWeight = '500'
          countSpan.title = `${totalCount.toLocaleString()} cells (100% visible)`
        }
      }
    })
    
    const perfTime = performance.now() - perfStart
    console.log(`⏱️ [PERF] updateSidebarCategoryCounts completed in ${perfTime.toFixed(2)}ms`)
    
    if (perfTime > 100) {
      console.warn(`⚠️ [PERF] updateSidebarCategoryCounts took ${perfTime.toFixed(2)}ms - consider further optimization`)
    }
  }

  // Update selected cells count display
  updateSelectedCellsCount() {
    const countElement = document.getElementById('selected-cells-count')
    //console.log(`updateSelectedCellsCount called - countElement found:`, !!countElement)
    
    if (countElement) {
      const totalSelectedCount = this.controller.selectedCells ? this.controller.selectedCells.size : 0
      countElement.textContent = totalSelectedCount.toLocaleString()
      
      // Update tooltip with detailed information
      if (totalSelectedCount > 0) {
        const visibleCount = this.controller.currentVisibleCells ? this.controller.currentVisibleCells.length : 0
        const totalCount = this.controller.currentCoordinates ? this.controller.currentCoordinates.length : 0
        const percentage = totalCount > 0 ? ((totalSelectedCount / totalCount) * 100).toFixed(1) : 0
        
        countElement.title = `${totalSelectedCount.toLocaleString()} cells selected (${percentage}% of ${totalCount.toLocaleString()} total)`
        countElement.style.color = '#1f2937'
        countElement.style.fontWeight = '600'
      } else {
        countElement.title = 'No cells selected'
        countElement.style.color = '#6b7280'
        countElement.style.fontWeight = '500'
      }
    }
  }

  // Update the state of the "Add all visible cells" button
  updateAddAllVisibleButtonState() {
    const button = document.getElementById('add-all-visible-btn')
    if (!button) return
    
    const visibleCount = this.controller.currentVisibleCells ? this.controller.currentVisibleCells.length : 0
    const selectedCount = this.controller.selectedCells ? this.controller.selectedCells.size : 0
    
    if (visibleCount === 0) {
      // No visible cells
      button.disabled = true
      button.textContent = 'No visible cells'
      button.title = 'No cells are currently visible'
    } else if (selectedCount >= visibleCount) {
      // All visible cells are already selected
      button.disabled = true
      button.textContent = 'All visible selected'
      button.title = 'All visible cells are already selected'
    } else {
      // Some visible cells are not selected
      button.disabled = false
      const remainingCount = visibleCount - selectedCount
      button.textContent = `Add ${remainingCount.toLocaleString()} visible`
      button.title = `Add ${remainingCount.toLocaleString()} remaining visible cells to selection`
    }
  }

  // Settings Window Methods
  toggleSettingsWindow() {
    const settingsWindow = document.getElementById('settings-window')
    if (!settingsWindow) return
    
    if (settingsWindow.style.display === 'none' || settingsWindow.style.display === '') {
      settingsWindow.style.display = 'block'
      this.initializeSettingsWindow()
    } else {
      settingsWindow.style.display = 'none'
    }
  }

  initializeSettingsWindow() {
    // Initialize point size slider value display
    const slider = document.getElementById('point-size-slider')
    const valueDisplay = document.getElementById('point-size-value')
    if (slider && valueDisplay) {
      // Set slider to current point size
      slider.value = this.controller.currentPointSize
      valueDisplay.textContent = this.controller.currentPointSize.toFixed(1)
      //console.log(`Settings window initialized with point size: ${this.controller.currentPointSize}`)
      
      // Add direct event listener to ensure it works
      slider.addEventListener('input', (e) => {
        const newSize = parseFloat(e.target.value)
        valueDisplay.textContent = newSize.toFixed(1)
        //console.log(`Slider value changed to: ${newSize}`)
        
        // CRITICAL: Update this.currentPointSize so it persists across re-renders
        //console.log(`Direct listener updating currentPointSize: ${this.controller.currentPointSize} -> ${newSize}`)
        this.controller.currentPointSize = newSize
        
        this.controller.rendererManager.updateAllPointSizes(newSize)
      })
    }
    
    // Add direct event listeners for checkboxes to ensure they work
    const axesCheckbox = document.getElementById('show-axes-checkbox')
    if (axesCheckbox) {
      //console.log('Adding event listener to axes checkbox')
      // Remove any existing listeners first
      axesCheckbox.removeEventListener('change', this.controller.boundAxesToggle)
      // Create bound method for proper cleanup
      this.controller.boundAxesToggle = (e) => {
        //console.log('Direct axes checkbox event listener triggered!')
        this.controller.toggleAxes()
      }
      axesCheckbox.addEventListener('change', this.controller.boundAxesToggle)
    } else {
      console.log('Axes checkbox not found during initialization!')
    }
    
    const gridCheckbox = document.getElementById('show-grid-checkbox')
    if (gridCheckbox) {
      gridCheckbox.addEventListener('change', (e) => {
        //console.log('Direct grid checkbox event listener triggered!')
        this.controller.toggleGrid()
      })
    }
    
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')
    if (categoriesCheckbox) {
      categoriesCheckbox.addEventListener('change', (e) => {
        //console.log('Direct categories checkbox event listener triggered!')
        this.controller.toggleCategories()
      })
    }
    
    // Add event listener for category order dropdown and set current value
    const categoryOrderSelect = document.getElementById('category-order-select')
    if (categoryOrderSelect) {
      // Set the selected option based on current preference
      categoryOrderSelect.value = this.controller.categoryOrder
      
      // Add event listener
      categoryOrderSelect.addEventListener('change', (e) => {
        console.log('📊 Category order changed:', e.target.value)
        this.changeCategoryOrder(e)
      })
    }
    
    // Add event listener for numerical order dropdown and set current value
    const numericalOrderSelect = document.getElementById('numerical-order-select')
    if (numericalOrderSelect) {
      // Set the selected option based on current preference
      numericalOrderSelect.value = this.controller.numericalOrder
      
      // Add event listener
      numericalOrderSelect.addEventListener('change', (e) => {
        console.log('📊 Numerical order changed:', e.target.value)
        this.changeNumericalOrder(e)
      })
    }
    
    // Add event listener for auto-preload checkbox
    const autoPreloadCheckbox = document.getElementById('auto-preload-checkbox')
    if (autoPreloadCheckbox) {
      // Set checkbox based on current preference
      autoPreloadCheckbox.checked = this.controller.autoPreloadMetadata
      
      // Add event listener
      autoPreloadCheckbox.addEventListener('change', (e) => {
        this.controller.autoPreloadMetadata = e.target.checked
        console.log('📊 Auto-preload metadata:', this.controller.autoPreloadMetadata)
        
        // If enabled, start preloading now
        if (this.controller.autoPreloadMetadata) {
          console.log('🚀 Starting automatic preload after checkbox enable...')
          this.controller.preloadAllMetadata().catch(error => {
            console.log('Background metadata preload encountered an error:', error)
          })
        }
      })
    }
    
    // Update categories checkbox state based on current metadata
    this.updateCategoriesCheckboxState()
    
    // Make window draggable
    this.makeSettingsWindowDraggable()
  }

  makeSettingsWindowDraggable() {
    const settingsWindow = document.getElementById('settings-window')
    const header = document.getElementById('settings-header')
    if (!settingsWindow || !header) return
    
    let isDragging = false
    let startX, startY, startLeft, startTop
    
    const startDrag = (e) => {
      isDragging = true
      startX = e.clientX
      startY = e.clientY
      
      // Get the actual current position of the window using computed position
      const rect = settingsWindow.getBoundingClientRect()
      startLeft = rect.left
      startTop = rect.top
      
      // Set explicit positioning to prevent jump
      settingsWindow.style.left = startLeft + 'px'
      settingsWindow.style.top = startTop + 'px'
      
      settingsWindow.style.cursor = 'grabbing'
      e.preventDefault()
    }
    
    const doDrag = (e) => {
      if (!isDragging) return
      
      const deltaX = e.clientX - startX
      const deltaY = e.clientY - startY
      
      settingsWindow.style.left = (startLeft + deltaX) + 'px'
      settingsWindow.style.top = (startTop + deltaY) + 'px'
    }
    
    const stopDrag = () => {
      isDragging = false
      settingsWindow.style.cursor = 'move'
    }
    
    header.addEventListener('mousedown', startDrag)
    document.addEventListener('mousemove', doDrag)
    document.addEventListener('mouseup', stopDrag)
    
    // Close button functionality
    const closeBtn = document.getElementById('close-settings-btn')
    if (closeBtn) {
      closeBtn.addEventListener('click', () => {
        settingsWindow.style.display = 'none'
      })
    }
  }

  // Tooltip methods
  showTooltip(cellId, point) {
    // This method is kept for compatibility with PixiJS mode
    // For RegL mode, we use showSimpleTooltip instead
    
    // Get cell information
    const cellName = `Cell ${cellId + 1}` // Generate cell name from ID
    
    // Get category information if available
    let categoryInfo = ''
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.values && this.controller.currentMetadataVector.values[cellId] !== undefined) {
      const { data_type, values } = this.controller.currentMetadataVector
      const value = values[cellId]
      
      if (data_type === 'DISCRETE') {
        // For discrete metadata, show the category name
        categoryInfo = `<br><strong>Category:</strong> ${value}`
      } else if (data_type === 'NUMERIC') {
        // For continuous metadata, show the numeric value
        categoryInfo = `<br><strong>Value:</strong> ${value.toFixed(3)}`
      }
    }
    
    // Set tooltip content with fixed/dynamic indicator
    let statusIndicator = ''
    if (this.controller.rendererType === 'regl' && this.controller.isTooltipFixed) {
      statusIndicator = '<br><em style="color: #00ff00;">🔒</em>'
    } else if (this.controller.rendererType === 'regl') {
      //statusIndicator = '<br><em style="color: #ccc;"></em>'
    }
    
    const tooltipHTML = `<strong>${cellName}</strong>${categoryInfo}${statusIndicator}`
    this.controller.tooltipContent.innerHTML = tooltipHTML
    // Tooltip content set
    
    // Position tooltip near the mouse cursor
    const plotContainer = document.querySelector('.plot-container')
    if (!plotContainer) {
      console.log('Plot container not found')
      return
    }
    
    const rect = plotContainer.getBoundingClientRect()
    // Plot container positioned
    
    // Get point position in screen coordinates
    const pointX = point.x + rect.left
    const pointY = point.y + rect.top
    
    // Position tooltip to the right of the point, with some offset
    let tooltipLeft = pointX + 15
    let tooltipTop = pointY - 10
    
    // Ensure tooltip stays within the plot container bounds
    const tooltipWidth = 200 // max-width from CSS
    const tooltipHeight = 50 // estimated height
    
    // Check if tooltip would go off the right edge
    if (tooltipLeft + tooltipWidth > rect.right) {
      tooltipLeft = pointX - tooltipWidth - 15 // Position to the left instead
    }
    
    // Check if tooltip would go off the bottom edge
    if (tooltipTop + tooltipHeight > rect.bottom) {
      tooltipTop = pointY - tooltipHeight - 10 // Position above instead
    }
    
    // Check if tooltip would go off the top edge
    if (tooltipTop < rect.top) {
      tooltipTop = rect.top + 10 // Keep it within bounds
    }
    
    // Additional safety check - ensure tooltip is within viewport
    if (tooltipLeft < rect.left) {
      tooltipLeft = rect.left + 10
    }
    if (tooltipLeft > rect.right - tooltipWidth) {
      tooltipLeft = rect.right - tooltipWidth - 10
    }
    
    console.log('🎯 [Tooltip] Positioning tooltip at:', { tooltipLeft, tooltipTop, pointX, pointY })
    
    this.controller.tooltip.style.left = `${tooltipLeft}px`
    this.controller.tooltip.style.top = `${tooltipTop}px`
    this.controller.tooltip.style.display = 'block'
    
    // Temporarily make tooltip more visible for debugging
    this.controller.tooltip.style.backgroundColor = 'red'
    this.controller.tooltip.style.fontSize = '16px'
    this.controller.tooltip.style.padding = '12px 16px'
    
    // Tooltip positioned
    
    // Debug: Check if tooltip is actually visible
    const computedStyle = window.getComputedStyle(this.controller.tooltip)
    console.log('🎯 [Tooltip] Computed style:', {
      display: computedStyle.display,
      visibility: computedStyle.visibility,
      opacity: computedStyle.opacity,
      position: computedStyle.position,
      zIndex: computedStyle.zIndex
    })
    
    // Force tooltip to be visible with maximum z-index
    this.controller.tooltip.style.zIndex = '999999'
    this.controller.tooltip.style.position = 'fixed'
    this.controller.tooltip.style.visibility = 'visible'
    this.controller.tooltip.style.opacity = '1'
    
    // For RegL mode, use proper positioning instead of fixed debug position
    if (this.controller.rendererType === 'regl') {
      console.log('🎯 [Tooltip] Applying RegL positioning and styling')
      
      // Use the calculated position for RegL
      this.controller.tooltip.style.left = `${tooltipLeft}px`
      this.controller.tooltip.style.top = `${tooltipTop}px`
      
      // Different styling for fixed vs dynamic tooltips
      if (this.controller.isTooltipFixed) {
        console.log('🎯 [Tooltip] Applying fixed tooltip styling (green)')
        this.controller.tooltip.style.backgroundColor = 'rgba(0, 100, 0, 0.9)' // Green for fixed
        this.controller.tooltip.style.border = '2px solid #00ff00'
        this.controller.tooltip.style.boxShadow = '0 0 10px rgba(0, 255, 0, 0.5)'
      } else {
        console.log('🎯 [Tooltip] Applying dynamic tooltip styling (black)')
        this.controller.tooltip.style.backgroundColor = 'rgba(0, 0, 0, 0.8)' // Black for dynamic
        this.controller.tooltip.style.border = '1px solid #ccc'
        this.controller.tooltip.style.boxShadow = '0 2px 4px rgba(0, 0, 0, 0.3)'
      }
      
      this.controller.tooltip.style.width = 'auto'
      this.controller.tooltip.style.height = 'auto'
      
      console.log('🎯 [Tooltip] Final RegL tooltip position:', {
        left: this.controller.tooltip.style.left,
        top: this.controller.tooltip.style.top,
        display: this.controller.tooltip.style.display,
        backgroundColor: this.controller.tooltip.style.backgroundColor
      })
      
      // TEMPORARY: Force tooltip to a visible position for debugging
      this.controller.tooltip.style.left = '100px'
      this.controller.tooltip.style.top = '100px'
      this.controller.tooltip.style.backgroundColor = 'red'
      this.controller.tooltip.style.border = '3px solid yellow'
      this.controller.tooltip.style.width = '300px'
      this.controller.tooltip.style.height = '100px'
      console.log('🎯 [Tooltip] FORCED tooltip to visible position for debugging')
    } else {
      // Keep debug positioning for PixiJS mode
      this.controller.tooltip.style.left = '50px'
      this.controller.tooltip.style.top = '50px'
      this.controller.tooltip.style.backgroundColor = 'red'
      this.controller.tooltip.style.border = '3px solid yellow'
      this.controller.tooltip.style.width = '300px'
      this.controller.tooltip.style.height = '100px'
    }
    
    // Tooltip positioned
  }

  hideTooltip() {
    if (this.controller.tooltip) {
      this.controller.tooltip.style.display = 'none'
    }
  }

  // Toggle methods for plot elements
  toggleAxes() {
    const checkbox = document.getElementById('show-axes-checkbox')
    if (!checkbox) {
      console.log('Axes checkbox not found!')
      return
    }
    
    if (this.controller.rendererType === 'regl') {
      // ReGL mode: redraw overlay (renderGrid clears and redraws everything)
      console.log(`🔄 [ReGL] Toggling axes: ${checkbox.checked}`)
      this.controller.rendererManager.renderGrid()
    } else if (this.controller.axesContainer) {
      // PixiJS mode: axes are in a PixiJS container
      this.controller.axesContainer.visible = checkbox.checked
      this.controller.rendererManager.renderAxes()
    }
  }

  toggleGrid() {
    const checkbox = document.getElementById('show-grid-checkbox')
    if (!checkbox) {
      console.log('Grid checkbox not found!')
      return
    }
    
    if (this.controller.rendererType === 'regl') {
      // ReGL mode: grid is drawn on Canvas2D overlay
      console.log(`🔄 [ReGL] Toggling grid: ${checkbox.checked}`)
      this.controller.rendererManager.renderGrid()
    } else if (this.controller.gridContainer) {
      // PixiJS mode: grid is in a PixiJS container
      this.controller.gridContainer.visible = checkbox.checked
      this.controller.rendererManager.renderGrid()
    }
  }

  toggleCategories() {
    const checkbox = document.getElementById('show-categories-checkbox')
    if (!checkbox) {
      console.log('🏷️ toggleCategories: checkbox not found!')
      return
    }
    
    console.log(`🏷️ Toggling categories: ${checkbox.checked}`)
    console.log(`🏷️ Current metadata:`, this.controller.currentMetadataVector ? `${this.controller.currentMetadataVector.name} (${this.controller.currentMetadataVector.data_type})` : 'none')
    
    // Toggle category labels on the plot
    if (this.controller.rendererType === 'regl') {
      // ReGL mode: Labels are drawn on Canvas2D overlay
      console.log('🏷️ [ReGL] Toggling category labels on Canvas2D overlay')
      if (checkbox.checked) {
        console.log('🏷️ [ReGL] Re-rendering category labels...')
        // Redraw overlay with labels
        this.controller.rendererManager.renderGrid()
        this.controller.rendererManager.renderAxes()
        this.controller.rendererManager.renderCategoryLabels()
      } else {
        console.log('🏷️ [ReGL] Clearing category labels')
        // Redraw overlay without labels (renderCategoryLabels will check checkbox and skip)
        this.controller.rendererManager.renderGrid()
        this.controller.rendererManager.renderAxes()
        this.controller.rendererManager.renderCategoryLabels()
      }
    } else if (this.controller.categoryLabelsContainer) {
      // PixiJS mode: Labels are in a PixiJS container
      this.controller.categoryLabelsContainer.visible = checkbox.checked
      console.log(`🏷️ Category labels container visible: ${this.controller.categoryLabelsContainer.visible}`)
      
      // If turning on, make sure labels are rendered
      if (checkbox.checked) {
        console.log('🏷️ Re-rendering category labels...')
        this.controller.rendererManager.renderCategoryLabels()
      } else {
        console.log('🏷️ Hiding category labels')
      }
    } else {
      console.log('🏷️ No categoryLabelsContainer available')
    }
    
    // Find the categories container in the right panel
    const categoriesContainer = document.querySelector('.metadata-categories')
    if (categoriesContainer) {
      categoriesContainer.style.display = checkbox.checked ? 'block' : 'none'
      console.log(`🏷️ Metadata categories panel: ${checkbox.checked ? 'shown' : 'hidden'}`)
    }
    
    console.log('🏷️ Categories toggle complete!')
  }

  changeCategoryOrder(event) {
    const newOrder = event.target.value
    console.log(`📊 [CATEGORY ORDER] Changing from '${this.controller.categoryOrder}' to '${newOrder}'`)
    
    if (newOrder === this.controller.categoryOrder) {
      console.log('📊 [CATEGORY ORDER] Order unchanged, skipping update')
      return
    }
    
    this.controller.categoryOrder = newOrder
    
    // Reset the flag so reordering will happen on next render
    this.controller._lastCategoryOrderApplied = null
    
    // Update ALL unfolded categorical metadata panels in the left sidebar
    this.controller.updateAllCategoryDisplayOrders()
    
    // If we have discrete metadata currently displayed, re-render the plot
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.data_type === 'DISCRETE') {
      console.log(`📊 [CATEGORY ORDER] ✅ Discrete metadata active - applying new order`)
      
      // IMPORTANT: Don't recreate color map - keep existing color assignments!
      // The color map should remain stable regardless of sort order
      // We only need to update the z-order (PixiJS) or buffer order (ReGL)
      
      if (this.controller.rendererType === 'regl') {
        // ReGL: Reorder points in buffer for painter's algorithm
        // This function will also redraw the overlay (grid, axes, labels)
        this.controller.reorderPointsForCategoryDisplay()
      } else {
        // PixiJS: Update sprite z-index
        this.controller.renderPointsWithCurrentColoring()
      
        // Re-render category labels
        this.controller.rendererManager.renderCategoryLabels()
      }
      
      console.log('📊 [CATEGORY ORDER] Complete!')
    } else {
      console.log('📊 [CATEGORY ORDER] No discrete metadata active, order preference saved for next use')
    }
  }

  changeNumericalOrder(event) {
    const newOrder = event.target.value
    console.log(`📊 Changing numerical order from '${this.controller.numericalOrder}' to '${newOrder}'`)
    
    if (newOrder === this.controller.numericalOrder) {
      console.log('📊 Numerical order unchanged, skipping update')
      return
    }
    
    this.controller.numericalOrder = newOrder
    
    // Reset the flag so reordering will happen on next render
    this.controller._lastNumericalOrderApplied = null
    
    // If we have continuous metadata currently displayed, re-render the plot
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.data_type === 'NUMERIC') {
      console.log(`📊 ✅ Continuous metadata active - applying new order`)
      
      // Re-render the plot with new order
      this.controller.renderPointsWithCurrentColoring()
      
      console.log('📊 Numerical order change complete!')
    } else {
      console.log('📊 No continuous metadata active, order preference saved for next use')
    }
  }

  // Update point size from UI slider
  updatePointSize() {
    //console.log('Stimulus updatePointSize method called!')
    const slider = document.getElementById('point-size-slider')
    const valueDisplay = document.getElementById('point-size-value')
    if (!slider || !valueDisplay) {
      console.log('Slider or valueDisplay not found')
      return
    }
    
    const newSize = parseFloat(slider.value)
    valueDisplay.textContent = newSize.toFixed(1)
    
    // Store the new point size for future renders
    //console.log(`Stimulus updatePointSize: ${this.controller.currentPointSize} -> ${newSize}`)
    this.controller.currentPointSize = newSize
    
    //console.log(`Stimulus updating point size to: ${newSize}`)
    
    // Update all existing points
    this.controller.rendererManager.updateAllPointSizes(newSize)
  }

  // Update embeddings dropdown based on selected loom file
  updateEmbeddings() {
    // Check if loom file select target exists (it's now manually found, not a Stimulus target)
    if (!this.controller.loomFileSelectTarget || !this.controller.hasEmbeddingSelectTarget || !this.controller.hasEmbeddingsByLoomValue) {
      console.log('Required targets or values not available')
      return
    }
    
    const selectedLoomFile = this.controller.loomFileSelectTarget.value
    const embeddings = this.controller.embeddingsByLoomValue[selectedLoomFile] || []
    
    // Clear current options
    this.controller.embeddingSelectTarget.innerHTML = '<option selected>Select embedding...</option>'
    
    // Add new options
    embeddings.forEach(embedding => {
      const option = document.createElement('option')
      option.value = embedding.id
      option.textContent = embedding.display_name
      this.controller.embeddingSelectTarget.appendChild(option)
    })
  }

  // Update metadata dropdown
  updateMetadata() {
    const perfStart = performance.now()
    console.log('⏱️ [PERF] ====== EMBEDDING SWITCH STARTED ======')
    
    if (!this.controller.hasMetadataSelectTarget) {
      console.log('Metadata select target not available')
      return
    }
    
    const selectedMetadataId = this.controller.metadataSelectTarget.value
    console.log(`⏱️ [PERF] Selected embedding ID: ${selectedMetadataId}`)
    
    if (selectedMetadataId) {
      // Show loading spinner
      this.showMetadataDropdownSpinner()
      
      // Load metadata and hide spinner when done
      this.controller.loadMetadataCoordinates(selectedMetadataId)
        .catch(error => {
          console.error('❌ Error loading metadata coordinates:', error)
        })
        .finally(() => {
          this.hideMetadataDropdownSpinner()
          const perfEnd = performance.now()
          console.log(`⏱️ [PERF] ====== EMBEDDING SWITCH COMPLETED in ${(perfEnd - perfStart).toFixed(2)}ms ======`)
        })
    }
  }

}
