// Filter Manager Module for Visualization
// Handles checkbox filtering and cell selection

export class FilterManager {
  constructor(controller) {
    this.controller = controller
    this.selectedCategories = {}
    this.filterCache = new Map()
    this.lastFilterState = null
    this.incrementalFilteredIndices = null
  }

  // Initialize all checkboxes
  initializeAllCheckboxes() {
    // Only initialize checkboxes for the current metadata
    if (this.controller.currentMetadataId) {
      this.initializeCheckboxesForMetadata(this.controller.currentMetadataId)
    }
  }

  // Initialize checkboxes for a specific metadata
  initializeCheckboxesForMetadata(metadataId) {
    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return

    // Initialize global checkbox
    const globalCheckbox = metadataContainer.querySelector('.metadata-global-checkbox')
    if (globalCheckbox) {
      globalCheckbox.checked = true
      globalCheckbox.addEventListener('change', (event) => {
        this.toggleMetadataSelection(event)
      })
    }

    // Initialize category checkboxes
    const categoryCheckboxes = metadataContainer.querySelectorAll('.category-checkbox')
    categoryCheckboxes.forEach(checkbox => {
      checkbox.checked = true
      checkbox.addEventListener('change', (event) => {
        this.toggleCategorySelection(event)
      })
    })

    // Initialize selected categories
    this.selectedCategories[metadataId] = new Set()
    const categories = this.controller.getCategoriesForMetadata(metadataId)
    categories.forEach(category => {
      this.selectedCategories[metadataId].add(category)
    })
  }

