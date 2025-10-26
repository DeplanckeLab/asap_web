// GradientManager - Handles all gradient-related functionality including modal, control points, and color calculations
export class GradientManager {
  constructor(controller) {
    this.controller = controller
  }

  // Open gradient editor modal
  openGradientEditorModal() {
    const modal = document.getElementById('gradient-editor-modal')
    if (!modal) {
      console.error('❌ Gradient editor modal not found')
      return
    }

    // Show modal
    modal.style.display = 'flex'
    
    // Initialize gradient editor
    this.controller.rendererManager.renderModalGradientPreview()
    this.controller.rendererManager.renderModalControlPointMarkers()
    this.controller.rendererManager.renderControlPointsList()
  }

  // Close gradient editor modal
  closeGradientEditorModal() {
    const modal = document.getElementById('gradient-editor-modal')
    if (modal) {
      modal.style.display = 'none'
    }
    
    // Close control point editor if open
    this.controller.closeControlPointEditor()
  }

  // Handle clicking on gradient bar to add new control point
  gradientBarClicked(event) {
    const canvas = event.target
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const position = x / rect.width
    
    // Get color at this position
    const color = this.getColorFromGradient(position)
    
    // Add new control point
    this.addControlPoint(position, color)
    
    // Update preview
    this.controller.rendererManager.renderModalGradientPreview()
    this.controller.rendererManager.renderModalControlPointMarkers()
    this.controller.rendererManager.renderControlPointsList()
    
    // Update colors
    this.controller.reapplyColorsWithNewGradient()
  }

  // Select a control point for editing
  selectControlPoint(index) {
    this.controller.selectedControlPointIndex = index
    
    const controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    if (controlPoints && controlPoints[index]) {
      const point = controlPoints[index]
      
      // Update color picker
      const colorPicker = document.getElementById('control-point-color')
      if (colorPicker) {
        colorPicker.value = `#${point.color.toString(16).padStart(6, '0')}`
      }
      
      // Update position slider
      const positionSlider = document.getElementById('control-point-position')
      if (positionSlider) {
        positionSlider.value = point.position
      }
      
      // Show control point editor
      this.controller.showControlPointEditor()
    }
    
    this.controller.rendererManager.renderControlPointsList()
  }

  // Add a new control point
  addControlPoint(position, color) {
    // Create custom gradient if modifying auto gradient
    if (!this.controller.customGradientControlPoints) {
      this.controller.customGradientControlPoints = [...(this.controller.gradientControlPoints || [])]
    }
    
    // Add new control point
    this.controller.customGradientControlPoints.push({
      position: Math.max(0, Math.min(1, position)),
      color: color
    })
    
    // Sort by position
    this.controller.customGradientControlPoints.sort((a, b) => a.position - b.position)
    
    // Update preview
    this.controller.rendererManager.renderModalGradientPreview()
    this.controller.rendererManager.renderModalControlPointMarkers()
    this.controller.rendererManager.renderControlPointsList()
    this.controller.reapplyColorsWithNewGradient()
  }

  // Remove selected control point
  removeControlPoint() {
    if (this.controller.selectedControlPointIndex === undefined) return
    
    // Create custom gradient if modifying auto gradient
    if (!this.controller.customGradientControlPoints) {
      this.controller.customGradientControlPoints = [...(this.controller.gradientControlPoints || [])]
    }
    
    // Remove control point
    this.controller.customGradientControlPoints.splice(this.controller.selectedControlPointIndex, 1)
    
    // Clear selection
    this.controller.selectedControlPointIndex = undefined
    
    // Update preview
    this.controller.rendererManager.renderModalGradientPreview()
    this.controller.rendererManager.renderModalControlPointMarkers()
    this.controller.rendererManager.renderControlPointsList()
    this.controller.reapplyColorsWithNewGradient()
  }

