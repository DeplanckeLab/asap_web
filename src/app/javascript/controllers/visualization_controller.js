import { Controller } from "@hotwired/stimulus"

console.log('Visualization controller file loaded - VERSION 2.0 WITH NEW LOGGING')

export default class extends Controller {
  static targets = ["loomFileSelect", "embeddingSelect", "metadataSelect"]
  static values = { 
    embeddingsByLoom: Object,
    defaultLoomFile: String
  }

  connect() {
    console.log('🚀 Visualization controller connected')
    
    // Initialize selected categories tracking
    this.selectedCategories = {}
    this.selectedRanges = {} // Store continuous metadata ranges for filtering
    this.loadedMetadataVectors = {} // Store all loaded metadata vectors for filtering
    this.currentVisibleCells = null // Track currently visible cells (null = all visible)
    this.lastFilterState = null // Track last filter state for incremental updates
    this.filterCache = new Map() // Cache for intersection results
    
    // Performance optimization: throttling for range slider updates
    this.rangeSliderUpdateScheduled = false
    this.lastLegendUpdate = 0
    
    // Track embedding method for animation decisions
    this.currentEmbeddingMethod = null
    this.previousEmbeddingMethod = null
    
    // Initialize color scheme for continuous metadata
    this.currentColorScheme = 'blue-green-red'
    
    // Initialize color range controls for continuous metadata
    this.customColorRange = null // { min: number, max: number } or null for auto
    
    // Initialize inline range slider data storage
    this.inlineRangeSliderData = {} // Store range slider data for each metadata
    
    // Performance optimization: store existing points for visibility updates
    this.existingPoints = null // Array of existing PIXI point objects
    this.lastMetadataVector = null // Track last metadata for optimization
    this.lastPointSize = null // Track last point size for optimization
    this.visibilityOnlyUpdate = false // When true, try to only toggle visibility
    
    // Expose controller globally for range slider access
    window.visualizationController = this
    
    // Don't initialize checkboxes yet - wait for metadata vectors to be loaded
    
    // Simple test - remove this after debugging
    /*setTimeout(() => {
      console.log('Controller test: Water drop buttons found:', document.querySelectorAll('[data-action*="waterDropClicked"]').length)
    }, 1000)
    console.log('Available targets:', {
      hasLoomFileSelectTarget: this.hasLoomFileSelectTarget,
      hasEmbeddingSelectTarget: this.hasEmbeddingSelectTarget
    })
    console.log('Available values:', {
      hasDefaultLoomFileValue: this.hasDefaultLoomFileValue,
      hasEmbeddingsByLoomValue: this.hasEmbeddingsByLoomValue,
      defaultLoomFileValue: this.defaultLoomFileValue
    })
    */
    // Test color loading immediately
    //console.log('Controller connecting - testing global colors availability:')
    //console.log('window.CATEGORY_COLORS:', window.CATEGORY_COLORS)
    //console.log('typeof window.CATEGORY_COLORS:', typeof window.CATEGORY_COLORS)
    //console.log('window.CATEGORY_COLORS length:', window.CATEGORY_COLORS?.length)
    //console.log('window object keys:', Object.keys(window).filter(k => k.includes('CATEGORY')))
    
    if (!window.CATEGORY_COLORS || window.CATEGORY_COLORS.length === 0) {
      console.error('CRITICAL: No global colors available! This will cause visualization errors.')
      console.error('Available window properties:', Object.keys(window).slice(0, 10))
      
      // Try again after a short delay in case colors are loaded asynchronously
      setTimeout(() => {
        //console.log('Delayed check - window.CATEGORY_COLORS:', window.CATEGORY_COLORS)
        if (window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0) {
          //console.log('Colors loaded after delay!')
          // Clear cache to get fresh colors
          this.clearCategoryColorsCache()
        } else {
          console.error('Still no colors after delay')
        }
      }, 1000)
    } else {
      //console.log('Global colors are available!')
      // Clear cache to get fresh colors
      this.clearCategoryColorsCache()
    }
    
    // Set the default loom file selection
    if (this.hasDefaultLoomFileValue && this.hasLoomFileSelectTarget) {
      this.loomFileSelectTarget.value = this.defaultLoomFileValue
      this.updateEmbeddings()
    }
    
    // Add click outside listener to close dropdowns
    this.boundCloseDropdowns = this.closeAllDropdowns.bind(this)
    document.addEventListener('click', this.boundCloseDropdowns)
    
    // Initialize draggable divider
    setTimeout(() => {
      this.initializeDraggableDivider()
    }, 500)
    
    // Initialize metadata vectors storage
    this.loadedMetadataVectors = {}
    this.loadingMetadataVectors = new Set() // Track which vectors are currently loading
    
    // Initialize interaction mode state
    this.interactionMode = 'pick' // 'pick', 'pan', 'lasso', or 'zoom'
    this.selectedCells = new Set()
    this.originalPointColors = new Map() // Store original colors for reset functionality
    this.draggingLabel = null // Track which label is being dragged
    this.clickingOnLabel = false // Track if we're clicking on a label
    //console.log(`Initializing currentPointSize to: 1.0 (was: ${this.currentPointSize})`)
    this.currentPointSize = 1.0 // Store current point size for consistent rendering
    this.lassoGraphics = null
    this.lassoPoints = []
    this.isDrawingLasso = false
    this.lastMouseMoveTime = 0
    this.mouseMoveCount = 0
    this.minLassoPointDistance = 8 // Minimum distance between lasso points in pixels
    this.lassoAnimationFrame = null // For smooth rendering
    
    // Initialize tooltip state
    this.tooltip = null
    this.tooltipContent = null
    
    // Zoom mode state
    this.isDrawingZoom = false
    this.isZooming = false
    this.zoomStartX = 0
    this.zoomStartY = 0
    this.zoomGraphics = null
    this.wheelZoomTimeout = null
    
    // Pan mode state
    this.isPanning = false
    this.panStartX = 0
    this.panStartY = 0
    this.panStartBounds = null
    
    // Initialize interaction system after DOM is ready
    setTimeout(() => {
      this.setupInteractionSystem()
      this.initializeTooltip()
      // Initialize the selection count display
      this.updateSelectedCellsCount()
    }, 100)
    
    // No automatic loading - metadata will be loaded on-demand when needed
  }

  disconnect() {
    // Remove click outside listener when controller disconnects
    if (this.boundCloseDropdowns) {
      document.removeEventListener('click', this.boundCloseDropdowns)
    }
    
    // Remove interaction event listeners
    this.removeInteractionEventListeners()
    
    // Clean up any existing PIXI app
    if (this.pixiApp) {
      this.pixiApp.destroy(true)
      this.pixiApp = null
    }
  }
  
  testAction() {
    alert('Stimulus controller is working!')
  }

  initializeTooltip() {
    //console.log('🔧 Initializing tooltip system')
    this.tooltip = document.getElementById('point-tooltip')
    this.tooltipContent = document.getElementById('tooltip-content')
    
    if (!this.tooltip || !this.tooltipContent) {
      console.warn('Tooltip elements not found, creating dynamically:', {
        tooltip: !!this.tooltip,
        tooltipContent: !!this.tooltipContent,
        tooltipElement: this.tooltip,
        contentElement: this.tooltipContent
      })
      
      // Create tooltip dynamically
      this.createTooltipDynamically()
      return
    }
    
    /*console.log('Tooltip system initialized successfully:', {
      tooltip: this.tooltip,
      tooltipContent: this.tooltipContent,
      tooltipTagName: this.tooltip.tagName,
      tooltipId: this.tooltip.id
    })*/
  }

  createTooltipDynamically() {
    //console.log('Creating tooltip dynamically')
    
    // Remove existing tooltip if it exists
    const existingTooltip = document.getElementById('point-tooltip')
    if (existingTooltip) {
      existingTooltip.remove()
    }
    
    // Create tooltip element
    this.tooltip = document.createElement('div')
    this.tooltip.id = 'point-tooltip'
    
    // Set styles individually for better compatibility
    this.tooltip.style.position = 'fixed'
    this.tooltip.style.backgroundColor = 'red'
    this.tooltip.style.color = 'white'
    this.tooltip.style.padding = '12px 16px'
    this.tooltip.style.borderRadius = '6px'
    this.tooltip.style.fontSize = '16px'
    this.tooltip.style.pointerEvents = 'none'
    this.tooltip.style.zIndex = '999999'
    this.tooltip.style.display = 'none'
    this.tooltip.style.maxWidth = '200px'
    this.tooltip.style.wordWrap = 'break-word'
    this.tooltip.style.boxShadow = '0 4px 6px rgba(0, 0, 0, 0.3)'
    this.tooltip.style.border = '3px solid yellow'
    this.tooltip.style.left = '50px'
    this.tooltip.style.top = '50px'
    
    // Create content element
    this.tooltipContent = document.createElement('div')
    this.tooltipContent.id = 'tooltip-content'
    this.tooltip.appendChild(this.tooltipContent)
    
    // Add to body
    document.body.appendChild(this.tooltip)
    
    /*console.log('Tooltip created dynamically:', {
      tooltip: this.tooltip,
      tooltipContent: this.tooltipContent,
      parentNode: this.tooltip.parentNode
    })*/
  }

  setupInteractionSystem() {
    console.log('🔧 Setting up interaction system')
    
    // Set up interaction mode buttons
    const panBtn = document.getElementById('pan-mode-btn')
    const pickBtn = document.getElementById('pick-mode-btn')
    const lassoBtn = document.getElementById('lasso-mode-btn')
    if (panBtn && pickBtn && lassoBtn) {
      //console.log('Found interaction mode buttons')
      // Set initial state (pick mode is default)
      this.updateButtonStates('pick')
      this.updateControlInstructions()
    } else {
      console.log('Interaction mode buttons not found')
    }
    
    // Set up canvas event listeners when PIXI app becomes available
    this.setupCanvasListeners()
  }

  setupCanvasListeners() {
    //console.log('Setting up canvas listeners')
    
    // This will be called when the PIXI app is created
    // For now, we'll set up a polling mechanism to check for the canvas
    const checkForCanvas = () => {
      const canvas = document.querySelector('.plot-container canvas')
      //console.log('Checking for canvas:', !!canvas, 'Setup done:', !!this.canvasListenersSetup)
      
      if (canvas && !this.canvasListenersSetup) {
        //console.log('Canvas found, setting up interaction listeners')
        this.canvas = canvas
        this.addInteractionEventListeners()
        this.canvasListenersSetup = true
      } else if (!canvas) {
        console.log('Canvas not found yet, checking again in 500ms')
        // Keep checking every 500ms until canvas is available
        setTimeout(checkForCanvas, 500)
      }
    }
    
    checkForCanvas()
  }

  updateEmbeddings() {
    if (!this.hasLoomFileSelectTarget || !this.hasEmbeddingSelectTarget || !this.hasEmbeddingsByLoomValue) {
      console.log('Required targets or values not available')
      return
    }
    
    const selectedLoomFile = this.loomFileSelectTarget.value
    const embeddings = this.embeddingsByLoomValue[selectedLoomFile] || []
    
    // Clear current options
    this.embeddingSelectTarget.innerHTML = '<option selected>Select embedding...</option>'
    
    // Add new options
    embeddings.forEach(embedding => {
      const option = document.createElement('option')
      option.value = embedding.id
      option.textContent = embedding.display_name
      this.embeddingSelectTarget.appendChild(option)
    })
  }

  updateMetadata() {
    if (!this.hasMetadataSelectTarget) {
      console.log('Metadata select target not available')
      return
    }
    
    const selectedMetadataId = this.metadataSelectTarget.value
    //console.log('Selected metadata ID:', selectedMetadataId)
    
    if (selectedMetadataId) {
      this.loadMetadataCoordinates(selectedMetadataId)
    } else {
      // Clear any existing metadata data
      this.clearMetadataData()
    }
  }

  async loadMetadataCoordinates(metadataId) {
    try {
      //console.log('Loading metadata coordinates for ID:', metadataId)
      
      // Get the current loom file selection
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : null
      
      // Build the URL for the metadata coordinates endpoint
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_coordinates?metadata_id=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      //console.log('Fetching binary data from URL:', url)
      
      // Get CSRF token safely
      const csrfMetaTag = document.querySelector('meta[name="csrf-token"]')
      const csrfToken = csrfMetaTag?.getAttribute('content')
      
      /*console.log('CSRF token debug:', {
        metaTagFound: !!csrfMetaTag,
        tokenValue: csrfToken ? 'present' : 'missing'
      })*/
      
      const headers = {
        'Accept': 'application/octet-stream'
      }
      
      if (csrfToken) {
        headers['X-CSRF-Token'] = csrfToken
      } else {
        console.warn('CSRF token not found, request may fail authentication')
      }
      
      const response = await fetch(url, {
        method: 'GET',
        headers: headers,
        credentials: 'same-origin'
      })
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      
      // Check if we got binary data or JSON error
      const contentType = response.headers.get('content-type')
      if (contentType && contentType.includes('application/json')) {
        const errorData = await response.json()
        console.error('Error from server:', errorData.error)
        alert(`Error loading metadata: ${errorData.error}`)
        return
      }
      
      // Extract metadata from headers
      const headerMetadataId = response.headers.get('X-Metadata-ID')
      const metadataName = response.headers.get('X-Metadata-Name')
      const cellCount = parseInt(response.headers.get('X-Cell-Count'))
      
      /*console.log('Received binary metadata data:', {
        metadataId: headerMetadataId,
        metadataName,
        cellCount,
        binarySize: response.headers.get('content-length')
      })*/
      
      // Get the binary data as ArrayBuffer
      const arrayBuffer = await response.arrayBuffer()
      
      /*console.log('ArrayBuffer details:', {
        byteLength: arrayBuffer.byteLength,
        expectedLength: cellCount * 4, // 4 bytes per coordinate pair
        isValid: arrayBuffer.byteLength === cellCount * 4
      })*/
      
      // Log first few bytes for debugging
      const view = new Uint8Array(arrayBuffer)
      //console.log('First 20 bytes of binary data:', Array.from(view.slice(0, 20)))
      //console.log('Last 20 bytes of binary data:', Array.from(view.slice(-20)))
      
      // Store the binary coordinate data
      this.storeBinaryMetadataData({
        id: headerMetadataId,
        name: metadataName,
        cellCount: cellCount,
        binaryData: arrayBuffer
      })
      
    } catch (error) {
      console.error('Error loading metadata coordinates:', error)
      alert(`Failed to load metadata coordinates: ${error.message}`)
    }
  }

  storeBinaryMetadataData(data) {
    // Store the binary coordinate data for later use
    // The coordinates are stored as 16-bit signed integers in binary format
    // Each coordinate pair takes 4 bytes (2 bytes for x, 2 bytes for y)
    
    this.metadataData = {
      id: data.id,
      name: data.name,
      cellCount: data.cellCount,
      binaryData: data.binaryData, // ArrayBuffer with binary data
      loadedAt: Date.now()
    }
    
    const binarySize = data.binaryData.byteLength
    const expectedSize = data.cellCount * 4 // 4 bytes per coordinate pair (2 coordinates * 2 bytes each)
    const compressionRatio = (data.cellCount * 2 * 8) / (binarySize * 8) // bits comparison
    
    /*console.log(`Stored binary metadata data for ${data.name}:`, {
      cellCount: data.cellCount,
      binarySize: binarySize,
      expectedSize: expectedSize,
      compressionRatio: compressionRatio.toFixed(2) + 'x',
      memoryEfficiency: ((1 - binarySize / (data.cellCount * 2 * 8)) * 100).toFixed(1) + '%'
    })*/
    
    // Update visualization with the new coordinate data
    this.updateVisualizationWithMetadata()
  }

  clearMetadataData() {
    this.metadataData = null
    //console.log('Cleared metadata data')
    
    // Clear PIXI.js visualization
    if (this.pixiApp) {
      this.pixiApp.destroy(true)
      this.pixiApp = null
      this.scatterContainer = null
    }
    
    // Show placeholder and hide plot info
    const placeholder = document.getElementById('plot-placeholder')
    const plotInfo = document.getElementById('plot-info')
    if (placeholder) placeholder.style.display = 'block'
    if (plotInfo) plotInfo.style.display = 'none'
    
    // Clear plot container
    const plotContainer = document.querySelector('.plot-container')
    if (plotContainer) {
      plotContainer.innerHTML = `
        <div id="plot-placeholder" style="position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); text-align: center; color: #6b7280;">
          <h3 style="margin: 0 0 10px 0;">UMAP Plot</h3>
          <p style="margin: 0;">Select metadata from the dropdown to visualize</p>
        </div>
      `
    }
  }

  updateVisualizationWithMetadata() {
    if (!this.metadataData) {
      console.log('No metadata data to visualize')
      return
    }
    
    //console.log('Updating visualization with metadata:', this.metadataData.name)
    
    // Decompress the binary coordinate data for visualization
    const decompressedCoords = this.decompressBinaryCoordinates(this.metadataData.binaryData)
    
    // Initialize PIXI.js scatter plot
    this.initializePixiScatterPlot(decompressedCoords)
    
    //console.log(`Decompressed ${decompressedCoords.length} coordinate pairs for visualization`)
  }

  async initializePixiScatterPlot(coordinates) {
    try {
      // Check if PIXI.js is loaded globally
      console.log('Checking PIXI availability:', typeof PIXI, PIXI)
      if (typeof PIXI === 'undefined') {
        console.error('PIXI.js is not loaded. Please ensure the script tag is present.')
        return
      }

      //console.log('Using global PIXI:', PIXI)
      //console.log('PIXI.Application:', PIXI.Application)

      // Find the plot container
      const plotContainer = document.querySelector('.plot-container')
      if (!plotContainer) {
        console.error('Plot container not found')
        return
      }
      
      //console.log('DEBUG: Checking conditions for updateScatterPlot')
      //console.log('DEBUG: this.pixiApp exists:', !!this.pixiApp)
      //console.log('DEBUG: this.currentLoomFile:', this.currentLoomFile)
      //console.log('DEBUG: this.loomFileSelectTarget.value:', this.loomFileSelectTarget.value)
      //console.log('DEBUG: Files match:', this.currentLoomFile === this.loomFileSelectTarget.value)
      
      // Check if we already have a PIXI app for this loom file
      if (this.pixiApp && this.currentLoomFile === this.loomFileSelectTarget.value) {
        //console.log('Changing visualization coordinates - animating transition')
        // Clear selection since coordinates might have changed
        this.selectedCells.clear()
        this.updateSelectedCellsCount()
        // Use updateScatterPlot to animate coordinate changes
        await this.updateScatterPlot(coordinates)
        return
      }
      
      //console.log('Creating new PIXI.js scatter plot')
      
      // Clear any existing PIXI app
      if (this.pixiApp) {
        this.pixiApp.destroy(true)
      }
      
      // Store PIXI reference for later use
      this.PIXI = PIXI
      
      // Use global PIXI.Application
      const Application = PIXI.Application
      
      //console.log('Using Application constructor:', Application)
      
      this.pixiApp = new Application({
        width: plotContainer.clientWidth,
        height: plotContainer.clientHeight,
        backgroundColor: 0xffffff,
        antialias: true,
        resolution: window.devicePixelRatio || 1,
        autoDensity: true
      })
      
      // Add PIXI canvas to the container
      plotContainer.innerHTML = ''
      plotContainer.appendChild(this.pixiApp.view)
      console.log('PIXI canvas added to container:', this.pixiApp.view)
      
      // Hide placeholder and show plot info
      const placeholder = document.getElementById('plot-placeholder')
      const plotInfo = document.getElementById('plot-info')
      if (placeholder) placeholder.style.display = 'none'
      if (plotInfo) plotInfo.style.display = 'block'
      
      // Create grid container (bottom layer)
      this.gridContainer = new PIXI.Container()
      this.gridContainer.visible = true // Initially visible
      this.pixiApp.stage.addChild(this.gridContainer)
      
     

      // Create main container for the scatter plot (top layer)
      this.scatterContainer = new PIXI.Container()
      this.pixiApp.stage.addChild(this.scatterContainer)
      
      // Create category labels container (topmost layer)
      this.categoryLabelsContainer = new PIXI.Container()
      this.categoryLabelsContainer.visible = true // Initially visible
      this.pixiApp.stage.addChild(this.categoryLabelsContainer)
      
      
      // Create axes container (middle layer)
      this.axesContainer = new PIXI.Container()
      this.axesContainer.visible = true // Initially visible
      this.pixiApp.stage.addChild(this.axesContainer)

      // Store current loom file
      this.currentLoomFile = this.loomFileSelectTarget.value
      
      // Render the scatter plot
      await this.renderScatterPlot(coordinates)
      
      // Add interaction handlers
      this.addInteractionHandlers()
      
      // Setup global drag handlers for label dragging
      this.setupGlobalDragHandlers()
      
      //console.log('PIXI.js scatter plot initialized successfully')
      
    } catch (error) {
      console.error('Failed to initialize PIXI.js scatter plot:', error)
    }
  }

  async renderScatterPlot(coordinates) {
    if (!this.pixiApp || !this.scatterContainer || !this.PIXI) return
    
    // Clear existing points
    this.scatterContainer.removeChildren()
    
    // Calculate bounds for normalization
    const originalBounds = this.calculateBounds(coordinates)
    const bounds = this.getAdjustedBounds(originalBounds)
    this.currentBounds = bounds // Store for future transitions
    this.currentCoordinates = coordinates // Store coordinates for future transitions
    //console.log('Coordinate bounds:', bounds)
    
    // Render axes, grid, and category labels
    this.renderAxes()
    this.renderGrid()
    this.renderCategoryLabels()
    
    // Set point properties
    const pointSize = this.currentPointSize
    const pointColor = 0x3b82f6 // Blue color
    
    // Render points individually to support pan/zoom optimization
    for (let i = 0; i < coordinates.length; i++) {
        const [x, y] = coordinates[i]
        
        // Normalize coordinates to screen space
        const screenX = this.normalizeX(x, bounds)
        const screenY = this.normalizeY(y, bounds)
        
      // Create individual point graphics
      const point = new PIXI.Graphics()
      point.beginFill(pointColor)
      point.drawCircle(0, 0, pointSize)
      point.endFill()
      point.x = screenX
      point.y = screenY
      
      // Store cell ID and mark as point for later reference
      point.cellId = i
      point.isPoint = true
      
      // Store original color for reset functionality
      this.storeOriginalPointColor(i, pointColor)
      
      // Add hover functionality
      point.interactive = true
      point.buttonMode = false
      point.on('pointerover', () => this.showTooltip(i, point))
      point.on('pointerout', () => this.hideTooltip())
      point.on('pointerdown', (event) => this.onPointClick(i, point, event))
      
      // Debug: Log point creation
      if (i < 5) { // Only log first 5 points to avoid spam
        console.log(`Created point ${i}:`, { 
          cellId: point.cellId, 
          isPoint: point.isPoint, 
          interactive: point.interactive,
          x: point.x, 
          y: point.y 
        })
      }
      
      this.scatterContainer.addChild(point)
    }
    
    //console.log(`Rendered ${coordinates.length} individual points`)
        
        // Update point count display
        const pointCountElement = document.getElementById('point-count')
        if (pointCountElement) {
          pointCountElement.textContent = coordinates.length.toLocaleString()
    }
    
    // Clear any stored original positions since points were recreated
    this.clearStoredOriginalPositions()
  }

