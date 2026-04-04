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
    // console.log('🔧 Setting up interaction system')
    
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
      // console.log('Interaction mode buttons not found')
    }
    
    // Set up canvas event listeners when the plot canvas is ready
    this.setupCanvasListeners()
  }

  setupCanvasListeners() {
    // console.log('Setting up canvas listeners')
    
    // Canvas should exist now since this is called after canvas creation
    if (this.controller.canvas && !this.controller.canvasListenersSetup) {
      // console.log('Canvas found, setting up interaction listeners')
      this.controller.addInteractionEventListeners()
      this.controller.canvasListenersSetup = true
    } else {
      // console.log('Canvas not available for interaction setup')
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
    
    // Add interaction event listeners (ReGL plot canvas)
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
    const normalized = margins.left + ((x - bounds.minX) / (bounds.maxX - bounds.minX)) * availableWidth
    
    // Debug logging for every normalization call during panning
    // if (this.controller.isPanning) {
    //   console.log(`🔍 [NORMALIZE] normalizeX: x=${x.toFixed(3)}, bounds=(${bounds.minX.toFixed(2)}, ${bounds.maxX.toFixed(2)}), screenWidth=${screenWidth}, availableWidth=${availableWidth}, margins.left=${margins.left}, result=${normalized.toFixed(1)}`)
    // } else if (!this._normalizeLogged) {
    //   console.log(`🔍 [NORMALIZE] normalizeX: x=${x.toFixed(3)}, bounds=(${bounds.minX.toFixed(2)}, ${bounds.maxX.toFixed(2)}), screenWidth=${screenWidth}, availableWidth=${availableWidth}, margins.left=${margins.left}, result=${normalized.toFixed(1)}`)
    //   this._normalizeLogged = true
    // }
    
    return normalized
  }

  normalizeY(y, bounds) {
    // Invert Y-axis: higher Y values appear at the top, lower Y values at the bottom
    const margins = this.rendererManager.getPlotMargins()
    const screenHeight = this.controller.canvas.height
    const availableHeight = screenHeight - margins.top - margins.bottom
    const normalized = margins.top + availableHeight - ((y - bounds.minY) / (bounds.maxY - bounds.minY)) * availableHeight
    
    // Debug logging for every normalization call during panning
    // if (this.controller.isPanning) {
    //   console.log(`🔍 [NORMALIZE] normalizeY: y=${y.toFixed(3)}, bounds=(${bounds.minY.toFixed(2)}, ${bounds.maxY.toFixed(2)}), screenHeight=${screenHeight}, availableHeight=${availableHeight}, margins.top=${margins.top}, result=${normalized.toFixed(1)}`)
    // } else if (!this._normalizeYLogged) {
    //   console.log(`🔍 [NORMALIZE] normalizeY: y=${y.toFixed(3)}, bounds=(${bounds.minY.toFixed(2)}, ${bounds.maxY.toFixed(2)}), screenHeight=${screenHeight}, availableHeight=${availableHeight}, margins.top=${margins.top}, result=${normalized.toFixed(1)}`)
    //   this._normalizeYLogged = true
    // }
    
    return normalized
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
