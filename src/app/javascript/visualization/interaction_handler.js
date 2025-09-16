// Interaction Handler Module for Visualization
// Handles all mouse/touch interactions including pan, zoom, lasso, and pick modes

export class InteractionHandler {
  constructor(controller) {
    this.controller = controller
    this.interactionMode = 'pick' // Default mode
    this.isPanning = false
    this.isDrawingLasso = false
    this.lassoPoints = []
    this.lassoGraphics = null
    this.draggingLabel = null
    
    // Pan state
    this.panStartX = 0
    this.panStartY = 0
    this.panStartBounds = null
    this.panOriginalBounds = null
  }

  // Set interaction mode
  setInteractionMode(mode) {
    this.interactionMode = mode
    
    // Update button states
    this.updateButtonStates(mode)
    
    // Update control instructions
    this.updateControlInstructions()
    
    // Update label interaction mode
    this.updateLabelInteractionMode()
    
    // Update cursor
    this.updateCursor(mode)
  }

  // Update button states
  updateButtonStates(activeMode) {
    const modes = ['pick', 'pan', 'lasso']
    
    modes.forEach(mode => {
      const button = document.getElementById(`${mode}-mode-btn`)
      if (button) {
        if (mode === activeMode) {
          button.style.backgroundColor = '#3b82f6'
          button.style.color = 'white'
        } else {
          button.style.backgroundColor = '#f3f4f6'
          button.style.color = '#374151'
        }
      }
    })
  }

  // Update control instructions
  updateControlInstructions() {
    const instructionsElement = document.getElementById('control-instructions')
    if (!instructionsElement) return

    const instructions = {
      pan: 'Drag to pan • Scroll to zoom (mouse-centered)',
      pick: 'Click to pick a cell, click and drag to move a label, scroll to zoom',
      lasso: 'Click and drag to select cells, scroll to zoom'
    }

    instructionsElement.textContent = instructions[this.interactionMode] || instructions.pick
  }

  // Update cursor based on mode
  updateCursor(mode) {
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return

    const cursors = {
      pan: 'grab',
      pick: 'default',
      lasso: 'crosshair'
    }

    canvas.style.cursor = cursors[mode] || 'default'
  }

  // Update label interaction mode
  updateLabelInteractionMode() {
    if (!this.controller.categoryLabelsContainer) return

    this.controller.categoryLabelsContainer.children.forEach(label => {
      if (this.interactionMode === 'pick') {
        label.interactive = true
        label.buttonMode = true
        label.cursor = 'move'
      } else {
        label.interactive = false
        label.buttonMode = false
        label.cursor = 'default'
      }
    })
  }

  // Add interaction event listeners
  addInteractionEventListeners() {
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return

    // Mouse events
    canvas.addEventListener('mousedown', this.onInteractionMouseDown.bind(this))
    canvas.addEventListener('mousemove', this.onInteractionMouseMove.bind(this))
    canvas.addEventListener('mouseup', this.onInteractionMouseUp.bind(this))
    canvas.addEventListener('dblclick', this.onInteractionDoubleClick.bind(this))
    canvas.addEventListener('wheel', this.onInteractionWheel.bind(this))

    // Touch events for mobile
    canvas.addEventListener('touchstart', this.onInteractionMouseDown.bind(this))
    canvas.addEventListener('touchmove', this.onInteractionMouseMove.bind(this))
    canvas.addEventListener('touchend', this.onInteractionMouseUp.bind(this))
  }

  // Remove interaction event listeners
  removeInteractionEventListeners() {
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return

    // Mouse events
    canvas.removeEventListener('mousedown', this.onInteractionMouseDown.bind(this))
    canvas.removeEventListener('mousemove', this.onInteractionMouseMove.bind(this))
    canvas.removeEventListener('mouseup', this.onInteractionMouseUp.bind(this))
    canvas.removeEventListener('dblclick', this.onInteractionDoubleClick.bind(this))
    canvas.removeEventListener('wheel', this.onInteractionWheel.bind(this))

    // Touch events
    canvas.removeEventListener('touchstart', this.onInteractionMouseDown.bind(this))
    canvas.removeEventListener('touchmove', this.onInteractionMouseMove.bind(this))
    canvas.removeEventListener('touchend', this.onInteractionMouseUp.bind(this))
  }

