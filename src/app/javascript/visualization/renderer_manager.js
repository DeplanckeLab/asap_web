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
    ctx.translate(20, height / 2)
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
    // console.log('🎨 [Canvas2D] Rendering continuous color legend START')
    
    if (!this.controller.overlayCtx || !this.controller.currentBounds || !this.controller.currentMetadataVector || !this.controller.currentCoordinates) {
      // console.log('🎨 [Canvas2D] Missing required components for continuous legend')
      return
    }

    // Only render legend for continuous metadata
    if (this.controller.currentMetadataVector.data_type !== 'NUMERIC') {
      // console.log('🎨 [Canvas2D] Not numeric metadata, skipping legend')
      return
    }

    // During panning, don't update legend
    if (this.controller.isPanning) {
      // console.log('🎨 [Canvas2D] Skipping legend updates during panning')
      return
    }

    // Redraw the entire overlay (grid, axes, legend) to ensure the old legend is cleared
    // This is necessary when the color range is adapted
    // console.log('🎨 [Canvas2D] Redrawing full overlay (grid + axes + legend)')
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
    // console.log('🎨 [Canvas2D] Effective range:', { minVal, maxVal })

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
    // console.log(`🎨 [Canvas2D] Continuous color legend rendered in ${totalTime.toFixed(2)}ms`)
  }

  renderGridCanvas2D() {
    // This method should be implemented in the RendererManager
    // For now, we'll delegate to the controller's renderGrid method
    this.renderGrid()
  }

  // Category labels and legends
  renderCategoryLabels() {
    if (!this.controller.overlayCtx || !this.controller.overlayCanvas || !this.controller.currentBounds || !this.controller.currentMetadataVector || !this.controller.currentCoordinates) {
      return
    }
    
    // Only render labels for discrete metadata
    if (this.controller.currentMetadataVector.data_type !== 'DISCRETE') {
      return
    }
    
    // Check if the user wants to see category labels
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')
    const shouldShowLabels = categoriesCheckbox ? categoriesCheckbox.checked : false

    if (!shouldShowLabels) {
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
    
    let categoryList = categories
    if (!categoryList || categoryList.length === 0) {
      categoryList = [...new Set(values)]
    }

    // Calculate centroids
    const centroids = this.controller.dataManager.calculateCategoryCentroids(values, categoryList)

    // Keep colors stable even when categories currently have 0 visible cells.
    let allCategories
    if (this.controller.currentMetadataVector.compression_info && this.controller.currentMetadataVector.compression_info.categories) {
      allCategories = [...this.controller.currentMetadataVector.compression_info.categories]
    } else {
      allCategories = [...new Set(values)]
    }
    
    const stableSortedCategories = this.controller.getStableSortedCategories(values, allCategories)
    const colorMap = this.controller.colorManager.createDiscreteColorMap(stableSortedCategories, this.controller.currentMetadataVector.id)
    
    // Label style settings
    const showLabelBoxes = this.controller.showLabelBoxes !== false
    const truncateLongLabels = this.controller.truncateLongLabels !== false
    const collisionPadding = 2
    const hitPadding = 6

    // Keep existing manual drag offsets so user positioning persists.
    const existingLabelsByCategory = new Map((this.controller.canvas2DLabels || []).map(label => [label.category, label]))

    const newLabels = []
    const placedBounds = []
    const placedVisualBounds = []
    const margins = this.getPlotMargins()

    const plotCenterX = (margins.left + (width - margins.right)) / 2
    const plotCenterY = (margins.top + (height - margins.bottom)) / 2

    const sortable = Object.entries(centroids)
      .filter(([, centroid]) => centroid && centroid.count > 0)
      .sort((a, b) => {
        const aX = this.controller.interactionHandler.normalizeX(a[1].x, this.controller.currentBounds)
        const aY = this.controller.interactionHandler.normalizeY(a[1].y, this.controller.currentBounds)
        const bX = this.controller.interactionHandler.normalizeX(b[1].x, this.controller.currentBounds)
        const bY = this.controller.interactionHandler.normalizeY(b[1].y, this.controller.currentBounds)

        const aDistanceToCenter = Math.hypot(aX - plotCenterX, aY - plotCenterY)
        const bDistanceToCenter = Math.hypot(bX - plotCenterX, bY - plotCenterY)
        if (aDistanceToCenter !== bDistanceToCenter) {
          return aDistanceToCenter - bDistanceToCenter
        }

        // Tie-breaker: larger categories first.
        return b[1].count - a[1].count
      })

    const manualLabelFontSize = Number(this.controller.labelFontSize) > 0 ? Number(this.controller.labelFontSize) : 12
    const autoLabelFontSize = this.getAutoLabelFontSize(sortable.length)
    const labelFontSize = this.controller.labelFontSizeMode === 'auto' ? autoLabelFontSize : manualLabelFontSize
    // Use tighter, font-scaled padding so small labels have compact boxes.
    const boxPadding = showLabelBoxes ? Math.max(2, Math.round(labelFontSize * 0.2)) : 2
    const resolvedMetadataId = this.controller.syncCurrentMetadataIdWithPanelByName
      ? this.controller.syncCurrentMetadataIdWithPanelByName()
      : String(this.controller.currentMetadataId || this.controller.currentMetadataVector?.id || '')

    sortable.forEach(([category, centroid]) => {
      const centroidScreenX = this.controller.interactionHandler.normalizeX(centroid.x, this.controller.currentBounds)
      const centroidScreenY = this.controller.interactionHandler.normalizeY(centroid.y, this.controller.currentBounds)

      // Hide labels when the underlying centroid is outside the visible plot area.
      const centroidVisibleInPlot = (
        centroidScreenX >= margins.left &&
        centroidScreenX <= (width - margins.right) &&
        centroidScreenY >= margins.top &&
        centroidScreenY <= (height - margins.bottom)
      )
      if (!centroidVisibleInPlot) return

      const existingLabel = existingLabelsByCategory.get(category)
      const persistedLock = this.controller.manualLabelLocks ? this.controller.manualLabelLocks.get(category) : null
      const manualOffsetX = persistedLock?.manualOffsetX ?? (existingLabel ? (existingLabel.manualOffsetX ?? existingLabel.offsetX ?? 0) : 0)
      const manualOffsetY = persistedLock?.manualOffsetY ?? (existingLabel ? (existingLabel.manualOffsetY ?? existingLabel.offsetY ?? 0) : 0)
      const labelIsManuallyMoved = !!(persistedLock?.isManuallyMoved || (existingLabel && existingLabel.isManuallyMoved))
      const freezeMovedLabels = this.controller.freezeMovedLabels !== false

      const freezePlacement = !!(this.controller.draggingLabel && this.controller.draggingLabel.category === category)

      let preferredX = centroidScreenX + manualOffsetX
      let preferredY = centroidScreenY + manualOffsetY
      // Keep manually moved labels fixed across re-renders, but never while actively dragging.
      if (!freezePlacement && freezeMovedLabels && labelIsManuallyMoved) {
        preferredX = persistedLock?.lockedX ?? existingLabel?.lockedX ?? existingLabel?.x ?? preferredX
        preferredY = persistedLock?.lockedY ?? existingLabel?.lockedY ?? existingLabel?.y ?? preferredY
      }

      const displayText = this.formatCategoryLabel(category, truncateLongLabels)
      ctx.font = `${labelFontSize}px Arial`
      const textMetrics = ctx.measureText(displayText)
      const textWidth = textMetrics.width
      const textHeight = Math.max(labelFontSize + 2, 12)

      // Build candidates around centroid/manual location and pick one that minimizes overlap.
      const placementMode = this.controller.labelPlacementMode || 'avoid-collisions'
      const useCentroidPlacement = placementMode === 'centroid'
      const keepManualPlacementFixed = freezeMovedLabels && labelIsManuallyMoved
      const centroidDistanceToCenter = Math.hypot(centroidScreenX - plotCenterX, centroidScreenY - plotCenterY)
      const maxCandidateRadius = Math.min(192, Math.max(56, 56 + centroidDistanceToCenter * 0.5))
      const candidates = (freezePlacement || useCentroidPlacement || keepManualPlacementFixed)
        ? [{ x: preferredX, y: preferredY }]
        : this.buildLabelCandidates(preferredX, preferredY, maxCandidateRadius)

      const evaluatedCandidates = []

      for (let i = 0; i < candidates.length; i++) {
        const candidate = candidates[i]
        const visualBounds = {
          x: candidate.x - textWidth / 2 - boxPadding,
          y: candidate.y - textHeight / 2 - boxPadding,
          width: textWidth + boxPadding * 2,
          height: textHeight + boxPadding * 2
        }

        // Keep labels inside viewport to avoid inaccessible drag targets.
        const insideCanvas = (
          visualBounds.x >= 0 &&
          visualBounds.y >= 0 &&
          (visualBounds.x + visualBounds.width) <= width &&
          (visualBounds.y + visualBounds.height) <= height
        )
        if (!insideCanvas) continue

        const collisionBounds = {
          x: visualBounds.x - collisionPadding,
          y: visualBounds.y - collisionPadding,
          width: visualBounds.width + collisionPadding * 2,
          height: visualBounds.height + collisionPadding * 2
        }

        let overlapArea = 0
        for (let j = 0; j < placedBounds.length; j++) {
          overlapArea += this.computeOverlapArea(collisionBounds, placedBounds[j])
        }

        // Penalize candidates whose leader line would cross existing label boxes.
        let lineCrossCount = 0
        const displacement = Math.hypot(candidate.x - centroidScreenX, candidate.y - centroidScreenY)
        if (displacement > 4) {
          for (let j = 0; j < placedVisualBounds.length; j++) {
            if (this.doesSegmentIntersectRect(
              centroidScreenX,
              centroidScreenY,
              candidate.x,
              candidate.y,
              placedVisualBounds[j]
            )) {
              lineCrossCount += 1
            }
          }
        }

        const distance = Math.hypot(candidate.x - preferredX, candidate.y - preferredY)
        evaluatedCandidates.push({
          ...candidate,
          visualBounds,
          collisionBounds,
          overlapArea,
          lineCrossCount,
          distance
        })
      }

      let bestCandidate = null
      if (evaluatedCandidates.length > 0) {
        const nearCandidates = evaluatedCandidates.filter(c => c.distance <= maxCandidateRadius)
        const candidatePool = nearCandidates.length > 0 ? nearCandidates : evaluatedCandidates

        const sortByQuality = (a, b) => {
          if (a.overlapArea !== b.overlapArea) return a.overlapArea - b.overlapArea
          if (a.lineCrossCount !== b.lineCrossCount) return a.lineCrossCount - b.lineCrossCount
          return a.distance - b.distance
        }

        const zeroOverlapZeroCross = candidatePool
          .filter(c => c.overlapArea === 0 && c.lineCrossCount === 0)
          .sort((a, b) => a.distance - b.distance)

        if (zeroOverlapZeroCross.length > 0) {
          bestCandidate = zeroOverlapZeroCross[0]
        } else {
          // Prioritize non-overlapping boxes before anything else.
          const zeroOverlap = candidatePool
            .filter(c => c.overlapArea === 0)
            .sort((a, b) => {
              if (a.lineCrossCount !== b.lineCrossCount) return a.lineCrossCount - b.lineCrossCount
              return a.distance - b.distance
            })

          if (zeroOverlap.length > 0) {
            bestCandidate = zeroOverlap[0]
          } else {
            // Last resort: smallest overlap first, then crossings, then distance.
            bestCandidate = candidatePool.sort(sortByQuality)[0]
          }
        }
      }

      if (!bestCandidate) return

      const screenX = bestCandidate.x
      const screenY = bestCandidate.y
      const { visualBounds } = bestCandidate

      const colorValue = colorMap[category] || 0x3b82f6
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

      ctx.save()

      // Draw leader line whenever label is displaced from centroid/manual anchor.
      const displacement = Math.hypot(screenX - centroidScreenX, screenY - centroidScreenY)
      if (displacement > 4) {
        ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, 0.85)`
        ctx.lineWidth = 1.5
        ctx.beginPath()
        ctx.moveTo(centroidScreenX, centroidScreenY)
        ctx.lineTo(screenX, screenY)
        ctx.stroke()
      }

      if (showLabelBoxes) {
        ctx.fillStyle = 'rgba(255, 255, 255, 0.9)'
        ctx.strokeStyle = `rgb(${r}, ${g}, ${b})`
        ctx.lineWidth = 2
        ctx.fillRect(visualBounds.x, visualBounds.y, visualBounds.width, visualBounds.height)
        ctx.strokeRect(visualBounds.x, visualBounds.y, visualBounds.width, visualBounds.height)
      } else {
        // Shadowed text mode for cleaner overlays without background boxes.
        ctx.shadowColor = 'rgba(255, 255, 255, 0.95)'
        ctx.shadowBlur = Math.max(4, Math.round(labelFontSize * 0.45))
        ctx.shadowOffsetX = 0
        ctx.shadowOffsetY = 0
      }

      ctx.fillStyle = '#333333'
      ctx.font = `${labelFontSize}px Arial`
      ctx.textAlign = 'center'
      ctx.textBaseline = 'middle'
      ctx.fillText(displayText, screenX, screenY)

      ctx.restore()

      // Slightly larger hit area keeps drag interaction easy in text-only mode.
      const hitBounds = {
        x: visualBounds.x - hitPadding,
        y: visualBounds.y - hitPadding,
        width: visualBounds.width + hitPadding * 2,
        height: visualBounds.height + hitPadding * 2
      }

      const finalIsManuallyMoved = labelIsManuallyMoved || freezePlacement
      const finalLockedX = finalIsManuallyMoved ? screenX : null
      const finalLockedY = finalIsManuallyMoved ? screenY : null

      newLabels.push({
        metadataId: String(resolvedMetadataId || ''),
        metadataName: String(this.controller.currentMetadataVector?.name || this.controller.dataManager?.getMetadataNameById?.(this.controller.currentMetadataId) || ''),
        category: category,
        displayText: displayText,
        x: screenX,
        y: screenY,
        bounds: hitBounds,
        visualBounds: visualBounds,
        centroidX: centroid.x,
        centroidY: centroid.y,
        centroidScreenX: centroidScreenX,
        centroidScreenY: centroidScreenY,
        manualOffsetX: manualOffsetX,
        manualOffsetY: manualOffsetY,
        offsetX: manualOffsetX,
        offsetY: manualOffsetY,
        isManuallyMoved: finalIsManuallyMoved,
        lockedX: finalLockedX,
        lockedY: finalLockedY,
        autoOffsetX: screenX - preferredX,
        autoOffsetY: screenY - preferredY,
        color: { r, g, b },
        fontSize: labelFontSize,
        showBox: showLabelBoxes
      })

      if (this.controller.manualLabelLocks) {
        if (finalIsManuallyMoved) {
          this.controller.manualLabelLocks.set(category, {
            isManuallyMoved: true,
            manualOffsetX: manualOffsetX,
            manualOffsetY: manualOffsetY,
            lockedX: finalLockedX,
            lockedY: finalLockedY
          })
        } else if (this.controller.manualLabelLocks.has(category)) {
          this.controller.manualLabelLocks.delete(category)
        }
      }

      placedBounds.push(bestCandidate.collisionBounds)
      placedVisualBounds.push(visualBounds)
    })

    // Draw centroid anchors last so line endpoints remain visible even if labels overlap.
    ctx.save()
    newLabels.forEach(label => {
      if (typeof label.centroidScreenX !== 'number' || typeof label.centroidScreenY !== 'number') return
      const displacement = Math.hypot(label.x - label.centroidScreenX, label.y - label.centroidScreenY)
      if (displacement <= 4) return

      const { r, g, b } = label.color
      ctx.beginPath()
      ctx.arc(label.centroidScreenX, label.centroidScreenY, 2.5, 0, Math.PI * 2)
      ctx.fillStyle = `rgba(${r}, ${g}, ${b}, 0.95)`
      ctx.fill()
      ctx.lineWidth = 1
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.95)'
      ctx.stroke()
    })
    ctx.restore()

    // Update stored labels
    this.controller.canvas2DLabels = newLabels
    
    // If we're currently dragging a label, update the reference to point to the new label object
    if (this.controller.draggingLabel) {
      const newDraggingLabel = newLabels.find(l => l.category === this.controller.draggingLabel.category)
      if (newDraggingLabel) {
        // console.log(`🏷️ [Canvas2D] Updated dragging label reference for "${this.controller.draggingLabel.category}"`)
        this.controller.draggingLabel = newDraggingLabel
      }
    }
    
  }

  formatCategoryLabel(label, truncateLongLabels = true) {
    const value = String(label ?? '')
    if (!truncateLongLabels || value.length <= 20) return value
    const prefix = value.slice(0, 10)
    const suffix = value.slice(-10)
    return `${prefix}...${suffix}`
  }

  buildLabelCandidates(centerX, centerY, maxRadius = 192) {
    const candidates = [{ x: centerX, y: centerY }]
    const distances = [16, 28, 40, 54, 70, 88, 108, 132, 160, 192]
    const angles = [0, 15, 30, 45, 60, 75, 90, 105, 120, 135, 150, 165, 180, 195, 210, 225, 240, 255, 270, 285, 300, 315, 330, 345]

    distances.forEach(distance => {
      if (distance > maxRadius) return
      angles.forEach(angleDeg => {
        const angle = (angleDeg * Math.PI) / 180
        candidates.push({
          x: centerX + Math.cos(angle) * distance,
          y: centerY + Math.sin(angle) * distance
        })
      })
    })

    return candidates
  }

  computeOverlapArea(a, b) {
    const overlapX = Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x))
    const overlapY = Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y))
    return overlapX * overlapY
  }

  getAutoLabelFontSize(labelCount) {
    if (labelCount <= 12) return 16
    if (labelCount <= 24) return 14
    if (labelCount <= 45) return 12
    return 10
  }

  doesSegmentIntersectRect(x1, y1, x2, y2, rect) {
    if (!rect) return false

    // If either endpoint is inside the box, we treat that as an intersection.
    if (this.isPointInRect(x1, y1, rect) || this.isPointInRect(x2, y2, rect)) {
      return true
    }

    const left = rect.x
    const right = rect.x + rect.width
    const top = rect.y
    const bottom = rect.y + rect.height

    // Check intersection against each rectangle edge.
    return (
      this.doSegmentsIntersect(x1, y1, x2, y2, left, top, right, top) ||
      this.doSegmentsIntersect(x1, y1, x2, y2, right, top, right, bottom) ||
      this.doSegmentsIntersect(x1, y1, x2, y2, right, bottom, left, bottom) ||
      this.doSegmentsIntersect(x1, y1, x2, y2, left, bottom, left, top)
    )
  }

  isPointInRect(x, y, rect) {
    return x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height
  }

  doSegmentsIntersect(ax, ay, bx, by, cx, cy, dx, dy) {
    const o1 = this.orientation(ax, ay, bx, by, cx, cy)
    const o2 = this.orientation(ax, ay, bx, by, dx, dy)
    const o3 = this.orientation(cx, cy, dx, dy, ax, ay)
    const o4 = this.orientation(cx, cy, dx, dy, bx, by)

    // General case
    if (o1 !== o2 && o3 !== o4) return true

    // Collinear edge cases
    if (o1 === 0 && this.isPointOnSegment(ax, ay, cx, cy, bx, by)) return true
    if (o2 === 0 && this.isPointOnSegment(ax, ay, dx, dy, bx, by)) return true
    if (o3 === 0 && this.isPointOnSegment(cx, cy, ax, ay, dx, dy)) return true
    if (o4 === 0 && this.isPointOnSegment(cx, cy, bx, by, dx, dy)) return true

    return false
  }

  orientation(ax, ay, bx, by, cx, cy) {
    const val = (by - ay) * (cx - bx) - (bx - ax) * (cy - by)
    if (Math.abs(val) < 1e-9) return 0
    return val > 0 ? 1 : 2
  }

  isPointOnSegment(ax, ay, px, py, bx, by) {
    return (
      px <= Math.max(ax, bx) &&
      px >= Math.min(ax, bx) &&
      py <= Math.max(ay, by) &&
      py >= Math.min(ay, by)
    )
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
    // console.log(`⏱️ [PERF] Updating point size to ${newSize}`)
    const updateStart = performance.now()
    
    // Update the current point size
    this.controller.currentPointSize = newSize
    
    // Update ReGL renderer if available
    if (this.controller.reglRenderer) {
      this.controller.reglRenderer.updatePointSize(newSize)
    }
    
    const updateEnd = performance.now()
    const updateTime = updateEnd - updateStart
    // console.log(`⏱️ [PERF] Point size update completed in ${updateTime.toFixed(2)}ms`)
  }

  // Initialize scatter plot with coordinates
  async initializeScatterPlot(coordinates) {
    try {
      // CRITICAL: Check if renderer already exists with state and matching coordinate count
      // If so, we should reuse it instead of destroying it!
      if (this.controller.reglRenderer) {
        const hasState = this.controller.reglRenderer.numPoints > 0 || 
                         (this.controller.reglRenderer.positions && this.controller.reglRenderer.positions.length > 0) ||
                         (this.controller.reglRenderer.colors && this.controller.reglRenderer.colors.length > 0)
        const coordinateCount = coordinates.length
        const rendererPointCount = this.controller.reglRenderer.numPoints || 
                                   (this.controller.reglRenderer.positions ? this.controller.reglRenderer.positions.length / 2 : 0)
        
        if (hasState && rendererPointCount === coordinateCount) {
          // console.log(`⏱️ [PERF] Step 3: Reusing existing ${this.controller.rendererType.toUpperCase()} renderer (FAST PATH - renderer has state)`)
          // console.log(`⏱️ [PERF] Renderer instance: ${this.controller.reglRenderer.instanceId}, points: ${rendererPointCount}`)
          // Renderer already exists with correct state - just render the coordinates
          await this.controller.renderScatterPlot(coordinates)
          return
        } else {
          // console.log(`⏱️ [PERF] Step 3: Creating new ${this.controller.rendererType.toUpperCase()} renderer (SLOW PATH - first render or count mismatch)`)
          // console.log(`⏱️ [PERF] Existing renderer state: hasState=${hasState}, rendererPoints=${rendererPointCount}, newPoints=${coordinateCount}`)
        }
      } else {
        // console.log(`⏱️ [PERF] Step 3: Creating new ${this.controller.rendererType.toUpperCase()} renderer (SLOW PATH - first render)`)
      }
      
      // Clear existing renderers
      if (this.controller.reglRenderer) {
        const oldRendererId = this.controller.reglRenderer.instanceId
        const oldRendererState = {
          numPoints: this.controller.reglRenderer.numPoints,
          hasPositions: !!this.controller.reglRenderer.positions,
          hasColors: !!this.controller.reglRenderer.colors
        }
        // console.log(`⏱️ [PERF] Destroying existing renderer: ${oldRendererId}`, oldRendererState)
        //console.trace(`⏱️ [PERF] Stack trace for renderer destruction`)
        this.controller.reglRenderer.destroy()
        this.controller.reglRenderer = null
        // console.log(`⏱️ [PERF] Renderer destroyed and set to null`)
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
        // console.log('🎯 Initializing ReGL renderer for WebGL performance')
        
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
        
        // console.log('🔍 DEBUG: Canvas dimensions:', {
          // width: canvas.width,
          // height: canvas.height,
          // clientWidth: plotContainer.clientWidth,
          // clientHeight: plotContainer.clientHeight,
          // containerVisible: plotContainer.offsetWidth > 0 && plotContainer.offsetHeight > 0
        // })
        
        // Initialize ReGL renderer
        // console.log(`⏱️ [PERF] Creating new ReglRenderer in initializeScatterPlot`)
        //console.trace(`⏱️ [PERF] Stack trace for renderer creation in initializeScatterPlot`)
        this.controller.reglRenderer = new ReglRenderer(canvas)
        this.controller.canvas = canvas
        // console.log(`⏱️ [PERF] New renderer created: ${this.controller.reglRenderer.instanceId}`)
        
        // console.log('ReGL canvas added to container:', canvas)
        
        // Setup interaction system now that canvas exists
        this.controller.interactionHandler.setupInteractionSystem()
        
        // Create HTML Canvas 2D overlay for axes/grid/labels
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
        
        // console.log('✅ Canvas 2D overlay created for UI elements (axes/grid/labels)')
        // console.log('📊 Canvas 2D overlay details:', {
          // width: overlayCanvas.width,
          // height: overlayCanvas.height,
          // zIndex: overlayCanvas.style.zIndex,
          // pointerEvents: overlayCanvas.style.pointerEvents
        // })
        
    
        // ReGL mode: Canvas 2D overlay for axes/grid/labels; dummy scatter container for legacy checks
        this.controller.scatterContainer = { children: [] }
        this.controller.gridContainer = null
        this.controller.categoryLabelsContainer = null
        this.controller.axesContainer = null
      

      // Store current loom file safely (loom selector can be absent in some layouts)
      const selectedLoomFile = this.controller.hasLoomFileSelectTarget
        ? this.controller.loomFileSelectTarget?.value
        : this.controller.getCurrentLoomFile?.()
      if (selectedLoomFile) {
        this.controller.currentLoomFile = selectedLoomFile
      }
      
      // Render the scatter plot
      await this.controller.renderScatterPlot(coordinates)
      
    } catch (error) {
      console.error('Error initializing scatter plot:', error)
      throw error
    }
  }

  // Render modal gradient preview
  renderModalGradientPreview() {
    // Delegate to gradientManager
    if (this.controller.gradientManager) {
      this.controller.gradientManager.renderModalGradientPreview()
    } else {
      console.warn('🎨 ⚠️ gradientManager not available')
    }
  }

  // Render modal control point markers
  renderModalControlPointMarkers() {
    // Delegate to gradientManager
    if (this.controller.gradientManager) {
      this.controller.gradientManager.renderModalControlPointMarkers()
    } else {
      console.warn('🎨 ⚠️ gradientManager not available')
    }
  }

  // Render control points list
  renderControlPointsList() {
    // Delegate to gradientManager
    if (this.controller.gradientManager) {
      this.controller.gradientManager.renderControlPointsList()
    } else {
      console.warn('🎨 ⚠️ gradientManager not available')
    }
  }
}