  async updateScatterPlot(coordinates) {
    if (!this.pixiApp || !this.scatterContainer || !this.PIXI) return
    
    //console.log('Updating scatter plot with new coordinates')
    //console.log('Current bounds:', this.currentBounds)
    
    // Calculate new bounds
    const originalNewBounds = this.calculateBounds(coordinates)
    const newBounds = this.getAdjustedBounds(originalNewBounds)
    //console.log('New coordinate bounds:', newBounds)
    
    // Check if we have existing points to update
    const hasExistingPoints = this.scatterContainer.children.length > 0
    if (!hasExistingPoints) {
      console.log('No existing points found, falling back to full render')
      await this.renderScatterPlot(coordinates)
      return
    }
    
    // Store current bounds and coordinates for transition
    const currentBounds = this.currentBounds || newBounds
    const previousCoordinates = this.currentCoordinates || coordinates
    // console.log('Using bounds for transition - from:', currentBounds, 'to:', newBounds)
    // console.log('Previous coordinates count:', previousCoordinates.length, 'New coordinates count:', coordinates.length)
    
    // Check if embedding method changed (more accurate than bounds comparison)
    const embeddingChanged = this.detectEmbeddingMethodChange(coordinates)
    
    if (!embeddingChanged) {
      console.log('Same embedding method detected, no animation needed - re-rendering points with new coordinates')
      // Clear existing individual points and re-render
      this.scatterContainer.removeChildren()
      
      // Update bounds and render axes, grid, and category labels
      this.currentBounds = newBounds
      this.renderAxes()
      this.renderGrid()
      
      // Initialize checkboxes for current metadata if not already done (only for discrete)
      if (this.currentMetadataVector?.id && this.currentMetadataVector.data_type === 'DISCRETE' && !this.selectedCategories[this.currentMetadataVector.id]) {
        this.initializeCheckboxesForMetadata(this.currentMetadataVector.id)
      }
      
      this.renderCategoryLabels()
      
      // Re-render with new coordinates using current coloring
      this.renderPointsWithCurrentColoring()
      
      // Reapply filtering after coordinate update
      //console.log('Reapplying filtering after coordinate update...')
      this.updateCellFiltering()
      
      // Update point count display
      const pointCountElement = document.getElementById('point-count')
      if (pointCountElement) {
        pointCountElement.textContent = coordinates.length.toLocaleString()
      }
      return
    }
    
    //console.log('Different embedding method detected, creating animated transition')
    
    // Clear incremental filtering state when embedding changes
    // This ensures filtering works correctly with new coordinate indices
    this.clearIncrementalState()
    
    // Update bounds and render axes, grid, and category labels with new embedding bounds
    this.currentBounds = newBounds
    this.renderAxes()
    this.renderGrid()
    this.renderCategoryLabels()
    
    // Clean up any existing animated container
    if (this.animatedContainer) {
      this.scatterContainer.removeChild(this.animatedContainer)
    }
    
    // Clear all existing individual points before animation
    this.scatterContainer.removeChildren()
    
    // Create individual point sprites for animation using previous coordinates
    this.createAnimatedPoints(previousCoordinates, coordinates, currentBounds, newBounds)
    

    //console.log(`Created ${coordinates.length} animated points for transition`)
    
    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = coordinates.length.toLocaleString()
    }
  }

  // Update existing graphics object with current coloring scheme
  updatePointsWithCurrentColoring(graphics, coordinates, bounds) {
    const pointSize = this.currentPointSize

    // Check if we have metadata coloring active
    if (this.currentMetadataVector && this.currentMetadataVector.values) {
      const { data_type, values, compression_info } = this.currentMetadataVector

      // Ensure we have the same number of values as coordinates
      if (values.length !== coordinates.length) {
        console.error(`Mismatch: ${values.length} metadata values vs ${coordinates.length} coordinates`)
        // Fall back to default coloring
        this.renderPointsWithDefaultColor(graphics, coordinates, bounds, pointSize)
        return
      }

      if (data_type === 'DISCRETE') {
        // Render each point individually to support selection transparency
        for (let i = 0; i < coordinates.length; i++) {
          const [x, y] = coordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, bounds)
          const screenY = this.normalizeY(y, bounds)
          
          graphics.beginFill(color)
          graphics.alpha = alpha
          graphics.drawCircle(screenX, screenY, pointSize)
          graphics.endFill()
        }
        
        //console.log(`Updated ${coordinates.length} points with discrete metadata coloring (${this.currentMetadataVector.name})`)
        
      } else if (data_type === 'NUMERIC') {
        // Render each point individually to support selection transparency
        for (let i = 0; i < coordinates.length; i++) {
          const [x, y] = coordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, bounds)
          const screenY = this.normalizeY(y, bounds)
          
          graphics.beginFill(color)
          graphics.alpha = alpha
          graphics.drawCircle(screenX, screenY, pointSize)
          graphics.endFill()
        }
        
        //console.log(`Updated ${coordinates.length} points with continuous metadata coloring (${this.currentMetadataVector.name})`)
      }
    } else {
      // Render each point individually to support selection transparency
      //console.log('Using default blue coloring')
      for (let i = 0; i < coordinates.length; i++) {
        const [x, y] = coordinates[i]
        const { color, alpha } = this.getColorAndAlpha(i)
        
        const screenX = this.normalizeX(x, bounds)
        const screenY = this.normalizeY(y, bounds)
        
        graphics.beginFill(color)
        graphics.alpha = alpha
        graphics.drawCircle(screenX, screenY, pointSize)
        graphics.endFill()
      }
    }
  }

  // Render points with default blue color
  renderPointsWithDefaultColor(graphics, coordinates, bounds, pointSize) {
    const pointColor = 0x3b82f6 // Default blue color
    
    graphics.beginFill(pointColor)
    for (let i = 0; i < coordinates.length; i++) {
      const [x, y] = coordinates[i]
      const screenX = this.normalizeX(x, bounds)
      const screenY = this.normalizeY(y, bounds)
      graphics.drawCircle(screenX, screenY, pointSize)
    }
    graphics.endFill()
    
    //console.log(`Rendered ${coordinates.length} points with default blue color`)
  }

  // Helper method to get color and alpha separately for PIXI.js
  getColorAndAlpha(pointIndex) {
    const hasSelection = this.selectedCells && this.selectedCells.size > 0
    const isSelected = this.selectedCells && this.selectedCells.has(pointIndex)
    
    // Check for selection coloring first (highest priority)
    if (isSelected) {
      return { color: 0xff0000, alpha: 1.0 } // Red for selected points
    }

    // Check for metadata coloring
    let baseColor = 0x3b82f6 // Default blue color
    if (this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[pointIndex] !== undefined) {
      const { data_type, values, compression_info } = this.currentMetadataVector
      const value = values[pointIndex]
      
      if (data_type === 'DISCRETE') {
        // Cache the color map to avoid recalculating for every point
        if (!this._cachedColorMap) {
          const sortedCategories = this.getSortedCategories(values, [...compression_info.categories])
          this._cachedColorMap = this.createDiscreteColorMap(sortedCategories, this.currentMetadataId)
        }
        baseColor = this._cachedColorMap[value] || 0x3b82f6
      } else if (data_type === 'NUMERIC') {
        const effectiveRange = this.getEffectiveColorRange()
        if (effectiveRange) {
          const { min: minVal, max: maxVal } = effectiveRange
          const range = maxVal - minVal
          const normalizedValue = (value - minVal) / range
          baseColor = this.valueToColor(normalizedValue)
        } else {
          // Fallback to original compression info
          const minVal = compression_info.min_val
          const maxVal = compression_info.max_val
          const range = maxVal - minVal
          const normalizedValue = (value - minVal) / range
          baseColor = this.valueToColor(normalizedValue)
        }
      }
    }

    // If there's a selection and this point is not selected, make it semi-transparent
    if (hasSelection && !isSelected) {
      return { color: baseColor, alpha: 0.3 } // 30% opacity for unselected points
    }

    return { color: baseColor, alpha: 1.0 }
  }

  // Centralized function to get the color for a point at a given index
  // This will be extended to handle all types of coloring (metadata, selection, filtering, etc.)
  getPointColor(pointIndex) {
    return this.getColorAndAlpha(pointIndex).color
  }

  extractCurrentScreenPositions(currentBounds, coordinateCount) {
    // Since we can't easily extract positions from individual PIXI Graphics objects,
    // we'll recreate the positions using the current bounds and coordinates
    // This is a limitation of PIXI Graphics - we need to store positions differently
    //console.log('Extracting current screen positions (recreating from bounds)')
    return currentBounds
  }

  createAnimatedPoints(previousCoordinates, newCoordinates, fromBounds, toBounds) {
    //console.log('Creating animated points from previous to new coordinates')
    const pointSize = this.currentPointSize // Use current point size setting
    const animationDuration = 1000 // 1 second for faster transitions
    
    //console.log('Creating animated points with current coloring scheme')
    
    // Create a container for points (this will be our standard structure)
    const pointsContainer = new this.PIXI.Container()
    this.scatterContainer.addChild(pointsContainer)
    this.animatedContainer = pointsContainer // Store reference for cleanup
    
    
    // Clear existing category labels during animation
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.removeChildren()
    }
    
    // Clear any existing individual points (they're already cleared by removeChildren() in updateScatterPlot)
    
    // Create individual point sprites
    const points = []
    let maxMovement = 0
    const minLength = Math.min(previousCoordinates.length, newCoordinates.length)
    
    // Sort point indices by category size (largest categories first) if we have metadata coloring
    let sortedIndices = Array.from({ length: minLength }, (_, i) => i)
    
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'DISCRETE' && this.currentMetadataVector.values) {
      const values = this.currentMetadataVector.values
      
      // Calculate category frequencies for layering (larger categories first)
      const categoryFrequencies = {}
      values.forEach(value => {
        categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
      })
      
      //console.log('Animation: Category frequencies for layering:', categoryFrequencies)
      
      // Sort point indices by category size (largest categories first, so they render in background)
      sortedIndices = sortedIndices.sort((a, b) => {
        const categoryA = values[a]
        const categoryB = values[b]
        const freqA = categoryFrequencies[categoryA]
        const freqB = categoryFrequencies[categoryB]
        return freqB - freqA // Descending order (largest first)
      })
      
      // Debug: Log the first few sorted indices and their categories
      //console.log('Animation: First 10 sorted point indices:', sortedIndices.slice(0, 10))
      //console.log('Animation: Categories for first 10 points:', sortedIndices.slice(0, 10).map(i => values[i]))
      //console.log('Animation: Frequencies for first 10 points:', sortedIndices.slice(0, 10).map(i => categoryFrequencies[values[i]]))
    }
    
    // Create points in sorted order (largest categories first)
    sortedIndices.forEach(i => {
      const [prevX, prevY] = previousCoordinates[i]
      const [newX, newY] = newCoordinates[i]
      
      // Calculate start and end positions
      const startX = this.normalizeX(prevX, fromBounds)
      const startY = this.normalizeY(prevY, fromBounds)
      const endX = this.normalizeX(newX, toBounds)
      const endY = this.normalizeY(newY, toBounds)
      
      // Track maximum movement for debugging
      const movement = Math.sqrt((endX - startX) ** 2 + (endY - startY) ** 2)
      maxMovement = Math.max(maxMovement, movement)
      
      // Determine point color using centralized color function
      const pointColor = this.getPointColor(i)
      
      // Create point sprite
      const point = new this.PIXI.Graphics()
      point.beginFill(pointColor)
      point.drawCircle(0, 0, pointSize)
      point.endFill()
      
      // Set initial position
      point.x = startX
      point.y = startY
      
      // Store cell ID and mark as point for later reference
      point.cellId = i
      point.isPoint = true
      
      // Store original color for reset functionality
      this.storeOriginalPointColor(i, pointColor)
      
      // Add hover functionality
      point.interactive = true
      point.buttonMode = false
      point.on('pointerover', () => this.showTooltip(i, point))
      point.on('pointerout', () => this.hideTooltip())
      point.on('pointerdown', (event) => this.onPointClick(i, point, event))
      
      pointsContainer.addChild(point)
      points.push({ sprite: point, startX, startY, endX, endY })
    })
    
    //console.log('Maximum point movement: ' + maxMovement.toFixed(2) + ' pixels')
    //console.log('Animation will run for ' + animationDuration + 'ms')
    
    // Get current filtered indices to respect filtering during animation
    const currentFilteredIndices = this.getIncrementalFilteredIndices()
    const filteredSet = currentFilteredIndices ? new Set(currentFilteredIndices) : null
    
    // Animate all points
    const startTime = Date.now()
    
    const animate = () => {
      const elapsed = Date.now() - startTime
      const progress = Math.min(elapsed / animationDuration, 1)
      
      // Easing function for smooth animation
      const easeProgress = 1 - Math.pow(1 - progress, 3) // ease-out cubic
      
      // Log progress every 500ms
      if (Math.floor(elapsed / 500) !== Math.floor((elapsed - 16) / 500)) {
        //console.log(`Animation progress: ${(progress * 100).toFixed(1)}% (${elapsed}ms)`)
      }
      
      // Update all point positions and visibility
      for (const point of points) {
        point.sprite.x = point.startX + (point.endX - point.startX) * easeProgress
        point.sprite.y = point.startY + (point.endY - point.startY) * easeProgress
        
        // Apply filtering during animation - hide points that should be hidden
        const shouldBeVisible = !filteredSet || filteredSet.has(point.sprite.cellId)
        point.sprite.visible = shouldBeVisible
      }
      
      
      if (progress < 1) {
        requestAnimationFrame(animate)
      } else {
        //console.log('Animation complete!')
        // Animation complete - keep the nested structure, no point movement needed
        const moveStartTime = performance.now()
        
        // Animation container now contains the final positioned points
        // We keep the structure: scatterContainer -> animatedContainer -> points
        // This is much more efficient and maintains consistency
        
        const moveEndTime = performance.now()
        console.log(`⏱️ Point structure maintained (no movement needed): ${(moveEndTime - moveStartTime).toFixed(2)}ms`)
        
        
        // Update stored coordinates and bounds for next transition
        this.currentBounds = toBounds
        this.currentCoordinates = newCoordinates
        
        // Clear animated labels
        const labelStartTime = performance.now()
        this.categoryLabelsContainer.removeChildren()
        
        // Update axes and grid with final bounds
        const axesStartTime = performance.now()
        this.renderAxes()
        this.renderGrid()
        const axesEndTime = performance.now()
        console.log(`⏱️ Axes/grid rendering took: ${(axesEndTime - axesStartTime).toFixed(2)}ms`)

        // Initialize checkboxes for current metadata if not already done (only for discrete)
        if (this.currentMetadataVector?.id && this.currentMetadataVector.data_type === 'DISCRETE' && !this.selectedCategories[this.currentMetadataVector.id]) {
          this.initializeCheckboxesForMetadata(this.currentMetadataVector.id)
        }

        const categoryLabelsStartTime = performance.now()
        this.renderCategoryLabels()
        const categoryLabelsEndTime = performance.now()
        console.log(`⏱️ Category labels rendering took: ${(categoryLabelsEndTime - categoryLabelsStartTime).toFixed(2)}ms`)
        
        const labelEndTime = performance.now()
        console.log(`⏱️ Total label setup took: ${(labelEndTime - labelStartTime).toFixed(2)}ms`)
        
        // Reapply filtering after embedding change
        const filteringStartTime = performance.now()
        this.updateCellFiltering()
        const filteringEndTime = performance.now()
        console.log(`⏱️ Cell filtering took: ${(filteringEndTime - filteringStartTime).toFixed(2)}ms`)
        
        //console.log('Animation finished - keeping animated points in final positions')
      }
    }
    
    // Start animation
    animate()
  }


  convertToGraphicsObject(newCoordinates, bounds, animatedContainer) {
    //console.log('Converting animated points back to efficient graphics object')
    
    // Remove animated container
    this.scatterContainer.removeChild(animatedContainer)
    
    // Create new efficient graphics object
    const graphics = new this.PIXI.Graphics()
    const pointSize = this.currentPointSize
    const pointColor = 0x3b82f6
    
    // Render points in batches for performance
    const batchSize = 10000
    let currentBatch = 0
    
    const renderBatch = () => {
      const start = currentBatch * batchSize
      const end = Math.min(start + batchSize, newCoordinates.length)
      
      graphics.beginFill(pointColor)
      
      for (let i = start; i < end; i++) {
        const [x, y] = newCoordinates[i]
        const screenX = this.normalizeX(x, bounds)
        const screenY = this.normalizeY(y, bounds)
        graphics.drawCircle(screenX, screenY, pointSize)
      }
      
      graphics.endFill()
      currentBatch++
      
      if (end < newCoordinates.length) {
        requestAnimationFrame(renderBatch)
      } else {
        // All points rendered, add to stage
        this.scatterContainer.addChild(graphics)
        this.currentBounds = bounds // Store new bounds for future transitions
        this.currentCoordinates = newCoordinates // Store new coordinates for future transitions
        //console.log(`Converted to efficient graphics object with ${newCoordinates.length} points`)
      }
    }
    
    // Start rendering
    renderBatch()
  }

  calculateBounds(coordinates) {
    if (coordinates.length === 0) return { minX: 0, maxX: 1, minY: 0, maxY: 1 }
    
    let minX = Infinity, maxX = -Infinity
    let minY = Infinity, maxY = -Infinity
    
    for (const [x, y] of coordinates) {
      minX = Math.min(minX, x)
      maxX = Math.max(maxX, x)
      minY = Math.min(minY, y)
      maxY = Math.max(maxY, y)
    }
    
    // Add some padding
    const paddingX = (maxX - minX) * 0.05
    const paddingY = (maxY - minY) * 0.05
    
    return {
      minX: minX - paddingX,
      maxX: maxX + paddingX,
      minY: minY - paddingY,
      maxY: maxY + paddingY
    }
  }

  // Get standardized margins for the plot
  getPlotMargins() {
    return {
      left: 60,    // Space for Y-axis labels
      right: 20,   // Right margin
      top: 20,     // Top margin
      bottom: 60   // Space for X-axis labels
    }
  }

  // Get bounds adjusted for axes margins
  getAdjustedBounds(originalBounds) {
    //console.log('getAdjustedBounds called with:', originalBounds)
    //console.log('axesContainer exists:', !!this.axesContainer)
    //console.log('axesContainer visible:', this.axesContainer ? this.axesContainer.visible : 'N/A')
    
    if (!originalBounds || !this.axesContainer || !this.axesContainer.visible) {
      //console.log('Returning original bounds (no adjustment needed)')
      return originalBounds
    }

    const { minX, maxX, minY, maxY } = originalBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height
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
    const adjustedMinX = minX - (margins.left * dataPerPixelX)
    const adjustedMaxX = maxX + (margins.right * dataPerPixelX)
    const adjustedMinY = minY - (margins.top * dataPerPixelY)
    const adjustedMaxY = maxY + (margins.bottom * dataPerPixelY)

    const adjustedBounds = {
      minX: adjustedMinX,
      maxX: adjustedMaxX,
      minY: adjustedMinY,
      maxY: adjustedMaxY
    }
    
    //console.log('Returning adjusted bounds:', adjustedBounds)
    return adjustedBounds
  }

  normalizeX(x, bounds) {
    const margins = this.getPlotMargins()
    const availableWidth = this.pixiApp.screen.width - margins.left - margins.right
    return margins.left + ((x - bounds.minX) / (bounds.maxX - bounds.minX)) * availableWidth
  }

  normalizeY(y, bounds) {
    // Invert Y-axis: higher Y values appear at the top, lower Y values at the bottom
    const margins = this.getPlotMargins()
    const availableHeight = this.pixiApp.screen.height - margins.top - margins.bottom
    return margins.top + availableHeight - ((y - bounds.minY) / (bounds.maxY - bounds.minY)) * availableHeight
  }

  addInteractionHandlers() {
    if (!this.pixiApp) return
    
    // Make the stage interactive
    this.pixiApp.stage.interactive = true
    
    // Set initial cursor based on interaction mode
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (canvas) {
      if (this.interactionMode === 'pan') {
        canvas.style.cursor = 'grab'
      } else if (this.interactionMode === 'lasso') {
        canvas.style.cursor = 'crosshair'
      }
    }
    
    // Add our new interaction event listeners
    this.addInteractionEventListeners()
  }

  decompressBinaryCoordinates(arrayBuffer) {
    // Convert binary data back to coordinate pairs
    // arrayBuffer contains 16-bit signed integers (little-endian)
    // Each coordinate pair takes 4 bytes (2 bytes for x, 2 bytes for y)
    
    /*console.log('Starting binary decompression:', {
      arrayBufferSize: arrayBuffer.byteLength,
      expectedPairs: arrayBuffer.byteLength / 4
    })*/
    
    const coordinates = []
    const view = new DataView(arrayBuffer)
    
    // Process 4 bytes at a time (2 coordinates * 2 bytes each)
    for (let i = 0; i < arrayBuffer.byteLength; i += 4) {
      if (i + 3 < arrayBuffer.byteLength) {
        // Read 16-bit signed integers (little-endian)
        const x = view.getInt16(i, true)     // true = little-endian
        const y = view.getInt16(i + 2, true)
        
        // Convert back to original precision (divide by 100 to allow larger coordinate ranges)
        // This allows coordinates up to ±327.67 instead of ±32.767
        const xFloat = x / 100
        const yFloat = y / 100
        
        coordinates.push([xFloat, yFloat])
        
        // Log first few coordinates for debugging
        if (coordinates.length <= 5) {
          console.log(`Coordinate ${coordinates.length}: [${x}, ${y}] -> [${xFloat}, ${yFloat}]`)
        }
      }
    }
    
    // Log coordinate statistics
    if (coordinates.length > 0) {
      const xValues = coordinates.map(coord => coord[0])
      const yValues = coordinates.map(coord => coord[1])
      
      console.log('Decompressed coordinate statistics:', {
        totalPairs: coordinates.length,
        xRange: [Math.min(...xValues), Math.max(...xValues)],
        yRange: [Math.min(...yValues), Math.max(...yValues)],
        first5: coordinates.slice(0, 5),
        last5: coordinates.slice(-5)
      })
    }
    
    return coordinates
  }

  // Load a single metadata vector on demand
  async loadSingleMetadataVector(metadataId) {
    console.log(`=== LOADING SINGLE METADATA VECTOR: ${metadataId} ===`)
    
    // Check if already loaded
    if (this.loadedMetadataVectors[metadataId]) {
      console.log(`Metadata vector ${metadataId} already loaded`)
      const cachedData = this.loadedMetadataVectors[metadataId]
      console.log('Cached data:', cachedData)
      console.log('Cached compressed_data:', cachedData.compressed_data)
      console.log('Cached compression_info:', cachedData.compression_info)
      return cachedData
    }
    
    // Check if currently loading
    if (this.loadingMetadataVectors.has(metadataId)) {
      //console.log(`Metadata vector ${metadataId} is currently loading, waiting...`)
      // Wait for the loading to complete
      while (this.loadingMetadataVectors.has(metadataId)) {
        await new Promise(resolve => setTimeout(resolve, 100))
      }
      return this.loadedMetadataVectors[metadataId]
    }
    
    // Mark as loading and show spinner
    this.loadingMetadataVectors.add(metadataId)
    this.showLoadingSpinner(metadataId)
    
    try {
      // Get the current loom file
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : this.defaultLoomFileValue
      
      // Build the URL for the single metadata vector endpoint
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      //console.log(`Fetching single metadata vector from URL: ${url}`)
      
      // Get CSRF token safely
      const csrfMetaTag = document.querySelector('meta[name="csrf-token"]')
      const csrfToken = csrfMetaTag?.getAttribute('content')
      
      const headers = {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
      
      if (csrfToken) {
        headers['X-CSRF-Token'] = csrfToken
      }
      
      const response = await fetch(url, {
        method: 'GET',
        headers: headers,
        credentials: 'same-origin'
      })
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      
      const data = await response.json()
      console.log('Received single metadata vector data:', data)
      
      // Store the loaded metadata vector
      const vectorData = data.metadata_vectors[metadataId]
      if (vectorData) {
        // Parse compression_info if it's a JSON string
        if (vectorData.compression_info && typeof vectorData.compression_info === 'string') {
          try {
            vectorData.compression_info = JSON.parse(vectorData.compression_info)
          } catch (e) {
            console.error('Failed to parse compression_info:', e)
          }
        }
        
        this.loadedMetadataVectors[metadataId] = vectorData
        this.metadataVectorsLoomFile = data.loom_file
        
        const info = vectorData.compression_info
        console.log(`Successfully loaded metadata ${vectorData.name} (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
        
        return vectorData
      } else {
        console.error(`Metadata vector ${metadataId} not found in response`)
        console.error('Available metadata IDs in response:', Object.keys(data.metadata_vectors || {}))
        throw new Error(`Metadata vector ${metadataId} not found in response`)
      }
      
    } catch (error) {
      console.error(`Error loading metadata vector ${metadataId}:`, error)
      return null
    } finally {
      // Remove from loading set and hide spinner
      this.loadingMetadataVectors.delete(metadataId)
      this.hideLoadingSpinner(metadataId)
    }
  }

  // Get loaded metadata vector for a specific metadata ID
  getLoadedMetadataVector(metadataId) {
    if (!this.loadedMetadataVectors) {
      console.log('No metadata vectors loaded yet')
      return null
    }
    
    const vectorData = this.loadedMetadataVectors[metadataId]
    if (!vectorData) {
      console.log(`No loaded vector found for metadata ID: ${metadataId}`)
      return null
    }
    
    //console.log(`Retrieved loaded vector for ${vectorData.name}:`, vectorData.compression_info)
    return vectorData
  }

  // Decompress discrete metadata vector from binary data
  decompressDiscreteMetadataVector(binaryData, compressionInfo) {
    //console.log('Decompressing discrete metadata vector:', compressionInfo)
    //console.log('Binary data type:', typeof binaryData, 'Binary data:', binaryData)
    
    // Handle optimized case: single category (no data needed)
    if (compressionInfo.single_category) {
      const { categories, category_index, length } = compressionInfo
      const categoryValue = categories[category_index] || 'Unknown'
      const categoryValues = new Array(length).fill(categoryValue)
      console.log(`Optimized single-category metadata: ${length} cells, all "${categoryValue}"`)
      return categoryValues
    }
    
    // Check if binaryData is valid
    if (!binaryData) {
      throw new Error('Binary data is null or undefined')
    }
    
    const { categories, bit_width, cell_count } = compressionInfo
    const indices = []
    
    // Convert Base64 string to ArrayBuffer if needed
    let arrayBuffer
    if (typeof binaryData === 'string') {
      // Decode Base64 string to binary data
      const binaryString = atob(binaryData)
      arrayBuffer = new ArrayBuffer(binaryString.length)
      const view = new Uint8Array(arrayBuffer)
      for (let i = 0; i < binaryString.length; i++) {
        view[i] = binaryString.charCodeAt(i)
      }
    } else {
      // Check if binaryData has a buffer property
      if (binaryData.buffer) {
        arrayBuffer = binaryData.buffer
      } else if (binaryData instanceof ArrayBuffer) {
        arrayBuffer = binaryData
      } else {
        throw new Error(`Invalid binary data format: ${typeof binaryData}, expected string, ArrayBuffer, or object with buffer property`)
      }
    }
    
    // Create a DataView for reading binary data
    const view = new DataView(arrayBuffer)
    
    // Read indices based on bit width
    switch (bit_width) {
      case 1:
        // Special case: unpack 8 indices per byte for 1-bit encoding
        for (let i = 0; i < cell_count; i++) {
          const byteIndex = Math.floor(i / 8)
          const bitIndex = i % 8
          const byte = view.getUint8(byteIndex)
          const index = (byte >> bitIndex) & 1
          indices.push(index)
        }
        break
      case 8:
        for (let i = 0; i < cell_count; i++) {
          indices.push(view.getUint8(i))
        }
        break
      case 16:
        for (let i = 0; i < cell_count; i++) {
          indices.push(view.getUint16(i * 2, true)) // little-endian
        }
        break
      case 32:
        for (let i = 0; i < cell_count; i++) {
          indices.push(view.getUint32(i * 4, true)) // little-endian
        }
        break
      default:
        throw new Error(`Unsupported bit width: ${bit_width}`)
    }
    
    // Convert indices back to category names
    const categoryValues = indices.map(index => categories[index] || 'Unknown')
    
    console.log(`Decompressed ${cell_count} discrete values:`, {
      first10: categoryValues.slice(0, 10),
      uniqueValues: [...new Set(categoryValues)].length,
      categories: categories.length
    })
    
    return categoryValues
  }

  // Decompress continuous metadata vector from binary data
  decompressContinuousMetadataVector(binaryData, compressionInfo) {
    //console.log('Decompressing continuous metadata vector:', compressionInfo)
    
    const { min_val, max_val, cell_count, bit_width } = compressionInfo
    const normalizedValues = []
    
    // Convert Base64 string to ArrayBuffer if needed
    let arrayBuffer
    if (typeof binaryData === 'string') {
      // Decode Base64 string to binary data
      const binaryString = atob(binaryData)
      arrayBuffer = new ArrayBuffer(binaryString.length)
      const view = new Uint8Array(arrayBuffer)
      for (let i = 0; i < binaryString.length; i++) {
        view[i] = binaryString.charCodeAt(i)
      }
    } else {
      arrayBuffer = binaryData.buffer || binaryData
    }
    
    // Create a DataView for reading binary data
    const view = new DataView(arrayBuffer)
    
    // Read normalized values
    for (let i = 0; i < cell_count; i++) {
      let normalized
      
      switch (bit_width) {
        case 16:
          normalized = view.getUint16(i * 2, true) // little-endian
          break
        default:
          throw new Error(`Unsupported bit width for continuous data: ${bit_width}`)
      }
      
      normalizedValues.push(normalized)
    }
    
    // Denormalize back to original range
    const range = max_val - min_val
    const numericValues = normalizedValues.map(normalized => {
      return min_val + (normalized / 65535) * range
    })
    
    /*console.log(`Decompressed ${cell_count} continuous values:`, {
      first10: numericValues.slice(0, 10),
      range: `${numericValues[0]?.toFixed(3)} to ${numericValues[cell_count-1]?.toFixed(3)}`,
      actualRange: `${Math.min(...numericValues).toFixed(3)} to ${Math.max(...numericValues).toFixed(3)}`
    })*/
    
    return numericValues
  }


  // Load and visualize metadata vector for a specific metadata ID
  async loadAndVisualizeMetadataVector(metadataId) {
    //console.log(`Loading and visualizing metadata vector for ID: ${metadataId}`)
    
    // Load the metadata vector on-demand
    let vectorData = await this.loadSingleMetadataVector(metadataId)
    
    if (!vectorData) {
      console.error('Failed to load metadata vector')
      return
    }
    
    // Validate the loaded data - handle both compressed and uncompressed data
    // Parse compression_info if it's a JSON string
    if (vectorData.compression_info && typeof vectorData.compression_info === 'string') {
      try {
        vectorData.compression_info = JSON.parse(vectorData.compression_info)
      } catch (e) {
        console.error('Failed to parse compression_info:', e)
      }
    }
    
    // Check if compression_info is a valid object (not an error string)
    const isValidCompressionInfo = vectorData.compression_info && 
                                  typeof vectorData.compression_info === 'object' && 
                                  !vectorData.compression_info.toString().includes('Unknown data type')
    
    // Handle single-category optimization (compressed_data can be null)
    const isSingleCategory = isValidCompressionInfo && vectorData.compression_info.single_category
    
    let hasCompressedData = (vectorData.compressed_data || isSingleCategory) && isValidCompressionInfo
    let hasUncompressedData = vectorData.values && vectorData.data_type
    
    if (!hasCompressedData && !hasUncompressedData) {
      console.error('Loaded metadata vector is missing required data:', vectorData)
      console.error('Available properties:', Object.keys(vectorData))
      
      // Check if this is a NUMERIC metadata with invalid compression_info
      if (vectorData.data_type === 'NUMERIC' && vectorData.compression_info && 
          typeof vectorData.compression_info === 'string' && 
          vectorData.compression_info.includes('Unknown data type')) {
        console.warn('NUMERIC metadata has invalid compression_info, attempting to create mock data...')
        
        // Try to create mock compression_info for NUMERIC data
        if (vectorData.values && Array.isArray(vectorData.values)) {
          const numericValues = vectorData.values.filter(v => typeof v === 'number' && !isNaN(v))
          if (numericValues.length > 0) {
            const minVal = Math.min(...numericValues)
            const maxVal = Math.max(...numericValues)
            vectorData.compression_info = {
              min_val: minVal,
              max_val: maxVal,
              data_type: 'NUMERIC'
            }
            hasUncompressedData = true
            console.log('Created mock compression_info for NUMERIC data:', vectorData.compression_info)
          }
        }
      }
      
      // If still no valid data, try to reload
      if (!hasCompressedData && !hasUncompressedData) {
        // Clear the corrupted cache entry and try to reload
        delete this.loadedMetadataVectors[metadataId]
        //console.log('Cleared corrupted cache entry, retrying load...')
        const retryData = await this.loadSingleMetadataVector(metadataId)
        if (!retryData) {
          console.error('Retry failed - metadata vector is still corrupted')
          return
        }
        // Use the retry data
        vectorData = retryData
        const retryIsValidCompressionInfo = vectorData.compression_info && 
                                           typeof vectorData.compression_info === 'object' && 
                                           !vectorData.compression_info.toString().includes('Unknown data type')
        const retryIsSingleCategory = retryIsValidCompressionInfo && vectorData.compression_info.single_category
        hasCompressedData = (vectorData.compressed_data || retryIsSingleCategory) && retryIsValidCompressionInfo
        hasUncompressedData = vectorData.values && vectorData.data_type
      }
    }
    
    // Decompress the vector data based on type
    let values
    try {
      if (hasUncompressedData) {
        // Data is already uncompressed, use it directly
        values = vectorData.values
        console.log(`Using uncompressed data: ${values.length} values for ${vectorData.name}`)
      } else if (hasCompressedData) {
        // Data is compressed, decompress it
        if (vectorData.data_type === 'DISCRETE') {
          values = this.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else if (vectorData.data_type === 'NUMERIC') {
          values = this.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else {
          console.error('Unknown data type:', vectorData.data_type)
          return
        }
      } else {
        console.error('No valid data found in metadata vector')
        return
      }
    } catch (error) {
      console.error('Error processing metadata vector:', error)
      // Clear the corrupted cache entry
      delete this.loadedMetadataVectors[metadataId]
      return
    }
    
    //console.log(`Successfully decompressed ${values.length} values for ${vectorData.name}`)
    
    // Store the decompressed values for visualization
    this.currentMetadataVector = {
      id: metadataId,
      name: vectorData.name,
      data_type: vectorData.data_type,
      values: values,
      compression_info: vectorData.compression_info
    }
    
    // Also store in loadedMetadataVectors for filtering
    this.loadedMetadataVectors[metadataId] = this.currentMetadataVector
    
    // Show checkboxes for this metadata now that it's loaded
    this.showCheckboxesForMetadata(metadataId)
    
    // Clear incremental state when new metadata is loaded
    this.clearIncrementalState()
    
    // Clear all checkbox selections when switching metadata
    this.clearAllCheckboxSelections()
    
    // Update settings window state
    this.updateCategoriesCheckboxState()
    
    // Also store the metadata ID for color mapping
    this.currentMetadataId = metadataId

    // Clear the cached color map since we have new metadata
    this.clearColorMapCache()
    
    // Update visualization with metadata coloring
    this.updateVisualizationWithMetadataVector()
    
    // Initialize checkboxes for the new metadata (only for discrete)
    if (this.currentMetadataVector?.data_type === 'DISCRETE') {
      this.initializeAllCheckboxes()
    }
    
    // Update cell filtering after loading metadata vector
    this.updateCellFiltering()
  }

  // Load all metadata vectors in a single request
  async loadAllMetadataVectorsInSingleRequest() {
    //console.log('=== LOADING ALL METADATA VECTORS IN SINGLE REQUEST ===')
    
    // Get all metadata IDs from the page
    const metadataElements = document.querySelectorAll('[data-metadata-item]')
    const metadataIds = Array.from(metadataElements).map(el => el.dataset.metadataItem)
    
    if (metadataIds.length === 0) {
      //console.log('No metadata items found on page')
      return
    }
    
    //console.log(`Found ${metadataIds.length} metadata items to load:`, metadataIds)
    
    try {
      // Get the current loom file
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : this.defaultLoomFileValue
      
      // Build the URL for the metadata vectors endpoint (single request for all)
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_vectors?metadata_ids=${metadataIds.join(',')}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      //console.log('Fetching all metadata vectors in single request from URL:', url)
      
      // Get CSRF token safely
      const csrfMetaTag = document.querySelector('meta[name="csrf-token"]')
      const csrfToken = csrfMetaTag?.getAttribute('content')
      
      const headers = {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
      
      if (csrfToken) {
        headers['X-CSRF-Token'] = csrfToken
      }
      
      const response = await fetch(url, {
        method: 'GET',
        headers: headers,
        credentials: 'same-origin'
      })
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      
      const data = await response.json()
      //console.log('Received all metadata vectors data:', data)
      
      // Store the loaded metadata vectors
      this.loadedMetadataVectors = data.metadata_vectors || {}
      this.metadataVectorsLoomFile = data.loom_file
      
      //console.log(`Successfully loaded ${data.total_loaded} metadata vectors in single request`)
      
      // Log compression info for each loaded vector
      Object.entries(this.loadedMetadataVectors).forEach(([metadataId, vectorData]) => {
        const info = vectorData.compression_info
        //console.log(`✓ ${vectorData.name} (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
      })
      
    } catch (error) {
      console.error('Error loading all metadata vectors in single request:', error)
      // Don't show alert for startup loading - just log the error
    }
  }

  // Load a single metadata vector silently (for preloading)
  async loadSingleMetadataVectorSilently(metadataId) {
    //console.log(`=== LOADING SINGLE METADATA VECTOR SILENTLY: ${metadataId} ===`)
    
    // Check if already loaded
    if (this.loadedMetadataVectors[metadataId]) {
      //console.log(`Metadata vector ${metadataId} already loaded`)
      return this.loadedMetadataVectors[metadataId]
    }
    
    // Check if currently loading
    if (this.loadingMetadataVectors.has(metadataId)) {
      //console.log(`Metadata vector ${metadataId} is currently loading, waiting...`)
      // Wait for the loading to complete
      while (this.loadingMetadataVectors.has(metadataId)) {
        await new Promise(resolve => setTimeout(resolve, 100))
      }
      return this.loadedMetadataVectors[metadataId]
    }
    
    // Mark as loading (but don't show spinner)
    this.loadingMetadataVectors.add(metadataId)
    
    try {
      // Get the current loom file
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : this.defaultLoomFileValue
      
      // Build the URL for the single metadata vector endpoint
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      //console.log(`Fetching single metadata vector silently from URL: ${url}`)
      
      // Get CSRF token safely
      const csrfMetaTag = document.querySelector('meta[name="csrf-token"]')
      const csrfToken = csrfMetaTag?.getAttribute('content')
      
      const headers = {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
      
      if (csrfToken) {
        headers['X-CSRF-Token'] = csrfToken
      }
      
      const response = await fetch(url, {
        method: 'GET',
        headers: headers,
        credentials: 'same-origin'
      })
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      
      const data = await response.json()
      //console.log('Received single metadata vector data silently:', data)
      
      // Store the loaded metadata vector
      const vectorData = data.metadata_vectors[metadataId]
      if (vectorData) {
        // Parse compression_info if it's a JSON string
        if (vectorData.compression_info && typeof vectorData.compression_info === 'string') {
          try {
            vectorData.compression_info = JSON.parse(vectorData.compression_info)
          } catch (e) {
            console.error('Failed to parse compression_info:', e)
          }
        }
        
        this.loadedMetadataVectors[metadataId] = vectorData
        this.metadataVectorsLoomFile = data.loom_file
        
        const info = vectorData.compression_info
        //console.log(`Successfully loaded metadata ${vectorData.name} silently (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
        
        // Show checkboxes for this metadata now that it's loaded
        this.showCheckboxesForMetadata(metadataId)
        
        return vectorData
      } else {
        throw new Error(`Metadata vector ${metadataId} not found in response`)
      }
      
    } catch (error) {
      console.error(`Error loading metadata vector ${metadataId} silently:`, error)
      return null
    } finally {
      // Remove from loading set (no spinner to hide)
      this.loadingMetadataVectors.delete(metadataId)
    }
  }

  // Show loading spinner for a specific metadata ID
  showLoadingSpinner(metadataId) {
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-action*="waterDropClicked"]`)
    if (!button) {
      //console.log(`Could not find water drop button for metadata ID: ${metadataId}`)
      return
    }
    
    // Store original content
    if (!button.dataset.originalContent) {
      button.dataset.originalContent = button.innerHTML
    }
    
    // Replace with spinner
    button.innerHTML = `
      <svg style="width: 16px; height: 16px; animation: spin 1s linear infinite;" fill="none" viewBox="0 0 24 24">
        <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566" opacity="0.25"/>
        <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566">
          <animate attributeName="stroke-dashoffset" dur="1.5s" values="12.566;0;12.566" repeatCount="indefinite"/>
        </circle>
      </svg>
    `
    
    // Add CSS animation if not already added
    if (!document.getElementById('spinner-styles')) {
      const style = document.createElement('style')
      style.id = 'spinner-styles'
      style.textContent = `
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `
      document.head.appendChild(style)
    }
    
    // Disable button during loading
    button.disabled = true
    button.style.cursor = 'wait'
    
    //console.log(`Showing loading spinner for metadata ${metadataId}`)
  }

  // Hide loading spinner for a specific metadata ID
  hideLoadingSpinner(metadataId) {
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-action*="waterDropClicked"]`)
    if (!button) {
      console.log(`Could not find water drop button for metadata ID: ${metadataId}`)
      return
    }
    
    // Restore original content
    if (button.dataset.originalContent) {
      button.innerHTML = button.dataset.originalContent
    }
    
    // Re-enable button
    button.disabled = false
    button.style.cursor = 'pointer'
    
    //console.log(`Hiding loading spinner for metadata ${metadataId}`)
  }

  // Preload metadata vector on hover for better UX
  preloadMetadataVector(event) {
    const button = event.currentTarget
    const metadataId = button.dataset.metadataId
    
    // Only preload if not already loaded and not currently loading
    if (!this.loadedMetadataVectors[metadataId] && !this.loadingMetadataVectors.has(metadataId)) {
      //console.log(`Preloading metadata vector ${metadataId} on hover`)
      // Load in background without showing spinner
      this.loadSingleMetadataVectorSilently(metadataId).catch(error => {
        console.log(`Preload failed for metadata ${metadataId}:`, error.message)
        // Don't show error to user for preloading failures
      })
    }
  }

  // Update visualization with metadata vector coloring
  updateVisualizationWithMetadataVector() {
    if (!this.currentMetadataVector || !this.pixiApp || !this.scatterContainer) {
      console.log('Cannot update visualization - missing data or PIXI app')
      return
    }
    
    //console.log(`Updating visualization with ${this.currentMetadataVector.name} (${this.currentMetadataVector.data_type})`)
    
    const { data_type, values, compression_info } = this.currentMetadataVector
    
    // Get existing coordinates for coloring
    if (!this.currentCoordinates || this.currentCoordinates.length === 0) {
      console.error('No coordinates available for coloring')
      return
    }
    
    // Ensure we have the same number of values as coordinates
    if (values.length !== this.currentCoordinates.length) {
      console.error(`Mismatch: ${values.length} metadata values vs ${this.currentCoordinates.length} coordinates`)
      return
    }
    
    // Use the centralized coloring approach
    this.forceReRenderPoints()
    
    // Render category labels if this is discrete metadata, or color legend if continuous
    if (this.currentMetadataVector.data_type === 'DISCRETE') {
      this.renderCategoryLabels()
    } else if (this.currentMetadataVector.data_type === 'NUMERIC') {
      this.renderContinuousColorLegend()
    }
    
    //console.log(`Successfully colored ${this.currentCoordinates.length} points with ${this.currentMetadataVector.name}`)
  }

  // Render all points using the current coloring scheme
  renderPointsWithCurrentColoring() {
    const startTime = performance.now()
    console.log('🚀 [PERF] renderPointsWithCurrentColoring started')
    
    if (!this.pixiApp || !this.scatterContainer || !this.currentCoordinates || !this.currentBounds) {
      console.log('Cannot render points - missing PIXI app or coordinates')
      const totalTime = performance.now() - startTime
      console.log(`🚀 [PERF] renderPointsWithCurrentColoring completed (early return) in ${totalTime.toFixed(2)}ms`)
      return
    }

    // Decide whether we can do a visibility-only update
    const pointSize = this.currentPointSize
    const canVisibilityUpdate = Boolean(
      this.visibilityOnlyUpdate &&
      this.existingPoints &&
      this.existingPoints.length === this.currentCoordinates.length &&
      this.lastMetadataVector === this.currentMetadataVector &&
      this.lastPointSize === pointSize &&
      this.scatterContainer && this.scatterContainer.children && this.scatterContainer.children.length > 0
    )

    // Prepare container only when a full re-render is needed
    let pointsContainer
    if (!canVisibilityUpdate) {
      const clearStart = performance.now()
      this.scatterContainer.removeChildren()
      this.existingPoints = null // Clear existing points reference
      
      // Always create the nested structure for consistency
      pointsContainer = new PIXI.Container()
      this.scatterContainer.addChild(pointsContainer)
      this.animatedContainer = pointsContainer // Store reference for consistency
      const clearTime = performance.now() - clearStart
      console.log(`🚀 [PERF] Container clear/setup took ${clearTime.toFixed(2)}ms`)
    } else {
      pointsContainer = this.animatedContainer || this.scatterContainer
      console.log('🚀 [PERF] Skipping container clear - visibility-only update')
    }
    
    //console.log(`renderPointsWithCurrentColoring using pointSize: ${pointSize}`)

    // Get filtered cell indices based on checkbox selections
    const filterStart = performance.now()
    const filteredIndices = this.getFilteredCellIndices()
    const filterTime = performance.now() - filterStart
    const cellCount = filteredIndices ? filteredIndices.length : 'all'
    console.log(`🚀 [PERF] getFilteredCellIndices took ${filterTime.toFixed(2)}ms, found ${cellCount} cells`)

    // Check if we have metadata coloring active
    if (this.currentMetadataVector && this.currentMetadataVector.values) {
      const { data_type, values, compression_info } = this.currentMetadataVector

      if (data_type === 'DISCRETE') {
        // Render each point individually to support selection transparency and color reset
        const uniqueValues = [...new Set(values)]
        
        // Calculate category frequencies for layering (larger categories first)
        const categoryFrequencies = {}
        values.forEach(value => {
          categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
        })
        
        //console.log('Category frequencies for layering:', categoryFrequencies)
        
        // Sort point indices by category size (largest categories first, so they render in background)
        const sortedPointIndices = Array.from({ length: this.currentCoordinates.length }, (_, i) => i)
          .sort((a, b) => {
            const categoryA = values[a]
            const categoryB = values[b]
            const freqA = categoryFrequencies[categoryA]
            const freqB = categoryFrequencies[categoryB]
            return freqB - freqA // Descending order (largest first)
          })
        
        // Debug: Log the first few sorted indices and their categories
        //console.log('First 10 sorted point indices:', sortedPointIndices.slice(0, 10))
        //console.log('Categories for first 10 points:', sortedPointIndices.slice(0, 10).map(i => values[i]))
        //console.log('Frequencies for first 10 points:', sortedPointIndices.slice(0, 10).map(i => categoryFrequencies[values[i]]))
        
        // Render points in sorted order (largest categories first)
        sortedPointIndices.forEach(i => {
          // Skip this point if it's not in the filtered indices
          if (filteredIndices && !filteredIndices.includes(i)) {
            return
          }

          const [x, y] = this.currentCoordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, this.currentBounds)
          const screenY = this.normalizeY(y, this.currentBounds)
          
          // Debug: Log coordinates for first few points to compare with zooming shape
          if (i < 5) {
            console.log(`🔍 Real Point ${i}:`, {
              dataCoords: [x, y],
              screenCoords: [screenX, screenY],
              bounds: this.currentBounds,
              screenSize: { width: this.pixiApp.screen.width, height: this.pixiApp.screen.height }
            })
          }
          
          // Create individual point graphics
          const point = new this.PIXI.Graphics()
          point.beginFill(color)
          point.alpha = alpha
          point.originalAlpha = alpha // Store original alpha for visibility updates
          point.drawCircle(0, 0, pointSize)
          point.endFill()
          point.x = screenX
          point.y = screenY
          
          // Store cell ID and mark as point for later reference
          point.cellId = i
          point.isPoint = true
          
          // Store original color for reset functionality
          this.storeOriginalPointColor(i, color)
          
          // Add hover functionality
          point.interactive = true
          point.buttonMode = false
          point.on('pointerover', () => this.showTooltip(i, point))
          point.on('pointerout', () => this.hideTooltip())
          
          pointsContainer.addChild(point)
        })
        
        // Update point count display with filtered count
        this.updatePointCountDisplay(filteredIndices)
        
      } else if (data_type === 'NUMERIC') {
        // Check if we can optimize by just showing/hiding existing points
        const renderStart = performance.now()
        console.log(`🚀 [PERF] Starting point rendering for ${this.currentCoordinates.length} points`)
        
        if (canVisibilityUpdate) {
          console.log(`🚀 [PERF] Optimizing: updating visibility of existing points`)
          const visibilityStart = performance.now()
          
          // Build a Set for O(1) membership checks
          let visibleSet = null
          if (filteredIndices) {
            visibleSet = new Set(filteredIndices)
          }
          
          // Update visibility of existing points
          for (let i = 0; i < this.existingPoints.length; i++) {
            const point = this.existingPoints[i]
            const shouldShow = !visibleSet || visibleSet.has(i)
            if (point.visible !== shouldShow) point.visible = shouldShow
          }
          
          const visibilityTime = performance.now() - visibilityStart
          console.log(`🚀 [PERF] Visibility update completed in ${visibilityTime.toFixed(2)}ms`)
          
          // Update point count display
          this.updatePointCountDisplay(filteredIndices)
          
          const totalTime = performance.now() - renderStart
          console.log(`🚀 [PERF] renderPointsWithCurrentColoring completed (optimized) in ${totalTime.toFixed(2)}ms`)
          
          // Reset the hint flag until next request
          this.visibilityOnlyUpdate = false
          return
        }
        
        // Full render: create all points from scratch
        console.log(`🚀 [PERF] Full render: creating ${this.currentCoordinates.length} points`)
        this.existingPoints = [] // Store reference to existing points
        
        for (let i = 0; i < this.currentCoordinates.length; i++) {
          // Skip this point if it's not in the filtered indices
          if (filteredIndices && !filteredIndices.includes(i)) {
            continue
          }

          const [x, y] = this.currentCoordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, this.currentBounds)
          const screenY = this.normalizeY(y, this.currentBounds)
          
          // Create individual point graphics
          const point = new this.PIXI.Graphics()
          point.beginFill(color)
          point.alpha = alpha
          point.originalAlpha = alpha // Store original alpha for visibility updates
          point.drawCircle(0, 0, pointSize)
          point.endFill()
          point.x = screenX
          point.y = screenY
          
          // Store cell ID and mark as point for later reference
          point.cellId = i
          point.isPoint = true
          
          // Store original color for reset functionality
          this.storeOriginalPointColor(i, color)
          
          // Add hover functionality
          point.interactive = true
          point.buttonMode = false
          point.on('pointerover', () => this.showTooltip(i, point))
          point.on('pointerout', () => this.hideTooltip())
          
          pointsContainer.addChild(point)
          this.existingPoints[i] = point // Store reference for future optimization
        }
        
        // Store metadata for optimization checks
        this.lastMetadataVector = this.currentMetadataVector
        this.lastPointSize = pointSize
        
        // Update point count display with filtered count
        this.updatePointCountDisplay(filteredIndices)
      }
    } else {
      // Render each point individually to support selection transparency and color reset
      for (let i = 0; i < this.currentCoordinates.length; i++) {
        // Skip this point if it's not in the filtered indices
        if (filteredIndices && !filteredIndices.includes(i)) {
          continue
        }

        const [x, y] = this.currentCoordinates[i]
        const { color, alpha } = this.getColorAndAlpha(i)
        
        const screenX = this.normalizeX(x, this.currentBounds)
        const screenY = this.normalizeY(y, this.currentBounds)
        
        
        // Create individual point graphics
        const point = new this.PIXI.Graphics()
        point.beginFill(color)
        point.alpha = alpha
        point.originalAlpha = alpha // Store original alpha for visibility updates
        point.drawCircle(0, 0, pointSize)
        point.endFill()
        point.x = screenX
        point.y = screenY
        
        // Store cell ID and mark as point for later reference
        point.cellId = i
        point.isPoint = true
        
        // Store original color for reset functionality
        this.storeOriginalPointColor(i, color)
        
        this.scatterContainer.addChild(point)
      }
      
      // Update point count display with filtered count
      const filteredCount = filteredIndices ? filteredIndices.length : this.currentCoordinates.length
      const pointCountElement = document.getElementById('point-count')
      if (pointCountElement) {
        pointCountElement.textContent = `${filteredCount.toLocaleString()} points`
      }
    }
    
    //console.log(`Rendered ${this.currentCoordinates.length} points with current coloring scheme`)
    
    // Clear any stored original positions since points were recreated
    this.clearStoredOriginalPositions()
    
    const totalTime = performance.now() - startTime
    console.log(`🚀 [PERF] renderPointsWithCurrentColoring completed in ${totalTime.toFixed(2)}ms`)
  }


  // Color points for continuous metadata
  colorPointsContinuous(values, compressionInfo) {
    /*console.log('Coloring points for continuous metadata:', {
      range: `${compressionInfo.min_val} to ${compressionInfo.max_val}`,
      actualRange: `${Math.min(...values).toFixed(3)} to ${Math.max(...values).toFixed(3)}`
    })*/
    
    const minVal = compressionInfo.min_val
    const maxVal = compressionInfo.max_val
    const range = maxVal - minVal
    
    // Create single graphics object for all points
    const graphics = new this.PIXI.Graphics()
    
    // Render points with color based on value
    this.currentCoordinates.forEach((coord, index) => {
      const value = values[index]
      const normalizedValue = (value - minVal) / range
      
      // Convert to color (blue to red gradient)
      const color = this.valueToColor(normalizedValue)
      
      const screenX = this.normalizeX(coord[0], this.currentBounds)
      const screenY = this.normalizeY(coord[1], this.currentBounds)
      
      graphics.beginFill(color)
      graphics.drawCircle(screenX, screenY, this.currentPointSize)
      graphics.endFill()
    })
    
    this.scatterContainer.addChild(graphics)
    
    // Update point count display
    this.updatePointCountDisplay(null)
  }

  // Create color map for discrete categories
  // Get categories sorted by frequency (largest to smallest) to match HTML legend ordering
  getSortedCategories(values, categories) {
    // Calculate category frequencies
    const categoryFrequencies = {}
    values.forEach(value => {
      categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
    })
    
    // Sort categories by frequency (largest to smallest)
    const sorted = categories.sort((a, b) => {
      const freqA = categoryFrequencies[a] || 0
      const freqB = categoryFrequencies[b] || 0
      return freqB - freqA // Descending order (largest first)
    })
    return sorted
  }

  createDiscreteColorMap(categories, metadataId) {
    // Use the centralized color palette from the server
    const colors = this.getCategoryColors()
    
    const colorMap = {}
    categories.forEach((category, index) => {
      // Check if we have a stored color for this category in this metadata
      const storageKey = `category_color_${metadataId}_${category}`
      const storedColor = localStorage.getItem(storageKey)
      
      if (storedColor) {
        // Convert hex string to number for PIXI.js
        colorMap[category] = parseInt(storedColor.replace('#', ''), 16)
      } else {
        // Use default color
      colorMap[category] = colors[index % colors.length]
      }
    })
    
    return colorMap
  }

  getCategoryColors() {
    // Cache the colors to prevent repeated conversion
    if (this._cachedCategoryColors) {
      return this._cachedCategoryColors
    }
    
    //console.log('🎨 getCategoryColors called - converting colors for first time')
    //console.log('🎨 window.CATEGORY_COLORS:', window.CATEGORY_COLORS)
    
    // Use colors from the global color palette loaded in layout
    if (window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0) {
      //console.log('Converting colors to JavaScript hex numbers')
      // Convert CSS hex colors (#1f77b4) to JavaScript hex numbers (0x1f77b4)
      const jsColors = window.CATEGORY_COLORS.map(cssColor => {
        // Remove # and convert to hex number
        return parseInt(cssColor.replace('#', ''), 16)
      })
      //console.log('Converted colors:', jsColors)
      
      // Cache the converted colors
      this._cachedCategoryColors = jsColors
      return jsColors
    }
    
    // Temporary fallback to prevent infinite loop - will be removed once colors are properly loaded
    console.warn('Using temporary fallback colors to prevent infinite loop')
    const fallbackColors = [
      0x1f77b4, 0xff7f0e, 0x2ca02c, 0x9467bd, 0x8c564b, 
      0xe377c2, 0x7f7f7f, 0xbcbd22, 0x17becf, 0x4ecdc4
    ]
    
    // Cache the fallback colors too
    this._cachedCategoryColors = fallbackColors
    return fallbackColors
  }

  // Clear the cached colors (call this when colors are reloaded)
  clearCategoryColorsCache() {
    this._cachedCategoryColors = null
    //console.log('Category colors cache cleared')
  }

  // Clear the cached color map (call this when metadata changes)
  clearColorMapCache() {
    this._cachedColorMap = null
    this._cachedCentroids = null
    this._cachedCentroidsKey = null
    //console.log('Color map cache cleared')
  }

  // Convert normalized value (0-1) to color using the current color scheme
  valueToColor(normalizedValue, colorScheme = null) {
    // Clamp to 0-1 range
    const clamped = Math.max(0, Math.min(1, normalizedValue))
    
    // Use the specified color scheme or default to the current one
    const scheme = colorScheme || this.currentColorScheme || 'blue-green-red'
    
    switch (scheme) {
      case 'viridis':
        return this.viridisColor(clamped)
      case 'plasma':
        return this.plasmaColor(clamped)
      case 'inferno':
        return this.infernoColor(clamped)
      case 'magma':
        return this.magmaColor(clamped)
      case 'cividis':
        return this.cividisColor(clamped)
      case 'blue-white-red':
        return this.blueWhiteRedColor(clamped)
      case 'blue-green-red':
      default:
        return this.blueGreenRedColor(clamped)
    }
  }

  // Blue to green to red gradient (original)
  blueGreenRedColor(normalizedValue) {
    if (normalizedValue < 0.5) {
      // Blue to green
      const t = normalizedValue * 2
      const r = Math.round(0 * (1 - t) + 0 * t)
      const g = Math.round(0 * (1 - t) + 255 * t)
      const b = Math.round(255 * (1 - t) + 0 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // Green to red
      const t = (normalizedValue - 0.5) * 2
      const r = Math.round(0 * (1 - t) + 255 * t)
      const g = Math.round(255 * (1 - t) + 0 * t)
      const b = Math.round(0 * (1 - t) + 0 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Blue to white to red gradient
  blueWhiteRedColor(normalizedValue) {
    if (normalizedValue < 0.5) {
      // Blue to white
      const t = normalizedValue * 2
      const r = Math.round(0 * (1 - t) + 255 * t)
      const g = Math.round(0 * (1 - t) + 255 * t)
      const b = Math.round(255 * (1 - t) + 255 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // White to red
      const t = (normalizedValue - 0.5) * 2
      const r = Math.round(255 * (1 - t) + 255 * t)
      const g = Math.round(255 * (1 - t) + 0 * t)
      const b = Math.round(255 * (1 - t) + 0 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Viridis color scheme (purple to blue to green to yellow)
  viridisColor(normalizedValue) {
    // Simplified viridis approximation
    if (normalizedValue < 0.25) {
      // Purple to blue
      const t = normalizedValue * 4
      const r = Math.round(68 * (1 - t) + 72 * t)
      const g = Math.round(1 * (1 - t) + 40 * t)
      const b = Math.round(84 * (1 - t) + 120 * t)
      return (r << 16) | (g << 8) | b
    } else if (normalizedValue < 0.5) {
      // Blue to green
      const t = (normalizedValue - 0.25) * 4
      const r = Math.round(72 * (1 - t) + 33 * t)
      const g = Math.round(40 * (1 - t) + 144 * t)
      const b = Math.round(120 * (1 - t) + 140 * t)
      return (r << 16) | (g << 8) | b
    } else if (normalizedValue < 0.75) {
      // Green to yellow-green
      const t = (normalizedValue - 0.5) * 4
      const r = Math.round(33 * (1 - t) + 92 * t)
      const g = Math.round(144 * (1 - t) + 201 * t)
      const b = Math.round(140 * (1 - t) + 99 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // Yellow-green to yellow
      const t = (normalizedValue - 0.75) * 4
      const r = Math.round(92 * (1 - t) + 253 * t)
      const g = Math.round(201 * (1 - t) + 231 * t)
      const b = Math.round(99 * (1 - t) + 37 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Plasma color scheme (purple to pink to yellow)
  plasmaColor(normalizedValue) {
    // Simplified plasma approximation
    if (normalizedValue < 0.33) {
      // Purple to pink
      const t = normalizedValue * 3
      const r = Math.round(13 * (1 - t) + 140 * t)
      const g = Math.round(8 * (1 - t) + 81 * t)
      const b = Math.round(135 * (1 - t) + 10 * t)
      return (r << 16) | (g << 8) | b
    } else if (normalizedValue < 0.66) {
      // Pink to orange
      const t = (normalizedValue - 0.33) * 3
      const r = Math.round(140 * (1 - t) + 240 * t)
      const g = Math.round(81 * (1 - t) + 249 * t)
      const b = Math.round(10 * (1 - t) + 33 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // Orange to yellow
      const t = (normalizedValue - 0.66) * 3
      const r = Math.round(240 * (1 - t) + 252 * t)
      const g = Math.round(249 * (1 - t) + 255 * t)
      const b = Math.round(33 * (1 - t) + 164 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Inferno color scheme (black to red to yellow)
  infernoColor(normalizedValue) {
    // Simplified inferno approximation
    if (normalizedValue < 0.33) {
      // Black to red
      const t = normalizedValue * 3
      const r = Math.round(0 * (1 - t) + 128 * t)
      const g = Math.round(0 * (1 - t) + 0 * t)
      const b = Math.round(4 * (1 - t) + 38 * t)
      return (r << 16) | (g << 8) | b
    } else if (normalizedValue < 0.66) {
      // Red to orange
      const t = (normalizedValue - 0.33) * 3
      const r = Math.round(128 * (1 - t) + 255 * t)
      const g = Math.round(0 * (1 - t) + 69 * t)
      const b = Math.round(38 * (1 - t) + 10 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // Orange to yellow
      const t = (normalizedValue - 0.66) * 3
      const r = Math.round(255 * (1 - t) + 252 * t)
      const g = Math.round(69 * (1 - t) + 255 * t)
      const b = Math.round(10 * (1 - t) + 164 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Magma color scheme (black to purple to white)
  magmaColor(normalizedValue) {
    // Simplified magma approximation
    if (normalizedValue < 0.33) {
      // Black to purple
      const t = normalizedValue * 3
      const r = Math.round(0 * (1 - t) + 64 * t)
      const g = Math.round(0 * (1 - t) + 0 * t)
      const b = Math.round(4 * (1 - t) + 130 * t)
      return (r << 16) | (g << 8) | b
    } else if (normalizedValue < 0.66) {
      // Purple to pink
      const t = (normalizedValue - 0.33) * 3
      const r = Math.round(64 * (1 - t) + 255 * t)
      const g = Math.round(0 * (1 - t) + 255 * t)
      const b = Math.round(130 * (1 - t) + 255 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // Pink to white
      const t = (normalizedValue - 0.66) * 3
      const r = Math.round(255 * (1 - t) + 252 * t)
      const g = Math.round(255 * (1 - t) + 255 * t)
      const b = Math.round(255 * (1 - t) + 164 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Cividis color scheme (dark blue to yellow, colorblind-friendly)
  cividisColor(normalizedValue) {
    // Simplified cividis approximation
    if (normalizedValue < 0.5) {
      // Dark blue to green
      const t = normalizedValue * 2
      const r = Math.round(0 * (1 - t) + 0 * t)
      const g = Math.round(32 * (1 - t) + 150 * t)
      const b = Math.round(76 * (1 - t) + 100 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // Green to yellow
      const t = (normalizedValue - 0.5) * 2
      const r = Math.round(0 * (1 - t) + 255 * t)
      const g = Math.round(150 * (1 - t) + 255 * t)
      const b = Math.round(100 * (1 - t) + 0 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Change the color scheme for continuous metadata
  setColorScheme(scheme) {
    if (!['blue-green-red', 'blue-white-red', 'viridis', 'plasma', 'inferno', 'magma', 'cividis'].includes(scheme)) {
      console.error('Invalid color scheme:', scheme)
      return
    }
    
    this.currentColorScheme = scheme
    
    // If we have continuous metadata active, re-render the visualization and legend
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'NUMERIC') {
      this.forceReRenderPoints()
      this.renderContinuousColorLegend()
    }
    
    console.log('🎨 Color scheme changed to:', scheme)
  }

  // Get available color schemes
  getAvailableColorSchemes() {
    return [
      { id: 'blue-green-red', name: 'Blue-Green-Red', description: 'Classic blue to green to red gradient' },
      { id: 'blue-white-red', name: 'Blue-White-Red', description: 'Blue to white to red gradient' },
      { id: 'viridis', name: 'Viridis', description: 'Purple to blue to green to yellow (perceptually uniform)' },
      { id: 'plasma', name: 'Plasma', description: 'Purple to pink to yellow' },
      { id: 'inferno', name: 'Inferno', description: 'Black to red to yellow' },
      { id: 'magma', name: 'Magma', description: 'Black to purple to white' },
      { id: 'cividis', name: 'Cividis', description: 'Dark blue to yellow (colorblind-friendly)' }
    ]
  }

  // Set custom color range for continuous metadata
  setColorRange(min, max) {
    if (min >= max) {
      console.error('Invalid color range: min must be less than max')
      return
    }
    
    this.customColorRange = { min, max }
    
    // If we have continuous metadata active, re-render the visualization and legend
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'NUMERIC') {
      this.forceReRenderPoints()
      this.renderContinuousColorLegend()
    }
    
    console.log('🎨 Color range set to:', { min, max })
  }

  // Reset color range to auto (use data min/max)
  resetColorRange() {
    this.customColorRange = null
    
    // If we have continuous metadata active, re-render the visualization and legend
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'NUMERIC') {
      this.forceReRenderPoints()
      this.renderContinuousColorLegend()
    }
    
    console.log('🎨 Color range reset to auto')
  }

  // Update color range for a specific metadata (used by inline range slider)
  updateColorRange(metadataId, min, max, shouldAdaptColorRange = false) {
    console.log('🎨 Updating color range for metadata:', metadataId, 'range:', { min, max }, 'adapt:', shouldAdaptColorRange)
    
    if (shouldAdaptColorRange) {
      // Set the custom color range to adapt to the selected range
      this.customColorRange = { min, max }
      console.log('🎨 Color range adapted to selected range:', { min, max })
    } else {
      // Clear the custom color range to use the full data range
      this.customColorRange = null
      console.log('🎨 Color range reset to full data range')
    }
  }

  // Redraw the entire visualization (used by inline range slider)
  redrawVisualization() {
    console.log('🎨 Redrawing visualization...')
    
    if (this.currentMetadataVector) {
      this.forceReRenderPoints()
      
      // Update the appropriate legend
      if (this.currentMetadataVector.data_type === 'NUMERIC') {
        this.renderContinuousColorLegend()
      } else {
        this.renderDiscreteColorLegend()
      }
    }
  }


  // Initialize inline range slider with metadata values
  initializeInlineRangeSlider(metadataId, values) {
    console.log('🎚️ Initializing inline range slider for metadata:', metadataId)
    
    if (!values || !Array.isArray(values)) {
      console.error('❌ Invalid values provided to initializeInlineRangeSlider:', values)
      return
    }
    
    const minVal = Math.min(...values)
    const maxVal = Math.max(...values)
    
    console.log('🎚️ Calculated min/max values:', { minVal, maxVal, valuesLength: values.length })
    
    // Store the data
    this.inlineRangeSliderData[metadataId] = {
      min: minVal,
      max: maxVal,
      currentMin: minVal,
      currentMax: maxVal,
      values: values
    }
    
    // Find the range slider controller and update its values
    const rangeSliderElement = document.querySelector(`[data-range-slider-metadata-id-value="${metadataId}"]`)
    console.log('🎚️ Looking for range slider element:', rangeSliderElement)
    
    if (rangeSliderElement) {
      const controller = this.application.getControllerForElementAndIdentifier(rangeSliderElement, 'range-slider')
      console.log('🎚️ Found range slider controller:', controller)
      
      if (controller) {
        controller.minValue = minVal
        controller.maxValue = maxVal
        controller.currentMinValue = minVal
        controller.currentMaxValue = maxVal
        controller.initializeSlider()
        console.log('🎚️ Range slider controller initialized successfully')
        
        // Draw the initial histogram
        controller.drawDensityPlot()
      } else {
        console.error('❌ Range slider controller not found for element:', rangeSliderElement)
      }
    } else {
      console.error('❌ Range slider element not found for metadata ID:', metadataId)
    }
  }

  // Get effective color range (custom or data range)
  getEffectiveColorRange() {
    if (!this.currentMetadataVector || this.currentMetadataVector.data_type !== 'NUMERIC') {
      return null
    }
    
    if (this.customColorRange) {
      return this.customColorRange
    }
    
    // Return data range from compression info
    const compressionInfo = this.currentMetadataVector.compression_info
    return {
      min: compressionInfo.min_val,
      max: compressionInfo.max_val
    }
  }

  // Debug function to help identify DOM structure issues
  debugMetadataContainerStructure(button) {
    console.log('🔍 Debugging metadata container structure...')
    console.log('Button element:', button)
    console.log('Button tagName:', button.tagName)
    console.log('Button className:', button.className)
    console.log('Button dataset:', button.dataset)
    console.log('Button parentElement:', button.parentElement)
    console.log('Button parentElement tagName:', button.parentElement?.tagName)
    console.log('Button parentElement className:', button.parentElement?.className)
    console.log('Button parentElement dataset:', button.parentElement?.dataset)
    
    // Check all parent elements
    let current = button.parentElement
    let level = 1
    while (current && level <= 5) {
      console.log(`Parent level ${level}:`, {
        tagName: current.tagName,
        className: current.className,
        dataset: current.dataset,
        id: current.id
      })
      current = current.parentElement
      level++
    }
    
    // Check for any metadata-related elements in the document
    const metadataElements = document.querySelectorAll('[data-metadata-item], .metadata-item, [data-metadata-id], .metadata')
    console.log('All metadata-related elements found:', metadataElements.length)
    metadataElements.forEach((el, index) => {
      console.log(`Metadata element ${index}:`, {
        tagName: el.tagName,
        className: el.className,
        dataset: el.dataset,
        id: el.id
      })
    })
  }

  // Test function to verify continuous metadata coloring implementation
  testContinuousMetadataColoring() {
    console.log('🧪 Testing continuous metadata coloring implementation...')
    
    // Test 1: Check if color schemes are available
    const schemes = this.getAvailableColorSchemes()
    console.log('✅ Available color schemes:', schemes.length)
    
    // Test 2: Test color conversion for different schemes
    const testValue = 0.5
    const colors = {}
    schemes.forEach(scheme => {
      colors[scheme.id] = this.valueToColor(testValue, scheme.id)
    })
    console.log('✅ Color conversion test:', colors)
    
    // Test 3: Test color range functionality
    this.setColorRange(0, 10)
    const range = this.getEffectiveColorRange()
    console.log('✅ Color range test:', range)
    
    this.resetColorRange()
    console.log('✅ Color range reset test:', this.getEffectiveColorRange())
    
    // Test 4: Check if continuous legend function exists
    if (typeof this.renderContinuousColorLegend === 'function') {
      console.log('✅ Continuous legend function exists')
    } else {
      console.error('❌ Continuous legend function missing')
    }
    
    console.log('🧪 Continuous metadata coloring test completed')
    return true
  }

  // Clear metadata coloring and return to default blue points
  clearMetadataColoring() {
    if (!this.pixiApp || !this.scatterContainer || !this.currentCoordinates || !this.currentBounds) {
      //console.log('Cannot clear coloring - missing PIXI app or coordinates')
      return
    }
    
    //console.log('Clearing metadata coloring, returning to default blue points')
    
    // Clear current metadata vector
    this.currentMetadataVector = null
    this.currentMetadataId = null
    
    // Clear custom color range
    this.customColorRange = null
    
    // Clear the cached color map since we're clearing metadata
    this.clearColorMapCache()
    
    // Clear existing colored points and re-render with default coloring
    this.forceReRenderPoints()
    
    // Clear any existing legend (both discrete and continuous)
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.removeChildren()
      this.categoryLabelsContainer.visible = false
    }
    
    //console.log('Successfully cleared metadata coloring')
  }
  
  // Clear all loaded metadata vectors cache (use when switching projects or clearing all data)
  clearLoadedMetadataVectorsCache() {
    //console.log('Clearing all loaded metadata vectors cache')
    this.loadedMetadataVectors = {}
    this.loadingMetadataVectors.clear()
  }
  
  // Detect if embedding method changed by analyzing coordinate patterns
  detectEmbeddingMethodChange(newCoordinates) {
    if (!this.currentCoordinates || !newCoordinates) {
      return true // First load or no previous coordinates
    }
    
    if (this.currentCoordinates.length !== newCoordinates.length) {
      return true // Different number of points
    }
    
    // Calculate coordinate statistics to detect embedding method changes
    const currentStats = this.calculateCoordinateStats(this.currentCoordinates)
    const newStats = this.calculateCoordinateStats(newCoordinates)
    
    // If the coordinate distribution is significantly different, it's likely a different embedding
    const significantChange = (
      Math.abs(currentStats.meanX - newStats.meanX) > 0.1 ||
      Math.abs(currentStats.meanY - newStats.meanY) > 0.1 ||
      Math.abs(currentStats.stdX - newStats.stdX) > 0.1 ||
      Math.abs(currentStats.stdY - newStats.stdY) > 0.1
    )
    
    if (significantChange) {
      console.log('Embedding method changed - animation will be triggered')
    }
    
    return significantChange
  }
  
  // Calculate basic statistics for coordinate arrays
  calculateCoordinateStats(coordinates) {
    if (!coordinates || coordinates.length === 0) {
      return { meanX: 0, meanY: 0, stdX: 0, stdY: 0 }
    }
    
    const xValues = coordinates.map(([x]) => x)
    const yValues = coordinates.map(([, y]) => y)
    
    const meanX = xValues.reduce((sum, x) => sum + x, 0) / xValues.length
    const meanY = yValues.reduce((sum, y) => sum + y, 0) / yValues.length
    
    const stdX = Math.sqrt(xValues.reduce((sum, x) => sum + Math.pow(x - meanX, 2), 0) / xValues.length)
    const stdY = Math.sqrt(yValues.reduce((sum, y) => sum + Math.pow(y - meanY, 2), 0) / yValues.length)
    
    return { meanX, meanY, stdX, stdY }
  }

  toggleDropdown(event) {
     //console.log('toggleDropdown called')
    event.stopPropagation()
    
    const button = event.currentTarget
    const dropdownMenu = button.nextElementSibling
    
    // Close all other dropdowns first
    document.querySelectorAll('.metadata-dropdown-menu').forEach(menu => {
      if (menu !== dropdownMenu) {
        menu.classList.add('hidden')
      }
    })
    
    // Toggle current dropdown
    dropdownMenu.classList.toggle('hidden')
  }

  editMetadata(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    //console.log('Edit metadata:', metadataId)
    // TODO: Implement edit functionality
    alert(`Edit metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  exportMetadata(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    //console.log('Export metadata:', metadataId)
    // TODO: Implement export functionality
    alert(`Export metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  duplicateMetadata(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    //console.log('Duplicate metadata:', metadataId)
    // TODO: Implement duplicate functionality
    alert(`Duplicate metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  viewCategories(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    //console.log('View categories for metadata:', metadataId)
    // TODO: Implement view categories functionality
    alert(`View categories for metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  viewStatistics(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    //console.log('View statistics for metadata:', metadataId)
    // TODO: Implement view statistics functionality
    alert(`View statistics for metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  deleteMetadata(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    //console.log('Delete metadata:', metadataId)
    
    if (confirm(`Are you sure you want to delete metadata ${metadataId}?`)) {
      // TODO: Implement delete functionality
      alert(`Metadata ${metadataId} deleted`)
      this.closeAllDropdowns()
    }
  }

  closeAllDropdowns() {
    document.querySelectorAll('.metadata-dropdown-menu').forEach(menu => {
      menu.classList.add('hidden')
    })
  }

  // Toggle metadata categories (moved from inline JS)
  async toggleMetadata(event) {
    const headerElement = event.currentTarget
    const chevron = headerElement.querySelector('svg')
    const nextSibling = headerElement.nextElementSibling
    const radioInput = headerElement.querySelector('input[type="radio"]')
    
    if (!chevron || !nextSibling || !radioInput) {
      console.error('Required elements not found')
      return
    }
    
    // Check if this is continuous metadata (has range section) or categorical metadata (has categories)
    const isContinuousMetadata = nextSibling.classList.contains('metadata-range-section')
    const categoriesDiv = isContinuousMetadata ? null : nextSibling
    const rangeSection = isContinuousMetadata ? nextSibling : null
    
    // Toggle the chevron rotation
    const isExpanding = chevron.style.transform === '' || chevron.style.transform === 'rotate(0deg)'
    
    if (isExpanding) {
      chevron.style.transform = 'rotate(90deg)'
      
      if (isContinuousMetadata) {
        // Handle continuous metadata - show range section
        rangeSection.style.display = 'block'
        
        // Get metadata info and initialize the range slider
        const metadataItem = headerElement.closest('[data-metadata-item]')
        if (metadataItem) {
          const metadataId = metadataItem.dataset.metadataItem
          const metadataName = headerElement.querySelector('[data-metadata-name]')?.dataset.metadataName || 'Unknown'
          
          console.log('🎚️ Expanding continuous metadata:', metadataId, metadataName)
          
          // Initialize the inline range slider
          this.toggleInlineRangeSlider(metadataId, metadataName)
        }
      } else {
        // Handle categorical metadata - show categories
        categoriesDiv.style.display = 'block'
        
        // Load metadata vector when expanding categories (for future coloring)
        const metadataItem = headerElement.closest('[data-metadata-item]')
        if (metadataItem) {
          const metadataId = metadataItem.dataset.metadataItem
          //console.log(`Loading metadata vector for ${metadataId} on category expansion`)
          
          // Load silently in background (no spinner for category expansion)
          this.loadSingleMetadataVectorSilently(metadataId).catch(error => {
            //console.log(`Failed to load metadata vector ${metadataId} on expansion:`, error.message)
          })
        }
      }
    } else {
      chevron.style.transform = 'rotate(0deg)'
      
      if (isContinuousMetadata) {
        rangeSection.style.display = 'none'
      } else {
        categoriesDiv.style.display = 'none'
      }
    }
    
    // Select this metadata option
    radioInput.checked = true
    
    // Trigger change event to update visualization if needed
    const changeEvent = new Event('change', { bubbles: true })
    radioInput.dispatchEvent(changeEvent)
  }

  // Initialize draggable divider (moved from inline JS)
  initializeDraggableDivider() {
    const divider = document.getElementById('metadata-divider')
    if (!divider) {
      console.error('Divider element not found')
      return
    }
    
    // Find panels by looking for elements with specific styles
    const discretePanel = divider.previousElementSibling
    const continuousPanel = divider.nextElementSibling
    const container = discretePanel?.parentElement
    
    //console.log('Elements found:', { divider, discretePanel, continuousPanel, container })
    
    if (!discretePanel || !continuousPanel || !container) {
      console.error('Required elements for draggable divider not found', { discretePanel, continuousPanel, container })
      return
    }
    
    let isDragging = false
    let startY = 0
    let startHeight = 0
    
    // Minimum heights for panels (in pixels)
    const minPanelHeight = 100
    
    const startDrag = (e) => {
      console.log('Start drag triggered')
      isDragging = true
      startY = e.clientY
      startHeight = discretePanel.offsetHeight
      
      // Add visual feedback
      document.body.style.cursor = 'row-resize'
      divider.style.backgroundColor = '#6B7280'
      
      // Prevent text selection during drag
      document.body.style.userSelect = 'none'
      
      e.preventDefault()
    }
    
    const doDrag = (e) => {
      if (!isDragging) return
      
      const deltaY = e.clientY - startY
      const newHeight = startHeight + deltaY
      
      // Calculate container height
      const containerHeight = container.offsetHeight - divider.offsetHeight
      
      // Apply constraints
      const constrainedHeight = Math.max(minPanelHeight, Math.min(newHeight, containerHeight - minPanelHeight))
      
      // Update discrete panel height
      const heightPercentage = (constrainedHeight / containerHeight) * 100
      discretePanel.style.height = heightPercentage + '%'
      
      //console.log('Dragging:', { deltaY, newHeight, containerHeight, constrainedHeight, heightPercentage })
    }
    
    const stopDrag = () => {
      if (!isDragging) return
      
      isDragging = false
      
      // Remove visual feedback
      document.body.style.cursor = ''
      divider.style.backgroundColor = ''
      document.body.style.userSelect = ''
    }
    
    // Event listeners
    divider.addEventListener('mousedown', startDrag)
    document.addEventListener('mousemove', doDrag)
    document.addEventListener('mouseup', stopDrag)
    document.addEventListener('mouseleave', stopDrag)
    
    //console.log('Draggable divider initialized')
  }

  // Handle water drop button clicks
  waterDropClicked(event) {
    /*console.log('=== WATER DROP CLICKED ===')
    console.log('Event:', event)
    console.log('Event target:', event.target)
    console.log('Event currentTarget:', event.currentTarget)
    */
    event.preventDefault()
    event.stopPropagation()
    
    const button = event.currentTarget
    const metadataName = button.dataset.metadataName
    let metadataId = button.dataset.metadataId
    const isCurrentlyActive = button.dataset.active === 'true'
    
    // Debug: Check what attributes the button actually has
    console.log('🔍 Button debugging:')
    console.log('Button element:', button)
    console.log('Button dataset:', button.dataset)
    console.log('Button attributes:', Array.from(button.attributes).map(attr => `${attr.name}="${attr.value}"`))
    console.log('metadataId from dataset:', metadataId)
    console.log('metadataName from dataset:', metadataName)
    
    // Check if metadataId is undefined and try alternative ways to get it
    if (!metadataId) {
      console.warn('⚠️ metadataId is undefined, trying alternative methods...')
      
      // Try different attribute names
      const altMetadataId = button.dataset.metadataId || 
                           button.dataset.metadata_id || 
                           button.dataset.metadataitem ||
                           button.dataset.metadataItem ||
                           button.getAttribute('data-metadata-id') ||
                           button.getAttribute('data-metadata_id') ||
                           button.getAttribute('data-metadataitem')
      
      console.log('Alternative metadataId found:', altMetadataId)
      
      if (altMetadataId) {
        // Use the alternative metadataId
        metadataId = altMetadataId
        console.log('Using alternative metadataId:', metadataId)
      } else {
        // Try to get metadataId from parent containers
        console.log('Trying to find metadataId in parent containers...')
        let parent = button.parentElement
        let attempts = 0
        while (parent && attempts < 5) {
          const parentMetadataId = parent.dataset.metadataId || 
                                  parent.dataset.metadata_id || 
                                  parent.dataset.metadataitem ||
                                  parent.dataset.metadataItem ||
                                  parent.getAttribute('data-metadata-id') ||
                                  parent.getAttribute('data-metadata_id') ||
                                  parent.getAttribute('data-metadataitem')
          
          if (parentMetadataId) {
            metadataId = parentMetadataId
            console.log('Found metadataId in parent container:', metadataId)
            break
          }
          
          parent = parent.parentElement
          attempts++
        }
        
        if (!metadataId) {
          console.error('❌ Could not find metadataId in any form!')
          console.error('Available dataset keys:', Object.keys(button.dataset))
          console.error('Available attributes:', Array.from(button.attributes).map(attr => attr.name))
          return // Exit early if we can't find the metadataId
        }
      }
    }
    
    // Final validation
    if (!metadataId || metadataId === 'undefined' || metadataId === 'null') {
      console.error('❌ Final validation failed: metadataId is still invalid:', metadataId)
      console.error('Button element:', button)
      console.error('Button dataset:', button.dataset)
      return
    }
    
    console.log('✅ Valid metadataId found:', metadataId)
    console.log('Metadata name:', metadataName)
    console.log('Is currently active:', isCurrentlyActive)
    
    if (isCurrentlyActive) {
      // Button is already active - deselect it
      console.log('🎨 Button is already active - deselecting...')
      this.resetAllWaterDropButtons()
      this.removeAllCategoryColors()
      this.clearMetadataColoring()
      console.log('🎨 === DESELECTION COMPLETE ===')
      return
    }
    
    // Button is not active - select it
    // 1. Reset all water drop buttons to grey (cancel previous associations)
    //console.log('Step 1: Resetting all water drop buttons...')
    this.resetAllWaterDropButtons()
    
    // 1.5. Hide all reset buttons (since we're switching to a different metadata)
    //console.log('Step 1.5: Hiding all reset buttons...')
    this.hideAllResetButtons()
    
    // 2. Remove all existing colored disks from all metadata
    //console.log('Step 2: Removing all existing category colors...')
    this.removeAllCategoryColors()
    
    // 3. Set this button to blue (active)
    //console.log('Step 3: Setting this button as active...')
    this.setWaterDropButtonActive(button)
    
    // 4. Find the metadata item container and add colored categories (optional for continuous metadata)
    console.log('Step 4: Finding metadata container...')
    console.log('Button element:', button)
    console.log('Button parent elements:', button.parentElement, button.parentElement?.parentElement)
    
    // Try multiple selectors to find the metadata container
    let metadataContainer = button.closest('[data-metadata-item]')
    if (!metadataContainer) {
      // Try alternative selectors
      metadataContainer = button.closest('.metadata-item')
      if (!metadataContainer) {
        metadataContainer = button.closest('[data-metadata-id]')
      }
      if (!metadataContainer) {
        // Look for any parent with metadata-related classes
        metadataContainer = button.closest('.metadata')
      }
    }
    
    console.log('Metadata container found:', metadataContainer)
    console.log('Available data attributes on button:', Object.keys(button.dataset))
    
    if (metadataContainer) {
      // Check if this is continuous metadata - if so, skip category colors
      const isContinuousMetadata = button.dataset.metadataType === 'NUMERIC' || 
                                   metadataContainer.dataset.metadataType === 'NUMERIC'
      
      if (isContinuousMetadata) {
        console.log('Step 5: Continuous metadata detected - toggling inline range slider')
        // Toggle inline range slider for numeric metadata
        this.toggleInlineRangeSlider(metadataId, metadataName)
        return // Don't load metadata vector yet, wait for range selection
      } else {
        console.log('Step 5: Adding category colors for discrete metadata...')
        this.addCategoryColors(metadataContainer, metadataId)
      }
      
      // Category colors will be handled above, metadata vector loading happens below
    } else {
      console.warn('🎨 WARNING: Could not find metadata container, but continuing with metadata loading...')
      
      // Use the debug function to get detailed information
      this.debugMetadataContainerStructure(button)
      
      // This is not necessarily an error - we can still load the metadata vector
      console.log('Proceeding with metadata vector loading without container...')
    }
    
    // Always try to load and visualize the metadata vector (this is the main goal)
    console.log('Step 6: Loading metadata vector for visualization...')
    this.loadAndVisualizeMetadataVector(metadataId)
    
    //console.log('=== WATER DROP CLICK COMPLETE ===')
  }
  
  // Reset all water drop buttons to grey
  resetAllWaterDropButtons() {
    //console.log('resetAllWaterDropButtons: Starting...')
    const allButtons = document.querySelectorAll('[data-action*="waterDropClicked"]')
    //console.log('resetAllWaterDropButtons: Found', allButtons.length, 'buttons')
    allButtons.forEach((button, index) => {
      //console.log(`resetAllWaterDropButtons: Resetting button ${index}:`, button)
      button.style.color = '#9ca3af'
      button.style.backgroundColor = ''
      button.dataset.active = 'false'
    })
    //console.log('resetAllWaterDropButtons: Complete')
  }
  
  // Set a water drop button to active (blue)
  setWaterDropButtonActive(button) {
    //console.log('setWaterDropButtonActive: Setting button as active:', button)
    button.style.color = '#3b82f6'
    button.style.backgroundColor = '#dbeafe'
    button.dataset.active = 'true'
    //console.log('setWaterDropButtonActive: Button now has color:', button.style.color)
  }
  
  // Remove all category colors from all metadata
  removeAllCategoryColors() {
    //console.log('removeAllCategoryColors: Starting...')
    const allColorDisks = document.querySelectorAll('.category-color-disk')
    //console.log('removeAllCategoryColors: Found', allColorDisks.length, 'existing color disks')
    allColorDisks.forEach((disk, index) => {
      //console.log(`removeAllCategoryColors: Removing disk ${index}:`, disk)
      disk.remove()
    })
    //console.log('removeAllCategoryColors: Complete')
  }
  
  // Add colored disks to categories
  addCategoryColors(metadataContainer, metadataId) {
    //console.log('addCategoryColors called for metadata:', metadataId)
    
    // Remove existing category colors
    const existingColors = metadataContainer.querySelectorAll('.category-color-disk')
    //console.log('Removing existing colors:', existingColors.length)
    existingColors.forEach(color => color.remove())
    
    // First, make sure the categories are expanded
    const chevron = metadataContainer.querySelector('svg')
    const categoriesDiv = metadataContainer.querySelector('[style*="padding-left: 32px"]')
    //console.log('Chevron found:', !!chevron)
    //console.log('Categories div found:', !!categoriesDiv)
    
    if (chevron && chevron.style.transform !== 'rotate(90deg)') {
      //console.log('Expanding categories first...')
      // Directly expand the categories
      chevron.style.transform = 'rotate(90deg)'
      if (categoriesDiv) {
        categoriesDiv.style.display = 'block'
      }
    }
    
    // Wait a bit for the categories to expand, then add colors
    //console.log('Setting timeout for color addition...')
    setTimeout(() => {
      //console.log('Timeout executed - adding colors...')
      // Find categories container
      const categoriesContainer = metadataContainer.querySelector('[style*="padding-left: 32px"]')
      //console.log('Categories container found:', !!categoriesContainer)
      
      if (!categoriesContainer || categoriesContainer.style.display === 'none') {
        console.log('Categories container not found or hidden')
        return
      }
      
      // Get categories data
      //console.log('Getting categories for metadata...')
      const categories = this.getCategoriesForMetadata(metadataId)
      //console.log('Categories data:', categories)
      
      if (!categories || categories.length === 0) {
        console.log('No categories found')
        return
      }
    
    // Add colored disks to each category
    const categoryItems = categoriesContainer.querySelectorAll('div[style*="display: flex; justify-content: space-between"]')
    //console.log('Found category items:', categoryItems.length)
    
    categoryItems.forEach((item, index) => {
      // Set up the container for absolute positioning
      item.style.position = 'relative'
      item.style.paddingLeft = '20px' // Make space for the color disk
      
      const categoryName = item.querySelector('span').textContent.trim()
      const color = this.getCategoryColor(categoryName, index, metadataId)
      
      //console.log(`Adding color disk for "${categoryName}" (index ${index}) with color ${color}`)
      
      // Create color disk
      const colorDisk = document.createElement('div')
      colorDisk.className = 'category-color-disk'
      colorDisk.style.cssText = `
        position: absolute;
        left: 0px;
        top: 50%;
        transform: translateY(-50%);
        width: 12px; 
        height: 12px; 
        border-radius: 50%; 
        background-color: ${color}; 
        cursor: pointer; 
        border: 1px solid #d1d5db;
        transition: transform 0.2s;
      `
      colorDisk.dataset.categoryName = categoryName
      colorDisk.dataset.metadataId = metadataId
      
      // Add hover effect
      colorDisk.addEventListener('mouseenter', () => {
        colorDisk.style.transform = 'translateY(-50%) scale(1.2)'
      })
      colorDisk.addEventListener('mouseleave', () => {
        colorDisk.style.transform = 'translateY(-50%) scale(1)'
      })
      
      // Add click handler for color picker
      colorDisk.addEventListener('click', (e) => {
        e.stopPropagation()
        this.showColorPicker(e.target, categoryName, metadataId)
      })
      
      // Insert color disk at the beginning of the category item
      item.insertBefore(colorDisk, item.firstChild)
    })
    
    // Add reset button if there are customized colors
    this.addResetColorsButton(metadataContainer, metadataId)
    
    }, 200) // Wait 200ms for categories to expand
  }
  
  // Get categories data for a metadata item
  getCategoriesForMetadata(metadataId) {
    // Find the metadata container
    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return null
    
    // Find the categories container (the div with padding-left: 32px)
    const categoriesContainer = metadataContainer.querySelector('[style*="padding-left: 32px"]')
    if (!categoriesContainer || categoriesContainer.style.display === 'none') return null
    
    // Extract categories from the DOM
    const categoryItems = categoriesContainer.querySelectorAll('div[style*="display: flex; justify-content: space-between"]')
    const categories = []
    
    categoryItems.forEach(item => {
      const nameSpan = item.querySelector('span')
      const countSpan = item.querySelector('span:last-child')
      
      if (nameSpan && countSpan) {
        const name = nameSpan.textContent.trim()
        const countText = countSpan.textContent.trim()
        const count = parseInt(countText.match(/\d+/)?.[0]) || 0
        
        categories.push({ name, count })
      }
    })
    
    return categories
  }
  
  // Get color for a category (using the same color palette as the plot)
  getCategoryColor(categoryName, index, metadataId) {
    // Always check if we have a stored color for this category in this specific metadata
    const storageKey = `category_color_${metadataId}_${categoryName}`
    const storedColor = localStorage.getItem(storageKey)
    
    if (storedColor) {
      //console.log(`Using stored color for "${categoryName}" in metadata ${metadataId}: ${storedColor}`)
      return storedColor
    }
    
    // Use the same color palette as the plot
    if (window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0) {
      const color = window.CATEGORY_COLORS[index % window.CATEGORY_COLORS.length]
      //console.log(`Using default color for "${categoryName}" (index ${index}) in metadata ${metadataId}: ${color}`)
      return color
    }
    
    // Fallback to default colors if global colors are not available
    const defaultColors = [
      '#3b82f6', // blue
      '#ef4444', // red
      '#10b981', // green
      '#f59e0b', // yellow
      '#8b5cf6', // purple
      '#06b6d4', // cyan
      '#84cc16', // lime
      '#f97316'  // orange
    ]
    
    const fallbackColor = defaultColors[index % defaultColors.length]
    console.log(`Using fallback color for "${categoryName}" (index ${index}) in metadata ${metadataId}: ${fallbackColor}`)
    return fallbackColor
  }
  
  // Check if a metadata has any customized colors
  hasCustomizedColors(metadataId) {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i)
      if (key && key.startsWith(`category_color_${metadataId}_`)) {
        return true
      }
    }
    return false
  }

  // Clear all stored colors for a metadata
  clearStoredColors(metadataId) {
    //console.log(`Clearing all stored colors for metadata ${metadataId}`)
    const keysToRemove = []
    
    // Find all localStorage keys for this metadata
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i)
      if (key && key.startsWith(`category_color_${metadataId}_`)) {
        keysToRemove.push(key)
      }
    }
    
    // Remove the keys
    keysToRemove.forEach(key => {
      const categoryName = key.replace(`category_color_${metadataId}_`, '')
      //console.log(`Removing stored color for "${categoryName}"`)
      localStorage.removeItem(key)
    })
    
    //console.log(`Cleared ${keysToRemove.length} stored colors`)
  }

  // Add reset colors button for a metadata
  addResetColorsButton(metadataContainer, metadataId) {
    // Check if there are customized colors
    if (!this.hasCustomizedColors(metadataId)) {
      return // No customized colors, don't show reset button
    }

    // Check if this metadata is currently active (being used for coloring)
    const waterDropButton = metadataContainer.querySelector('[data-action*="waterDropClicked"]')
    if (!waterDropButton || waterDropButton.dataset.active !== 'true') {
      return // Metadata is not active, don't show reset button
    }

    // Check if reset button already exists
    const existingResetButton = metadataContainer.querySelector('.reset-colors-btn')
    if (existingResetButton) {
      return // Reset button already exists
    }

    // Create reset button
    const resetButton = document.createElement('button')
    resetButton.className = 'reset-colors-btn'
    resetButton.innerHTML = '<i class="fas fa-undo"></i>' // Font Awesome undo icon
    resetButton.title = 'Reset to default colors'
    resetButton.style.cssText = `
      padding: 4px;
      color: #ef4444;
      background: #fef2f2;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      transition: all 0.2s;
      margin-right: 4px;
      font-size: 16px;
      font-weight: normal;
      line-height: 1;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      vertical-align: top;
    `

    // Add hover effects
    resetButton.addEventListener('mouseenter', () => {
      if (resetButton.dataset.active !== 'true') {
        resetButton.style.color = '#dc2626'
        resetButton.style.backgroundColor = '#fee2e2'
      }
    })
    
    resetButton.addEventListener('mouseleave', () => {
      if (resetButton.dataset.active !== 'true') {
        resetButton.style.color = '#ef4444'
        resetButton.style.backgroundColor = '#fef2f2'
      }
    })

    // Add click handler
    resetButton.addEventListener('click', (e) => {
      e.stopPropagation()
      this.resetColorsForMetadata(metadataId)
    })

    // Insert before the water drop button
    waterDropButton.parentNode.insertBefore(resetButton, waterDropButton)
    
    // Ensure the reset button has the exact same height as the palette button
    const paletteButtonHeight = waterDropButton.offsetHeight
    resetButton.style.height = paletteButtonHeight + 'px'
    resetButton.style.minHeight = paletteButtonHeight + 'px'
    
    //console.log('Added reset colors button for metadata', metadataId, 'with height:', paletteButtonHeight + 'px')
  }

  // Reset colors for a specific metadata
  resetColorsForMetadata(metadataId) {
    //console.log('Resetting colors for metadata', metadataId)
    
    // Clear stored colors
    this.clearStoredColors(metadataId)
    
    // Clear cached color map
    this._cachedColorMap = null
    
    // Re-render the plot if this is the current metadata
    if (this.currentMetadataId === metadataId && this.currentMetadataVector) {
      //console.log('Re-rendering plot with default colors')
      this.renderPointsWithCurrentColoring()
      
      // Re-render category labels if they are visible
      if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
        //console.log('Re-rendering category labels with default colors')
        this.renderCategoryLabels()
      }
    }
    
    // Update the legend colors
    this.updateLegendColors(metadataId)
    
    // Remove the reset button since there are no more customized colors
    this.removeResetColorsButton(metadataId)
  }

  // Get default color for a category (ignoring localStorage)
  getDefaultCategoryColor(categoryName, index) {
    // Use the same color palette as the plot
    if (window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0) {
      const color = window.CATEGORY_COLORS[index % window.CATEGORY_COLORS.length]
      return color
    }
    
    // Fallback to default colors if global colors are not available
    const defaultColors = [
      '#3b82f6', // blue
      '#ef4444', // red
      '#10b981', // green
      '#f59e0b', // yellow
      '#8b5cf6', // purple
      '#06b6d4', // cyan
      '#84cc16', // lime
      '#f97316'  // orange
    ]
    
    return defaultColors[index % defaultColors.length]
  }

  // Update legend colors to default
  updateLegendColors(metadataId) {
    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return

    const colorDisks = metadataContainer.querySelectorAll('.category-color-disk')
    colorDisks.forEach((disk, index) => {
      const categoryName = disk.dataset.categoryName
      const defaultColor = this.getDefaultCategoryColor(categoryName, index)
      disk.style.backgroundColor = defaultColor
      //console.log(`Updated legend color for "${categoryName}" to default: ${defaultColor}`)
    })
  }

  // Remove reset button
  removeResetColorsButton(metadataId) {
    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return

    const resetButton = metadataContainer.querySelector('.reset-colors-btn')
    if (resetButton) {
      resetButton.remove()
      //console.log('Removed reset colors button for metadata', metadataId)
    }
  }

  // Hide all reset buttons (when switching to a different metadata)
  hideAllResetButtons() {
    const allResetButtons = document.querySelectorAll('.reset-colors-btn')
    allResetButtons.forEach(button => {
      button.remove()
    })
    //console.log('Hidden all reset buttons')
  }
  
  // Show color picker form
  showColorPicker(colorDisk, categoryName, metadataId) {
    //console.log(`showColorPicker called for category: ${categoryName}, metadata: ${metadataId}`)
    //console.log(`Current point size when opening color picker: ${this.currentPointSize}`)
    
    // Check if there's an existing color picker for the same category
    const existingPicker = document.getElementById('color-picker-form')
    if (existingPicker) {
      const existingCategory = existingPicker.dataset.category
      const existingMetadata = existingPicker.dataset.metadata
      
      // If clicking the same category disk again, hide the picker (toggle behavior)
      if (existingCategory === categoryName && existingMetadata === metadataId) {
        //console.log(`Toggling off color picker for category: ${categoryName}`)
        existingPicker.remove()
        return
      } else {
        // Different category, remove existing picker and show new one
      existingPicker.remove()
      }
    }
    
    // Create color picker form
    const picker = document.createElement('div')
    picker.id = 'color-picker-form'
    picker.dataset.category = categoryName
    picker.dataset.metadata = metadataId
    picker.style.cssText = `
      position: fixed;
      background: white;
      border: 1px solid #d1d5db;
      border-radius: 8px;
      padding: 16px;
      box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1);
      z-index: 1000;
      min-width: 200px;
    `
    
    // Get current color
    const currentColor = colorDisk.style.backgroundColor
    
    picker.innerHTML = `
      <h4 style="margin: 0 0 12px 0; font-size: 14px; font-weight: 500;">Change color for "${categoryName}"</h4>
      <div style="display: flex; gap: 8px; margin-bottom: 12px;">
        <input type="color" id="color-input" value="${currentColor}" style="width: 40px; height: 40px; border: none; border-radius: 4px; cursor: pointer;">
        <input type="text" id="color-text" value="${currentColor}" style="flex: 1; padding: 8px; border: 1px solid #d1d5db; border-radius: 4px; font-size: 12px;">
      </div>
      <div style="display: flex; gap: 8px; justify-content: flex-end;">
        <button id="cancel-color" style="padding: 6px 12px; border: 1px solid #d1d5db; background: white; border-radius: 4px; cursor: pointer; font-size: 12px;">Cancel</button>
        <button id="save-color" style="padding: 6px 12px; background: #3b82f6; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px;">Save</button>
      </div>
    `
    
    // Position the picker
    const rect = colorDisk.getBoundingClientRect()
    picker.style.left = `${rect.left + rect.width + 10}px`
    picker.style.top = `${rect.top}px`
    
    document.body.appendChild(picker)
    
    // Add event listeners
    const colorInput = picker.querySelector('#color-input')
    const colorText = picker.querySelector('#color-text')
    const cancelBtn = picker.querySelector('#cancel-color')
    const saveBtn = picker.querySelector('#save-color')
    
    // Sync color inputs
    colorInput.addEventListener('input', () => {
      colorText.value = colorInput.value
    })
    
    colorText.addEventListener('input', () => {
      if (/^#[0-9A-F]{6}$/i.test(colorText.value)) {
        colorInput.value = colorText.value
      }
    })
    
    // Cancel button
    cancelBtn.addEventListener('click', () => {
      picker.remove()
    })
    
    // Save button
    saveBtn.addEventListener('click', () => {
      const newColor = colorInput.value
      
      // Update the color disk
      colorDisk.style.backgroundColor = newColor
      
      // Store the color with metadata-specific key
      const storageKey = `category_color_${metadataId}_${categoryName}`
      localStorage.setItem(storageKey, newColor)
      
      // Clear the cached color map so plot will use updated colors
      this._cachedColorMap = null
      
      // Re-render the plot with the new color
      if (this.currentMetadataVector && this.currentMetadataId === metadataId) {
        //console.log('Color changed, re-rendering plot with updated colors')
        //console.log(`Current point size before re-render: ${this.currentPointSize}`)
        this.renderPointsWithCurrentColoring()
        
        // Re-render category labels if they are visible
        if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
          //console.log('Re-rendering category labels with updated colors')
          this.renderCategoryLabels()
        }
      } else {
        console.log('Color saved but not re-rendering plot (different metadata active)')
      }
      
      // Add reset button if it doesn't exist (first customization)
      const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
      if (metadataContainer) {
        this.addResetColorsButton(metadataContainer, metadataId)
      }
      
      // Close the picker
      picker.remove()
    })
    
    // Close on outside click
    setTimeout(() => {
      document.addEventListener('click', function closePicker(e) {
        if (!picker.contains(e.target)) {
          picker.remove()
          document.removeEventListener('click', closePicker)
        }
      })
    }, 0)
  }

  // Interaction Mode Methods
  // Set Pan/Zoom mode
  setPanMode(event) {
    //console.log('Setting interaction mode to: pan')
    this.setInteractionMode('pan')
    this.updateButtonStates('pan')
  }

  // Set Lasso mode
  setLassoMode(event) {
    //console.log('Setting interaction mode to: lasso')
    this.setInteractionMode('lasso')
    this.updateButtonStates('lasso')
  }

  // Set Pick mode
  setPickMode(event) {
    //console.log('Setting interaction mode to: pick')
    this.setInteractionMode('pick')
    this.updateButtonStates('pick')
  }

  // Set interaction mode (internal method)
  setInteractionMode(mode) {
    this.interactionMode = mode
    
    // Clear any existing interaction state
    this.clearLasso()
    
    // Only stop panning if we're actually in a panning state
    if (this.isPanning) {
    this.stopPanning()
    }
    
    // Ensure currentBounds is initialized if not already set
    if (!this.currentBounds && this.currentCoordinates) {
      const originalBounds = this.calculateBounds(this.currentCoordinates)
      this.currentBounds = this.getAdjustedBounds(originalBounds)
      //console.log('Initialized currentBounds in setInteractionMode:', this.currentBounds)
    }
    
    // Update cursor based on mode
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (canvas) {
      if (mode === 'lasso') {
        canvas.style.cursor = 'crosshair'
      } else if (mode === 'pan') {
        canvas.style.cursor = 'grab'
      } else if (mode === 'pick') {
        canvas.style.cursor = 'pointer'
      }
    }
    
    // Update label interaction behavior
    this.updateLabelInteractionMode()
    
    // Update control instructions
    this.updateControlInstructions()
    
    // Remove existing event listeners and add new ones
    this.removeInteractionEventListeners()
    this.addInteractionEventListeners()
    
    // Add global drag event handlers for labels
    this.setupGlobalDragHandlers()
  }

  // Update button visual states
  updateButtonStates(activeMode) {
    const panBtn = document.getElementById('pan-mode-btn')
    const pickBtn = document.getElementById('pick-mode-btn')
    const lassoBtn = document.getElementById('lasso-mode-btn')
    
    if (panBtn && pickBtn && lassoBtn) {
      // Reset all buttons to inactive state
      panBtn.style.backgroundColor = '#f3f4f6'
      panBtn.style.color = '#374151'
      pickBtn.style.backgroundColor = '#f3f4f6'
      pickBtn.style.color = '#374151'
      lassoBtn.style.backgroundColor = '#f3f4f6'
      lassoBtn.style.color = '#374151'
      
      // Set active button
      if (activeMode === 'pan') {
        panBtn.style.backgroundColor = '#3b82f6'
        panBtn.style.color = 'white'
      } else if (activeMode === 'pick') {
        pickBtn.style.backgroundColor = '#3b82f6'
        pickBtn.style.color = 'white'
      } else if (activeMode === 'lasso') {
        lassoBtn.style.backgroundColor = '#3b82f6'
        lassoBtn.style.color = 'white'
      }
    }
  }

  addInteractionEventListeners() {
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) {
      //console.log('No canvas available for interaction listeners')
      return
    }
    
    //console.log('Adding interaction event listeners to canvas')
    
    this.boundMouseDown = this.onInteractionMouseDown.bind(this)
    this.boundMouseMove = this.onInteractionMouseMove.bind(this)
    this.boundMouseUp = this.onInteractionMouseUp.bind(this)
    this.boundWheel = this.onInteractionWheel.bind(this)
    this.boundDoubleClick = this.onInteractionDoubleClick.bind(this)
    
    canvas.addEventListener('mousedown', this.boundMouseDown)
    canvas.addEventListener('mousemove', this.boundMouseMove)
    canvas.addEventListener('mouseup', this.boundMouseUp)
    canvas.addEventListener('wheel', this.boundWheel)
    canvas.addEventListener('dblclick', this.boundDoubleClick)
    
    /*console.log('Event listeners added:', {
      mousedown: !!this.boundMouseDown,
      mousemove: !!this.boundMouseMove,
      mouseup: !!this.boundMouseUp,
      wheel: !!this.boundWheel,
      dblclick: !!this.boundDoubleClick
    })*/
    
    // Set initial cursor
    if (this.interactionMode === 'pan') {
      canvas.style.cursor = 'grab'
      // Set cursor to grab (pan mode)
    } else if (this.interactionMode === 'lasso') {
      canvas.style.cursor = 'crosshair'
      // Set cursor to crosshair (lasso mode)
    } else if (this.interactionMode === 'pick') {
      canvas.style.cursor = 'pointer'
      // Set cursor to pointer (pick mode)
    }
  }

  removeInteractionEventListeners() {
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    if (this.boundMouseDown) {
      canvas.removeEventListener('mousedown', this.boundMouseDown)
    }
    if (this.boundMouseMove) {
      canvas.removeEventListener('mousemove', this.boundMouseMove)
    }
    if (this.boundMouseUp) {
      canvas.removeEventListener('mouseup', this.boundMouseUp)
    }
    if (this.boundWheel) {
      canvas.removeEventListener('wheel', this.boundWheel)
    }
    if (this.boundDoubleClick) {
      canvas.removeEventListener('dblclick', this.boundDoubleClick)
    }
  }

  onInteractionMouseDown(event) {
    //console.log('Mouse down event:', this.interactionMode)
    if (this.interactionMode === 'lasso') {
      this.onLassoMouseDown(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanMouseDown(event)
    } else if (this.interactionMode === 'pick') {
      this.onPickMouseDown(event)
    }
  }

  onInteractionMouseMove(event) {
    if (this.interactionMode === 'lasso') {
      this.onLassoMouseMove(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanMouseMove(event)
    }
  }

  onInteractionMouseUp(event) {
    if (this.interactionMode === 'lasso') {
      this.onLassoMouseUp(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanMouseUp(event)
    }
  }

  onInteractionDoubleClick(event) {
    //console.log('Double-click event:', this.interactionMode)
    if (this.interactionMode === 'lasso') {
      this.onLassoDoubleClick(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanDoubleClick(event)
    }
  }

  onInteractionWheel(event) {
    //console.log('Wheel event:', event.deltaY, 'isPanning:', this.isPanning, 'interactionMode:', this.interactionMode)
    
    // Don't zoom if we're currently panning (but allow zoom in pan mode when not actively panning)
    if (this.isPanning) {
      //console.log('Ignoring wheel event during active panning')
      return
    }
    
    // Zoom functionality
    event.preventDefault()
    
    if (!this.currentCoordinates || !this.currentBounds) {
      //console.log('No data available for zoom')
      return
    }
    
    //console.log('Zooming with data available')
    
    // Get mouse position relative to canvas
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    const rect = canvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    
    // Basic zoom implementation with faster increments, zooming around mouse cursor
    const delta = event.deltaY > 0 ? 1.05 : 0.95
    
    // Convert mouse position to data coordinates
    const mouseDataX = this.currentBounds.minX + (mouseX / this.pixiApp.screen.width) * (this.currentBounds.maxX - this.currentBounds.minX)
    const mouseDataY = this.currentBounds.minY + (mouseY / this.pixiApp.screen.height) * (this.currentBounds.maxY - this.currentBounds.minY)
    
    // Zoom around mouse cursor position
    const newBounds = {
      minX: mouseDataX - (mouseDataX - this.currentBounds.minX) * delta,
      maxX: mouseDataX + (this.currentBounds.maxX - mouseDataX) * delta,
      minY: mouseDataY - (mouseDataY - this.currentBounds.minY) * delta,
      maxY: mouseDataY + (this.currentBounds.maxY - mouseDataY) * delta
    }
    
    //console.log('Zoom: Updating bounds to:', newBounds, 'Mouse position:', { mouseX, mouseY })
    
    // Store the old bounds for translation calculation
    const oldBounds = { ...this.currentBounds }
    
    // Update current bounds
    this.currentBounds = newBounds
    
    // Check if we should use shape-based zooming for performance
    // Use a faster estimation instead of counting all points
    const boundsArea = (newBounds.maxX - newBounds.minX) * (newBounds.maxY - newBounds.minY)
    const totalArea = (this.currentBounds.maxX - this.currentBounds.minX) * (this.currentBounds.maxY - this.currentBounds.minY)
    const estimatedVisiblePoints = Math.floor((boundsArea / totalArea) * this.currentCoordinates.length)
    const useShapeZooming = estimatedVisiblePoints > 10000
    
    if (useShapeZooming) {
      //console.log('Using shape-based zooming for ~', estimatedVisiblePoints, 'visible points')
      
      // Hide points and show zooming shape
      if (this.scatterContainer) {
        this.scatterContainer.visible = false
      }
      if (this.categoryLabelsContainer) {
        this.categoryLabelsContainer.visible = false
      }
      
      // Store the bounds for this zooming operation
      const zoomingBounds = newBounds
      //console.log('Using zoomingBounds for this operation:', zoomingBounds)
      
      // Create or reuse zooming shape
      if (!this.zoomingShape) {
        // Create the zooming shape with the zooming bounds
        this.zoomingShape = this.createZoomingShapeWithBounds(zoomingBounds)
        if (this.zoomingShape && this.pixiApp) {
          this.pixiApp.stage.addChild(this.zoomingShape)
          // Start pulsing animation
          this.startZoomingAnimation()
        }
      } else {
        // Transform the existing shape instead of recreating it
        this.transformZoomingShape(oldBounds, newBounds)
        // Restart animation for the transformed shape
        this.startZoomingAnimation()
      }
      
      // Update axes and grid
      this.renderAxes()
      this.renderGrid()
      
      // Clear any existing timeout
      if (this.zoomTimeout) {
        clearTimeout(this.zoomTimeout)
      }
      
      // Schedule a delayed update to show actual points
      this.zoomTimeout = setTimeout(() => {
        this.finishZooming()
      }, 200) // Increased delay for better performance
      
    } else {
      // Use normal zooming for smaller datasets
      //console.log('Using normal zooming for ~', estimatedVisiblePoints, 'visible points')
      
      // Remove any existing zooming shape (in case we switched from shape-based to normal)
      if (this.zoomingShape && this.pixiApp) {
        // Remove the mask first
        if (this.zoomingShape.maskGraphics) {
          this.pixiApp.stage.removeChild(this.zoomingShape.maskGraphics)
          this.zoomingShape.maskGraphics = null
        }
        // Remove the shape
        this.pixiApp.stage.removeChild(this.zoomingShape)
        this.zoomingShape = null
      }
      
      // Clear any existing timeout
      if (this.zoomTimeout) {
        clearTimeout(this.zoomTimeout)
        this.zoomTimeout = null
      }
      
      // Update axes, grid, and category labels with new bounds
      this.renderAxes()
      this.renderGrid()
      this.renderCategoryLabels()
      
      // Use translation approach like pan mode, centered on mouse position
      this.translatePointsForZoom(oldBounds, newBounds, mouseX, mouseY)
    }
  }

  // Lasso mode handlers
  onLassoMouseDown(event) {
    console.log('Lasso mouse down - starting detailed performance tracking')
    this.isDrawingLasso = true
    this.lassoPoints = []
    this.mouseMoveCount = 0
    this.lastMouseMoveTime = performance.now()
    
    // Get mouse position relative to canvas
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    
    this.lassoPoints.push({ x, y })
    
    // Create lasso graphics object
    this.lassoGraphics = new this.PIXI.Graphics()
    this.scatterContainer.addChild(this.lassoGraphics)
  }

  onLassoMouseMove(event) {
    if (!this.isDrawingLasso) return
    
    const totalStartTime = performance.now()
    this.mouseMoveCount++
    
    // Track mouse event frequency
    const currentTime = performance.now()
    const timeSinceLastMove = currentTime - this.lastMouseMoveTime
    this.lastMouseMoveTime = currentTime
    
    // Get mouse position relative to canvas
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    const rectStartTime = performance.now()
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    const rectEndTime = performance.now()
    
    // Only add point if it's far enough from the last point
    const lastPoint = this.lassoPoints[this.lassoPoints.length - 1]
    let updateStartTime = 0
    let updateEndTime = 0
    
    if (!lastPoint || this.getDistance(lastPoint, { x, y }) >= this.minLassoPointDistance) {
      this.lassoPoints.push({ x, y })
      
      updateStartTime = performance.now()
      this.updateLassoGraphics()
      updateEndTime = performance.now()
    }
    
    const totalEndTime = performance.now()
    
    // Log detailed performance every 5 points
    if (this.lassoPoints.length % 5 === 0) {
      console.log(`Lasso Performance Analysis - Points: ${this.lassoPoints.length}`)
      console.log(`  - Mouse move count: ${this.mouseMoveCount}`)
      console.log(`  - Time since last move: ${timeSinceLastMove.toFixed(3)}ms`)
      console.log(`  - Rect calculation: ${(rectEndTime - rectStartTime).toFixed(3)}ms`)
      console.log(`  - Graphics update: ${(updateEndTime - updateStartTime).toFixed(3)}ms`)
      console.log(`  - Total time: ${(totalEndTime - totalStartTime).toFixed(3)}ms`)
      console.log(`  - Points array length: ${this.lassoPoints.length}`)
      console.log(`  - PIXI App exists: ${!!this.pixiApp}`)
      console.log(`  - PIXI Renderer exists: ${!!(this.pixiApp && this.pixiApp.renderer)}`)
    }
  }

  onLassoMouseUp(event) {
    if (!this.isDrawingLasso) return
    
    //console.log('Lasso mouse up - completing selection')
    this.isDrawingLasso = false
    
    // Only proceed if we have a PIXI app and coordinates to work with
    if (!this.pixiApp || !this.currentCoordinates) {
      //console.log('No PIXI app or coordinates available for lasso selection')
      this.clearLasso()
      return
    }
    
    // Complete the lasso by closing the path
    if (this.lassoPoints.length > 2) {
      this.lassoPoints.push(this.lassoPoints[0]) // Close the loop
      
      // Force final graphics update
      this.updateLassoGraphics()
      
      // Find points inside the lasso
      this.selectPointsInLasso()
    }
    
    // Clear lasso after a short delay
    setTimeout(() => {
      this.clearLasso()
    }, 1000)
  }

  // Pan mode handlers
  onPanMouseDown(event) {
    //console.log('Pan mouse down')
    this.isPanning = true
    
    // Store starting position
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    this.panStartX = event.clientX - rect.left
    this.panStartY = event.clientY - rect.top
    
    // Store current bounds
    this.panStartBounds = { ...this.currentBounds }
    
    // Store original bounds for consistent pan scaling
    this.panOriginalBounds = this.calculateBounds(this.currentCoordinates)
    
    /*console.log('Pan Start Debug:', {
      panStartBounds: this.panStartBounds,
      panOriginalBounds: this.panOriginalBounds,
      currentBounds: this.currentBounds,
      screenSize: { width: this.pixiApp.screen.width, height: this.pixiApp.screen.height }
    })*/
    
    // Hide points and category labels during panning for smooth performance
    if (this.scatterContainer) {
      this.scatterContainer.visible = false
    }
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.visible = false
    }
    
    // Create and show the panning shape
    this.panningShape = this.createPanningShape()
    if (this.panningShape && this.pixiApp) {
      this.pixiApp.stage.addChild(this.panningShape)
    }
    
    // Change cursor to grabbing
    const panCanvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (panCanvas) {
      panCanvas.style.cursor = 'grabbing'
    }
  }

  onPanMouseMove(event) {
    if (!this.isPanning) return
    
    // Get current mouse position
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    const currentX = event.clientX - rect.left
    const currentY = event.clientY - rect.top
    
    // Calculate pan delta
    const deltaX = currentX - this.panStartX
    const deltaY = currentY - this.panStartY
    
    // Store the mouse delta for label movement
    this.panMouseDeltaX = deltaX
    this.panMouseDeltaY = deltaY
    
    // Convert screen delta to data delta using the same coordinate system as normalization
    const screenWidth = this.pixiApp.screen.width
    const screenHeight = this.pixiApp.screen.height
    
    // Use current bounds for pan calculation to match current view
    const dataDeltaX = (deltaX / screenWidth) * (this.panStartBounds.maxX - this.panStartBounds.minX)
    const dataDeltaY = (deltaY / screenHeight) * (this.panStartBounds.maxY - this.panStartBounds.minY)
    
    // Update bounds - invert Y delta to match the inverted Y-axis in normalizeY
    const newBounds = {
      minX: this.panStartBounds.minX - dataDeltaX,
      maxX: this.panStartBounds.maxX - dataDeltaX,
      minY: this.panStartBounds.minY + dataDeltaY, // Invert Y delta to match coordinate system
      maxY: this.panStartBounds.maxY + dataDeltaY
    }
    
    // Debug: Check if bounds are changing size (indicating zoom)
    const startWidth = this.panStartBounds.maxX - this.panStartBounds.minX
    const startHeight = this.panStartBounds.maxY - this.panStartBounds.minY
    const newWidth = newBounds.maxX - newBounds.minX
    const newHeight = newBounds.maxY - newBounds.minY
    
    /*console.log('Pan Debug:', {
      deltaX: deltaX,
      deltaY: deltaY,
      dataDeltaX: dataDeltaX,
      dataDeltaY: dataDeltaY,
      startBounds: this.panStartBounds,
      newBounds: newBounds,
      sizeChange: {
        width: { start: startWidth, new: newWidth, diff: newWidth - startWidth },
        height: { start: startHeight, new: newHeight, diff: newHeight - startHeight }
      }
    })*/
    
    // Update bounds in real-time during panning
    this.currentBounds = newBounds
    
    // Update axes and grid with new bounds
    this.renderAxes()
    this.renderGrid()
    
    // Move the points to match the new bounds during panning
    this.updatePointPositions()

    // Don't update category labels during panning - they will be updated when panning stops
    
    // Move the panning shape as well
    if (this.panningShape) {
      this.panningShape.x = deltaX
      this.panningShape.y = deltaY
    }
    
    /*console.log('Pan Move Debug:', {
      deltaX: deltaX,
      deltaY: deltaY,
      shapePosition: this.panningShape ? { x: this.panningShape.x, y: this.panningShape.y } : 'No shape'
    })*/
  }

  onPanMouseUp(event) {
    if (!this.isPanning) return
    
    //console.log('Pan mouse up')
    this.stopPanning()
  }

  stopPanning() {
    this.isPanning = false
    
    // Store bounds for debug before resetting
    const debugPanStartBounds = this.panStartBounds
    const debugPanOriginalBounds = this.panOriginalBounds
    
    // Bounds are already updated in real-time during panning, no need to recalculate
    
    // Remove the panning shape and its mask
    if (this.panningShape && this.pixiApp) {
      // Remove the mask first
      if (this.panningShape.maskGraphics) {
        this.pixiApp.stage.removeChild(this.panningShape.maskGraphics)
        this.panningShape.maskGraphics = null
      }
      // Remove the shape
      this.pixiApp.stage.removeChild(this.panningShape)
      this.panningShape = null
    }
    

    // Reset panning state
    this.panStartX = 0
    this.panStartY = 0
    this.panStartBounds = null
    this.panOriginalBounds = null
    this.panMouseDeltaX = undefined
    this.panMouseDeltaY = undefined
    
    // Show points and category labels again after panning is finished
    if (this.scatterContainer) {
      this.scatterContainer.visible = true
    }
    // Refresh labels after panning with a delay to ensure all position updates are complete
    if (this.categoryLabelsContainer) {
      // Check if categories should be visible
      const categoriesCheckbox = document.getElementById('show-categories-checkbox')
      if (categoriesCheckbox && categoriesCheckbox.checked) {
        // Use delayed refresh to ensure all position updates are complete
        setTimeout(() => {
          console.log(`🏷️ Refreshing labels after panning (delayed)`)
          this.renderCategoryLabels()
        }, 200)
      }
    }
    
    // Update point positions to match the new bounds after panning
    /*console.log('Pan Stop Debug:', {
      finalBounds: finalBounds,
      panStartBounds: debugPanStartBounds,
      panOriginalBounds: debugPanOriginalBounds,
      boundsDifference: finalBounds && debugPanStartBounds ? {
        minX: finalBounds.minX - debugPanStartBounds.minX,
        maxX: finalBounds.maxX - debugPanStartBounds.maxX,
        minY: finalBounds.minY - debugPanStartBounds.minY,
        maxY: finalBounds.maxY - debugPanStartBounds.maxY
      } : 'Cannot calculate - missing bounds'
    })*/
    
    if (this.currentCoordinates && this.scatterContainer && this.currentBounds) {
      this.updatePointPositions()
    }
    
    // Reset cursor
    const stopCanvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (stopCanvas) {
      if (this.interactionMode === 'pan') {
        stopCanvas.style.cursor = 'grab'
      }
    }
  }

  // Double-click handlers for pan and lasso modes
  onPanDoubleClick(event) {
    //console.log('Pan mode double-click: Resetting zoom and pan')
    this.resetZoomAndPan()
  }

  onLassoDoubleClick(event) {
    //console.log('Lasso mode double-click: Canceling current selection')
    this.cancelSelection()
  }




  // Reset zoom and pan to original view
  resetZoomAndPan() {
    if (!this.currentCoordinates) {
      //console.log('No data available for reset')
      return
    }

    //console.log('Resetting to original view')
    
    // Clear any stored original positions to force re-rendering
    this.clearStoredOriginalPositions()
    
    // Reset to original bounds
    const originalBounds = this.calculateBounds(this.currentCoordinates)
    this.currentBounds = this.getAdjustedBounds(originalBounds)
    
    // Force re-render all points with original bounds
    this.scatterContainer.removeChildren()
    this.renderPointsWithCurrentColoring()
    
    // Re-render category labels after resetting view
    if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
      this.renderCategoryLabels()
    }
    
    //console.log('Zoom and pan reset to original view')
  }

  updateVisualizationBounds(newBounds) {
    //console.log('updateVisualizationBounds called with:', newBounds)
    this.currentBounds = newBounds
    
    // Update axes and grid with new bounds
    this.renderAxes()
    this.renderGrid()
    
    // Don't update category labels during panning to avoid coordinate issues
    // Labels will be updated when panning stops
    
    // Update point positions when not panning (during panning, points are updated in onPanMouseMove)
    if (!this.isPanning) {
      // Update existing point positions instead of re-rendering
      if (this.currentCoordinates && this.scatterContainer) {
        this.updatePointPositions()
      } else {
        console.log('Cannot update positions - missing data')
      }
    }
  }

  // Optimized method to update point positions without re-rendering
  // Count how many points are visible in the given bounds
  countVisiblePoints(bounds) {
    if (!this.currentCoordinates || !bounds) return 0
    
    let visibleCount = 0
    for (let i = 0; i < this.currentCoordinates.length; i++) {
      const [x, y] = this.currentCoordinates[i]
      if (x >= bounds.minX && x <= bounds.maxX && y >= bounds.minY && y <= bounds.maxY) {
        visibleCount++
      }
    }
    return visibleCount
  }

  // Transform existing zooming shape instead of recreating it
  transformZoomingShape(oldBounds, newBounds) {
    if (!this.zoomingShape) return
    
    // Reset container scale to avoid double transformation
    this.zoomingShape.scale.x = 1
    this.zoomingShape.scale.y = 1
    
    // Update individual point positions based on new bounds using proper coordinate system
    this.zoomingShape.children.forEach((pointSprite, index) => {
      if (this.currentCoordinates && index < this.currentCoordinates.length) {
        const [x, y] = this.currentCoordinates[index]
        // Use the same coordinate system as normalizeX/Y with proper margins and Y-axis inversion
        pointSprite.x = this.normalizeX(x, newBounds)
        pointSprite.y = this.normalizeY(y, newBounds)
        
        // Update the stored comparison point for index 0
        if (index === 0) {
          this.zoomingShapePoint0 = { 
            x: pointSprite.x, 
            y: pointSprite.y, 
            dataCoords: [x, y] 
          }
          //console.log('Updated zoomingShapePoint0 in transformZoomingShape:', this.zoomingShapePoint0)
        }
      }
    })
  }

  // Create a shape for zooming with specific bounds
  createZoomingShapeWithBounds(bounds) {
    if (!this.pixiApp || !bounds || !this.currentCoordinates) return null
    
    const container = new PIXI.Container()
    
    // Sample points to create a simplified representation
    const sampleSize = Math.min(10000, this.currentCoordinates.length)
    const step = Math.max(1, Math.floor(this.currentCoordinates.length / sampleSize))
    
    // Cache bounds calculations for performance (same as updatePointPositions)
    const width = bounds.maxX - bounds.minX
    const height = bounds.maxY - bounds.minY
    
    // Debug: Log bounds being used for zooming shape
    /*console.log('Zooming Shape Bounds:', {
      bounds: bounds,
      width: width,
      height: height,
      screenSize: { width: this.pixiApp.screen.width, height: this.pixiApp.screen.height },
      timestamp: Date.now()
    })*/
    
    // Create individual animated point sprites
    for (let i = 0; i < this.currentCoordinates.length; i += step) {
      const [x, y] = this.currentCoordinates[i]
      
      // Use the same coordinate system as normalizeX/Y with proper margins and Y-axis inversion
      const screenX = this.normalizeX(x, bounds)
      const screenY = this.normalizeY(y, bounds)
      
      // Debug: Log coordinates for first few points to understand the shift
      /*if (i < 5) {
        console.log(`Zooming Shape Point ${i}:`, {
          dataCoords: [x, y],
          normalizedCoords: [normalizedX, normalizedY],
          screenCoords: [screenX, screenY],
          bounds: bounds,
          width: width,
          height: height,
          screenSize: { width: this.pixiApp.screen.width, height: this.pixiApp.screen.height },
          calculation: {
            step1: `(${x} - ${bounds.minX}) / ${width} = ${normalizedX}`,
            step2: `${normalizedX} * ${this.pixiApp.screen.width} = ${screenX}`
          }
        })
      }*/
      
      // Store for comparison with real points
      if (i === 0) {
        this.zoomingShapePoint0 = { x: screenX, y: screenY, dataCoords: [x, y] }
      }
      
      // Get color for this point
      const colorInfo = this.getColorAndAlpha(i)
      const color = colorInfo.color
      const alpha = colorInfo.alpha * 0.8
      
      // Create individual point graphics
      const pointGraphics = new PIXI.Graphics()
      
      // Create multi-layer point with glow
      const baseSize = 2
      const glowSize = 4
      const pulseSize = 6
      
      // Outer pulse ring
      pointGraphics.beginFill(color, alpha * 0.1)
      pointGraphics.drawCircle(0, 0, pulseSize)
      pointGraphics.endFill()
      
      // Glow effect
      pointGraphics.beginFill(color, alpha * 0.3)
      pointGraphics.drawCircle(0, 0, glowSize)
      pointGraphics.endFill()
      
      // Main point
      pointGraphics.beginFill(color, alpha)
      pointGraphics.drawCircle(0, 0, baseSize)
      pointGraphics.endFill()
      
      // Position the point
      pointGraphics.x = screenX
      pointGraphics.y = screenY
      
      // Store animation properties
      pointGraphics.originalAlpha = alpha
      pointGraphics.originalScale = 1.0
      pointGraphics.animationOffset = i * 0.1 // Stagger animation timing
      
      container.addChild(pointGraphics)
    }
    
    // Position the container
    container.x = 0
    container.y = 0
    
    // Create a mask to clip the container to the plot area only
    const margins = this.getPlotMargins()
    const plotWidth = this.pixiApp.screen.width - margins.left - margins.right
    const plotHeight = this.pixiApp.screen.height - margins.top - margins.bottom
    
    const mask = new PIXI.Graphics()
    mask.beginFill(0xffffff, 1.0)
    mask.drawRect(margins.left, margins.top, plotWidth, plotHeight)
    mask.endFill()
    
    // Apply the mask to the container
    container.mask = mask
    
    // Add the mask to the stage so it's rendered
    if (this.pixiApp && this.pixiApp.stage) {
      this.pixiApp.stage.addChild(mask)
      // Store reference to mask for cleanup
      container.maskGraphics = mask
    }
    
    // Debug: Log container positioning
    /*console.log('Zooming Shape Container Position:', {
      containerX: container.x,
      containerY: container.y,
      containerScale: { x: container.scale.x, y: container.scale.y }
    })*/
    
    return container
  }

  // Create a shape for zooming (backward compatibility - uses current bounds)
  createZoomingShape() {
    return this.createZoomingShapeWithBounds(this.currentBounds)
  }

  // Start pulsing animation for the zooming shape
  startZoomingAnimation() {
    if (!this.zoomingShape || this.zoomingAnimationId) return
    
    let time = 0
    const animate = () => {
      if (!this.zoomingShape || !this.zoomingShape.visible) {
        this.stopZoomingAnimation()
        return
      }
      
      // Animate each individual point sprite
      this.zoomingShape.children.forEach((pointSprite, index) => {
        if (pointSprite.originalAlpha !== undefined) {
          // Create staggered pulsing effect
          const animationTime = time + pointSprite.animationOffset
          /*
          // Pulsing alpha (more dramatic)
          const alphaPulse = Math.sin(animationTime * 0.008) * 0.3 + 0.7 // 0.4 to 1.0
          pointSprite.alpha = alphaPulse
          
          // Pulsing scale (more noticeable)
          const scalePulse = Math.sin(animationTime * 0.006) * 0.2 + 1.0 // 0.8 to 1.2
          pointSprite.scale.set(scalePulse)
          
          // Subtle rotation for extra dynamism
          const rotation = Math.sin(animationTime * 0.003) * 0.1
          pointSprite.rotation = rotation
          */
          pointSprite.alpha = 0.7
          
        }
      })
      
      time += 16 // ~60fps
      this.zoomingAnimationId = requestAnimationFrame(animate)
    }
    
    this.zoomingAnimationId = requestAnimationFrame(animate)
  }

  // Stop the zooming animation
  stopZoomingAnimation() {
    if (this.zoomingAnimationId) {
      cancelAnimationFrame(this.zoomingAnimationId)
      this.zoomingAnimationId = null
    }
    
    // Reset all point sprite properties
    if (this.zoomingShape && this.zoomingShape.children) {
      this.zoomingShape.children.forEach(pointSprite => {
        if (pointSprite.originalAlpha !== undefined) {
          pointSprite.alpha = pointSprite.originalAlpha
          pointSprite.scale.set(pointSprite.originalScale)
          pointSprite.rotation = 0
        }
      })
    }
  }

  // Finish zooming by removing the shape and showing actual points
  finishZooming() {
    // Clear the timeout
    if (this.zoomTimeout) {
      clearTimeout(this.zoomTimeout)
      this.zoomTimeout = null
    }
    
    // Stop animation
    this.stopZoomingAnimation()
    
    // Remove the zooming shape and its mask
    if (this.zoomingShape && this.pixiApp) {
      // Remove the mask first
      if (this.zoomingShape.maskGraphics) {
        this.pixiApp.stage.removeChild(this.zoomingShape.maskGraphics)
        this.zoomingShape.maskGraphics = null
      }
      // Remove the shape
      this.pixiApp.stage.removeChild(this.zoomingShape)
      this.zoomingShape = null
    }
    
    // Show points and category labels again
    if (this.scatterContainer) {
      this.scatterContainer.visible = true
    }
    if (this.categoryLabelsContainer) {
      // Check if categories should be visible
      const categoriesCheckbox = document.getElementById('show-categories-checkbox')
      if (categoriesCheckbox && categoriesCheckbox.checked) {
        //this.categoryLabelsContainer.visible = true
        setTimeout(() => {
          console.log(`🏷️ Refreshing labels after panning (delayed)`)
          this.renderCategoryLabels()
        }, 200)
        //this.renderCategoryLabels()
      }
    }
    
    // Update point positions (bounds should already be correct)
    if (this.currentCoordinates && this.scatterContainer && this.currentBounds) {
      this.updatePointPositions()
    }
  }

  // Create a shape that mimics the actual plot for smooth panning
  createPanningShape() {
    if (!this.pixiApp || !this.currentBounds || !this.currentCoordinates) return null
    
    const shape = new PIXI.Graphics()
    const margins = this.getPlotMargins()
    
    // Get the plot area dimensions (same as axes/grid)
    const plotWidth = this.pixiApp.screen.width - margins.left - margins.right
    const plotHeight = this.pixiApp.screen.height - margins.top - margins.bottom
    
    // Sample points to create a simplified representation
    const sampleSize = Math.min(10000, this.currentCoordinates.length) // Sample up to 10000 points
    const step = Math.max(1, Math.floor(this.currentCoordinates.length / sampleSize))
    
    // Create a simplified point cloud representation
    for (let i = 0; i < this.currentCoordinates.length; i += step) {
      const [x, y] = this.currentCoordinates[i]
      
      // Use the same coordinate system as the actual points
      const screenX = this.normalizeX(x, this.currentBounds)
      const screenY = this.normalizeY(y, this.currentBounds)
      
      // Get color for this point
      const colorInfo = this.getColorAndAlpha(i)
      const color = colorInfo.color
      const alpha = colorInfo.alpha * 0.8 // Slightly more opaque for better visibility
      
      // Draw a small circle for each point with a subtle glow effect
      shape.beginFill(color, alpha)
      shape.drawCircle(screenX, screenY, 2) // Slightly larger for better visibility
      shape.endFill()
      
      // Add a subtle glow effect for better visual appeal
      shape.beginFill(color, alpha * 0.3)
      shape.drawCircle(screenX, screenY, 3.5)
      shape.endFill()
    }
    
    // Position the shape at the current plot area
    shape.x = 0
    shape.y = 0
    
    // Create a mask to clip the shape to the plot area only
    const mask = new PIXI.Graphics()
    mask.beginFill(0xffffff, 1.0)
    mask.drawRect(margins.left, margins.top, plotWidth, plotHeight)
    mask.endFill()
    
    // Apply the mask to the shape
    shape.mask = mask
    
    // Add the mask to the stage so it's rendered
    if (this.pixiApp && this.pixiApp.stage) {
      this.pixiApp.stage.addChild(mask)
      // Store reference to mask for cleanup
      shape.maskGraphics = mask
    }
    
    return shape
  }

  updatePointPositions() {
    if (!this.currentCoordinates || !this.currentBounds || !this.scatterContainer) {
      console.log('Cannot update positions - missing data:', {
        coordinates: !!this.currentCoordinates,
        bounds: !!this.currentBounds,
        container: !!this.scatterContainer
      })
      return
    }
    
   /* console.log('UpdatePointPositions Debug:', {
      currentBounds: this.currentBounds,
      coordinatesCount: this.currentCoordinates.length,
      scatterContainerChildren: this.scatterContainer.children.length
    })*/

    /*console.log('Updating point positions:', {
      pointCount: this.scatterContainer.children.length,
      coordinateCount: this.currentCoordinates.length
    })*/

    // For pan operations, we should just translate existing positions
    // For zoom operations, we need to recalculate from coordinates (scale change)
    if (this.isPanning && this.panStartBounds) {
      //console.log('Panning: Translating existing positions')
      this.translatePointPositions()
      return
    }

    // Cache bounds calculations for performance
    const bounds = this.currentBounds
    const width = bounds.maxX - bounds.minX
    const height = bounds.maxY - bounds.minY
    
    // Debug: Log bounds being used for real points
    /*console.log('Real Points Bounds:', {
      bounds: bounds,
      width: width,
      height: height,
      screenSize: { width: this.pixiApp.screen.width, height: this.pixiApp.screen.height },
      timestamp: Date.now(),
      callStack: new Error().stack
    })*/

    let updatedCount = 0

    // Helper function to update points in a container
    const updatePointsInContainer = (container, containerName) => {
      container.children.forEach((child, index) => {
        // Debug: Check what we're working with
        if (index < 3) {
          /*console.log(`${containerName} Point ${index}:`, {
            isPoint: child.isPoint,
            cellId: child.cellId,
            hasPosition: child.x !== undefined && child.y !== undefined
          })*/
        }

        // Try to update if it's a point with cellId
        if (child.isPoint && child.cellId !== undefined && child.cellId < this.currentCoordinates.length) {
          const [x, y] = this.currentCoordinates[child.cellId]
          
          // Optimized normalization (avoid function calls)
          const normalizedX = (x - bounds.minX) / width
          const normalizedY = (y - bounds.minY) / height
          
          // Convert to screen coordinates using the same system as normalizeX/Y
          if (this.pixiApp) {
            // Debug: Log coordinate calculation for first few points
            if (index < 3) {
              const realScreenX = normalizedX * this.pixiApp.screen.width
              const realScreenY = normalizedY * this.pixiApp.screen.height
              
              /*console.log(`Real Point ${index} coordinate calculation:`, {
                originalCoords: [x, y],
                normalizedCoords: [normalizedX, normalizedY],
                pixiScreenSize: { width: this.pixiApp.screen.width, height: this.pixiApp.screen.height },
                calculatedPosition: {
                  x: realScreenX,
                  y: realScreenY
                },
                bounds: bounds,
                width: width,
                height: height,
                calculation: {
                  step1: `(${x} - ${bounds.minX}) / ${width} = ${normalizedX}`,
                  step2: `${normalizedX} * ${this.pixiApp.screen.width} = ${realScreenX}`
                }
              })*/
              
              // Compare with zooming shape point 0
              /*if (index === 0 && this.zoomingShapePoint0) {
                const deltaX = realScreenX - this.zoomingShapePoint0.x
                const deltaY = realScreenY - this.zoomingShapePoint0.y
                console.log(`Point 0 Comparison:`, {
                  zoomingShape: this.zoomingShapePoint0,
                  realPoint: { x: realScreenX, y: realScreenY, dataCoords: [x, y] },
                  delta: { x: deltaX, y: deltaY },
                  sameDataCoords: x === this.zoomingShapePoint0.dataCoords[0] && y === this.zoomingShapePoint0.dataCoords[1]
                })
              }*/
            }
            
            // Use the same coordinate system as normalizeX/Y with proper margins and Y-axis inversion
            child.x = this.normalizeX(x, bounds)
            child.y = this.normalizeY(y, bounds)
            updatedCount++
          }
        }
      })
    }

    // Update positions of existing points in scatterContainer (direct children)
    updatePointsInContainer(this.scatterContainer, 'Direct')
    
    // Also check for points in animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      //console.log('Found animatedContainer with', this.animatedContainer.children.length, 'children')
      updatePointsInContainer(this.animatedContainer, 'Animated')
    }

    //console.log(`Updated ${updatedCount} point positions`)
    
    // Fallback: If no points were updated, fall back to re-rendering
    if (updatedCount === 0 && this.scatterContainer.children.length > 0) {
      //console.log('No points updated, falling back to re-rendering')
      // Only fall back if we have coordinates and bounds
      if (this.currentCoordinates && this.currentBounds) {
        this.forceReRenderPoints()
      }
    }
  }

  // Translate existing point positions for pan operations
  translatePointPositions() {
    if (!this.panStartBounds || !this.currentBounds) return

    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return

    // Calculate the translation needed (direct from bounds difference)
    const scaleFactor = 0.5 // Reduce sensitivity by half
    const deltaX = (this.currentBounds.minX - this.panStartBounds.minX) * (canvas.width / (this.panStartBounds.maxX - this.panStartBounds.minX)) * scaleFactor
    const deltaY = (this.currentBounds.minY - this.panStartBounds.minY) * (canvas.height / (this.panStartBounds.maxY - this.panStartBounds.minY)) * scaleFactor

    //console.log('Pan Translation:', { deltaX, deltaY })

    let translatedCount = 0

    // Helper function to translate points in a container
    const translatePointsInContainer = (container, containerName) => {
      container.children.forEach((child) => {
        if (child.isPoint) {
          // Always translate from current position, not stored original
          const currentX = child.x
          const currentY = child.y
          
          // Apply translation from current position
          child.x = currentX - deltaX
          child.y = currentY - deltaY
          translatedCount++
        }
      })
    }

    // Translate points in scatterContainer (direct children)
    translatePointsInContainer(this.scatterContainer, 'Direct')
    
    // Also check for points in animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      //console.log('Found animatedContainer with', this.animatedContainer.children.length, 'children for pan translation')
      translatePointsInContainer(this.animatedContainer, 'Animated')
    }

    // Don't update panStartBounds - keep original reference for sharp direction changes
    // this.panStartBounds = { ...this.currentBounds }

    //console.log(`Pan translated ${translatedCount} point positions`)
  }

  // Translate existing point positions for zoom operations (like pan but with scale)
  translatePointsForZoom(oldBounds, newBounds, mouseX = null, mouseY = null) {
    if (!oldBounds || !newBounds) return

    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return

    // Calculate scale factors for zoom
    const oldWidth = oldBounds.maxX - oldBounds.minX
    const oldHeight = oldBounds.maxY - oldBounds.minY
    const newWidth = newBounds.maxX - newBounds.minX
    const newHeight = newBounds.maxY - newBounds.minY

    const scaleX = oldWidth / newWidth  // Invert because we're zooming in
    const scaleY = oldHeight / newHeight

    // Use mouse position as zoom center, fallback to canvas center
    const centerX = mouseX !== null ? mouseX : canvas.width / 2
    const centerY = mouseY !== null ? mouseY : canvas.height / 2

    //console.log('Zoom Translation:', { scaleX, scaleY, centerX, centerY, mouseX, mouseY })

    let translatedCount = 0

    // Helper function to translate points in a container
    const translatePointsInContainer = (container, containerName) => {
      container.children.forEach((child) => {
        if (child.isPoint) {
          // Always scale from current position, not stored original
          const currentX = child.x
          const currentY = child.y
          
          // Apply zoom transformation: scale around mouse position
          const relativeX = currentX - centerX
          const relativeY = currentY - centerY
          
          child.x = centerX + (relativeX * scaleX)
          child.y = centerY + (relativeY * scaleY)
          translatedCount++
        }
      })
    }

    // Translate points in scatterContainer (direct children)
    translatePointsInContainer(this.scatterContainer, 'Direct')
    
    // Also check for points in animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      //console.log('Found animatedContainer with', this.animatedContainer.children.length, 'children for zoom translation')
      translatePointsInContainer(this.animatedContainer, 'Animated')
    }

    //console.log(`Zoom translated ${translatedCount} point positions`)
  }

  // Clear stored original positions (called when coordinates change)
  clearStoredOriginalPositions() {
    //console.log('Clearing stored original positions')
    
    // Clear positions in scatterContainer
    this.scatterContainer.children.forEach((child) => {
      if (child.isPoint) {
        delete child.originalX
        delete child.originalY
      }
    })
    
    // Also clear positions in animatedContainer if it exists
    if (this.animatedContainer) {
      this.animatedContainer.children.forEach((child) => {
        if (child.isPoint) {
          delete child.originalX
          delete child.originalY
        }
      })
    }
  }

  // Force re-render when colors or metadata change
  forceReRenderPoints() {
    if (this.currentCoordinates && this.scatterContainer) {
      // Check if we have the nested structure (animatedContainer)
      if (this.animatedContainer && this.scatterContainer.children.includes(this.animatedContainer)) {
        // Preserve nested structure: clear points from animatedContainer, not scatterContainer
        this.animatedContainer.removeChildren()
        
        // Re-render points in the animatedContainer (preserving nested structure)
        this.renderPointsWithCurrentColoringInContainer(this.animatedContainer)
      } else {
        // Fallback to old method if no nested structure
        this.scatterContainer.removeChildren()
        this.renderPointsWithCurrentColoring()
      }
      
      // Re-render category labels after force re-render
      if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
        this.renderCategoryLabels()
      }
    }
  }

  // Render points with current coloring in a specific container (preserves nested structure)
  renderPointsWithCurrentColoringInContainer(container) {
    if (!this.currentCoordinates || !container) {
      console.log('Cannot render points - missing coordinates or container')
      return
    }

    // Get filtered indices for current filtering state
    const filteredIndices = this.getIncrementalFilteredIndices()
    
    // Create points in the specified container using the same method as the main rendering
    this.currentCoordinates.forEach((coord, i) => {
      // If no filtering is applied (filteredIndices is null), show all points
      if (!filteredIndices || filteredIndices.includes(i)) {
        const { color, alpha } = this.getColorAndAlpha(i)
        
        // Extract x, y from coordinate array
        const [x, y] = coord
        
        // Convert data coordinates to screen coordinates
        const screenX = this.normalizeX(x, this.currentBounds)
        const screenY = this.normalizeY(y, this.currentBounds)
        
        // Create individual point graphics using the same pattern as the main rendering
        const point = new PIXI.Graphics()
        point.beginFill(color)
        point.alpha = alpha
        point.originalAlpha = alpha // Store original alpha for visibility updates
        point.drawCircle(0, 0, this.currentPointSize)
        point.endFill()
        point.x = screenX
        point.y = screenY
        
        // Store cell ID and mark as point for later reference
        point.cellId = i
        point.isPoint = true
        
        container.addChild(point)
      }
    })
  }

  // Render plot axes with labels
  renderAxes() {
    if (!this.axesContainer || !this.currentBounds || !this.pixiApp) {
      return
    }

    // Clear existing axes
    this.axesContainer.removeChildren()

    // Use current view bounds (which change with pan/zoom)
    const { minX, maxX, minY, maxY } = this.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height
    const margins = this.getPlotMargins()

    // Create axes graphics
    const axesGraphics = new PIXI.Graphics()
    axesGraphics.lineStyle(2, 0x333333, 0.8) // Dark gray lines

    // X-axis (horizontal line at bottom)
    const xAxisY = height - margins.bottom
    axesGraphics.moveTo(margins.left, xAxisY)
    axesGraphics.lineTo(width - margins.right, xAxisY)

    // Y-axis (vertical line at left)
    const yAxisX = margins.left
    axesGraphics.moveTo(yAxisX, margins.top)
    axesGraphics.lineTo(yAxisX, height - margins.bottom)

    // Add white rectangles to cover margin areas (below x-axis and left of y-axis)
    const marginGraphics = new PIXI.Graphics()
    marginGraphics.beginFill(0xffffff, 1.0) // White background
    
    // Rectangle below x-axis (covers bottom margin)
    marginGraphics.drawRect(0, xAxisY, width, height - xAxisY)
    
    // Rectangle left of y-axis (covers left margin)
    marginGraphics.drawRect(0, 0, yAxisX, height)
    
    marginGraphics.endFill()
    
    // Add margin rectangles first (behind axes)
    this.axesContainer.addChild(marginGraphics)
    
    // Add axes on top
    this.axesContainer.addChild(axesGraphics)

    // Add axis labels
    this.addAxisLabels(minX, maxX, minY, maxY, width, height)
  }

  // Add axis labels
  addAxisLabels(minX, maxX, minY, maxY, width, height) {
    const margins = this.getPlotMargins()
    
    // X-axis label (Dimension 1)
    const xLabel = new PIXI.Text('Dimension 1', {
      fontFamily: 'Arial, sans-serif',
      fontSize: 14,
      fill: 0x333333,
      align: 'center'
    })
    xLabel.x = width / 2
    xLabel.y = height - margins.bottom / 2
    xLabel.anchor.set(0.5, 0.5)
    this.axesContainer.addChild(xLabel)

    // Y-axis label (Dimension 2) - rotated 90 degrees
    const yLabel = new PIXI.Text('Dimension 2', {
      fontFamily: 'Arial, sans-serif',
      fontSize: 14,
      fill: 0x333333,
      align: 'center'
    })
    yLabel.x = margins.left / 2
    yLabel.y = height / 2
    yLabel.anchor.set(0.5, 0.5)
    yLabel.rotation = -Math.PI / 2 // Rotate 90 degrees counter-clockwise
    this.axesContainer.addChild(yLabel)

    // Add tick marks and values
    this.addTickMarks(minX, maxX, minY, maxY, width, height)
  }

  // Add tick marks and values
  addTickMarks(minX, maxX, minY, maxY, width, height) {
    const tickLength = 5
    const margins = this.getPlotMargins()
    const xAxisY = height - margins.bottom
    const yAxisX = margins.left

    // Calculate smart tick spacing based on zoom level
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)

    // X-axis ticks (bottom)
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let value = xStart; value <= xEnd; value += xTickSpacing) {
      const t = (value - minX) / (maxX - minX)
      const availableWidth = width - margins.left - margins.right
      const x = margins.left + t * availableWidth

      // Skip if outside visible area
      if (x < margins.left || x > width - margins.right) continue

      // Tick mark
      const tickGraphics = new PIXI.Graphics()
      tickGraphics.lineStyle(1, 0x666666, 0.6)
      tickGraphics.moveTo(x, xAxisY - tickLength)
      tickGraphics.lineTo(x, xAxisY + tickLength)
      this.axesContainer.addChild(tickGraphics)

      // Tick value
      const tickText = new PIXI.Text(this.formatTickValue(value), {
        fontFamily: 'Arial, sans-serif',
        fontSize: 10,
        fill: 0x666666,
        align: 'center'
      })
      tickText.x = x
      tickText.y = xAxisY + 15
      tickText.anchor.set(0.5, 0.5)
      this.axesContainer.addChild(tickText)
    }

    // Y-axis ticks (left) - inverted to match inverted Y-axis
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const t = (value - minY) / (maxY - minY)
      // Invert Y-axis tick positioning to match inverted Y-axis
      const availableHeight = height - margins.top - margins.bottom
      const y = margins.top + availableHeight - t * availableHeight

      // Skip if outside visible area
      if (y < margins.top || y > height - margins.bottom) continue

      // Tick mark
      const tickGraphics = new PIXI.Graphics()
      tickGraphics.lineStyle(1, 0x666666, 0.6)
      tickGraphics.moveTo(yAxisX - tickLength, y)
      tickGraphics.lineTo(yAxisX + tickLength, y)
      this.axesContainer.addChild(tickGraphics)

      // Tick value
      const tickText = new PIXI.Text(this.formatTickValue(value), {
        fontFamily: 'Arial, sans-serif',
        fontSize: 10,
        fill: 0x666666,
        align: 'center'
      })
      tickText.x = yAxisX - 15
      tickText.y = y
      tickText.anchor.set(0.5, 0.5)
      this.axesContainer.addChild(tickText)
    }
  }

  // Calculate smart tick spacing based on range
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

  // Format tick values nicely
  formatTickValue(value) {
    // If it's an integer, don't show decimals
    if (Number.isInteger(value)) {
      return value.toString()
    }
    
    // For non-integers, use appropriate precision and remove trailing zeros
    if (Math.abs(value) >= 100) {
      return value.toFixed(1).replace(/\.0$/, '')
    } else if (Math.abs(value) >= 10) {
      return value.toFixed(2).replace(/\.0+$/, '')
    } else if (Math.abs(value) >= 1) {
      return value.toFixed(3).replace(/\.0+$/, '')
    } else {
      return value.toFixed(4).replace(/\.0+$/, '')
    }
  }

  // Render grid lines aligned with tick marks
  renderGrid() {
    if (!this.gridContainer || !this.currentBounds || !this.pixiApp) {
      return
    }

    // Clear existing grid
    this.gridContainer.removeChildren()

    const { minX, maxX, minY, maxY } = this.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height
    const margins = this.getPlotMargins()

    // Calculate smart tick spacing (same as axes)
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)

    // Create grid graphics
    const gridGraphics = new PIXI.Graphics()
    gridGraphics.lineStyle(1, 0xcccccc, 0.3) // Light grey, semi-transparent

    // Vertical grid lines (aligned with X-axis ticks)
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let value = xStart; value <= xEnd; value += xTickSpacing) {
      const t = (value - minX) / (maxX - minX)
      const availableWidth = width - margins.left - margins.right
      const x = margins.left + t * availableWidth

      // Skip if outside visible area
      if (x < margins.left || x > width - margins.right) continue

      // Draw vertical line from top to bottom
      gridGraphics.moveTo(x, margins.top)
      gridGraphics.lineTo(x, height - margins.bottom)
    }

    // Horizontal grid lines (aligned with Y-axis ticks) - inverted to match inverted Y-axis
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const t = (value - minY) / (maxY - minY)
      const availableHeight = height - margins.top - margins.bottom
      const y = margins.top + availableHeight - t * availableHeight

      // Skip if outside visible area
      if (y < margins.top || y > height - margins.bottom) continue

      // Draw horizontal line from left to right
      gridGraphics.moveTo(margins.left, y)
      gridGraphics.lineTo(width - margins.right, y)
    }

    this.gridContainer.addChild(gridGraphics)
  }


  // Render category labels at centroids of colored groups
  renderCategoryLabels() {
    const renderStartTime = performance.now()
    
    // Debug: Track where this function is called from
    const stack = new Error().stack
    const caller = stack.split('\n')[2] || 'unknown'
    console.log(`🏷️ renderCategoryLabels called from:`, caller.trim())
    console.log(`🏷️ isPanning: ${this.isPanning}`)
    
    if (!this.categoryLabelsContainer || !this.currentBounds || !this.pixiApp || !this.currentMetadataVector || !this.currentCoordinates) {
      console.log('🏷️ Missing required components, returning early')
      return
    }

    // Only render labels for discrete metadata
    if (this.currentMetadataVector.data_type !== 'DISCRETE') {
      return
    }

    // During panning, don't update labels at all - let them stay in their original positions
    if (this.isPanning) {
      console.log(`🏷️ Skipping label updates during panning`)
      return
    }
    

    // Clear existing labels
    this.categoryLabelsContainer.removeChildren()

    const { minX, maxX, minY, maxY } = this.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height

    // Get the metadata values and categories
    const values = this.currentMetadataVector.values
    const categories = this.currentMetadataVector.categories
    
    // If categories is undefined, try to get unique values from the values array
    let categoryList = categories
    if (!categoryList || categoryList.length === 0) {
      categoryList = [...new Set(values)]
    }

    // Calculate centroids from currently visible points in the current view
    // This ensures labels follow the points correctly when panning/zooming
    const centroidStartTime = performance.now()
    console.log(`🏷️ Calculating centroids - isPanning: ${this.isPanning}, bounds:`, this.currentBounds)
    
    let centroids
    if (this.isPanning && this.storedCentroids) {
      // During panning, use stored centroids to avoid coordinate mismatch
      console.log(`🏷️ Using stored centroids during panning:`, this.storedCentroids)
      centroids = this.storedCentroids
    } else {
      // Normal calculation when not panning
      centroids = this.calculateCategoryCentroids(values, categoryList)
      // Store centroids for use during panning
      this.storedCentroids = centroids
      console.log(`🏷️ Stored centroids for future panning:`, this.storedCentroids)
    }
    
    // Note: We don't pre-calculate centroids for unselected categories
    // because centroids should only be calculated from visible points
    // When a category is re-selected, the points become visible and we can calculate centroids then
    
    const centroidEndTime = performance.now()

    this.categoryLabelsContainer.visible = false

    // Render labels for each category
    const labelCreationStartTime = performance.now()
    let labelsAdded = 0
    // First, process categories with visible points
    Object.entries(centroids).forEach(([category, centroid]) => {
      if (centroid.count > 0) { // Only show labels for categories with points
        // Check if this category is selected by looking at the checkbox state
        const categoryCheckbox = document.querySelector(`.category-checkbox[data-metadata-id="${this.currentMetadataVector.id}"][data-category="${category}"]`)
        const bgColor = categoryCheckbox ? categoryCheckbox.style.backgroundColor : ''
        // Check if NOT unselected (unselected is #f3f4f6 or rgb(243, 244, 246))
        const isCategorySelected = categoryCheckbox && bgColor !== '#f3f4f6' && bgColor !== 'rgb(243, 244, 246)'
        
        
        if (!isCategorySelected) {
          return // Skip rendering label for unselected categories
        }

        
        const screenX = this.normalizeX(centroid.x, this.currentBounds)
        const screenY = this.normalizeY(centroid.y, this.currentBounds)
        
        console.log(`🏷️ Label positioning for ${category}:`, {
          centroidData: { x: centroid.x, y: centroid.y, count: centroid.count },
          currentBounds: this.currentBounds,
          screenPosition: { x: screenX, y: screenY },
          isPanning: this.isPanning,
          storedCentroids: this.storedCentroids ? 'exists' : 'missing',
          screenWidth: this.pixiApp.screen.width,
          screenHeight: this.pixiApp.screen.height
        })

        // Skip if outside visible area (with some margin)
        const margins = this.getPlotMargins()
        const margin = Math.max(margins.left, margins.right, margins.top, margins.bottom)
        if (screenX < -margin || screenX > width + margin || screenY < -margin || screenY > height + margin) {
          return
        }

        // Create label with background
        let label
        try {
          label = this.createCategoryLabel(category, centroid.count)
        } catch (error) {
          console.error(`🏷️ Error creating label for ${category}:`, error)
          return
        }
        
        // Position the label at the centroid
        label.x = screenX
        label.y = screenY
        
        // Store original position for panning
        label.originalX = screenX
        label.originalY = screenY
        
        // Center the label by setting anchor on the text object inside the container
        if (label.children[1] && label.children[1].anchor) {
          label.children[1].anchor.set(0.5, 0.5)
        }

        this.categoryLabelsContainer.addChild(label)
        labelsAdded++
        
        // Debug: Check label position after creation
        console.log(`🏷️ Label ${category} created at position:`, { x: label.x, y: label.y, screenX, screenY })
        
      }
    })
    
    this.categoryLabelsContainer.visible = true

    // Update label interaction behavior for newly created labels
    this.updateLabelInteractionMode()

    const labelCreationEndTime = performance.now()
    
    const renderEndTime = performance.now()
    
    
  }

  // Calculate centroids for each category
  calculateCategoryCentroids(values, categories) {
    const calcStartTime = performance.now()
    
    if (!categories || !Array.isArray(categories)) {
      console.log('Categories is not a valid array, returning empty centroids')
      return {}
    }
    
    const centroids = {}
    
    // Initialize centroids
    categories.forEach(category => {
      centroids[category] = { x: 0, y: 0, count: 0 }
    })

    // Calculate centroids from actual visible points in the scatter container
    if (this.scatterContainer && this.scatterContainer.children) {
        let validPoints = 0

        // Always look for points in the nested container structure
        const pointsToCheck = []
        
        this.scatterContainer.children.forEach((child, index) => {
          //console.log(`Child ${index}: isPoint=${child.isPoint}, hasChildren=${!!child.children}, childrenCount=${child.children?.length || 0}`)
          
          if (child.isPoint) {
            // Individual point (shouldn't happen with new structure)
            pointsToCheck.push(child)
          } else if (child.children) {
            // Nested container - check its children (this is our standard structure)
            child.children.forEach((point) => {
              if (point.isPoint) {
                pointsToCheck.push(point)
              }
            })
          }
        })
        

        // Calculate centroids from visible points using currentCoordinates for accuracy
        const categoryCounts = {}
        let debugCount = 0
        pointsToCheck.forEach((point, index) => {
          if (point.visible && point.cellId !== undefined) {
            validPoints++
          const category = values[point.cellId]
          if (centroids[category]) {
            // Debug first few points to see their positions
            if (index < 3) {
              // Get world position instead of local position
              const worldPos = point.getGlobalPosition()
              console.log(`🏷️ Point ${index} (${category}):`, {
                localPosition: { x: point.x, y: point.y },
                worldPosition: { x: worldPos.x, y: worldPos.y },
                currentBounds: this.currentBounds,
                isPanning: this.isPanning,
                screenWidth: this.pixiApp.screen.width,
                screenHeight: this.pixiApp.screen.height
              })
            }
              // Use original data coordinates for accurate centroid calculation
              const coord = this.currentCoordinates[point.cellId]
              if (coord && coord.length >= 2) {
                centroids[category].x += coord[0]
                centroids[category].y += coord[1]
                centroids[category].count += 1
              } else {
                // Fallback to screen coordinate conversion (should not happen)
                console.warn(`No coordinate found for point ${point.cellId}`)
              }
              
              // Track category counts for debugging
              categoryCounts[category] = (categoryCounts[category] || 0) + 1
          }
        }
      })
        
    }

    // Calculate average coordinates (centroids)
    Object.keys(centroids).forEach(category => {
      if (centroids[category].count > 0) {
        centroids[category].x /= centroids[category].count
        centroids[category].y /= centroids[category].count
        console.log(`🏷️ Final centroid for ${category}:`, {
          count: centroids[category].count,
          x: centroids[category].x.toFixed(2),
          y: centroids[category].y.toFixed(2),
          isPanning: this.isPanning
        })
      }
    })

    const calcEndTime = performance.now()
    return centroids
  }


  // Create a category label with background
  createCategoryLabel(categoryName, count) {
    const container = new PIXI.Container()

    // Create text - try to fix the PIXI.js constructor issue
    let text
    try {
      // Try creating with explicit PIXI namespace
      text = new window.PIXI.Text(categoryName, {
        fontFamily: 'Arial, sans-serif',
        fontSize: 12,
        fill: 0x333333,
        align: 'center',
        fontWeight: 'bold'
      })
    } catch (error) {
      console.error('🏷️ Error creating PIXI.Text with window.PIXI:', error)
      try {
        // Fallback to direct PIXI reference
        text = new PIXI.Text(categoryName, {
          fontFamily: 'Arial, sans-serif',
          fontSize: 12,
          fill: 0x333333,
          align: 'center',
          fontWeight: 'bold'
        })
      } catch (error2) {
        console.error('🏷️ Error creating PIXI.Text with PIXI:', error2)
        // Last resort: create a simple container
        text = new PIXI.Container()
        text.text = categoryName
      }
    }
    
    
    // Get the category color for the border
    const rawCategories = this.currentMetadataVector.categories || [...new Set(this.currentMetadataVector.values)]
    const sortedCategories = this.getSortedCategories(this.currentMetadataVector.values, [...rawCategories])
    const categoryIndex = sortedCategories.indexOf(categoryName)
    const categoryColor = this.getCategoryColor(categoryName, categoryIndex, this.currentMetadataId)
    const borderColor = this.convertHexToPixiColor(categoryColor)

    // Create background rectangle
    const padding = 3
    let background
    try {
      background = new window.PIXI.Graphics()
      background.beginFill(0xffffff, 0.8)
      background.lineStyle(2, borderColor, 0.8)
      background.drawRoundedRect(
        -text.width / 2 - padding,
        -text.height / 2 - padding,
        text.width + padding * 2,
        text.height + padding * 2,
        3
      )
      background.endFill()
    } catch (error) {
      console.error('🏷️ Error creating PIXI.Graphics with window.PIXI:', error)
      try {
        background = new PIXI.Graphics()
        background.beginFill(0xffffff, 0.8)
        background.lineStyle(2, borderColor, 0.8)
        background.drawRoundedRect(
          -text.width / 2 - padding,
          -text.height / 2 - padding,
          text.width + padding * 2,
          text.height + padding * 2,
          3
        )
        background.endFill()
      } catch (error2) {
        console.error('🏷️ Error creating PIXI.Graphics with PIXI:', error2)
        background = new PIXI.Container()
      }
    }
    

    // Add background and text to container
    container.addChild(background)
    container.addChild(text)
    

    // Store the category name and border color for reference
    container.categoryName = categoryName
    container.borderColor = borderColor

    // Make the label interactive for dragging in pick mode
    container.interactive = true
    container.buttonMode = false
    container.cursor = 'default'

    return container
  }

  // Render continuous color legend for continuous metadata
  renderContinuousColorLegend() {
    const startTime = performance.now()
    console.log('🎨 Rendering continuous color legend')
    
    // Throttle legend updates to avoid redundant work
    const now = Date.now()
    if (this.lastLegendUpdate && now - this.lastLegendUpdate < 100) { // 100ms throttle
      console.log('🎨 Throttling legend update (too soon)')
      return
    }
    this.lastLegendUpdate = now
    
    if (!this.categoryLabelsContainer || !this.currentBounds || !this.pixiApp || !this.currentMetadataVector || !this.currentCoordinates) {
      console.log('🎨 Missing required components for continuous legend, returning early')
      return
    }

    // Only render legend for continuous metadata
    if (this.currentMetadataVector.data_type !== 'NUMERIC') {
      return
    }

    // During panning, don't update legend
    if (this.isPanning) {
      console.log('🎨 Skipping legend updates during panning')
      return
    }

    // Clear existing legend
    this.categoryLabelsContainer.removeChildren()

    const { minX, maxX, minY, maxY } = this.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height

    // Get metadata values and effective color range
    const values = this.currentMetadataVector.values
    const effectiveRange = this.getEffectiveColorRange()
    const minVal = effectiveRange.min
    const maxVal = effectiveRange.max

    // Create legend container
    const legendContainer = new PIXI.Container()
    
    // Legend dimensions
    const margins = this.getPlotMargins()
    const legendWidth = 200
    const legendHeight = 20
    const legendX = width - legendWidth - margins.right // Position on right side
    const legendY = margins.top // Position at top

    // Create color gradient bar
    const gradientBar = new PIXI.Graphics()
    const numSteps = 100
    
    for (let i = 0; i < numSteps; i++) {
      const normalizedValue = i / (numSteps - 1)
      const color = this.valueToColor(normalizedValue)
      
      const stepX = legendX + (i * legendWidth / numSteps)
      const stepWidth = legendWidth / numSteps
      
      gradientBar.beginFill(color)
      gradientBar.drawRect(stepX, legendY, stepWidth, legendHeight)
      gradientBar.endFill()
    }

    // Create border around gradient bar
    const border = new PIXI.Graphics()
    border.lineStyle(1, 0x333333, 1)
    border.drawRect(legendX, legendY, legendWidth, legendHeight)
    
    // Create min/max value labels
    const minLabel = this.createLegendLabel(minVal.toFixed(2), legendX, legendY + legendHeight + 5)
    const maxLabel = this.createLegendLabel(maxVal.toFixed(2), legendX + legendWidth, legendY + legendHeight + 5)
    
    // Center the max label
    if (maxLabel.children[1] && maxLabel.children[1].anchor) {
      maxLabel.children[1].anchor.set(1, 0) // Right-align
    }

    // Create metadata name label
    const nameLabel = this.createLegendLabel(this.currentMetadataVector.name, legendX, legendY - margins.top)
    if (nameLabel.children[1] && nameLabel.children[1].anchor) {
      nameLabel.children[1].anchor.set(0, 0.5) // Left-align
    }

    // Add all elements to legend container
    legendContainer.addChild(gradientBar)
    legendContainer.addChild(border)
    legendContainer.addChild(minLabel)
    legendContainer.addChild(maxLabel)
    legendContainer.addChild(nameLabel)

    // Add legend to the category labels container
    this.categoryLabelsContainer.addChild(legendContainer)
    this.categoryLabelsContainer.visible = true

    const totalTime = performance.now() - startTime
    console.log(`🎨 Continuous color legend rendered successfully in ${totalTime.toFixed(2)}ms`)
  }

  // Create a label for the continuous legend
  createLegendLabel(text, x, y) {
    const container = new PIXI.Container()

    // Create text
    let textObj
    try {
      textObj = new window.PIXI.Text(text, {
        fontFamily: 'Arial, sans-serif',
        fontSize: 10,
        fill: 0x333333,
        align: 'left'
      })
    } catch (error) {
      try {
        textObj = new PIXI.Text(text, {
          fontFamily: 'Arial, sans-serif',
          fontSize: 10,
          fill: 0x333333,
          align: 'left'
        })
      } catch (error2) {
        console.error('🎨 Error creating legend text:', error2)
        textObj = new PIXI.Container()
        textObj.text = text
      }
    }

    container.addChild(textObj)
    container.x = x
    container.y = y

    return container
  }

  // Get total count for a category (unfiltered)
  getTotalCountForCategory(categoryName) {
    if (!this.currentMetadataVector || !this.currentMetadataVector.values) {
      return 0
    }
    
    let count = 0
    for (let i = 0; i < this.currentMetadataVector.values.length; i++) {
      if (this.currentMetadataVector.values[i] === categoryName) {
        count++
      }
    }
    return count
  }


  // Update sidebar category counts with visual indicators
  updateSidebarCategoryCounts() {
    if (!this.currentMetadataVector || !this.currentMetadataVector.id) {
      return
    }

    const metadataId = this.currentMetadataVector.id
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    
    categoryCheckboxes.forEach(checkbox => {
      const category = checkbox.dataset.category
      
      // Find the count span - it's the second span in the parent container
      const parentContainer = checkbox.parentElement.parentElement
      const spans = parentContainer.querySelectorAll('span')
      const countSpan = spans[spans.length - 1] // Last span is the count
      
      if (countSpan) {
        // Get total count from the original data
        const totalCount = this.getTotalCountForCategory(category)
        
        // Get visible count (current count displayed)
        const visibleCount = this.getVisibleCountForCategory(category)
        
        // Update the count display
        countSpan.textContent = visibleCount.toLocaleString()
        
        // Add visual indicators
        if (totalCount > visibleCount) {
          // Some cells are filtered out - show in red
          countSpan.style.color = '#dc2626'
          countSpan.style.fontWeight = '600'
          
          // Add hover tooltip
          const percentage = ((visibleCount / totalCount) * 100).toFixed(1)
          countSpan.title = `${visibleCount.toLocaleString()} of ${totalCount.toLocaleString()} cells (${percentage}% selected)`
        } else {
          // No filtering - normal appearance
          countSpan.style.color = '#6b7280'
          countSpan.style.fontWeight = '500'
          countSpan.title = `${totalCount.toLocaleString()} cells (100% selected)`
        }
      }
    })
  }

  // Get visible count for a category (considering current filtering)
  getVisibleCountForCategory(categoryName) {
    if (!this.currentMetadataVector || !this.currentMetadataVector.values) {
      return 0
    }
    
    // If no filtering is applied, return total count
    if (!this.currentVisibleCells || this.currentVisibleCells.length === this.currentMetadataVector.values.length) {
      return this.getTotalCountForCategory(categoryName)
    }
    
    // Count visible cells for this category
    let visibleCount = 0
    for (let i = 0; i < this.currentVisibleCells.length; i++) {
      const cellIndex = this.currentVisibleCells[i]
      if (this.currentMetadataVector.values[cellIndex] === categoryName) {
        visibleCount++
      }
    }
    
    return visibleCount
  }

  // Update label interaction behavior based on current interaction mode
  updateLabelInteractionMode() {
    if (!this.categoryLabelsContainer || !this.pixiApp) return

    this.categoryLabelsContainer.children.forEach(label => {
      if (label.categoryName) { // Check if it's a category label
        if (this.interactionMode === 'pick') {
          label.cursor = 'move'
          // Add drag event handlers for pick mode
          label.on('pointerdown', (event) => {
            event.stopPropagation()
            this.clickingOnLabel = true
            this.draggingLabel = label
            label.alpha = 0.7
          })
        } else {
          label.cursor = 'default'
          // Reset any hover effects if not in pick mode
          label.scale.set(1.0)
          label.alpha = 1.0
          // Remove drag event handlers
          label.off('pointerdown')
        }
      }
    })
  }

  // Update control instructions based on current interaction mode
  updateControlInstructions() {
    const controlElement = document.getElementById('control-instructions')
    if (!controlElement) return

    let instructions = ''
    switch (this.interactionMode) {
      case 'pick':
        instructions = 'Click to pick a cell, click and drag to move a label, scroll to zoom'
        break
      case 'pan':
        instructions = 'Drag to pan • Scroll to zoom (mouse-centered)'
        break
      case 'lasso':
        instructions = 'Click and drag to select cells, scroll to zoom'
        break
      default:
        instructions = 'Click to pick a cell, click and drag to move a label, scroll to zoom'
    }
    
    controlElement.textContent = instructions
  }

  // Setup global drag handlers for label dragging
  setupGlobalDragHandlers() {
    if (!this.pixiApp || !this.pixiApp.stage) return

    // Remove existing global drag handlers if they exist
    if (this.globalDragHandlers) {
      this.pixiApp.stage.off('pointermove', this.globalDragHandlers.move)
      this.pixiApp.stage.off('pointerup', this.globalDragHandlers.up)
      this.pixiApp.stage.off('pointerupoutside', this.globalDragHandlers.upOutside)
    }

    // Create new global drag handlers
    this.globalDragHandlers = {
      move: (event) => {
        if (this.draggingLabel && this.interactionMode === 'pick') {
          const newPosition = event.data.getLocalPosition(this.draggingLabel.parent)
          this.draggingLabel.x = newPosition.x
          this.draggingLabel.y = newPosition.y
        }
      },
      up: (event) => {
        if (this.draggingLabel) {
          event.stopPropagation()
          this.draggingLabel.alpha = 1.0
          this.draggingLabel = null
        }
        this.clickingOnLabel = false
      },
      upOutside: (event) => {
        if (this.draggingLabel) {
          event.stopPropagation()
          this.draggingLabel.alpha = 1.0
          this.draggingLabel = null
        }
        this.clickingOnLabel = false
      }
    }

    // Add global event listeners
    this.pixiApp.stage.on('pointermove', this.globalDragHandlers.move)
    this.pixiApp.stage.on('pointerup', this.globalDragHandlers.up)
    this.pixiApp.stage.on('pointerupoutside', this.globalDragHandlers.upOutside)
  }

  // Convert hex color to PIXI color number
  convertHexToPixiColor(hexColor) {
    if (!hexColor) return 0xcccccc // Default grey if no color
    // Remove # if present and convert to number
    const hex = hexColor.replace('#', '')
    return parseInt(hex, 16)
  }

  updateLassoGraphics() {
    if (!this.lassoGraphics || this.lassoPoints.length < 2) return
    
    // Simplified rendering - just line, no fill
    this.lassoGraphics.clear()
    this.lassoGraphics.lineStyle(1, 0x3b82f6, 0.8) // Blue line
    this.lassoGraphics.beginFill(0x3b82f6, 0.1)
    this.lassoGraphics.moveTo(this.lassoPoints[0].x, this.lassoPoints[0].y)
    for (let i = 1; i < this.lassoPoints.length; i++) {
      this.lassoGraphics.lineTo(this.lassoPoints[i].x, this.lassoPoints[i].y)
    }
  }

  selectPointsInLasso() {
    if (!this.currentCoordinates || this.lassoPoints.length < 3) return
    
    //console.log(`Checking ${this.currentCoordinates.length} points against lasso selection`)
    
    const selectedIndices = []
    
    // Check points by their actual screen positions (after pan/zoom transformations)
    this.scatterContainer.children.forEach((child, index) => {
      if (child.isPoint && child.cellId !== undefined) {
        const screenX = child.x
        const screenY = child.y
      
      if (this.isPointInPolygon(screenX, screenY, this.lassoPoints)) {
          selectedIndices.push(child.cellId)
        }
      }
    })
    
    // Also check points in animatedContainer if they exist
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      this.animatedContainer.children.forEach((child, index) => {
        if (child.isPoint && child.cellId !== undefined) {
          const screenX = child.x
          const screenY = child.y
          
          if (this.isPointInPolygon(screenX, screenY, this.lassoPoints)) {
            selectedIndices.push(child.cellId)
          }
        }
      })
    }
    
    //console.log(`Selected ${selectedIndices.length} cells with lasso`)
    
    // Add to selected cells set
    selectedIndices.forEach(index => {
      this.selectedCells.add(index)
    })
    
    // Update selection count display
    this.updateSelectionCount()
    
    // Update colors of selected points without re-rendering (preserves pan/zoom state)
    this.updateSelectedPointColors()
  }

  // Update colors of selected points without re-rendering (preserves pan/zoom state)
  updateSelectedPointColors() {
    if (!this.scatterContainer) return
    
    //console.log('Updating selected point colors without re-rendering')
    
    // Update colors in scatterContainer
    this.scatterContainer.children.forEach((child) => {
      if (child.isPoint && child.cellId !== undefined) {
        if (this.selectedCells.has(child.cellId)) {
          // Set selected color (red) by clearing and redrawing
          child.clear()
          child.beginFill(0xff0000) // Pure red
          child.drawCircle(0, 0, this.currentPointSize) // Use current point size
          child.endFill()
        } else {
          // Restore original color
          const originalColor = this.originalPointColors.get(child.cellId)
          if (originalColor !== undefined) {
            child.clear()
            child.beginFill(originalColor)
            child.drawCircle(0, 0, this.currentPointSize) // Use current point size
            child.endFill()
          }
        }
      }
    })
    
    // Also update colors in animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      this.animatedContainer.children.forEach((child) => {
        if (child.isPoint && child.cellId !== undefined) {
          if (this.selectedCells.has(child.cellId)) {
            // Set selected color (red) by clearing and redrawing
            child.clear()
            child.beginFill(0xff0000) // Pure red
            child.drawCircle(0, 0, this.currentPointSize) // Use current point size
            child.endFill()
          } else {
            // Restore original color
            const originalColor = this.originalPointColors.get(child.cellId)
            if (originalColor !== undefined) {
              child.clear()
              child.beginFill(originalColor)
              child.drawCircle(0, 0, this.currentPointSize) // Use current point size
              child.endFill()
            }
          }
        }
      })
    }
  }

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

  clearLasso() {
    if (this.lassoGraphics) {
      this.scatterContainer.removeChild(this.lassoGraphics)
      this.lassoGraphics = null
    }
    this.lassoPoints = []
    this.isDrawingLasso = false
  }

  // Helper method to calculate distance between two points
  getDistance(point1, point2) {
    const dx = point2.x - point1.x
    const dy = point2.y - point1.y
    return Math.sqrt(dx * dx + dy * dy)
  }

  updateSelectionCount() {
    const countElement = document.getElementById('selected-cells-count')
    if (countElement) {
      countElement.textContent = this.selectedCells.size.toLocaleString()
    }
  }

  // Tab switching for selections panel
  switchSelectionTab(event) {
    const tab = event.currentTarget.dataset.tab
    //console.log('Switching to tab:', tab)
    
    // Update tab buttons
    const cellsTab = document.getElementById('cells-tab')
    const geneSetsTab = document.getElementById('gene-sets-tab')
    const cellsContent = document.getElementById('cells-tab-content')
    const geneSetsContent = document.getElementById('gene-sets-tab-content')
    
    if (tab === 'cells') {
      cellsTab.classList.add('border-blue-500', 'text-blue-600')
      cellsTab.classList.remove('border-transparent', 'text-gray-500')
      geneSetsTab.classList.remove('border-blue-500', 'text-blue-600')
      geneSetsTab.classList.add('border-transparent', 'text-gray-500')
      
      cellsContent.classList.remove('hidden')
      geneSetsContent.classList.add('hidden')
    } else if (tab === 'gene-sets') {
      geneSetsTab.classList.add('border-blue-500', 'text-blue-600')
      geneSetsTab.classList.remove('border-transparent', 'text-gray-500')
      cellsTab.classList.remove('border-blue-500', 'text-blue-600')
      cellsTab.classList.add('border-transparent', 'text-gray-500')
      
      geneSetsContent.classList.remove('hidden')
      cellsContent.classList.add('hidden')
    }
  }

  // Add all visible cells to selection
  addAllVisibleCells() {
    //console.log('Adding all visible cells to selection')
    
    // Get currently visible cells
    const visibleCells = this.currentVisibleCells || (this.currentCoordinates ? Array.from({length: this.currentCoordinates.length}, (_, i) => i) : [])
    
    if (visibleCells.length === 0) {
      console.log('No visible cells to select')
      return
    }
    
    // Add all visible cells to selection
    visibleCells.forEach(cellId => {
      this.selectedCells.add(cellId)
    })
    
    //(`Added ${visibleCells.length} visible cells to selection`)
    
    // Update the selection count display
    this.updateSelectedCellsCount()
    
    // Update point colors to show selection
    this.updateSelectedPointColors()
    
    // Update button state
    this.updateAddAllVisibleButtonState()
  }

  // Update the state of the "Add all visible cells" button
  updateAddAllVisibleButtonState() {
    const button = document.getElementById('add-all-visible-btn')
    if (!button) return
    
    const visibleCells = this.currentVisibleCells || (this.currentCoordinates ? Array.from({length: this.currentCoordinates.length}, (_, i) => i) : [])
    const allVisibleSelected = visibleCells.length > 0 && visibleCells.every(cellId => this.selectedCells.has(cellId))
    
    if (allVisibleSelected) {
      button.disabled = true
      button.style.backgroundColor = '#9ca3af'
      button.style.cursor = 'not-allowed'
      button.title = 'All visible cells are already selected'
    } else {
      button.disabled = false
      button.style.backgroundColor = '#10b981'
      button.style.cursor = 'pointer'
      button.title = 'Add all currently visible cells to selection'
    }
  }

  // Settings Window Methods
  toggleSettingsWindow() {
    const settingsWindow = document.getElementById('settings-window')
    if (!settingsWindow) return
    
    if (settingsWindow.style.display === 'none' || settingsWindow.style.display === '') {
      settingsWindow.style.display = 'block'
      this.initializeSettingsWindow()
    } else {
      settingsWindow.style.display = 'none'
    }
  }

  initializeSettingsWindow() {
    // Initialize point size slider value display
    const slider = document.getElementById('point-size-slider')
    const valueDisplay = document.getElementById('point-size-value')
    if (slider && valueDisplay) {
      // Set slider to current point size
      slider.value = this.currentPointSize
      valueDisplay.textContent = this.currentPointSize.toFixed(1)
      //console.log(`Settings window initialized with point size: ${this.currentPointSize}`)
      
      // Add direct event listener to ensure it works
      slider.addEventListener('input', (e) => {
        const newSize = parseFloat(e.target.value)
        valueDisplay.textContent = newSize.toFixed(1)
        //console.log(`Slider value changed to: ${newSize}`)
        
        // CRITICAL: Update this.currentPointSize so it persists across re-renders
        //console.log(`Direct listener updating currentPointSize: ${this.currentPointSize} -> ${newSize}`)
        this.currentPointSize = newSize
        
        this.updateAllPointSizes(newSize)
      })
    }
    
    // Add direct event listeners for checkboxes to ensure they work
    const axesCheckbox = document.getElementById('show-axes-checkbox')
    if (axesCheckbox) {
      //console.log('Adding event listener to axes checkbox')
      // Remove any existing listeners first
      axesCheckbox.removeEventListener('change', this.boundAxesToggle)
      // Create bound method for proper cleanup
      this.boundAxesToggle = (e) => {
        //console.log('Direct axes checkbox event listener triggered!')
        this.toggleAxes()
      }
      axesCheckbox.addEventListener('change', this.boundAxesToggle)
    } else {
      console.log('Axes checkbox not found during initialization!')
    }
    
    const gridCheckbox = document.getElementById('show-grid-checkbox')
    if (gridCheckbox) {
      gridCheckbox.addEventListener('change', (e) => {
        //console.log('Direct grid checkbox event listener triggered!')
        this.toggleGrid()
      })
    }
    
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')
    if (categoriesCheckbox) {
      categoriesCheckbox.addEventListener('change', (e) => {
        //console.log('Direct categories checkbox event listener triggered!')
        this.toggleCategories()
      })
    }
    
    // Update categories checkbox state based on current metadata
    this.updateCategoriesCheckboxState()
    
    // Make window draggable
    this.makeSettingsWindowDraggable()
  }

  makeSettingsWindowDraggable() {
    const settingsWindow = document.getElementById('settings-window')
    const header = document.getElementById('settings-header')
    if (!settingsWindow || !header) return
    
    let isDragging = false
    let startX, startY, startLeft, startTop
    
    const startDrag = (e) => {
      isDragging = true
      startX = e.clientX
      startY = e.clientY
      startLeft = parseInt(settingsWindow.style.left) || 0
      startTop = parseInt(settingsWindow.style.top) || 0
      settingsWindow.style.cursor = 'grabbing'
      e.preventDefault()
    }
    
    const doDrag = (e) => {
      if (!isDragging) return
      
      const deltaX = e.clientX - startX
      const deltaY = e.clientY - startY
      
      settingsWindow.style.left = (startLeft + deltaX) + 'px'
      settingsWindow.style.top = (startTop + deltaY) + 'px'
    }
    
    const stopDrag = () => {
      isDragging = false
      settingsWindow.style.cursor = 'move'
    }
    
    header.addEventListener('mousedown', startDrag)
    document.addEventListener('mousemove', doDrag)
    document.addEventListener('mouseup', stopDrag)
    
    // Close button functionality
    const closeBtn = document.getElementById('close-settings-btn')
    if (closeBtn) {
      closeBtn.addEventListener('click', () => {
        settingsWindow.style.display = 'none'
      })
    }
  }

  updatePointSize() {
    //console.log('Stimulus updatePointSize method called!')
    const slider = document.getElementById('point-size-slider')
    const valueDisplay = document.getElementById('point-size-value')
    if (!slider || !valueDisplay) {
      console.log('Slider or valueDisplay not found')
      return
    }
    
    const newSize = parseFloat(slider.value)
    valueDisplay.textContent = newSize.toFixed(1)
    
    // Store the new point size for future renders
    //console.log(`Stimulus updatePointSize: ${this.currentPointSize} -> ${newSize}`)
    this.currentPointSize = newSize
    
    //console.log(`Stimulus updating point size to: ${newSize}`)
    
    // Update all existing points
    this.updateAllPointSizes(newSize)
  }

  updateAllPointSizes(newSize) {
    if (!this.scatterContainer) {
      console.log('No scatterContainer found')
      return
    }
    
    let updatedCount = 0
    
    // Update points in scatterContainer
    this.scatterContainer.children.forEach((child) => {
      if (child.isPoint) {
        this.updatePointSize(child, newSize)
        updatedCount++
      }
    })
    
    // Update points in animatedContainer if it exists
    if (this.animatedContainer) {
      this.animatedContainer.children.forEach((child) => {
        if (child.isPoint) {
          this.updatePointSize(child, newSize)
          updatedCount++
        }
      })
    }
    
    //console.log(`Updated ${updatedCount} points to size ${newSize}`)
    //console.log(`ScatterContainer children: ${this.scatterContainer.children.length}`)
    //console.log(`AnimatedContainer children: ${this.animatedContainer ? this.animatedContainer.children.length : 'none'}`)
    
    // Debug first few points
    if (this.scatterContainer.children.length > 0) {
      const firstPoint = this.scatterContainer.children[0]
      /*console.log(`First point properties:`, {
        isPoint: firstPoint.isPoint,
        visible: firstPoint.visible,
        alpha: firstPoint.alpha,
        x: firstPoint.x,
        y: firstPoint.y,
        cellId: firstPoint.cellId
      })*/
    }
  }

  // Helper method to update a single point's size
  updatePointSize(point, newSize) {
    if (!point || !point.isPoint) return
    
    // Store the current position and properties
    const currentX = point.x
    const currentY = point.y
    const currentAlpha = point.alpha || 1.0
    
    // Get the current color from the current coloring scheme
    let currentColor = 0x3b82f6 // Default blue fallback
    
    if (point.cellId !== undefined) {
      // Use the current coloring scheme to get the correct color
      const { color } = this.getColorAndAlpha(point.cellId)
      currentColor = color
    }
    
    // Clear and redraw the circle with new size
    point.clear()
    point.beginFill(currentColor)
    point.alpha = currentAlpha
    point.drawCircle(0, 0, newSize)
    point.endFill()
    
    // Restore position
    point.x = currentX
    point.y = currentY
  }

  toggleAxes() {
    //console.log('toggleAxes method called!')
    const checkbox = document.getElementById('show-axes-checkbox')
    if (!checkbox) {
      console.log('Checkbox not found!')
      return
    }
    if (!this.axesContainer) {
      console.log('Axes container not found!')
      return
    }
    
    //console.log(`Toggling axes: ${checkbox.checked}`)
    //console.log(`Current axes visible: ${this.axesContainer.visible}`)
    
    // Recalculate bounds with/without axes margins BEFORE toggling visibility
    if (this.currentCoordinates) {
      const originalBounds = this.calculateBounds(this.currentCoordinates)
      //console.log('Original bounds:', originalBounds)
      
      // Temporarily set axes visibility to match checkbox state for bounds calculation
      const previousVisibility = this.axesContainer.visible
      this.axesContainer.visible = checkbox.checked
      
      const newBounds = this.getAdjustedBounds(originalBounds)
      //console.log('Adjusted bounds:', newBounds)
      this.currentBounds = newBounds
      
      // Restore the previous visibility state
      this.axesContainer.visible = previousVisibility
      
      // Re-render points with new bounds
      this.scatterContainer.removeChildren()
      this.renderPointsWithCurrentColoring()
      
      // Re-render category labels after axes toggle
      if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
        this.renderCategoryLabels()
      }
      
      // Now set the final axes visibility
      this.axesContainer.visible = checkbox.checked
      //console.log(`Final axes visible: ${this.axesContainer.visible}`)
      
      // Re-render axes
      this.renderAxes()
      //console.log('Axes toggle complete!')
    } else {
      console.log('No current coordinates found!')
    }
  }

  toggleGrid() {
    const checkbox = document.getElementById('show-grid-checkbox')
    if (!checkbox || !this.gridContainer) return
    
    //console.log(`Toggling grid: ${checkbox.checked}`)
    //console.log(`Current grid visible: ${this.gridContainer.visible}`)
    
    // Toggle grid visibility
    this.gridContainer.visible = checkbox.checked
    //console.log(`New grid visible: ${this.gridContainer.visible}`)
    
    // Re-render grid to ensure it's up to date
    this.renderGrid()
    //console.log('Grid toggle complete!')
  }

  toggleCategories() {
    const checkbox = document.getElementById('show-categories-checkbox')
    if (!checkbox) return
    
    //console.log(`Toggling categories: ${checkbox.checked}`)
    
    // Toggle category labels on the plot
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.visible = checkbox.checked
      //console.log(`Category labels visible: ${this.categoryLabelsContainer.visible}`)
      
      // If turning on, make sure labels are rendered
      if (checkbox.checked) {
        //console.log('Re-rendering category labels')
        this.renderCategoryLabels()
      }
    }
    
    // Find the categories container in the right panel
    const categoriesContainer = document.querySelector('.metadata-categories')
    if (categoriesContainer) {
      categoriesContainer.style.display = checkbox.checked ? 'block' : 'none'
    }
    
    //console.log('Categories toggle complete!')
  }

  updateCategoriesCheckboxState() {
    const checkbox = document.getElementById('show-categories-checkbox')
    if (!checkbox) return
    
    // Check if current metadata is discrete
    const isDiscreteMetadata = this.currentMetadataVector && this.currentMetadataVector.data_type === 'DISCRETE'
    
    if (isDiscreteMetadata) {
      checkbox.disabled = false
      checkbox.title = 'Toggle category legend visibility'
    } else {
      checkbox.disabled = true
      checkbox.checked = false
      checkbox.title = 'Categories only available for discrete metadata'
    }
  }

  // Save selection method
  saveSelection() {
    //console.log('Saving selection:', this.selectedCells.size, 'cells')
    
    if (this.selectedCells.size === 0) {
      alert('No cells selected to save')
      return
    }
    
    // Here you would typically save the selection to a backend or local storage
    // For now, we'll just show a success message
    const selectionName = prompt('Enter a name for this selection:')
    if (selectionName) {
      //console.log(`Selection "${selectionName}" saved with ${this.selectedCells.size} cells`)
      // TODO: Implement actual saving logic (API call, local storage, etc.)
      alert(`Selection "${selectionName}" saved successfully!`)
    }
  }

  // Save plot as SVG method
  saveAsSVG() {
    //console.log('Saving plot as SVG')
    
    if (!this.pixiApp || !this.scatterContainer) {
      alert('No plot available to save')
      return
    }

    try {
      // Get the canvas element
      const canvas = this.canvas || this.pixiApp.canvas
      if (!canvas) {
        alert('Canvas not found')
        return
      }

      // Create SVG content
      const svgContent = this.generateSVGFromPlot(canvas)
      
      // Create and download the SVG file
      this.downloadSVG(svgContent, 'plot.svg')
      
      //console.log('SVG saved successfully')
    } catch (error) {
      console.error('Error saving SVG:', error)
      alert('Error saving SVG file')
    }
  }

  // Generate SVG content from the current plot
  generateSVGFromPlot(canvas) {
    // Use the same dimensions as the actual plot
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height
    
    // Start SVG with proper dimensions
    let svg = `<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">`
    
    // Add background
    svg += `<rect width="100%" height="100%" fill="white"/>`
    
    // Add grid if visible
    if (this.gridContainer && this.gridContainer.visible) {
      svg += this.generateSVGGrid(width, height)
    }
    
    // Add axes if visible
    if (this.axesContainer && this.axesContainer.visible) {
      svg += this.generateSVGAxes(width, height)
    }
    
    // Add points from scatterContainer
    if (this.scatterContainer && this.scatterContainer.children) {
      this.scatterContainer.children.forEach((child) => {
        if (child.isPoint && child.cellId !== undefined) {
          const x = child.x
          const y = child.y
          
          // Get the current color and size
          const { color, size } = this.getPointColorAndSize(child)
          
          // Add circle for each point
          svg += `<circle cx="${x}" cy="${y}" r="${size}" fill="${color}"/>`
        }
      })
    }
    
    // Add points from animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children) {
      this.animatedContainer.children.forEach((child) => {
        if (child.isPoint && child.cellId !== undefined) {
          const x = child.x
          const y = child.y
          
          // Get the current color and size
          const { color, size } = this.getPointColorAndSize(child)
          
          // Add circle for each point
          svg += `<circle cx="${x}" cy="${y}" r="${size}" fill="${color}"/>`
        }
      })
    }
    
    // Add category labels if visible
    if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
      svg += this.generateSVGCategoryLabels()
    }
    
    // Add lasso graphics if it exists
    if (this.lassoGraphics && this.lassoPoints && this.lassoPoints.length > 0) {
      svg += `<polyline points="${this.lassoPoints.map(p => `${p.x},${p.y}`).join(' ')}" fill="none" stroke="#3b82f6" stroke-width="2" opacity="0.8"/>`
    }
    
    svg += `</svg>`
    return svg
  }

  // Convert hex color to RGB
  hexToRgb(hex) {
    if (!hex) {
      return '#cccccc' // Default grey if undefined/null
    }
    
    if (typeof hex === 'string' && hex.startsWith('#')) {
      return hex
    }
    
    // Convert number to hex string
    const hexStr = hex.toString(16).padStart(6, '0')
    return `#${hexStr}`
  }

  // Get point color and size for SVG export
  getPointColorAndSize(point) {
    let color = '#3b82f6' // Default blue
    let size = this.currentPointSize || 1
    
    // Check for selection coloring first
    if (this.selectedCells && this.selectedCells.has(point.cellId)) {
      color = '#ff0000' // Red for selected
    } else if (this.currentMetadataVector && this.currentMetadataVector.values) {
      // Use current metadata coloring
      const { color: metadataColor } = this.getColorAndAlpha(point.cellId)
      color = this.hexToRgb(metadataColor)
    } else if (this.originalPointColors && this.originalPointColors.has(point.cellId)) {
      const originalColor = this.originalPointColors.get(point.cellId)
      color = this.hexToRgb(originalColor)
    }
    
    return { color, size }
  }

  // Generate SVG grid
  generateSVGGrid(width, height) {
    if (!this.currentBounds) return ''
    
    let svg = ''
    const { minX, maxX, minY, maxY } = this.currentBounds
    const margins = this.getPlotMargins()
    
    // Use the same coordinate system as the actual plot
    const plotWidth = this.pixiApp.screen.width
    const plotHeight = this.pixiApp.screen.height
    
    // Calculate tick spacing for each axis
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    // Vertical grid lines
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let x = xStart; x <= xEnd; x += xTickSpacing) {
      const availableWidth = plotWidth - margins.left - margins.right
      const screenX = margins.left + ((x - minX) / (maxX - minX)) * availableWidth
      svg += `<line x1="${screenX}" y1="${margins.top}" x2="${screenX}" y2="${plotHeight - margins.bottom}" stroke="#e5e7eb" stroke-width="1" stroke-dasharray="2,2" opacity="0.6"/>`
    }
    
    // Horizontal grid lines - inverted to match inverted Y-axis
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let y = yStart; y <= yEnd; y += yTickSpacing) {
      const availableHeight = plotHeight - margins.top - margins.bottom
      const screenY = margins.top + availableHeight - ((y - minY) / (maxY - minY)) * availableHeight
      svg += `<line x1="${margins.left}" y1="${screenY}" x2="${plotWidth - margins.right}" y2="${screenY}" stroke="#e5e7eb" stroke-width="1" stroke-dasharray="2,2" opacity="0.6"/>`
    }
    
    return svg
  }

  // Generate SVG axes
  generateSVGAxes(width, height) {
    if (!this.currentBounds) return ''
    
    let svg = ''
    const { minX, maxX, minY, maxY } = this.currentBounds
    const margins = this.getPlotMargins()
    
    // Use the same coordinate system as the actual plot
    const plotWidth = this.pixiApp.screen.width
    const plotHeight = this.pixiApp.screen.height
    
    // X-axis (bottom)
    const xAxisY = plotHeight - margins.bottom
    svg += `<line x1="${margins.left}" y1="${xAxisY}" x2="${plotWidth - margins.right}" y2="${xAxisY}" stroke="#374151" stroke-width="2"/>`
    
    // Y-axis (left)
    const yAxisX = margins.left
    svg += `<line x1="${yAxisX}" y1="${margins.top}" x2="${yAxisX}" y2="${plotHeight - margins.bottom}" stroke="#374151" stroke-width="2"/>`
    
    // Axis labels
    svg += `<text x="${plotWidth/2}" y="${plotHeight - margins.bottom/2}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#374151">Dimension 1</text>`
    svg += `<text x="${margins.left/2}" y="${plotHeight/2}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#374151" transform="rotate(-90, ${margins.left/2}, ${plotHeight/2})">Dimension 2</text>`
    
    // Tick marks and values
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    // X-axis ticks
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let x = xStart; x <= xEnd; x += xTickSpacing) {
      const availableWidth = plotWidth - margins.left - margins.right
      const screenX = margins.left + ((x - minX) / (maxX - minX)) * availableWidth
      svg += `<line x1="${screenX}" y1="${xAxisY - 5}" x2="${screenX}" y2="${xAxisY + 5}" stroke="#374151" stroke-width="1"/>`
      svg += `<text x="${screenX}" y="${xAxisY + 15}" text-anchor="middle" font-family="Arial, sans-serif" font-size="10" fill="#6b7280">${this.formatTickValue(x)}</text>`
    }
    
    // Y-axis ticks - inverted to match inverted Y-axis
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let y = yStart; y <= yEnd; y += yTickSpacing) {
      const availableHeight = plotHeight - margins.top - margins.bottom
      const screenY = margins.top + availableHeight - ((y - minY) / (maxY - minY)) * availableHeight
      svg += `<line x1="${yAxisX - 5}" y1="${screenY}" x2="${yAxisX + 5}" y2="${screenY}" stroke="#374151" stroke-width="1"/>`
      svg += `<text x="${yAxisX - 10}" y="${screenY + 3}" text-anchor="end" font-family="Arial, sans-serif" font-size="10" fill="#6b7280">${this.formatTickValue(y)}</text>`
    }
    
    return svg
  }

  // Generate SVG category labels
  generateSVGCategoryLabels() {
    if (!this.categoryLabelsContainer || !this.currentMetadataVector || this.currentMetadataVector.data_type !== 'DISCRETE') {
      return ''
    }
    
    let svg = ''
    
    this.categoryLabelsContainer.children.forEach(label => {
      if (label.categoryName) {
        const x = label.x
        const y = label.y
        const text = label.categoryName
        
        // Get the text element to get dimensions
        const textElement = label.children[1] // Text is the second child
        if (textElement) {
          const textWidth = textElement.width || text.length * 7 // Approximate width
          const textHeight = textElement.height || 12
          const padding = 3
          
          // Get border color from stored property
          const borderColor = label.borderColor ? this.hexToRgb(label.borderColor) : '#cccccc'
          
          // Background rectangle
          svg += `<rect x="${x - textWidth/2 - padding}" y="${y - textHeight/2 - padding}" width="${textWidth + padding*2}" height="${textHeight + padding*2}" fill="white" fill-opacity="0.8" stroke="${borderColor}" stroke-width="2" rx="3"/>`
          
          // Text
          svg += `<text x="${x}" y="${y + 3}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" font-weight="bold" fill="#333333">${text}</text>`
        }
      }
    })
    
    return svg
  }

  // Download SVG content as file
  downloadSVG(svgContent, filename) {
    const blob = new Blob([svgContent], { type: 'image/svg+xml' })
    const url = URL.createObjectURL(blob)
    
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    
    // Clean up the URL object
    URL.revokeObjectURL(url)
  }

  // Cancel selection method - resets points to original colors
  cancelSelection() {
    console.log('🔄 Canceling selection, reverting to previous coloring scheme')
    
    // Clear the selected cells
    this.selectedCells.clear()
    
    // Revert to the previous coloring scheme if there was one
    if (this.currentMetadataId && this.currentMetadataVector) {
      //console.log(`Reverting to metadata coloring: ${this.currentMetadataVector.name}`)
      // Re-render with the current metadata coloring
      this.renderPointsWithCurrentColoring()
      
      // Re-render category labels after reverting to metadata coloring
      if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
        this.renderCategoryLabels()
      }
    } else {
      console.log('No metadata coloring active, using default colors')
      // Update colors without re-rendering (preserves pan/zoom state)
      this.updateSelectedPointColors()
    }
    
    // Update the cell count display
    this.updateSelectedCellsCount()
    
    // Clear any lasso graphics
    if (this.lassoGraphics) {
      this.lassoGraphics.clear()
      this.lassoGraphics = null
    }
    
    //console.log('Selection canceled, reverted to previous coloring scheme')
  }


  // Store original colors when points are first rendered
  storeOriginalPointColor(cellId, color) {
    if (!this.originalPointColors.has(cellId)) {
      this.originalPointColors.set(cellId, color)
    }
  }

  // Update the selected cells count display
  updateSelectedCellsCount() {
    const countElement = document.getElementById('selected-cells-count')
    //console.log(`updateSelectedCellsCount called - countElement found:`, !!countElement)
    
    if (countElement) {
      const selectionCount = this.selectedCells ? this.selectedCells.size : 0
      const totalVisible = this.currentVisibleCells ? this.currentVisibleCells.length : (this.currentCoordinates?.length || 0)
      
      //console.log(`Selection count: ${selectionCount}, Total visible: ${totalVisible}`)
      
      if (selectionCount === 0) {
        countElement.textContent = '0'
        countElement.title = 'No cells selected'
        //console.log(`Updated display to: 0 cells selected`)
      } else if (this.currentVisibleCells && this.currentVisibleCells.length < (this.currentCoordinates?.length || 0)) {
        // Filtering is applied
        const percentage = totalVisible > 0 ? ((selectionCount / totalVisible) * 100).toFixed(1) : 0
        countElement.textContent = selectionCount.toLocaleString()
        countElement.title = `${selectionCount.toLocaleString()} cells selected (${percentage}% of visible cells)`
        //console.log(`Updated display to: ${selectionCount} cells selected (${percentage}% of visible cells)`)
      } else {
        // No filtering applied
        const percentage = totalVisible > 0 ? ((selectionCount / totalVisible) * 100).toFixed(1) : 0
        countElement.textContent = selectionCount.toLocaleString()
        countElement.title = `${selectionCount.toLocaleString()} cells selected (${percentage}% of total cells)`
        //console.log(`Updated display to: ${selectionCount} cells selected (${percentage}% of total cells)`)
      }
    } else {
      console.log(`selected-cells-count element not found!`)
    }
    
    // Update the "Add all visible cells" button state
    this.updateAddAllVisibleButtonState()
  }

  // Tooltip methods
  showTooltip(cellId, point) {
    
    // Force create tooltip if not available
    if (!this.tooltip || !this.tooltipContent) {
      console.log('Tooltip elements not found, creating now:', { 
        tooltip: !!this.tooltip, 
        tooltipContent: !!this.tooltipContent 
      })
      this.createTooltipDynamically()
    }
    
    // Double-check after creation
    if (!this.tooltip || !this.tooltipContent) {
      console.log('Failed to create tooltip elements')
      return
    }
    
    // Get cell information
    const cellName = `Cell ${cellId + 1}` // Generate cell name from ID
    
    // Get category information if available
    let categoryInfo = ''
    if (this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[cellId] !== undefined) {
      const { data_type, values } = this.currentMetadataVector
      const value = values[cellId]
      
      if (data_type === 'DISCRETE') {
        // For discrete metadata, show the category name
        categoryInfo = `<br><strong>Category:</strong> ${value}`
      } else if (data_type === 'NUMERIC') {
        // For continuous metadata, show the numeric value
        categoryInfo = `<br><strong>Value:</strong> ${value.toFixed(3)}`
      }
    }
    
    // Set tooltip content
    const tooltipHTML = `<strong>${cellName}</strong>${categoryInfo}`
    this.tooltipContent.innerHTML = tooltipHTML
    // Tooltip content set
    
    // Position tooltip near the mouse cursor
    const plotContainer = document.querySelector('.plot-container')
    if (!plotContainer) {
      console.log('Plot container not found')
      return
    }
    
    const rect = plotContainer.getBoundingClientRect()
    // Plot container positioned
    
    // Get point position in screen coordinates
    const pointX = point.x + rect.left
    const pointY = point.y + rect.top
    
    // Position tooltip to the right of the point, with some offset
    let tooltipLeft = pointX + 15
    let tooltipTop = pointY - 10
    
    // Ensure tooltip stays within the plot container bounds
    const tooltipWidth = 200 // max-width from CSS
    const tooltipHeight = 50 // estimated height
    
    // Check if tooltip would go off the right edge
    if (tooltipLeft + tooltipWidth > rect.right) {
      tooltipLeft = pointX - tooltipWidth - 15 // Position to the left instead
    }
    
    // Check if tooltip would go off the bottom edge
    if (tooltipTop + tooltipHeight > rect.bottom) {
      tooltipTop = pointY - tooltipHeight - 10 // Position above instead
    }
    
    // Check if tooltip would go off the top edge
    if (tooltipTop < rect.top) {
      tooltipTop = rect.top + 10 // Keep it within bounds
    }
    
    this.tooltip.style.left = `${tooltipLeft}px`
    this.tooltip.style.top = `${tooltipTop}px`
    this.tooltip.style.display = 'block'
    
    // Temporarily make tooltip more visible for debugging
    this.tooltip.style.backgroundColor = 'red'
    this.tooltip.style.fontSize = '16px'
    this.tooltip.style.padding = '12px 16px'
    
    // Tooltip positioned
    
    // Debug: Check if tooltip is actually visible
    const computedStyle = window.getComputedStyle(this.tooltip)
    // Tooltip style computed
    
    // Force tooltip to be visible with maximum z-index
    this.tooltip.style.zIndex = '999999'
    this.tooltip.style.position = 'fixed'
    this.tooltip.style.visibility = 'visible'
    this.tooltip.style.opacity = '1'
    
    // Test: Position tooltip in a fixed, visible location
    this.tooltip.style.left = '50px'
    this.tooltip.style.top = '50px'
    this.tooltip.style.backgroundColor = 'red'
    this.tooltip.style.border = '3px solid yellow'
    this.tooltip.style.width = '300px'
    this.tooltip.style.height = '100px'
    
    // Tooltip forced to fixed position
  }

  hideTooltip() {
    if (this.tooltip) {
      this.tooltip.style.display = 'none'
    }
  }

  showSimpleTooltip(cellName, categoryInfo, point) {
    // Simple tooltip shown
    
    // Remove any existing simple tooltip
    const existing = document.getElementById('simple-tooltip')
    if (existing) {
      existing.remove()
    }
    
    // Get plot container for positioning
    const plotContainer = document.querySelector('.plot-container')
    const rect = plotContainer ? plotContainer.getBoundingClientRect() : { left: 0, top: 0, width: 600, height: 400 }
    
    // Position tooltip above the plot, centered horizontally
    const margins = this.getPlotMargins()
    const tooltipLeft = rect.left + (rect.width / 2) - 100 // Center horizontally, offset for tooltip width
    const tooltipTop = rect.top - margins.top - 20 // Above the plot with margin
    
    // Create tooltip container
    const tooltip = document.createElement('div')
    tooltip.id = 'simple-tooltip'
    tooltip.style.cssText = `
      position: fixed !important;
      top: ${tooltipTop}px !important;
      left: ${tooltipLeft}px !important;
      background: rgba(0, 0, 0, 0.9) !important;
      color: white !important;
      padding: 12px 16px !important;
      font-size: 14px !important;
      font-weight: normal !important;
      border: 1px solid rgba(255, 255, 255, 0.2) !important;
      border-radius: 6px !important;
      z-index: 9999999 !important;
      display: block !important;
      visibility: visible !important;
      opacity: 1 !important;
      pointer-events: auto !important;
      box-shadow: 0 4px 12px rgba(0,0,0,0.3) !important;
      min-width: 200px !important;
      max-width: 300px !important;
    `
    
    // Create close button
    const closeButton = document.createElement('button')
    closeButton.innerHTML = '×'
    closeButton.style.cssText = `
      position: absolute !important;
      top: 4px !important;
      right: 8px !important;
      background: none !important;
      border: none !important;
      color: white !important;
      font-size: 18px !important;
      font-weight: bold !important;
      cursor: pointer !important;
      padding: 0 !important;
      width: 20px !important;
      height: 20px !important;
      line-height: 1 !important;
    `
    closeButton.onclick = () => {
      tooltip.remove()
      console.log('🗑️ Tooltip closed by user')
    }
    
    // Create content
    const content = document.createElement('div')
    content.style.cssText = `
      padding-right: 25px !important;
      line-height: 1.4 !important;
    `
    
    // Add cell name
    const cellNameDiv = document.createElement('div')
    cellNameDiv.style.cssText = `
      font-weight: 600 !important;
      margin-bottom: 4px !important;
    `
    cellNameDiv.textContent = cellName
    
    // Add category info if available
    if (categoryInfo) {
      const categoryDiv = document.createElement('div')
      categoryDiv.style.cssText = `
        font-size: 12px !important;
        color: #e5e7eb !important;
        margin-top: 2px !important;
      `
      categoryDiv.textContent = categoryInfo.replace('\n', '')
      content.appendChild(cellNameDiv)
      content.appendChild(categoryDiv)
    } else {
      content.appendChild(cellNameDiv)
    }
    
    // Assemble tooltip
    tooltip.appendChild(content)
    tooltip.appendChild(closeButton)
    document.body.appendChild(tooltip)
    
    // Improved tooltip created and positioned
  }

  // Pick mode methods
  onPickMouseDown(event) {
    // In pick mode, use fallback detection to find clicked points
    // But don't detect points if we're clicking on a label
    if (this.clickingOnLabel) {
      return
    }
    
    // Safety check for PIXI app and scatterContainer
    if (!this.pixiApp || !this.scatterContainer) {
      console.log('PIXI app or scatterContainer not available for point detection')
      return
    }
    
    // Pick mode: Canvas clicked
    this.detectPointClick(event)
  }

  onPointClick(cellId, point, event) {
    // Only show tooltip in pick mode
    if (this.interactionMode === 'pick') {
      // Point clicked in pick mode
      
      // Simple test - show alert first
      //alert(`Cell ${cellId + 1} clicked!`)
      
      this.showTooltip(cellId, point)
      event.stopPropagation() // Prevent canvas click event
    }
  }

  // Fallback method to detect point clicks when PIXI events don't work
  detectPointClick(event) {
    if (this.interactionMode !== 'pick') return

    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return

    // Safety check for scatterContainer
    if (!this.scatterContainer || !this.scatterContainer.children) {
      console.log('ScatterContainer not available for point detection')
      return
    }

    const rect = canvas.getBoundingClientRect()
    const clickX = event.clientX - rect.left
    const clickY = event.clientY - rect.top

    //console.log('Detecting point click at:', { clickX, clickY })
    //console.log('ScatterContainer children count:', this.scatterContainer.children.length)

    // Check all points in scatterContainer
    let closestPoint = null
    let closestDistance = Infinity
    const maxDistance = 5 // Maximum distance to consider a click

    this.scatterContainer.children.forEach((child, index) => {
      if (index < 3) { // Debug first 3 children
        console.log(`Child ${index}:`, { 
          isPoint: child.isPoint, 
          cellId: child.cellId, 
          x: child.x, 
          y: child.y 
        })
      }
      if (child.isPoint && child.cellId !== undefined) {
        const distance = Math.sqrt(
          Math.pow(child.x - clickX, 2) + Math.pow(child.y - clickY, 2)
        )
        
        if (distance < maxDistance && distance < closestDistance) {
          closestDistance = distance
          closestPoint = child
        }
      }
    })

    // Also check animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      this.animatedContainer.children.forEach((child) => {
        if (child.isPoint && child.cellId !== undefined) {
          const distance = Math.sqrt(
            Math.pow(child.x - clickX, 2) + Math.pow(child.y - clickY, 2)
          )
          
          if (distance < maxDistance && distance < closestDistance) {
            closestDistance = distance
            closestPoint = child
          }
        }
      })
    }

    if (closestPoint) {
      // Closest point found
      
      // Simple test - show alert with category info
      const cellName = `Cell ${closestPoint.cellId + 1}`
      let categoryInfo = ''
      if (this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[closestPoint.cellId] !== undefined) {
        const { data_type, values } = this.currentMetadataVector
        const value = values[closestPoint.cellId]
        
        if (data_type === 'DISCRETE') {
          categoryInfo = `\nCategory: ${value}`
        } else if (data_type === 'NUMERIC') {
          categoryInfo = `\nValue: ${value.toFixed(3)}`
        }
      }
      
      // Show tooltip
      this.showSimpleTooltip(cellName, categoryInfo, closestPoint)
    } else {
      console.log('No point found near click position')
      this.hideTooltip()
    }
  }

  // Checkbox functionality for cell selection
  toggleMetadataSelection(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const checkbox = event.currentTarget
    const isSelected = checkbox.style.backgroundColor === 'rgb(16, 185, 129)' // #10b981
    
    // Toggle the checkbox state
    if (isSelected) {
      // Deselect all categories for this metadata
      checkbox.style.backgroundColor = '#f3f4f6'
      checkbox.querySelector('i').style.display = 'none'
      this.deselectAllCategoriesForMetadata(metadataId)
    } else {
      // Select all categories for this metadata
      checkbox.style.backgroundColor = '#10b981'
      checkbox.querySelector('i').style.display = 'block'
      this.selectAllCategoriesForMetadata(metadataId)
    }
    
    // Update cell filtering
    this.updateCellFiltering()
  }

  toggleCategorySelection(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const category = event.currentTarget.dataset.category
    const checkbox = event.currentTarget
    const isSelected = checkbox.style.backgroundColor === 'rgb(16, 185, 129)' // #10b981
    
    console.log(`🔄 Toggle category selection: ${category}, isSelected: ${isSelected}`)
    
    // Initialize checkboxes for this metadata if not already done (only for discrete)
    const metadataVector = this.getMetadataVectorById(metadataId)
    if (metadataVector?.data_type === 'DISCRETE' && !this.selectedCategories[metadataId]) {
      this.initializeCheckboxesForMetadata(metadataId)
    }
    
    // Toggle the checkbox state
    if (isSelected) {
      // Deselect this category
      checkbox.style.backgroundColor = '#f3f4f6'
      checkbox.querySelector('i').style.display = 'none'
      this.deselectCategory(metadataId, category)
    } else {
      // Select this category
      checkbox.style.backgroundColor = '#10b981'
      checkbox.querySelector('i').style.display = 'block'
      this.selectCategory(metadataId, category)
    }
    
    // Update the metadata checkbox state
    this.updateMetadataCheckboxState(metadataId)
    
    // Update cell filtering
    console.log(`🔄 About to call updateCellFiltering`)
    console.log(`🔄 Labels before updateCellFiltering:`, this.categoryLabelsContainer.children.length)
    this.updateCellFiltering()
    console.log(`🔄 updateCellFiltering completed`)
    console.log(`🔄 Labels after updateCellFiltering:`, this.categoryLabelsContainer.children.length)
    
    // Re-render category labels to reflect selection changes
    // Use requestAnimationFrame to ensure points are visible before calculating centroids
    requestAnimationFrame(() => {
      console.log(`🔄 Checking category labels container:`, {
        exists: !!this.categoryLabelsContainer,
        visible: this.categoryLabelsContainer?.visible,
        children: this.categoryLabelsContainer?.children?.length
      })
      
      if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
        console.log(`🔄 Re-rendering labels after category selection change`)
        console.log(`🔄 Current metadata vector:`, this.currentMetadataVector?.id, this.currentMetadataVector?.type)
        console.log(`🔄 Current bounds:`, this.currentBounds)
        console.log(`🔄 Current coordinates:`, this.currentCoordinates?.length)
        try {
          this.renderCategoryLabels()
          console.log(`🔄 renderCategoryLabels completed successfully`)
        } catch (error) {
          console.error(`🔄 Error in renderCategoryLabels:`, error)
        }
      } else {
        console.log(`🔄 Category labels container not visible, skipping label re-render`)
      }
    })
    
    console.log(`🔄 toggleCategorySelection function completed`)
  }

  selectAllCategoriesForMetadata(metadataId) {
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = '#10b981'
      checkbox.querySelector('i').style.display = 'block'
      const category = checkbox.dataset.category
      this.selectCategory(metadataId, category)
    })
    
    // Re-render category labels to reflect selection changes
    if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
      this.renderCategoryLabels()
    }
  }

  deselectAllCategoriesForMetadata(metadataId) {
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = '#f3f4f6'
      checkbox.querySelector('i').style.display = 'none'
      const category = checkbox.dataset.category
      this.deselectCategory(metadataId, category)
    })
    
    // Re-render category labels to reflect selection changes
    if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
      this.renderCategoryLabels()
    }
  }

  selectCategory(metadataId, category) {
    // This will be used to track selected categories
    if (!this.selectedCategories) {
      this.selectedCategories = {}
    }
    if (!this.selectedCategories[metadataId]) {
      this.selectedCategories[metadataId] = new Set()
    }
    this.selectedCategories[metadataId].add(category)
  }

  deselectCategory(metadataId, category) {
    if (this.selectedCategories && this.selectedCategories[metadataId]) {
      this.selectedCategories[metadataId].delete(category)
    }
  }


  updateMetadataCheckboxState(metadataId) {
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    const selectedCount = Array.from(categoryCheckboxes).filter(cb => 
      cb.style.backgroundColor === 'rgb(16, 185, 129)'
    ).length
    
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    
    if (selectedCount === 0) {
      // No categories selected
      metadataCheckbox.style.backgroundColor = '#f3f4f6'
      metadataCheckbox.querySelector('i').style.display = 'none'
    } else if (selectedCount === categoryCheckboxes.length) {
      // All categories selected
      metadataCheckbox.style.backgroundColor = '#10b981'
      metadataCheckbox.querySelector('i').style.display = 'block'
    } else {
      // Some categories selected (indeterminate state)
      metadataCheckbox.style.backgroundColor = '#f59e0b'
      metadataCheckbox.querySelector('i').style.display = 'block'
    }
  }

  initializeAllCheckboxes() {
    // Initialize checkboxes only for the currently loaded metadata
    const metadataId = this.currentMetadataId
    if (!metadataId) {
      console.log('⚠️ No current metadata ID - skipping checkbox initialization')
      return
    }

    this.initializeCheckboxesForMetadata(metadataId)
  }

  initializeCheckboxesForMetadata(metadataId) {
    //console.log(`Initializing checkboxes for metadata: ${metadataId}`)
    
    // Only initialize for discrete metadata
    const metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector || metadataVector.data_type !== 'DISCRETE') {
      console.log(`Skipping checkbox initialization for non-discrete metadata: ${metadataId}`)
      return
    }
    
    // Initialize the selected categories for this metadata
    this.selectedCategories[metadataId] = new Set()
    
    // Get all categories for this metadata
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(categoryCheckbox => {
      const category = categoryCheckbox.dataset.category
      this.selectedCategories[metadataId].add(category)
    })
    
    //console.log(`Initialized checkboxes for metadata ${metadataId}:`, Array.from(this.selectedCategories[metadataId]))
    
    // Update point count display after initializing checkboxes
    this.updateCellFiltering()
  }

  showCheckboxesForMetadata(metadataId) {
    //console.log(`Showing checkboxes for metadata: ${metadataId}`)
    
    // Show the global metadata checkbox
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    if (metadataCheckbox) {
      metadataCheckbox.style.display = 'flex'
    }
    
    // Show all category checkboxes for this metadata
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.display = 'flex'
    })
    
    //console.log(`Showed ${categoryCheckboxes.length} category checkboxes for metadata ${metadataId}`)
  }

  // Optimized method to show/hide points without re-rendering
  updatePointVisibility(filteredIndices) {
    if (!this.scatterContainer || !this.scatterContainer.children) {
      console.log('No scatter container or children - cannot update visibility')
      return
    }

    const startTime = performance.now()
    let visibleCount = 0
    let hiddenCount = 0

    // Convert filteredIndices to Set for O(1) lookup if it exists
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null

    let pointCount = 0
    
    // Helper function to update points in a container
    const updatePointsInContainer = (container, containerName) => {
      container.children.forEach((point) => {
        if (point.isPoint) {
          pointCount++
          // Use the cellId property instead of array index
          const shouldBeVisible = !filteredSet || filteredSet.has(point.cellId)
          
          if (shouldBeVisible) {
            point.visible = true
            point.alpha = point.originalAlpha || 1.0 // Restore original alpha
            visibleCount++
          } else {
            point.visible = false
            hiddenCount++
          }
        }
      })
    }
    
    // Update points in scatterContainer (direct children)
    updatePointsInContainer(this.scatterContainer, 'Direct')
    
    // Also check for points in animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      updatePointsInContainer(this.animatedContainer, 'Animated')
    }
    
    // Check for nested containers (our standard structure)
    this.scatterContainer.children.forEach((child) => {
      if (child.children && child.children.length > 1000 && !child.isPoint) {
        // This is likely our main points container, update its children
        updatePointsInContainer(child, 'Nested')
      }
    })

    const endTime = performance.now()
    //console.log(`Visibility update: ${visibleCount} visible, ${hiddenCount} hidden (${pointCount} total points)`)
  }

  // Update the point count display with detailed filtering information
  updatePointCountDisplay(filteredIndices) {
    const pointCountElement = document.getElementById('point-count')
    if (!pointCountElement) return

    const totalPoints = this.currentCoordinates?.length || 0
    
    // Handle undefined or null filteredIndices
    if (!filteredIndices || filteredIndices === undefined) {
      // No filtering applied - show total points
      pointCountElement.textContent = `${totalPoints.toLocaleString()} points`
      pointCountElement.title = 'All points visible (no filtering applied)'
      pointCountElement.style.color = '' // Reset to default
      pointCountElement.style.fontWeight = ''
    } else {
      // Filtering applied - show filtered count and percentage
      const filteredCount = filteredIndices.length || 0
      const percentage = totalPoints > 0 ? ((filteredCount / totalPoints) * 100).toFixed(1) : 0
      const filteringSummary = this.getFilteringSummary()
      
      pointCountElement.textContent = `${filteredCount.toLocaleString()} points`
      
      // Create detailed tooltip
      let tooltip = `${filteredCount.toLocaleString()} of ${totalPoints.toLocaleString()} points visible (${percentage}%)`
      if (filteringSummary) {
        tooltip += `\n\nActive filters: ${filteringSummary}`
      }
      pointCountElement.title = tooltip
      
      // Add visual indicator if filtering is applied
      if (filteredCount < totalPoints) {
        pointCountElement.style.color = '#f59e0b' // Orange to indicate filtering
        pointCountElement.style.fontWeight = '600'
      } else {
        pointCountElement.style.color = '' // Reset to default
        pointCountElement.style.fontWeight = ''
      }
    }

    // Ensure the plot info panel is visible
    this.showPlotInfoPanel()
  }

  // Show the plot info panel
  showPlotInfoPanel() {
    const plotInfo = document.getElementById('plot-info')
    if (plotInfo) {
      plotInfo.style.display = 'block'
    }
  }

  // Get a summary of current filtering constraints
  getFilteringSummary() {
    if (!this.selectedCategories || Object.keys(this.selectedCategories).length === 0) {
      return null
    }

    const summary = []
    Object.keys(this.selectedCategories).forEach(metadataId => {
      const selections = this.selectedCategories[metadataId]
      if (selections && selections.size > 0) {
        const metadataVector = this.getMetadataVectorById(metadataId)
        if (metadataVector) {
          const metadataName = metadataVector.name
          const selectedCategories = Array.from(selections)
          summary.push(`${metadataName}: ${selectedCategories.length} categories`)
        }
      }
    })

    return summary.length > 0 ? summary.join(' • ') : null
  }

  updateCellFiltering() {
    // Use incremental filtering for better performance
    const filteredIndices = this.getIncrementalFilteredIndices()
    //console.log('Filtered indices result:', filteredIndices ? `${filteredIndices.length} cells` : 'null (no filtering)')
    
    // Update the current visible cells state
    this.currentVisibleCells = filteredIndices
    
    // Update current selection to only include visible cells
    this.updateSelectionBasedOnFiltering(filteredIndices)
    
    // Update point count display immediately
    this.updatePointCountDisplay(filteredIndices)
    
    // Update sidebar category counts with visual indicators
    this.updateSidebarCategoryCounts()
    
    // Update button state after filtering
    this.updateAddAllVisibleButtonState()
    
    // Use requestAnimationFrame for smooth updates
    requestAnimationFrame(() => {
      this.updatePointVisibility(filteredIndices)
    })
  }

  // Update current selection to only include cells that are currently visible (not filtered out)
  updateSelectionBasedOnFiltering(filteredIndices) {
    //console.log(`updateSelectionBasedOnFiltering called with filteredIndices:`, filteredIndices ? filteredIndices.length : 'null')
    //console.log(`Current selectedCells size:`, this.selectedCells ? this.selectedCells.size : 'null')
    
    if (!this.selectedCells || this.selectedCells.size === 0) {
      // No current selection, nothing to update
      console.log(`No current selection to update`)
      return
    }

    const originalSelectionSize = this.selectedCells.size
    
    if (!filteredIndices) {
      // No filtering applied - all cells are visible, keep current selection
      console.log(`Selection unchanged: ${originalSelectionSize} cells (no filtering)`)
      return
    }

    // Create a set of visible cell indices for O(1) lookup
    const visibleCellsSet = new Set(filteredIndices)
    
    // Filter the current selection to only include visible cells
    const filteredSelection = new Set()
    this.selectedCells.forEach(cellId => {
      if (visibleCellsSet.has(cellId)) {
        filteredSelection.add(cellId)
      }
    })
    
    // Update the current selection
    this.selectedCells = filteredSelection
    
    const newSelectionSize = this.selectedCells.size
    //console.log(`Selection updated: ${originalSelectionSize} → ${newSelectionSize} cells (filtered)`)
    
    // Update the selection count display
    this.updateSelectedCellsCount()
    
    // Update point colors to reflect the new selection
    this.updateSelectedPointColors()
  }

  // Incremental filtering - much faster for small changes
  getIncrementalFilteredIndices() {
    if (!this.selectedCategories || Object.keys(this.selectedCategories).length === 0) {
      // No filtering applied, return all cells
      return null
    }

    // Get all metadata that have selections AND have loaded vectors
    const metadataWithSelections = Object.keys(this.selectedCategories).filter(metadataId => {
      const selections = this.selectedCategories[metadataId]
      const hasSelections = selections && selections.size > 0
      const hasLoadedVector = this.getMetadataVectorById(metadataId) !== null
      return hasSelections && hasLoadedVector
    })

    if (metadataWithSelections.length === 0) {
      return null
    }

    // Create current filter state
    const currentFilterState = this.createFilterCacheKey()
    
    // If this is the same as last state, return current visible cells
    if (this.lastFilterState === currentFilterState && this.currentVisibleCells) {
      //console.log('Using cached incremental result')
      return this.currentVisibleCells
    }

    // If we have no current visible cells, do full calculation
    if (!this.currentVisibleCells) {
      //console.log('No current visible cells - doing full calculation')
      const result = this.getFilteredCellIndices()
      this.lastFilterState = currentFilterState
      return result
    }

    // Try incremental update based on what changed
    const incrementalResult = this.tryIncrementalUpdate(metadataWithSelections)
    if (incrementalResult !== null) {
      //console.log('Using incremental update')
      this.lastFilterState = currentFilterState
      return incrementalResult
    }

    // Fall back to full calculation
    //console.log('Fallback to full calculation')
    const result = this.getFilteredCellIndices()
    this.lastFilterState = currentFilterState
    return result
  }

  // Try to do an incremental update
  tryIncrementalUpdate(metadataWithSelections) {
    // For now, let's implement a simple case: single metadata changes
    if (metadataWithSelections.length === 1) {
      const metadataId = metadataWithSelections[0]
      const selectedCategories = this.selectedCategories[metadataId]
      //console.log(`Single metadata incremental filtering for ${metadataId}`)
      return this.getCellsForMetadataCategories(metadataId, selectedCategories)
    }

    // For multiple metadata, we could implement more sophisticated logic
    // For now, return null to trigger full calculation
    return null
  }

  // Get the intersection of selected cells across all metadata (full calculation)
  getFilteredCellIndices() {
    const startTime = performance.now()
    const hasDiscreteSelections = this.selectedCategories && Object.keys(this.selectedCategories).length > 0
    const hasContinuousSelections = this.selectedRanges && Object.keys(this.selectedRanges).length > 0
    
    console.log('🔍 getFilteredCellIndices called:', {
      hasDiscreteSelections,
      hasContinuousSelections,
      selectedCategories: this.selectedCategories,
      selectedRanges: this.selectedRanges
    })
    
    if (!hasDiscreteSelections && !hasContinuousSelections) {
      // No filtering applied, return all cells
      console.log('🔍 No selections found, returning null (no filtering)')
      return null
    }

    // Create cache key from current selections
    const cacheKey = this.createFilterCacheKey()
    if (this.filterCache.has(cacheKey)) {
      //console.log('Using cached filter result')
      return this.filterCache.get(cacheKey)
    }

    // Check if there are any actual constraints (this will be done more precisely below)
    // We'll check for constraints in the filtering logic below

    // Get all metadata that have actual constraints (not all categories/values selected)
    const discreteMetadataWithConstraints = Object.keys(this.selectedCategories).filter(metadataId => {
      const selections = this.selectedCategories[metadataId]
      const hasSelections = selections && selections.size > 0
      const hasLoadedVector = this.getMetadataVectorById(metadataId) !== null
      
      if (!hasSelections || !hasLoadedVector) return false
      
      // Check if all categories are selected (no constraint)
      const metadataVector = this.getMetadataVectorById(metadataId)
      if (metadataVector && metadataVector.values) {
        const availableCategories = [...new Set(metadataVector.values)]
        const allSelected = availableCategories.every(category => selections.has(category))
        return !allSelected // Only include if not all categories are selected
      }
      
      return true
    })

    const continuousMetadataWithConstraints = Object.keys(this.selectedRanges).filter(metadataId => {
      const range = this.selectedRanges[metadataId]
      const hasRange = range && (range.min !== undefined && range.max !== undefined)
      const hasLoadedVector = this.getMetadataVectorById(metadataId) !== null
      
      if (!hasRange || !hasLoadedVector) return false
      
      // Check if range covers the full range (no constraint)
      const metadataVector = this.getMetadataVectorById(metadataId)
      if (metadataVector && metadataVector.values) {
        const values = metadataVector.values
        const minVal = Math.min(...values)
        const maxVal = Math.max(...values)
        const isFullRange = range.min <= minVal && range.max >= maxVal
        return !isFullRange // Only include if range is not full
      }
      
      return true
    })

    // Combine all metadata with actual constraints
    const allMetadataWithConstraints = [...new Set([...discreteMetadataWithConstraints, ...continuousMetadataWithConstraints])]

    //console.log(`All metadata in selectedCategories:`, Object.keys(this.selectedCategories))
    //console.log(`Loaded metadata vectors:`, Object.keys(this.loadedMetadataVectors))
    //console.log(`Current metadata ID:`, this.currentMetadataId)

    if (allMetadataWithConstraints.length === 0) {
      // No metadata has actual constraints, return all cells
      console.log('🔍 No metadata with constraints found, returning null (no filtering)')
      return null
    }

    console.log('🔍 Metadata with constraints:', allMetadataWithConstraints)

    // Start with cells that match the first metadata's constraints
    const firstMetadataId = allMetadataWithConstraints[0]
    let filteredIndices = this.getCellsForMetadata(firstMetadataId)
    console.log(`🔍 First metadata ${firstMetadataId} filtered indices:`, filteredIndices ? filteredIndices.length : 'null')

    // Intersect with each subsequent metadata's constraints using Set for O(1) lookups
    for (let i = 1; i < allMetadataWithConstraints.length; i++) {
      const metadataId = allMetadataWithConstraints[i]
      const cellsForThisMetadata = this.getCellsForMetadata(metadataId)
      console.log(`🔍 Metadata ${metadataId} filtered indices:`, cellsForThisMetadata ? cellsForThisMetadata.length : 'null')
      
      // Convert to Set for O(1) lookup instead of O(n) includes()
      const cellsSet = new Set(cellsForThisMetadata)
      
      // Intersection: keep only cells that are in both sets
      filteredIndices = filteredIndices.filter(cellIndex => cellsSet.has(cellIndex))
      console.log(`🔍 After intersection with ${metadataId}:`, filteredIndices ? filteredIndices.length : 'null')
    }

    console.log(`🔍 Final filtered ${filteredIndices ? filteredIndices.length : 'null'} cells from ${this.currentCoordinates?.length || 0} total cells`)
    
    // Cache the result
    this.filterCache.set(cacheKey, filteredIndices)
    
    const totalTime = performance.now() - startTime
    console.log(`🚀 [PERF] getFilteredCellIndices completed in ${totalTime.toFixed(2)}ms`)
    
    return filteredIndices
  }

  // Get cell indices for a given metadata (handles both discrete and continuous)
  getCellsForMetadata(metadataId) {
    // Check if this is discrete metadata with actual selections
    if (this.selectedCategories[metadataId] && this.selectedCategories[metadataId].size > 0) {
      return this.getCellsForMetadataCategories(metadataId, this.selectedCategories[metadataId])
    }
    
    // Check if this is continuous metadata with actual range
    if (this.selectedRanges[metadataId]) {
      return this.getCellsForMetadataRange(metadataId, this.selectedRanges[metadataId])
    }
    
    console.warn(`No selection found for metadata ID: ${metadataId}`)
    return []
  }

  // Get cell indices that belong to the specified categories for a given metadata
  getCellsForMetadataCategories(metadataId, selectedCategories) {
    // Find the metadata vector for this metadata ID
    const metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector || !metadataVector.values) {
      console.warn(`No metadata vector found for metadata ID: ${metadataId}`)
      return []
    }

    const startTime = performance.now()
    const cellIndices = []
    const values = metadataVector.values
    
    // Use for loop instead of forEach for better performance
    for (let index = 0; index < values.length; index++) {
      if (selectedCategories.has(values[index])) {
        cellIndices.push(index)
      }
    }

    const endTime = performance.now()
    console.log(`Found ${cellIndices.length} cells for discrete metadata ${metadataId} in ${(endTime - startTime).toFixed(2)}ms`)
    return cellIndices
  }

  // Get cell indices that fall within the specified range for continuous metadata
  getCellsForMetadataRange(metadataId, range) {
    // Find the metadata vector for this metadata ID
    const metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector || !metadataVector.values) {
      console.warn(`No metadata vector found for metadata ID: ${metadataId}`)
      return []
    }

    console.log(`🔍 getCellsForMetadataRange called for metadata ${metadataId}:`, {
      range,
      valuesLength: metadataVector.values.length,
      firstFewValues: metadataVector.values.slice(0, 10)
    })

    const startTime = performance.now()
    const cellIndices = []
    const values = metadataVector.values
    
    // Use for loop instead of forEach for better performance
    for (let index = 0; index < values.length; index++) {
      const value = values[index]
      if (value >= range.min && value <= range.max) {
        cellIndices.push(index)
      }
    }

    const endTime = performance.now()
    console.log(`🔍 Found ${cellIndices.length} cells for continuous metadata ${metadataId} in range [${range.min}, ${range.max}] in ${(endTime - startTime).toFixed(2)}ms`)
    console.log(`🔍 First 10 filtered indices:`, cellIndices.slice(0, 10))
    return cellIndices
  }

  // Create a cache key from current selections
  createFilterCacheKey() {
    const keyParts = []
    
    // Add discrete metadata selections
    Object.keys(this.selectedCategories).sort().forEach(metadataId => {
      const categories = Array.from(this.selectedCategories[metadataId]).sort()
      keyParts.push(`d:${metadataId}:${categories.join(',')}`)
    })
    
    // Add continuous metadata ranges
    Object.keys(this.selectedRanges).sort().forEach(metadataId => {
      const range = this.selectedRanges[metadataId]
      keyParts.push(`c:${metadataId}:${range.min}-${range.max}`)
    })
    
    return keyParts.join('|')
  }

  // Clear incremental filtering state
  clearIncrementalState() {
    this.currentVisibleCells = null
    this.lastFilterState = null
    this.filterCache.clear()
    //console.log('Cleared incremental filtering state after embedding change')
  }

  // Clear all checkbox selections when switching metadata
  clearAllCheckboxSelections() {
    // Clear the selected categories for all metadata
    this.selectedCategories = {}
    
    // Reset all checkbox visual states
    const allCheckboxes = document.querySelectorAll('.metadata-checkbox, .category-checkbox')
    allCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = '#10b981' // Green (selected)
      const icon = checkbox.querySelector('i')
      if (icon) {
        icon.style.display = 'block'
      }
    })
    
    //console.log('Cleared all checkbox selections')
  }

  // Helper method to get metadata vector by ID
  getMetadataVectorById(metadataId) {
    // Check if it's the current metadata vector (fully loaded and decompressed)
    if (this.currentMetadataId === metadataId && this.currentMetadataVector) {
      return this.currentMetadataVector
    }
    
    // Check stored metadata vectors
    if (this.loadedMetadataVectors && this.loadedMetadataVectors[metadataId]) {
      const vectorData = this.loadedMetadataVectors[metadataId]
      
      // If it's already decompressed (has values), return it
      if (vectorData.values) {
        return vectorData
      }
      
      // If it's compressed, decompress it on demand
      try {
        let values
        if (vectorData.data_type === 'DISCRETE') {
          values = this.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else if (vectorData.data_type === 'NUMERIC') {
          values = this.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else {
          console.warn(`Unknown data type for metadata ${metadataId}: ${vectorData.data_type}`)
          return null
        }
        
        // Create a fully loaded metadata vector object
        const decompressedVector = {
          id: metadataId,
          name: vectorData.name,
          data_type: vectorData.data_type,
          values: values,
          compression_info: vectorData.compression_info
        }
        
        // Store the decompressed version
        this.loadedMetadataVectors[metadataId] = decompressedVector
        
        //console.log(`Decompressed metadata vector ${metadataId} on demand: ${values.length} values`)
        return decompressedVector
        
      } catch (error) {
        console.error(`Error decompressing metadata vector ${metadataId}:`, error)
        return null
      }
    }
    
    console.warn(`Metadata vector not found for ID: ${metadataId}`)
    return null
  }

  // ===== RANGE SLIDER FUNCTIONALITY =====
  
  // Decompress metadata vector based on data type
  decompressMetadataVector(vectorData) {
    if (!vectorData.compressed_data || !vectorData.compression_info) {
      console.error('Missing compressed data or compression info')
      return null
    }
    
    try {
      let values
      if (vectorData.data_type === 'DISCRETE') {
        values = this.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
      } else if (vectorData.data_type === 'NUMERIC') {
        values = this.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
      } else {
        console.error('Unknown data type for decompression:', vectorData.data_type)
        return null
      }
      
      return values
    } catch (error) {
      console.error('Error decompressing metadata vector:', error)
      return null
    }
  }
  
  // Toggle inline range slider for numeric metadata
  toggleInlineRangeSlider(metadataId, metadataName) {
    console.log('🎚️ Toggling inline range slider for metadata:', metadataId, metadataName)
    
    const metadataCard = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataCard) {
      console.error('❌ Metadata card not found for ID:', metadataId)
      return
    }
    
    const rangeSection = metadataCard.querySelector('.metadata-range-section')
    const chevron = metadataCard.querySelector('svg')
    
    if (!rangeSection || !chevron) {
      console.error('❌ Range section or chevron not found')
      console.log('Range section:', rangeSection)
      console.log('Chevron:', chevron)
      return
    }
    
    // Since toggleMetadata already handles visibility, we just need to initialize the range slider
    console.log('🎚️ Initializing inline range slider data...')
    
    // Wait a bit for the DOM to update, then load and initialize the range slider data
    setTimeout(() => {
      console.log('🎚️ Loading metadata for inline range slider...')
      this.loadSingleMetadataVector(metadataId).then(vectorData => {
        console.log('🎚️ Metadata loaded for inline range slider:', vectorData)
        if (!vectorData) {
          console.error('❌ No vector data loaded for inline range slider')
          return
        }
        
        let values = vectorData.values
        if (!values && vectorData.compressed_data) {
          console.log('🎚️ Decompressing metadata for inline range slider...')
          values = this.decompressMetadataVector(vectorData)
        }
        
        if (!values) {
          console.error('❌ No values available for inline range slider')
          return
        }
        
        console.log('🎚️ Values loaded for inline range slider:', values.length, 'values')
        
        // Initialize the inline range slider with the loaded values
        this.initializeInlineRangeSlider(metadataId, values)
        
        // Apply the metadata coloring to the main visualization
        console.log('🎚️ Applying metadata coloring to main visualization...')
        const minVal = Math.min(...values)
        const maxVal = Math.max(...values)
        this.setColorRange(minVal, maxVal)
        this.loadAndVisualizeMetadataVector(metadataId)
        
        console.log('🎚️ Inline range slider fully initialized and ready for interaction')
      }).catch(error => {
        console.error('❌ Error loading metadata for inline range slider:', error)
      })
    }, 100) // Wait 100ms for DOM to update
  }

  // Update inline range slider UI
  updateInlineRangeSlider(metadataId) {
    if (!this.inlineRangeSliderData || !this.inlineRangeSliderData[metadataId]) return
    
    const sliderData = this.inlineRangeSliderData[metadataId]
    const { min, max, currentMin, currentMax } = sliderData
    const range = max - min
    
    const minPercent = ((currentMin - min) / range) * 100
    const maxPercent = ((currentMax - min) / range) * 100
    
    const metadataCard = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataCard) return
    
    const minHandle = metadataCard.querySelector('.range-slider-min-handle')
    const maxHandle = metadataCard.querySelector('.range-slider-max-handle')
    const activeTrack = metadataCard.querySelector('.range-slider-active')
    const minInput = metadataCard.querySelector('.range-min-input')
    const maxInput = metadataCard.querySelector('.range-max-input')
    
    if (minHandle) minHandle.style.left = `${minPercent}%`
    if (maxHandle) maxHandle.style.left = `${maxPercent}%`
    if (activeTrack) {
      activeTrack.style.left = `${minPercent}%`
      activeTrack.style.width = `${maxPercent - minPercent}%`
    }
    if (minInput) minInput.value = currentMin.toFixed(3)
    if (maxInput) maxInput.value = currentMax.toFixed(3)
  }


  // Show range slider modal for numeric metadata
  showRangeSlider(metadataId, metadataName) {
    console.log('🎚️ Showing range slider for metadata:', metadataId, metadataName)
    
    // Store current metadata info
    this.currentRangeSliderMetadataId = metadataId
    this.currentRangeSliderMetadataName = metadataName
    
    console.log('🎚️ Stored metadata info:', {
      currentRangeSliderMetadataId: this.currentRangeSliderMetadataId,
      currentRangeSliderMetadataName: this.currentRangeSliderMetadataName
    })
    
    // Load metadata vector first to get the data range
    this.loadSingleMetadataVector(metadataId).then(vectorData => {
      console.log('🎚️ Loaded vector data for range slider:', vectorData)
      
      if (!vectorData) {
        console.error('❌ Failed to load metadata vector for range slider - vectorData is null')
        alert('Failed to load metadata vector. Please try again.')
        return
      }
      
      // Check if we need to decompress the data
      let values = vectorData.values
      if (!values && vectorData.compressed_data) {
        console.log('🎚️ Decompressing metadata vector data...')
        values = this.decompressMetadataVector(vectorData)
        if (!values) {
          console.error('❌ Failed to decompress metadata vector')
          alert('Failed to decompress metadata values. Please try again.')
          return
        }
        console.log('🎚️ Successfully decompressed', values.length, 'values')
      }
      
      if (!values) {
        console.error('❌ Failed to load metadata vector for range slider - no values property')
        console.error('Available properties:', Object.keys(vectorData))
        alert('Failed to load metadata values. Please try again.')
        return
      }
      
      // Calculate data range
      console.log('🎚️ Values loaded:', values.length, 'values, range:', Math.min(...values), 'to', Math.max(...values))
      
      const minVal = Math.min(...values)
      const maxVal = Math.max(...values)
      
      // Update modal content
      document.getElementById('range-slider-metadata-name').textContent = metadataName
      document.getElementById('range-slider-current-range').textContent = `${minVal.toFixed(3)} to ${maxVal.toFixed(3)}`
      
      // Initialize modal range slider
      this.initializeModalRangeSlider(minVal, maxVal, values)
      
      // Show modal
      const modal = document.getElementById('range-slider-modal')
      console.log('🎚️ Modal element found:', modal)
      if (modal) {
        modal.style.display = 'flex'
        console.log('🎚️ Modal display set to flex')
        
        // Check computed styles
        const computedStyle = window.getComputedStyle(modal)
        console.log('🎚️ Modal computed styles:', {
          display: computedStyle.display,
          visibility: computedStyle.visibility,
          opacity: computedStyle.opacity,
          zIndex: computedStyle.zIndex,
          position: computedStyle.position
        })
        
        // Check if modal is actually visible
        console.log('🎚️ Modal offsetParent:', modal.offsetParent)
        console.log('🎚️ Modal clientWidth:', modal.clientWidth)
        console.log('🎚️ Modal clientHeight:', modal.clientHeight)
      } else {
        console.error('❌ Range slider modal not found!')
      }
      
      // Setup event listeners
      this.setupRangeSliderEventListeners()
      
      // Automatically apply the full range to show the visualization
      console.log('🎚️ Applying full range to visualization...')
      this.setColorRange(minVal, maxVal)
      this.loadAndVisualizeMetadataVector(metadataId)
      
    }).catch(error => {
      console.error('❌ Error loading metadata for range slider:', error)
      alert('Error loading metadata: ' + error.message)
    })
  }
  
  // Initialize modal range slider with data
  initializeModalRangeSlider(minVal, maxVal, values) {
    console.log('🎚️ Initializing range slider with:', { minVal, maxVal, valuesLength: values.length })
    
    this.rangeSliderData = {
      min: minVal,
      max: maxVal,
      values: values,
      currentMin: minVal,
      currentMax: maxVal
    }
    
    // Store globally as fallback in case controller data gets cleared
    window.globalRangeSliderData = this.rangeSliderData
    
    console.log('🎚️ rangeSliderData set:', this.rangeSliderData)
    console.log('🎚️ Global fallback also set:', window.globalRangeSliderData)
    
    // Update input fields
    document.getElementById('range-min-input').value = minVal.toFixed(3)
    document.getElementById('range-max-input').value = maxVal.toFixed(3)
    
    // Update slider handles
    this.updateRangeSliderHandles()
    
    // Draw initial plot
    this.drawDensityPlot(values)
  }
  
  // Update range slider handle positions
  updateRangeSliderHandles() {
    const { min, max, currentMin, currentMax } = this.rangeSliderData
    const range = max - min
    
    const minPercent = ((currentMin - min) / range) * 100
    const maxPercent = ((currentMax - min) / range) * 100
    
    // Cache DOM elements to avoid repeated queries
    if (!this._cachedSliderElements) {
      this._cachedSliderElements = {
        minHandle: document.getElementById('range-slider-min-handle'),
        maxHandle: document.getElementById('range-slider-max-handle'),
        activeTrack: document.getElementById('range-slider-active'),
        minValue: document.getElementById('range-slider-min-value'),
        maxValue: document.getElementById('range-slider-max-value')
      }
    }
    
    const { minHandle, maxHandle, activeTrack, minValue, maxValue } = this._cachedSliderElements
    
    // Update positions immediately (no throttling for smooth dragging)
    minHandle.style.left = `${minPercent}%`
    maxHandle.style.left = `${maxPercent}%`
    activeTrack.style.left = `${minPercent}%`
    activeTrack.style.width = `${maxPercent - minPercent}%`
    
    // Update value displays (throttled to reduce DOM updates)
    if (!this._valueUpdateScheduled) {
      this._valueUpdateScheduled = true
      requestAnimationFrame(() => {
        minValue.textContent = currentMin.toFixed(3)
        maxValue.textContent = currentMax.toFixed(3)
        this._valueUpdateScheduled = false
      })
    }
    
    // Keep global fallback in sync
    if (window.globalRangeSliderData) {
      window.globalRangeSliderData.currentMin = currentMin
      window.globalRangeSliderData.currentMax = currentMax
    }
  }
  
  // Setup event listeners for range slider
  setupRangeSliderEventListeners() {
    console.log('🎚️ Setting up range slider event listeners...')
    
    // Close button
    const closeBtn = document.getElementById('close-range-slider')
    if (closeBtn) {
      closeBtn.onclick = () => {
        this.hideRangeSlider()
      }
      console.log('🎚️ Close button event listener set')
    } else {
      console.error('❌ Close button not found')
    }
    
    // Modal background click
    document.getElementById('range-slider-modal').onclick = (e) => {
      if (e.target.id === 'range-slider-modal') {
        this.hideRangeSlider()
      }
    }
    
    // Input field changes
    document.getElementById('range-min-input').onchange = (e) => {
      const value = parseFloat(e.target.value)
      if (!isNaN(value)) {
        this.rangeSliderData.currentMin = Math.max(this.rangeSliderData.min, Math.min(value, this.rangeSliderData.currentMax))
        this.updateRangeSliderHandles()
        this.updatePlot()
      }
    }
    
    document.getElementById('range-max-input').onchange = (e) => {
      const value = parseFloat(e.target.value)
      if (!isNaN(value)) {
        this.rangeSliderData.currentMax = Math.min(this.rangeSliderData.max, Math.max(value, this.rangeSliderData.currentMin))
        this.updateRangeSliderHandles()
        this.updatePlot()
      }
    }
    
    // Plot type buttons
    document.getElementById('density-plot-btn').onclick = () => {
      this.setActivePlotType('density')
      this.drawDensityPlot(this.rangeSliderData.values)
    }
    
    document.getElementById('violin-plot-btn').onclick = () => {
      this.setActivePlotType('violin')
      this.drawViolinPlot(this.rangeSliderData.values)
    }
    
    // Action buttons
    document.getElementById('reset-range-btn').onclick = () => {
      this.resetRangeSlider()
    }
    
    document.getElementById('apply-range-btn').onclick = () => {
      this.applyRangeSelection()
    }
  }
  
  // Set active plot type button
  setActivePlotType(type) {
    const densityBtn = document.getElementById('density-plot-btn')
    const violinBtn = document.getElementById('violin-plot-btn')
    
    if (type === 'density') {
      densityBtn.classList.add('active')
      densityBtn.style.backgroundColor = '#3b82f6'
      densityBtn.style.color = 'white'
      densityBtn.style.borderColor = '#3b82f6'
      
      violinBtn.classList.remove('active')
      violinBtn.style.backgroundColor = 'white'
      violinBtn.style.color = '#374151'
      violinBtn.style.borderColor = '#d1d5db'
    } else {
      violinBtn.classList.add('active')
      violinBtn.style.backgroundColor = '#3b82f6'
      violinBtn.style.color = 'white'
      violinBtn.style.borderColor = '#3b82f6'
      
      densityBtn.classList.remove('active')
      densityBtn.style.backgroundColor = 'white'
      densityBtn.style.color = '#374151'
      densityBtn.style.borderColor = '#d1d5db'
    }
  }
  
  // Draw density plot
  drawDensityPlot(values) {
    // Cache canvas and context for better performance
    if (!this._cachedPlotCanvas) {
      this._cachedPlotCanvas = document.getElementById('range-slider-plot')
      this._cachedPlotContext = this._cachedPlotCanvas.getContext('2d')
    }
    
    const canvas = this._cachedPlotCanvas
    const ctx = this._cachedPlotContext
    const width = canvas.width
    const height = canvas.height
    
    // Clear canvas
    ctx.clearRect(0, 0, width, height)
    
    // Create histogram with optimized binning
    const bins = 50
    const { min, max } = this.rangeSliderData
    const binWidth = (max - min) / bins
    const histogram = new Array(bins).fill(0)
    
    // Optimize histogram creation
    const invBinWidth = 1 / binWidth
    for (let i = 0; i < values.length; i++) {
      const binIndex = Math.min(Math.floor((values[i] - min) * invBinWidth), bins - 1)
      histogram[binIndex]++
    }
    
    const maxCount = Math.max(...histogram)
    
    // Draw histogram
    ctx.fillStyle = '#3b82f6'
    ctx.strokeStyle = '#1d4ed8'
    ctx.lineWidth = 1
    
    const margins = this.getPlotMargins()
    histogram.forEach((count, i) => {
      const x = (i / bins) * width
      const barWidth = width / bins
      const barHeight = (count / maxCount) * (height - margins.top - margins.bottom)
      const y = height - margins.bottom - barHeight
      
      ctx.fillRect(x, y, barWidth - 1, barHeight)
      ctx.strokeRect(x, y, barWidth - 1, barHeight)
    })
    
    // Draw range selection
    const { currentMin, currentMax } = this.rangeSliderData
    const minX = ((currentMin - min) / (max - min)) * width
    const maxX = ((currentMax - min) / (max - min)) * width
    
    ctx.fillStyle = 'rgba(59, 130, 246, 0.3)'
    ctx.fillRect(minX, 0, maxX - minX, height)
    
    // Draw range lines
    ctx.strokeStyle = '#ef4444'
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(minX, 0)
    ctx.lineTo(minX, height)
    ctx.moveTo(maxX, 0)
    ctx.lineTo(maxX, height)
    ctx.stroke()
    
    // Draw labels
    ctx.fillStyle = '#374151'
    ctx.font = '12px sans-serif'
    ctx.textAlign = 'center'
    ctx.fillText(currentMin.toFixed(3), minX, height - 5)
    ctx.fillText(currentMax.toFixed(3), maxX, height - 5)
  }
  
  // Draw violin plot showing distribution per discrete category
  drawViolinPlot(values) {
    const canvas = document.getElementById('range-slider-plot')
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    
    // Clear canvas
    ctx.clearRect(0, 0, width, height)
    
    // Check if we have discrete metadata loaded
    if (!this.currentMetadataVector || this.currentMetadataVector.data_type !== 'DISCRETE') {
      ctx.fillStyle = '#6b7280'
      ctx.font = '16px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('Violin plot requires discrete metadata to be active', width / 2, height / 2)
      ctx.fillText('Please select a discrete metadata first', width / 2, height / 2 + 20)
      return
    }
    
    // Get discrete categories and their corresponding numeric values
    const discreteValues = this.currentMetadataVector.values
    const categories = this.currentMetadataVector.categories || [...new Set(discreteValues)]
    
    // Group numeric values by discrete category
    const categoryGroups = {}
    categories.forEach(category => {
      categoryGroups[category] = []
    })
    
    values.forEach((numericValue, index) => {
      const category = discreteValues[index]
      if (categoryGroups[category]) {
        categoryGroups[category].push(numericValue)
      }
    })
    
    // Calculate statistics for each category
    const categoryStats = {}
    Object.keys(categoryGroups).forEach(category => {
      const groupValues = categoryGroups[category]
      if (groupValues.length > 0) {
        const sorted = groupValues.sort((a, b) => a - b)
        const q1 = sorted[Math.floor(sorted.length * 0.25)]
        const median = sorted[Math.floor(sorted.length * 0.5)]
        const q3 = sorted[Math.floor(sorted.length * 0.75)]
        const min = sorted[0]
        const max = sorted[sorted.length - 1]
        
        categoryStats[category] = {
          values: groupValues,
          min, max, q1, median, q3,
          count: groupValues.length
        }
      }
    })
    
    // Draw violin plots
    const numCategories = Object.keys(categoryStats).length
    if (numCategories === 0) {
      ctx.fillStyle = '#6b7280'
      ctx.font = '16px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('No data available for violin plot', width / 2, height / 2)
      return
    }
    
    const margins = this.getPlotMargins()
    const plotWidth = width - margins.left - margins.right
    const plotHeight = height - margins.top - margins.bottom
    const categoryWidth = plotWidth / numCategories
    const startX = margins.left
    const startY = margins.top
    
    // Get color palette
    const colors = this.getCategoryColors()
    
    Object.keys(categoryStats).forEach((category, index) => {
      const stats = categoryStats[category]
      const x = startX + (index * categoryWidth) + (categoryWidth / 2)
      const color = colors[index % colors.length]
      
      // Draw violin shape (simplified box plot with density)
      const { min, max, q1, median, q3 } = stats
      const { currentMin, currentMax } = this.rangeSliderData
      
      // Scale values to plot coordinates
      const scaleY = (value) => startY + plotHeight - ((value - currentMin) / (currentMax - currentMin)) * plotHeight
      
      // Draw box plot elements
      const boxTop = scaleY(q3)
      const boxBottom = scaleY(q1)
      const boxHeight = boxBottom - boxTop
      const boxWidth = categoryWidth * 0.6
      
      // Box
      ctx.fillStyle = color + '40' // Add transparency
      ctx.fillRect(x - boxWidth/2, boxTop, boxWidth, boxHeight)
      
      // Box border
      ctx.strokeStyle = color
      ctx.lineWidth = 1
      ctx.strokeRect(x - boxWidth/2, boxTop, boxWidth, boxHeight)
      
      // Median line
      const medianY = scaleY(median)
      ctx.strokeStyle = color
      ctx.lineWidth = 2
      ctx.beginPath()
      ctx.moveTo(x - boxWidth/2, medianY)
      ctx.lineTo(x + boxWidth/2, medianY)
      ctx.stroke()
      
      // Whiskers
      const minY = scaleY(min)
      const maxY = scaleY(max)
      
      ctx.strokeStyle = color
      ctx.lineWidth = 1
      ctx.beginPath()
      // Lower whisker
      ctx.moveTo(x, boxBottom)
      ctx.lineTo(x, minY)
      ctx.moveTo(x - boxWidth/4, minY)
      ctx.lineTo(x + boxWidth/4, minY)
      // Upper whisker
      ctx.moveTo(x, boxTop)
      ctx.lineTo(x, maxY)
      ctx.moveTo(x - boxWidth/4, maxY)
      ctx.lineTo(x + boxWidth/4, maxY)
      ctx.stroke()
      
      // Category label
      ctx.fillStyle = '#374151'
      ctx.font = '10px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText(category, x, startY + plotHeight + 15)
      
      // Count label
      ctx.fillStyle = '#6b7280'
      ctx.font = '8px sans-serif'
      ctx.fillText(`n=${stats.count}`, x, startY + plotHeight + 25)
    })
    
    // Draw range selection overlay
    const { currentMin, currentMax } = this.rangeSliderData
    const { min, max } = this.rangeSliderData
    const minY = startY + plotHeight - ((currentMin - min) / (max - min)) * plotHeight
    const maxY = startY + plotHeight - ((currentMax - min) / (max - min)) * plotHeight
    
    ctx.fillStyle = 'rgba(59, 130, 246, 0.2)'
    ctx.fillRect(startX, Math.min(minY, maxY), plotWidth, Math.abs(maxY - minY))
    
    // Draw range lines
    ctx.strokeStyle = '#ef4444'
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(startX, minY)
    ctx.lineTo(startX + plotWidth, minY)
    ctx.moveTo(startX, maxY)
    ctx.lineTo(startX + plotWidth, maxY)
    ctx.stroke()
    
    // Y-axis labels
    ctx.fillStyle = '#374151'
    ctx.font = '10px sans-serif'
    ctx.textAlign = 'right'
    ctx.fillText(currentMin.toFixed(2), startX - 5, startY + plotHeight)
    ctx.fillText(currentMax.toFixed(2), startX - 5, startY)
  }
  
  // Update plot when range changes
  updatePlot() {
    const startTime = performance.now()
    console.log('🚀 [PERF] updatePlot started')
    
    const activeBtn = document.querySelector('.plot-type-btn.active')
    if (activeBtn.id === 'density-plot-btn') {
      const densityStart = performance.now()
      this.drawDensityPlot(this.rangeSliderData.values)
      const densityTime = performance.now() - densityStart
      console.log(`🚀 [PERF] drawDensityPlot took ${densityTime.toFixed(2)}ms`)
    } else {
      const violinStart = performance.now()
      this.drawViolinPlot(this.rangeSliderData.values)
      const violinTime = performance.now() - violinStart
      console.log(`🚀 [PERF] drawViolinPlot took ${violinTime.toFixed(2)}ms`)
    }
    
    const totalTime = performance.now() - startTime
    console.log(`🚀 [PERF] updatePlot completed in ${totalTime.toFixed(2)}ms`)
  }
  
  // Reset range slider to full range
  resetRangeSlider() {
    this.rangeSliderData.currentMin = this.rangeSliderData.min
    this.rangeSliderData.currentMax = this.rangeSliderData.max
    
    document.getElementById('range-min-input').value = this.rangeSliderData.min.toFixed(3)
    document.getElementById('range-max-input').value = this.rangeSliderData.max.toFixed(3)
    
    this.updateRangeSliderHandles()
    this.updatePlot()
  }
  
  // Apply range selection and load metadata
  applyRangeSelection() {
    const { currentMin, currentMax } = this.rangeSliderData
    
    // Set custom color range
    this.setColorRange(currentMin, currentMax)
    
    // Hide modal
    this.hideRangeSlider()
    
    // Load and visualize metadata with the selected range
    this.loadAndVisualizeMetadataVector(this.currentRangeSliderMetadataId)
  }
  
  // Hide range slider modal
  hideRangeSlider() {
    const modal = document.getElementById('range-slider-modal')
    modal.style.display = 'none'
    
    // Clean up
    this.currentRangeSliderMetadataId = null
    this.currentRangeSliderMetadataName = null
    this.rangeSliderData = null
  }

  // ===== RANGE SLIDER DRAG FUNCTIONALITY =====
  
  // Start dragging a range slider handle
  startRangeSliderDrag(event) {
    console.log('🎚️ startRangeSliderDrag called!', event)
    event.preventDefault()
    event.stopPropagation()
    
    const handleType = event.currentTarget.dataset.handleType
    console.log('🎚️ Starting drag for handle:', handleType)
    console.log('🎚️ rangeSliderData exists:', !!this.rangeSliderData)
    
    if (!this.rangeSliderData) {
      console.error('❌ No rangeSliderData available for dragging')
      return
    }
    
    this.rangeSliderDragState = {
      isDragging: true,
      handleType: handleType,
      startX: event.type === 'mousedown' ? event.clientX : event.touches[0].clientX,
      startValue: handleType === 'min' ? this.rangeSliderData.currentMin : this.rangeSliderData.currentMax
    }
    
    console.log('🎚️ Drag state initialized:', this.rangeSliderDragState)
    
    // Bind the event handlers to preserve 'this' context
    this.boundHandleDrag = this.handleRangeSliderDrag.bind(this)
    this.boundStopDrag = this.stopRangeSliderDrag.bind(this)
    
    // Add global event listeners
    document.addEventListener('mousemove', this.boundHandleDrag)
    document.addEventListener('mouseup', this.boundStopDrag)
    document.addEventListener('touchmove', this.boundHandleDrag)
    document.addEventListener('touchend', this.boundStopDrag)
    
    console.log('🎚️ Event listeners added')
    
    // Change cursor
    document.body.style.cursor = 'grabbing'
  }
  
  // Handle range slider drag movement
  handleRangeSliderDrag(event) {
    if (!this.rangeSliderDragState || !this.rangeSliderDragState.isDragging) {
      return
    }
    
    const dragStartTime = performance.now()
    event.preventDefault()
    
    const currentX = event.type === 'mousemove' ? event.clientX : event.touches[0].clientX
    const deltaX = currentX - this.rangeSliderDragState.startX
    
    const slider = document.getElementById('range-slider-modal')
    const rect = slider.getBoundingClientRect()
    const sliderWidth = rect.width - 40 // Account for padding
    
    const { min, max } = this.rangeSliderData
    const range = max - min
    const deltaValue = (deltaX / sliderWidth) * range
    
    let newValue = this.rangeSliderDragState.startValue + deltaValue
    newValue = Math.max(min, Math.min(max, newValue))
    
    if (this.rangeSliderDragState.handleType === 'min') {
      newValue = Math.min(newValue, this.rangeSliderData.currentMax)
      this.rangeSliderData.currentMin = newValue
      document.getElementById('range-min-input').value = newValue.toFixed(3)
    } else {
      newValue = Math.max(newValue, this.rangeSliderData.currentMin)
      this.rangeSliderData.currentMax = newValue
      document.getElementById('range-max-input').value = newValue.toFixed(3)
    }
    
    const handleUpdateStart = performance.now()
    this.updateRangeSliderHandles()
    const handleUpdateTime = performance.now() - handleUpdateStart
    console.log(`🚀 [PERF] updateRangeSliderHandles took ${handleUpdateTime.toFixed(2)}ms`)
    
    // Throttle plot updates during dragging for better performance
    if (!this.rangeSliderUpdateScheduled) {
      this.rangeSliderUpdateScheduled = true
      requestAnimationFrame(() => {
        this.rangeSliderUpdateScheduled = false
        console.log('🚀 [PERF] Scheduled modal range slider plot update')
        const plotUpdateStart = performance.now()
        this.updatePlot()
        const plotUpdateTime = performance.now() - plotUpdateStart
        console.log(`🚀 [PERF] Modal range slider updatePlot took ${plotUpdateTime.toFixed(2)}ms`)
      })
    } else {
      console.log('🚀 [PERF] Throttled modal range slider plot update (already scheduled)')
    }
    
    const totalDragTime = performance.now() - dragStartTime
    console.log(`🚀 [PERF] Modal range slider handleRangeSliderDrag completed in ${totalDragTime.toFixed(2)}ms`)
  }
  
  // Stop range slider drag
  stopRangeSliderDrag() {
    if (!this.rangeSliderDragState) return
    
    this.rangeSliderDragState.isDragging = false
    this.rangeSliderDragState = null
    
    // Remove global event listeners using the bound functions
    if (this.boundHandleDrag) {
      document.removeEventListener('mousemove', this.boundHandleDrag)
      document.removeEventListener('touchmove', this.boundHandleDrag)
    }
    if (this.boundStopDrag) {
      document.removeEventListener('mouseup', this.boundStopDrag)
      document.removeEventListener('touchend', this.boundStopDrag)
    }
    
    // Reset cursor
    document.body.style.cursor = ''
    
    // Ensure final update is performed when dragging stops
    this.updatePlot()
  }

}
