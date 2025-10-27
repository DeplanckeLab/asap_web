/**
 * Renderer Manager Module
 * Handles rendering coordination between ReGL and Canvas 2D
 */

import { ReglRenderer } from "visualization/regl_renderer"

export class RendererManager {
  constructor(controller) {
    this.controller = controller
  }

  // Main rendering methods
  initializeScatterPlot(coordinates) {
    return this.controller.initializeScatterPlot(coordinates)
  }

  renderPointsWithCurrentColoringInContainer(container) {
    return this.controller.renderPointsWithCurrentColoringInContainer(container)
  }

  // Axes and grid rendering
  renderAxes() {
    if (!this.controller.overlayCtx || !this.controller.overlayCanvas || !this.controller.currentBounds) return
    
    // Check if axes should be visible
    const axesCheckbox = document.getElementById('show-axes-checkbox')
    if (!axesCheckbox || !axesCheckbox.checked) return
    
    const ctx = this.controller.overlayCtx
    const { minX, maxX, minY, maxY } = this.controller.currentBounds
    const width = this.controller.overlayCanvas.width
    const height = this.controller.overlayCanvas.height
    const margins = this.getPlotMargins()
    
    const xAxisY = height - margins.bottom
    const yAxisX = margins.left
    
    // Draw white rectangles to cover margin areas (below x-axis and left of y-axis)
    ctx.fillStyle = '#ffffff'
    
    // Rectangle below x-axis (covers bottom margin)
    ctx.fillRect(0, xAxisY, width, height - xAxisY)
    
    // Rectangle left of y-axis (covers left margin)
    ctx.fillRect(0, 0, yAxisX, height)
    
    // Draw axes lines
    ctx.strokeStyle = '#333333'
    ctx.lineWidth = 2
    ctx.globalAlpha = 0.8
    
    // X-axis
    ctx.beginPath()
    ctx.moveTo(margins.left, xAxisY)
    ctx.lineTo(width - margins.right, xAxisY)
    ctx.stroke()
    
    // Y-axis
    ctx.beginPath()
    ctx.moveTo(yAxisX, margins.top)
    ctx.lineTo(yAxisX, height - margins.bottom)
    ctx.stroke()
    
    ctx.globalAlpha = 1.0
    
    // Add tick marks and labels
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    ctx.fillStyle = '#333333'
    ctx.strokeStyle = '#333333'
    ctx.font = '12px Arial'
    
    // X-axis ticks
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let value = xStart; value <= xEnd; value += xTickSpacing) {
      const screenX = margins.left + ((value - minX) / xRange) * (width - margins.left - margins.right)
      
      // Tick mark
      ctx.beginPath()
      ctx.moveTo(screenX, xAxisY)
      ctx.lineTo(screenX, xAxisY + 5)
      ctx.stroke()
      
      // Label
      ctx.fillText(value.toFixed(1), screenX, xAxisY + 10)
    }
    
    // Y-axis ticks
    ctx.textAlign = 'right'
    ctx.textBaseline = 'middle'
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const screenY = height - margins.bottom - ((value - minY) / yRange) * (height - margins.top - margins.bottom)
      
      // Tick mark
      ctx.beginPath()
      ctx.moveTo(yAxisX - 5, screenY)
      ctx.lineTo(yAxisX, screenY)
      ctx.stroke()
      