  // Show checkboxes for a specific metadata
  showCheckboxesForMetadata(metadataId) {
    // Hide all checkboxes first
    this.hideAllCheckboxes()

    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return

    // Show global checkbox
    const globalCheckbox = metadataContainer.querySelector('.metadata-global-checkbox')
    if (globalCheckbox) {
      globalCheckbox.style.display = 'block'
    }

    // Show category checkboxes
    const categoryCheckboxes = metadataContainer.querySelectorAll('.category-checkbox')
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.display = 'block'
    })
  }

  // Hide all checkboxes
  hideAllCheckboxes() {
    const allCheckboxes = document.querySelectorAll('.metadata-global-checkbox, .category-checkbox')
    allCheckboxes.forEach(checkbox => {
      checkbox.style.display = 'none'
    })
  }

  // Toggle metadata selection
  toggleMetadataSelection(event) {
    const metadataId = event.target.dataset.metadataId
    const isSelected = event.target.checked

    if (isSelected) {
      this.selectAllCategoriesForMetadata(metadataId)
    } else {
      this.deselectAllCategoriesForMetadata(metadataId)
    }

    this.updateMetadataCheckboxState(metadataId)
    this.updateCellFiltering()
  }

  // Toggle category selection
  toggleCategorySelection(event) {
    const metadataId = event.target.dataset.metadataId
    const category = event.target.dataset.category
    const isSelected = event.target.checked

    if (isSelected) {
      this.selectCategory(metadataId, category)
    } else {
      this.deselectCategory(metadataId, category)
    }

    this.updateMetadataCheckboxState(metadataId)
    this.updateCellFiltering()
  }

  // Select all categories for a metadata
  selectAllCategoriesForMetadata(metadataId) {
    const categories = this.controller.getCategoriesForMetadata(metadataId)
    categories.forEach(category => {
      this.selectCategory(metadataId, category)
    })
  }

  // Deselect all categories for a metadata
  deselectAllCategoriesForMetadata(metadataId) {
    const categories = this.controller.getCategoriesForMetadata(metadataId)
    categories.forEach(category => {
      this.deselectCategory(metadataId, category)
    })
  }

  // Select a category
  selectCategory(metadataId, category) {
    if (!this.selectedCategories[metadataId]) {
      this.selectedCategories[metadataId] = new Set()
    }
    this.selectedCategories[metadataId].add(category)
  }

  // Deselect a category
  deselectCategory(metadataId, category) {
    if (this.selectedCategories[metadataId]) {
      this.selectedCategories[metadataId].delete(category)
    }
  }

  // Update metadata checkbox state
  updateMetadataCheckboxState(metadataId) {
    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return

    const globalCheckbox = metadataContainer.querySelector('.metadata-global-checkbox')
    const categoryCheckboxes = metadataContainer.querySelectorAll('.category-checkbox')
    
    if (!globalCheckbox || categoryCheckboxes.length === 0) return

    const selectedCount = this.selectedCategories[metadataId] ? this.selectedCategories[metadataId].size : 0
    const totalCount = categoryCheckboxes.length

    if (selectedCount === 0) {
      globalCheckbox.checked = false
      globalCheckbox.indeterminate = false
    } else if (selectedCount === totalCount) {
      globalCheckbox.checked = true
      globalCheckbox.indeterminate = false
    } else {
      globalCheckbox.checked = false
      globalCheckbox.indeterminate = true
    }
  }

  // Update cell filtering
  updateCellFiltering() {
    const filteredIndices = this.getIncrementalFilteredIndices()
    this.updatePointVisibility(filteredIndices)
    this.updatePointCountDisplay(filteredIndices)
    this.updateSelectionBasedOnFiltering(filteredIndices)
    this.updateAddAllVisibleButtonState()
  }

  // Update point visibility
  updatePointVisibility(filteredIndices) {
    if (!this.controller.scatterContainer || !this.controller.scatterContainer.children) {
      return
    }

    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    let visibleCount = 0
    let hiddenCount = 0

    this.controller.scatterContainer.children.forEach((point) => {
      if (point.isPoint) {
        const shouldBeVisible = !filteredSet || filteredSet.has(point.cellId)
        
        if (shouldBeVisible) {
          point.visible = true
          point.alpha = point.originalAlpha || 1.0
          visibleCount++
        } else {
          point.visible = false
          hiddenCount++
        }
      }
    })

    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = visibleCount.toLocaleString()
    }
  }

  // Update point count display
  updatePointCountDisplay(filteredIndices) {
    const pointCountElement = document.getElementById('point-count')
    if (!pointCountElement) return

    if (filteredIndices) {
      pointCountElement.textContent = filteredIndices.length.toLocaleString()
    } else {
      pointCountElement.textContent = this.controller.currentCoordinates ? this.controller.currentCoordinates.length.toLocaleString() : '0'
    }
  }

  // Update selection based on filtering
  updateSelectionBasedOnFiltering(filteredIndices) {
    if (!this.controller.selectedCells || this.controller.selectedCells.size === 0) {
      return
    }

    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const newSelectedCells = new Set()

    this.controller.selectedCells.forEach(cellId => {
      if (!filteredSet || filteredSet.has(cellId)) {
        newSelectedCells.add(cellId)
      }
    })

    this.controller.selectedCells = newSelectedCells
    this.controller.updateSelectedCellsCount()
  }

  // Update add all visible button state
  updateAddAllVisibleButtonState() {
    const button = document.getElementById('add-all-visible-btn')
    if (!button) return

    const filteredIndices = this.getIncrementalFilteredIndices()
    const visibleCount = filteredIndices ? filteredIndices.length : (this.controller.currentCoordinates ? this.controller.currentCoordinates.length : 0)
    const selectedCount = this.controller.selectedCells ? this.controller.selectedCells.size : 0

    // Disable if all visible cells are already selected
    button.disabled = selectedCount >= visibleCount
  }

  // Get incremental filtered indices
  getIncrementalFilteredIndices() {
    if (!this.selectedCategories || Object.keys(this.selectedCategories).length === 0) {
      return null
    }

    // Create current filter state
    const currentFilterState = this.createFilterCacheKey()
    
    // Check if we can use cached result
    if (this.lastFilterState === currentFilterState && this.incrementalFilteredIndices !== null) {
      return this.incrementalFilteredIndices
    }

    // Try incremental update first
    const metadataWithSelections = Object.keys(this.selectedCategories).filter(metadataId => 
      this.selectedCategories[metadataId] && this.selectedCategories[metadataId].size > 0
    )

    if (metadataWithSelections.length === 0) {
      this.incrementalFilteredIndices = null
      this.lastFilterState = currentFilterState
      return null
    }

    // Try incremental update based on what changed
    const incrementalResult = this.tryIncrementalUpdate(metadataWithSelections)
    if (incrementalResult !== null) {
      this.incrementalFilteredIndices = incrementalResult
      this.lastFilterState = currentFilterState
      return incrementalResult
    }

    // Fall back to full calculation
    const result = this.getFilteredCellIndices()
    this.incrementalFilteredIndices = result
    this.lastFilterState = currentFilterState
    return result
  }

  // Try to do an incremental update
  tryIncrementalUpdate(metadataWithSelections) {
    // For now, let's implement a simple case: single metadata changes
    if (metadataWithSelections.length === 1) {
      const metadataId = metadataWithSelections[0]
      const selectedCategories = this.selectedCategories[metadataId]
      
      if (selectedCategories && selectedCategories.size > 0) {
        return this.getCellsForMetadataCategories(metadataId, selectedCategories)
      }
    }
    
    return null
  }

  // Get filtered cell indices
  getFilteredCellIndices() {
    if (!this.selectedCategories || Object.keys(this.selectedCategories).length === 0) {
      return null
    }

    // Create cache key from current selections
    const cacheKey = this.createFilterCacheKey()
    if (this.filterCache.has(cacheKey)) {
      return this.filterCache.get(cacheKey)
    }

    // Get metadata with selections
    const metadataWithSelections = Object.keys(this.selectedCategories).filter(metadataId => 
      this.selectedCategories[metadataId] && this.selectedCategories[metadataId].size > 0
    )

    if (metadataWithSelections.length === 0) {
      this.filterCache.set(cacheKey, null)
      return null
    }

    // Calculate intersection of all selected categories
    let result = null
    for (const metadataId of metadataWithSelections) {
      const selectedCategories = this.selectedCategories[metadataId]
      const cellsForMetadata = this.getCellsForMetadataCategories(metadataId, selectedCategories)
      
      if (result === null) {
        result = cellsForMetadata
      } else {
        // Intersection
        result = result.filter(cellId => cellsForMetadata.includes(cellId))
      }
    }

    // Cache the result
    this.filterCache.set(cacheKey, result)
    return result
  }

  // Get cells for metadata categories
  getCellsForMetadataCategories(metadataId, selectedCategories) {
    const metadataVector = this.controller.getMetadataVectorById(metadataId)
    if (!metadataVector || !metadataVector.values) {
      return []
    }

    const cells = []
    metadataVector.values.forEach((value, index) => {
      if (selectedCategories.has(value)) {
        cells.push(index)
      }
    })

    return cells
  }

  // Create filter cache key
  createFilterCacheKey() {
    const keys = Object.keys(this.selectedCategories).sort()
    return keys.map(metadataId => {
      const categories = Array.from(this.selectedCategories[metadataId] || []).sort()
      return `${metadataId}:${categories.join(',')}`
    }).join('|')
  }

  // Clear incremental state
  clearIncrementalState() {
    this.incrementalFilteredIndices = null
    this.lastFilterState = null
  }

  // Clear all checkbox selections
  clearAllCheckboxSelections() {
    // Clear selected categories
    this.selectedCategories = {}
    
    // Clear cache
    this.filterCache.clear()
    this.clearIncrementalState()
    
    // Hide all checkboxes
    this.hideAllCheckboxes()
    
    // Update filtering
    this.updateCellFiltering()
  }

  // Add all visible cells to selection
  addAllVisibleCells() {
    const filteredIndices = this.getIncrementalFilteredIndices()
    if (!filteredIndices || filteredIndices.length === 0) return

    if (!this.controller.selectedCells) {
      this.controller.selectedCells = new Set()
    }

    filteredIndices.forEach(cellId => {
      this.controller.selectedCells.add(cellId)
    })

    this.controller.updateSelectedPointColors()
    this.controller.updateSelectedCellsCount()
    this.updateAddAllVisibleButtonState()
  }

  // Cleanup method
  destroy() {
    this.selectedCategories = {}
    this.filterCache.clear()
    this.incrementalFilteredIndices = null
    this.lastFilterState = null
  }
}