  // Get color from gradient at normalized position (0-1)
  getColorFromGradient(normalizedValue) {
    // Handle invalid values
    if (normalizedValue < 0 || normalizedValue > 1 || isNaN(normalizedValue)) {
      return 0x000000 // Black
    }
    
    // Get active gradient (custom or auto)
    const controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    if (!controlPoints || controlPoints.length === 0) {
      return 0x000000 // Black fallback
    }
    
    // Sort control points by position
    const sorted = [...controlPoints].sort((a, b) => a.position - b.position)
    
    // Find the two control points to interpolate between
    let leftPoint = null
    let rightPoint = null
    
    for (let i = 0; i < sorted.length; i++) {
      const point = sorted[i]
      if (point.position <= normalizedValue) {
        leftPoint = point
      }
      if (point.position >= normalizedValue && !rightPoint) {
        rightPoint = point
        break
      }
    }
    
    // Handle edge cases
    if (!leftPoint && rightPoint) {
      return rightPoint.color
    }
    if (leftPoint && !rightPoint) {
      return leftPoint.color
    }
    if (!leftPoint && !rightPoint) {
      return 0x000000 // Black fallback
    }
    
    // Interpolate between the two points
    const t = (normalizedValue - leftPoint.position) / (rightPoint.position - leftPoint.position)
    return this.interpolateColor(leftPoint.color, rightPoint.color, t)
  }

  // Interpolate between two colors
  interpolateColor(color1, color2, t) {
    const r1 = (color1 >> 16) & 0xFF
    const g1 = (color1 >> 8) & 0xFF
    const b1 = color1 & 0xFF
    
    const r2 = (color2 >> 16) & 0xFF
    const g2 = (color2 >> 8) & 0xFF
    const b2 = color2 & 0xFF
    
    const r = Math.round(r1 + (r2 - r1) * t)
    const g = Math.round(g1 + (g2 - g1) * t)
    const b = Math.round(b1 + (b2 - b1) * t)
    
    return (r << 16) | (g << 8) | b
  }

  // Initialize gradient legend listeners
  initializeGradientLegendListeners() {
    if (!this.controller.overlayCanvas) {
      console.log('⚠️ Cannot initialize gradient legend listeners: overlayCanvas is null')
      return
    }

    // Get the parent container to listen for events (overlay canvas has pointerEvents: 'none')
    const canvasContainer = this.controller.overlayCanvas.parentElement
    if (!canvasContainer) {
      console.log('⚠️ Cannot find canvas container')
      return
    }

    // Remove existing listeners if any
    if (this.controller.gradientLegendClickListener) {
      canvasContainer.removeEventListener('click', this.controller.gradientLegendClickListener)
    }
    if (this.controller.gradientLegendMouseMoveListener) {
      canvasContainer.removeEventListener('mousemove', this.controller.gradientLegendMouseMoveListener)
    }
    if (this.controller.gradientLegendMouseLeaveListener) {
      canvasContainer.removeEventListener('mouseleave', this.controller.gradientLegendMouseLeaveListener)
    }

    // Add click listener to gradient legend
    this.controller.gradientLegendClickListener = (event) => {
      if (this.controller.gradientLegendBounds && this.isPointInGradientLegend(event.clientX, event.clientY)) {
        this.openGradientEditorModal()
        event.stopPropagation()
      }
    }

    // Add hover listeners for gradient legend
    this.controller.gradientLegendMouseMoveListener = (event) => {
      if (this.controller.gradientLegendBounds) {
        const isHovering = this.isPointInGradientLegend(event.clientX, event.clientY)
        if (isHovering !== this.controller.isHoveringGradientLegend) {
          this.controller.isHoveringGradientLegend = isHovering
          this.controller.overlayCanvas.style.cursor = isHovering ? 'pointer' : 'default'
          this.controller.rendererManager.renderContinuousColorLegendCanvas2D()
        }
      }
    }

    this.controller.gradientLegendMouseLeaveListener = () => {
      if (this.controller.isHoveringGradientLegend) {
        this.controller.isHoveringGradientLegend = false
        this.controller.overlayCanvas.style.cursor = 'default'
        this.controller.rendererManager.renderContinuousColorLegendCanvas2D()
      }
    }

    // Add listeners to the container, not the overlay canvas
    canvasContainer.addEventListener('click', this.controller.gradientLegendClickListener)
    canvasContainer.addEventListener('mousemove', this.controller.gradientLegendMouseMoveListener)
    canvasContainer.addEventListener('mouseleave', this.controller.gradientLegendMouseLeaveListener)

    console.log('✅ Gradient legend listeners initialized successfully')
  }

