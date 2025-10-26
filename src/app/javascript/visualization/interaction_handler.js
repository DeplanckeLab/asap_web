/**
 * Interaction Handler Module
 * Handles mouse/touch interactions (pan, zoom, lasso, pick)
 */

export class InteractionHandler {
  constructor(controller, rendererManager) {
    this.controller = controller
    this.rendererManager = rendererManager
  }

  // Interaction setup
  setupInteractionSystem() {
    console.log('🔧 Setting up interaction system')
    
    // Set up interaction mode buttons
    const panBtn = document.getElementById('pan-mode-btn')
    const pickBtn = document.getElementById('pick-mode-btn')
    const lassoBtn = document.getElementById('lasso-mode-btn')
    if (panBtn && pickBtn && lassoBtn) {
      //console.log('Found interaction mode buttons')
      // Set initial state (pick mode is default)
      this.controller.updateButtonStates('pick')
      this.controller.updateControlInstructions()
    } else {
      console.log('Interaction mode buttons not found')
    }
    
    // Set up canvas event listeners when PIXI app becomes available
    this.setupCanvasListeners()
  }

  setupCanvasListeners() {
    console.log('Setting up canvas listeners')
    
    // Canvas should exist now since this is called after canvas creation
    if (this.controller.canvas && !this.controller.canvasListenersSetup) {
      console.log('Canvas found, setting up interaction listeners')
      this.controller.addInteractionEventListeners()
      this.controller.canvasListenersSetup = true
    } else {
      console.log('Canvas not available for interaction setup')
    }
  }

  addInteractionHandlers() {
    // Set initial cursor based on interaction mode
    const canvas = this.controller.canvas
    if (canvas) {
      if (this.controller.interactionMode === 'pan') {
        canvas.style.cursor = 'grab'
      } else if (this.controller.interactionMode === 'lasso') {
        canvas.style.cursor = 'crosshair'
      }
    }
    
    // Add our new interaction event listeners (works for both ReGL and PixiJS)
    this.controller.addInteractionEventListeners()
  }

  // Mouse event handlers
  onInteractionMouseDown(event) {
    return this.controller.onInteractionMouseDown(event)
  }

  onInteractionMouseMove(event) {
    return this.controller.onInteractionMouseMove(event)
  }

  onInteractionMouseUp(event) {
    return this.controller.onInteractionMouseUp(event)
  }

  onInteractionDoubleClick(event) {
    return this.controller.onInteractionDoubleClick(event)
  }

  onInteractionWheel(event) {
    return this.controller.onInteractionWheel(event)
  }

  // Pan mode handlers
  onPanMouseDown(event) {
    return this.controller.onPanMouseDown(event)
  }

  onPanMouseMove(event) {
    return this.controller.onPanMouseMove(event)
  }

  onPanMouseUp(event) {
    return this.controller.onPanMouseUp(event)
  }

  onPanDoubleClick(event) {
    return this.controller.onPanDoubleClick(event)
  }

  // Pick mode handlers
  onPickMouseDown(event) {
    return this.controller.onPickMouseDown(event)
  }

  onPickMouseMove(event) {
    return this.controller.onPickMouseMove(event)
  }

  onPickMouseUp(event) {
    return this.controller.onPickMouseUp(event)
  }

  // Lasso mode handlers
  onLassoMouseDown(event) {
    return this.controller.onLassoMouseDown(event)
  }

  onLassoMouseMove(event) {
    return this.controller.onLassoMouseMove(event)
  }

  onLassoMouseUp(event) {
    return this.controller.onLassoMouseUp(event)
  }

  onLassoDoubleClick(event) {
    return this.controller.onLassoDoubleClick(event)
  }

  // View manipulation
  resetZoomAndPan() {
    return this.controller.resetZoomAndPan()
  }

  // Coordinate utilities
  calculateBounds(coordinates) {
    return this.controller.dataManager.calculateBounds(coordinates)
  }


  normalizeX(x, bounds) {
    const margins = this.rendererManager.getPlotMargins()
    const screenWidth = this.controller.canvas.width
    const availableWidth = screenWidth - margins.left - margins.right
    return margins.left + ((x - bounds.minX) / (bounds.maxX - bounds.minX)) * availableWidth
  }

  normalizeY(y, bounds) {
    // Invert Y-axis: higher Y values appear at the top, lower Y values at the bottom
    const margins = this.rendererManager.getPlotMargins()
    const screenHeight = this.controller.canvas.height
    const availableHeight = screenHeight - margins.top - margins.bottom
    return margins.top + availableHeight - ((y - bounds.minY) / (bounds.maxY - bounds.minY)) * availableHeight
  }

  extractCurrentScreenPositions(currentBounds, coordinateCount) {
    return this.controller.extractCurrentScreenPositions(currentBounds, coordinateCount)
  }

  // Point detection and hovering
  detectRegLPointHover(event) {
    return this.controller.detectRegLPointHover(event)
  }

  // Selection management
  clearLasso() {
    return this.controller.clearLasso()
  }

  cancelSelection() {
    return this.controller.cancelSelection()
  }
}
