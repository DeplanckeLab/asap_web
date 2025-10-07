// Range Slider Controller for inline range sliders
// This controller handles the range slider functionality for metadata filtering

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["track", "activeTrack", "minHandle", "maxHandle", "minInput", "maxInput", "selectedCount", "totalCount", "canvas", "adaptColorRangeButton"]
  static values = { 
    metadataId: String,
    min: Number,
    max: Number,
    currentMin: Number,
    currentMax: Number
  }

  connect() {
    console.log('🎚️ Range slider controller connected for metadata:', this.metadataIdValue)
    console.log('🎚️ Initial values:', {
      min: this.minValue,
      max: this.maxValue,
      currentMin: this.currentMinValue,
      currentMax: this.currentMaxValue
    })
    
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
    
    // Color range adaptation button state
    this.adaptColorRangeEnabled = false
    
    // Get the main visualization controller
    this.visualizationController = window.visualizationController
    console.log('🎚️ Range slider controller connected, visualization controller:', !!this.visualizationController)
    
    // Initialize button appearance
    this.updateButtonAppearance()
    
    // Don't initialize immediately - wait for values to be set by the main controller
    console.log('🎚️ Range slider controller ready, waiting for initialization')
  }

  disconnect() {
    // Clean up event listeners
    this.stopDrag()
  }

  // Initialize the slider with data
  initializeSlider() {
    console.log('🎚️ Initializing range slider with values:', {
      min: this.minValue,
      max: this.maxValue,
      currentMin: this.currentMinValue,
      currentMax: this.currentMaxValue
    })
    
    if (this.minValue === undefined || this.maxValue === undefined) {
      console.error('❌ Range slider values not properly set:', {
        min: this.minValue,
        max: this.maxValue
      })
      return
    }
    
    // Check if visualization controller and data are available
    console.log('🎚️ Checking data availability:', {
      hasVisualizationController: !!this.visualizationController,
      hasInlineRangeSliderData: !!this.visualizationController?.inlineRangeSliderData,
      hasMetadataData: !!this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue],
      metadataId: this.metadataIdValue
    })
    
    this.updateSliderUI()
    this.updateSelectedCellsCount()
    this.drawDensityPlot()
  }

  // Start dragging a handle
  startDrag(event) {
    // Get the handle type from the event target's data attribute
    const handleType = event.target.dataset.rangeSliderHandleParam
    console.log('🎚️ Starting drag for handle:', handleType)
    
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
    this.updateSelectedCellsCount()
    const uiTime = performance.now() - uiStartTime
    console.log(`🚀 [PERF] UI update took ${uiTime.toFixed(2)}ms`)
    
    // Throttle expensive operations during dragging
    if (!this.dragUpdateScheduled) {
      this.dragUpdateScheduled = true
      requestAnimationFrame(() => {
        this.dragUpdateScheduled = false
        console.log('🚀 [PERF] Scheduled expensive operations for metadata:', this.metadataIdValue)
        this.updateMainPlot()
        this.drawDensityPlot()
      })
    } else {
      console.log('🚀 [PERF] Throttled expensive operations (already scheduled)')
    }
    
    const totalDragTime = performance.now() - dragStartTime
    console.log(`🚀 [PERF] handleDrag completed in ${totalDragTime.toFixed(2)}ms for metadata:`, this.metadataIdValue)
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
    this.updateMainPlot()
    this.drawDensityPlot()
    
    console.log('🎚️ Drag stopped')
  }

  // Update the slider UI elements
  updateSliderUI() {
    console.log('🎚️ Updating slider UI with values:', {
      min: this.minValue,
      max: this.maxValue,
      currentMin: this.currentMinValue,
      currentMax: this.currentMaxValue
    })
    
    const range = this.maxValue - this.minValue
    const minPercent = ((this.currentMinValue - this.minValue) / range) * 100
    const maxPercent = ((this.currentMaxValue - this.minValue) / range) * 100
    
    console.log('🎚️ Calculated percentages:', { minPercent, maxPercent })
    
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
  }

  // Update the selected cells count display
  updateSelectedCellsCount() {
    if (!this.hasSelectedCountTarget) return
    
    // Get the metadata values from the visualization controller
    const sliderData = this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue]
    if (!sliderData || !sliderData.values) {
      console.log('🎚️ No slider data available for count update')
      return
    }
    
    // Count cells within the selected range
    const selectedCount = sliderData.values.filter(value => 
      value >= this.currentMinValue && value <= this.currentMaxValue
    ).length
    
    console.log('🎚️ Updating selected count:', {
      selectedCount,
      currentMin: this.currentMinValue,
      currentMax: this.currentMaxValue,
      totalValues: sliderData.values.length
    })
    
    this.selectedCountTarget.textContent = selectedCount.toLocaleString()
    
    // Update total count if the target exists (for backward compatibility)
    if (this.hasTotalCountTarget) {
      const totalCount = sliderData.values.length
      this.totalCountTarget.textContent = totalCount.toLocaleString()
    }
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
            console.log('🚀 [PERF] Scheduled plot update for metadata:', this.metadataIdValue)
            this.performPlotUpdate()
          })
        }
        console.log('🚀 [PERF] Throttled plot update (too soon), metadata:', this.metadataIdValue)
        return
      }
    }
    
    console.log('🚀 [PERF] Starting plot update for metadata:', this.metadataIdValue)
    this.performPlotUpdate()
    this.lastPlotUpdate = now
    
    const endTime = performance.now()
    console.log(`🚀 [PERF] updateMainPlot completed in ${(endTime - startTime).toFixed(2)}ms for metadata:`, this.metadataIdValue)
  }
  
  // Perform the actual plot update (separated for throttling)
  performPlotUpdate() {
    if (!this.visualizationController) return
    
    const startTime = performance.now()
    console.log('🚀 [PERF] performPlotUpdate started for metadata:', this.metadataIdValue)
    
    // Update the color range in the main visualization
    const colorRangeStart = performance.now()
    if (this.visualizationController.updateColorRange) {
      // Check if we should adapt the color range to the selected range
      const shouldAdaptColorRange = this.adaptColorRangeEnabled
      
      if (shouldAdaptColorRange) {
        // Full color range adaptation - use the full rendering approach
        console.log('🎨 Adapting color range to selected range')
        this.visualizationController.visibilityOnlyUpdate = false // Force full render
      } else {
        // Fast path - just visibility updates
        if (typeof this.visualizationController.visibilityOnlyUpdate === 'boolean') {
          this.visualizationController.visibilityOnlyUpdate = true
        }
      }
      
      this.visualizationController.updateColorRange(
        this.metadataIdValue, 
        this.currentMinValue, 
        this.currentMaxValue,
        shouldAdaptColorRange
      )
    }
    const colorRangeTime = performance.now() - colorRangeStart
    console.log(`🚀 [PERF] updateColorRange took ${colorRangeTime.toFixed(2)}ms`)
    
    // Check if we're showing the full range (no filtering needed)
    const isFullRange = this.currentMinValue <= this.minValue && this.currentMaxValue >= this.maxValue
    
    if (isFullRange) {
      // Remove from selectedRanges to disable filtering
      if (this.visualizationController.selectedRanges) {
        delete this.visualizationController.selectedRanges[this.metadataIdValue]
      }
    } else {
      // Store the range in selectedRanges for unified filtering
      if (!this.visualizationController.selectedRanges) {
        this.visualizationController.selectedRanges = {}
      }
      this.visualizationController.selectedRanges[this.metadataIdValue] = {
        min: this.currentMinValue,
        max: this.currentMaxValue
      }
    }
    
    // Clear the filter cache and trigger a re-render with unified filtering
    const cacheClearStart = performance.now()
    if (this.visualizationController.filterCache) {
      this.visualizationController.filterCache.clear()
    }
    const cacheClearTime = performance.now() - cacheClearStart
    console.log(`🚀 [PERF] filterCache.clear took ${cacheClearTime.toFixed(2)}ms`)
    
    // Re-render with unified filtering
    const renderStart = performance.now()
    if (this.visualizationController.renderPointsWithCurrentColoring) {
      this.visualizationController.renderPointsWithCurrentColoring()
    }
    const renderTime = performance.now() - renderStart
    console.log(`🚀 [PERF] renderPointsWithCurrentColoring took ${renderTime.toFixed(2)}ms`)
    
    // Update the color legend after rendering
    const legendStart = performance.now()
    if (this.visualizationController.renderContinuousColorLegend) {
      this.visualizationController.renderContinuousColorLegend()
    }
    const legendTime = performance.now() - legendStart
    console.log(`🚀 [PERF] renderContinuousColorLegend took ${legendTime.toFixed(2)}ms`)
    
    const totalTime = performance.now() - startTime
    console.log(`🚀 [PERF] performPlotUpdate completed in ${totalTime.toFixed(2)}ms for metadata:`, this.metadataIdValue)
  }

  // Draw the density plot
  drawDensityPlot() {
    if (!this.hasCanvasTarget) return
    
    const sliderData = this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue]
    if (!sliderData || !sliderData.values) return
    
    const canvas = this.canvasTarget
    const ctx = canvas.getContext('2d')
    const rect = canvas.getBoundingClientRect()
    const dpr = window.devicePixelRatio || 1
    
    // Set canvas size
    canvas.width = rect.width * dpr
    canvas.height = rect.height * dpr
    ctx.scale(dpr, dpr)
    canvas.style.width = rect.width + 'px'
    canvas.style.height = rect.height + 'px'
    
    // Clear canvas
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    
    // Create histogram
    const numBins = 50
    const binWidth = (this.maxValue - this.minValue) / numBins
    const bins = new Array(numBins).fill(0)
    
    sliderData.values.forEach(value => {
      const binIndex = Math.min(Math.floor((value - this.minValue) / binWidth), numBins - 1)
      bins[binIndex]++
    })
    
    const maxCount = Math.max(...bins)
    const barWidth = rect.width / numBins
    
    // Draw bars
    ctx.fillStyle = '#e0e0e0'
    bins.forEach((count, i) => {
      const barHeight = (count / maxCount) * (rect.height - 20)
      const x = i * barWidth
      const y = rect.height - barHeight - 10
      ctx.fillRect(x, y, barWidth - 1, barHeight)
    })
    
    // Draw range selection overlay
    const range = this.maxValue - this.minValue
    const minPercent = (this.currentMinValue - this.minValue) / range
    const maxPercent = (this.currentMaxValue - this.minValue) / range
    
    ctx.fillStyle = 'rgba(0, 123, 255, 0.3)'
    const overlayX = minPercent * rect.width
    const overlayWidth = (maxPercent - minPercent) * rect.width
    ctx.fillRect(overlayX, 10, overlayWidth, rect.height - 20)
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
    console.log('🎚️ Applying range:', { min: this.currentMinValue, max: this.currentMaxValue })
    this.updateMainPlot()
  }

  // Reset to full range (called by Reset button)
  resetRange() {
    console.log('🎚️ Resetting range to full range')
    this.currentMinValue = this.minValue
    this.currentMaxValue = this.maxValue
    this.updateSliderUI()
    this.updateSelectedCellsCount()
    this.updateMainPlot()
    this.drawDensityPlot()
  }

  // Handle color range adaptation button click
  adaptColorRangeChanged() {
    console.log('🎨 adaptColorRangeChanged method called!')
    console.log('🎨 Has button target:', this.hasAdaptColorRangeButtonTarget)
    
    if (!this.hasAdaptColorRangeButtonTarget) {
      console.error('🎨 Button target not found!')
      return
    }
    
    // Toggle the state
    this.adaptColorRangeEnabled = !this.adaptColorRangeEnabled
    console.log('🎨 Color range adaptation changed:', this.adaptColorRangeEnabled ? 'enabled' : 'disabled')
    console.log('🎨 Current range:', { min: this.currentMinValue, max: this.currentMaxValue })
    
    // Update button appearance
    this.updateButtonAppearance()
    
    if (!this.visualizationController) {
      console.error('🎨 Visualization controller not found!')
      return
    }
    
    // Force a full re-render to update colors and legend
    this.visualizationController.visibilityOnlyUpdate = false
    
    // Update the color range with the new setting
    this.visualizationController.updateColorRange(
      this.metadataIdValue, 
      this.currentMinValue, 
      this.currentMaxValue,
      this.adaptColorRangeEnabled
    )
    
    // Trigger a full re-render of the plot and legend
    if (this.visualizationController.renderPointsWithCurrentColoring) {
      console.log('🎨 Triggering full plot re-render...')
      this.visualizationController.renderPointsWithCurrentColoring()
    }
    
    if (this.visualizationController.renderContinuousColorLegend) {
      console.log('🎨 Triggering legend re-render...')
      this.visualizationController.renderContinuousColorLegend()
    }
    
    console.log('🎨 Button click handling completed!')
  }

  // Update button appearance based on state
  updateButtonAppearance() {
    if (!this.hasAdaptColorRangeButtonTarget) {
      console.log('🎨 Button target not found for appearance update')
      return
    }
    
    const button = this.adaptColorRangeButtonTarget
    console.log('🎨 Updating button appearance, enabled:', this.adaptColorRangeEnabled)
    
    if (this.adaptColorRangeEnabled) {
      // Active state - green colors
      console.log('🎨 Setting green colors for active state')
      button.style.backgroundColor = '#f0fdf4'
      button.style.borderColor = '#86efac'
      button.style.color = '#16a34a'
      button.title = 'Color range adapted to selected range - Click to use full data range'
    } else {
      // Inactive state - grey colors
      console.log('🎨 Setting grey colors for inactive state')
      button.style.backgroundColor = '#f9fafb'
      button.style.borderColor = '#d1d5db'
      button.style.color = '#6b7280'
      button.title = 'Adapt color range to selected range - When enabled, the color legend will adjust to show the full range of selected values'
    }
    
    console.log('🎨 Button appearance updated:', {
      backgroundColor: button.style.backgroundColor,
      borderColor: button.style.borderColor,
      color: button.style.color
    })
  }
}