  // Handle mouse down events
  onInteractionMouseDown(event) {
    // Prevent default to avoid text selection
    event.preventDefault()

    switch (this.interactionMode) {
      case 'pan':
        this.onPanMouseDown(event)
        break
      case 'lasso':
        this.onLassoMouseDown(event)
        break
      case 'pick':
        this.onPickMouseDown(event)
        break
    }
  }

  // Handle mouse move events
  onInteractionMouseMove(event) {
    switch (this.interactionMode) {
      case 'pan':
        this.onPanMouseMove(event)
        break
      case 'lasso':
        this.onLassoMouseMove(event)
        break
    }
  }

  // Handle mouse up events
  onInteractionMouseUp(event) {
    switch (this.interactionMode) {
      case 'pan':
        this.onPanMouseUp(event)
        break
      case 'lasso':
        this.onLassoMouseUp(event)
        break
    }
  }

  // Handle double click events
  onInteractionDoubleClick(event) {
    switch (this.interactionMode) {
      case 'pan':
        this.onPanDoubleClick(event)
        break
      case 'lasso':
        this.onLassoDoubleClick(event)
        break
    }
  }

  // Handle wheel events (zoom)
  onInteractionWheel(event) {
    event.preventDefault()

    // Get mouse position relative to canvas
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return

    const rect = canvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top

    // Calculate zoom factor
    const zoomFactor = event.deltaY > 0 ? 1.1 : 0.9
    const oldBounds = { ...this.controller.currentBounds }

    // Calculate new bounds
    const centerX = oldBounds.minX + (mouseX / this.controller.pixiApp.screen.width) * (oldBounds.maxX - oldBounds.minX)
    const centerY = oldBounds.minY + (mouseY / this.controller.pixiApp.screen.height) * (oldBounds.maxY - oldBounds.minY)

    const newWidth = (oldBounds.maxX - oldBounds.minX) * zoomFactor
    const newHeight = (oldBounds.maxY - oldBounds.minY) * zoomFactor

    const newBounds = {
      minX: centerX - newWidth / 2,
      maxX: centerX + newWidth / 2,
      minY: centerY - newHeight / 2,
      maxY: centerY + newHeight / 2
    }

    // Update visualization bounds
    this.controller.updateVisualizationBounds(newBounds)

    // Update axes, grid, and category labels
    this.controller.renderAxes()
    this.controller.renderGrid()
    this.controller.renderCategoryLabels()

    // Use translation approach like pan mode, centered on mouse position
    this.translatePointsForZoom(oldBounds, newBounds, mouseX, mouseY)
  }

  // Pan mode handlers
  onPanMouseDown(event) {
    this.isPanning = true
    
    // Store starting position
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    this.panStartX = event.clientX - rect.left
    this.panStartY = event.clientY - rect.top
    
    // Store current bounds
    this.panStartBounds = { ...this.controller.currentBounds }
    
    // Store original bounds for consistent pan scaling
    this.panOriginalBounds = this.controller.calculateBounds(this.controller.currentCoordinates)
    
    // Hide category labels during panning to avoid coordinate shift
    if (this.controller.categoryLabelsContainer) {
      this.controller.categoryLabelsContainer.visible = false
    }
    
    // Change cursor to grabbing
    const panCanvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (panCanvas) {
      panCanvas.style.cursor = 'grabbing'
    }
  }

