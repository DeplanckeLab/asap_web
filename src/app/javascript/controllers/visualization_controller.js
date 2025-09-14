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
    // Simple test - remove this after debugging
    setTimeout(() => {
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
    this.interactionMode = 'pan' // 'pan', 'lasso', or 'zoom'
    this.selectedCells = new Set()
    this.originalPointColors = new Map() // Store original colors for reset functionality
    this.lassoGraphics = null
    this.lassoPoints = []
    this.isDrawingLasso = false
    
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

  setupInteractionSystem() {
    console.log('🔧 Setting up interaction system')
    
    // Set up the mode dropdown change handler
    const modeDropdown = document.getElementById('interaction-mode')
    if (modeDropdown) {
      console.log('✅ Found interaction mode dropdown')
      modeDropdown.addEventListener('change', (event) => {
        console.log('🔄 Mode dropdown changed to:', event.target.value)
        this.changeInteractionMode(event)
      })
    } else {
      console.log('❌ Interaction mode dropdown not found')
    }
    
    // Set up canvas event listeners when PIXI app becomes available
    this.setupCanvasListeners()
  }

  setupCanvasListeners() {
    console.log('🔍 Setting up canvas listeners')
    
    // This will be called when the PIXI app is created
    // For now, we'll set up a polling mechanism to check for the canvas
    const checkForCanvas = () => {
      const canvas = document.querySelector('.plot-container canvas')
      console.log('🔍 Checking for canvas:', !!canvas, 'Setup done:', !!this.canvasListenersSetup)
      
      if (canvas && !this.canvasListenersSetup) {
        console.log('✅ Canvas found, setting up interaction listeners')
        this.canvas = canvas
        this.addInteractionEventListeners()
        this.canvasListenersSetup = true
      } else if (!canvas) {
        console.log('⏳ Canvas not found yet, checking again in 500ms')
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
    console.log('Selected metadata ID:', selectedMetadataId)
    
    if (selectedMetadataId) {
      this.loadMetadataCoordinates(selectedMetadataId)
    } else {
      // Clear any existing metadata data
      this.clearMetadataData()
    }
  }

  async loadMetadataCoordinates(metadataId) {
    try {
      console.log('Loading metadata coordinates for ID:', metadataId)
      
      // Get the current loom file selection
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : null
      
      // Build the URL for the metadata coordinates endpoint
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_coordinates?metadata_id=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      console.log('Fetching binary data from URL:', url)
      
      // Get CSRF token safely
      const csrfMetaTag = document.querySelector('meta[name="csrf-token"]')
      const csrfToken = csrfMetaTag?.getAttribute('content')
      
      console.log('CSRF token debug:', {
        metaTagFound: !!csrfMetaTag,
        tokenValue: csrfToken ? 'present' : 'missing'
      })
      
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
      
      console.log('Received binary metadata data:', {
        metadataId: headerMetadataId,
        metadataName,
        cellCount,
        binarySize: response.headers.get('content-length')
      })
      
      // Get the binary data as ArrayBuffer
      const arrayBuffer = await response.arrayBuffer()
      
      console.log('ArrayBuffer details:', {
        byteLength: arrayBuffer.byteLength,
        expectedLength: cellCount * 4, // 4 bytes per coordinate pair
        isValid: arrayBuffer.byteLength === cellCount * 4
      })
      
      // Log first few bytes for debugging
      const view = new Uint8Array(arrayBuffer)
      console.log('First 20 bytes of binary data:', Array.from(view.slice(0, 20)))
      console.log('Last 20 bytes of binary data:', Array.from(view.slice(-20)))
      
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
    
    console.log(`Stored binary metadata data for ${data.name}:`, {
      cellCount: data.cellCount,
      binarySize: binarySize,
      expectedSize: expectedSize,
      compressionRatio: compressionRatio.toFixed(2) + 'x',
      memoryEfficiency: ((1 - binarySize / (data.cellCount * 2 * 8)) * 100).toFixed(1) + '%'
    })
    
    // Update visualization with the new coordinate data
    this.updateVisualizationWithMetadata()
  }

  clearMetadataData() {
    this.metadataData = null
    console.log('Cleared metadata data')
    
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
    
    console.log('Updating visualization with metadata:', this.metadataData.name)
    
    // Decompress the binary coordinate data for visualization
    const decompressedCoords = this.decompressBinaryCoordinates(this.metadataData.binaryData)
    
    // Initialize PIXI.js scatter plot
    this.initializePixiScatterPlot(decompressedCoords)
    
    console.log(`Decompressed ${decompressedCoords.length} coordinate pairs for visualization`)
  }

  async initializePixiScatterPlot(coordinates) {
    try {
      // Check if PIXI.js is loaded globally
      if (typeof PIXI === 'undefined') {
        console.error('PIXI.js is not loaded. Please ensure the script tag is present.')
        return
      }

      console.log('Using global PIXI:', PIXI)
      console.log('PIXI.Application:', PIXI.Application)

      // Find the plot container
      const plotContainer = document.querySelector('.plot-container')
      if (!plotContainer) {
        console.error('Plot container not found')
        return
      }
      
      console.log('DEBUG: Checking conditions for updateScatterPlot')
      console.log('DEBUG: this.pixiApp exists:', !!this.pixiApp)
      console.log('DEBUG: this.currentLoomFile:', this.currentLoomFile)
      console.log('DEBUG: this.loomFileSelectTarget.value:', this.loomFileSelectTarget.value)
      console.log('DEBUG: Files match:', this.currentLoomFile === this.loomFileSelectTarget.value)
      
      // Check if we already have a PIXI app for this loom file
      if (this.pixiApp && this.currentLoomFile === this.loomFileSelectTarget.value) {
        console.log('Changing visualization coordinates - animating transition')
        // Clear selection since coordinates might have changed
        this.selectedCells.clear()
        this.updateSelectedCellsCount()
        // Use updateScatterPlot to animate coordinate changes
        await this.updateScatterPlot(coordinates)
        return
      }
      
      console.log('Creating new PIXI.js scatter plot')
      
      // Clear any existing PIXI app
      if (this.pixiApp) {
        this.pixiApp.destroy(true)
      }
      
      // Store PIXI reference for later use
      this.PIXI = PIXI
      
      // Use global PIXI.Application
      const Application = PIXI.Application
      
      console.log('Using Application constructor:', Application)
      
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
      
      // Hide placeholder and show plot info
      const placeholder = document.getElementById('plot-placeholder')
      const plotInfo = document.getElementById('plot-info')
      if (placeholder) placeholder.style.display = 'none'
      if (plotInfo) plotInfo.style.display = 'block'
      
      // Create main container for the scatter plot
      this.scatterContainer = new PIXI.Container()
      this.pixiApp.stage.addChild(this.scatterContainer)
      
      // Store current loom file
      this.currentLoomFile = this.loomFileSelectTarget.value
      
      // Render the scatter plot
      await this.renderScatterPlot(coordinates)
      
      // Add interaction handlers
      this.addInteractionHandlers()
      
      console.log('PIXI.js scatter plot initialized successfully')
      
    } catch (error) {
      console.error('Failed to initialize PIXI.js scatter plot:', error)
    }
  }

  async renderScatterPlot(coordinates) {
    if (!this.pixiApp || !this.scatterContainer || !this.PIXI) return
    
    // Clear existing points
    this.scatterContainer.removeChildren()
    
    // Calculate bounds for normalization
    const bounds = this.calculateBounds(coordinates)
    this.currentBounds = bounds // Store for future transitions
    this.currentCoordinates = coordinates // Store coordinates for future transitions
    console.log('Coordinate bounds:', bounds)
    
    // Set point properties
    const pointSize = 1
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
      
      this.scatterContainer.addChild(point)
    }
    
    console.log(`Rendered ${coordinates.length} individual points`)
    
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
    
    console.log('Updating scatter plot with new coordinates')
    console.log('Current bounds:', this.currentBounds)
    
    // Calculate new bounds
    const newBounds = this.calculateBounds(coordinates)
    console.log('New coordinate bounds:', newBounds)
    
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
    console.log('Using bounds for transition - from:', currentBounds, 'to:', newBounds)
    console.log('Previous coordinates count:', previousCoordinates.length, 'New coordinates count:', coordinates.length)
    
    // Check if bounds are actually different
    const boundsChanged = (
      Math.abs(currentBounds.minX - newBounds.minX) > 0.001 ||
      Math.abs(currentBounds.maxX - newBounds.maxX) > 0.001 ||
      Math.abs(currentBounds.minY - newBounds.minY) > 0.001 ||
      Math.abs(currentBounds.maxY - newBounds.maxY) > 0.001
    )
    
    if (!boundsChanged) {
      console.log('Bounds are the same, no transition needed - re-rendering points with new coordinates')
      // Clear existing individual points and re-render
      this.scatterContainer.removeChildren()
      
      // Re-render with new coordinates using current coloring
      this.renderPointsWithCurrentColoring()
      
      // Update point count display
      const pointCountElement = document.getElementById('point-count')
      if (pointCountElement) {
        pointCountElement.textContent = coordinates.length.toLocaleString()
      }
      return
    }
    
    console.log('Bounds are different, creating animated transition')
    
    // Clean up any existing animated container
    if (this.animatedContainer) {
      this.scatterContainer.removeChild(this.animatedContainer)
    }
    
    // Clear all existing individual points before animation
    this.scatterContainer.removeChildren()
    
    // Create individual point sprites for animation using previous coordinates
    this.createAnimatedPoints(previousCoordinates, coordinates, currentBounds, newBounds)
    
    console.log(`Created ${coordinates.length} animated points for transition`)
    
    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = coordinates.length.toLocaleString()
    }
  }

  // Update existing graphics object with current coloring scheme
  updatePointsWithCurrentColoring(graphics, coordinates, bounds) {
    const pointSize = 1

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
        
        console.log(`Updated ${coordinates.length} points with discrete metadata coloring (${this.currentMetadataVector.name})`)
        
      } else if (data_type === 'CONTINUOUS') {
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
        
        console.log(`Updated ${coordinates.length} points with continuous metadata coloring (${this.currentMetadataVector.name})`)
      }
    } else {
      // Render each point individually to support selection transparency
      console.log('Using default blue coloring')
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
    
    console.log(`Rendered ${coordinates.length} points with default blue color`)
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
        const colorMap = this.createDiscreteColorMap(compression_info.categories)
        baseColor = colorMap[value] || 0x3b82f6
      } else if (data_type === 'CONTINUOUS') {
        const minVal = compression_info.min_val
        const maxVal = compression_info.max_val
        const range = maxVal - minVal
        const normalizedValue = (value - minVal) / range
        baseColor = this.valueToColor(normalizedValue)
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
    console.log('Extracting current screen positions (recreating from bounds)')
    return currentBounds
  }

  createAnimatedPoints(previousCoordinates, newCoordinates, fromBounds, toBounds) {
    console.log('Creating animated points from previous to new coordinates')
    const pointSize = 1 // Keep same size as original plot
    const animationDuration = 4000 // 4 seconds for very smooth transition
    
    console.log('Creating animated points with current coloring scheme')
    
    // Create a container for animated points
    const animatedContainer = new this.PIXI.Container()
    this.scatterContainer.addChild(animatedContainer)
    this.animatedContainer = animatedContainer // Store reference for cleanup
    
    // Clear any existing individual points (they're already cleared by removeChildren() in updateScatterPlot)
    
    // Create individual point sprites
    const points = []
    let maxMovement = 0
    const minLength = Math.min(previousCoordinates.length, newCoordinates.length)
    
    for (let i = 0; i < minLength; i++) {
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
      
      animatedContainer.addChild(point)
      points.push({ sprite: point, startX, startY, endX, endY })
    }
    
    console.log(`Maximum point movement: ${maxMovement.toFixed(2)} pixels`)
    console.log(`Animation will run for ${animationDuration}ms`)
    
    // Animate all points
    const startTime = Date.now()
    
    const animate = () => {
      const elapsed = Date.now() - startTime
      const progress = Math.min(elapsed / animationDuration, 1)
      
      // Easing function for smooth animation
      const easeProgress = 1 - Math.pow(1 - progress, 3) // ease-out cubic
      
      // Log progress every 500ms
      if (Math.floor(elapsed / 500) !== Math.floor((elapsed - 16) / 500)) {
        console.log(`Animation progress: ${(progress * 100).toFixed(1)}% (${elapsed}ms)`)
      }
      
      // Update all point positions
      for (const point of points) {
        point.sprite.x = point.startX + (point.endX - point.startX) * easeProgress
        point.sprite.y = point.startY + (point.endY - point.startY) * easeProgress
      }
      
      if (progress < 1) {
        requestAnimationFrame(animate)
      } else {
        console.log('Animation complete!')
        // Animation complete, just keep the animated container
        // No need to convert back to graphics object - the animated points are already in final positions
        animatedContainer.visible = true // Ensure it's visible
        
        // Update stored coordinates and bounds for next transition
        this.currentBounds = toBounds
        this.currentCoordinates = newCoordinates
        
        console.log('Animation finished - keeping animated points in final positions')
      }
    }
    
    // Start animation
    animate()
  }

  convertToGraphicsObject(newCoordinates, bounds, animatedContainer) {
    console.log('Converting animated points back to efficient graphics object')
    
    // Remove animated container
    this.scatterContainer.removeChild(animatedContainer)
    
    // Create new efficient graphics object
    const graphics = new this.PIXI.Graphics()
    const pointSize = 1
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
        console.log(`Converted to efficient graphics object with ${newCoordinates.length} points`)
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

  normalizeX(x, bounds) {
    return ((x - bounds.minX) / (bounds.maxX - bounds.minX)) * this.pixiApp.screen.width
  }

  normalizeY(y, bounds) {
    return ((y - bounds.minY) / (bounds.maxY - bounds.minY)) * this.pixiApp.screen.height
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
    
    console.log('Starting binary decompression:', {
      arrayBufferSize: arrayBuffer.byteLength,
      expectedPairs: arrayBuffer.byteLength / 4
    })
    
    const coordinates = []
    const view = new DataView(arrayBuffer)
    
    // Process 4 bytes at a time (2 coordinates * 2 bytes each)
    for (let i = 0; i < arrayBuffer.byteLength; i += 4) {
      if (i + 3 < arrayBuffer.byteLength) {
        // Read 16-bit signed integers (little-endian)
        const x = view.getInt16(i, true)     // true = little-endian
        const y = view.getInt16(i + 2, true)
        
        // Convert back to original precision (divide by 1000)
        const xFloat = x / 1000
        const yFloat = y / 1000
        
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
      return this.loadedMetadataVectors[metadataId]
    }
    
    // Check if currently loading
    if (this.loadingMetadataVectors.has(metadataId)) {
      console.log(`Metadata vector ${metadataId} is currently loading, waiting...`)
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
      
      console.log(`Fetching single metadata vector from URL: ${url}`)
      
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
        this.loadedMetadataVectors[metadataId] = vectorData
        this.metadataVectorsLoomFile = data.loom_file
        
        const info = vectorData.compression_info
        console.log(`Successfully loaded metadata ${vectorData.name} (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
        
        return vectorData
      } else {
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
    
    console.log(`Retrieved loaded vector for ${vectorData.name}:`, vectorData.compression_info)
    return vectorData
  }

  // Decompress discrete metadata vector from binary data
  decompressDiscreteMetadataVector(binaryData, compressionInfo) {
    console.log('Decompressing discrete metadata vector:', compressionInfo)
    
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
      arrayBuffer = binaryData.buffer || binaryData
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
    console.log('Decompressing continuous metadata vector:', compressionInfo)
    
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
    
    console.log(`Decompressed ${cell_count} continuous values:`, {
      first10: numericValues.slice(0, 10),
      range: `${numericValues[0]?.toFixed(3)} to ${numericValues[cell_count-1]?.toFixed(3)}`,
      actualRange: `${Math.min(...numericValues).toFixed(3)} to ${Math.max(...numericValues).toFixed(3)}`
    })
    
    return numericValues
  }

  // Load and visualize metadata vector for a specific metadata ID
  async loadAndVisualizeMetadataVector(metadataId) {
    console.log(`Loading and visualizing metadata vector for ID: ${metadataId}`)
    
    // Load the metadata vector on-demand
    const vectorData = await this.loadSingleMetadataVector(metadataId)
    
    if (!vectorData) {
      console.error('Failed to load metadata vector')
      return
    }
    
    // Decompress the vector data based on type
    let values
    try {
      if (vectorData.data_type === 'DISCRETE') {
        values = this.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
      } else if (vectorData.data_type === 'CONTINUOUS') {
        values = this.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
      } else {
        console.error('Unknown data type:', vectorData.data_type)
        return
      }
    } catch (error) {
      console.error('Error decompressing metadata vector:', error)
      return
    }
    
    console.log(`Successfully decompressed ${values.length} values for ${vectorData.name}`)
    
    // Store the decompressed values for visualization
    this.currentMetadataVector = {
      id: metadataId,
      name: vectorData.name,
      data_type: vectorData.data_type,
      values: values,
      compression_info: vectorData.compression_info
    }
    
    // Update visualization with metadata coloring
    this.updateVisualizationWithMetadataVector()
  }

  // Load all metadata vectors in a single request
  async loadAllMetadataVectorsInSingleRequest() {
    console.log('=== LOADING ALL METADATA VECTORS IN SINGLE REQUEST ===')
    
    // Get all metadata IDs from the page
    const metadataElements = document.querySelectorAll('[data-metadata-item]')
    const metadataIds = Array.from(metadataElements).map(el => el.dataset.metadataItem)
    
    if (metadataIds.length === 0) {
      console.log('No metadata items found on page')
      return
    }
    
    console.log(`Found ${metadataIds.length} metadata items to load:`, metadataIds)
    
    try {
      // Get the current loom file
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : this.defaultLoomFileValue
      
      // Build the URL for the metadata vectors endpoint (single request for all)
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_vectors?metadata_ids=${metadataIds.join(',')}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      console.log('Fetching all metadata vectors in single request from URL:', url)
      
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
      console.log('Received all metadata vectors data:', data)
      
      // Store the loaded metadata vectors
      this.loadedMetadataVectors = data.metadata_vectors || {}
      this.metadataVectorsLoomFile = data.loom_file
      
      console.log(`Successfully loaded ${data.total_loaded} metadata vectors in single request`)
      
      // Log compression info for each loaded vector
      Object.entries(this.loadedMetadataVectors).forEach(([metadataId, vectorData]) => {
        const info = vectorData.compression_info
        console.log(`✓ ${vectorData.name} (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
      })
      
    } catch (error) {
      console.error('Error loading all metadata vectors in single request:', error)
      // Don't show alert for startup loading - just log the error
    }
  }

  // Load a single metadata vector silently (for preloading)
  async loadSingleMetadataVectorSilently(metadataId) {
    console.log(`=== LOADING SINGLE METADATA VECTOR SILENTLY: ${metadataId} ===`)
    
    // Check if already loaded
    if (this.loadedMetadataVectors[metadataId]) {
      console.log(`Metadata vector ${metadataId} already loaded`)
      return this.loadedMetadataVectors[metadataId]
    }
    
    // Check if currently loading
    if (this.loadingMetadataVectors.has(metadataId)) {
      console.log(`Metadata vector ${metadataId} is currently loading, waiting...`)
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
      
      console.log(`Fetching single metadata vector silently from URL: ${url}`)
      
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
      console.log('Received single metadata vector data silently:', data)
      
      // Store the loaded metadata vector
      const vectorData = data.metadata_vectors[metadataId]
      if (vectorData) {
        this.loadedMetadataVectors[metadataId] = vectorData
        this.metadataVectorsLoomFile = data.loom_file
        
        const info = vectorData.compression_info
        console.log(`Successfully loaded metadata ${vectorData.name} silently (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
        
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
      console.log(`Could not find water drop button for metadata ID: ${metadataId}`)
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
    
    console.log(`Showing loading spinner for metadata ${metadataId}`)
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
    
    console.log(`Hiding loading spinner for metadata ${metadataId}`)
  }

  // Preload metadata vector on hover for better UX
  preloadMetadataVector(event) {
    const button = event.currentTarget
    const metadataId = button.dataset.metadataId
    
    // Only preload if not already loaded and not currently loading
    if (!this.loadedMetadataVectors[metadataId] && !this.loadingMetadataVectors.has(metadataId)) {
      console.log(`Preloading metadata vector ${metadataId} on hover`)
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
    
    console.log(`Updating visualization with ${this.currentMetadataVector.name} (${this.currentMetadataVector.data_type})`)
    
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
    
    console.log(`Successfully colored ${this.currentCoordinates.length} points with ${this.currentMetadataVector.name}`)
  }

  // Render all points using the current coloring scheme
  renderPointsWithCurrentColoring() {
    if (!this.pixiApp || !this.scatterContainer || !this.currentCoordinates || !this.currentBounds) {
      console.log('Cannot render points - missing PIXI app or coordinates')
      return
    }

    // Clear existing points
    this.scatterContainer.removeChildren()
    
    const pointSize = 1

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
        
        console.log('Category frequencies for layering:', categoryFrequencies)
        
        // Sort point indices by category size (largest categories first, so they render in background)
        const sortedPointIndices = Array.from({ length: this.currentCoordinates.length }, (_, i) => i)
          .sort((a, b) => {
            const categoryA = values[a]
            const categoryB = values[b]
            const freqA = categoryFrequencies[categoryA]
            const freqB = categoryFrequencies[categoryB]
            return freqB - freqA // Descending order (largest first)
          })
        
        // Render points in sorted order (largest categories first)
        sortedPointIndices.forEach(i => {
          const [x, y] = this.currentCoordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, this.currentBounds)
          const screenY = this.normalizeY(y, this.currentBounds)
          
          // Create individual point graphics
          const point = new this.PIXI.Graphics()
          point.beginFill(color)
          point.alpha = alpha
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
        })
        
        // Update point count display
        this.updatePointCountDisplay(this.currentCoordinates.length, uniqueValues.length)
        
      } else if (data_type === 'CONTINUOUS') {
        // Render each point individually to support selection transparency and color reset
        for (let i = 0; i < this.currentCoordinates.length; i++) {
          const [x, y] = this.currentCoordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, this.currentBounds)
          const screenY = this.normalizeY(y, this.currentBounds)
          
          // Create individual point graphics
          const point = new this.PIXI.Graphics()
          point.beginFill(color)
          point.alpha = alpha
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
        
        // Update point count display
        this.updatePointCountDisplay(this.currentCoordinates.length, 'continuous')
      }
    } else {
      // Render each point individually to support selection transparency and color reset
      for (let i = 0; i < this.currentCoordinates.length; i++) {
        const [x, y] = this.currentCoordinates[i]
        const { color, alpha } = this.getColorAndAlpha(i)
        
        const screenX = this.normalizeX(x, this.currentBounds)
        const screenY = this.normalizeY(y, this.currentBounds)
        
        // Create individual point graphics
        const point = new this.PIXI.Graphics()
        point.beginFill(color)
        point.alpha = alpha
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
      
      // Update point count display
      const pointCountElement = document.getElementById('point-count')
      if (pointCountElement) {
        pointCountElement.textContent = `${this.currentCoordinates.length.toLocaleString()} points`
      }
    }
    
    console.log(`Rendered ${this.currentCoordinates.length} points with current coloring scheme`)
    
    // Clear any stored original positions since points were recreated
    this.clearStoredOriginalPositions()
  }

  // Color points for discrete metadata
  colorPointsDiscrete(values, compressionInfo) {
    console.log('Coloring points for discrete metadata:', {
      categories: compressionInfo.categories,
      uniqueCount: [...new Set(values)].length
    })
    
    const { categories } = compressionInfo
    const uniqueValues = [...new Set(values)]
    
    // Create color map for categories
    const colorMap = this.createDiscreteColorMap(categories)
    
    // Group points by category for efficient rendering
    const pointsByCategory = {}
    uniqueValues.forEach(value => {
      pointsByCategory[value] = []
    })
    
    // Group coordinates by their category values
    this.currentCoordinates.forEach((coord, index) => {
      const value = values[index]
      pointsByCategory[value].push(coord)
    })
    
    // Render points for each category
    Object.entries(pointsByCategory).forEach(([category, coords]) => {
      if (coords.length === 0) return
      
      const color = colorMap[category]
      const graphics = new this.PIXI.Graphics()
      
      graphics.beginFill(color)
      
      coords.forEach(([x, y]) => {
        const screenX = this.normalizeX(x, this.currentBounds)
        const screenY = this.normalizeY(y, this.currentBounds)
        graphics.drawCircle(screenX, screenY, 1)
      })
      
      graphics.endFill()
      this.scatterContainer.addChild(graphics)
    })
    
    // Update point count display
    this.updatePointCountDisplay(this.currentCoordinates.length, uniqueValues.length)
  }

  // Color points for continuous metadata
  colorPointsContinuous(values, compressionInfo) {
    console.log('Coloring points for continuous metadata:', {
      range: `${compressionInfo.min_val} to ${compressionInfo.max_val}`,
      actualRange: `${Math.min(...values).toFixed(3)} to ${Math.max(...values).toFixed(3)}`
    })
    
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
      graphics.drawCircle(screenX, screenY, 1)
      graphics.endFill()
    })
    
    this.scatterContainer.addChild(graphics)
    
    // Update point count display
    this.updatePointCountDisplay(this.currentCoordinates.length, 'continuous')
  }

  // Create color map for discrete categories
  createDiscreteColorMap(categories) {
    const colors = [
      0x1f77b4, // blue
      0xff7f0e, // orange
      0x2ca02c, // green
      0x9467bd, // purple
      0x8c564b, // brown
      0xe377c2, // pink
      0x7f7f7f, // gray
      0xbcbd22, // olive
      0x17becf, // cyan
      0x4ecdc4, // teal
      0x45b7d1, // light blue
      0x96ceb4, // mint
      0xfeca57, // yellow
      0xff9ff3, // magenta
      0x9b59b6, // violet
      0x3498db, // sky blue
      0x2ecc71, // emerald
      0xf39c12, // carrot
    ]
    
    const colorMap = {}
    categories.forEach((category, index) => {
      colorMap[category] = colors[index % colors.length]
    })
    
    console.log('Created discrete color map:', colorMap)
    return colorMap
  }

  // Convert normalized value (0-1) to color
  valueToColor(normalizedValue) {
    // Clamp to 0-1 range
    const clamped = Math.max(0, Math.min(1, normalizedValue))
    
    // Blue to red gradient
    if (clamped < 0.5) {
      // Blue to green
      const t = clamped * 2
      const r = Math.round(0 * (1 - t) + 0 * t)
      const g = Math.round(0 * (1 - t) + 255 * t)
      const b = Math.round(255 * (1 - t) + 0 * t)
      return (r << 16) | (g << 8) | b
    } else {
      // Green to red
      const t = (clamped - 0.5) * 2
      const r = Math.round(0 * (1 - t) + 255 * t)
      const g = Math.round(255 * (1 - t) + 0 * t)
      const b = Math.round(0 * (1 - t) + 0 * t)
      return (r << 16) | (g << 8) | b
    }
  }

  // Update point count display
  updatePointCountDisplay(totalPoints, categoriesOrType) {
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      if (typeof categoriesOrType === 'number') {
        pointCountElement.textContent = `${totalPoints.toLocaleString()} points, ${categoriesOrType} categories`
      } else {
        pointCountElement.textContent = `${totalPoints.toLocaleString()} points (${categoriesOrType})`
      }
    }
  }

  // Clear metadata coloring and return to default blue points
  clearMetadataColoring() {
    if (!this.pixiApp || !this.scatterContainer || !this.currentCoordinates || !this.currentBounds) {
      console.log('Cannot clear coloring - missing PIXI app or coordinates')
      return
    }
    
    console.log('Clearing metadata coloring, returning to default blue points')
    
    // Clear current metadata vector
    this.currentMetadataVector = null
    
    // Clear existing colored points and re-render with default coloring
    this.forceReRenderPoints()
    
    console.log('Successfully cleared metadata coloring')
  }

  toggleDropdown(event) {
     console.log('toggleDropdown called')
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
    console.log('Edit metadata:', metadataId)
    // TODO: Implement edit functionality
    alert(`Edit metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  exportMetadata(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    console.log('Export metadata:', metadataId)
    // TODO: Implement export functionality
    alert(`Export metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  duplicateMetadata(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    console.log('Duplicate metadata:', metadataId)
    // TODO: Implement duplicate functionality
    alert(`Duplicate metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  viewCategories(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    console.log('View categories for metadata:', metadataId)
    // TODO: Implement view categories functionality
    alert(`View categories for metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  viewStatistics(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    console.log('View statistics for metadata:', metadataId)
    // TODO: Implement view statistics functionality
    alert(`View statistics for metadata ${metadataId}`)
    this.closeAllDropdowns()
  }

  deleteMetadata(event) {
    event.preventDefault()
    const metadataId = event.currentTarget.dataset.metadataId
    console.log('Delete metadata:', metadataId)
    
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
    const categoriesDiv = headerElement.nextElementSibling
    const radioInput = headerElement.querySelector('input[type="radio"]')
    
    if (!chevron || !categoriesDiv || !radioInput) {
      console.error('Required elements not found')
      return
    }
    
    // Toggle the chevron rotation
    const isExpanding = chevron.style.transform === '' || chevron.style.transform === 'rotate(0deg)'
    
    if (isExpanding) {
      chevron.style.transform = 'rotate(90deg)'
      categoriesDiv.style.display = 'block'
      
      // Load metadata vector when expanding categories (for future coloring)
      const metadataItem = headerElement.closest('[data-metadata-item]')
      if (metadataItem) {
        const metadataId = metadataItem.dataset.metadataItem
        console.log(`Loading metadata vector for ${metadataId} on category expansion`)
        
        // Load silently in background (no spinner for category expansion)
        this.loadSingleMetadataVectorSilently(metadataId).catch(error => {
          console.log(`Failed to load metadata vector ${metadataId} on expansion:`, error.message)
        })
      }
    } else {
      chevron.style.transform = 'rotate(0deg)'
      categoriesDiv.style.display = 'none'
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
    
    console.log('Elements found:', { divider, discretePanel, continuousPanel, container })
    
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
      
      console.log('Dragging:', { deltaY, newHeight, containerHeight, constrainedHeight, heightPercentage })
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
    
    console.log('Draggable divider initialized')
  }

  // Handle water drop button clicks
  waterDropClicked(event) {
    console.log('=== WATER DROP CLICKED ===')
    console.log('Event:', event)
    console.log('Event target:', event.target)
    console.log('Event currentTarget:', event.currentTarget)
    
    event.preventDefault()
    event.stopPropagation()
    
    const button = event.currentTarget
    const metadataName = button.dataset.metadataName
    const metadataId = button.dataset.metadataId
    const isCurrentlyActive = button.dataset.active === 'true'
    
    console.log('Button element:', button)
    console.log('Metadata name:', metadataName)
    console.log('Metadata ID:', metadataId)
    console.log('Is currently active:', isCurrentlyActive)
    console.log('Button dataset:', button.dataset)
    
    if (isCurrentlyActive) {
      // Button is already active - deselect it
      console.log('Button is already active - deselecting...')
      this.resetAllWaterDropButtons()
      this.removeAllCategoryColors()
      this.clearMetadataColoring()
      console.log('=== DESELECTION COMPLETE ===')
      return
    }
    
    // Button is not active - select it
    // 1. Reset all water drop buttons to grey (cancel previous associations)
    console.log('Step 1: Resetting all water drop buttons...')
    this.resetAllWaterDropButtons()
    
    // 2. Remove all existing colored disks from all metadata
    console.log('Step 2: Removing all existing category colors...')
    this.removeAllCategoryColors()
    
    // 3. Set this button to blue (active)
    console.log('Step 3: Setting this button as active...')
    this.setWaterDropButtonActive(button)
    
    // 4. Find the metadata item container and add colored categories
    console.log('Step 4: Finding metadata container...')
    const metadataContainer = button.closest('[data-metadata-item]')
    console.log('Metadata container found:', metadataContainer)
    
    if (metadataContainer) {
      console.log('Step 5: Adding category colors...')
      this.addCategoryColors(metadataContainer, metadataId)
      
      // 6. Load and visualize metadata vector if available
      console.log('Step 6: Loading metadata vector for visualization...')
      this.loadAndVisualizeMetadataVector(metadataId)
    } else {
      console.error('ERROR: Could not find metadata container!')
    }
    
    console.log('=== WATER DROP CLICK COMPLETE ===')
  }
  
  // Reset all water drop buttons to grey
  resetAllWaterDropButtons() {
    console.log('resetAllWaterDropButtons: Starting...')
    const allButtons = document.querySelectorAll('[data-action*="waterDropClicked"]')
    console.log('resetAllWaterDropButtons: Found', allButtons.length, 'buttons')
    allButtons.forEach((button, index) => {
      console.log(`resetAllWaterDropButtons: Resetting button ${index}:`, button)
      button.style.color = '#9ca3af'
      button.style.backgroundColor = ''
      button.dataset.active = 'false'
    })
    console.log('resetAllWaterDropButtons: Complete')
  }
  
  // Set a water drop button to active (blue)
  setWaterDropButtonActive(button) {
    console.log('setWaterDropButtonActive: Setting button as active:', button)
    button.style.color = '#3b82f6'
    button.style.backgroundColor = '#dbeafe'
    button.dataset.active = 'true'
    console.log('setWaterDropButtonActive: Button now has color:', button.style.color)
  }
  
  // Remove all category colors from all metadata
  removeAllCategoryColors() {
    console.log('removeAllCategoryColors: Starting...')
    const allColorDisks = document.querySelectorAll('.category-color-disk')
    console.log('removeAllCategoryColors: Found', allColorDisks.length, 'existing color disks')
    allColorDisks.forEach((disk, index) => {
      console.log(`removeAllCategoryColors: Removing disk ${index}:`, disk)
      disk.remove()
    })
    console.log('removeAllCategoryColors: Complete')
  }
  
  // Add colored disks to categories
  addCategoryColors(metadataContainer, metadataId) {
    console.log('Adding category colors for metadata:', metadataId)
    
    // Remove existing category colors
    const existingColors = metadataContainer.querySelectorAll('.category-color-disk')
    existingColors.forEach(color => color.remove())
    
    // First, make sure the categories are expanded
    const chevron = metadataContainer.querySelector('svg')
    const categoriesDiv = metadataContainer.querySelector('[style*="padding-left: 32px"]')
    
    if (chevron && chevron.style.transform !== 'rotate(90deg)') {
      console.log('Expanding categories first...')
      // Directly expand the categories
      chevron.style.transform = 'rotate(90deg)'
      if (categoriesDiv) {
        categoriesDiv.style.display = 'block'
      }
    }
    
    // Wait a bit for the categories to expand, then add colors
    setTimeout(() => {
      // Find categories container
      const categoriesContainer = metadataContainer.querySelector('[style*="padding-left: 32px"]')
      console.log('Categories container found:', categoriesContainer)
      
      if (!categoriesContainer || categoriesContainer.style.display === 'none') {
        console.log('Categories container not found or hidden')
        return
      }
      
      // Get categories data
      const categories = this.getCategoriesForMetadata(metadataId)
      console.log('Categories data:', categories)
      
      if (!categories || categories.length === 0) {
        console.log('No categories found')
        return
      }
    
    // Add colored disks to each category
    const categoryItems = categoriesContainer.querySelectorAll('div[style*="display: flex; justify-content: space-between"]')
    categoryItems.forEach((item, index) => {
      // Set up the container for absolute positioning
      item.style.position = 'relative'
      item.style.paddingLeft = '20px' // Make space for the color disk
      
      const categoryName = item.querySelector('span').textContent.trim()
      const color = this.getCategoryColor(categoryName, index, metadataId)
      
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
  
  // Get color for a category (with default colors)
  getCategoryColor(categoryName, index, metadataId) {
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
    
    // Check if we have a stored color for this category in this specific metadata
    const storageKey = `category_color_${metadataId}_${categoryName}`
    const storedColor = localStorage.getItem(storageKey)
    return storedColor || defaultColors[index % defaultColors.length]
  }
  
  // Show color picker form
  showColorPicker(colorDisk, categoryName, metadataId) {
    // Remove existing color picker
    const existingPicker = document.getElementById('color-picker-form')
    if (existingPicker) {
      existingPicker.remove()
    }
    
    // Create color picker form
    const picker = document.createElement('div')
    picker.id = 'color-picker-form'
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
  changeInteractionMode(event) {
    const mode = event.target.value
    console.log('Changing interaction mode to:', mode)
    
    this.interactionMode = mode
    
    // Clear any existing interaction state
    this.clearLasso()
    this.stopPanning()
    
    // Update cursor based on mode
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (canvas) {
      if (mode === 'lasso') {
        canvas.style.cursor = 'crosshair'
      } else if (mode === 'pan') {
        canvas.style.cursor = 'grab'
      }
    }
    
    // Remove existing event listeners and add new ones
    this.removeInteractionEventListeners()
    this.addInteractionEventListeners()
  }

  addInteractionEventListeners() {
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) {
      console.log('❌ No canvas available for interaction listeners')
      return
    }
    
    console.log('✅ Adding interaction event listeners to canvas')
    
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
    
    console.log('✅ Event listeners added:', {
      mousedown: !!this.boundMouseDown,
      mousemove: !!this.boundMouseMove,
      mouseup: !!this.boundMouseUp,
      wheel: !!this.boundWheel,
      dblclick: !!this.boundDoubleClick
    })
    
    // Set initial cursor
    if (this.interactionMode === 'pan') {
      canvas.style.cursor = 'grab'
      console.log('🎯 Set cursor to grab (pan mode)')
    } else if (this.interactionMode === 'lasso') {
      canvas.style.cursor = 'crosshair'
      console.log('🎯 Set cursor to crosshair (lasso mode)')
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
    console.log('🖱️ Mouse down event:', this.interactionMode)
    if (this.interactionMode === 'lasso') {
      this.onLassoMouseDown(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanMouseDown(event)
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
    console.log('🖱️ Double-click event:', this.interactionMode)
    if (this.interactionMode === 'lasso') {
      this.onLassoDoubleClick(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanDoubleClick(event)
    }
  }

  onInteractionWheel(event) {
    console.log('🔄 Wheel event:', event.deltaY, 'isPanning:', this.isPanning, 'interactionMode:', this.interactionMode)
    
    // Don't zoom if we're currently panning (but allow zoom in pan mode when not actively panning)
    if (this.isPanning) {
      console.log('🚫 Ignoring wheel event during active panning')
      return
    }
    
    // Zoom functionality
    event.preventDefault()
    
    if (!this.currentCoordinates || !this.currentBounds) {
      console.log('❌ No data available for zoom')
      return
    }
    
    console.log('✅ Zooming with data available')
    
    // Get mouse position relative to canvas
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    const rect = canvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    
    // Basic zoom implementation
    const delta = event.deltaY > 0 ? 1.1 : 0.9
    const centerX = (this.currentBounds.minX + this.currentBounds.maxX) / 2
    const centerY = (this.currentBounds.minY + this.currentBounds.maxY) / 2
    
    const newBounds = {
      minX: centerX - (centerX - this.currentBounds.minX) * delta,
      maxX: centerX + (this.currentBounds.maxX - centerX) * delta,
      minY: centerY - (centerY - this.currentBounds.minY) * delta,
      maxY: centerY + (this.currentBounds.maxY - centerY) * delta
    }
    
    console.log('🔄 Zoom: Updating bounds to:', newBounds, 'Mouse position:', { mouseX, mouseY })
    
    // Store the old bounds for translation calculation
    const oldBounds = { ...this.currentBounds }
    
    // Update current bounds
    this.currentBounds = newBounds
    
    // Use translation approach like pan mode, centered on mouse position
    this.translatePointsForZoom(oldBounds, newBounds, mouseX, mouseY)
  }

  // Lasso mode handlers
  onLassoMouseDown(event) {
    console.log('Lasso mouse down')
    this.isDrawingLasso = true
    this.lassoPoints = []
    
    // Get mouse position relative to canvas
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    
    this.lassoPoints.push({ x, y })
    
    // Create lasso graphics object
    this.lassoGraphics = new this.PIXI.Graphics()
    this.pixiApp.stage.addChild(this.lassoGraphics)
  }

  onLassoMouseMove(event) {
    if (!this.isDrawingLasso) return
    
    // Get mouse position relative to canvas
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    
    this.lassoPoints.push({ x, y })
    this.updateLassoGraphics()
  }

  onLassoMouseUp(event) {
    if (!this.isDrawingLasso) return
    
    console.log('Lasso mouse up - completing selection')
    this.isDrawingLasso = false
    
    // Only proceed if we have a PIXI app and coordinates to work with
    if (!this.pixiApp || !this.currentCoordinates) {
      console.log('No PIXI app or coordinates available for lasso selection')
      this.clearLasso()
      return
    }
    
    // Complete the lasso by closing the path
    if (this.lassoPoints.length > 2) {
      this.lassoPoints.push(this.lassoPoints[0]) // Close the loop
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
    console.log('Pan mouse down')
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
    
    // Convert screen delta to data delta
    const canvasWidth = canvas.width
    const canvasHeight = canvas.height
    
    // Use current bounds for pan calculation to match current view
    const dataDeltaX = (deltaX / canvasWidth) * (this.panStartBounds.maxX - this.panStartBounds.minX)
    const dataDeltaY = (deltaY / canvasHeight) * (this.panStartBounds.maxY - this.panStartBounds.minY)
    
    // Update bounds
    const newBounds = {
      minX: this.panStartBounds.minX - dataDeltaX,
      maxX: this.panStartBounds.maxX - dataDeltaX,
      minY: this.panStartBounds.minY - dataDeltaY, // Invert Y axis
      maxY: this.panStartBounds.maxY - dataDeltaY
    }
    
    // Debug: Check if bounds are changing size (indicating zoom)
    const startWidth = this.panStartBounds.maxX - this.panStartBounds.minX
    const startHeight = this.panStartBounds.maxY - this.panStartBounds.minY
    const newWidth = newBounds.maxX - newBounds.minX
    const newHeight = newBounds.maxY - newBounds.minY
    
    console.log('🔄 Pan Debug:', {
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
    })
    
    // Update visualization with new bounds
    console.log('🔄 Pan: Updating bounds to:', newBounds)
    this.updateVisualizationBounds(newBounds)
  }

  onPanMouseUp(event) {
    if (!this.isPanning) return
    
    console.log('Pan mouse up')
    this.stopPanning()
  }

  stopPanning() {
    this.isPanning = false
    this.panStartX = 0
    this.panStartY = 0
    this.panStartBounds = null
    this.panOriginalBounds = null
    
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
    console.log('🔄 Pan mode double-click: Resetting zoom and pan')
    this.resetZoomAndPan()
  }

  onLassoDoubleClick(event) {
    console.log('❌ Lasso mode double-click: Canceling current selection')
    this.cancelSelection()
  }




  // Reset zoom and pan to original view
  resetZoomAndPan() {
    if (!this.currentCoordinates) {
      console.log('❌ No data available for reset')
      return
    }

    console.log('🔄 Resetting to original view')
    
    // Clear any stored original positions to force re-rendering
    this.clearStoredOriginalPositions()
    
    // Reset to original bounds
    const originalBounds = this.calculateBounds(this.currentCoordinates)
    this.currentBounds = originalBounds
    
    // Force re-render all points with original bounds
    this.scatterContainer.removeChildren()
    this.renderPointsWithCurrentColoring()
    
    console.log('✅ Zoom and pan reset to original view')
  }

  updateVisualizationBounds(newBounds) {
    console.log('🔄 updateVisualizationBounds called with:', newBounds)
    this.currentBounds = newBounds
    
    // Update existing point positions instead of re-rendering
    if (this.currentCoordinates && this.scatterContainer) {
      this.updatePointPositions()
    } else {
      console.log('❌ Cannot update positions - missing data')
    }
  }

  // Optimized method to update point positions without re-rendering
  updatePointPositions() {
    if (!this.currentCoordinates || !this.currentBounds || !this.scatterContainer) {
      console.log('❌ Cannot update positions - missing data:', {
        coordinates: !!this.currentCoordinates,
        bounds: !!this.currentBounds,
        container: !!this.scatterContainer
      })
      return
    }

    console.log('🔄 Updating point positions:', {
      pointCount: this.scatterContainer.children.length,
      coordinateCount: this.currentCoordinates.length
    })

    // For pan operations, we should just translate existing positions
    // For zoom operations, we need to recalculate from coordinates (scale change)
    if (this.isPanning && this.panStartBounds) {
      console.log('🔄 Panning: Translating existing positions')
      this.translatePointPositions()
      return
    }

    // Cache bounds calculations for performance
    const bounds = this.currentBounds
    const width = bounds.maxX - bounds.minX
    const height = bounds.maxY - bounds.minY

    let updatedCount = 0

    // Helper function to update points in a container
    const updatePointsInContainer = (container, containerName) => {
      container.children.forEach((child, index) => {
        // Debug: Check what we're working with
        if (index < 3) {
          console.log(`${containerName} Point ${index}:`, {
            isPoint: child.isPoint,
            cellId: child.cellId,
            hasPosition: child.x !== undefined && child.y !== undefined
          })
        }

        // Try to update if it's a point with cellId
        if (child.isPoint && child.cellId !== undefined && child.cellId < this.currentCoordinates.length) {
          const [x, y] = this.currentCoordinates[child.cellId]
          
          // Optimized normalization (avoid function calls)
          const normalizedX = (x - bounds.minX) / width
          const normalizedY = (y - bounds.minY) / height
          
          // Convert to screen coordinates
          const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
          if (canvas) {
            child.x = normalizedX * canvas.width
            child.y = normalizedY * canvas.height
            updatedCount++
          }
        }
      })
    }

    // Update positions of existing points in scatterContainer (direct children)
    updatePointsInContainer(this.scatterContainer, 'Direct')
    
    // Also check for points in animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      console.log('Found animatedContainer with', this.animatedContainer.children.length, 'children')
      updatePointsInContainer(this.animatedContainer, 'Animated')
    }

    console.log(`✅ Updated ${updatedCount} point positions`)
    
    // Fallback: If no points were updated, fall back to re-rendering
    if (updatedCount === 0 && this.scatterContainer.children.length > 0) {
      console.log('⚠️ No points updated, falling back to re-rendering')
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

    console.log('🔄 Pan Translation:', { deltaX, deltaY })

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
      console.log('Found animatedContainer with', this.animatedContainer.children.length, 'children for pan translation')
      translatePointsInContainer(this.animatedContainer, 'Animated')
    }

    // Don't update panStartBounds - keep original reference for sharp direction changes
    // this.panStartBounds = { ...this.currentBounds }

    console.log(`✅ Pan translated ${translatedCount} point positions`)
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

    console.log('🔄 Zoom Translation:', { scaleX, scaleY, centerX, centerY, mouseX, mouseY })

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
      console.log('Found animatedContainer with', this.animatedContainer.children.length, 'children for zoom translation')
      translatePointsInContainer(this.animatedContainer, 'Animated')
    }

    console.log(`✅ Zoom translated ${translatedCount} point positions`)
  }

  // Clear stored original positions (called when coordinates change)
  clearStoredOriginalPositions() {
    console.log('🧹 Clearing stored original positions')
    
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
      this.scatterContainer.removeChildren()
      this.renderPointsWithCurrentColoring()
    }
  }

  updateLassoGraphics() {
    if (!this.lassoGraphics || this.lassoPoints.length < 2) return
    
    this.lassoGraphics.clear()
    this.lassoGraphics.lineStyle(2, 0x3b82f6, 0.8) // Blue line
    this.lassoGraphics.beginFill(0x3b82f6, 0.1) // Light blue fill
    
    this.lassoGraphics.moveTo(this.lassoPoints[0].x, this.lassoPoints[0].y)
    for (let i = 1; i < this.lassoPoints.length; i++) {
      this.lassoGraphics.lineTo(this.lassoPoints[i].x, this.lassoPoints[i].y)
    }
    
    this.lassoGraphics.endFill()
  }

  selectPointsInLasso() {
    if (!this.currentCoordinates || this.lassoPoints.length < 3) return
    
    console.log(`Checking ${this.currentCoordinates.length} points against lasso selection`)
    
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
    
    console.log(`Selected ${selectedIndices.length} cells with lasso`)
    
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
    
    console.log('🎨 Updating selected point colors without re-rendering')
    
    // Update colors in scatterContainer
    this.scatterContainer.children.forEach((child) => {
      if (child.isPoint && child.cellId !== undefined) {
        if (this.selectedCells.has(child.cellId)) {
          // Set selected color (red) by clearing and redrawing
          child.clear()
          child.beginFill(0xff0000) // Pure red
          child.drawCircle(0, 0, 1) // Same size as original
          child.endFill()
        } else {
          // Restore original color
          const originalColor = this.originalPointColors.get(child.cellId)
          if (originalColor !== undefined) {
            child.clear()
            child.beginFill(originalColor)
            child.drawCircle(0, 0, 1) // Same size as original
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
            child.drawCircle(0, 0, 1) // Same size as original
            child.endFill()
          } else {
            // Restore original color
            const originalColor = this.originalPointColors.get(child.cellId)
            if (originalColor !== undefined) {
              child.clear()
              child.beginFill(originalColor)
              child.drawCircle(0, 0, 1) // Same size as original
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
      this.pixiApp.stage.removeChild(this.lassoGraphics)
      this.lassoGraphics = null
    }
    this.lassoPoints = []
    this.isDrawingLasso = false
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
    console.log('Switching to tab:', tab)
    
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

  // Save selection method
  saveSelection() {
    console.log('💾 Saving selection:', this.selectedCells.size, 'cells')
    
    if (this.selectedCells.size === 0) {
      alert('No cells selected to save')
      return
    }
    
    // Here you would typically save the selection to a backend or local storage
    // For now, we'll just show a success message
    const selectionName = prompt('Enter a name for this selection:')
    if (selectionName) {
      console.log(`Selection "${selectionName}" saved with ${this.selectedCells.size} cells`)
      // TODO: Implement actual saving logic (API call, local storage, etc.)
      alert(`Selection "${selectionName}" saved successfully!`)
    }
  }

  // Cancel selection method - resets points to original colors
  cancelSelection() {
    console.log('❌ Canceling selection, resetting to original colors')
    
    // Clear the selected cells
    this.selectedCells.clear()
    
    // Update colors without re-rendering (preserves pan/zoom state)
    this.updateSelectedPointColors()
    
    // Update the cell count display
    this.updateSelectedCellsCount()
    
    // Clear any lasso graphics
    if (this.lassoGraphics) {
      this.lassoGraphics.clear()
      this.lassoGraphics = null
    }
    
    console.log('✅ Selection canceled, points reset to original colors')
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
    if (countElement) {
      countElement.textContent = this.selectedCells.size
    }
  }
}
