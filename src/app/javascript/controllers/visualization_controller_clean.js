import { Controller } from "@hotwired/stimulus"
import { ReglRenderer } from "visualization/regl_renderer"

console.log('Visualization controller file loaded - REGL ONLY VERSION')

export default class extends Controller {
  static targets = ["loomFileSelect", "embeddingSelect", "metadataSelect"]
  static values = { 
    embeddingsByLoom: Object,
    defaultLoomFile: String
  }

  connect() {
    console.log('🚀 Visualization controller connected')
    
    // RENDERER CHOICE: RegL only
    this.rendererType = 'regl'
    this.reglRenderer = null
    
    // Initialize IndexedDB for storing metadata on disk instead of memory
    this.initializeIndexedDB()
    
    // Initialize memory management
    this.binaryDataCache = new Map()
    this.loadedMetadataVectors = {}
    this.metadataUsageTracker = new Map()
    
    // Initialize interaction state
    this.selectedCells = new Set()
    this.interactionMode = 'pan'
    
    // Initialize metadata state
    this.currentMetadataVector = null
    this.selectedCategories = {}
    this.selectedRanges = {}
    
    // Initialize rendering state
    this.currentBounds = null
    this.currentCoordinates = null
    this.currentPointSize = 2
    
    // Initialize canvas
    this.canvas = null
    this.overlayCanvas = null
    this.overlayCtx = null
    
    // Clear category colors cache
    this.clearCategoryColorsCache()
    
    // Auto-load the first available embedding on page load
    setTimeout(() => {
      if (this.hasMetadataSelectTarget) {
        const firstOption = this.metadataSelectTarget.querySelector('option[value]:not([value=""])')
        if (firstOption) {
          console.log('🚀 Auto-loading first embedding on page load:', firstOption.textContent)
          this.metadataSelectTarget.value = firstOption.value
          this.updateMetadata()
        }
      }
    }, 100)
    
    // Initialize draggable divider
    setTimeout(() => {
      this.initializeDraggableDivider()
    }, 500)
    
    // Create diagnostic button
    setTimeout(() => {
      this.createDiagnosticButton()
    }, 3000)
  }

  disconnect() {
    // Remove click outside listener when controller disconnects
    if (this.boundCloseDropdowns) {
      document.removeEventListener('click', this.boundCloseDropdowns)
    }
    
    // Remove interaction event listeners
    this.removeInteractionEventListeners()
    
    // Clean up any existing ReGL renderer
    if (this.reglRenderer) {
      this.reglRenderer.destroy()
      this.reglRenderer = null
    }
  }

  // Initialize IndexedDB for storing metadata on disk
  initializeIndexedDB() {
    const dbName = 'VisualizationMetadataCache'
    const dbVersion = 1
    
    const request = indexedDB.open(dbName, dbVersion)
    
    request.onerror = () => {
      console.error('💾 IndexedDB initialization failed')
    }
    
    request.onsuccess = () => {
      this.db = request.result
      console.log('💾 IndexedDB initialized successfully - metadata will be stored on disk')
    }
    
    request.onupgradeneeded = (event) => {
      const db = event.target.result
      if (!db.objectStoreNames.contains('metadata')) {
        db.createObjectStore('metadata', { keyPath: 'id' })
      }
    }
  }

  // Clear category colors cache
  clearCategoryColorsCache() {
    this.cachedColorsByCellIndex = new Map()
    this.cachedColorMap = null
    this.lastColoringMetadataId = null
    this.lastColorRange = null
  }

  // Initialize draggable divider
  initializeDraggableDivider() {
    console.log('Initializing draggable divider')
  }

  // Setup interaction system
  setupInteractionSystem() {
    console.log('Setting up interaction system')
  }

  // Initialize tooltip
  initializeTooltip() {
    console.log('Initializing tooltip')
  }

  // Update selected cells count
  updateSelectedCellsCount() {
    console.log('Updating selected cells count')
  }

