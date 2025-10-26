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
    
    // Get the main visualization controller and its modules
    this.visualizationController = window.visualizationController
    this.dataManager = this.visualizationController?.dataManager
    this.rendererManager = this.visualizationController?.rendererManager
    console.log('🎚️ Range slider controller connected, visualization controller:', !!this.visualizationController)
    console.log('🎚️ Range slider controller connected, dataManager:', !!this.dataManager)
    console.log('🎚️ Range slider controller connected, rendererManager:', !!this.rendererManager)
    
    // Initialize button appearance
    this.updateButtonAppearance()
    
    // Don't initialize immediately - wait for values to be set by the main controller
    console.log('🎚️ Range slider controller ready, waiting for initialization')
  }

  disconnect() {
    // Clean up event listeners
    this.stopDrag()
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
    
    // Update checkbox color based on whether it's a subrange
    this.updateCheckboxColor()
  }
  
  // Update checkbox color: green if full range, orange if subrange
  updateCheckboxColor() {
    const checkbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${this.metadataIdValue}"]`)
    if (!checkbox) return
    
    // Check if current range is the full range (with small tolerance for floating point)
    const tolerance = (this.maxValue - this.minValue) * 0.001 // 0.1% tolerance
    const isFullRange = Math.abs(this.currentMinValue - this.minValue) < tolerance && 
                        Math.abs(this.currentMaxValue - this.maxValue) < tolerance
    
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
      console.log('🎚️ No slider data available for count update')
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
    
    console.log('🎚️ Updating selected count:', {
      selectedByRangeCount,
      selectedByAllFiltersCount,
      currentMin: this.currentMinValue,
      currentMax: this.currentMaxValue,
      totalValues: sliderData.values.length,
      hasOtherFilters: selectedByRangeCount !== selectedByAllFiltersCount
    })
    
    // Show count with visual indicator if other filters are active
    if (selectedByRangeCount > selectedByAllFiltersCount) {
      // Other filters are reducing the count - show both counts in red
      this.selectedCountTarget.textContent = selectedByAllFiltersCount.toLocaleString()
      this.selectedCountTarget.style.color = '#dc2626'
      this.selectedCountTarget.style.fontWeight = '600'
      this.selectedCountTarget.title = `${selectedByAllFiltersCount.toLocaleString()} cells (${selectedByRangeCount.toLocaleString()} in range, but ${selectedByRangeCount - selectedByAllFiltersCount} filtered out by other metadata)`
    } else {
      // No other filters active
      this.selectedCountTarget.textContent = selectedByAllFiltersCount.toLocaleString()
      this.selectedCountTarget.style.color = '#6b7280'
      this.selectedCountTarget.style.fontWeight = '500'
      this.selectedCountTarget.title = `${selectedByAllFiltersCount.toLocaleString()} cells selected by range`
    }
    
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
    if (!this.visualizationController || !this.dataManager) return
    
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
    
    // Trigger unified filtering (which will update ALL counts and render)
    const filterStart = performance.now()
    if (this.dataManager.updateCellFiltering) {
      // Pass shouldUpdateColors=true if we're adapting the color range
      const shouldUpdateColors = this.adaptColorRangeEnabled
      this.dataManager.updateCellFiltering(shouldUpdateColors)
    }
    const filterTime = performance.now() - filterStart
    console.log(`🚀 [PERF] updateCellFiltering took ${filterTime.toFixed(2)}ms`)
    
    // Only update the color legend if we're adapting the color range
    // (otherwise the legend doesn't change, so no need to redraw)
    if (this.adaptColorRangeEnabled) {
      const legendStart = performance.now()
      if (this.rendererManager.renderContinuousColorLegendCanvas2D) {
        this.rendererManager.renderContinuousColorLegendCanvas2D()
      }
      const legendTime = performance.now() - legendStart
      console.log(`🚀 [PERF] renderContinuousColorLegend took ${legendTime.toFixed(2)}ms`)
    } else {
      console.log(`🚀 [PERF] Skipping legend update (adapt range not enabled)`)
    }
    
    const totalTime = performance.now() - startTime
    console.log(`🚀 [PERF] performPlotUpdate completed in ${totalTime.toFixed(2)}ms for metadata:`, this.metadataIdValue)
  }

  // Draw the density plot
  drawDensityPlot() {
    console.log('🎨 drawDensityPlot called for metadata:', this.metadataIdValue)
    console.log('🎨 hasCanvasTarget:', this.hasCanvasTarget)
    
    if (!this.hasCanvasTarget) {
      console.log('🎨 No canvas target, returning')
      return
    }
    
    const sliderData = this.visualizationController?.inlineRangeSliderData?.[this.metadataIdValue]
    console.log('🎨 Slider data available:', !!sliderData)
    console.log('🎨 Values available:', !!sliderData?.values)
    console.log('🎨 inlineRangeSliderData keys:', Object.keys(this.visualizationController?.inlineRangeSliderData || {}))
    
    if (!sliderData || !sliderData.values) {
      console.log('🎨 No slider data or values, returning')
      return
    }
    
    console.log('🎨 Drawing density plot with', sliderData.values.length, 'values')
    
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
    
    // Clear stored canvas data for tooltip
    this.originalCanvasData = null
    
    // Define margins for axis titles
    const leftMargin = 30
    const bottomMargin = 25
    const topMargin = 10
    const rightMargin = 10
    
    // Calculate plot area
    const plotWidth = rect.width - leftMargin - rightMargin
    const plotHeight = rect.height - topMargin - bottomMargin
    
    // Create histogram
    const numBins = 50
    const binWidth = (this.maxValue - this.minValue) / numBins
    const bins = new Array(numBins).fill(0)
    
    sliderData.values.forEach(value => {
      const binIndex = Math.min(Math.floor((value - this.minValue) / binWidth), numBins - 1)
      bins[binIndex]++
    })
    
    const maxCount = this.safeMax(bins)
    const barWidth = plotWidth / numBins
    
    // Store bin data for hover tooltip
    this.binData = bins.map((count, i) => ({
      count,
      density: (count / sliderData.values.length) * 100,
      range: {
        min: this.minValue + i * binWidth,
        max: this.minValue + (i + 1) * binWidth
      },
      x: leftMargin + i * barWidth,
      y: topMargin + plotHeight - (count / maxCount) * plotHeight,
      width: barWidth - 1,
      height: (count / maxCount) * plotHeight
    }))
    
    // Draw bars
    ctx.fillStyle = '#e0e0e0'
    this.binData.forEach((bin, i) => {
      ctx.fillRect(bin.x, bin.y, bin.width, bin.height)
    })
    
    // Draw range selection overlay
    const range = this.maxValue - this.minValue
    const minPercent = (this.currentMinValue - this.minValue) / range
    const maxPercent = (this.currentMaxValue - this.minValue) / range
    
    ctx.fillStyle = 'rgba(0, 123, 255, 0.3)'
    const overlayX = leftMargin + minPercent * plotWidth
    const overlayWidth = (maxPercent - minPercent) * plotWidth
    ctx.fillRect(overlayX, topMargin, overlayWidth, plotHeight)
    
    // Draw axis titles
    ctx.fillStyle = '#374151'
    ctx.font = '11px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    
    // X-axis title (bottom) - moved closer to axis
    const xAxisTitle = 'Value bins'
    ctx.fillText(xAxisTitle, rect.width / 2, rect.height - 15)
    
    // Y-axis title (left side, rotated) - moved up
    ctx.save()
    ctx.translate(15, rect.height / 2 - 10)
    ctx.rotate(-Math.PI / 2)
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
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
    
    // Tooltip content
    const rangeText = `${bin.range.min.toFixed(3)} - ${bin.range.max.toFixed(3)}`
    const densityText = `${bin.density.toFixed(1)}%`
    
    // Calculate tooltip position (top right corner of plot)
    const tooltipX = rect.width - 10
    const tooltipY = 10
    
    // Draw tooltip background
    ctx.fillStyle = 'rgba(0, 0, 0, 0.8)'
    ctx.fillRect(tooltipX - 80, tooltipY, 80, 40)
    
    // Draw tooltip text
    ctx.fillStyle = 'white'
    ctx.font = '10px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
    ctx.textAlign = 'right'
    ctx.textBaseline = 'top'
    
    ctx.fillText(rangeText, tooltipX - 5, tooltipY + 5)
    ctx.fillText(densityText, tooltipX - 5, tooltipY + 20)
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
    
    console.log('🎨 After updateButtonAppearance, checking visualization controller...')
    
    if (!this.visualizationController) {
      console.error('🎨 Visualization controller not found!')
      return
    }
    
    console.log('🎨 Visualization controller found, proceeding with re-render')
    
    // Force a full re-render to update colors and legend
    this.visualizationController.visibilityOnlyUpdate = false
    console.log('🎨 Set visibilityOnlyUpdate to false')
    
    // Calculate the effective range based on visible cells when adapt is enabled
    let effectiveMin = this.currentMinValue
    let effectiveMax = this.currentMaxValue
    
    if (this.adaptColorRangeEnabled) {
      // Get the metadata vector and calculate range from visible cells only
      const metadataVector = this.visualizationController.getMetadataVectorById(this.metadataIdValue)
      if (metadataVector && metadataVector.values) {
        const visibleCells = this.visualizationController.currentVisibleCells
        
        if (visibleCells && visibleCells.length > 0) {
          // Calculate min/max from visible cells only
          let minVal = Infinity
          let maxVal = -Infinity
          
          for (let i = 0; i < visibleCells.length; i++) {
            const cellIndex = visibleCells[i]
            const value = metadataVector.values[cellIndex]
            if (!isNaN(value)) {
              if (value < minVal) minVal = value
              if (value > maxVal) maxVal = value
            }
          }
          
          if (minVal !== Infinity && maxVal !== -Infinity) {
            effectiveMin = minVal
            effectiveMax = maxVal
            console.log('🎨 Adapted color range to visible cells:', { min: effectiveMin, max: effectiveMax })
            
            // Update the slider to show the new range
            this.currentMinValue = effectiveMin
            this.currentMaxValue = effectiveMax
            this.updateSliderUI()
            this.updateSelectedCellsCount()
          }
        } else {
          console.log('🎨 No filtering applied, using full data range')
          // Use the full data range when no filtering is applied
          effectiveMin = this.minValue
          effectiveMax = this.maxValue
          
          // Update the slider to show the full range
          this.currentMinValue = effectiveMin
          this.currentMaxValue = effectiveMax
          this.updateSliderUI()
          this.updateSelectedCellsCount()
        }
      }
    }
    
    // Update the color range with the new setting
    console.log('🎨 Calling updateColorRange with:', {
      metadataId: this.metadataIdValue,
      min: effectiveMin,
      max: effectiveMax,
      adapt: this.adaptColorRangeEnabled
    })
    this.visualizationController.updateColorRange(
      this.metadataIdValue, 
      effectiveMin, 
      effectiveMax,
      this.adaptColorRangeEnabled
    )
    console.log('🎨 updateColorRange completed')
    
    // Trigger a full re-render of the plot and legend
    console.log('🎨 About to trigger re-render, method exists?', !!this.visualizationController.renderPointsWithCurrentColoring)
    if (this.visualizationController.renderPointsWithCurrentColoring) {
      console.log('🎨 Triggering full plot re-render...')
      try {
        this.visualizationController.renderPointsWithCurrentColoring()
        console.log('🎨 Plot re-render completed')
      } catch (error) {
        console.error('🎨 ERROR during plot re-render:', error)
        console.error('🎨 Error stack:', error.stack)
      }
    } else {
      console.error('🎨 renderPointsWithCurrentColoring method not found!')
    }
    
    console.log('🎨 About to trigger legend re-render, method exists?', !!this.rendererManager.renderContinuousColorLegendCanvas2D)
    if (this.rendererManager.renderContinuousColorLegendCanvas2D) {
      console.log('🎨 Triggering legend re-render...')
      this.rendererManager.renderContinuousColorLegendCanvas2D()
      console.log('🎨 Legend re-render completed')
    } else {
      console.error('🎨 renderContinuousColorLegend method not found!')
    }
    
    // Redraw the histogram to reflect the new range
    this.drawDensityPlot()
    
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