  onPanMouseMove(event) {
    if (!this.isPanning) return
    
    // Get current mouse position
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    const currentX = event.clientX - rect.left
    const currentY = event.clientY - rect.top
    
    // Calculate pan delta
    const deltaX = currentX - this.panStartX
    const deltaY = currentY - this.panStartY
    
    // Convert screen delta to data delta using the same coordinate system as normalization
    const screenWidth = this.controller.pixiApp.screen.width
    const screenHeight = this.controller.pixiApp.screen.height
    
    // Use current bounds for pan calculation to match current view
    const dataDeltaX = (deltaX / screenWidth) * (this.panStartBounds.maxX - this.panStartBounds.minX)
    const dataDeltaY = (deltaY / screenHeight) * (this.panStartBounds.maxY - this.panStartBounds.minY)
    
    // Update bounds
    const newBounds = {
      minX: this.panStartBounds.minX - dataDeltaX,
      maxX: this.panStartBounds.maxX - dataDeltaX,
      minY: this.panStartBounds.minY - dataDeltaY, // Invert Y axis
      maxY: this.panStartBounds.maxY - dataDeltaY
    }
    
    // Update visualization with new bounds
    this.controller.updateVisualizationBounds(newBounds)
    
    // Also update grid during pan for real-time feedback
    this.controller.renderGrid()
  }

  onPanMouseUp(event) {
    if (!this.isPanning) return
    this.stopPanning()
  }

  stopPanning() {
    this.isPanning = false
    this.panStartX = 0
    this.panStartY = 0
    this.panStartBounds = null
    this.panOriginalBounds = null
    
    // Reposition category labels after panning is finished
    if (this.controller.categoryLabelsContainer && this.controller.categoryLabelsContainer.visible === false) {
      // Check if categories should be visible
      const categoriesCheckbox = document.getElementById('show-categories-checkbox')
      if (categoriesCheckbox && categoriesCheckbox.checked) {
        this.controller.categoryLabelsContainer.visible = true
        this.controller.renderCategoryLabels() // Reposition labels with current bounds
      }
    }
    
    // Reset cursor
    const stopCanvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (stopCanvas) {
      if (this.interactionMode === 'pan') {
        stopCanvas.style.cursor = 'grab'
      }
    }
  }

  onPanDoubleClick(event) {
    this.controller.resetZoomAndPan()
  }

  // Lasso mode handlers
  onLassoMouseDown(event) {
    this.isDrawingLasso = true
    this.lassoPoints = []
    
    // Get mouse position relative to canvas
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    
    this.lassoPoints.push({ x, y })
    
    // Create lasso graphics
    this.lassoGraphics = new this.controller.PIXI.Graphics()
    this.controller.scatterContainer.addChild(this.lassoGraphics)
  }

  onLassoMouseMove(event) {
    if (!this.isDrawingLasso) return
    
    // Get mouse position relative to canvas
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    
    this.lassoPoints.push({ x, y })
    this.updateLassoGraphics()
  }

  onLassoMouseUp(event) {
    if (!this.isDrawingLasso) return
    
    this.isDrawingLasso = false
    this.selectPointsInLasso()
    this.clearLasso()
  }

  onLassoDoubleClick(event) {
    this.controller.cancelSelection()
  }

  // Update lasso graphics
  updateLassoGraphics() {
    if (!this.lassoGraphics || this.lassoPoints.length < 2) return
    
    this.lassoGraphics.clear()
    this.lassoGraphics.lineStyle(2, 0x007bff, 0.8)
    this.lassoGraphics.beginFill(0x007bff, 0.1)
    
    this.lassoGraphics.moveTo(this.lassoPoints[0].x, this.lassoPoints[0].y)
    for (let i = 1; i < this.lassoPoints.length; i++) {
      this.lassoGraphics.lineTo(this.lassoPoints[i].x, this.lassoPoints[i].y)
    }
    this.lassoGraphics.closePath()
    this.lassoGraphics.endFill()
  }

  // Select points in lasso
  selectPointsInLasso() {
    if (this.lassoPoints.length < 3) return
    
    const selectedPoints = []
    
    this.controller.scatterContainer.children.forEach(point => {
      if (point.isPoint && point.visible) {
        const isInside = this.isPointInPolygon(point.x, point.y, this.lassoPoints)
        if (isInside) {
          selectedPoints.push(point.cellId)
        }
      }
    })
    
    // Add to selection
    if (selectedPoints.length > 0) {
      if (!this.controller.selectedCells) {
        this.controller.selectedCells = new Set()
      }
      
      selectedPoints.forEach(cellId => {
        this.controller.selectedCells.add(cellId)
      })
      
      this.controller.updateSelectedPointColors()
      this.controller.updateSelectedCellsCount()
    }
  }