  // Create diagnostic button
  createDiagnosticButton() {
    console.log('Creating diagnostic button')
  }

  // Remove interaction event listeners
  removeInteractionEventListeners() {
    console.log('Removing interaction event listeners')
  }

  // Create tooltip dynamically
  createTooltipDynamically() {
    console.log('Creating tooltip dynamically')
  }

  // Update button states
  updateButtonStates(mode) {
    console.log('Updating button states:', mode)
  }

  // Update control instructions
  updateControlInstructions() {
    console.log('Updating control instructions')
  }

  // Setup canvas listeners
  setupCanvasListeners() {
    console.log('Setting up canvas listeners')
  }

  // Update embeddings
  updateEmbeddings() {
    if (!this.hasLoomFileSelectTarget || !this.hasEmbeddingSelectTarget || !this.hasEmbeddingsByLoomValue) {
      console.log('Embedding targets not available')
      return
    }
    
    const selectedLoomFile = this.loomFileSelectTarget.value
    const embeddings = this.embeddingsByLoomValue[selectedLoomFile] || []
    
    // Clear existing options
    this.embeddingSelectTarget.innerHTML = '<option value="">Select embedding...</option>'
    
    // Add new options
    embeddings.forEach(embedding => {
      const option = document.createElement('option')
      option.value = embedding.id
      option.textContent = embedding.name
      this.embeddingSelectTarget.appendChild(option)
    })
  }

  // Update metadata
  updateMetadata() {
    const perfStart = performance.now()
    console.log('⏱️ [PERF] ====== EMBEDDING SWITCH STARTED ======')
    
    if (!this.hasMetadataSelectTarget) {
      console.log('Metadata select target not available')
      return
    }
    
    const selectedMetadataId = this.metadataSelectTarget.value
    console.log(`⏱️ [PERF] Selected embedding ID: ${selectedMetadataId}`)
    
    if (selectedMetadataId) {
      // Show loading spinner
      this.showMetadataDropdownSpinner()
      
      // Load metadata and hide spinner when done
      this.loadMetadataCoordinates(selectedMetadataId)
        .catch(error => {
          console.error('❌ Error loading metadata coordinates:', error)
        })
        .finally(() => {
          this.hideMetadataDropdownSpinner()
          const perfEnd = performance.now()
          console.log(`⏱️ [PERF] ====== TOTAL EMBEDDING SWITCH TIME: ${(perfEnd - perfStart).toFixed(2)}ms ======`)
        })
    } else {
      // Clear any existing metadata data
      this.clearMetadataData()
    }
  }

  // Load metadata coordinates
  async loadMetadataCoordinates(metadataId) {
    const fetchStart = performance.now()
    
    try {
      // Check cache first!
      if (this.binaryDataCache.has(metadataId)) {
        console.log(`⏱️ [PERF] Step 1: BINARY CACHE HIT - Skipping network fetch for ${metadataId}`)
        const cachedData = this.binaryDataCache.get(metadataId)
        const cacheTime = performance.now() - fetchStart
        console.log(`⏱️ [PERF] Step 1: Binary cache retrieval: ${cacheTime.toFixed(2)}ms (saved ~5s download!)`)
        
        // Use cached binary data
        this.storeBinaryMetadataData(cachedData)
        return
      }
      
      console.log(`⏱️ [PERF] Step 1: BINARY CACHE MISS - Starting network fetch for ${metadataId}`)
      
      // Get the current loom file selection
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : null
      
      // Build the URL for the metadata coordinates endpoint
      const projectId = window.location.pathname.split('/')[2]
      const url = `/projects/${projectId}/metadata_coordinates?metadata_id=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      // Get CSRF token
      const csrfMetaTag = document.querySelector('meta[name="csrf-token"]')
      const csrfToken = csrfMetaTag?.getAttribute('content')
      
      const headers = { 'Accept': 'application/octet-stream' }
      if (csrfToken) headers['X-CSRF-Token'] = csrfToken

      const response = await fetch(url, { headers })
      
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`)
      }
      