  // Check if point is within gradient legend bounds
  isPointInGradientLegend(x, y) {
    if (!this.controller.gradientLegendBounds) return false
    
    const rect = this.controller.overlayCanvas.getBoundingClientRect()
    const relativeX = x - rect.left
    const relativeY = y - rect.top
    
    return relativeX >= this.controller.gradientLegendBounds.x &&
           relativeX <= this.controller.gradientLegendBounds.x + this.controller.gradientLegendBounds.width &&
           relativeY >= this.controller.gradientLegendBounds.y &&
           relativeY <= this.controller.gradientLegendBounds.y + this.controller.gradientLegendBounds.height
  }

  // Render gradient preview in modal
  renderModalGradientPreview() {
    const canvas = document.getElementById('gradient-editor-preview-canvas')
    if (!canvas) return
    
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    
    // Clear canvas
    ctx.clearRect(0, 0, width, height)
    
    // Get active gradient (custom or auto)
    const controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    if (!controlPoints || controlPoints.length === 0) {
      // Draw a default gradient if no control points
      const gradient = ctx.createLinearGradient(0, 0, width, 0)
      gradient.addColorStop(0, '#3b82f6')
      gradient.addColorStop(1, '#ef4444')
      ctx.fillStyle = gradient
      ctx.fillRect(0, 0, width, height)
      return
    }
    
    // Sort control points by position
    const sorted = [...controlPoints].sort((a, b) => a.position - b.position)
    
    // Create linear gradient
    const gradient = ctx.createLinearGradient(0, 0, width, 0)
    
    for (const point of sorted) {
      const color = `#${point.color.toString(16).padStart(6, '0')}`
      gradient.addColorStop(point.position, color)
    }
    
    ctx.fillStyle = gradient
    ctx.fillRect(0, 0, width, height)
  }
  
  // Render control point markers on the gradient bar in modal
  renderModalControlPointMarkers() {
    const container = document.getElementById('gradient-editor-control-points')
    if (!container) return
    
    // Clear existing markers
    container.innerHTML = ''
    
    // Get active gradient (custom or auto)
    const controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    if (!controlPoints || controlPoints.length === 0) return
    
    const canvas = document.getElementById('gradient-editor-preview-canvas')
    if (!canvas) return
    
    const canvasWidth = canvas.offsetWidth
    
    // Create a marker for each control point
    controlPoints.forEach((point, index) => {
      const marker = document.createElement('div')
      const markerSize = 16
      const x = point.position * canvasWidth - (markerSize / 2)
      
      marker.style.cssText = `
        position: absolute;
        left: ${x}px;
        top: 50%;
        transform: translateY(-50%);
        width: ${markerSize}px;
        height: ${markerSize}px;
        border: 2px solid white;
        border-radius: 50%;
        background-color: #${point.color.toString(16).padStart(6, '0')};
        box-shadow: 0 2px 4px rgba(0,0,0,0.3);
        cursor: pointer;
        pointer-events: all;
        transition: transform 0.2s;
      `
      
      marker.addEventListener('mouseenter', () => {
        marker.style.transform = 'translateY(-50%) scale(1.3)'
      })
      
      marker.addEventListener('mouseleave', () => {
        marker.style.transform = 'translateY(-50%) scale(1)'
      })
      
      marker.addEventListener('click', (e) => {
        e.stopPropagation()
        this.selectControlPoint(index)
      })
      
      container.appendChild(marker)
    })
  }
  
  // Render list of control points (now just updates markers, list UI removed for simplicity)
  renderControlPointsList() {
    // UI simplified - control points list removed
    // Control points are now only visible on the gradient bar and in the editor
    // This method is kept for backward compatibility but does nothing
  }
}