  // Check if point is inside polygon
  isPointInPolygon(x, y, polygon) {
    let inside = false
    for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      if (((polygon[i].y > y) !== (polygon[j].y > y)) &&
          (x < (polygon[j].x - polygon[i].x) * (y - polygon[i].y) / (polygon[j].y - polygon[i].y) + polygon[i].x)) {
        inside = !inside
      }
    }
    return inside
  }

  // Clear lasso
  clearLasso() {
    if (this.lassoGraphics) {
      this.controller.scatterContainer.removeChild(this.lassoGraphics)
      this.lassoGraphics = null
    }
    this.lassoPoints = []
  }

  // Pick mode handlers
  onPickMouseDown(event) {
    // Pick mode doesn't need special mouse down handling
    // Point clicks are handled by individual point event listeners
  }

  // Translate points for zoom
  translatePointsForZoom(oldBounds, newBounds, mouseX = null, mouseY = null) {
    if (!this.controller.scatterContainer || !this.controller.scatterContainer.children) {
      return
    }

    // Calculate translation factors
    const scaleX = (newBounds.maxX - newBounds.minX) / (oldBounds.maxX - oldBounds.minX)
    const scaleY = (newBounds.maxY - newBounds.minY) / (oldBounds.maxY - oldBounds.minY)

    // Calculate center point for scaling
    let centerX, centerY
    if (mouseX !== null && mouseY !== null) {
      // Zoom centered on mouse position
      centerX = oldBounds.minX + (mouseX / this.controller.pixiApp.screen.width) * (oldBounds.maxX - oldBounds.minX)
      centerY = oldBounds.minY + (mouseY / this.controller.pixiApp.screen.height) * (oldBounds.maxY - oldBounds.minY)
    } else {
      // Zoom centered on plot center
      centerX = (oldBounds.minX + oldBounds.maxX) / 2
      centerY = (oldBounds.minY + oldBounds.maxY) / 2
    }

    // Update point positions
    this.controller.scatterContainer.children.forEach(point => {
      if (point.isPoint && point.cellId !== undefined) {
        const [x, y] = this.controller.currentCoordinates[point.cellId]
        
        // Transform coordinates
        const newX = centerX + (x - centerX) * scaleX
        const newY = centerY + (y - centerY) * scaleY
        
        // Update screen position
        point.x = this.controller.normalizeX(newX, newBounds)
        point.y = this.controller.normalizeY(newY, newBounds)
      }
    })
  }

  // Setup global drag handlers for labels
  setupGlobalDragHandlers() {
    if (!this.controller.pixiApp || !this.controller.pixiApp.stage) return

    // Global pointer move handler for label dragging
    this.controller.pixiApp.stage.on('pointermove', (event) => {
      if (this.draggingLabel) {
        const globalPos = event.global
        this.draggingLabel.x = globalPos.x
        this.draggingLabel.y = globalPos.y
      }
    })

    // Global pointer up handler for label dragging
    this.controller.pixiApp.stage.on('pointerup', () => {
      if (this.draggingLabel) {
        this.draggingLabel.alpha = 1.0
        this.draggingLabel = null
      }
    })

    this.controller.pixiApp.stage.on('pointerupoutside', () => {
      if (this.draggingLabel) {
        this.draggingLabel.alpha = 1.0
        this.draggingLabel = null
      }
    })
  }

  // Reset zoom and pan
  resetZoomAndPan() {
    if (!this.controller.currentCoordinates) return

    // Calculate original bounds
    const originalBounds = this.controller.calculateBounds(this.controller.currentCoordinates)
    
    // Update bounds
    this.controller.currentBounds = this.controller.getAdjustedBounds(originalBounds)
    
    // Force re-render all points with original bounds
    this.controller.scatterContainer.removeChildren()
    this.controller.renderPointsWithCurrentColoring()
    
    // Update axes, grid, and category labels
    this.controller.renderAxes()
    this.controller.renderGrid()
    this.controller.renderCategoryLabels()
  }

  // Cleanup method
  destroy() {
    this.removeInteractionEventListeners()
    this.clearLasso()
    this.draggingLabel = null
  }
}