      const arrayBuffer = await response.arrayBuffer()
      const fetchTime = performance.now() - fetchStart
      console.log(`⏱️ [PERF] Step 1: Network fetch completed in ${fetchTime.toFixed(2)}ms`)
      
      // Store in cache for future use
      this.binaryDataCache.set(metadataId, arrayBuffer)
      
      // Process the binary data
      this.storeBinaryMetadataData(arrayBuffer)
      
    } catch (error) {
      console.error('❌ Error loading metadata coordinates:', error)
      alert(`Failed to load metadata coordinates: ${error.message}`)
    }
  }

  // Store binary metadata data
  storeBinaryMetadataData(data) {
    // Store the binary coordinate data for later use
    this.metadataData = {
      binaryData: data,
      timestamp: Date.now()
    }
    
    // Update visualization with the new coordinate data
    this.updateVisualizationWithMetadata()
  }

  // Clear metadata data
  clearMetadataData() {
    this.metadataData = null
    
    // Clear ReGL visualization
    if (this.reglRenderer) {
      this.reglRenderer.destroy()
      this.reglRenderer = null
    }
    
    // Show placeholder and hide plot info
    const placeholder = document.getElementById('plot-placeholder')
    const plotInfo = document.getElementById('plot-info')
    if (placeholder) placeholder.style.display = 'block'
    if (plotInfo) plotInfo.style.display = 'none'
    
    // Clear point count
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = '0'
    }
  }

  // Update visualization with metadata
  updateVisualizationWithMetadata() {
    const vizStart = performance.now()
    
    if (!this.metadataData) {
      console.log('No metadata data available')
      return
    }
    
    // Decompress coordinates
    const decompressStart = performance.now()
    let decompressedCoords
    try {
      decompressedCoords = this.decompressBinaryCoordinates(this.metadataData.binaryData)
      const decompressTime = performance.now() - decompressStart
      console.log(`⏱️ [PERF] Step 2a: Total decompress + cache: ${decompressTime.toFixed(2)}ms`)
    } catch (error) {
      console.error('❌ Error decompressing coordinates:', error)
      return
    }
    
    // Initialize ReGL scatter plot
    const reglStart = performance.now()
    this.initializeReGLScatterPlot(decompressedCoords)
    const reglTime = performance.now() - reglStart
    
    const vizTime = performance.now() - vizStart
    console.log(`⏱️ [PERF] Step 2: updateVisualizationWithMetadata completed in ${vizTime.toFixed(2)}ms`)
  }

  // Initialize ReGL scatter plot
  async initializeReGLScatterPlot(coordinates) {
    try {
      // Find the plot container
      const plotContainer = document.querySelector('.plot-container')
      if (!plotContainer) {
        console.error('Plot container not found')
        return
      }
      
      // Check if we already have a ReGL renderer for this loom file
      if (this.reglRenderer && this.currentLoomFile === this.loomFileSelectTarget.value) {
        console.log('⏱️ [PERF] Step 3: Updating existing plot (FAST PATH)')
        const updateStart = performance.now()
        // Clear selection since coordinates might have changed
        this.selectedCells.clear()
        this.updateSelectedCellsCount()
        // Use updateScatterPlot to animate coordinate changes
        await this.updateScatterPlot(coordinates)
        const updateTime = performance.now() - updateStart
        console.log(`⏱️ [PERF] Step 3: Plot update completed in ${updateTime.toFixed(2)}ms`)
        return
      }
      
      console.log(`⏱️ [PERF] Step 3: Creating new ReGL renderer (SLOW PATH - first render)`)
      
      // Clear existing renderers
      if (this.reglRenderer) {
        this.reglRenderer.destroy()
        this.reglRenderer = null
      }
      
      // Clear plot container
      plotContainer.innerHTML = ''
      
      // Create ReGL canvas (if not already created)
      if (!this.canvas) {
        const canvas = document.createElement('canvas')
        canvas.width = plotContainer.clientWidth
        canvas.height = plotContainer.clientHeight
        canvas.style.width = '100%'
        canvas.style.height = '100%'
        plotContainer.appendChild(canvas)
        
        // Store canvas reference
        this.canvas = canvas
        
        // Initialize ReGL renderer
        this.reglRenderer = new ReglRenderer(canvas)
      }
      
      console.log('✅ ReGL scatter plot initialized')
      
      // Hide placeholder and show plot info
      const placeholder = document.getElementById('plot-placeholder')
      const plotInfo = document.getElementById('plot-info')
      if (placeholder) placeholder.style.display = 'none'
      if (plotInfo) plotInfo.style.display = 'block'
      
      // Store current loom file
      this.currentLoomFile = this.loomFileSelectTarget.value
      
      // Render the scatter plot
      await this.renderScatterPlot(coordinates)
      
      // Add interaction handlers
      this.addInteractionHandlers()
      
      console.log('✅ ReGL scatter plot initialized successfully')
      
    } catch (error) {
      console.error('Failed to initialize ReGL scatter plot:', error)
    }
  }

  // Render scatter plot
  async renderScatterPlot(coordinates) {
    // Use ReGL renderer only
    return this.renderScatterPlotReGL(coordinates)
  }

  // ReGL version of renderScatterPlot
  async renderScatterPlotReGL(coordinates) {
    if (!this.reglRenderer) return
    
    const startTime = performance.now()
    console.log(`🎯 [ReGL] Rendering ${coordinates.length.toLocaleString()} points...`)
    
    // Calculate bounds for normalization
    const originalBounds = this.calculateBounds(coordinates)
    const bounds = this.getAdjustedBounds(originalBounds)
    this.currentBounds = bounds
    this.currentCoordinates = coordinates
    
    // Render points using ReGL
    this.reglRenderer.renderPoints(coordinates, bounds)
    
    const elapsed = performance.now() - startTime
    console.log(`🎯 [ReGL] Rendered in ${elapsed.toFixed(2)}ms`)
  }

  // Update scatter plot
  async updateScatterPlot(coordinates) {
    return this.renderScatterPlot(coordinates)
  }

  // Calculate bounds for coordinates
  calculateBounds(coordinates) {
    if (coordinates.length === 0) return { minX: 0, maxX: 1, minY: 0, maxY: 1 }
    
    let minX = coordinates[0][0]
    let maxX = coordinates[0][0]
    let minY = coordinates[0][1]
    let maxY = coordinates[0][1]
    
    for (const [x, y] of coordinates) {
      minX = Math.min(minX, x)
      maxX = Math.max(maxX, x)
      minY = Math.min(minY, y)
      maxY = Math.max(maxY, y)
    }
    
    // Add padding
    const paddingX = (maxX - minX) * 0.05
    const paddingY = (maxY - minY) * 0.05
    
    return {
      minX: minX - paddingX,
      maxX: maxX + paddingX,
      minY: minY - paddingY,
      maxY: maxY + paddingY
    }
  }

  // Get plot margins
  getPlotMargins() {
    return {
      left: 60,   // Space for Y-axis labels
      right: 20,  // Space for right edge
      top: 20,    // Space for top edge
      bottom: 60  // Space for X-axis labels
    }
  }

  // Get bounds adjusted for axes margins
  getAdjustedBounds(originalBounds) {
    if (!this.canvas) {
      return originalBounds
    }
    
    const { minX, maxX, minY, maxY } = originalBounds
    const width = this.canvas.width
    const height = this.canvas.height
    const margins = this.getPlotMargins()
    
    // Calculate the data range that fits in the available space
    const availableWidth = width - margins.left - margins.right
    const availableHeight = height - margins.top - margins.bottom
    
    // Calculate the aspect ratio of the available space
    const availableAspectRatio = availableWidth / availableHeight
    const dataAspectRatio = (maxX - minX) / (maxY - minY)
    
    let adjustedMinX = minX
    let adjustedMaxX = maxX
    let adjustedMinY = minY
    let adjustedMaxY = maxY
    
    if (dataAspectRatio > availableAspectRatio) {
      // Data is wider than available space, adjust Y bounds
      const dataWidth = maxX - minX
      const targetHeight = dataWidth / availableAspectRatio
      const heightDifference = targetHeight - (maxY - minY)
      adjustedMinY = minY - heightDifference / 2
      adjustedMaxY = maxY + heightDifference / 2
    } else {
      // Data is taller than available space, adjust X bounds
      const dataHeight = maxY - minY
      const targetWidth = dataHeight * availableAspectRatio
      const widthDifference = targetWidth - (maxX - minX)
      adjustedMinX = minX - widthDifference / 2
      adjustedMaxX = maxX + widthDifference / 2
    }
    
    return {
      minX: adjustedMinX,
      maxX: adjustedMaxX,
      minY: adjustedMinY,
      maxY: adjustedMaxY
    }
  }

  // Add interaction handlers
  addInteractionHandlers() {
    // ReGL mode - interaction handled differently
    
    // Set initial cursor based on interaction mode
    const canvas = this.canvas
    if (canvas) {
      if (this.interactionMode === 'pan') {
        canvas.style.cursor = 'grab'
      } else if (this.interactionMode === 'lasso') {
        canvas.style.cursor = 'crosshair'
      } else {
        canvas.style.cursor = 'default'
      }
    }
    
    // Add interaction event listeners (ReGL plot canvas)
    this.addInteractionEventListeners()
  }

  // Add interaction event listeners
  addInteractionEventListeners() {
    console.log('Adding interaction event listeners')
  }

  // Decompress binary coordinates
  decompressBinaryCoordinates(arrayBuffer) {
    // OPTIMIZED: Use Int16Array for much faster decompression
    const int16Array = new Int16Array(arrayBuffer)
    const coordinates = []
    
    // Each coordinate is 2 int16 values (x, y)
    for (let i = 0; i < int16Array.length; i += 2) {
      coordinates.push([int16Array[i], int16Array[i + 1]])
    }
    
    return coordinates
  }

  // Show metadata dropdown spinner
  showMetadataDropdownSpinner() {
    const dropdown = document.getElementById('metadata-select-dropdown')
    const spinner = document.getElementById('metadata-dropdown-spinner')
    
    if (dropdown) {
      dropdown.disabled = true
      dropdown.style.opacity = '0.6'
    }
    
    if (spinner) {
      spinner.style.display = 'block'
    }
  }

  // Hide metadata dropdown spinner
  hideMetadataDropdownSpinner() {
    const dropdown = document.getElementById('metadata-select-dropdown')
    const spinner = document.getElementById('metadata-dropdown-spinner')
    
    if (dropdown) {
      dropdown.disabled = false
      dropdown.style.opacity = '1'
    }
    
    if (spinner) {
      spinner.style.display = 'none'
    }
  }

  // Update visualization with metadata vector coloring
  updateVisualizationWithMetadataVector() {
    // Check for renderer availability (ReGL only)
    if (this.reglRenderer) {
      this.renderPointsWithCurrentColoring()
    }
  }

  // Render points with current coloring (RegL implementation)
  renderPointsWithCurrentColoring() {
    // RegL implementation for rendering points with current coloring
    console.log('Rendering points with current coloring (RegL)')
  }

  // Close all dropdowns
  closeAllDropdowns() {
    // Implementation for closing all dropdowns
    console.log('Closing all dropdowns')
  }

  // Run emergency diagnostic
  runEmergencyDiagnostic() {
    // Implementation for emergency diagnostic
    console.log('Running emergency diagnostic')
  }
}