      // Label
      ctx.fillText(value.toFixed(1), yAxisX - 7, screenY)
    }
    
    // Add axis titles
    ctx.fillStyle = '#333333'
    ctx.font = '14px Arial'
    
    // X-axis title
    ctx.textAlign = 'center'
    ctx.textBaseline = 'bottom'
    ctx.fillText('Dimension 1', width / 2, height - 15)
    
    // Y-axis title (rotated)
    ctx.save()
    ctx.translate(15, height / 2)
    ctx.rotate(-Math.PI / 2)
    ctx.textAlign = 'center'
    ctx.textBaseline = 'bottom'
    ctx.fillText('Dimension 2', 0, 0)
    ctx.restore()
  }

  renderAxesCanvas2D() {
    this.renderAxes()
  }

  renderGrid() {
    if (!this.controller.overlayCtx || !this.controller.overlayCanvas || !this.controller.currentBounds) return
    
    // Clear canvas first
    this.controller.overlayCtx.clearRect(0, 0, this.controller.overlayCanvas.width, this.controller.overlayCanvas.height)
    
    // Check if grid should be visible
    const gridCheckbox = document.getElementById('show-grid-checkbox')
    const shouldDrawGrid = gridCheckbox && gridCheckbox.checked
    
    const ctx = this.controller.overlayCtx
    const { minX, maxX, minY, maxY } = this.controller.currentBounds
    const width = this.controller.overlayCanvas.width
    const height = this.controller.overlayCanvas.height
    const margins = this.getPlotMargins()
    
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    // Only draw grid if checkbox is checked
    if (shouldDrawGrid) {
      ctx.strokeStyle = 'rgba(204, 204, 204, 0.3)'
      ctx.lineWidth = 1
      
      // Vertical grid lines
      const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
      const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
      for (let value = xStart; value <= xEnd; value += xTickSpacing) {
        const t = (value - minX) / xRange
        const x = margins.left + t * (width - margins.left - margins.right)
        if (x >= margins.left && x <= width - margins.right) {
          ctx.beginPath()
          ctx.moveTo(x, margins.top)
          ctx.lineTo(x, height - margins.bottom)
          ctx.stroke()
        }
      }
      
      // Horizontal grid lines
      const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
      const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
      for (let value = yStart; value <= yEnd; value += yTickSpacing) {
        const t = (value - minY) / yRange
        const y = margins.top + (height - margins.top - margins.bottom) - t * (height - margins.top - margins.bottom)
        if (y >= margins.top && y <= height - margins.bottom) {
          ctx.beginPath()
          ctx.moveTo(margins.left, y)
          ctx.lineTo(width - margins.right, y)
          ctx.stroke()
        }
      }
    }
    
    // Always redraw axes and category labels after clearing
    this.renderAxes()
    this.renderCategoryLabels()
  }
  // Render continuous color legend using Canvas 2D (ReGL mode)
  renderContinuousColorLegendCanvas2D() {
    const startTime = performance.now()
    console.log('🎨 [Canvas2D] Rendering continuous color legend START')
    
    if (!this.controller.overlayCtx || !this.controller.currentBounds || !this.controller.currentMetadataVector || !this.controller.currentCoordinates) {
      console.log('🎨 [Canvas2D] Missing required components for continuous legend')
      return
    }

    // Only render legend for continuous metadata
    if (this.controller.currentMetadataVector.data_type !== 'NUMERIC') {
      console.log('🎨 [Canvas2D] Not numeric metadata, skipping legend')
      return
    }

    // During panning, don't update legend
    if (this.controller.isPanning) {
      console.log('🎨 [Canvas2D] Skipping legend updates during panning')
      return
    }

    // Redraw the entire overlay (grid, axes, legend) to ensure the old legend is cleared
    // This is necessary when the color range is adapted
    console.log('🎨 [Canvas2D] Redrawing full overlay (grid + axes + legend)')
    this.renderGrid() // Clears the canvas
    this.renderAxes() // Draw axes

    const ctx = this.controller.overlayCtx
    const width = this.controller.overlayCanvas.width
    const height = this.controller.overlayCanvas.height

    // Get metadata values and effective color range
    const values = this.controller.currentMetadataVector.values
    const effectiveRange = this.controller.getEffectiveColorRange()
    const minVal = effectiveRange.min
    const maxVal = effectiveRange.max
    console.log('🎨 [Canvas2D] Effective range:', { minVal, maxVal })

    // Legend dimensions
    const margins = this.getPlotMargins()
    const legendWidth = 200
    const legendHeight = 20
    const padding = 10
    const legendX = width - legendWidth - margins.right - 10 // Position on right side
    const legendY = margins.top + 10 // Position at top
    
    // Calculate background dimensions (includes padding for title and labels)
    const bgX = legendX - padding
    const bgY = legendY - 25 // Account for title above
    const bgWidth = legendWidth + (padding * 2)
    const bgHeight = legendHeight + 40 // Account for title above and labels below
    
    // Store legend bounds for click and hover detection
    this.controller.gradientLegendBounds = {
      x: bgX,
      y: bgY,
      width: bgWidth,
      height: bgHeight
    }
    
    // Draw semi-transparent background (changes color on hover)
    ctx.save()
    if (this.controller.isHoveringGradientLegend) {
      // Light blue when hovering
      ctx.fillStyle = 'rgba(224, 242, 254, 0.9)' // Light blue (#e0f2fe)
      ctx.strokeStyle = 'rgba(125, 211, 252, 0.8)' // Light blue border
    } else {
      // Semi-transparent white normally
      ctx.fillStyle = 'rgba(255, 255, 255, 0.9)'
      ctx.strokeStyle = 'rgba(200, 200, 200, 0.6)'
    }
    ctx.fillRect(bgX, bgY, bgWidth, bgHeight)
    
    // Add border to the background
    ctx.lineWidth = 1
    ctx.strokeRect(bgX, bgY, bgWidth, bgHeight)
    ctx.restore()

    // Draw metadata name label above the legend
    ctx.save()
    ctx.font = 'bold 12px Arial'
    ctx.fillStyle = '#333333'
    ctx.textAlign = 'left'
    ctx.textBaseline = 'bottom'
    ctx.fillText(this.controller.currentMetadataVector.name, legendX, legendY - 5)
    ctx.restore()

    // Draw color gradient bar
    const numSteps = 100
    
    for (let i = 0; i < numSteps; i++) {
      const normalizedValue = i / (numSteps - 1)
      const color = this.controller.gradientManager.getColorFromGradient(normalizedValue)
      
      // Convert color integer to RGB
      const r = (color >> 16) & 0xFF
      const g = (color >> 8) & 0xFF
      const b = color & 0xFF
      
      const stepX = legendX + (i * legendWidth / numSteps)
      const stepWidth = Math.ceil(legendWidth / numSteps) + 1 // Add 1 to avoid gaps
      
      ctx.fillStyle = `rgb(${r}, ${g}, ${b})`
      ctx.fillRect(stepX, legendY, stepWidth, legendHeight)
    }

    // Draw border around gradient bar
    ctx.strokeStyle = '#333333'
    ctx.lineWidth = 1
    ctx.strokeRect(legendX, legendY, legendWidth, legendHeight)

    // Draw min/max value labels
    ctx.save()
    ctx.font = '10px Arial'
    ctx.fillStyle = '#333333'
    
    // Min label (left-aligned)
    ctx.textAlign = 'left'
    ctx.textBaseline = 'top'
    ctx.fillText(minVal.toFixed(2), legendX, legendY + legendHeight + 5)
    
    // Max label (right-aligned)
    ctx.textAlign = 'right'
    ctx.fillText(maxVal.toFixed(2), legendX + legendWidth, legendY + legendHeight + 5)
    
    ctx.restore()

    const totalTime = performance.now() - startTime
    console.log(`🎨 [Canvas2D] Continuous color legend rendered in ${totalTime.toFixed(2)}ms`)
  }

  renderGridCanvas2D() {
    // This method should be implemented in the RendererManager
    // For now, we'll delegate to the controller's renderGrid method
    this.renderGrid()
  }

  // Category labels and legends
  renderCategoryLabels() {
    console.log('🏷️ [Canvas2D] renderCategoryLabelsCanvas2D called')
    
    if (!this.controller.overlayCtx || !this.controller.overlayCanvas || !this.controller.currentBounds || !this.controller.currentMetadataVector || !this.controller.currentCoordinates) {
      console.log('🏷️ [Canvas2D] Missing required components')
      return
    }
    
    // Only render labels for discrete metadata
    if (this.controller.currentMetadataVector.data_type !== 'DISCRETE') {
      console.log('🏷️ [Canvas2D] Not discrete metadata, skipping (checkbox can still be toggled for when categorical metadata is selected)')
      return
    }
    
    // Check if the user wants to see category labels
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')
    const shouldShowLabels = categoriesCheckbox ? categoriesCheckbox.checked : false
    
    console.log(`🏷️ [Canvas2D] Category labels checkbox state: ${shouldShowLabels}`)
    
    if (!shouldShowLabels) {
      console.log('🏷️ [Canvas2D] Category labels hidden by user preference')
      // Clear stored labels when hidden
      this.controller.canvas2DLabels = []
      return
    }
    
    // Initialize labels array if not exists
    if (!this.controller.canvas2DLabels) {
      this.controller.canvas2DLabels = []
    }
    
    const ctx = this.controller.overlayCtx
    const width = this.controller.overlayCanvas.width
    const height = this.controller.overlayCanvas.height
    
    // Get the metadata values and categories
    const values = this.controller.currentMetadataVector.values
    const categories = this.controller.currentMetadataVector.categories
    
    // If categories is undefined, try to get unique values from the values array
    let categoryList = categories
    if (!categoryList || categoryList.length === 0) {
      categoryList = [...new Set(values)]
    }
    
    console.log(`🏷️ [Canvas2D] Found ${categoryList.length} categories`)
    console.log(`🏷️ [Canvas2D] Current bounds:`, this.controller.currentBounds)
    console.log(`🏷️ [Canvas2D] Canvas dimensions: ${width}x${height}`)
    
    // Calculate centroids
    const centroids = this.controller.dataManager.calculateCategoryCentroids(values, categoryList)
    
    console.log(`🏷️ [Canvas2D] Calculated ${Object.keys(centroids).length} centroids`)
    
    // Get category colors using the same logic as plot dots for consistency
    // Use DOM order (same as legend) for consistent color assignment
    const domOrderCategories = this.controller.getCategoriesForMetadata(this.controller.currentMetadataVector.id)
    let colorMap = {}
    
    if (domOrderCategories && domOrderCategories.length > 0) {
      const categoryNames = domOrderCategories.map(cat => cat.name)
      colorMap = this.controller.colorManager.createDiscreteColorMap(categoryNames, this.controller.currentMetadataVector.id)
    } else {
      // Fallback to original categories if DOM not available
      const uniqueCategories = [...new Set(values)]
      colorMap = this.controller.colorManager.createDiscreteColorMap(uniqueCategories, this.controller.currentMetadataVector.id)
    }
    
    // Clear old labels array for this rendering
    const newLabels = []
    
    // Render labels for each category
    let labelsDrawn = 0
    let labelsSkipped = 0
    Object.entries(centroids).forEach(([category, centroid]) => {
      if (centroid.count > 0) {
        // Calculate default screen position from centroid
        let screenX = this.controller.interactionHandler.normalizeX(centroid.x, this.controller.currentBounds)
        let screenY = this.controller.interactionHandler.normalizeY(centroid.y, this.controller.currentBounds)
        
        // Check if this label was previously dragged (has offset)
        const existingLabel = this.controller.canvas2DLabels.find(l => l.category === category)
        if (existingLabel && existingLabel.offsetX !== undefined && existingLabel.offsetY !== undefined) {
          // Apply the drag offset to the centroid position
          console.log(`🏷️ [Canvas2D] Found existing label for "${category}" with offset (${existingLabel.offsetX}, ${existingLabel.offsetY})`)
          screenX += existingLabel.offsetX
          screenY += existingLabel.offsetY
        }
        
        console.log(`🏷️ [Canvas2D] Category "${category}": data coords (${centroid.x.toFixed(2)}, ${centroid.y.toFixed(2)}) -> screen coords (${screenX.toFixed(0)}, ${screenY.toFixed(0)})`)
        
        // Skip if outside visible area
        const margins = this.getPlotMargins()
        const margin = Math.max(margins.left, margins.right, margins.top, margins.bottom)
        const isOffScreen = screenX < -margin || screenX > width + margin || screenY < -margin || screenY > height + margin
        if (isOffScreen) {
          console.log(`🏷️ [Canvas2D] Category "${category}" is off-screen (width: ${width}, height: ${height}, margin: ${margin})`)
          labelsSkipped++
          return
        }
        
        // Get category color from the same color map used by plot dots
        const colorValue = colorMap[category] || 0x3b82f6 // Default blue if not found
        
        // Convert color to RGB for canvas
        let r, g, b
        if (typeof colorValue === 'string') {
          const hex = colorValue.replace('#', '')
          r = parseInt(hex.substr(0, 2), 16)
          g = parseInt(hex.substr(2, 2), 16)
          b = parseInt(hex.substr(4, 2), 16)
        } else {
          r = (colorValue >> 16) & 0xFF
          g = (colorValue >> 8) & 0xFF
          b = colorValue & 0xFF
        }
        
        // Draw label with background
        ctx.save()
        
        // Measure text for background sizing
        ctx.font = '12px Arial'
        const text = category
        const textMetrics = ctx.measureText(text)
        const textWidth = textMetrics.width
        const textHeight = 14
        const padding = 4
        
        // Draw white background with border
        ctx.fillStyle = 'rgba(255, 255, 255, 0.9)'
        ctx.strokeStyle = `rgb(${r}, ${g}, ${b})`
        ctx.lineWidth = 2
        
        const bgX = screenX - textWidth / 2 - padding
        const bgY = screenY - textHeight / 2 - padding
        const bgWidth = textWidth + padding * 2
        const bgHeight = textHeight + padding * 2
        
        ctx.fillRect(bgX, bgY, bgWidth, bgHeight)
        ctx.strokeRect(bgX, bgY, bgWidth, bgHeight)
        
        // Draw text
        ctx.fillStyle = '#333333'
        ctx.textAlign = 'center'
        ctx.textBaseline = 'middle'
        ctx.fillText(text, screenX, screenY)
        
        ctx.restore()
        
        // Store label bounds for hit testing and dragging
        newLabels.push({
          category: category,
          x: screenX,
          y: screenY,
          bounds: {
            x: bgX,
            y: bgY,
            width: bgWidth,
            height: bgHeight
          },
          centroidX: centroid.x,
          centroidY: centroid.y,
          offsetX: existingLabel ? existingLabel.offsetX || 0 : 0,
          offsetY: existingLabel ? existingLabel.offsetY || 0 : 0,
          color: { r, g, b }
        })
        
        labelsDrawn++
      }
    })
    
    // Update stored labels
    this.controller.canvas2DLabels = newLabels
    
    // If we're currently dragging a label, update the reference to point to the new label object
    if (this.controller.draggingLabel) {
      const newDraggingLabel = newLabels.find(l => l.category === this.controller.draggingLabel.category)
      if (newDraggingLabel) {
        console.log(`🏷️ [Canvas2D] Updated dragging label reference for "${this.controller.draggingLabel.category}"`)
        this.controller.draggingLabel = newDraggingLabel
      }
    }
    
    console.log(`🏷️ [Canvas2D] Drew ${labelsDrawn} category labels (${labelsSkipped} skipped as off-screen)`)
  }

  renderContinuousColorLegend() {
    return this.controller.renderContinuousColorLegend()
  }

  // Point visibility and filtering
  updatePointVisibility(filteredIndices) {
    return this.controller.updatePointVisibility(filteredIndices)
  }

  updatePointVisibilityReGL(filteredIndices) {
    return this.controller.updatePointVisibilityReGL(filteredIndices)
  }

  // Color updates
  updateSelectedPointColors() {
    return this.controller.updateSelectedPointColors()
  }

  // Coordinate transformations
  translatePointsForZoom(oldBounds, newBounds, mouseX, mouseY) {
    return this.controller.translatePointsForZoom(oldBounds, newBounds, mouseX, mouseY)
  }

  // Reordering for category display
  reorderPointsForCategoryDisplay() {
    return this.controller.reorderPointsForCategoryDisplay()
  }

  reorderPointsForNumericDisplay() {
    return this.controller.reorderPointsForNumericDisplay()
  }

  // Tick calculation utilities
  calculateTickSpacing(range) {
    return this.controller.calculateTickSpacing(range)
  }

  formatTickValue(value) {
    return this.controller.formatTickValue(value)
  }

  // SVG export
  generateSVGFromPlotReGL() {
    return this.controller.generateSVGFromPlotReGL()
  }

  generateSVGFromPlotPixi() {
    return this.controller.generateSVGFromPlotPixi()
  }

  // Point counting
  countVisiblePoints(bounds) {
    return this.controller.countVisiblePoints(bounds)
  }

  // Utility methods for rendering
  getPlotMargins() {
    return {
      left: 60,    // Space for Y-axis labels
      right: 20,   // Right margin
      top: 20,      // Minimal top margin
      bottom: 60   // Space for X-axis labels and title (increased to 50)
    }
  }

  // Get bounds adjusted for axes margins
  getAdjustedBounds(originalBounds) {
    if (!originalBounds || !this.controller.canvas) {
      return originalBounds
    }

    const { minX, maxX, minY, maxY } = originalBounds
    const width = this.controller.canvas.width
    const height = this.controller.canvas.height
    const margins = this.getPlotMargins()

    // Calculate the data range that fits in the available space
    const availableWidth = width - margins.left - margins.right
    const availableHeight = height - margins.top - margins.bottom

    // Calculate the data range per pixel
    const dataWidth = maxX - minX
    const dataHeight = maxY - minY
    const dataPerPixelX = dataWidth / availableWidth
    const dataPerPixelY = dataHeight / availableHeight

    // Adjust bounds to account for margins
    // Note: Y-axis is inverted, so maxY appears at top, minY at bottom
    const adjustedMinX = minX - (margins.left * dataPerPixelX)
    const adjustedMaxX = maxX + (margins.right * dataPerPixelX)
    const adjustedMinY = minY - (margins.bottom * dataPerPixelY)  // Bottom of plot (X-axis labels)
    const adjustedMaxY = maxY + (margins.top * dataPerPixelY)     // Top of plot (minimal space)

    const adjustedBounds = {
      minX: adjustedMinX,
      maxX: adjustedMaxX,
      minY: adjustedMinY,
      maxY: adjustedMaxY
    }
    
    return adjustedBounds
  }

  calculateTickSpacing(range) {
    // Target about 5-8 ticks per axis
    const targetTicks = 6
    const roughSpacing = range / targetTicks
    
    // Find nice round numbers
    const magnitude = Math.pow(10, Math.floor(Math.log10(roughSpacing)))
    const normalized = roughSpacing / magnitude
    
    let niceSpacing
    if (normalized <= 1) {
      niceSpacing = 1
    } else if (normalized <= 2) {
      niceSpacing = 2
    } else if (normalized <= 5) {
      niceSpacing = 5
    } else {
      niceSpacing = 10
    }
    
    return niceSpacing * magnitude
  }

  // Point size management
  updateAllPointSizes(newSize) {
    console.log(`⏱️ [PERF] Updating point size to ${newSize}`)
    const updateStart = performance.now()
    
    // Update the current point size
    this.controller.currentPointSize = newSize
    
    // Update ReGL renderer if available
    if (this.controller.reglRenderer) {
      this.controller.reglRenderer.updatePointSize(newSize)
    }
    
    const updateEnd = performance.now()
    const updateTime = updateEnd - updateStart
    console.log(`⏱️ [PERF] Point size update completed in ${updateTime.toFixed(2)}ms`)
  }

  // Initialize scatter plot with coordinates
  async initializeScatterPlot(coordinates) {
    try {
      
      console.log(`⏱️ [PERF] Step 3: Creating new ${this.controller.rendererType.toUpperCase()} renderer (SLOW PATH - first render)`)
      
      // Clear existing renderers

      if (this.controller.reglRenderer) {
        this.controller.reglRenderer.destroy()
        this.controller.reglRenderer = null
      }
      
      // Reset canvas listeners flag so they get reattached to the new canvas
      this.controller.canvasListenersSetup = false
      
      // Find the plot container
      const plotContainer = document.querySelector('.plot-container')
      if (!plotContainer) {
        console.error('Plot container not found')
        return
      }
      
      // Clear plot container
      plotContainer.innerHTML = ''
      
        // ===== ReGL RENDERER =====
        console.log('🎯 Initializing ReGL renderer for WebGL performance')
        
        // Ensure container is positioned for absolute children
        plotContainer.style.position = 'relative'
        
        // Create ReGL canvas for points (layer 1)
        const canvas = document.createElement('canvas')
        canvas.width = plotContainer.clientWidth
        canvas.height = plotContainer.clientHeight
        canvas.style.width = '100%'
        canvas.style.height = '100%'
        canvas.style.position = 'absolute'
        canvas.style.top = '0'
        canvas.style.left = '0'
        canvas.style.zIndex = '1' // Bottom layer
        plotContainer.appendChild(canvas)
        
        console.log('🔍 DEBUG: Canvas dimensions:', {
          width: canvas.width,
          height: canvas.height,
          clientWidth: plotContainer.clientWidth,
          clientHeight: plotContainer.clientHeight,
          containerVisible: plotContainer.offsetWidth > 0 && plotContainer.offsetHeight > 0
        })
        
        // Initialize ReGL renderer
        this.controller.reglRenderer = new ReglRenderer(canvas)
        this.controller.canvas = canvas
        
        console.log('ReGL canvas added to container:', canvas)
        
        // Setup interaction system now that canvas exists
        this.controller.interactionHandler.setupInteractionSystem()
        
        // Create HTML Canvas 2D overlay for axes/grid/labels
        // (Simple and efficient - no need for PixiJS!)
        const overlayCanvas = document.createElement('canvas')
        overlayCanvas.width = plotContainer.clientWidth
        overlayCanvas.height = plotContainer.clientHeight
        overlayCanvas.style.width = '100%'
        overlayCanvas.style.height = '100%'
        overlayCanvas.style.position = 'absolute'
        overlayCanvas.style.top = '0'
        overlayCanvas.style.left = '0'
        overlayCanvas.style.zIndex = '2' // Top layer
        overlayCanvas.style.pointerEvents = 'none' // Let events pass through
        plotContainer.appendChild(overlayCanvas)
        
        this.controller.overlayCanvas = overlayCanvas
        this.controller.overlayCtx = overlayCanvas.getContext('2d')
        
        // Store PIXI reference for compatibility (but don't create app)
        this.controller.PIXI = PIXI
        this.controller.pixiApp = null // No PixiJS app in ReGL mode
        
        console.log('✅ Canvas 2D overlay created for UI elements (axes/grid/labels)')
        console.log('📊 Canvas 2D overlay details:', {
          width: overlayCanvas.width,
          height: overlayCanvas.height,
          zIndex: overlayCanvas.style.zIndex,
          pointerEvents: overlayCanvas.style.pointerEvents
        })
        
    
        // ReGL mode: No PixiJS containers needed, using Canvas 2D overlay
        this.controller.scatterContainer = { children: [] } // Dummy for compatibility
        this.controller.gridContainer = null
        this.controller.categoryLabelsContainer = null
        this.controller.axesContainer = null
        console.log(`✅ ReGL mode - using Canvas 2D overlay (no PixiJS containers)`)
      

      // Store current loom file
      this.controller.currentLoomFile = this.controller.loomFileSelectTarget.value
      
      // Render the scatter plot
      await this.controller.renderScatterPlot(coordinates)
      
    } catch (error) {
      console.error('Error initializing scatter plot:', error)
      throw error
    }
  }

  // Render modal gradient preview
  renderModalGradientPreview() {
    // This method should render the gradient preview in the modal
    // For now, just log that it was called
    console.log('🎨 Rendering modal gradient preview')
  }

  // Render modal control point markers
  renderModalControlPointMarkers() {
    // This method should render control point markers in the modal
    // For now, just log that it was called
    console.log('🎨 Rendering modal control point markers')
  }

  // Render control points list
  renderControlPointsList() {
    // This method should render the control points list in the modal
    // For now, just log that it was called
    console.log('🎨 Rendering control points list')
  }
}
