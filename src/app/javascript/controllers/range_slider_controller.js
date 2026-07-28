// Range Slider Controller for inline range sliders
// This controller handles the range slider functionality for metadata filtering

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static LIVE_COUNT_UPDATE_MAX_CELLS = 10000

  static targets = ["track", "activeTrack", "minHandle", "maxHandle", "minInput", "maxInput", "selectedCount", "totalCount", "canvas", "adaptColorRangeButton", "histogramIgnoreZeros", "histogramScale"]
  static values = { 
    metadataId: String,
    min: Number,
    max: Number,
    currentMin: Number,
    currentMax: Number
  }

  connect() {
    // console.log('🎚️ Range slider controller connected for metadata:', this.metadataIdValue)
    // console.log('🎚️ Initial values:', {
      // min: this.minValue,
      // max: this.maxValue,
      // currentMin: this.currentMinValue,
      // currentMax: this.currentMaxValue
    // })
    
    // Initialize drag state
    this.isDragging = false
    this.dragHandle = null
    this.dragStartX = 0
    this.dragStartValue = 0
    
    // Performance optimization: throttling for plot updates
    this.plotUpdateScheduled = false
    this.lastPlotUpdate = 0
    this.plotUpdateThrottle = 16 // ~60fps (16ms)
    this.dragUpdateScheduled = false
    this.pendingDensityPlotTimeout = null
    
    // Color range adaptation button state
    this.adaptColorRangeEnabled = false
    
    // Get the main visualization controller and its modules
    // CRITICAL: Always get the controller directly from the DOM element
    // This ensures we get the same instance that Stimulus is managing for that element
    // Don't rely on window.visualizationController which might be stale
    let visualizationController = null
    const visualizationElement = document.querySelector('[data-controller="visualization"]')
    if (visualizationElement) {
      visualizationController = this.application.getControllerForElementAndIdentifier(visualizationElement, 'visualization')
      if (visualizationController) {
        // console.log('🎚️ [RANGE SLIDER] Got visualization controller from DOM element, instance ID:', visualizationController.instanceId)
        // Update window reference to keep it in sync
        window.visualizationController = visualizationController
      } else {
        console.warn('🎚️ [RANGE SLIDER] Could not get controller from DOM element, falling back to window.visualizationController')
        visualizationController = window.visualizationController
      }
    } else {
      console.warn('🎚️ [RANGE SLIDER] Visualization element not found, falling back to window.visualizationController')
      visualizationController = window.visualizationController
    }
    
    this.visualizationController = visualizationController
    this.dataManager = this.visualizationController?.dataManager
    this.rendererManager = this.visualizationController?.rendererManager
    if (this.visualizationController) {
      if (!this.visualizationController.adaptColorRangeByMetadataId) {
        this.visualizationController.adaptColorRangeByMetadataId = {}
      }
      this.adaptColorRangeEnabled = this.visualizationController.adaptColorRangeByMetadataId[this.metadataIdValue] === true
    }
    // console.log('🎚️ Range slider controller connected, visualization controller:', !!this.visualizationController)
    // console.log('🎚️ Range slider controller connected, controller instance ID:', this.visualizationController?.instanceId || 'none')
    // console.log('🎚️ Range slider controller connected, renderer instance ID:', this.visualizationController?.reglRenderer?.instanceId || 'none')
    // console.log('🎚️ Range slider controller connected, dataManager:', !!this.dataManager)
    // console.log('🎚️ Range slider controller connected, rendererManager:', !!this.rendererManager)
    
    // Initialize button appearance
    this.updateButtonAppearance()
    this.initializeHistogramControls()
    
    // Check if data is already available (e.g., for genes that loaded data before slider connected)
    if (this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue]) {
      const sliderData = this.visualizationController.inlineRangeSliderData[this.metadataIdValue]
      if (sliderData.values && sliderData.min !== undefined && sliderData.max !== undefined) {
        // console.log('🎚️ Data already available, initializing slider immediately')
        this.minValue = sliderData.min
        this.maxValue = sliderData.max
        this.currentMinValue = sliderData.currentMin ?? sliderData.min
        this.currentMaxValue = sliderData.currentMax ?? sliderData.max
        this.initializeSlider()
        return
      }
    }
    
    // Don't initialize immediately - wait for values to be set by the main controller
    // console.log('🎚️ Range slider controller ready, waiting for initialization')
  }

  disconnect() {
    // Clean up event listeners
    this.stopDrag()
    if (this.pendingDensityPlotTimeout) {
      clearTimeout(this.pendingDensityPlotTimeout)
      this.pendingDensityPlotTimeout = null
    }
  }

  metadataIdValueChanged() {
    const id = this.metadataIdValue ? String(this.metadataIdValue).trim() : ''
    if (!id || !this.visualizationController?.inlineRangeSliderData?.[id]) return
    const sliderData = this.visualizationController.inlineRangeSliderData[id]
    if (!sliderData?.values || sliderData.values.length === 0) return
    this.minValue = sliderData.min
    this.maxValue = sliderData.max
    this.currentMinValue = sliderData.currentMin ?? sliderData.min
    this.currentMaxValue = sliderData.currentMax ?? sliderData.max
    this.initializeSlider()
  }

  isGeneSlider() {
    return this.metadataIdValue && String(this.metadataIdValue).startsWith('gene_')
  }

  getHistogramOptions() {
    if (!this.visualizationController) {
      return { scale: 'normal', ignoreZeros: true }
    }
    if (this.isGeneSlider()) {
      return {
        scale: this.visualizationController.histogramScale === 'log' ? 'log' : 'normal',
        ignoreZeros: this.visualizationController.histogramIgnoreZeros !== false
      }
    }
    const metadataOptions = this.visualizationController.getMetadataHistogramOptions(this.metadataIdValue)
    return {
      scale: metadataOptions.scale === 'log' ? 'log' : 'normal',
      ignoreZeros: metadataOptions.ignoreZeros !== false
    }
  }

  initializeHistogramControls() {
    if (!this.hasHistogramIgnoreZerosTarget || !this.hasHistogramScaleTarget) return
    const options = this.getHistogramOptions()
    this.histogramIgnoreZerosTarget.checked = options.ignoreZeros !== false
    this.histogramScaleTarget.value = options.scale === 'log' ? 'log' : 'normal'
  }

  histogramIgnoreZerosChanged(event) {
    if (!this.visualizationController || this.isGeneSlider()) return
    this.visualizationController.setMetadataHistogramOptions(this.metadataIdValue, {
      ignoreZeros: !!event.target.checked
    })
    this.drawDensityPlot()
  }

  histogramScaleChanged(event) {
    if (!this.visualizationController || this.isGeneSlider()) return
    this.visualizationController.setMetadataHistogramOptions(this.metadataIdValue, {
      scale: event.target.value === 'log' ? 'log' : 'normal'
    })
    this.drawDensityPlot()
  }

  // Helper methods for safely calculating min/max on large arrays
  // Using spread operator with Math.min/max fails with arrays > ~65k-100k elements
  safeMin(arr) {
    if (!arr || arr.length === 0) return undefined
    let min = arr[0]
    for (let i = 1; i < arr.length; i++) {
      if (arr[i] < min) min = arr[i]
    }
    return min
  }
  
  safeMax(arr) {
    if (!arr || arr.length === 0) return undefined
    let max = arr[0]
    for (let i = 1; i < arr.length; i++) {
      if (arr[i] > max) max = arr[i]
    }
    return max
  }

  // Initialize the slider with data
  initializeSlider() {
    // console.log('🎚️ Initializing range slider with values:', {
      // min: this.minValue,
      // max: this.maxValue,
      // currentMin: this.currentMinValue,
      // currentMax: this.currentMaxValue
    // })
    
    if (this.minValue === undefined || this.maxValue === undefined) {
      console.error('❌ Range slider values not properly set:', {
        min: this.minValue,
        max: this.maxValue
      })
      return
    }
    
    // CRITICAL: Only update the visualization controller reference if:
    // 1. We don't have one, OR
    // 2. The one we have doesn't have the data we need
    // Don't overwrite if it was explicitly set by the caller (e.g., initializeInlineRangeSlider)
    if (!this.visualizationController) {
      // Get from DOM if we don't have a reference
      const visualizationElement = document.querySelector('[data-controller="visualization"]')
      if (visualizationElement) {
        const domController = this.application.getControllerForElementAndIdentifier(visualizationElement, 'visualization')
        if (domController) {
          // console.log('🎚️ [RANGE SLIDER] Got visualization controller from DOM element, instance ID:', domController.instanceId)
          this.visualizationController = domController
          this.dataManager = domController.dataManager
          this.rendererManager = domController.rendererManager
          window.visualizationController = domController
        }
      }
    } else {
      // We have a reference - verify it has the data we need
      const hasData = this.visualizationController.inlineRangeSliderData?.[this.metadataIdValue]
      const hasInlineRangeSliderData = !!this.visualizationController.inlineRangeSliderData
      const inlineRangeSliderDataKeys = this.visualizationController.inlineRangeSliderData ? Object.keys(this.visualizationController.inlineRangeSliderData) : []
      
      // console.log('🎚️ [RANGE SLIDER] Checking current controller for data:', {
        // controllerId: this.visualizationController.instanceId,
        // hasInlineRangeSliderData,
        // inlineRangeSliderDataKeys,
        // hasDataForThisMetadata: hasData,
        // metadataId: this.metadataIdValue
      // })
      
      if (!hasData) {
        // Try to get a different instance that might have the data
        const visualizationElement = document.querySelector('[data-controller="visualization"]')
        if (visualizationElement) {
          const domController = this.application.getControllerForElementAndIdentifier(visualizationElement, 'visualization')
          if (domController && domController !== this.visualizationController) {
            // Check if the DOM controller has the data
            const domHasData = domController.inlineRangeSliderData?.[this.metadataIdValue]
            const domHasInlineRangeSliderData = !!domController.inlineRangeSliderData
            const domInlineRangeSliderDataKeys = domController.inlineRangeSliderData ? Object.keys(domController.inlineRangeSliderData) : []
            
            // console.log('🎚️ [RANGE SLIDER] Checking DOM controller for data:', {
              // controllerId: domController.instanceId,
              // hasInlineRangeSliderData: domHasInlineRangeSliderData,
              // inlineRangeSliderDataKeys: domInlineRangeSliderDataKeys,
              // hasDataForThisMetadata: domHasData,
              // metadataId: this.metadataIdValue
            // })
            
            if (domHasData) {
              // console.log('🎚️ [RANGE SLIDER] Current controller missing data, switching to DOM controller with data')
              // console.log('🎚️ [RANGE SLIDER] Old controller ID:', this.visualizationController?.instanceId || 'none')
              // console.log('🎚️ [RANGE SLIDER] New controller ID:', domController.instanceId)
              this.visualizationController = domController
              this.dataManager = domController.dataManager
              this.rendererManager = domController.rendererManager
              window.visualizationController = domController
            } else {
              // console.log('🎚️ [RANGE SLIDER] Neither controller has data, keeping current reference (was explicitly set)')
            }
          }
        }
      } else {
        // console.log('🎚️ [RANGE SLIDER] Current controller has data, keeping reference')
      }
    }
    
    // Check if visualization controller and data are available
    // console.log('🎚️ Checking data availability:', {
      // hasVisualizationController: !!this.visualizationController,
      // controllerInstanceId: this.visualizationController?.instanceId || 'none',
      // rendererInstanceId: this.visualizationController?.reglRenderer?.instanceId || 'none',
      // hasInlineRangeSliderData: !!this.visualizationController?.inlineRangeSliderData,
      // inlineRangeSliderDataKeys: this.visualizationController?.inlineRangeSliderData ? Object.keys(this.visualizationController.inlineRangeSliderData) : [],
      // hasMetadataData: !!this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue],
      // metadataId: this.metadataIdValue
    // })
    
    this.updateSliderUI()
    this.updateSelectedCellsCount()
    this.drawDensityPlot()
    // Update checkbox color and filter state icon to restore state after DOM recreation
    this.updateCheckboxColor()
    
    // Update button appearance to show/hide based on coloring state
    this.updateButtonAppearance()
  }

  // Start dragging a handle
  startDrag(event) {
    // Get the handle type from the event target's data attribute
    const handleType = event.target.dataset.rangeSliderHandleParam
    // console.log('🎚️ Starting drag for handle:', handleType)
    
    event.preventDefault()
    event.stopPropagation()
    
    this.isDragging = true
    this.dragHandle = handleType
    
    // Get initial mouse position and current value
    this.dragStartX = event.type === 'mousedown' ? event.clientX : event.touches[0].clientX
    this.dragStartValue = handleType === 'min' ? this.currentMinValue : this.currentMaxValue
    
    // Add event listeners
    document.addEventListener('mousemove', this.handleDrag.bind(this))
    document.addEventListener('mouseup', this.stopDrag.bind(this))
    document.addEventListener('touchmove', this.handleDrag.bind(this))
    document.addEventListener('touchend', this.stopDrag.bind(this))
  }

  // Handle drag movement
  handleDrag(event) {
    if (!this.isDragging) return
    
    const dragStartTime = performance.now()
    event.preventDefault()
    
    const currentX = event.type === 'mousemove' ? event.clientX : event.touches[0].clientX
    const deltaX = currentX - this.dragStartX
    
    // Get track dimensions
    const trackRect = this.trackTarget.getBoundingClientRect()
    const trackWidth = trackRect.width
    
    // Calculate new value based on drag distance
    const range = this.maxValue - this.minValue
    const deltaPercent = deltaX / trackWidth
    const deltaValue = deltaPercent * range
    
    let newValue = this.dragStartValue + deltaValue
    
    // Clamp to valid range
    newValue = Math.max(this.minValue, Math.min(this.maxValue, newValue))
    
    // Update the appropriate value
    if (this.dragHandle === 'min') {
      newValue = Math.min(newValue, this.currentMaxValue)
      this.currentMinValue = newValue
    } else {
      newValue = Math.max(newValue, this.currentMinValue)
      this.currentMaxValue = newValue
    }
    
    // Update UI immediately for responsive feel
    const uiStartTime = performance.now()
    this.updateSliderUI()
    if (this.shouldUpdateCountDuringDrag()) {
      this.updateSelectedCellsCount()
    }
    const uiTime = performance.now() - uiStartTime
    // console.log(`🚀 [PERF] UI update took ${uiTime.toFixed(2)}ms`)
    
    // Throttle expensive operations during dragging
    if (!this.dragUpdateScheduled) {
      this.dragUpdateScheduled = true
      requestAnimationFrame(() => {
        this.dragUpdateScheduled = false
        // console.log('🚀 [PERF] Scheduled expensive operations for metadata:', this.metadataIdValue)
        this.updateMainPlot()
        this.drawDensityPlot()
      })
    } else {
      // console.log('🚀 [PERF] Throttled expensive operations (already scheduled)')
    }
    
    const totalDragTime = performance.now() - dragStartTime
    // console.log(`🚀 [PERF] handleDrag completed in ${totalDragTime.toFixed(2)}ms for metadata:`, this.metadataIdValue)
  }

  // Stop dragging
  stopDrag() {
    if (!this.isDragging) return
    
    this.isDragging = false
    this.dragHandle = null
    
    // Remove event listeners
    document.removeEventListener('mousemove', this.handleDrag.bind(this))
    document.removeEventListener('mouseup', this.stopDrag.bind(this))
    document.removeEventListener('touchmove', this.handleDrag.bind(this))
    document.removeEventListener('touchend', this.stopDrag.bind(this))
    
    // Ensure final update is performed when dragging stops
    this.updateSelectedCellsCount()
    this.updateMainPlot()
    this.drawDensityPlot()
    
    // console.log('🎚️ Drag stopped')
  }

  shouldUpdateCountDuringDrag() {
    const sliderData = this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue]
    const totalCells = sliderData?.values?.length || 0
    return totalCells <= this.constructor.LIVE_COUNT_UPDATE_MAX_CELLS
  }

  // Update the slider UI elements
  updateSliderUI() {
    // console.log('🎚️ Updating slider UI with values:', {
      // min: this.minValue,
      // max: this.maxValue,
      // currentMin: this.currentMinValue,
      // currentMax: this.currentMaxValue
    // })
    
    const range = this.maxValue - this.minValue
    const minPercent = ((this.currentMinValue - this.minValue) / range) * 100
    const maxPercent = ((this.currentMaxValue - this.minValue) / range) * 100
    
    // console.log('🎚️ Calculated percentages:', { minPercent, maxPercent })
    
    // Update handle positions
    this.minHandleTarget.style.left = `${minPercent}%`
    this.maxHandleTarget.style.left = `${maxPercent}%`
    
    // Update active track
    this.activeTrackTarget.style.left = `${minPercent}%`
    this.activeTrackTarget.style.width = `${maxPercent - minPercent}%`
    
    // Update input fields if they exist
    if (this.hasMinInputTarget) {
      this.minInputTarget.value = this.currentMinValue.toFixed(3)
    }
    if (this.hasMaxInputTarget) {
      this.maxInputTarget.value = this.currentMaxValue.toFixed(3)
    }
    
    // Update checkbox color based on whether it's a subrange
    this.updateCheckboxColor()
  }
  
  setFilterControlsDisabled(isDisabled) {
    const rangeSection = this.element.closest('.gene-range-section') || this.element.closest('.metadata-range-section')
    if (rangeSection) {
      rangeSection.style.opacity = isDisabled ? '0.5' : '1'
    }
    
    if (this.hasMinInputTarget) {
      this.minInputTarget.disabled = isDisabled
      this.minInputTarget.style.opacity = isDisabled ? '0.5' : '1'
      this.minInputTarget.style.cursor = isDisabled ? 'not-allowed' : 'default'
    }
    if (this.hasMaxInputTarget) {
      this.maxInputTarget.disabled = isDisabled
      this.maxInputTarget.style.opacity = isDisabled ? '0.5' : '1'
      this.maxInputTarget.style.cursor = isDisabled ? 'not-allowed' : 'default'
    }
    
    if (this.hasMinHandleTarget) {
      this.minHandleTarget.style.opacity = isDisabled ? '0.5' : '1'
      this.minHandleTarget.style.pointerEvents = isDisabled ? 'none' : 'auto'
      this.minHandleTarget.style.cursor = isDisabled ? 'not-allowed' : 'grab'
      this.minHandleTarget.style.backgroundColor = isDisabled ? '#d1d5db' : '#3b82f6'
    }
    if (this.hasMaxHandleTarget) {
      this.maxHandleTarget.style.opacity = isDisabled ? '0.5' : '1'
      this.maxHandleTarget.style.pointerEvents = isDisabled ? 'none' : 'auto'
      this.maxHandleTarget.style.cursor = isDisabled ? 'not-allowed' : 'grab'
      this.maxHandleTarget.style.backgroundColor = isDisabled ? '#d1d5db' : '#3b82f6'
    }
    
    if (this.hasActiveTrackTarget) {
      this.activeTrackTarget.style.backgroundColor = isDisabled ? '#d1d5db' : '#3b82f6'
    }
    
    if (this.hasAdaptColorRangeButtonTarget) {
      this.adaptColorRangeButtonTarget.disabled = isDisabled
      this.adaptColorRangeButtonTarget.style.opacity = isDisabled ? '0.5' : '1'
      this.adaptColorRangeButtonTarget.style.cursor = isDisabled ? 'not-allowed' : 'pointer'
    }
    
    if (typeof this.drawDensityPlot === 'function') {
      this.drawDensityPlot()
    }
  }
  
  // Update checkbox color: green if full range, orange if subrange
  // Also updates the filter state icon (for both metadata and genes)
  updateCheckboxColor() {
    // Check if current range is the full range (same tolerance as global filter / selectedRanges)
    const dataManager = this.visualizationController?.dataManager
    const isFullRange = dataManager?.isContinuousRangeFullCoverage
      ? dataManager.isContinuousRangeFullCoverage(
          this.currentMinValue,
          this.currentMaxValue,
          this.minValue,
          this.maxValue
        )
      : (
          Math.abs(this.currentMinValue - this.minValue) < Math.abs(this.maxValue - this.minValue) * 0.001 &&
          Math.abs(this.currentMaxValue - this.maxValue) < Math.abs(this.maxValue - this.minValue) * 0.001
        )
    
    // Update the filter state icon for metadata (new UI)
    const filterStateIcon = document.querySelector(`.metadata-filter-state-icon[data-metadata-id="${this.metadataIdValue}"]`)
    if (filterStateIcon) {
      const icon = filterStateIcon.querySelector('i')
      if (isFullRange) {
        // Full range - white background, gray icon
        filterStateIcon.style.backgroundColor = 'white'
        filterStateIcon.style.borderColor = '#d1d5db'
        if (icon) {
          icon.style.color = '#9ca3af'
        }
        filterStateIcon.title = 'No filter applied (full range)'
      } else {
        // Subrange - orange background, white icon
        filterStateIcon.style.backgroundColor = '#f59e0b'
        filterStateIcon.style.borderColor = '#f59e0b'
        if (icon) {
          icon.style.color = 'white'
        }
        filterStateIcon.title = `Subrange selected: ${this.currentMinValue.toFixed(3)} - ${this.currentMaxValue.toFixed(3)}`
      }
    }
    
    // Update the filter state icon for genes (if this is a gene slider)
    if (this.metadataIdValue && this.metadataIdValue.startsWith('gene_')) {
      const geneIdToken = this.metadataIdValue.slice(5)
      const stableGeneId = geneIdToken.split('_')[0]
      const geneFilterStateIcon = document.querySelector(`.gene-filter-state-icon[data-gene-id="${stableGeneId}"]`)
      if (geneFilterStateIcon) {
        geneFilterStateIcon.style.display = 'flex'
        const icon = geneFilterStateIcon.querySelector('i')
        if (isFullRange) {
          // Full range - white background, gray icon
          geneFilterStateIcon.style.backgroundColor = 'white'
          geneFilterStateIcon.style.borderColor = '#d1d5db'
          if (icon) {
            icon.style.color = '#9ca3af'
          }
          geneFilterStateIcon.title = 'No filter applied (full range)'
        } else {
          // Subrange - orange background, white icon
          geneFilterStateIcon.style.backgroundColor = '#f59e0b'
          geneFilterStateIcon.style.borderColor = '#f59e0b'
          if (icon) {
            icon.style.color = 'white'
          }
          geneFilterStateIcon.title = `Subrange selected: ${this.currentMinValue.toFixed(3)} - ${this.currentMaxValue.toFixed(3)}`
        }
      }
    }
    
    // Legacy: Update the old checkbox if it exists (for backward compatibility)
    const checkbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${this.metadataIdValue}"]`)
    if (!checkbox) return
    
    // Get the visualization controller to check if this metadata was explicitly unchecked
    const visualizationController = this.application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="visualization"]'),
      'visualization'
    )
    
    // If the metadata was explicitly unchecked by the user, don't change the color
    if (visualizationController?.uncheckedMetadata?.has(this.metadataIdValue)) {
      // console.log(`🔍 [CHECKBOX COLOR] Metadata ${this.metadataIdValue} is in uncheckedMetadata set - keeping it unchecked`)
      return
    }
    
    // Check if the checkbox is currently unchecked (gray)
    const currentBgColor = checkbox.style.backgroundColor
    const isCurrentlyUnchecked = currentBgColor === 'rgb(243, 244, 246)' || currentBgColor === '#f3f4f6'
    
    if (isCurrentlyUnchecked) {
      // console.log(`🔍 [CHECKBOX COLOR] Metadata ${this.metadataIdValue} is currently unchecked - not changing color`)
      return
    }
    
    if (isFullRange) {
      // Full range - green checkbox
      checkbox.style.backgroundColor = '#10b981' // green
      checkbox.title = 'Full range selected (click to disable filtering)'
    } else {
      // Subrange - orange checkbox
      checkbox.style.backgroundColor = '#f59e0b' // orange
      checkbox.title = `Subrange selected: ${this.currentMinValue.toFixed(3)} - ${this.currentMaxValue.toFixed(3)} (click to disable filtering)`
    }
  }

  // Update the selected cells count display
  updateSelectedCellsCount() {
    if (!this.hasSelectedCountTarget) return
    
    // Get the metadata values from the visualization controller
    const sliderData = this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue]
    if (!sliderData || !sliderData.values) {
      console.error('🎚️ [ERROR] No slider data available for count update for metadata:', this.metadataIdValue)
      console.error('🎚️ [ERROR] Available keys in inlineRangeSliderData:', Object.keys(this.visualizationController?.inlineRangeSliderData || {}))
      return
    }
    
    // Count cells within the selected range (considering ALL filters)
    let selectedByRangeCount = 0
    let selectedByAllFiltersCount = 0
    
    // Get currently visible cells (after ALL filters)
    const currentVisibleCells = this.visualizationController?.currentVisibleCells
    
    if (currentVisibleCells) {
      // Convert to Set for O(1) lookups instead of O(n) includes()
      const visibleSet = new Set(currentVisibleCells)
      
      // Count cells that pass both range and other filters
      for (let i = 0; i < sliderData.values.length; i++) {
        const value = sliderData.values[i]
        const inRange = value >= this.currentMinValue && value <= this.currentMaxValue
        
        if (inRange) {
          selectedByRangeCount++
          // O(1) lookup instead of O(n) includes()
          if (visibleSet.has(i)) {
            selectedByAllFiltersCount++
          }
        }
      }
    } else {
      // No other filters - just count cells in range
      selectedByRangeCount = sliderData.values.filter(value => 
        value >= this.currentMinValue && value <= this.currentMaxValue
      ).length
      selectedByAllFiltersCount = selectedByRangeCount
    }
    
    // console.log('🎚️ Updating selected count:', {
      // selectedByRangeCount,
      // selectedByAllFiltersCount,
      // currentMin: this.currentMinValue,
      // currentMax: this.currentMaxValue,
      // totalValues: sliderData.values.length,
      // hasOtherFilters: selectedByRangeCount !== selectedByAllFiltersCount
    // })
    
    // Show count with visual indicator if other filters are active
    if (selectedByRangeCount > selectedByAllFiltersCount) {
      // Other filters are reducing the count - show both counts in red
      this.selectedCountTarget.textContent = selectedByAllFiltersCount.toLocaleString()
      this.selectedCountTarget.style.color = '#dc2626'
      this.selectedCountTarget.style.fontWeight = '600'
      this.selectedCountTooltipData = {
        selectedByAllFiltersCount,
        selectedByRangeCount,
        filteredOutCount: selectedByRangeCount - selectedByAllFiltersCount,
        hasOtherFilters: true
      }
    } else {
      // No other filters active
      this.selectedCountTarget.textContent = selectedByAllFiltersCount.toLocaleString()
      this.selectedCountTarget.style.color = '#6b7280'
      this.selectedCountTarget.style.fontWeight = '500'
      this.selectedCountTooltipData = {
        selectedByAllFiltersCount,
        selectedByRangeCount,
        filteredOutCount: 0,
        hasOtherFilters: false
      }
    }
    this.selectedCountTarget.removeAttribute('title')
    this.attachSelectedCountTooltipHandlers()
    
    // Update total count if the target exists (for backward compatibility)
    if (this.hasTotalCountTarget) {
      const totalCount = sliderData.values.length
      this.totalCountTarget.textContent = totalCount.toLocaleString()
    }
  }

  attachSelectedCountTooltipHandlers() {
    if (!this.hasSelectedCountTarget) return

    const target = this.selectedCountTarget
    const tooltip = this.ensureSelectedCountTooltip()

    const hideTooltip = () => {
      tooltip.style.display = 'none'
    }

    const showTooltip = (event) => {
      const data = this.selectedCountTooltipData
      if (!data) return

      const total = data.selectedByRangeCount
      const filtered = data.selectedByAllFiltersCount
      const filteredOut = data.filteredOutCount
      const filteredPct = total > 0 ? (filtered / total) * 100 : 0
      const filteredOutPct = total > 0 ? (filteredOut / total) * 100 : 0

      const lines = []
      lines.push(`Total: <strong>${total.toLocaleString()}</strong>`)
      lines.push(`Filtered: <strong>${filtered.toLocaleString()}</strong> (<strong>${filteredPct.toFixed(1)}%</strong>)`)
      lines.push(`Filtered out: <strong>${filteredOut.toLocaleString()}</strong> (<strong>${filteredOutPct.toFixed(1)}%</strong>)`)

      tooltip.innerHTML = lines.join('<br>')
      tooltip.style.display = 'block'
      const isGeneSlider = this.metadataIdValue && this.metadataIdValue.startsWith('gene_')
      if (isGeneSlider) {
        const tooltipWidth = tooltip.offsetWidth || 220
        tooltip.style.left = `${event.clientX - tooltipWidth - 12}px`
      } else {
        tooltip.style.left = `${event.clientX + 12}px`
      }
      tooltip.style.top = `${event.clientY + 12}px`
    }

    if (target._selectedCountTooltipMoveHandler) {
      target.removeEventListener('mousemove', target._selectedCountTooltipMoveHandler)
    }
    if (target._selectedCountTooltipLeaveHandler) {
      target.removeEventListener('mouseleave', target._selectedCountTooltipLeaveHandler)
    }

    target.addEventListener('mousemove', showTooltip)
    target.addEventListener('mouseleave', hideTooltip)
    target._selectedCountTooltipMoveHandler = showTooltip
    target._selectedCountTooltipLeaveHandler = hideTooltip
  }

  ensureSelectedCountTooltip() {
    let tooltip = document.getElementById('range-selected-count-tooltip')
    if (tooltip) return tooltip

    tooltip = document.createElement('div')
    tooltip.id = 'range-selected-count-tooltip'
    tooltip.style.position = 'fixed'
    tooltip.style.display = 'none'
    tooltip.style.pointerEvents = 'none'
    tooltip.style.zIndex = '11000'
    tooltip.style.backgroundColor = 'rgba(17, 24, 39, 0.95)'
    tooltip.style.color = 'white'
    tooltip.style.padding = '8px 10px'
    tooltip.style.borderRadius = '6px'
    tooltip.style.fontSize = '12px'
    tooltip.style.lineHeight = '1.35'
    tooltip.style.boxShadow = '0 4px 12px rgba(0, 0, 0, 0.25)'
    tooltip.style.maxWidth = '260px'
    document.body.appendChild(tooltip)
    return tooltip
  }

  // Update the main plot with the new range (throttled for performance)
  updateMainPlot() {
    if (!this.visualizationController) return
    
    const startTime = performance.now()
    const now = Date.now()
    
    // If we're dragging, throttle the updates to improve performance
    if (this.isDragging) {
      if (now - this.lastPlotUpdate < this.plotUpdateThrottle) {
        // Schedule an update if one isn't already scheduled
        if (!this.plotUpdateScheduled) {
          this.plotUpdateScheduled = true
          requestAnimationFrame(() => {
            this.plotUpdateScheduled = false
            // console.log('🚀 [PERF] Scheduled plot update for metadata:', this.metadataIdValue)
            this.performPlotUpdate()
          })
        }
        // console.log('🚀 [PERF] Throttled plot update (too soon), metadata:', this.metadataIdValue)
        return
      }
    }
    
    // console.log('🚀 [PERF] Starting plot update for metadata:', this.metadataIdValue)
    this.performPlotUpdate()
    this.lastPlotUpdate = now
    
    const endTime = performance.now()
    // console.log(`🚀 [PERF] updateMainPlot completed in ${(endTime - startTime).toFixed(2)}ms for metadata:`, this.metadataIdValue)
  }
  
  // Perform the actual plot update (separated for throttling)
  performPlotUpdate() {
    if (!this.visualizationController || !this.dataManager) return
    
    const isGene = this.metadataIdValue && this.metadataIdValue.startsWith('gene_')
    const logPrefix = isGene ? '🧬 [SLIDER UPDATE]' : '🚀 [PERF]'
    
    const startTime = performance.now()
    // console.log(`${logPrefix} performPlotUpdate started for metadata:`, this.metadataIdValue)

    const activeColoringId = this.visualizationController.currentMetadataId
      ? String(this.visualizationController.currentMetadataId)
      : ''
    const sliderMetadataId = this.metadataIdValue ? String(this.metadataIdValue) : ''
    const isThisSliderActiveNumericColoring =
      activeColoringId === sliderMetadataId &&
      this.visualizationController.currentMetadataVector?.data_type === 'NUMERIC'
    
    // Update the color range in the main visualization
    const colorRangeStart = performance.now()
    if (this.visualizationController.updateColorRange) {
      // Check if we should adapt the color range to the selected range
      const shouldAdaptColorRange = this.adaptColorRangeEnabled && isThisSliderActiveNumericColoring

      if (shouldAdaptColorRange) {
        // Full color range adaptation only when this slider controls the active numeric coloring metadata.
        this.visualizationController.visibilityOnlyUpdate = false
        this.visualizationController.updateColorRange(
          this.metadataIdValue,
          this.currentMinValue,
          this.currentMaxValue,
          true
        )
      } else {
        // Filtering-only path: do not touch global color range while coloring is based on other metadata.
        if (typeof this.visualizationController.visibilityOnlyUpdate === 'boolean') {
          this.visualizationController.visibilityOnlyUpdate = true
        }
      }
    }
    const colorRangeTime = performance.now() - colorRangeStart
    // console.log(`${logPrefix} updateColorRange took ${colorRangeTime.toFixed(2)}ms`)
    
    // Check if we're showing the full range (no filtering needed).
    // Use the same tolerance as isContinuousSelectionConstraining / checkbox color so the
    // global filter tool never keeps a ghost entry after a visual full-range reset.
    const dataManager = this.visualizationController?.dataManager
    const isFullRange = dataManager?.isContinuousRangeFullCoverage
      ? dataManager.isContinuousRangeFullCoverage(
          this.currentMinValue,
          this.currentMaxValue,
          this.minValue,
          this.maxValue
        )
      : (
          this.currentMinValue <= this.minValue &&
          this.currentMaxValue >= this.maxValue
        )

    const rangeCandidate = { min: this.currentMinValue, max: this.currentMaxValue }
    const loadedVector =
      this.visualizationController?.loadedMetadataVectors?.[this.metadataIdValue] ||
      this.visualizationController?.loadedMetadataVectors?.[String(this.metadataIdValue)]
    const knownNotConstraining = !!(
      loadedVector?.values &&
      dataManager?.isContinuousSelectionConstraining &&
      dataManager.isContinuousSelectionConstraining(this.metadataIdValue, rangeCandidate) === false
    )

    if (isFullRange || knownNotConstraining) {
      // Remove from selectedRanges to disable filtering
      if (dataManager?.clearSelectedRange) {
        dataManager.clearSelectedRange(this.metadataIdValue)
      } else if (this.visualizationController.selectedRanges) {
        delete this.visualizationController.selectedRanges[this.metadataIdValue]
        delete this.visualizationController.selectedRanges[String(this.metadataIdValue)]
      }
      // Fully drop saved/disabled state so the global filter tool does not keep a stale entry.
      if (this.visualizationController.savedRanges) {
        Object.keys(this.visualizationController.savedRanges).forEach((key) => {
          if (String(key) === String(this.metadataIdValue)) {
            delete this.visualizationController.savedRanges[key]
          }
        })
      }
      if (this.visualizationController.disabledFilters instanceof Set) {
        this.visualizationController.disabledFilters.delete(this.metadataIdValue)
        this.visualizationController.disabledFilters.delete(String(this.metadataIdValue))
      }
      const filterSwitch = document.querySelector(
        `.metadata-filter-switch[data-metadata-id="${this.metadataIdValue}"]`
      )
      if (filterSwitch) {
        filterSwitch.dataset.filterEnabled = 'true'
      }
      if (isGene) {
        const geneIdToken = this.metadataIdValue.slice(5)
        const stableGeneId = geneIdToken.split('_')[0]
        const geneSwitch = document.querySelector(`.gene-filter-switch[data-gene-id="${stableGeneId}"]`)
        if (geneSwitch) {
          geneSwitch.dataset.filterEnabled = 'true'
        }
      }
    } else {
      // Store the range in selectedRanges for unified filtering
      if (dataManager?.setSelectedRange) {
        dataManager.setSelectedRange(this.metadataIdValue, rangeCandidate)
      } else {
        if (!this.visualizationController.selectedRanges) {
          this.visualizationController.selectedRanges = {}
        }
        this.visualizationController.selectedRanges[this.metadataIdValue] = rangeCandidate
      }
    }
    
    // Clear the filter cache and trigger a re-render with unified filtering
    const cacheClearStart = performance.now()
    if (this.visualizationController.filterCache) {
      this.visualizationController.filterCache.clear()
    }
    const cacheClearTime = performance.now() - cacheClearStart
    // console.log(`${logPrefix} filterCache.clear took ${cacheClearTime.toFixed(2)}ms`)
    
    // Update button appearance when range changes (after selectedRanges is updated)
    this.updateButtonAppearance()
    
    // Update filter switch visibility based on whether there's a selection
    if (this.visualizationController.uiManager) {
      this.visualizationController.uiManager.updateFilterSwitchVisibility(this.metadataIdValue)
      
      // Also update gene filter switch visibility if this is a gene slider
      if (this.metadataIdValue && this.metadataIdValue.startsWith('gene_')) {
        const geneIdToken = this.metadataIdValue.slice(5)
        const stableGeneId = geneIdToken.split('_')[0]
        this.visualizationController.uiManager.updateGeneFilterSwitchVisibility(stableGeneId, this.metadataIdValue)
      }
    }
    
    // Verify loadedMetadataVectors has the gene before filtering (critical check)
    if (isGene) {
      const hasInLoadedVectors = !!this.visualizationController.loadedMetadataVectors?.[this.metadataIdValue]
      // console.log(`${logPrefix} BEFORE updateCellFiltering - loadedMetadataVectors has ${this.metadataIdValue}:`, hasInLoadedVectors)
      if (!hasInLoadedVectors) {
        console.error(`❌ ${logPrefix} CRITICAL: ${this.metadataIdValue} NOT in loadedMetadataVectors before filtering!`)
        console.error(`❌ ${logPrefix} loadedMetadataVectors keys:`, Object.keys(this.visualizationController.loadedMetadataVectors || {}))
        
        // CRITICAL: Try to restore the gene metadata from inlineRangeSliderData
        // The metadata might be in a different controller instance
        const sliderData = this.visualizationController.inlineRangeSliderData?.[this.metadataIdValue]
        if (sliderData && sliderData.values) {
          // console.log(`${logPrefix} Attempting to restore gene metadata from inlineRangeSliderData`)
          
          // Create the metadata vector structure
          const minVal = this.visualizationController.dataManager?.safeMin(sliderData.values) ?? Math.min(...sliderData.values)
          const maxVal = this.visualizationController.dataManager?.safeMax(sliderData.values) ?? Math.max(...sliderData.values)
          
          if (!this.visualizationController.loadedMetadataVectors) {
            this.visualizationController.loadedMetadataVectors = {}
          }
          
          // Extract gene ID from metadata ID (gene_219 -> 219)
          const geneId = this.metadataIdValue.replace('gene_', '')
          
          this.visualizationController.loadedMetadataVectors[this.metadataIdValue] = {
            id: this.metadataIdValue,
            name: `Gene ${geneId}`,
            display_name: `Gene ${geneId}`,
            data_type: 'NUMERIC',
            values: sliderData.values,
            compression_info: {
              min_val: minVal,
              max_val: maxVal,
              data_type: 'NUMERIC'
            },
            nber_rows: 1,
            nber_cols: sliderData.values.length
          }
          
          // console.log(`${logPrefix} Restored gene metadata in loadedMetadataVectors: ${this.metadataIdValue}`)
          // console.log(`${logPrefix} loadedMetadataVectors keys after restore:`, Object.keys(this.visualizationController.loadedMetadataVectors))
        } else {
          console.error(`❌ ${logPrefix} Cannot restore - inlineRangeSliderData also missing ${this.metadataIdValue}`)
        }
      }
      
      // Check renderer state before filtering (for debugging)
      // console.log(`${logPrefix} Renderer state BEFORE updateCellFiltering (gene filtering):`, {
        // hasReglRenderer: !!this.visualizationController.reglRenderer,
        // rendererInstanceId: this.visualizationController.reglRenderer?.instanceId || 'none',
        // numPoints: this.visualizationController.reglRenderer?.numPoints || 0,
        // hasPositions: !!this.visualizationController.reglRenderer?.positions,
        // positionsLength: this.visualizationController.reglRenderer?.positions?.length || 0,
        // hasCurrentCoordinates: !!this.visualizationController.currentCoordinates,
        // currentCoordinatesLength: this.visualizationController.currentCoordinates?.length || 0
      // })
    }
    
    // Trigger unified filtering (which will update ALL counts and render)
    const filterStart = performance.now()
    if (this.dataManager.updateCellFiltering) {
      // Recompute colors only when this slider controls active numeric coloring.
      const shouldUpdateColors = this.adaptColorRangeEnabled && isThisSliderActiveNumericColoring
      // console.log(`${logPrefix} Calling updateCellFiltering with shouldUpdateColors:`, shouldUpdateColors)
      this.dataManager.updateCellFiltering(shouldUpdateColors)
    } else {
      console.error(`❌ ${logPrefix} dataManager.updateCellFiltering is not available!`)
    }
    // Keep global filter tool in sync immediately when a continuous filter is added/removed.
    if (this.visualizationController.uiManager?.updateGlobalFilterSummary) {
      this.visualizationController.uiManager.updateGlobalFilterSummary()
    }
    if (this.visualizationController.globalFilterPanelVisible &&
        this.visualizationController.uiManager?.updateGlobalFilterPanelContent) {
      this.visualizationController.uiManager.updateGlobalFilterPanelContent()
    }
    const filterTime = performance.now() - filterStart
    // console.log(`${logPrefix} updateCellFiltering took ${filterTime.toFixed(2)}ms`)
    
    // Only update the color legend if we're adapting the color range
    // (otherwise the legend doesn't change, so no need to redraw)
    if (this.adaptColorRangeEnabled) {
      const legendStart = performance.now()
      if (this.rendererManager.renderContinuousColorLegendCanvas2D) {
        this.rendererManager.renderContinuousColorLegendCanvas2D()
      }
      const legendTime = performance.now() - legendStart
      // console.log(`🚀 [PERF] renderContinuousColorLegend took ${legendTime.toFixed(2)}ms`)
    } else {
      // console.log(`🚀 [PERF] Skipping legend update (adapt range not enabled)`)
    }
    
    const totalTime = performance.now() - startTime
    // console.log(`🚀 [PERF] performPlotUpdate completed in ${totalTime.toFixed(2)}ms for metadata:`, this.metadataIdValue)
  }

  isPlotVisible() {
    if (!this.element) return false
    if (this.element.offsetParent === null) return false
    const rects = this.element.getClientRects()
    return rects.length > 0
  }

  scheduleDensityPlotRender(delay = 120) {
    if (this.pendingDensityPlotTimeout) return
    this.pendingDensityPlotTimeout = setTimeout(() => {
      this.pendingDensityPlotTimeout = null
      this.drawDensityPlot()
    }, delay)
  }

  // Draw the density plot
  drawDensityPlot() {
    if (!this.hasCanvasTarget) {
      return
    }
    if (!this.isPlotVisible()) {
      this.scheduleDensityPlotRender()
      return
    }

    const sliderData = this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue]
    if (!sliderData || !sliderData.values || sliderData.values.length === 0) {
      return
    }

    const canvas = this.canvasTarget
    if (!canvas) {
      return
    }

    const ctx = canvas.getContext('2d')
    const rect = canvas.getBoundingClientRect()

    // Check if canvas currently has non-zero dimensions
    if (rect.width === 0 || rect.height === 0) {
      this.scheduleDensityPlotRender()
      return
    }
    
    const dpr = window.devicePixelRatio || 1
    
    // Calculate required height based on content
    // We need space for: top margin + plot area + bottom margin (with axis labels)
    // First, estimate text width for min/max values to calculate margins
    const tempCanvas = document.createElement('canvas')
    const tempCtx = tempCanvas.getContext('2d')
    tempCtx.font = '10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    const minValueText = this.minValue.toFixed(3)
    const maxValueText = this.maxValue.toFixed(3)
    const minTextMetrics = tempCtx.measureText(minValueText)
    const maxTextMetrics = tempCtx.measureText(maxValueText)
    const maxTextWidth = Math.max(minTextMetrics.width, maxTextMetrics.width)
    
    // Calculate required margins
    const estimatedLeftMargin = Math.max(35, 15 + maxTextWidth / 2)
    const estimatedRightMargin = Math.max(15, maxTextWidth / 2 + 5)
    const estimatedBottomMargin = 35 // Space for tick labels (10px) + axis title (12px) + padding (13px) - reduced
    const estimatedTopMargin = 10
    const tooltipSpace = 30 // Space for tooltip below the plot (20px height + 10px padding)
    const minPlotHeight = 30 // Minimum plot area height
    const requiredHeight = estimatedTopMargin + minPlotHeight + estimatedBottomMargin + tooltipSpace
    
    // Adjust canvas height if current height is too small
    const containerDiv = canvas.parentElement
    if (containerDiv && (rect.height < requiredHeight || !canvas.style.height)) {
      canvas.style.height = `${requiredHeight}px`
      // Recalculate rect after height change
      const newRect = canvas.getBoundingClientRect()
      rect.width = newRect.width
      rect.height = newRect.height
    }
    
    // Set canvas internal resolution to match display size
    // Note: We intentionally do NOT set canvas.style.width/height here because
    // the canvas should adapt to its container (which has width: 100% in CSS)
    // Setting explicit pixel values would prevent it from adapting to column resizing
    // The CSS handles the display size, we only update the internal resolution
    canvas.width = rect.width * dpr
    canvas.height = rect.height * dpr
    ctx.scale(dpr, dpr)
    
    // Clear any fixed pixel width/height that might have been set previously
    // This allows the canvas to adapt to container width changes via CSS
    if (canvas.style.width && !canvas.style.width.includes('%')) {
      canvas.style.width = ''
    }
    
    // Clear canvas
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    
    // Clear stored canvas data for tooltip
    this.originalCanvasData = null
    
    // Calculate text metrics to determine required margins (after scaling)
    ctx.font = '10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    const minTextMetricsScaled = ctx.measureText(minValueText)
    const maxTextMetricsScaled = ctx.measureText(maxValueText)
    const maxTextWidthScaled = Math.max(minTextMetricsScaled.width, maxTextMetricsScaled.width)
    
    // Define margins for axis titles and tick labels
    // Left margin needs to accommodate rotated Y-axis title and potential tick labels
    const leftMargin = Math.max(35, 15 + maxTextWidthScaled / 2)
    // Bottom margin needs space for X-axis title and tick labels (reduced to move axis higher)
    const bottomMargin = Math.max(30, 20 + 10)
    const topMargin = 10
    // Right margin needs space for potential tick labels
    const rightMargin = Math.max(15, maxTextWidthScaled / 2 + 5)
    
    // Calculate plot area
    const plotWidth = rect.width - leftMargin - rightMargin
    const plotHeight = rect.height - topMargin - bottomMargin
    
    // Get filtered cell indices (if any filters are active)
    // This ensures the histogram only shows cells that pass all active filters
    const filteredIndices = this.visualizationController?.dataManager?.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    
    // Check if there's a range filter on this metadata
    const rangeFilter = this.visualizationController?.selectedRanges && this.visualizationController.selectedRanges[this.metadataIdValue]
    const hasRangeFilter = rangeFilter && rangeFilter.min !== undefined && rangeFilter.max !== undefined
    
    // Filter values to only include those from filtered cells AND within the selected range (if a range filter exists)
    const filteredValues = []
    sliderData.values.forEach((value, index) => {
      // Only include values from cells that pass all filters
      if (!filteredSet || filteredSet.has(index)) {
        // If there's a range filter on this metadata, also check that the value is within the range
        if (hasRangeFilter) {
          if (value >= rangeFilter.min && value <= rangeFilter.max) {
            filteredValues.push(value)
          }
        } else {
          filteredValues.push(value)
        }
      }
    })
    
    // Create histogram using only filtered values
    const numBins = 50
    const histogramOptions = this.getHistogramOptions()
    const { bins, maxCount, binRanges, sourceCount } = this.visualizationController.buildHistogramBins(
      filteredValues,
      this.minValue,
      this.maxValue,
      numBins,
      histogramOptions
    )
    const barWidth = plotWidth / numBins
    const denom = maxCount > 0 ? maxCount : 1
    const totalForDensity = sourceCount > 0 ? sourceCount : filteredValues.length
    
    // Store bin data for hover tooltip
    this.binData = bins.map((count, i) => ({
      count,
      density: totalForDensity > 0 ? (count / totalForDensity) * 100 : 0,
      range: binRanges[i] || { min: this.minValue, max: this.maxValue },
      x: leftMargin + i * barWidth,
      y: topMargin + plotHeight - (count / denom) * plotHeight,
      width: barWidth - 1,
      height: (count / denom) * plotHeight
    }))
    
    // Draw bars
    ctx.fillStyle = '#9ca3af'
    this.binData.forEach((bin, i) => {
      ctx.fillRect(bin.x, bin.y, bin.width, bin.height)
    })
    
    // Draw range selection overlay (linear or log10 along value axis, matching histogram bins)
    const vc = this.visualizationController
    const minPercent = vc.histogramSelectionFraction(this.currentMinValue, this.minValue, this.maxValue, histogramOptions)
    const maxPercent = vc.histogramSelectionFraction(this.currentMaxValue, this.minValue, this.maxValue, histogramOptions)
    const p0 = Math.min(minPercent, maxPercent)
    const p1 = Math.max(minPercent, maxPercent)
    
    // Check if filter is disabled (gray) or enabled (blue)
    const isFilterDisabled = this.visualizationController?.disabledFilters?.has(this.metadataIdValue)
    ctx.fillStyle = isFilterDisabled ? 'rgba(209, 213, 219, 0.5)' : 'rgba(59, 130, 246, 0.18)' // gray or blue
    const overlayX = leftMargin + p0 * plotWidth
    const overlayWidth = (p1 - p0) * plotWidth
    ctx.fillRect(overlayX, topMargin, overlayWidth, plotHeight)
    
    // Draw axis titles and tick labels
    ctx.fillStyle = '#374151'
    ctx.font = '10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    
    // Draw X-axis tick labels (min and max values) - moved higher
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    const xAxisY = rect.height - bottomMargin + 2
    ctx.fillText(minValueText, leftMargin, xAxisY)
    ctx.fillText(maxValueText, rect.width - rightMargin, xAxisY)
    
    // Draw X-axis title (below tick labels) - moved higher
    ctx.font = '11px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    const xAxisTitle = histogramOptions.scale === 'log' ? 'Value bins (log)' : 'Value bins'
    ctx.fillText(xAxisTitle, rect.width / 2, rect.height - bottomMargin + 15)
    
    // Y-axis title (left side, rotated)
    ctx.save()
    ctx.translate(15, rect.height / 2 - 10)
    ctx.rotate(-Math.PI / 2)
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.font = '11px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    const yAxisTitle = 'Density'
    ctx.fillText(yAxisTitle, 0, 0)
    ctx.restore()
    
    // Add mouse event listeners for hover tooltip
    this.setupDensityPlotHover(canvas, rect)
  }

  // Setup hover tooltip for density plot
  setupDensityPlotHover(canvas, rect) {
    // Remove existing event listeners to avoid duplicates
    canvas.removeEventListener('mousemove', this.handleDensityPlotHover)
    canvas.removeEventListener('mouseleave', this.handleDensityPlotLeave)
    
    // Add new event listeners
    canvas.addEventListener('mousemove', this.handleDensityPlotHover.bind(this))
    canvas.addEventListener('mouseleave', this.handleDensityPlotLeave.bind(this))
  }

  // Handle mouse hover over density plot
  handleDensityPlotHover(event) {
    if (!this.binData) return
    
    const canvas = this.canvasTarget
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    
    // Find which bin the mouse is over based only on horizontal position
    const hoveredBin = this.binData.find(bin => 
      x >= bin.x && x <= bin.x + bin.width
    )
    
    if (hoveredBin) {
      // Show tooltip
      this.showDensityPlotTooltip(hoveredBin, x, 0)
    } else {
      // Hide tooltip
      this.hideDensityPlotTooltip()
    }
  }

  // Handle mouse leave from density plot
  handleDensityPlotLeave() {
    this.hideDensityPlotTooltip()
  }

  // Show tooltip with bin information
  showDensityPlotTooltip(bin, mouseX, mouseY) {
    const canvas = this.canvasTarget
    const rect = canvas.getBoundingClientRect()
    const ctx = canvas.getContext('2d')
    
    // Store original canvas state if not already stored
    if (!this.originalCanvasData) {
      this.originalCanvasData = ctx.getImageData(0, 0, canvas.width, canvas.height)
    }
    
    // Tooltip content - combine on single line with cell count
    const tooltipText = `${bin.range.min.toFixed(3)} - ${bin.range.max.toFixed(3)} (${bin.count} cells, ${bin.density.toFixed(1)}%)`
    
    // Calculate tooltip width based on text content
    ctx.font = '10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    const textMetrics = ctx.measureText(tooltipText)
    const tooltipWidth = textMetrics.width + 16
    const tooltipHeight = 20
    
    // Calculate margins to match drawDensityPlot (recalculate to ensure consistency)
    const minValueText = this.minValue.toFixed(3)
    const maxValueText = this.maxValue.toFixed(3)
    const minTextMetrics = ctx.measureText(minValueText)
    const maxTextMetrics = ctx.measureText(maxValueText)
    const maxTextWidth = Math.max(minTextMetrics.width, maxTextMetrics.width)
    
    const leftMargin = Math.max(35, 15 + maxTextWidth / 2)
    const rightMargin = Math.max(15, maxTextWidth / 2 + 5)
    const bottomMargin = Math.max(30, 20 + 10)
    const plotBottom = rect.height - bottomMargin
    
    // Position tooltip below the plot area, centered on mouse X position
    // Clamp to ensure tooltip stays within canvas bounds
    const tooltipX = Math.max(leftMargin + tooltipWidth / 2, 
                      Math.min(mouseX, rect.width - rightMargin - tooltipWidth / 2))
    const tooltipY = plotBottom + 5
    
    // Draw tooltip background
    ctx.fillStyle = 'rgba(0, 0, 0, 0.8)'
    ctx.fillRect(tooltipX - tooltipWidth / 2, tooltipY, tooltipWidth, tooltipHeight)
    
    // Draw tooltip text (single line)
    ctx.fillStyle = 'white'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    ctx.fillText(tooltipText, tooltipX, tooltipY + 4)
  }

  // Hide tooltip
  hideDensityPlotTooltip() {
    if (this.originalCanvasData) {
      const canvas = this.canvasTarget
      const ctx = canvas.getContext('2d')
      ctx.putImageData(this.originalCanvasData, 0, 0)
    }
  }

  // Handle input field changes
  minInputChanged() {
    if (!this.hasMinInputTarget) return
    
    const newValue = parseFloat(this.minInputTarget.value)
    if (!isNaN(newValue) && newValue >= this.minValue && newValue <= this.currentMaxValue) {
      this.currentMinValue = newValue
      this.updateSliderUI()
      this.updateSelectedCellsCount()
      this.updateMainPlot()
      this.drawDensityPlot()
    }
  }

  maxInputChanged() {
    if (!this.hasMaxInputTarget) return
    
    const newValue = parseFloat(this.maxInputTarget.value)
    if (!isNaN(newValue) && newValue >= this.currentMinValue && newValue <= this.maxValue) {
      this.currentMaxValue = newValue
      this.updateSliderUI()
      this.updateSelectedCellsCount()
      this.updateMainPlot()
      this.drawDensityPlot()
    }
  }

  // Apply the current range (called by Apply button)
  applyRange() {
    // console.log('🎚️ Applying range:', { min: this.currentMinValue, max: this.currentMaxValue })
    this.updateMainPlot()
  }

  // Reset to full range (called by Reset button)
  resetRange() {
    // console.log('🎚️ Resetting range to full range')
    this.currentMinValue = this.minValue
    this.currentMaxValue = this.maxValue
    this.updateSliderUI()
    this.updateSelectedCellsCount()
    this.updateMainPlot()
    this.drawDensityPlot()
  }

  // Handle color range adaptation button click
  adaptColorRangeChanged() {
    // console.log('🎨 adaptColorRangeChanged method called!')
    // console.log('🎨 Has button target:', this.hasAdaptColorRangeButtonTarget)
    
    if (!this.hasAdaptColorRangeButtonTarget) {
      console.error('🎨 Button target not found!')
      return
    }
    
    // Toggle the state
    this.adaptColorRangeEnabled = !this.adaptColorRangeEnabled
    if (this.visualizationController) {
      if (!this.visualizationController.adaptColorRangeByMetadataId) {
        this.visualizationController.adaptColorRangeByMetadataId = {}
      }
      this.visualizationController.adaptColorRangeByMetadataId[this.metadataIdValue] = this.adaptColorRangeEnabled
    }
    // console.log('🎨 Color range adaptation changed:', this.adaptColorRangeEnabled ? 'enabled' : 'disabled')
    // console.log('🎨 Current range:', { min: this.currentMinValue, max: this.currentMaxValue })
    
    // Update button appearance
    this.updateButtonAppearance()
    
    // console.log('🎨 After updateButtonAppearance, checking visualization controller...')
    
    if (!this.visualizationController) {
      console.error('🎨 Visualization controller not found!')
      return
    }
    
    // console.log('🎨 Visualization controller found, proceeding with re-render')
    
    // Force a full re-render to update colors and legend
    this.visualizationController.visibilityOnlyUpdate = false
    // console.log('🎨 Set visibilityOnlyUpdate to false')
    
    // Calculate the effective range for color adaptation
    // When adapt is enabled, use the selected range (currentMinValue/currentMaxValue)
    // When adapt is disabled, use the full data range (minValue/maxValue)
    // IMPORTANT: Do NOT modify the slider values - only use them for color range calculation
    let effectiveMin = this.currentMinValue
    let effectiveMax = this.currentMaxValue
    
    if (this.adaptColorRangeEnabled) {
      // Use the selected range for color adaptation
      // This adapts the color legend to show the full range of selected values
      effectiveMin = this.currentMinValue
      effectiveMax = this.currentMaxValue
      // console.log('🎨 Adapting color range to selected range:', { min: effectiveMin, max: effectiveMax })
    } else {
      // Use the full data range
      effectiveMin = this.minValue
      effectiveMax = this.maxValue
      // console.log('🎨 Using full data range for colors:', { min: effectiveMin, max: effectiveMax })
    }
    
    // Update the color range with the new setting
    // console.log('🎨 Calling updateColorRange with:', {
      // metadataId: this.metadataIdValue,
      // min: effectiveMin,
      // max: effectiveMax,
      // adapt: this.adaptColorRangeEnabled
    // })
    this.visualizationController.updateColorRange(
      this.metadataIdValue, 
      effectiveMin, 
      effectiveMax,
      this.adaptColorRangeEnabled
    )
    // console.log('🎨 updateColorRange completed')
    
    // Trigger a full re-render of the plot and legend
    // console.log('🎨 About to trigger re-render, method exists?', !!this.visualizationController.renderPointsWithCurrentColoring)
    if (this.visualizationController.renderPointsWithCurrentColoring) {
      // console.log('🎨 Triggering full plot re-render...')
      try {
        this.visualizationController.renderPointsWithCurrentColoring()
        // console.log('🎨 Plot re-render completed')
      } catch (error) {
        console.error('🎨 ERROR during plot re-render:', error)
        console.error('🎨 Error stack:', error.stack)
      }
    } else {
      console.error('🎨 renderPointsWithCurrentColoring method not found!')
    }
    
    // console.log('🎨 About to trigger legend re-render, method exists?', !!this.rendererManager.renderContinuousColorLegendCanvas2D)
    if (this.rendererManager.renderContinuousColorLegendCanvas2D) {
      // console.log('🎨 Triggering legend re-render...')
      this.rendererManager.renderContinuousColorLegendCanvas2D()
      // console.log('🎨 Legend re-render completed')
    } else {
      console.error('🎨 renderContinuousColorLegend method not found!')
    }
    
    // Redraw the histogram to reflect the new range
    this.drawDensityPlot()
    
    // Update all bar plots to reflect the new gradient
    if (this.visualizationController.dataManager && this.visualizationController.dataManager.updateAllCategoryDistributions) {
      // console.log('🎨 Updating all category distributions...')
      this.visualizationController.dataManager.updateAllCategoryDistributions()
      // console.log('🎨 Category distributions updated')
    } else {
      console.warn('🎨 updateAllCategoryDistributions not found!')
    }
    
    // console.log('🎨 Button click handling completed!')
  }

  // Update button appearance based on state
  updateButtonAppearance() {
    if (!this.hasAdaptColorRangeButtonTarget) {
      // console.log('🎨 Button target not found for appearance update')
      return
    }
    
    const button = this.adaptColorRangeButtonTarget
    
    // Check if this metadata/gene is currently being used for coloring
    const isColoringActive = this.visualizationController?.currentMetadataVector?.id === this.metadataIdValue
    
    // Check if there's a restricted selection range (filter applied)
    // A range is restricted if it's not the full range
    let isRangeRestricted = false
    const tolerance = 0.0001
    
    // Check if selectedRanges contains this metadataId (indicates a filter is applied)
    const hasSelectedRange = this.visualizationController?.selectedRanges?.[this.metadataIdValue] !== undefined
    if (hasSelectedRange && this.minValue !== undefined && this.maxValue !== undefined) {
      const selectedRange = this.visualizationController.selectedRanges[this.metadataIdValue]
      // Range is restricted if it's not the full range
      isRangeRestricted = !(Math.abs(selectedRange.min - this.minValue) < tolerance && 
                           Math.abs(selectedRange.max - this.maxValue) < tolerance)
    }
    
    // Also check slider's current values as fallback (in case selectedRanges hasn't been updated yet)
    if (!isRangeRestricted && this.minValue !== undefined && this.maxValue !== undefined && 
        this.currentMinValue !== undefined && this.currentMaxValue !== undefined) {
      // Range is restricted if current range is different from full range
      isRangeRestricted = !(Math.abs(this.currentMinValue - this.minValue) < tolerance && 
                           Math.abs(this.currentMaxValue - this.maxValue) < tolerance)
    }
    
    // Show button only if coloring is active AND there's a restricted range
    const shouldShowButton = isColoringActive && isRangeRestricted
    
    // Use visibility instead of display to maintain layout space and prevent slider from resizing
    if (!shouldShowButton) {
      button.style.visibility = 'hidden'
      button.style.pointerEvents = 'none'
      // console.log('🎨 Hiding adapt color range button - coloring not active or range not restricted')
      return
    }
    
    // Show button only if both conditions are met
    button.style.visibility = 'visible'
    button.style.pointerEvents = 'auto'
    
    if (this.adaptColorRangeEnabled) {
      // Active state - green colors
      // console.log('🎨 Setting green colors for active state')
      button.style.backgroundColor = '#f0fdf4'
      button.style.borderColor = '#86efac'
      button.style.color = '#16a34a'
      button.title = 'Color range adapted to selected range - Click to use full data range'
    } else {
      // Inactive state - grey colors
      // console.log('🎨 Setting grey colors for inactive state')
      button.style.backgroundColor = '#f9fafb'
      button.style.borderColor = '#d1d5db'
      button.style.color = '#6b7280'
      button.title = 'Adapt color range to selected range - When enabled, the color legend will adjust to show the full range of selected values'
    }
    
    // console.log('🎨 Button appearance updated:', {
      // backgroundColor: button.style.backgroundColor,
      // borderColor: button.style.borderColor,
      // color: button.style.color
    // })
  }
}
