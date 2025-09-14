import { Controller } from "@hotwired/stimulus"

console.log('Visualization controller file loaded - VERSION 2.0 WITH NEW LOGGING')

export default class extends Controller {
  static targets = ["loomFileSelect", "embeddingSelect", "metadataSelect"]
  static values = { 
    embeddingsByLoom: Object,
    defaultLoomFile: String
  }

  connect() {
    console.log('Visualization controller connected')
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
  }

  disconnect() {
    // Remove click outside listener when controller disconnects
    if (this.boundCloseDropdowns) {
      document.removeEventListener('click', this.boundCloseDropdowns)
    }
  }
  
  testAction() {
    alert('Stimulus controller is working!')
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
        console.log('Updating existing plot with new coordinates for same loom file')
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
    
    // Create graphics for efficient rendering
    const graphics = new PIXI.Graphics()
    
    // Set point properties
    const pointSize = 1
    const pointColor = 0x3b82f6 // Blue color
    
    // Render points in batches for performance
    const batchSize = 10000
    let currentBatch = 0
    
    const renderBatch = () => {
      const start = currentBatch * batchSize
      const end = Math.min(start + batchSize, coordinates.length)
      
      graphics.beginFill(pointColor)
      
      for (let i = start; i < end; i++) {
        const [x, y] = coordinates[i]
        
        // Normalize coordinates to screen space
        const screenX = this.normalizeX(x, bounds)
        const screenY = this.normalizeY(y, bounds)
        
        // Draw point
        graphics.drawCircle(screenX, screenY, pointSize)
      }
      
      graphics.endFill()
      
      currentBatch++
      
      if (end < coordinates.length) {
        // Continue with next batch
        requestAnimationFrame(renderBatch)
      } else {
        // All points rendered, add to stage
        this.scatterContainer.addChild(graphics)
        console.log(`Rendered ${coordinates.length} points in ${currentBatch} batches`)
        
        // Update point count display
        const pointCountElement = document.getElementById('point-count')
        if (pointCountElement) {
          pointCountElement.textContent = coordinates.length.toLocaleString()
        }
      }
    }
    
    // Start rendering
    renderBatch()
  }

  async updateScatterPlot(coordinates) {
    if (!this.pixiApp || !this.scatterContainer || !this.PIXI) return
    
    console.log('Updating scatter plot with new coordinates')
    console.log('Current bounds:', this.currentBounds)
    
    // Calculate new bounds
    const newBounds = this.calculateBounds(coordinates)
    console.log('New coordinate bounds:', newBounds)
    
    // Get existing graphics object
    const existingGraphics = this.scatterContainer.children[0]
    if (!existingGraphics) {
      console.log('No existing graphics found, falling back to full render')
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
      console.log('Bounds are the same, no transition needed')
      // Just update the points without animation
      existingGraphics.clear()
      const pointSize = 1
      const pointColor = 0x3b82f6
      
      existingGraphics.beginFill(pointColor)
      for (let i = 0; i < coordinates.length; i++) {
        const [x, y] = coordinates[i]
        const screenX = this.normalizeX(x, newBounds)
        const screenY = this.normalizeY(y, newBounds)
        existingGraphics.drawCircle(screenX, screenY, pointSize)
      }
      existingGraphics.endFill()
      
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
    
    // Create individual point sprites for animation using previous coordinates
    this.createAnimatedPoints(previousCoordinates, coordinates, currentBounds, newBounds, existingGraphics)
    
    console.log(`Created ${coordinates.length} animated points for transition`)
    
    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = coordinates.length.toLocaleString()
    }
  }

  extractCurrentScreenPositions(existingGraphics, currentBounds, coordinateCount) {
    // Since we can't easily extract positions from a PIXI Graphics object,
    // we'll recreate the positions using the current bounds and coordinates
    // This is a limitation of PIXI Graphics - we need to store positions differently
    console.log('Extracting current screen positions (recreating from bounds)')
    return currentBounds
  }

  createAnimatedPoints(previousCoordinates, newCoordinates, fromBounds, toBounds, existingGraphics) {
    console.log('Creating animated points from previous to new coordinates')
    const pointSize = 1 // Keep same size as original plot
    const pointColor = 0x3b82f6 // Keep same blue color as original plot
    const animationDuration = 4000 // 4 seconds for very smooth transition
    
    // Create a container for animated points
    const animatedContainer = new this.PIXI.Container()
    this.scatterContainer.addChild(animatedContainer)
    this.animatedContainer = animatedContainer // Store reference for cleanup
    
    // Remove old graphics object after animation container is added (no gap)
    if (existingGraphics) {
      this.scatterContainer.removeChild(existingGraphics)
    }
    
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
      
      // Create point sprite
      const point = new this.PIXI.Graphics()
      point.beginFill(pointColor)
      point.drawCircle(0, 0, pointSize)
      point.endFill()
      
      // Set initial position
      point.x = startX
      point.y = startY
      
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
    
    // Add zoom and pan functionality
    let isDragging = false
    let dragStart = { x: 0, y: 0 }
    
    // Mouse/touch events for panning
    this.pixiApp.stage.on('pointerdown', (event) => {
      isDragging = true
      dragStart = { x: event.data.global.x, y: event.data.global.y }
    })
    
    this.pixiApp.stage.on('pointermove', (event) => {
      if (isDragging) {
        const dx = event.data.global.x - dragStart.x
        const dy = event.data.global.y - dragStart.y
        
        this.scatterContainer.x += dx
        this.scatterContainer.y += dy
        
        dragStart = { x: event.data.global.x, y: event.data.global.y }
      }
    })
    
    this.pixiApp.stage.on('pointerup', () => {
      isDragging = false
    })
    
    // Wheel event for zooming
    this.pixiApp.view.addEventListener('wheel', (event) => {
      event.preventDefault()
      
      const zoomFactor = event.deltaY > 0 ? 0.9 : 1.1
      const mouseX = event.clientX - this.pixiApp.view.getBoundingClientRect().left
      const mouseY = event.clientY - this.pixiApp.view.getBoundingClientRect().top
      
      // Zoom towards mouse position
      this.scatterContainer.scale.x *= zoomFactor
      this.scatterContainer.scale.y *= zoomFactor
      
      // Clamp zoom levels
      this.scatterContainer.scale.x = Math.max(0.1, Math.min(10, this.scatterContainer.scale.x))
      this.scatterContainer.scale.y = Math.max(0.1, Math.min(10, this.scatterContainer.scale.y))
    })
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
  toggleMetadata(event) {
    const headerElement = event.currentTarget
    const chevron = headerElement.querySelector('svg')
    const categoriesDiv = headerElement.nextElementSibling
    const radioInput = headerElement.querySelector('input[type="radio"]')
    
    if (!chevron || !categoriesDiv || !radioInput) {
      console.error('Required elements not found')
      return
    }
    
    // Toggle the chevron rotation
    if (chevron.style.transform === '' || chevron.style.transform === 'rotate(0deg)') {
      chevron.style.transform = 'rotate(90deg)'
      categoriesDiv.style.display = 'block'
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
}
