// Range Slider Controller for inline range sliders
// This controller handles the range slider functionality for metadata filtering

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["track", "activeTrack", "minHandle", "maxHandle", "minInput", "maxInput", "selectedCount", "totalCount", "canvas"]
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
    
    // Get the main visualization controller
    this.visualizationController = window.visualizationController
    console.log('🎚️ Range slider controller connected, visualization controller:', !!this.visualizationController)
    
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
    
    // Update UI and trigger callbacks
    this.updateSliderUI()
    this.updateSelectedCellsCount()
    this.updateMainPlot()
    this.drawDensityPlot()
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

  // Update the main plot with the new range
  updateMainPlot() {
    if (!this.visualizationController) return
    
    // Update the color range in the main visualization
    if (this.visualizationController.updateColorRange) {
      this.visualizationController.updateColorRange(
        this.metadataIdValue, 
        this.currentMinValue, 
        this.currentMaxValue
      )
    }
    
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
      console.log('🎚️ Stored range in selectedRanges:', {
        metadataId: this.metadataIdValue,
        range: this.visualizationController.selectedRanges[this.metadataIdValue],
        allSelectedRanges: this.visualizationController.selectedRanges
      })
    }
    
    // Clear the filter cache and trigger a re-render with unified filtering
    if (this.visualizationController.filterCache) {
      this.visualizationController.filterCache.clear()
    }
    
    // Re-render with unified filtering
    if (this.visualizationController.renderPointsWithCurrentColoring) {
      this.visualizationController.renderPointsWithCurrentColoring()
    }
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
}
