import { Controller } from "@hotwired/stimulus"
import { ReglRenderer } from "visualization/regl_renderer"

console.log('Visualization controller file loaded - VERSION 3.0 WITH REGL + CATEGORY LABELS')

export default class extends Controller {
  static targets = ["loomFileSelect", "embeddingSelect", "metadataSelect"]
  static values = { 
    embeddingsByLoom: Object,
    defaultLoomFile: String
  }

  connect() {
    console.log('🚀 Visualization controller connected')
    
    // RENDERER CHOICE: 'pixi' or 'regl'
    this.rendererType = 'regl' // 🎯 Using ReGL for better performance
    this.reglRenderer = null // Will hold ReGL renderer instance
    
    // Initialize IndexedDB for storing metadata on disk instead of memory
    this.initializeIndexedDB()
    
    // Initialize selected categories tracking
    this.selectedCategories = {}
    this.selectedRanges = {} // Store continuous metadata ranges for filtering
    this.loadedMetadataVectors = {} // Store ONLY currently active metadata vectors (not all)
    this.currentVisibleCells = null // Track currently visible cells (null = all visible)
    this.lastFilterState = null // Track last filter state for incremental updates
    this.filterCache = new Map() // Cache for intersection results
    
    // Performance optimization: cache and batching
    this.lastFilteredIndices = null // Cache last filtered indices result
    this.lastFilterStateHash = null // Hash of filter state for change detection
    this.pendingUpdates = new Set() // Track pending updates for batching
    this.updateBatchTimer = null // Timer for batching updates
    
    // Color update optimization
    this.lastColorUpdateHash = null // Hash of color state for change detection
    this.colorUpdateCache = new Map() // Cache for color calculations
    
    // Performance monitoring
    this.performanceMetrics = {
      lastUpdateTime: 0,
      updateCount: 0,
      averageUpdateTime: 0,
      maxUpdateTime: 0
    }
    
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
    
    // Initialize category display order preference
    this.categoryOrder = 'largest-first' // 'largest-first' or 'smallest-first'
    
    // Initialize numerical display order preference for continuous metadata
    this.numericalOrder = 'negative-to-positive' // 'negative-to-positive', 'positive-to-negative', 'abs-min-to-max', 'abs-max-to-min'
    
    // Initialize auto-preload preference (enabled by default for better UX)
    this.autoPreloadMetadata = true
    
    // Initialize inline range slider data storage
    this.inlineRangeSliderData = {} // Store range slider data for each metadata
    
    // Performance optimization: store existing points for visibility updates and fast color switching
    this.pointSprites = null // Array of sprite objects for fast updates (replaces existingPoints)
    this.pointTexture = null // Shared texture for all point sprites
    this.lastMetadataVector = null // Track last metadata for optimization
    this.lastPointSize = null // Track last point size for optimization
    this.visibilityOnlyUpdate = false // When true, try to only toggle visibility
    this.spritesRenderType = null // Track what type of rendering created current sprites: 'discrete', 'numeric', or 'default'
    
    // Cache for decompressed embedding coordinates (avoid re-decompressing)
    this.decompressedCoordinatesCache = new Map() // Key: embeddingId, Value: decompressed coordinates
    
    // Cache for binary embedding data (avoid re-fetching from network)
    this.binaryDataCache = new Map() // Key: embeddingId, Value: { name, cellCount, binaryData }
    
    // Expose controller globally for range slider access
    window.visualizationController = this
    
    // Expose emergency diagnostic function
    window.runEmergencyDiagnostic = () => this.runEmergencyDiagnostic()
    
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
      }, 100) // Small delay to ensure DOM is ready
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
    
    // Memory management for metadata vectors
    this.metadataUsageTracker = new Map() // Track when metadata was last accessed
    this.maxMetadataInMemory = 5 // Default buffer size, will be adjusted based on dataset size
    
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
    this.minLassoPointDistance = 0 // Accept ALL events (remote desktop sends very few)
    this.lassoAnimationFrame = null // For smooth rendering
    
    // Initialize tooltip state
    this.tooltip = null
    this.tooltipContent = null
    this.fixedTooltipCellId = null // Cell ID for fixed tooltip (clicked cell)
    this.isTooltipFixed = false // Whether tooltip is fixed to a clicked cell
    
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
    
    // Create diagnostic button after a delay (fallback in case preloading doesn't complete)
    setTimeout(() => {
      this.createDiagnosticButton()
    }, 3000) // Wait 3 seconds after connection
    
    // Automatic preloading is now enabled - metadata will be preloaded in background when autoPreloadMetadata is true
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
  
  // Helper methods for safely calculating min/max on large arrays
  // Using spread operator with Math.min/max fails with arrays > ~65k-100k elements
  safeMin(arr) {
    if (!arr || arr.length === 0) return undefined
    let min = arr[0]
    for (let i = 1; i < arr.length; i++) {
      if (arr[i] < min) min = arr[i]
    }
    return min
  }
  
  safeMax(arr) {
    if (!arr || arr.length === 0) return undefined
    let max = arr[0]
    for (let i = 1; i < arr.length; i++) {
      if (arr[i] > max) max = arr[i]
    }
    return max
  }
  
  // Log memory usage for debugging
  logMemoryUsage(context = '') {
    if (performance.memory) {
      const used = (performance.memory.usedJSHeapSize / 1024 / 1024).toFixed(2)
      const total = (performance.memory.totalJSHeapSize / 1024 / 1024).toFixed(2)
      const limit = (performance.memory.jsHeapSizeLimit / 1024 / 1024).toFixed(2)
      const percent = ((performance.memory.usedJSHeapSize / performance.memory.jsHeapSizeLimit) * 100).toFixed(1)
      
      console.log(`💾 [MEMORY] ${context}: ${used}MB / ${total}MB (${percent}% of ${limit}MB limit)`)
      
      // Warn if memory usage is high
      if (percent > 80) {
        console.warn(`⚠️ [MEMORY] High memory usage: ${percent}% - performance may be degraded`)
      }
      
      return { used: parseFloat(used), total: parseFloat(total), limit: parseFloat(limit), percent: parseFloat(percent) }
    } else {
      console.log(`💾 [MEMORY] ${context}: performance.memory not available (use Chrome/Edge for memory stats)`)
      return null
    }
  }
  
  // Check for potential memory leaks and report sprite/object counts
  checkMemoryHealth() {
    console.log('🔍 [MEMORY HEALTH CHECK]')
    console.log(`  Sprites: ${this.pointSprites?.length || 0}`)
    console.log(`  Scatter container children: ${this.scatterContainer?.children.length || 0}`)
    console.log(`  Animated container children: ${this.animatedContainer?.children.length || 0}`)
    console.log(`  Loaded metadata vectors IN MEMORY: ${Object.keys(this.loadedMetadataVectors || {}).length}`)
    console.log(`  Selected categories: ${Object.keys(this.selectedCategories || {}).length}`)
    console.log(`  Selected ranges: ${Object.keys(this.selectedRanges || {}).length}`)
    console.log(`  Filter cache size: ${this.filterCache?.size || 0}`)
    console.log(`  Original point colors: ${this.originalPointColors?.size || 0}`)
    
    this.logMemoryUsage('Current state')
    
    // Check IndexedDB usage
    if (this.db) {
      console.log('💾 IndexedDB initialized and available for disk storage')
    }
    
    // Expose function globally for easy console access
    console.log('💡 To run this check anytime, type: visualizationController.checkMemoryHealth()')
  }
  
  // Initialize IndexedDB for storing metadata on disk
  initializeIndexedDB() {
    const dbName = 'VisualizationMetadataCache'
    const dbVersion = 1
    
    const request = indexedDB.open(dbName, dbVersion)
    
    request.onerror = () => {
      console.error('💾 Failed to open IndexedDB, will keep metadata in memory')
      this.db = null
    }
    
    request.onsuccess = (event) => {
      this.db = event.target.result
      console.log('💾 IndexedDB initialized successfully - metadata will be stored on disk')
    }
    
    request.onupgradeneeded = (event) => {
      const db = event.target.result
      
      // Create object store for metadata vectors
      if (!db.objectStoreNames.contains('metadataVectors')) {
        const objectStore = db.createObjectStore('metadataVectors', { keyPath: 'id' })
        objectStore.createIndex('loomFile', 'loomFile', { unique: false })
        console.log('💾 Created IndexedDB object store for metadata vectors')
      }
    }
  }
  
  // Store metadata vector in IndexedDB (disk storage)
  async storeMetadataInIndexedDB(metadataId, vectorData) {
    if (!this.db) return false
    
    try {
      const transaction = this.db.transaction(['metadataVectors'], 'readwrite')
      const objectStore = transaction.objectStore('metadataVectors')
      
      // Add loom file info for cache invalidation
      const dataToStore = {
        id: metadataId,
        loomFile: this.currentLoomFile,
        timestamp: Date.now(),
        ...vectorData
      }
      
      objectStore.put(dataToStore)
      
      return new Promise((resolve, reject) => {
        transaction.oncomplete = () => {
          console.log(`💾 Stored metadata ${metadataId} in IndexedDB`)
          resolve(true)
        }
        transaction.onerror = () => {
          console.error(`💾 Failed to store metadata ${metadataId} in IndexedDB`)
          reject(false)
        }
      })
    } catch (error) {
      console.error('💾 Error storing in IndexedDB:', error)
      return false
    }
  }
  
  // Load metadata vector from IndexedDB (disk storage)
  async loadMetadataFromIndexedDB(metadataId) {
    if (!this.db) {
      console.log(`💾 IndexedDB not available for metadata ${metadataId}`)
      return null
    }
    
    try {
      const transaction = this.db.transaction(['metadataVectors'], 'readonly')
      const objectStore = transaction.objectStore('metadataVectors')
      const request = objectStore.get(metadataId)
      
      return new Promise((resolve, reject) => {
        request.onsuccess = () => {
          if (request.result) {
            const currentLoom = this.currentLoomFile || this.loomFileSelectTarget?.value || this.defaultLoomFileValue
            
            console.log(`💾 IndexedDB lookup for ${metadataId}:`, {
              found: true,
              storedLoomFile: request.result.loomFile,
              currentLoomFile: currentLoom,
              match: request.result.loomFile === currentLoom
            })
            
            if (request.result.loomFile === currentLoom) {
              console.log(`💾 ✅ Loaded metadata ${metadataId} from IndexedDB (disk storage)`)
              resolve(request.result)
            } else {
              console.log(`💾 ⚠️ Loom file mismatch, ignoring cached data for ${metadataId}`)
              resolve(null) // Wrong loom file
            }
          } else {
            console.log(`💾 Metadata ${metadataId} not found in IndexedDB`)
            
            // Debug info removed - use diagnostic button for detailed analysis
            
            resolve(null)
          }
        }
        request.onerror = () => {
          console.error(`💾 Failed to load metadata ${metadataId} from IndexedDB:`, request.error)
          resolve(null)
        }
      })
    } catch (error) {
      console.error('💾 Error loading from IndexedDB:', error)
      return null
    }
  }
  
  // Clear old metadata from memory (keep only current one)
  clearOldMetadataFromMemory(currentMetadataId) {
    const beforeCount = Object.keys(this.loadedMetadataVectors).length
    const beforeMem = this.logMemoryUsage('Before clearing old metadata')
    
    // Keep only the current metadata in memory
    Object.keys(this.loadedMetadataVectors).forEach(id => {
      if (id !== currentMetadataId) {
        delete this.loadedMetadataVectors[id]
      }
    })
    
    const afterCount = Object.keys(this.loadedMetadataVectors).length
    console.log(`💾 Cleared ${beforeCount - afterCount} old metadata vectors from memory, kept ${afterCount}`)
    
    // Force garbage collection hint
    if (window.gc) {
      window.gc()
      console.log('💾 Triggered manual garbage collection')
    }
    
    setTimeout(() => {
      const afterMem = this.logMemoryUsage('After clearing old metadata')
      if (beforeMem && afterMem) {
        const freed = beforeMem.used - afterMem.used
        console.log(`💾 Freed approximately ${freed.toFixed(2)}MB of memory`)
      }
    }, 100)
  }
  
  // Clear all IndexedDB cache (useful for debugging or when data is corrupted)
  async clearIndexedDBCache() {
    if (!this.db) {
      console.log('💾 IndexedDB not available')
      return
    }
    
    try {
      const transaction = this.db.transaction(['metadataVectors'], 'readwrite')
      const objectStore = transaction.objectStore('metadataVectors')
      const request = objectStore.clear()
      
      return new Promise((resolve, reject) => {
        request.onsuccess = () => {
          console.log('💾 Cleared all metadata from IndexedDB')
          resolve(true)
        }
        request.onerror = () => {
          console.error('💾 Failed to clear IndexedDB')
          reject(false)
        }
      })
    } catch (error) {
      console.error('💾 Error clearing IndexedDB:', error)
      return false
    }
  }
  
  // Create a reusable point texture for sprite-based rendering
  // This is much faster than creating Graphics objects for each point
  createPointTexture(radius) {
    const graphics = new this.PIXI.Graphics()
    graphics.beginFill(0xFFFFFF) // White circle, will be tinted
    graphics.drawCircle(radius, radius, radius)
    graphics.endFill()
    
    const texture = this.pixiApp.renderer.generateTexture(graphics, {
      resolution: 2, // Higher resolution for sharp edges
      scaleMode: this.PIXI.SCALE_MODES.LINEAR
    })
    
    graphics.destroy()
    return texture
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
    console.log('🎯 [Tooltip] Creating tooltip dynamically')
    
    // Remove existing tooltip if it exists
    const existingTooltip = document.getElementById('point-tooltip')
    if (existingTooltip) {
      console.log('🎯 [Tooltip] Removing existing tooltip')
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
    
    console.log('🎯 [Tooltip] Tooltip created dynamically:', {
      tooltip: this.tooltip,
      tooltipContent: this.tooltipContent,
      parentNode: this.tooltip.parentNode,
      tooltipId: this.tooltip.id
    })
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
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_coordinates?metadata_id=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      // Get CSRF token safely
      const csrfMetaTag = document.querySelector('meta[name="csrf-token"]')
      const csrfToken = csrfMetaTag?.getAttribute('content')
      
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
      
      const fetchTime = performance.now() - fetchStart
      console.log(`⏱️ [PERF] Step 1: Network fetch completed in ${fetchTime.toFixed(2)}ms`)
      
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
      
      console.log(`⏱️ [PERF] Received ${metadataName} with ${cellCount} cells`)
      
      // Get the binary data as ArrayBuffer
      const bufferStart = performance.now()
      const arrayBuffer = await response.arrayBuffer()
      const bufferTime = performance.now() - bufferStart
      console.log(`⏱️ [PERF] ArrayBuffer conversion: ${bufferTime.toFixed(2)}ms (${(arrayBuffer.byteLength / 1024).toFixed(1)}KB)`)
      
      /*console.log('ArrayBuffer details:', {
        byteLength: arrayBuffer.byteLength,
        expectedLength: cellCount * 4, // 4 bytes per coordinate pair
        isValid: arrayBuffer.byteLength === cellCount * 4
      })*/
      
      // Log first few bytes for debugging
      const view = new Uint8Array(arrayBuffer)
      //console.log('First 20 bytes of binary data:', Array.from(view.slice(0, 20)))
      //console.log('Last 20 bytes of binary data:', Array.from(view.slice(-20)))
      
      // Prepare data object
      const dataObject = {
        id: headerMetadataId,
        name: metadataName,
        cellCount: cellCount,
        binaryData: arrayBuffer
      }
      
      // Cache binary data for instant retrieval next time
      this.binaryDataCache.set(metadataId, dataObject)
      console.log(`⏱️ [PERF] Cached binary data for ${metadataName} (${(arrayBuffer.byteLength / 1024).toFixed(1)}KB)`)
      
      // Store the binary coordinate data
      this.storeBinaryMetadataData(dataObject)
      
    } catch (error) {
      console.error('Error loading metadata coordinates:', error)
      alert(`Failed to load metadata coordinates: ${error.message}`)
    }
  }

  // Silent version of loadMetadataCoordinates - only caches without displaying
  async loadMetadataCoordinatesSilently(metadataId, metadataName = 'unknown') {
    try {
      // Check cache first - if already cached, nothing to do
      if (this.binaryDataCache.has(metadataId)) {
        return { success: true, cached: true }
      }
      
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
      
      const response = await fetch(url, {
        method: 'GET',
        headers: headers,
        credentials: 'same-origin'
      })
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      
      // Check for JSON error
      const contentType = response.headers.get('content-type')
      if (contentType && contentType.includes('application/json')) {
        const errorData = await response.json()
        throw new Error(errorData.error || 'Unknown error')
      }
      
      // Extract metadata from headers
      const headerMetadataId = response.headers.get('X-Metadata-ID')
      const responseName = response.headers.get('X-Metadata-Name')
      const cellCount = parseInt(response.headers.get('X-Cell-Count'))
      
      // Get the binary data
      const arrayBuffer = await response.arrayBuffer()
      
      // Prepare data object
      const dataObject = {
        id: headerMetadataId,
        name: responseName,
        cellCount: cellCount,
        binaryData: arrayBuffer
      }
      
      // Cache binary data (but DON'T call storeBinaryMetadataData - that would display it)
      this.binaryDataCache.set(metadataId, dataObject)
      
      return { 
        success: true, 
        cached: false,
        size: (arrayBuffer.byteLength / 1024).toFixed(1) + 'KB'
      }
      
    } catch (error) {
      return { 
        success: false, 
        error: error.message 
      }
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
    const vizStart = performance.now()
    console.log('⏱️ [PERF] Step 2: updateVisualizationWithMetadata started')
    
    if (!this.metadataData) {
      console.log('No metadata data to visualize')
      return
    }
    
    // Get embedding ID for caching (use name as key)
    const embeddingId = this.metadataData.name
    
    // Check cache first to avoid re-decompressing
    let decompressedCoords
    const decompressStart = performance.now()
    
    if (this.decompressedCoordinatesCache.has(embeddingId)) {
      console.log(`⏱️ [PERF] Step 2a: CACHE HIT - Using cached coordinates for ${embeddingId}`)
      decompressedCoords = this.decompressedCoordinatesCache.get(embeddingId)
      const cacheTime = performance.now() - decompressStart
      console.log(`⏱️ [PERF] Step 2a: Cache retrieval: ${cacheTime.toFixed(2)}ms`)
    } else {
      console.log(`⏱️ [PERF] Step 2a: CACHE MISS - Decompressing ${embeddingId}`)
      // Decompress and cache (this method has its own internal logging)
      decompressedCoords = this.decompressBinaryCoordinates(this.metadataData.binaryData)
      this.decompressedCoordinatesCache.set(embeddingId, decompressedCoords)
      const decompressTime = performance.now() - decompressStart
      console.log(`⏱️ [PERF] Step 2a: Total decompress + cache: ${decompressTime.toFixed(2)}ms`)
    }
    
    // Initialize PIXI.js scatter plot
    const pixiStart = performance.now()
    this.initializePixiScatterPlot(decompressedCoords)
    const pixiTime = performance.now() - pixiStart
    
    const vizTime = performance.now() - vizStart
    console.log(`⏱️ [PERF] Step 2: updateVisualizationWithMetadata completed in ${vizTime.toFixed(2)}ms`)
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
      
      console.log(`⏱️ [PERF] Step 3: Creating new ${this.rendererType.toUpperCase()} renderer (SLOW PATH - first render)`)
      
      // Clear existing renderers
      if (this.pixiApp) {
        this.pixiApp.destroy(true)
        this.pixiApp = null
      }
      if (this.reglRenderer) {
        this.reglRenderer.destroy()
        this.reglRenderer = null
      }
      
      // Clear plot container
      plotContainer.innerHTML = ''
      
      if (this.rendererType === 'regl') {
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
        
        // Initialize ReGL renderer
        this.reglRenderer = new ReglRenderer(canvas)
        this.canvas = canvas
        
        console.log('ReGL canvas added to container:', canvas)
        
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
        
        this.overlayCanvas = overlayCanvas
        this.overlayCtx = overlayCanvas.getContext('2d')
        
        // Store PIXI reference for compatibility (but don't create app)
        this.PIXI = PIXI
        this.pixiApp = null // No PixiJS app in ReGL mode
        
        console.log('✅ Canvas 2D overlay created for UI elements (axes/grid/labels)')
        console.log('📊 Canvas 2D overlay details:', {
          width: overlayCanvas.width,
          height: overlayCanvas.height,
          zIndex: overlayCanvas.style.zIndex,
          pointerEvents: overlayCanvas.style.pointerEvents
        })
        
      } else {
        // ===== PIXI RENDERER (original) =====
      // Store PIXI reference for later use
      this.PIXI = PIXI
      
      // Use global PIXI.Application
      const Application = PIXI.Application
      
      this.pixiApp = new Application({
        width: plotContainer.clientWidth,
        height: plotContainer.clientHeight,
        backgroundColor: 0xffffff,
        antialias: true,
        resolution: window.devicePixelRatio || 1,
        autoDensity: true
      })
      
      // Add PIXI canvas to the container
      plotContainer.appendChild(this.pixiApp.view)
      console.log('PIXI canvas added to container:', this.pixiApp.view)
      }
      
      // Hide placeholder and show plot info
      const placeholder = document.getElementById('plot-placeholder')
      const plotInfo = document.getElementById('plot-info')
      if (placeholder) placeholder.style.display = 'none'
      if (plotInfo) plotInfo.style.display = 'block'
      
      // Create containers based on renderer type
      if (this.rendererType === 'pixi') {
        // PixiJS mode: Create PixiJS containers
      this.gridContainer = new PIXI.Container()
        this.gridContainer.visible = true
      this.pixiApp.stage.addChild(this.gridContainer)
      
      this.scatterContainer = new PIXI.Container()
        this.scatterContainer.sortableChildren = true
      this.pixiApp.stage.addChild(this.scatterContainer)
      
      this.categoryLabelsContainer = new PIXI.Container()
        this.categoryLabelsContainer.visible = true
      this.pixiApp.stage.addChild(this.categoryLabelsContainer)
      
      this.axesContainer = new PIXI.Container()
        this.axesContainer.visible = true
      this.pixiApp.stage.addChild(this.axesContainer)
        
        console.log(`✅ PixiJS containers created`)
      } else {
        // ReGL mode: No PixiJS containers needed, using Canvas 2D overlay
        this.scatterContainer = { children: [] } // Dummy for compatibility
        this.gridContainer = null
        this.categoryLabelsContainer = null
        this.axesContainer = null
        console.log(`✅ ReGL mode - using Canvas 2D overlay (no PixiJS containers)`)
      }

      // Store current loom file
      this.currentLoomFile = this.loomFileSelectTarget.value
      
      // Render the scatter plot
      await this.renderScatterPlot(coordinates)
      
      // Reapply current metadata coloring if any is active
      if (this.currentMetadataVector && this.currentMetadataVector.values) {
        console.log(`🎨 Reapplying metadata coloring after embedding switch: ${this.currentMetadataVector.name}`)
        if (this.rendererType === 'regl') {
          await this.renderPointsWithCurrentColoringReGL()
        } else {
          this.updateVisualizationWithMetadataVector()
        }
      }
      
      // Add interaction handlers
      this.addInteractionHandlers()
      
      // Setup global drag handlers for label dragging
      this.setupGlobalDragHandlers()
      
      //console.log('PIXI.js scatter plot initialized successfully')
      
      // Only auto-preload if the option is enabled
      if (this.autoPreloadMetadata) {
        // Start preloading immediately (in background, ordered: embeddings → categorical → continuous)
        console.log('🚀 Starting automatic metadata preload...')
        this.preloadAllMetadata().catch(error => {
          console.log('Background metadata preload encountered an error:', error)
        })
      } else {
        console.log('🚀 Auto-preload disabled - metadata will load on hover/click only')
      }
      
      // Initial memory health check
      setTimeout(() => {
        this.checkMemoryHealth()
      }, 2000)
      
    } catch (error) {
      console.error('Failed to initialize PIXI.js scatter plot:', error)
    }
  }

  async renderScatterPlot(coordinates) {
    // Dispatch to ReGL if using ReGL renderer
    if (this.rendererType === 'regl') {
      return this.renderScatterPlotReGL(coordinates)
    }
    
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
    
    // Create shared point texture if it doesn't exist or size changed
    if (!this.pointTexture || this.lastPointSize !== pointSize) {
      if (this.pointTexture) this.pointTexture.destroy(true)
      this.pointTexture = this.createPointTexture(pointSize)
      this.lastPointSize = pointSize
    }
    
    // Initialize sprite array
    this.pointSprites = new Array(coordinates.length)
    
    console.log(`🚀 [PERF] Creating ${coordinates.length} sprite-based points...`)
    const startTime = performance.now()
    
    // Render points using sprites for better performance
    for (let i = 0; i < coordinates.length; i++) {
        const [x, y] = coordinates[i]
        
        // Normalize coordinates to screen space
        const screenX = this.normalizeX(x, bounds)
        const screenY = this.normalizeY(y, bounds)
        
      // Create sprite using shared texture (much faster than Graphics)
      const sprite = new PIXI.Sprite(this.pointTexture)
      sprite.anchor.set(0.5) // Center the sprite
      sprite.x = screenX
      sprite.y = screenY
      sprite.tint = pointColor
      sprite.zIndex = 0 // Initial z-order (can be changed later)
      
      // Store cell ID and mark as point for later reference
      sprite.cellId = i
      sprite.isPoint = true
      
      // Store original color for reset functionality
      this.storeOriginalPointColor(i, pointColor)
      
      // Add hover functionality
      sprite.interactive = true
      sprite.buttonMode = false
      sprite.on('pointerover', () => this.showTooltip(i, sprite))
      sprite.on('pointerout', () => this.hideTooltip())
      sprite.on('pointerdown', (event) => this.onPointClick(i, sprite, event))
      
      // Debug: Log point creation
      if (i < 5) { // Only log first 5 points to avoid spam
        console.log(`Created sprite point ${i}:`, { 
          cellId: sprite.cellId, 
          isPoint: sprite.isPoint, 
          interactive: sprite.interactive,
          x: sprite.x, 
          y: sprite.y 
        })
      }
      
      this.scatterContainer.addChild(sprite)
      this.pointSprites[i] = sprite
    }
    
    const createTime = performance.now() - startTime
    console.log(`🚀 [PERF] Created ${coordinates.length} sprites in ${createTime.toFixed(2)}ms`)
    
    // Mark initial sprites as default coloring
    this.spritesRenderType = 'default'
    
    // Log memory usage after creating sprites
    this.logMemoryUsage('After creating initial sprites')
    
    //console.log(`Rendered ${coordinates.length} individual points`)
        
        // Update point count display
        const pointCountElement = document.getElementById('point-count')
        if (pointCountElement) {
          pointCountElement.textContent = coordinates.length.toLocaleString()
    }
    
    // Clear any stored original positions since points were recreated
    this.clearStoredOriginalPositions()
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
    
    // Reset ordering flags so they'll be reapplied for this new embedding
    this._lastCategoryOrderApplied = null
    this._lastNumericOrderApplied = null
    
    // Initialize display order array (identity mapping initially)
    // displayOrder[drawPosition] = originalCellIndex
    this.displayOrder = new Array(coordinates.length)
    for (let i = 0; i < coordinates.length; i++) {
      this.displayOrder[i] = i
    }
    console.log(`🎯 [ReGL] Initialized display order (identity: 0, 1, 2, ...)`)
    
    // Normalize coordinates to screen space (0 to canvas size)
    const canvas = this.canvas
    const screenCoordinates = new Float32Array(coordinates.length * 2)
    
    for (let i = 0; i < coordinates.length; i++) {
      const [x, y] = coordinates[i]
      screenCoordinates[i * 2] = this.normalizeX(x, bounds)
      screenCoordinates[i * 2 + 1] = this.normalizeY(y, bounds)
    }
    
    // Set positions in ReGL renderer
    this.reglRenderer.setPositions(screenCoordinates)
    
    // Set initial point size
    this.reglRenderer.setPointSize(this.currentPointSize || 4)
    
    // Render first frame
    this.reglRenderer.render()
    
    // Render grid and axes using PixiJS overlay
    this.renderGrid()
    this.renderAxes()
    this.renderCategoryLabels() // ✅ Category labels work in ReGL mode!
    
    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = coordinates.length.toLocaleString()
    }
    
    // Store for tracking
    this.numPoints = coordinates.length
    this.spritesRenderType = 'default'
    
    const elapsed = performance.now() - startTime
    console.log(`🎯 [ReGL] Rendered in ${elapsed.toFixed(2)}ms`)
  }

  // NEW METHOD: Update sprite positions without recreating them
  updateSpritePositions(coordinates, newBounds) {
    const updateStart = performance.now()
    
    if (!this.pointSprites || this.pointSprites.length !== coordinates.length) {
      console.log('🚀 [PERF] Cannot update positions - sprite count mismatch or no sprites')
      return false
    }
    
    console.log(`🚀 [PERF] Updating positions of ${this.pointSprites.length} existing sprites (FAST PATH)`)
    
    // Update sprite positions directly - no recreation!
    for (let i = 0; i < this.pointSprites.length; i++) {
      const [newX, newY] = coordinates[i]
      const sprite = this.pointSprites[i]
      sprite.x = this.normalizeX(newX, newBounds)
      sprite.y = this.normalizeY(newY, newBounds)
    }
    
    const updateTime = performance.now() - updateStart
    console.log(`🚀 [PERF] Position update completed in ${updateTime.toFixed(2)}ms (${(this.pointSprites.length / updateTime * 1000).toFixed(0)} points/sec)`)
    
    return true
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
      console.log('🚀 [PERF] Same embedding detected - attempting fast position update')
      
      // Try to update positions without recreation (FAST PATH)
      const updated = this.updateSpritePositions(coordinates, newBounds)
      
      if (updated) {
        // Success! Just update metadata and we're done
        this.currentBounds = newBounds
        this.currentCoordinates = coordinates
        this.renderAxes()
        this.renderGrid()
        this.renderCategoryLabels()
        this.updateCellFiltering()
        
        const pointCountElement = document.getElementById('point-count')
        if (pointCountElement) {
          pointCountElement.textContent = coordinates.length.toLocaleString()
        }
        return
      }
      
      // Fall through to recreation if update failed
      console.log('🚀 [PERF] Fast update failed, falling back to recreation')
      this.scatterContainer.removeChildren()
      this.pointSprites = null
      this.existingPoints = null
      this.spritesRenderType = null
      
      this.currentBounds = newBounds
      this.currentCoordinates = coordinates
      this.renderAxes()
      this.renderGrid()
      
      if (this.currentMetadataVector?.id && this.currentMetadataVector.data_type === 'DISCRETE' && !this.selectedCategories[this.currentMetadataVector.id]) {
        this.initializeCheckboxesForMetadata(this.currentMetadataVector.id)
      }
      
      this.renderCategoryLabels()
      this.renderPointsWithCurrentColoring()
      this.updateCellFiltering()
      
      const pointCountElement = document.getElementById('point-count')
      if (pointCountElement) {
        pointCountElement.textContent = coordinates.length.toLocaleString()
      }
      return
    }
    
    // Check if we should skip animation for large datasets (> 100k cells)
    const skipAnimation = coordinates.length > 150000
    
    if (skipAnimation) {
      console.log(`🚀 [PERF] Large dataset (${coordinates.length} cells) - skipping animation`)
      
      // Try fast position update first if counts match
      if (previousCoordinates.length === coordinates.length) {
        console.log('🚀 [PERF] Same cell count - attempting fast position update')
        const updated = this.updateSpritePositions(coordinates, newBounds)
        
        if (updated) {
      this.clearIncrementalState()
          this.currentBounds = newBounds
          this.currentCoordinates = coordinates
          this.renderAxes()
          this.renderGrid()
          this.renderCategoryLabels()
          this.updateCellFiltering()
          
          const pointCountElement = document.getElementById('point-count')
          if (pointCountElement) {
            pointCountElement.textContent = coordinates.length.toLocaleString()
          }
          return
        }
      }
      
      // Fall back to recreation
      console.log('🚀 [PERF] Recreating sprites for large dataset')
      this.clearIncrementalState()
      this.scatterContainer.removeChildren()
      this.pointSprites = null
      this.existingPoints = null
      
      this.currentBounds = newBounds
      this.currentCoordinates = coordinates
      this.renderAxes()
      this.renderGrid()
      this.renderCategoryLabels()
      this.renderPointsWithCurrentColoring()
      this.updateCellFiltering()
      
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
    
    // Update bounds and coordinates for the new embedding
    this.currentBounds = newBounds
    this.currentCoordinates = coordinates
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
          // Use DOM order (same as legend) for consistent color assignment
          const domOrderCategories = this.getCategoriesForMetadata(this.currentMetadataId)
          if (domOrderCategories && domOrderCategories.length > 0) {
            const categoryNames = domOrderCategories.map(cat => cat.name)
            this._cachedColorMap = this.createDiscreteColorMap(categoryNames, this.currentMetadataId)
          } else {
            // Fallback to original categories if DOM not available
            this._cachedColorMap = this.createDiscreteColorMap([...compression_info.categories], this.currentMetadataId)
          }
        }
        baseColor = this._cachedColorMap[value] || 0x3b82f6
      } else if (data_type === 'NUMERIC') {
        const effectiveRange = this.getEffectiveColorRange()
        if (effectiveRange) {
          const { min: minVal, max: maxVal } = effectiveRange
          const range = maxVal - minVal
          const normalizedValue = (value - minVal) / range
          baseColor = this.getColorFromGradient(normalizedValue)
        } else {
          // Fallback to original compression info
          const minVal = compression_info.min_val
          const maxVal = compression_info.max_val
          const range = maxVal - minVal
          const normalizedValue = (value - minVal) / range
          baseColor = this.getColorFromGradient(normalizedValue)
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
    // Safety check: Don't animate large datasets (> 100k cells)
    if (newCoordinates.length > 150000) {
      console.log(`🚀 [PERF] Skipping animation in createAnimatedPoints - dataset too large (${newCoordinates.length} cells)`)
      // Clear sprite cache to force recreation with new positions
      this.pointSprites = null
      this.existingPoints = null
      this.spritesRenderType = null
      // Render the points directly without animation
      this.renderPointsWithCurrentColoring()
      return
    }
    
    //console.log('Creating animated points from previous to new coordinates')
    const pointSize = this.currentPointSize // Use current point size setting
    const animationDuration = 3000 // 1 second for faster transitions
    
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
      
      // Calculate category frequencies for layering
      const categoryFrequencies = {}
      values.forEach(value => {
        categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
      })
      
      //console.log('Animation: Category frequencies for layering:', categoryFrequencies)
      
      // Sort point indices by category size based on user preference
      sortedIndices = sortedIndices.sort((a, b) => {
        const categoryA = values[a]
        const categoryB = values[b]
        const freqA = categoryFrequencies[categoryA]
        const freqB = categoryFrequencies[categoryB]
        
        if (this.categoryOrder === 'smallest-first') {
          return freqA - freqB // Ascending order (smallest first)
        } else {
          return freqB - freqA // Descending order (largest first) - default
        }
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
    
    // Add minimal padding on both top and bottom
    const paddingX = (maxX - minX) * 0.05
    const paddingYBottom = (maxY - minY) * 0.01  // Minimal padding on bottom
    const paddingYTop = (maxY - minY) * 0.01     // Minimal padding on top
    
    return {
      minX: minX - paddingX,
      maxX: maxX + paddingX,
      minY: minY - paddingYBottom,
      maxY: maxY + paddingYTop
    }
  }

  // Get standardized margins for the plot
  getPlotMargins() {
    return {
      left: 60,    // Space for Y-axis labels
      right: 20,   // Right margin
      top: 20,      // Minimal top margin
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
    
    //console.log('Returning adjusted bounds:', adjustedBounds)
    return adjustedBounds
  }

  normalizeX(x, bounds) {
    const margins = this.getPlotMargins()
    const screenWidth = this.rendererType === 'regl' ? this.canvas.width : this.pixiApp.screen.width
    const availableWidth = screenWidth - margins.left - margins.right
    return margins.left + ((x - bounds.minX) / (bounds.maxX - bounds.minX)) * availableWidth
  }

  normalizeY(y, bounds) {
    // Invert Y-axis: higher Y values appear at the top, lower Y values at the bottom
    const margins = this.getPlotMargins()
    const screenHeight = this.rendererType === 'regl' ? this.canvas.height : this.pixiApp.screen.height
    const availableHeight = screenHeight - margins.top - margins.bottom
    return margins.top + availableHeight - ((y - bounds.minY) / (bounds.maxY - bounds.minY)) * availableHeight
  }

  addInteractionHandlers() {
    // Make the stage interactive (PixiJS mode only)
    if (this.rendererType === 'pixi' && this.pixiApp) {
    this.pixiApp.stage.interactive = true
    }
    
    // Set initial cursor based on interaction mode
    const canvas = this.rendererType === 'regl' ? this.canvas : (this.pixiApp && this.pixiApp.view)
    if (canvas) {
      if (this.interactionMode === 'pan') {
        canvas.style.cursor = 'grab'
      } else if (this.interactionMode === 'lasso') {
        canvas.style.cursor = 'crosshair'
      }
    }
    
    // Add our new interaction event listeners (works for both ReGL and PixiJS)
    this.addInteractionEventListeners()
  }

  decompressBinaryCoordinates(arrayBuffer) {
    // OPTIMIZED: Use Int16Array for much faster decompression
    const decompressStart = performance.now()
    
    // Create Int16Array view directly (much faster than DataView)
    const int16View = new Int16Array(arrayBuffer)
    const numPairs = int16View.length / 2
    
    // Pre-allocate array for better performance
    const coordinates = new Array(numPairs)
    
    // Single loop with direct typed array access (10-100x faster!)
    let xMin = Infinity, xMax = -Infinity
    let yMin = Infinity, yMax = -Infinity
    
    for (let i = 0; i < numPairs; i++) {
      const idx = i * 2
      const x = int16View[idx] / 100      // Direct array access - very fast!
      const y = int16View[idx + 1] / 100
      
      coordinates[i] = [x, y]
      
      // Track min/max in same loop (no need for second pass)
        if (x < xMin) xMin = x
        if (x > xMax) xMax = x
        if (y < yMin) yMin = y
        if (y > yMax) yMax = y
      
      // Log first few coordinates for debugging
      if (i < 3) {
        console.log(`  Coordinate ${i + 1}: [${int16View[idx]}, ${int16View[idx + 1]}] -> [${x}, ${y}]`)
      }
    }
    
    const decompressTime = performance.now() - decompressStart
    const pairsPerSec = Math.round(numPairs / decompressTime * 1000)
    
    console.log(`⏱️ [PERF] Binary decompression: ${numPairs.toLocaleString()} pairs in ${decompressTime.toFixed(2)}ms (${pairsPerSec.toLocaleString()} pairs/sec)`)
    console.log(`  Range: X[${xMin.toFixed(2)}, ${xMax.toFixed(2)}] Y[${yMin.toFixed(2)}, ${yMax.toFixed(2)}]`)
    
    return coordinates
  }

  // Load a single metadata vector on demand
  async loadSingleMetadataVector(metadataId) {
    console.log(`=== LOADING SINGLE METADATA VECTOR: ${metadataId} ===`)
    console.log(`Call stack:`, new Error().stack)
    
    // Check if already loaded in memory
    if (this.loadedMetadataVectors[metadataId]) {
      console.log(`💾 Metadata vector ${metadataId} already in memory`)
      const cachedData = this.loadedMetadataVectors[metadataId]
      console.log('Cached data:', cachedData)
      console.log('Cached compressed_data:', cachedData.compressed_data)
      console.log('Cached compression_info:', cachedData.compression_info)
      return cachedData
    }
    
    // Try to load from IndexedDB (disk storage) - ONLY on cold start (nothing in memory yet)
    // This avoids race conditions during active preloading
    const isSessionColdStart = Object.keys(this.loadedMetadataVectors).length === 0
    
    if (isSessionColdStart && !this.loadingMetadataVectors.has(metadataId)) {
      const diskData = await this.loadMetadataFromIndexedDB(metadataId)
      if (diskData) {
        console.log(`💾 ✅ Loaded metadata ${metadataId} from IndexedDB (disk) - saved bandwidth!`)
        
        // Remove IndexedDB metadata fields before returning
        const cleanData = { ...diskData }
        delete cleanData.loomFile
        delete cleanData.timestamp
        
        this.loadedMetadataVectors[metadataId] = cleanData
        return cleanData
      }
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
        
        // FIRST: Store in memory cache immediately
        this.loadedMetadataVectors[metadataId] = vectorData
        this.metadataVectorsLoomFile = data.loom_file
        
        const info = vectorData.compression_info
        console.log(`Successfully loaded metadata ${vectorData.name} (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
        
        // THEN: Store in IndexedDB asynchronously for future use (don't await - fire and forget)
        this.storeMetadataInIndexedDB(metadataId, vectorData).catch(error => {
          console.warn('Failed to store in IndexedDB, but will keep in memory:', error)
        })
        
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
      actualRange: `${this.safeMin(numericValues).toFixed(3)} to ${this.safeMax(numericValues).toFixed(3)}`
    })*/
    
    return numericValues
  }

  // Show spinner next to metadata dropdown
  showMetadataDropdownSpinner() {
    const dropdown = document.getElementById('metadata-select-dropdown')
    const spinner = document.getElementById('metadata-loading-spinner')
    
    if (dropdown) {
      dropdown.disabled = true
      dropdown.style.opacity = '0.6'
    }
    if (spinner) {
      spinner.style.display = 'block'
    }
  }

  // Hide spinner and re-enable metadata dropdown
  hideMetadataDropdownSpinner() {
    const dropdown = document.getElementById('metadata-select-dropdown')
    const spinner = document.getElementById('metadata-loading-spinner')
    
    if (dropdown) {
      dropdown.disabled = false
      dropdown.style.opacity = '1'
    }
    if (spinner) {
      spinner.style.display = 'none'
    }
  }
  // Load and visualize metadata vector for a specific metadata ID
  async loadAndVisualizeMetadataVector(metadataId) {
    console.log(`Loading and visualizing metadata vector for ID: ${metadataId}`)
    
    // Ensure metadata is loaded into memory for fast access
    let vectorData = await this.loadSingleMetadataVector(metadataId)
    
    if (!vectorData) {
      console.error('Failed to load metadata vector for:', metadataId)
      console.error('loadedMetadataVectors:', Object.keys(this.loadedMetadataVectors))
      console.error('IndexedDB available:', !!this.db)
      return
    }
    
    console.log('✅ Successfully loaded metadata vector:', {
      id: vectorData.id || metadataId,
      name: vectorData.name,
      dataType: vectorData.data_type,
      hasValues: !!vectorData.values,
      hasCompressedData: !!vectorData.compressed_data,
      valuesLength: vectorData.values?.length
    })
    
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
            const minVal = this.safeMin(numericValues)
            const maxVal = this.safeMax(numericValues)
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
    
    // Note: We keep metadata in memory during the session for fast switching
    // IndexedDB is used for persistence across page reloads
    // Memory will be managed by browser's garbage collector
    
    // Show checkboxes for this metadata now that it's loaded
    this.showCheckboxesForMetadata(metadataId)
    
    // Clear incremental state when new metadata is loaded
    this.clearIncrementalState()
    
    // Clear performance caches for new metadata
    this.clearPerformanceCaches()
    
    // Don't clear checkbox selections - preserve them when switching metadata
    // This allows users to maintain their filter selections across different visualizations
    
    // Update settings window state
    this.updateCategoriesCheckboxState()
    
    // Also store the metadata ID for color mapping
    this.currentMetadataId = metadataId

    // Clear the cached color map since we have new metadata
    this.clearColorMapCache()
    
    // Clear old category labels before rendering new metadata
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.removeChildren()
    }
    
    // Initialize gradient BEFORE updating visualization for continuous metadata
    if (this.currentMetadataVector?.data_type === 'NUMERIC') {
      // Initialize default gradient based on data distribution
      this.initializeDefaultGradient()
    }
    
    // Update visualization with metadata coloring
    this.updateVisualizationWithMetadataVector()
    
    // Initialize checkboxes for the new metadata (only for discrete)
    if (this.currentMetadataVector?.data_type === 'DISCRETE') {
      this.initializeAllCheckboxes()
    }
    
    // Update cell filtering after loading metadata vector
    // Pass shouldUpdateColors=true for continuous metadata to ensure colors are rendered after filtering
    const shouldUpdateColors = this.currentMetadataVector?.data_type === 'NUMERIC'
    this.updateCellFiltering(shouldUpdateColors)

    // Initialize gradient legend listeners for continuous metadata
    if (this.currentMetadataVector?.data_type === 'NUMERIC') {
      this.initializeGradientLegendListeners()
    } else {
      // Disable pointer events on overlay for discrete metadata
      // This allows interactions with the plot below
      if (this.overlayCanvas) {
        this.overlayCanvas.style.pointerEvents = 'none'
      }
    }
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
    
    // Check if already loaded in memory
    if (this.loadedMetadataVectors[metadataId]) {
      //console.log(`💾 Metadata ${metadataId} already in memory`)
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
      
      // Special debugging for sex and age metadata
      const metadataName = this.getMetadataNameById(metadataId)
      if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
        console.log(`🔍 [SEX/AGE DEBUG] About to request ${metadataName} (${metadataId})`)
        console.log(`🔍 [SEX/AGE DEBUG] Loom file selector value: "${this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : 'N/A'}"`)
        console.log(`🔍 [SEX/AGE DEBUG] Default loom file value: "${this.defaultLoomFileValue}"`)
        console.log(`🔍 [SEX/AGE DEBUG] Final loom file: "${loomFile}"`)
      }
      
      // Check if loom file is available
      if (!loomFile) {
        const errorMsg = `No loom file available for metadata ${metadataId}`
        if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
          console.log(`🔍 [SEX/AGE DEBUG] ${errorMsg}`)
        }
        throw new Error(errorMsg)
      }
      
      // Build the URL for the single metadata vector endpoint
      const projectId = window.location.pathname.split('/')[2] // Extract project ID from URL
      const url = `/projects/${projectId}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      // Additional debugging for sex and age metadata
      if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
        console.log(`🔍 [SEX/AGE DEBUG] Requesting ${metadataName} (${metadataId}) from URL: ${url}`)
        console.log(`🔍 [SEX/AGE DEBUG] Current loom file: "${loomFile}"`)
        console.log(`🔍 [SEX/AGE DEBUG] Project ID: ${projectId}`)
      }
      
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
      // Reduced logging for cleaner output
      
      // Special debugging for sex and age metadata
      if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
        console.log(`🔍 [SEX/AGE DEBUG] Server response for ${metadataName} (${metadataId}):`, {
          hasMetadataVectors: !!data.metadata_vectors,
          metadataVectorsKeys: data.metadata_vectors ? Object.keys(data.metadata_vectors) : [],
          requestedId: metadataId,
          foundInResponse: !!data.metadata_vectors?.[metadataId],
          totalLoaded: data.total_loaded,
          availableLoomFiles: data.loom_files,
          requestedLoomFile: loomFile,
          fullResponse: data
        })
      }
      
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
        
        // FIRST: Store in memory cache immediately to avoid race conditions
        this.loadedMetadataVectors[metadataId] = vectorData
        this.metadataVectorsLoomFile = data.loom_file
        
        const info = vectorData.compression_info
        //console.log(`Successfully loaded metadata ${vectorData.name} silently (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
        
        // THEN: Store in IndexedDB for disk storage (fire and forget)
        this.storeMetadataInIndexedDB(metadataId, vectorData).catch(error => {
          console.warn('Failed to store in IndexedDB:', error)
        })
        
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
    // Show spinner in place of the metadata checkbox
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    if (metadataCheckbox) {
      // Store original content if not already stored
      if (!metadataCheckbox.dataset.originalContent) {
        metadataCheckbox.dataset.originalContent = metadataCheckbox.innerHTML
      }
      
      // Show the checkbox container and replace content with spinner
      metadataCheckbox.style.display = 'flex'
      metadataCheckbox.innerHTML = `
        <svg style="width: 12px; height: 12px; animation: spin 1s linear infinite;" fill="none" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566" opacity="0.25"/>
          <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566">
            <animate attributeName="stroke-dashoffset" dur="1.5s" values="12.566;0;12.566" repeatCount="indefinite"/>
          </circle>
        </svg>
      `
      
      // Disable checkbox during loading
      metadataCheckbox.style.pointerEvents = 'none'
      metadataCheckbox.style.opacity = '0.7'
    }
    
    // Also show spinner on water drop button for consistency
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-action*="waterDropClicked"]`)
    if (button) {
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
      
      // Disable button during loading
      button.disabled = true
      button.style.cursor = 'wait'
    }
    
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
    
    //console.log(`Showing loading spinner for metadata ${metadataId}`)
  }

  // Hide loading spinner for a specific metadata ID
  hideLoadingSpinner(metadataId) {
    // Restore the metadata checkbox
    const metadataCheckbox = document.querySelector(`.metadata-checkbox[data-metadata-id="${metadataId}"]`)
    if (metadataCheckbox) {
      // Restore original content
      if (metadataCheckbox.dataset.originalContent) {
        metadataCheckbox.innerHTML = metadataCheckbox.dataset.originalContent
      }
      
      // Re-enable checkbox
      metadataCheckbox.style.pointerEvents = 'auto'
      metadataCheckbox.style.opacity = '1'
      
      // Keep the checkbox visible since metadata is now loaded
      metadataCheckbox.style.display = 'flex'
    }
    
    // Restore the water drop button
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-action*="waterDropClicked"]`)
    if (button) {
      // Restore original content
      if (button.dataset.originalContent) {
        button.innerHTML = button.dataset.originalContent
      }
      
      // Re-enable button
      button.disabled = false
      button.style.cursor = 'pointer'
    } else {
      console.log(`Could not find water drop button for metadata ID: ${metadataId}`)
    }
    
    //console.log(`Hiding loading spinner for metadata ${metadataId}`)
  }

  // Preload metadata vector on hover for better UX
  preloadMetadataVector(event) {
    const button = event.currentTarget
    const metadataId = button.dataset.metadataId
    
    // Debounce: Only preload if mouse stays on element for 300ms
    // This prevents UI lag when quickly moving mouse over items
    if (this.preloadTimeout) {
      clearTimeout(this.preloadTimeout)
    }
    
    this.preloadTimeout = setTimeout(() => {
    // Only preload if not already loaded and not currently loading
    if (!this.loadedMetadataVectors[metadataId] && !this.loadingMetadataVectors.has(metadataId)) {
      console.log(`🚀 Preloading metadata vector ${metadataId} on hover`)
      // Load silently without showing spinners
      this.loadSingleMetadataVectorSilently(metadataId).catch(error => {
        console.log(`Preload failed for metadata ${metadataId}:`, error.message)
        // Don't show error to user for preloading failures
      })
      }
    }, 300) // 300ms delay - only preload if user hovers for a bit
  }
  
  // Cancel preload if user quickly moves away
  cancelPreload(event) {
    if (this.preloadTimeout) {
      clearTimeout(this.preloadTimeout)
      this.preloadTimeout = null
    }
  }
  
  // Helper function to get metadata name by ID
  getMetadataNameById(metadataId) {
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-metadata-name]`)
    return button ? button.dataset.metadataName : null
  }

  // Calculate optimal memory buffer size based on dataset characteristics
  calculateOptimalBufferSize() {
    // Get dataset size information
    const totalCells = this.currentCoordinates?.length || 0
    const totalMetadata = document.querySelectorAll('button[data-metadata-id]').length
    
    console.log(`🧠 [Memory] Calculating buffer size for dataset: ${totalCells} cells, ${totalMetadata} metadata`)
    
    // Base buffer size on dataset size and available metadata
    let bufferSize = 5 // Default minimum
    
    if (totalCells > 100000) {
      // Large datasets: smaller buffer to save memory
      bufferSize = Math.min(3, totalMetadata)
    } else if (totalCells > 50000) {
      // Medium datasets: moderate buffer
      bufferSize = Math.min(5, totalMetadata)
    } else if (totalCells > 10000) {
      // Small datasets: larger buffer for better performance
      bufferSize = Math.min(8, totalMetadata)
    } else {
      // Very small datasets: can afford larger buffer
      bufferSize = Math.min(10, totalMetadata)
    }
    
    // Ensure we always keep at least 1 metadata in memory (current one)
    bufferSize = Math.max(1, bufferSize)
    
    console.log(`🧠 [Memory] Optimal buffer size: ${bufferSize} metadata vectors`)
    return bufferSize
  }

  // Update metadata usage tracker
  updateMetadataUsage(metadataId) {
    const now = Date.now()
    this.metadataUsageTracker.set(metadataId, now)
    console.log(`🧠 [Memory] Updated usage for metadata ${metadataId} at ${now}`)
  }

  // Get least recently used metadata IDs
  getLeastRecentlyUsedMetadata(limit = 1) {
    const entries = Array.from(this.metadataUsageTracker.entries())
      .sort((a, b) => a[1] - b[1]) // Sort by timestamp (oldest first)
      .slice(0, limit)
    
    return entries.map(([metadataId]) => metadataId)
  }

  // Run comprehensive metadata diagnostic
  async runMetadataDiagnostic() {
    console.log(`\n🔍 [DIAGNOSTIC] Starting comprehensive metadata analysis... (v2.0 - Fixed disk-first logic)`)
    
    // 1. Check UI metadata
    const allMetadataButtons = document.querySelectorAll('button[data-metadata-id]')
    const uiMetadataIds = Array.from(allMetadataButtons).map(btn => btn.dataset.metadataId).filter(id => id)
    const uiMetadataInfo = Array.from(allMetadataButtons).map(btn => ({
      id: btn.dataset.metadataId,
      name: btn.dataset.metadataName,
      type: btn.dataset.metadataType,
      hasMetadataItem: !!btn.closest('[data-metadata-item]'),
      hasWaterDropAction: btn.dataset.action?.includes('waterDropClicked')
    }))
    
    console.log(`🔍 [DIAGNOSTIC] UI Metadata Analysis:`)
    console.log(`  📊 Total metadata buttons found: ${allMetadataButtons.length}`)
    console.log(`  📊 Valid metadata IDs: ${uiMetadataIds.length}`)
    console.log(`  📊 First 10 UI metadata IDs:`, uiMetadataIds.slice(0, 10))
    console.log(`  📊 Last 10 UI metadata IDs:`, uiMetadataIds.slice(-10))
    
    // 2. Check IndexedDB storage
    let indexedDBMetadata = []
    if (this.db) {
      try {
        const transaction = this.db.transaction(['metadataVectors'], 'readonly')
        const objectStore = transaction.objectStore('metadataVectors')
        const request = objectStore.getAll()
        
        indexedDBMetadata = await new Promise((resolve) => {
          request.onsuccess = () => {
            resolve(request.result || [])
          }
          request.onerror = () => {
            console.error('Failed to read from IndexedDB')
            resolve([])
          }
        })
      } catch (error) {
        console.error('Error accessing IndexedDB:', error)
      }
    }
    
    const storedIds = indexedDBMetadata.map(m => m.id)
    console.log(`🔍 [DIAGNOSTIC] IndexedDB Analysis:`)
    console.log(`  💾 Total metadata stored: ${indexedDBMetadata.length}`)
    console.log(`  💾 First 10 stored metadata IDs:`, storedIds.slice(0, 10))
    console.log(`  💾 Last 10 stored metadata IDs:`, storedIds.slice(-10))
    
    // 3. Check memory storage
    const memoryIds = Object.keys(this.loadedMetadataVectors)
    console.log(`🔍 [DIAGNOSTIC] Memory Analysis:`)
    console.log(`  🧠 Metadata in memory: ${memoryIds.length}`)
    console.log(`  🧠 Memory metadata IDs:`, memoryIds)
    console.log(`  🧠 Buffer size: ${this.maxMetadataInMemory}`)
    console.log(`  🧠 Buffer utilization: ${((memoryIds.length / this.maxMetadataInMemory) * 100).toFixed(1)}%`)
    
    // 4. Find mismatches (with disk-first approach understanding)
    // For disk-first approach: metadata can be in IndexedDB without being in memory
    const availableMetadata = [...new Set([...storedIds, ...memoryIds])]
    const missingMetadata = uiMetadataIds.filter(id => !availableMetadata.includes(id))
    const storedOnly = storedIds.filter(id => !uiMetadataIds.includes(id))
    const memoryOnly = memoryIds.filter(id => !storedIds.includes(id))
    
    console.log(`🔍 [DIAGNOSTIC] Mismatch Analysis:`)
    console.log(`  🔍 Debug: UI metadata count: ${uiMetadataIds.length}`)
    console.log(`  🔍 Debug: IndexedDB metadata count: ${storedIds.length}`)
    console.log(`  🔍 Debug: Memory metadata count: ${memoryIds.length}`)
    console.log(`  🔍 Debug: Available metadata count: ${availableMetadata.length}`)
    
    if (missingMetadata.length > 0) {
      console.log(`  ⚠️ UI metadata not available anywhere:`, missingMetadata)
    }
    if (storedOnly.length > 0) {
      console.log(`  ⚠️ IndexedDB-only metadata (not in UI):`, storedOnly)
    }
    if (memoryOnly.length > 0) {
      console.log(`  ⚠️ Memory-only metadata (not in IndexedDB):`, memoryOnly)
    }
    
    console.log(`🔍 [DIAGNOSTIC] Availability Summary:`)
    console.log(`  ✅ Available metadata (disk + memory): ${availableMetadata.length}`)
    console.log(`  ❌ Missing metadata: ${missingMetadata.length}`)
    const coverage = uiMetadataIds.length > 0 ? ((availableMetadata.length / uiMetadataIds.length) * 100).toFixed(1) : '0.0'
    console.log(`  📊 Coverage: ${coverage}%`)
    console.log(`  📊 Note: Coverage > 100% means IndexedDB has more metadata than UI (possible with old data)`)
    
    // 5. Check specific problematic metadata
    const problematicId = '469981' // Changed to the one mentioned by user
    console.log(`🔍 [DIAGNOSTIC] Problematic Metadata Analysis (ID: ${problematicId}):`)
    console.log(`  🔍 In UI:`, uiMetadataIds.includes(problematicId))
    console.log(`  🔍 In IndexedDB:`, storedIds.includes(problematicId))
    console.log(`  🔍 In Memory:`, memoryIds.includes(problematicId))
    console.log(`  🔍 In Available:`, availableMetadata.includes(problematicId))
    console.log(`  🔍 In Missing:`, missingMetadata.includes(problematicId))
    console.log(`  🔍 In StoredOnly:`, storedOnly.includes(problematicId))
    
    if (uiMetadataIds.includes(problematicId)) {
      const uiInfo = uiMetadataInfo.find(m => m.id === problematicId)
      console.log(`  🔍 UI Info:`, uiInfo)
    }
    
    if (storedIds.includes(problematicId)) {
      const storedInfo = indexedDBMetadata.find(m => m.id === problematicId)
      console.log(`  🔍 IndexedDB Info:`, {
        id: storedInfo.id,
        name: storedInfo.name,
        data_type: storedInfo.data_type,
        loomFile: storedInfo.loomFile,
        hasValues: !!storedInfo.values,
        hasCompressedData: !!storedInfo.compressed_data
      })
    }
    
    // 6. Recommendations
    console.log(`🔍 [DIAGNOSTIC] Recommendations:`)
    if (missingMetadata.length > 0) {
      console.log(`  💡 Consider preloading missing UI metadata: ${missingMetadata.join(', ')}`)
    }
    if (storedOnly.length > 0) {
      console.log(`  💡 Consider cleaning up orphaned IndexedDB metadata: ${storedOnly.join(', ')}`)
    }
    
    // Additional recommendations based on disk-first approach
    if (availableMetadata.length === uiMetadataIds.length) {
      console.log(`  ✅ All UI metadata are available (disk-first approach working correctly)`)
    }
    if (memoryIds.length > 0) {
      console.log(`  💡 Memory contains ${memoryIds.length} metadata (LRU cache active)`)
    }
    if (memoryOnly.length > 0) {
      console.log(`  💡 Consider syncing memory-only metadata to IndexedDB`)
    }
    
    console.log(`🔍 [DIAGNOSTIC] Analysis complete! (Updated: ${new Date().toISOString()})`)
    
    return {
      uiMetadata: uiMetadataInfo,
      indexedDBMetadata: indexedDBMetadata,
      memoryMetadata: memoryIds,
      mismatches: {
        missingMetadata,
        storedOnly,
        memoryOnly
      }
    }
  }

  // Emergency diagnostic for infinite loop detection
  runEmergencyDiagnostic() {
    console.log(`🚨 [EMERGENCY DIAGNOSTIC] Starting...`)
    
    console.log(`🔍 Loading call counts:`, this.loadingCallCount ? Object.fromEntries(this.loadingCallCount) : 'None')
    console.log(`🔍 Currently loading:`, Array.from(this.loadingMetadataVectors))
    console.log(`🔍 Loaded in memory:`, Object.keys(this.loadedMetadataVectors))
    
    // Check for problematic metadata
    if (this.loadingCallCount) {
      const problematicMetadata = Array.from(this.loadingCallCount.entries())
        .filter(([id, count]) => count > 3)
        .map(([id, count]) => `${id} (${count} calls)`)
      
      if (problematicMetadata.length > 0) {
        console.error(`🚨 PROBLEMATIC METADATA:`, problematicMetadata)
      }
    }
    
    console.log(`🚨 [EMERGENCY DIAGNOSTIC] Complete`)
  }

  // Create and show diagnostic button
  createDiagnosticButton() {
    console.log('🔍 [DIAGNOSTIC] Creating diagnostic button...')
    
    // Hide the diagnostic button - return early without creating it
    console.log('🔍 [DIAGNOSTIC] Diagnostic button is hidden')
    return
    
    // Remove existing diagnostic button if it exists
    const existingButton = document.getElementById('metadata-diagnostic-btn')
    if (existingButton) {
      console.log('🔍 [DIAGNOSTIC] Removing existing button')
      existingButton.remove()
    }

    // Create diagnostic button
    const diagnosticBtn = document.createElement('button')
    diagnosticBtn.id = 'metadata-diagnostic-btn'
    diagnosticBtn.className = 'btn btn-outline-info btn-sm'
    diagnosticBtn.innerHTML = '🔍 Run Metadata Diagnostic'
    diagnosticBtn.style.margin = '10px'
    diagnosticBtn.style.position = 'fixed'
    diagnosticBtn.style.top = '10px'
    diagnosticBtn.style.right = '10px'
    diagnosticBtn.style.zIndex = '9999'
    diagnosticBtn.style.backgroundColor = '#17a2b8'
    diagnosticBtn.style.color = 'white'
    diagnosticBtn.style.border = '1px solid #17a2b8'
    diagnosticBtn.style.borderRadius = '4px'
    diagnosticBtn.style.padding = '8px 16px'
    diagnosticBtn.style.fontSize = '14px'
    diagnosticBtn.style.cursor = 'pointer'
    diagnosticBtn.style.boxShadow = '0 2px 4px rgba(0,0,0,0.2)'
    
    diagnosticBtn.addEventListener('click', async () => {
      console.log('🔍 [DIAGNOSTIC] Button clicked, starting diagnostic...')
      diagnosticBtn.disabled = true
      diagnosticBtn.innerHTML = '🔍 Running Diagnostic...'
      
      try {
        await this.runMetadataDiagnostic()
        diagnosticBtn.innerHTML = '✅ Diagnostic Complete'
        setTimeout(() => {
          diagnosticBtn.innerHTML = '🔍 Run Metadata Diagnostic'
          diagnosticBtn.disabled = false
        }, 3000)
      } catch (error) {
        console.error('Diagnostic failed:', error)
        diagnosticBtn.innerHTML = '❌ Diagnostic Failed'
        setTimeout(() => {
          diagnosticBtn.innerHTML = '🔍 Run Metadata Diagnostic'
          diagnosticBtn.disabled = false
        }, 3000)
      }
    })

    // Add to page
    document.body.appendChild(diagnosticBtn)
    console.log('🔍 [DIAGNOSTIC] Diagnostic button created and added to page')
    console.log('🔍 [DIAGNOSTIC] Button element:', diagnosticBtn)
    console.log('🔍 [DIAGNOSTIC] Button position:', {
      top: diagnosticBtn.style.top,
      right: diagnosticBtn.style.right,
      position: diagnosticBtn.style.position,
      zIndex: diagnosticBtn.style.zIndex
    })
    
    // Also make it available globally for manual testing
    window.showDiagnosticButton = () => {
      console.log('🔍 [DIAGNOSTIC] Manual button creation triggered')
      this.createDiagnosticButton()
    }
    
    console.log('🔍 [DIAGNOSTIC] You can also call window.showDiagnosticButton() to manually show the button')
  }

  // Clean up unused metadata from memory
  cleanupUnusedMetadata() {
    const currentCount = Object.keys(this.loadedMetadataVectors).length
    
    if (currentCount <= this.maxMetadataInMemory) {
      console.log(`🧠 [Memory] No cleanup needed: ${currentCount}/${this.maxMetadataInMemory} metadata in memory`)
      return
    }
    
    const toRemove = currentCount - this.maxMetadataInMemory
    console.log(`🧠 [Memory] Need to remove ${toRemove} metadata vectors from memory`)
    
    // Get the least recently used metadata
    const lruMetadata = this.getLeastRecentlyUsedMetadata(toRemove)
    
    // Don't remove the current metadata
    const currentMetadataId = this.currentMetadataVector?.id
    const metadataToRemove = lruMetadata.filter(id => id !== currentMetadataId)
    
    let removedCount = 0
    metadataToRemove.forEach(metadataId => {
      if (this.loadedMetadataVectors[metadataId]) {
        delete this.loadedMetadataVectors[metadataId]
        this.metadataUsageTracker.delete(metadataId)
        removedCount++
        console.log(`🧠 [Memory] Removed metadata ${metadataId} from memory`)
      }
    })
    
    console.log(`🧠 [Memory] Cleanup complete: removed ${removedCount} metadata vectors`)
    
    // Force garbage collection if available
    if (window.gc) {
      window.gc()
      console.log(`🧠 [Memory] Forced garbage collection`)
    }
  }

  // Preload metadata vector directly to disk (IndexedDB) without keeping in memory
  async preloadMetadataToDisk(metadataId) {
    console.log(`💾 [DISK] Preloading metadata ${metadataId} directly to disk...`)
    
    // Check if already stored on disk
    const existingData = await this.loadMetadataFromIndexedDB(metadataId)
    if (existingData) {
      console.log(`💾 [DISK] Metadata ${metadataId} already exists on disk`)
      return { success: true, cached: true }
    }
    
    // Check if currently loading
    if (this.loadingMetadataVectors.has(metadataId)) {
      console.log(`💾 [DISK] Metadata ${metadataId} is currently loading, waiting...`)
      while (this.loadingMetadataVectors.has(metadataId)) {
        await new Promise(resolve => setTimeout(resolve, 100))
      }
      return { success: true, cached: true }
    }
    
    // Mark as loading
    this.loadingMetadataVectors.add(metadataId)
    
    try {
      // Get the current loom file
      const loomFile = this.hasLoomFileSelectTarget ? this.loomFileSelectTarget.value : this.defaultLoomFileValue
      
      if (!loomFile) {
        throw new Error(`No loom file available for metadata ${metadataId}`)
      }
      
      // Build the URL for the single metadata vector endpoint
      const projectId = window.location.pathname.split('/')[2]
      const url = `/projects/${projectId}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile)}`
      
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
        
        // Store directly to IndexedDB (disk) without keeping in memory
        const storeSuccess = await this.storeMetadataInIndexedDB(metadataId, vectorData)
        
        if (storeSuccess) {
          const info = vectorData.compression_info
          console.log(`💾 [DISK] Successfully stored metadata ${vectorData.name} to disk (${info.type}): ${info.binary_size} bytes`)
          
          // Show checkboxes for this metadata now that it's available on disk
          this.showCheckboxesForMetadata(metadataId)
          
          return { success: true, cached: false, size: info.binary_size }
        } else {
          throw new Error('Failed to store metadata to IndexedDB')
        }
      } else {
        throw new Error(`Metadata vector ${metadataId} not found in response`)
      }
      
    } catch (error) {
      console.error(`💾 [DISK] Error preloading metadata ${metadataId} to disk:`, error)
      return { success: false, error: error.message }
    } finally {
      // Remove from loading set
      this.loadingMetadataVectors.delete(metadataId)
    }
  }

  // Assess performance after preloading to identify optimization opportunities
  async assessPerformanceAfterPreload() {
    console.log(`\n🔍 [PERF] Assessing performance after preloading...`)
    
    // Memory usage analysis
    const memoryInfo = this.logMemoryUsage('Performance Assessment')
    
    // Count loaded metadata vectors and estimate memory usage
    const loadedMetadataCount = Object.keys(this.loadedMetadataVectors).length
    const loadingCount = this.loadingMetadataVectors.size
    
    console.log(`📊 [PERF] Metadata vectors in memory: ${loadedMetadataCount}/${this.maxMetadataInMemory}`)
    console.log(`📊 [PERF] Currently loading: ${loadingCount}`)
    console.log(`💾 [PERF] Using disk-first preloading with LRU memory buffer`)
    console.log(`🧠 [Memory] Buffer utilization: ${((loadedMetadataCount / this.maxMetadataInMemory) * 100).toFixed(1)}%`)
    
    // Estimate memory usage per metadata vector (only what's actually in memory)
    let totalEstimatedMemory = 0
    let largestMetadata = null
    let largestSize = 0
    
    Object.entries(this.loadedMetadataVectors).forEach(([id, data]) => {
      if (data && data.compression_info) {
        const size = data.compression_info.binary_size || 0
        totalEstimatedMemory += size
        
        if (size > largestSize) {
          largestSize = size
          largestMetadata = { id, name: this.getMetadataNameById(id), size }
        }
      }
    })
    
    console.log(`📊 [PERF] Estimated metadata memory usage: ${(totalEstimatedMemory / 1024 / 1024).toFixed(2)} MB (only active metadata)`)
    if (largestMetadata) {
      console.log(`📊 [PERF] Largest metadata in memory: ${largestMetadata.name} (${(largestMetadata.size / 1024 / 1024).toFixed(2)} MB)`)
    }
    
    // Performance timing test
    const startTime = performance.now()
    
    // Test DOM responsiveness
    const testElement = document.createElement('div')
    document.body.appendChild(testElement)
    testElement.style.display = 'none'
    document.body.removeChild(testElement)
    
    const domTime = performance.now() - startTime
    
    // Test JavaScript responsiveness
    const jsStartTime = performance.now()
    let testSum = 0
    for (let i = 0; i < 10000; i++) {
      testSum += Math.random()
    }
    const jsTime = performance.now() - jsStartTime
    
    console.log(`⏱️ [PERF] DOM responsiveness: ${domTime.toFixed(2)}ms`)
    console.log(`⏱️ [PERF] JavaScript responsiveness: ${jsTime.toFixed(2)}ms`)
    
    // Performance recommendations
    const recommendations = []
    
    if (loadedMetadataCount > this.maxMetadataInMemory) {
      recommendations.push('Memory buffer exceeded (' + loadedMetadataCount + '/' + this.maxMetadataInMemory + ' metadata) - LRU cleanup should trigger')
    }
    
    if (totalEstimatedMemory > 100) { // More than 100MB in memory
      recommendations.push('High memory usage detected (' + (totalEstimatedMemory / 1024 / 1024).toFixed(2) + 'MB) - consider reducing buffer size')
    }
    
    if (domTime > 10) {
      recommendations.push('DOM operations are slow (' + domTime.toFixed(2) + 'ms) - browser may be under memory pressure')
    }
    
    if (jsTime > 5) {
      recommendations.push('JavaScript execution is slow (' + jsTime.toFixed(2) + 'ms) - consider reducing memory usage')
    }
    
    if (loadedMetadataCount <= 3 && totalEstimatedMemory < 20) {
      recommendations.push('✅ Memory usage is optimal - using disk-first approach effectively')
    }
    
    if (recommendations.length > 0) {
      console.log(`💡 [PERF] Performance recommendations:`)
      recommendations.forEach((rec, index) => {
        console.log(`  ${index + 1}. ${rec}`)
      })
    } else {
      console.log(`✅ [PERF] Performance looks good!`)
    }
    
    // Suggest memory optimization if needed (with LRU system, this should rarely be needed)
    if (loadedMetadataCount > this.maxMetadataInMemory || totalEstimatedMemory > 50) {
      console.log(`\n🔧 [PERF] Suggesting memory optimization...`)
      this.optimizeMemoryUsage()
    }
    
    return {
      loadedMetadataCount,
      totalEstimatedMemory,
      domTime,
      jsTime,
      recommendations
    }
  }

  // Optimize memory usage by implementing LRU-based memory management
  optimizeMemoryUsage() {
    console.log(`🔧 [PERF] Starting LRU-based memory optimization...`)
    
    const loadedCount = Object.keys(this.loadedMetadataVectors).length
    if (loadedCount <= this.maxMetadataInMemory) {
      console.log(`🔧 [PERF] Memory usage is optimal (${loadedCount}/${this.maxMetadataInMemory} metadata vectors) - LRU buffer working well`)
      return
    }
    
    // Use the LRU cleanup system
    this.cleanupUnusedMetadata()
    
    console.log(`🔧 [PERF] LRU-based memory optimization complete`)
    console.log(`  📊 Buffer size: ${this.maxMetadataInMemory} metadata vectors`)
    console.log(`  💾 All metadata is available on disk via IndexedDB`)
    console.log(`  🧠 LRU system automatically manages memory usage`)
    
    // Log memory usage after optimization
    setTimeout(() => {
      this.logMemoryUsage('After LRU memory optimization')
    }, 1000)
  }

  // Preload all metadata (embeddings + metadata vectors) for instant switching
  async preloadAllMetadata() {
    console.log('🚀 [PERF] Starting background preload of all metadata...')
    
    // Calculate and set optimal buffer size based on dataset characteristics
    this.maxMetadataInMemory = this.calculateOptimalBufferSize()
    console.log(`🧠 [Memory] Set memory buffer size to ${this.maxMetadataInMemory} metadata vectors`)
    
    // Separate metadata by type for ordered preloading
    const visualizationEmbeddings = []
    const categoricalMetadata = []
    const continuousMetadata = []
    
    // 1. Get visualization embeddings from dropdown (2D/3D coordinate data)
    const embeddingDropdown = document.getElementById('metadata-select-dropdown')
    if (embeddingDropdown) {
      const options = embeddingDropdown.querySelectorAll('option[value]:not([value=""])')
      options.forEach(option => {
        const embeddingId = option.value
        const embeddingName = option.textContent
        if (embeddingId) {
          visualizationEmbeddings.push({ id: embeddingId, name: embeddingName })
        }
      })
    }
    
    // Use Sets to avoid duplicates (multiple elements might have same metadata-id)
    const categoricalSet = new Set()
    const continuousSet = new Set()
    const embeddingSet = new Set(visualizationEmbeddings.map(e => e.id))
    
    // 2. Get categorical and continuous metadata from the palette buttons
    const metadataButtons = document.querySelectorAll('[data-metadata-item] button[data-action*="waterDropClicked"][data-metadata-id][data-metadata-type]')
    console.log(`🔍 [Preload Debug] Found ${metadataButtons.length} metadata palette buttons in left panel`)
    
    // Debug: Let's also check for all buttons with metadata attributes
    const allMetadataButtons = document.querySelectorAll('button[data-metadata-id]')
    console.log(`🔍 [Preload Debug] Found ${allMetadataButtons.length} total buttons with data-metadata-id`)
    
    // Debug: Check for sex and age buttons specifically
    allMetadataButtons.forEach(btn => {
      const name = btn.dataset.metadataName
      if (name && (name.toLowerCase().includes('sex') || name.toLowerCase().includes('age'))) {
        console.log(`🔍 [SEX/AGE DEBUG] Found button for ${name}:`, {
          hasMetadataItem: !!btn.closest('[data-metadata-item]'),
          hasWaterDropAction: btn.dataset.action?.includes('waterDropClicked'),
          hasMetadataId: !!btn.dataset.metadataId,
          hasMetadataType: !!btn.dataset.metadataType,
          metadataType: btn.dataset.metadataType,
          element: btn
        })
      }
    })
    
    // Debug info removed - use diagnostic button for detailed analysis
    
    metadataButtons.forEach(btn => {
      const metadataId = btn.dataset.metadataId
      const metadataType = btn.dataset.metadataType
      const metadataName = btn.dataset.metadataName || 'unknown'
      
      // Special logging for sex and age metadata
      if (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age')) {
        console.log(`🔍 [SEX/AGE DEBUG] Found metadata: ${metadataName} (${metadataId}) - Type: ${metadataType}`)
        console.log(`🔍 [SEX/AGE DEBUG] Button element:`, btn)
        console.log(`🔍 [SEX/AGE DEBUG] Button dataset:`, btn.dataset)
      }
      
      if (!metadataId) return
      
      // Process categorical and continuous metadata (excluding embeddings)
      if (metadataType === 'DISCRETE') {
        if (!categoricalSet.has(metadataId)) {
          categoricalSet.add(metadataId)
          console.log(`  ✅ Categorical: ${metadataName} (${metadataId})`)
          
          // Special logging for sex and age
          if (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age')) {
            console.log(`🔍 [SEX/AGE DEBUG] Added to categorical set: ${metadataName}`)
          }
        }
      } else if (metadataType === 'NUMERIC') {
        // Skip if it's an embedding (will be preloaded separately)
        if (embeddingSet.has(metadataId)) {
          console.log(`  📊 Embedding: ${metadataName} (${metadataId}) - will preload with embeddings`)
          
          // Special logging for sex and age
          if (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age')) {
            console.log(`🔍 [SEX/AGE DEBUG] Skipped as embedding: ${metadataName}`)
          }
        } else if (!continuousSet.has(metadataId)) {
          continuousSet.add(metadataId)
          console.log(`  ✅ Continuous: ${metadataName} (${metadataId})`)
          
          // Special logging for sex and age
          if (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age')) {
            console.log(`🔍 [SEX/AGE DEBUG] Added to continuous set: ${metadataName}`)
          }
        }
      } else {
        console.warn(`  ⚠️  Unknown metadata type "${metadataType}" for ${metadataName} (${metadataId})`)
        
        // Special logging for sex and age
        if (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age')) {
          console.log(`🔍 [SEX/AGE DEBUG] Unknown type for: ${metadataName} - Type: ${metadataType}`)
        }
      }
    })
    
    // Convert Sets to Arrays
    categoricalMetadata.push(...categoricalSet)
    continuousMetadata.push(...continuousSet)
    
    // Fallback: If we didn't find any metadata buttons with the strict selector, try a more lenient approach
    if (metadataButtons.length === 0) {
      console.log(`🔍 [Preload Debug] No buttons found with strict selector, trying fallback...`)
      
      // Try to find buttons with just the basic attributes
      const fallbackButtons = document.querySelectorAll('button[data-metadata-id][data-metadata-type]')
      console.log(`🔍 [Preload Debug] Found ${fallbackButtons.length} buttons with fallback selector`)
      
      fallbackButtons.forEach(btn => {
        const metadataId = btn.dataset.metadataId
        const metadataType = btn.dataset.metadataType
        const metadataName = btn.dataset.metadataName || 'unknown'
        
        // Special logging for sex and age metadata
        if (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age')) {
          console.log(`🔍 [SEX/AGE DEBUG] Fallback found metadata: ${metadataName} (${metadataId}) - Type: ${metadataType}`)
        }
        
        if (!metadataId) return
        
        // Process categorical and continuous metadata (excluding embeddings)
        if (metadataType === 'DISCRETE') {
          if (!categoricalSet.has(metadataId)) {
            categoricalSet.add(metadataId)
            console.log(`  ✅ Categorical (fallback): ${metadataName} (${metadataId})`)
          }
        } else if (metadataType === 'NUMERIC') {
          // Skip if it's an embedding (will be preloaded separately)
          if (embeddingSet.has(metadataId)) {
            console.log(`  📊 Embedding (fallback): ${metadataName} (${metadataId}) - will preload with embeddings`)
          } else if (!continuousSet.has(metadataId)) {
            continuousSet.add(metadataId)
            console.log(`  ✅ Continuous (fallback): ${metadataName} (${metadataId})`)
          }
        }
      })
      
      // Update the arrays with any new metadata found via fallback
      categoricalMetadata.length = 0
      continuousMetadata.length = 0
      categoricalMetadata.push(...categoricalSet)
      continuousMetadata.push(...continuousSet)
    }
    
    console.log(`🚀 [PERF] Found metadata to preload:`)
    console.log(`  - ${visualizationEmbeddings.length} visualization embeddings:`, visualizationEmbeddings.slice(0, 3).map(e => e.name))
    console.log(`  - ${categoricalMetadata.length} categorical metadata`)
    console.log(`  - ${continuousMetadata.length} continuous metadata`)
    
    // Special logging for sex and age in final lists
    const allMetadataToPreload = [...categoricalMetadata, ...continuousMetadata]
    const sexAgeMetadata = allMetadataToPreload.filter(id => {
      const name = this.getMetadataNameById(id)
      return name && (name.toLowerCase().includes('sex') || name.toLowerCase().includes('age'))
    })
    
    if (sexAgeMetadata.length > 0) {
      console.log(`🔍 [SEX/AGE DEBUG] Sex/Age metadata found in preload list:`, sexAgeMetadata.map(id => this.getMetadataNameById(id)))
    } else {
      console.log(`🔍 [SEX/AGE DEBUG] No sex/age metadata found in preload list!`)
    }
    
    let embeddingCount = 0
    let categoricalCount = 0
    let continuousCount = 0
    
    // PHASE 1: Preload visualization embeddings (coordinate data)
    // These are cached silently in binaryDataCache without displaying
    console.log(`\n📊 [Phase 1] Preloading ${visualizationEmbeddings.length} embeddings...`)
    for (const embedding of visualizationEmbeddings) {
      try {
        console.log(`  📥 Loading: ${embedding.name}`)
        const result = await this.loadMetadataCoordinatesSilently(embedding.id, embedding.name)
        
        if (result.success) {
          embeddingCount++
          if (result.cached) {
            console.log(`  ⏭️  Already cached: ${embedding.name}`)
          } else {
            console.log(`  ✅ Cached: ${embedding.name} (${result.size}) - ${embeddingCount}/${visualizationEmbeddings.length}`)
          }
        } else {
          console.log(`  ❌ Failed: ${embedding.name} - ${result.error}`)
        }
      } catch (error) {
        console.log(`  ❌ Failed: ${embedding.name} - ${error.message}`)
      }
      
      // Small delay between embeddings (they're large files)
      await new Promise(resolve => setTimeout(resolve, 200))
    }
    
    // PHASE 2: Preload metadata vectors (categorical + continuous)
    // These use loadSingleMetadataVectorSilently and are stored in IndexedDB
    const orderedMetadata = [
      ...categoricalMetadata,
      ...continuousMetadata
    ]
    
    if (orderedMetadata.length > 0) {
      console.log(`\n🏷️ [Phase 2] Preloading all ${orderedMetadata.length} metadata vectors to disk...`)
      console.log(`💾 [PERF] Using disk-first approach - all metadata will be stored on disk, not in memory`)
      
      // Reduce batch size to prevent server overload and add retry logic
      const batchSize = 1 // Reduced from 3 to 1 to prevent server overload
      const maxRetries = 2
      
      for (let i = 0; i < orderedMetadata.length; i += batchSize) {
        const batch = orderedMetadata.slice(i, i + batchSize)
        
        // Load batch sequentially (not in parallel) to reduce server load
        for (let batchIndex = 0; batchIndex < batch.length; batchIndex++) {
          const metadataId = batch[batchIndex]
          // Skip if already loaded
          if (this.loadedMetadataVectors[metadataId] || this.loadingMetadataVectors.has(metadataId)) {
            // Special logging for sex and age
            const metadataName = this.getMetadataNameById(metadataId)
            if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
              console.log(`🔍 [SEX/AGE DEBUG] Skipping ${metadataName} (${metadataId}) - already loaded/loading`)
            }
            continue
          }
          
          // Special logging for sex and age before loading
          const metadataName = this.getMetadataNameById(metadataId)
          if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
            console.log(`🔍 [SEX/AGE DEBUG] Starting to preload ${metadataName} (${metadataId})`)
          }
          
          // Retry logic for failed requests
          let success = false
          let lastError = null
          
          for (let retry = 0; retry <= maxRetries; retry++) {
            try {
              if (retry > 0) {
                // Exponential backoff: wait longer between retries
                const delay = Math.pow(2, retry) * 1000 // 2s, 4s, 8s...
                console.log(`  🔄 Retry ${retry}/${maxRetries} for metadata ${metadataId} after ${delay}ms delay`)
                await new Promise(resolve => setTimeout(resolve, delay))
              }
              
              // Load from server directly to disk (IndexedDB) without keeping in memory
              const result = await this.preloadMetadataToDisk(metadataId)
              const globalIndex = i + batchIndex
              
              // Check if the loading actually succeeded
              if (result.success) {
                // Log progress for each type
                if (globalIndex < categoricalMetadata.length) {
                  categoricalCount++
                  console.log(`  ✅ Categorical ${categoricalCount}/${categoricalMetadata.length}${result.cached ? ' (cached)' : ''}`)
                } else {
                  continuousCount++
                  console.log(`  ✅ Continuous ${continuousCount}/${continuousMetadata.length}${result.cached ? ' (cached)' : ''}`)
                }
                
                // Special logging for sex and age after successful loading
                if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
                  console.log(`🔍 [SEX/AGE DEBUG] Successfully preloaded ${metadataName} (${metadataId}) to disk${retry > 0 ? ` on retry ${retry}` : ''}`)
                }
                success = true
                break
              } else {
                // Loading failed
                lastError = new Error(result.error || 'Unknown error')
                console.log(`  ❌ Failed metadata ${metadataId} (attempt ${retry + 1}): ${result.error}`)
              }
            } catch (error) {
              lastError = error
              console.log(`  ❌ Failed metadata ${metadataId} (attempt ${retry + 1}): ${error.message}`)
            }
          }
          
          // If all retries failed, log the final error
          if (!success) {
            console.log(`  ❌ Final failure for metadata ${metadataId} after ${maxRetries + 1} attempts`)
            
            // Special logging for sex and age on final failure
            if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
              console.log(`🔍 [SEX/AGE DEBUG] Final failure for ${metadataName} (${metadataId}): ${lastError?.message || 'Unknown error'}`)
            }
          }
          
          // Add delay between requests to prevent server overload
          if (i + batchSize < orderedMetadata.length) {
            await new Promise(resolve => setTimeout(resolve, 500)) // 500ms delay between requests
          }
        }
        
        // Small delay between batches
        if (i + batchSize < orderedMetadata.length) {
          await new Promise(resolve => setTimeout(resolve, 100))
        }
      }
    }
    
    console.log(`\n🚀 [PERF] ✅ Preload complete!`)
    console.log(`  📊 ${embeddingCount}/${visualizationEmbeddings.length} Embeddings`)
    console.log(`  🏷️ ${categoricalCount}/${categoricalMetadata.length} Categorical`)
    console.log(`  📈 ${continuousCount}/${continuousMetadata.length} Continuous`)
    this.logMemoryUsage('After preloading all metadata')
    
    // Performance assessment after preloading
    await this.assessPerformanceAfterPreload()
    
    // Create diagnostic button for troubleshooting
    this.createDiagnosticButton()
  }

  // Update visualization with metadata vector coloring
  updateVisualizationWithMetadataVector() {
    // Check for renderer availability (either ReGL or PixiJS)
    const hasRenderer = this.rendererType === 'regl' ? !!this.reglRenderer : (!!this.pixiApp && !!this.scatterContainer)
    
    if (!this.currentMetadataVector || !hasRenderer) {
      console.log('Cannot update visualization - missing data or renderer')
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
    
    // Smart re-render: Sprites can ALWAYS be reused, just update colors and z-order!
    // No need to recreate sprites when switching metadata
    console.log(`🔄 Switching to ${data_type} metadata, will reuse sprites and update colors/z-order`)
    
    // Store for next comparison
    this.lastMetadataVector = this.currentMetadataVector
    
    // Render with current coloring (will reuse sprites if type matches)
    this.renderPointsWithCurrentColoring()
    
    // Render category labels if this is discrete metadata, or color legend if continuous
    // Note: In ReGL mode, renderPointsWithCurrentColoringReGL() already renders labels
    if (this.rendererType === 'pixi') {
    if (this.currentMetadataVector.data_type === 'DISCRETE') {
      // renderCategoryLabels will handle visibility based on checkbox state
      this.renderCategoryLabels()
    } else if (this.currentMetadataVector.data_type === 'NUMERIC') {
      // Hide category labels for numeric metadata
      if (this.categoryLabelsContainer) {
        this.categoryLabelsContainer.visible = false
        this.categoryLabelsContainer.removeChildren()
      }
      this.renderContinuousColorLegend()
      }
    }
    
    //console.log(`Successfully colored ${this.currentCoordinates.length} points with ${this.currentMetadataVector.name}`)
  }
  // Render all points using the current coloring scheme
  renderPointsWithCurrentColoring() {
    // Dispatch to ReGL if using ReGL renderer
    if (this.rendererType === 'regl') {
      return this.renderPointsWithCurrentColoringReGL()
    }
    
    const startTime = performance.now()
    console.log('🚀 [PERF] renderPointsWithCurrentColoring started')
    
    if (!this.pixiApp || !this.scatterContainer || !this.currentCoordinates || !this.currentBounds) {
      console.log('Cannot render points - missing PIXI app or coordinates')
      const totalTime = performance.now() - startTime
      console.log(`🚀 [PERF] renderPointsWithCurrentColoring completed (early return) in ${totalTime.toFixed(2)}ms`)
      return
    }

    // NEW STRATEGY: NEVER recreate container once sprites exist!
    // Just update sprite properties (color, zIndex, visibility, etc.)
    const pointSize = this.currentPointSize
    
    let pointsContainer
    
    // If we have sprites and container, ALWAYS reuse them
    if (this.pointSprites && this.pointSprites.length === this.currentCoordinates.length) {
      // Check if animatedContainer exists and is still valid
      if (this.animatedContainer && this.animatedContainer.destroyed === false) {
      pointsContainer = this.animatedContainer
      
      // Ensure container is in scene graph
      if (!this.scatterContainer.children.includes(this.animatedContainer)) {
        this.scatterContainer.addChild(this.animatedContainer)
        console.log(`🚀 [PERF] Re-added animatedContainer to scatterContainer`)
      }
      
      console.log(`🚀 [PERF] Reusing sprites and container - NO recreation, just property updates`)
      console.log(`🚀 [PERF] Container has ${pointsContainer.children.length} children, ${this.pointSprites.length} sprites`)
      } else {
        // Container was destroyed but sprites still exist - recreate container and add sprites to it
        console.log(`🚀 [PERF] Container destroyed but sprites exist - recreating container only`)
        
        // Remove any invalid children
        this.scatterContainer.removeChildren()
        
        // Create new container
        pointsContainer = new PIXI.Container()
        pointsContainer.sortableChildren = true
        this.scatterContainer.addChild(pointsContainer)
        this.animatedContainer = pointsContainer
        
        // Re-add existing sprites to new container
        for (let i = 0; i < this.pointSprites.length; i++) {
          const sprite = this.pointSprites[i]
          if (sprite && !sprite.destroyed) {
            pointsContainer.addChild(sprite)
          }
        }
        
        console.log(`🚀 [PERF] Re-added ${this.pointSprites.length} existing sprites to new container`)
      }
    } else {
      // First time or coordinates changed - create new container and sprites
      console.log(`🚀 [PERF] Creating new sprites - sprite count: ${this.pointSprites?.length}, coord count: ${this.currentCoordinates?.length}`)
      
      const clearStart = performance.now()
      this.scatterContainer.removeChildren()
      this.existingPoints = null
      this.pointSprites = null // Clear sprite array too
      
      // Create new container
      pointsContainer = new PIXI.Container()
      pointsContainer.sortableChildren = true // Enable z-index sorting
      this.scatterContainer.addChild(pointsContainer)
      this.animatedContainer = pointsContainer
      
      const clearTime = performance.now() - clearStart
      console.log(`🚀 [PERF] First render or coordinates changed - creating new container`)
      console.log(`🚀 [PERF] New pointsContainer created`)
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
        
        // Sort point indices by category size based on user preference
        const sortedPointIndices = Array.from({ length: this.currentCoordinates.length }, (_, i) => i)
          .sort((a, b) => {
            const categoryA = values[a]
            const categoryB = values[b]
            const freqA = categoryFrequencies[categoryA]
            const freqB = categoryFrequencies[categoryB]
            
            if (this.categoryOrder === 'smallest-first') {
              return freqA - freqB // Ascending order (smallest first)
            } else {
              return freqB - freqA // Descending order (largest first) - default
            }
          })
        
        // Debug: Log the first few sorted indices and their categories
        //console.log('First 10 sorted point indices:', sortedPointIndices.slice(0, 10))
        //console.log('Categories for first 10 points:', sortedPointIndices.slice(0, 10).map(i => values[i]))
        //console.log('Frequencies for first 10 points:', sortedPointIndices.slice(0, 10).map(i => categoryFrequencies[values[i]]))
        
        // Check if we can reuse existing sprites - can reuse from any type now that we use zIndex
        const canReuseSprites = this.pointSprites && 
                                 this.pointSprites.length === this.currentCoordinates.length
        
        console.log(`🚀 [PERF] Discrete sprite reuse check:`, {
          hasPointSprites: !!this.pointSprites,
          spritesLength: this.pointSprites?.length,
          coordsLength: this.currentCoordinates.length,
          canReuse: canReuseSprites
        })
        
        if (canReuseSprites) {
          console.log(`🚀 [PERF] Fast discrete update: reusing ${this.pointSprites.length} sprites, updating colors and z-order`)
          const colorUpdateStart = performance.now()
          
          // Pre-calculate discrete color map if needed
          if (!this._cachedColorMap) {
            // Use DOM order (same as legend) for consistent color assignment
            const domOrderCategories = this.getCategoriesForMetadata(this.currentMetadataId)
            if (domOrderCategories && domOrderCategories.length > 0) {
              const categoryNames = domOrderCategories.map(cat => cat.name)
              this._cachedColorMap = this.createDiscreteColorMap(categoryNames, this.currentMetadataId)
            } else {
              // Fallback to original categories if DOM not available
              this._cachedColorMap = this.createDiscreteColorMap([...compression_info.categories], this.currentMetadataId)
            }
          }
          const colorMap = this._cachedColorMap
          const hasSelection = this.selectedCells && this.selectedCells.size > 0
          
          // Calculate category frequencies for z-ordering (larger categories have lower zIndex = background)
          const freqStart = performance.now()
          const categoryFrequencies = {}
          for (let i = 0; i < values.length; i++) {
            const value = values[i]
            categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
          }
          const freqTime = performance.now() - freqStart
          console.log(`🚀 [PERF] Category frequency calculation took ${freqTime.toFixed(2)}ms`)
          
          // Find max frequency for normalization
          const maxFreq = this.safeMax(Object.values(categoryFrequencies))
          console.log(`🚀 [PERF] Max frequency: ${maxFreq}`)
          
          // Build visibility set for O(1) lookups
          const visibleSet = filteredIndices ? new Set(filteredIndices) : null
          
          // Batch add sprites first if needed (much faster than individual addChild)
          let addedToContainer = 0
          if (pointsContainer.children.length === 0 && this.pointSprites.length > 0) {
            console.log(`🚀 [PERF] Container is empty, batch-adding all ${this.pointSprites.length} sprites...`)
            const batchStart = performance.now()
            
            // Temporarily disable sorting during batch add for maximum performance
            const wasSortable = pointsContainer.sortableChildren
            pointsContainer.sortableChildren = false
            
            for (let i = 0; i < this.pointSprites.length; i++) {
              const sprite = this.pointSprites[i]
              if (sprite && !sprite.parent) {
                pointsContainer.addChild(sprite)
                addedToContainer++
              }
            }
            
            // Re-enable sorting after batch add
            pointsContainer.sortableChildren = wasSortable
            
            const batchTime = performance.now() - batchStart
            console.log(`🚀 [PERF] Batch-added ${addedToContainer} sprites in ${batchTime.toFixed(2)}ms`)
          }
          
          console.log(`🚀 [PERF] Starting discrete color and z-order update for ${this.pointSprites.length} sprites...`)
          
          // Update sprite colors, visibility, and z-order
          const updateStart = performance.now()
          for (let i = 0; i < this.pointSprites.length; i++) {
            const sprite = this.pointSprites[i]
            if (sprite) {
              const category = values[i]
              const isSelected = this.selectedCells && this.selectedCells.has(i)
              
              // Update color
              if (isSelected) {
                sprite.tint = 0xff0000
                sprite.alpha = 1.0
              } else {
                sprite.tint = colorMap[category] || 0x3b82f6
                sprite.alpha = hasSelection ? 0.3 : 1.0
              }
              
              // Update z-order based on user preference
              const freq = categoryFrequencies[category] || 0
              if (this.categoryOrder === 'smallest-first') {
                // Smallest first: small categories in background
                sprite.zIndex = freq // Small freq = low zIndex = background
              } else {
                // Largest first (default): large categories in background
                sprite.zIndex = maxFreq - freq // Large freq = low zIndex = background
              }
              
              sprite.visible = !visibleSet || visibleSet.has(i)
            }
          }
          
          const updateTime = performance.now() - updateStart
          console.log(`🚀 [PERF] Color and z-order update completed in ${updateTime.toFixed(2)}ms`)
          
          const colorUpdateTime = performance.now() - colorUpdateStart
          console.log(`🚀 [PERF] Total discrete update completed in ${colorUpdateTime.toFixed(2)}ms`)
          this.logMemoryUsage('After discrete metadata update')
        } else {
          // Full render: create sprites in sorted order (largest categories first)
          console.log(`🚀 [PERF] Full discrete render: creating ${sortedPointIndices.length} sprites`)
          
          // Mark that these sprites are for discrete metadata
          this.spritesRenderType = 'discrete'
          
          if (!this.pointTexture || this.lastPointSize !== pointSize) {
            if (this.pointTexture) this.pointTexture.destroy(true)
            this.pointTexture = this.createPointTexture(pointSize)
            this.lastPointSize = pointSize
          }
          
          this.pointSprites = new Array(this.currentCoordinates.length)
          
          // Calculate category frequencies for z-ordering
          const maxFreq = this.safeMax(Object.values(categoryFrequencies))
          
          sortedPointIndices.forEach((i, sortIndex) => {
          // Skip this point if it's not in the filtered indices
          if (filteredIndices && !filteredIndices.includes(i)) {
            return
          }

          const [x, y] = this.currentCoordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, this.currentBounds)
          const screenY = this.normalizeY(y, this.currentBounds)
          
            // Create sprite using shared texture
            const sprite = new this.PIXI.Sprite(this.pointTexture)
            sprite.anchor.set(0.5)
            sprite.x = screenX
            sprite.y = screenY
            sprite.tint = color
            sprite.alpha = alpha
            sprite.originalAlpha = alpha
          
          // Store cell ID and mark as point for later reference
            sprite.cellId = i
            sprite.isPoint = true
            
            // Set z-order based on user preference
            const category = values[i]
            const freq = categoryFrequencies[category] || 0
            if (this.categoryOrder === 'smallest-first') {
              // Smallest first: small categories in background
              sprite.zIndex = freq
            } else {
              // Largest first (default): large categories in background
              sprite.zIndex = maxFreq - freq
            }
          
          // Store original color for reset functionality
          this.storeOriginalPointColor(i, color)
          
          // Add hover functionality
            sprite.interactive = true
            sprite.buttonMode = false
            sprite.on('pointerover', () => this.showTooltip(i, sprite))
            sprite.on('pointerout', () => this.hideTooltip())
            
            pointsContainer.addChild(sprite)
            this.pointSprites[i] = sprite
          })
        }
        
        // Update point count display with filtered count
        this.updatePointCountDisplay(filteredIndices)
        
      } else if (data_type === 'NUMERIC') {
        // Check for ultra-fast visibility-only update (no color changes)
        const canVisibilityOnlyUpdate = Boolean(
          this.visibilityOnlyUpdate &&
          this.pointSprites &&
          this.pointSprites.length === this.currentCoordinates.length
        )
        
        if (canVisibilityOnlyUpdate) {
          console.log(`🚀 [PERF] Ultra-fast visibility-only update: ${this.pointSprites.length} sprites`)
          const visibilityStart = performance.now()
          
          // Build visibility set for O(1) lookups
          const visibleSet = filteredIndices ? new Set(filteredIndices) : null
          
          // Only update visibility, skip color recalculation
          for (let i = 0; i < this.pointSprites.length; i++) {
            const sprite = this.pointSprites[i]
            if (sprite) {
              sprite.visible = !visibleSet || visibleSet.has(i)
            }
          }
          
          const visibilityTime = performance.now() - visibilityStart
          console.log(`🚀 [PERF] Visibility-only update completed in ${visibilityTime.toFixed(2)}ms`)
          
          // Update point count display
          this.updatePointCountDisplay(filteredIndices)
          
          // Reset the flag
          this.visibilityOnlyUpdate = false
          
          const totalTime = performance.now() - startTime
          console.log(`🚀 [PERF] renderPointsWithCurrentColoring completed (visibility-only) in ${totalTime.toFixed(2)}ms`)
          return
        }
        
        // Check if we can reuse existing sprites - can reuse from any type now that we use zIndex
        const canReuseSprites = this.pointSprites && 
                                 this.pointSprites.length === this.currentCoordinates.length
        
        console.log(`🚀 [PERF] Numeric sprite reuse check:`, {
          hasPointSprites: !!this.pointSprites,
          spritesLength: this.pointSprites?.length,
          coordsLength: this.currentCoordinates.length,
          canReuse: canReuseSprites
        })
        
        if (canReuseSprites) {
          console.log(`🚀 [PERF] Fast numeric update: reusing ${this.pointSprites.length} sprites, just updating colors`)
          const colorUpdateStart = performance.now()
          
          // Pre-calculate range values to avoid calling getEffectiveColorRange 500k times
          const effectiveRange = this.getEffectiveColorRange()
          const minVal = effectiveRange ? effectiveRange.min : compression_info.min_val
          const maxVal = effectiveRange ? effectiveRange.max : compression_info.max_val
          const range = maxVal - minVal
          const invRange = 1.0 / range // Pre-calculate inverse for faster division
          const hasSelection = this.selectedCells && this.selectedCells.size > 0
          const useDefaultScheme = this.currentColorScheme === 'blue-green-red' || !this.currentColorScheme
          
          // Build visibility set for O(1) lookups
          const visibleSet = filteredIndices ? new Set(filteredIndices) : null
          
          // Pre-compute all z-indices for performance (avoid 500k+ function calls)
          console.log(`🚀 [PERF] Pre-computing z-indices for all values...`)
          const zIndexStart = performance.now()
          const zIndices = this.precomputeNumericZIndices(values, minVal, maxVal)
          const zIndexTime = performance.now() - zIndexStart
          console.log(`🚀 [PERF] Z-index pre-computation took ${zIndexTime.toFixed(2)}ms`)
          
          // Batch add sprites first if needed (much faster than individual addChild)
          let addedToContainer = 0
          if (pointsContainer.children.length === 0 && this.pointSprites.length > 0) {
            console.log(`🚀 [PERF] Container is empty, batch-adding all sprites...`)
            const batchStart = performance.now()
            
            // Temporarily disable sorting during batch add for maximum performance
            const wasSortable = pointsContainer.sortableChildren
            pointsContainer.sortableChildren = false
            
            for (let i = 0; i < this.pointSprites.length; i++) {
              const sprite = this.pointSprites[i]
              if (sprite && !sprite.parent) {
                pointsContainer.addChild(sprite)
                addedToContainer++
              }
            }
            
            // Re-enable sorting after batch add
            pointsContainer.sortableChildren = wasSortable
            
            const batchTime = performance.now() - batchStart
            console.log(`🚀 [PERF] Batch-added ${addedToContainer} sprites in ${batchTime.toFixed(2)}ms`)
          }
          
          console.log(`🚀 [PERF] Starting color update loop for ${this.pointSprites.length} sprites...`)
          const loopStart = performance.now()
          
          // Update sprite colors and visibility
          for (let i = 0; i < this.pointSprites.length; i++) {
            const sprite = this.pointSprites[i]
            if (sprite) {
              // Inline color calculation for performance (avoid function call overhead)
              const isSelected = this.selectedCells && this.selectedCells.has(i)
              
              if (isSelected) {
                sprite.tint = 0xff0000
                sprite.alpha = 1.0
              } else {
                const value = values[i]
                const normalizedValue = (value - minVal) * invRange
                
                // Inline blue-green-red gradient for maximum performance
                if (useDefaultScheme) {
                  const clamped = Math.max(0, Math.min(1, normalizedValue))
                  if (clamped < 0.5) {
                    const t = clamped * 2
                    const g = Math.round(255 * t)
                    const b = Math.round(255 * (1 - t))
                    sprite.tint = (g << 8) | b
                  } else {
                    const t = (clamped - 0.5) * 2
                    const r = Math.round(255 * t)
                    const g = Math.round(255 * (1 - t))
                    sprite.tint = (r << 16) | (g << 8)
                  }
                } else {
                  sprite.tint = this.valueToColor(normalizedValue)
                }
                
                sprite.alpha = hasSelection ? 0.3 : 1.0
              }
              
              // Use pre-computed z-index for performance
              sprite.zIndex = zIndices[i]
              sprite.visible = !visibleSet || visibleSet.has(i)
            }
          }
          
          const loopTime = performance.now() - loopStart
          console.log(`🚀 [PERF] Color update loop completed in ${loopTime.toFixed(2)}ms`)
          
          const colorUpdateTime = performance.now() - colorUpdateStart
          console.log(`🚀 [PERF] Total numeric update completed in ${colorUpdateTime.toFixed(2)}ms`)
          this.logMemoryUsage('After numeric metadata update')
        } else {
          // Full render: create sprites from scratch
          console.log(`🚀 [PERF] Full numeric render: creating ${this.currentCoordinates.length} sprites`)
          
          // Mark that these sprites are for numeric metadata
          this.spritesRenderType = 'numeric'
          
          if (!this.pointTexture || this.lastPointSize !== pointSize) {
            if (this.pointTexture) this.pointTexture.destroy(true)
            this.pointTexture = this.createPointTexture(pointSize)
            this.lastPointSize = pointSize
          }
          
          this.pointSprites = new Array(this.currentCoordinates.length)
          
          // Pre-calculate range and z-indices for all values (performance optimization)
          const effectiveRange = this.getEffectiveColorRange()
          const minVal = effectiveRange ? effectiveRange.min : compression_info.min_val
          const maxVal = effectiveRange ? effectiveRange.max : compression_info.max_val
          
          console.log(`🚀 [PERF] Pre-computing z-indices for all values...`)
          const zIndexStart = performance.now()
          const zIndices = this.precomputeNumericZIndices(values, minVal, maxVal)
          const zIndexTime = performance.now() - zIndexStart
          console.log(`🚀 [PERF] Z-index pre-computation took ${zIndexTime.toFixed(2)}ms`)
        
        for (let i = 0; i < this.currentCoordinates.length; i++) {
          // Skip this point if it's not in the filtered indices
          if (filteredIndices && !filteredIndices.includes(i)) {
            continue
          }

          const [x, y] = this.currentCoordinates[i]
          const { color, alpha } = this.getColorAndAlpha(i)
          
          const screenX = this.normalizeX(x, this.currentBounds)
          const screenY = this.normalizeY(y, this.currentBounds)
          
            // Create sprite using shared texture
            const sprite = new this.PIXI.Sprite(this.pointTexture)
            sprite.anchor.set(0.5)
            sprite.x = screenX
            sprite.y = screenY
            sprite.tint = color
            sprite.alpha = alpha
            sprite.originalAlpha = alpha
            
            // Use pre-computed z-index for performance
            sprite.zIndex = zIndices[i]
          
          // Store cell ID and mark as point for later reference
            sprite.cellId = i
            sprite.isPoint = true
          
          // Store original color for reset functionality
          this.storeOriginalPointColor(i, color)
          
          // Add hover functionality
            sprite.interactive = true
            sprite.buttonMode = false
            sprite.on('pointerover', () => this.showTooltip(i, sprite))
            sprite.on('pointerout', () => this.hideTooltip())
            
            pointsContainer.addChild(sprite)
            this.pointSprites[i] = sprite
          }
        }
        
        this.existingPoints = this.pointSprites // Maintain compatibility
        
        // Store point size for optimization checks
        this.lastPointSize = pointSize
        
        // Update point count display with filtered count
        this.updatePointCountDisplay(filteredIndices)
      }
    } else {
      // No metadata - default coloring
      // Check if we can reuse existing sprites - can reuse from any type now
      const canReuseSprites = this.pointSprites && 
                               this.pointSprites.length === this.currentCoordinates.length
      
      if (canReuseSprites) {
        console.log(`🚀 [PERF] Fast default color update: reusing ${this.pointSprites.length} sprites`)
        const colorUpdateStart = performance.now()
        
        const hasSelection = this.selectedCells && this.selectedCells.size > 0
        
        // Build visibility set for O(1) lookups
        const visibleSet = filteredIndices ? new Set(filteredIndices) : null
        
        // Update sprite colors and visibility
        for (let i = 0; i < this.pointSprites.length; i++) {
          const sprite = this.pointSprites[i]
          if (sprite) {
            // Inline color calculation for performance
            const isSelected = this.selectedCells && this.selectedCells.has(i)
            
            if (isSelected) {
              sprite.tint = 0xff0000
              sprite.alpha = 1.0
            } else {
              sprite.tint = 0x3b82f6 // Default blue
              sprite.alpha = hasSelection ? 0.3 : 1.0
            }
            
            sprite.zIndex = 0 // Default doesn't need special z-ordering
            sprite.visible = !visibleSet || visibleSet.has(i)
          }
        }
        
        const colorUpdateTime = performance.now() - colorUpdateStart
        console.log(`🚀 [PERF] Default color update completed in ${colorUpdateTime.toFixed(2)}ms`)
      } else {
        console.log(`🚀 [PERF] Full default render: creating ${this.currentCoordinates.length} sprites`)
        
        // Mark that these sprites are for default coloring
        this.spritesRenderType = 'default'
        
        if (!this.pointTexture || this.lastPointSize !== pointSize) {
          if (this.pointTexture) this.pointTexture.destroy(true)
          this.pointTexture = this.createPointTexture(pointSize)
          this.lastPointSize = pointSize
        }
        
        this.pointSprites = new Array(this.currentCoordinates.length)
        
      for (let i = 0; i < this.currentCoordinates.length; i++) {
        // Skip this point if it's not in the filtered indices
        if (filteredIndices && !filteredIndices.includes(i)) {
          continue
        }

        const [x, y] = this.currentCoordinates[i]
        const { color, alpha } = this.getColorAndAlpha(i)
        
        const screenX = this.normalizeX(x, this.currentBounds)
        const screenY = this.normalizeY(y, this.currentBounds)
        
          // Create sprite using shared texture
          const sprite = new this.PIXI.Sprite(this.pointTexture)
          sprite.anchor.set(0.5)
          sprite.x = screenX
          sprite.y = screenY
          sprite.tint = color
          sprite.alpha = alpha
          sprite.originalAlpha = alpha
          sprite.zIndex = 0 // Default doesn't need special z-ordering
        
        // Store cell ID and mark as point for later reference
          sprite.cellId = i
          sprite.isPoint = true
        
        // Store original color for reset functionality
        this.storeOriginalPointColor(i, color)
        
          this.scatterContainer.addChild(sprite)
          this.pointSprites[i] = sprite
        }
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
  // ReGL version of renderPointsWithCurrentColoring
  renderPointsWithCurrentColoringReGL() {
    // Performance optimization: check if color state has changed
    const currentColorHash = this.getColorStateHash()
    if (this.lastColorUpdateHash === currentColorHash && this.colorUpdateCache.has('lastColorMap')) {
      console.log('🎨 [ReGL] Using cached color update (no color state change)')
      const cachedColorMap = this.colorUpdateCache.get('lastColorMap')
      this.reglRenderer.updateColors(cachedColorMap)
      this.reglRenderer.render()
      return
    }
    
    console.log('🎨 [ReGL] Updating point colors based on metadata')
    const startTime = performance.now()
    
    if (!this.reglRenderer || !this.currentCoordinates) {
      console.log('⚠️ [ReGL] Cannot update colors - missing renderer or coordinates')
      return
    }
    
    const colorMap = new Map()
    
    // Get current filtered indices to hide invisible points
    const filteredIndices = this.getIncrementalFilteredIndices()
    const visibleSet = filteredIndices ? new Set(filteredIndices) : null
    console.log(`🎨 [ReGL] Filtered indices:`, filteredIndices ? `${filteredIndices.length} visible cells` : 'all visible')
    
    // Check if we have metadata coloring active
    if (this.currentMetadataVector) {
      console.log(`🎨 [ReGL] Applying ${this.currentMetadataVector.data_type} metadata colors`)
      
      if (this.currentMetadataVector.data_type === 'DISCRETE') {
        // Discrete metadata coloring with category ordering
        const categoryColors = this.getCategoryColors()
        
        // Build category-to-index map using DOM order (same as legend)
        const domOrderCategories = this.getCategoriesForMetadata(this.currentMetadataId)
        let categoryToIndex = {}
        
        if (domOrderCategories && domOrderCategories.length > 0) {
          // Use DOM order for consistent color assignment
          const categoryNames = domOrderCategories.map(cat => cat.name)
          categoryNames.forEach((cat, idx) => {
            categoryToIndex[cat] = idx
          })
        } else {
          // Fallback to Set order if DOM not available
          const uniqueCategories = [...new Set(this.currentMetadataVector.values)]
          uniqueCategories.forEach((cat, idx) => {
            categoryToIndex[cat] = idx
          })
        }
        
        const uniqueCategories = Object.keys(categoryToIndex)
        console.log(`🎨 [ReGL] ${uniqueCategories.length} categories, ${categoryColors.length} colors available`)
        
        // Assign colors using displayOrder, hiding filtered-out cells
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const isVisible = !visibleSet || visibleSet.has(cellIndex)
          
          if (isVisible) {
            const category = this.currentMetadataVector.values[cellIndex]
            const categoryIndex = categoryToIndex[category] || 0
            const colorValue = categoryColors[categoryIndex % categoryColors.length]
            
            const color = typeof colorValue === 'string' 
              ? parseInt(colorValue.replace('#', ''), 16)
              : colorValue
            
            colorMap.set(drawPos, color)
            this.originalPointColors.set(cellIndex, color) // Store by cell index
          } else {
            // Hide filtered-out points
            colorMap.set(drawPos, 0x00000000)
          }
        }
        
        // Update colors in ReGL
        this.reglRenderer.updateColors(colorMap)
        this.reglRenderer.render()
        
        // Check if we need to reorder points for category display
        // Only reorder if this is the first time loading this metadata or if order preference changed
        const needsReordering = !this._lastCategoryOrderApplied || this._lastCategoryOrderApplied !== this.categoryOrder
        
        if (needsReordering) {
          console.log('📊 [ReGL] Applying category display order (first time or order changed)...')
          this._lastCategoryOrderApplied = this.categoryOrder
          
          // Reorder points in buffer (this will re-render and redraw overlay)
          this.reorderPointsForCategoryDisplay()
          
          // Redraw overlay is handled by reorderPointsForCategoryDisplay
          const elapsed = performance.now() - startTime
          console.log(`🎨 [ReGL] Color update with reordering completed in ${elapsed.toFixed(2)}ms`)
          return // Early exit - reordering already rendered everything
        }
        
      } else if (this.currentMetadataVector.data_type === 'NUMERIC') {
        // Continuous/numeric metadata coloring
        const values = this.currentMetadataVector.values
        const compressionInfo = this.currentMetadataVector.compression_info
        
        console.log(`🎨 [ReGL] Applying continuous coloring for ${values.length} points`)
        
        // Get effective color range (respects user-set range slider)
        const effectiveRange = this.getEffectiveColorRange()
        let minVal, maxVal
        
        if (effectiveRange) {
          minVal = effectiveRange.min
          maxVal = effectiveRange.max
          console.log(`🎨 [ReGL] Using user-defined range: [${minVal}, ${maxVal}]`)
        } else if (compressionInfo) {
          minVal = compressionInfo.min_val
          maxVal = compressionInfo.max_val
          console.log(`🎨 [ReGL] Using compression info range: [${minVal}, ${maxVal}]`)
        } else {
          // Fallback: calculate range from values (avoid spreading large arrays)
          minVal = values[0]
          maxVal = values[0]
          for (let i = 1; i < values.length; i++) {
            if (values[i] < minVal) minVal = values[i]
            if (values[i] > maxVal) maxVal = values[i]
          }
          console.log(`🎨 [ReGL] Calculated range from values: [${minVal}, ${maxVal}]`)
        }
        
        const range = maxVal - minVal
        
        // Apply colors using displayOrder, hiding filtered-out cells
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const isVisible = !visibleSet || visibleSet.has(cellIndex)
          
          if (isVisible) {
            const value = values[cellIndex]
            const normalizedValue = range > 0 ? (value - minVal) / range : 0.5
            const color = this.getColorFromGradient(normalizedValue)
            
            colorMap.set(drawPos, color)
            this.originalPointColors.set(cellIndex, color) // Store by cell index
          } else {
            // Hide filtered-out points
            colorMap.set(drawPos, 0x00000000)
          }
        }
        
        console.log(`🎨 [ReGL] Applied continuous colors to ${colorMap.size} points (including hidden ones)`)
        
        // Update colors in ReGL (but don't render yet, we'll reorder first)
        this.reglRenderer.updateColors(colorMap)
        
        // Check if we need to reorder points for numeric display
        const needsReordering = !this._lastNumericOrderApplied || this._lastNumericOrderApplied !== this.numericalOrder
        
        if (needsReordering) {
          console.log('📊 [ReGL] Applying numeric display order (first time or order changed)...')
          this._lastNumericOrderApplied = this.numericalOrder
          
          // Reorder points in buffer based on z-index (this will re-render and redraw overlay)
          this.reorderPointsForNumericDisplay(values, minVal, maxVal)
          
          // Redraw overlay and legend is handled by reorderPointsForNumericDisplay
          const elapsed = performance.now() - startTime
          console.log(`🎨 [ReGL] Color update with numeric reordering completed in ${elapsed.toFixed(2)}ms`)
          return // Early exit - reordering already rendered everything
        } else {
          // Just render without reordering
          this.reglRenderer.render()
          
          // Render continuous color legend
          this.renderContinuousColorLegend()
        }
      }
    } else {
      // Default blue coloring
      console.log('🎨 [ReGL] Applying default blue colors')
      const defaultColor = 0x3b82f6
      for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
        const cellIndex = this.displayOrder[drawPos]
        const isVisible = !visibleSet || visibleSet.has(cellIndex)
        
        if (isVisible) {
          colorMap.set(drawPos, defaultColor)
          this.originalPointColors.set(cellIndex, defaultColor) // Store by cell index
        } else {
          // Hide filtered-out points
          colorMap.set(drawPos, 0x00000000)
        }
      }
      
      // Update colors in ReGL
      this.reglRenderer.updateColors(colorMap)
      this.reglRenderer.render()
    }
    
    // Redraw the Canvas 2D overlay (grid, axes, labels/legend) to ensure everything is visible
    // Order matters: grid first (clears), then axes, then labels/legend
    this.renderGrid()
    this.renderAxes()
    if (this.currentMetadataVector) {
      if (this.currentMetadataVector.data_type === 'DISCRETE') {
        this.renderCategoryLabels()
      } else if (this.currentMetadataVector.data_type === 'NUMERIC') {
        this.renderContinuousColorLegend()
      }
    }
    
    // Cache the color map and state hash
    this.colorUpdateCache.set('lastColorMap', colorMap)
    this.lastColorUpdateHash = currentColorHash
    
    const elapsed = performance.now() - startTime
    this.recordPerformanceMetrics('ColorUpdate', elapsed)
    console.log(`🎨 [ReGL] Color update completed in ${elapsed.toFixed(2)}ms`)
  }


  // Color points for continuous metadata
  colorPointsContinuous(values, compressionInfo) {
    /*console.log('Coloring points for continuous metadata:', {
      range: `${compressionInfo.min_val} to ${compressionInfo.max_val}`,
      actualRange: `${this.safeMin(values).toFixed(3)} to ${this.safeMax(values).toFixed(3)}`
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
  // Get categories sorted by frequency based on user preference
  getSortedCategories(values, categories) {
    // Calculate category frequencies
    const categoryFrequencies = {}
    values.forEach(value => {
      categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
    })
    
    // Sort categories by frequency based on user preference
    const sorted = categories.sort((a, b) => {
      const freqA = categoryFrequencies[a] || 0
      const freqB = categoryFrequencies[b] || 0
      
      if (this.categoryOrder === 'smallest-first') {
        return freqA - freqB // Ascending order (smallest first)
      } else {
        return freqB - freqA // Descending order (largest first) - default
      }
    })
    return sorted
  }

  // Get categories in a STABLE order for color assignment (always largest-first)
  // This ensures colors are consistent regardless of user's display preference
  getStableSortedCategories(values, categories) {
    const categoryFrequencies = {}
    values.forEach(value => {
      categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
    })
    
    // Always sort largest-first for stable color assignment
    const sorted = [...categories].sort((a, b) => {
      const freqA = categoryFrequencies[a] || 0
      const freqB = categoryFrequencies[b] || 0
      return freqB - freqA // Always descending (largest first)
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
    
    const minVal = this.safeMin(values)
    const maxVal = this.safeMax(values)
    
    console.log('🎚️ Calculated min/max values:', { minVal, maxVal, valuesLength: values.length })
    
    // Check if there's an existing selected range for this metadata - preserve it!
    const existingRange = this.selectedRanges?.[metadataId]
    const currentMin = existingRange?.min ?? minVal
    const currentMax = existingRange?.max ?? maxVal
    
    if (existingRange) {
      console.log('🎚️ Preserving existing range for slider:', existingRange)
    }
    
    // Store the data with preserved range if it exists
    this.inlineRangeSliderData[metadataId] = {
      min: minVal,
      max: maxVal,
      currentMin: currentMin,
      currentMax: currentMax,
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
        controller.currentMinValue = currentMin  // Use preserved value
        controller.currentMaxValue = currentMax  // Use preserved value
        controller.initializeSlider()
        console.log('🎚️ Range slider controller initialized successfully with range:', { currentMin, currentMax })
        
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
    console.log('🎨 clearMetadataColoring() called')
    console.log('🎨 Checking prerequisites:', {
      rendererType: this.rendererType,
      reglRenderer: !!this.reglRenderer,
      pixiApp: !!this.pixiApp,
      scatterContainer: !!this.scatterContainer,
      currentCoordinates: !!this.currentCoordinates,
      currentBounds: !!this.currentBounds
    })
    
    // Check for renderer availability (either ReGL or PixiJS)
    const hasRenderer = this.rendererType === 'regl' ? !!this.reglRenderer : (!!this.pixiApp && !!this.scatterContainer)
    
    if (!hasRenderer || !this.currentCoordinates || !this.currentBounds) {
      console.log('🎨 Cannot clear coloring - missing renderer or coordinates')
      return
    }
    
    console.log('🎨 Clearing metadata coloring, returning to default blue')
    
    // Clear current metadata vector
    this.currentMetadataVector = null
    this.currentMetadataId = null
    
    // Clear custom color range
    this.customColorRange = null
    
    // Clear the cached color map since we're clearing metadata
    this.clearColorMapCache()
    
    // Render points with default blue coloring based on renderer type
    if (this.rendererType === 'regl') {
      console.log('🎨 Using ReGL renderer to clear coloring')
      // For ReGL, we need to render with default blue colors
      this.renderPointsWithCurrentColoringReGL()
    } else {
      // OPTIMIZED: Just update sprite colors directly instead of recreating!
      if (this.pointSprites && this.pointSprites.length > 0) {
        console.log('🎨 Using fast color update path (no recreation)')
        const defaultColor = 0x3b82f6 // Default blue
        
        for (let i = 0; i < this.pointSprites.length; i++) {
          const sprite = this.pointSprites[i]
          if (sprite && !sprite.destroyed) {
            sprite.tint = defaultColor
            sprite.zIndex = 0
            this.originalPointColors.set(i, defaultColor)
          }
        }
        
        // Mark sprites as default coloring
        this.spritesRenderType = 'default'
      } else {
        // Fallback: full re-render if sprites don't exist
        console.log('🎨 Sprites not available, using full re-render')
        this.forceReRenderPoints()
      }
    }
    
    // Clear any existing legend (both discrete and continuous)
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.removeChildren()
      this.categoryLabelsContainer.visible = false
    }
    
    console.log('🎨 Successfully cleared metadata coloring')
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
          // Load into memory for fast access (no spinner for category expansion)
          this.loadSingleMetadataVector(metadataId).then(() => {
            // Initialize checkboxes for this metadata to enable filtering
            this.initializeCheckboxesForMetadata(metadataId).then(() => {
              // Now update the filtering to apply the category selections
              this.updateCellFiltering()
            })
          }).catch(error => {
            console.log(`Failed to load metadata vector ${metadataId} on expansion:`, error.message)
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
    
    // Don't automatically select or color - just expand/collapse the panel
    // The water drop button is used for coloring
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
    console.log('Button dataset.active:', button.dataset.active)
    console.log('Current metadata ID:', this.currentMetadataId)
    
    if (isCurrentlyActive) {
      // Button is already active - deselect it
      console.log('🎨 Button is already active - deselecting...')
      console.log('🎨 Step 1: Resetting water drop buttons...')
      this.resetAllWaterDropButtons()
      console.log('🎨 Step 2: Removing category colors...')
      this.removeAllCategoryColors()
      console.log('🎨 Step 3: Clearing metadata coloring...')
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
        console.log('Step 5: Continuous metadata detected - expanding panel')
        // Expand the continuous metadata panel to show histogram
        this.expandContinuousMetadataPanel(metadataId, metadataName)
        // Continue to load and visualize below
      } else {
        console.log('Step 5: Adding category colors for discrete metadata...')
        this.addCategoryColors(metadataContainer, metadataId)
      }
    } else {
      console.warn('🎨 WARNING: Could not find metadata container, but continuing with metadata loading...')
      
      // Use the debug function to get detailed information
      this.debugMetadataContainerStructure(button)
      
      // This is not necessarily an error - we can still load the metadata vector
      console.log('Proceeding with metadata vector loading without container...')
    }
    
    // Always try to load and visualize the metadata vector (this is the main goal)
    console.log('Step 6: Loading metadata vector for visualization...')
    
    // Show loading spinner immediately
    this.showMetadataDropdownSpinner()
    
    // For continuous metadata, set the color range before visualizing
    if (button.dataset.metadataType === 'NUMERIC') {
      console.log('🎚️ Handling NUMERIC metadata for coloring')
      // Load the metadata first to get the range
      this.loadSingleMetadataVector(metadataId).then(vectorData => {
        console.log('🎚️ Metadata loaded:', vectorData)
        if (vectorData) {
          // Decompress if needed
          let values = vectorData.values
          if (!values && vectorData.compressed_data) {
            console.log('🎚️ Decompressing numeric metadata...')
            values = this.decompressMetadataVector(vectorData)
          }
          
          if (values) {
            // Check if there's already a selected range for this metadata - preserve it!
            const existingRange = this.selectedRanges?.[metadataId]
            
            if (existingRange) {
              // Preserve the existing range
              console.log('🎚️ Preserving existing range for continuous metadata:', existingRange)
              this.setColorRange(existingRange.min, existingRange.max)
            } else {
              // No existing range - use full range
              const minVal = this.safeMin(values)
              const maxVal = this.safeMax(values)
              console.log('🎚️ Setting full color range for continuous metadata:', minVal, maxVal)
              this.setColorRange(minVal, maxVal)
            }
            
            // Now load and visualize
            console.log('🎚️ Calling loadAndVisualizeMetadataVector...')
            return this.loadAndVisualizeMetadataVector(metadataId)
          } else {
            console.error('❌ No values available after decompression')
          }
        } else {
          console.error('❌ No vector data loaded')
        }
      })
      .catch(error => {
        console.error('❌ Error loading/visualizing metadata:', error)
      })
      .finally(() => {
        console.log('🎚️ Hiding spinner after continuous metadata processing')
        this.hideMetadataDropdownSpinner()
      })
    } else {
      // For discrete metadata, just load and visualize directly
      this.loadAndVisualizeMetadataVector(metadataId)
        .catch(error => {
          console.error('❌ Error loading metadata:', error)
        })
        .finally(() => {
          this.hideMetadataDropdownSpinner()
        })
    }
    
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
    
    // Re-enable sprite interactivity
    if (this.scatterContainer) {
      this.scatterContainer.interactiveChildren = true
    }
    if (this.animatedContainer) {
      this.animatedContainer.interactiveChildren = true
    }
  }

  // Set Lasso mode
  setLassoMode(event) {
    //console.log('Setting interaction mode to: lasso')
    this.setInteractionMode('lasso')
    this.updateButtonStates('lasso')
    
    // Disable sprite interactivity for smooth mouse movements
    if (this.scatterContainer) {
      this.scatterContainer.interactiveChildren = false
    }
    if (this.animatedContainer) {
      this.animatedContainer.interactiveChildren = false
    }
  }

  // Set Pick mode
  setPickMode(event) {
    //console.log('Setting interaction mode to: pick')
    this.setInteractionMode('pick')
    this.updateButtonStates('pick')
    
    // Re-enable sprite interactivity
    if (this.scatterContainer) {
      this.scatterContainer.interactiveChildren = true
    }
    if (this.animatedContainer) {
      this.animatedContainer.interactiveChildren = true
    }
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
    const canvas = this.rendererType === 'regl' ? this.canvas : (this.pixiApp && this.pixiApp.view)
    if (!canvas) {
      console.log('⚠️ No canvas available for interaction listeners')
      return
    }
    
    //console.log('Adding interaction event listeners to canvas')
    
    // Get the plot container to add wheel listener there too
    const plotContainer = document.querySelector('.plot-container')
    
    this.boundMouseDown = this.onInteractionMouseDown.bind(this)
    this.boundMouseMove = this.onInteractionMouseMove.bind(this)
    this.boundMouseUp = this.onInteractionMouseUp.bind(this)
    this.boundWheel = this.onInteractionWheel.bind(this)
    this.boundDoubleClick = this.onInteractionDoubleClick.bind(this)
    
    // WORKAROUND: Attach to document with capture to intercept before PIXI gets them!
    console.log('Adding event listeners to canvas AND document:', canvas)
    console.log('Canvas element:', canvas.tagName, canvas.width, canvas.height)
    
    canvas.addEventListener('pointerdown', this.boundMouseDown)
    canvas.addEventListener('pointerup', this.boundMouseUp)
    canvas.addEventListener('wheel', this.boundWheel, { passive: false })
    canvas.addEventListener('dblclick', this.boundDoubleClick)
    
    // Add pointermove to DOCUMENT with capture=true to intercept BEFORE PIXI
    document.addEventListener('pointermove', this.boundMouseMove, { capture: true })
    this.documentMoveListenerAdded = true
    
    // Test if events are reaching handlers
    let testCount = 0
    document.addEventListener('pointermove', (e) => {
      testCount++
      if (testCount % 50 === 0) {
        console.log(`✅ TEST: Document received ${testCount} pointermove events`)
      }
    }, { capture: true })
    
    console.log('✅ Event listeners registered - pointermove on DOCUMENT with capture=true')
    
    // Store reference to plot container for cleanup (but don't add wheel listener)
    if (plotContainer) {
      this.plotContainerElement = plotContainer
    }
    
    // Don't add wheel listener to main container - it would capture left panel scroll events!
    // Only the canvas should have wheel zoom
    
    // Allow body/html scrolling for the left panel
    // The plot container has overflow:hidden, which is enough
    // document.body.style.overflow = 'hidden'  // REMOVED - blocks left panel scroll
    // document.documentElement.style.overflow = 'hidden'  // REMOVED - blocks left panel scroll
    
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
      canvas.removeEventListener('pointerdown', this.boundMouseDown)
    }
    if (this.boundMouseMove) {
      // Remove from document if we added it there
      if (this.documentMoveListenerAdded) {
        document.removeEventListener('pointermove', this.boundMouseMove, { capture: true })
        this.documentMoveListenerAdded = false
      }
    }
    if (this.boundMouseUp) {
      canvas.removeEventListener('pointerup', this.boundMouseUp)
    }
    if (this.boundWheel) {
      canvas.removeEventListener('wheel', this.boundWheel, { passive: false })
    }
    if (this.boundDoubleClick) {
      canvas.removeEventListener('dblclick', this.boundDoubleClick)
    }
  }

  onInteractionMouseDown(event) {
    console.log('🎯 [Interaction] onInteractionMouseDown called, mode:', this.interactionMode, 'rendererType:', this.rendererType)
    if (this.interactionMode === 'lasso') {
      this.onLassoMouseDown(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanMouseDown(event)
    } else if (this.interactionMode === 'pick') {
      this.onPickMouseDown(event)
    }
  }

  onInteractionMouseMove(event) {
    // Handle label dragging in pick mode (ReGL)
    if (this.interactionMode === 'pick' && this.draggingLabel && this.rendererType === 'regl') {
      const canvas = this.canvas
      const rect = canvas.getBoundingClientRect()
      const mouseX = event.clientX - rect.left
      const mouseY = event.clientY - rect.top
      
      // Calculate drag delta
      const deltaX = mouseX - this.labelDragStartX
      const deltaY = mouseY - this.labelDragStartY
      
      // Update label offset
      this.draggingLabel.offsetX = this.labelStartOffsetX + deltaX
      this.draggingLabel.offsetY = this.labelStartOffsetY + deltaY
      
      console.log(`🏷️ [Drag] Moving label "${this.draggingLabel.category}" - offset: (${this.draggingLabel.offsetX}, ${this.draggingLabel.offsetY})`)
      
      // Redraw the overlay (grid, axes, labels)
      this.renderGrid()
      this.renderAxes()
      this.renderCategoryLabels()
      
      return
    }
    
    // Handle point hovering in pick mode (RegL)
    if (this.interactionMode === 'pick' && this.rendererType === 'regl' && !this.isTooltipFixed) {
      this.detectRegLPointHover(event)
      return
    }
    
    // DEBUG: Log to verify events are being received
    if (this.isDrawingLasso) {
      this.interactionMoveCount = (this.interactionMoveCount || 0) + 1
      if (this.interactionMoveCount % 20 === 0) {
        console.log(`⏱️ [DEBUG] onInteractionMouseMove called ${this.interactionMoveCount} times (lasso mode)`)
      }
    }
    
    // Only process if actually drawing/panning (not just hovering)
    if (this.interactionMode === 'lasso' && this.isDrawingLasso) {
      this.onLassoMouseMove(event)
    } else if (this.interactionMode === 'pan' && this.isPanning) {
      this.onPanMouseMove(event)
    }
    // If just hovering, do nothing - don't block the UI thread!
  }

  onInteractionMouseUp(event) {
    // Handle label drag end in pick mode (ReGL)
    if (this.interactionMode === 'pick' && this.draggingLabel && this.rendererType === 'regl') {
      console.log(`🏷️ Finished dragging label: ${this.draggingLabel.category}`)
      this.draggingLabel = null
      this.clickingOnLabel = false
      return
    }
    
    if (this.interactionMode === 'lasso') {
      this.onLassoMouseUp(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanMouseUp(event)
    }
  }

  onInteractionDoubleClick(event) {
    console.log('Double-click event:', this.interactionMode)
    if (this.interactionMode === 'lasso') {
      this.onLassoDoubleClick(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanDoubleClick(event)
    } else if (this.interactionMode === 'pick') {
      // In pick mode, double-click also resets zoom/pan
      this.onPanDoubleClick(event)
    }
  }

  onInteractionWheel(event) {
    // Always prevent default scroll behavior when over the plot
    if (event.cancelable) {
      event.preventDefault()
      event.stopPropagation()
      event.stopImmediatePropagation()
    }
    
    // Don't zoom if we're currently panning (but allow zoom in pan mode when not actively panning)
    if (this.isPanning) {
      return false
    }
    
    if (!this.currentCoordinates || !this.currentBounds) {
      return false
    }
    
    // Get mouse position relative to canvas
    const canvas = this.rendererType === 'regl' ? this.canvas : (this.pixiApp && this.pixiApp.view)
    const rect = canvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    
    // Basic zoom implementation with faster increments, zooming around mouse cursor
    const delta = event.deltaY > 0 ? 1.05 : 0.95
    
    // Get canvas dimensions
    const canvasWidth = this.rendererType === 'regl' ? this.canvas.width : this.pixiApp.screen.width
    const canvasHeight = this.rendererType === 'regl' ? this.canvas.height : this.pixiApp.screen.height
    
    // Convert mouse position to data coordinates
    const mouseDataX = this.currentBounds.minX + (mouseX / canvasWidth) * (this.currentBounds.maxX - this.currentBounds.minX)
    const mouseDataY = this.currentBounds.minY + (mouseY / canvasHeight) * (this.currentBounds.maxY - this.currentBounds.minY)
    
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
    
    // Use shape-based zooming for smooth performance with large datasets
    // Only use for PixiJS mode with very large visible point counts
    const boundsArea = (newBounds.maxX - newBounds.minX) * (newBounds.maxY - newBounds.minY)
    const totalArea = (this.currentBounds.maxX - this.currentBounds.minX) * (this.currentBounds.maxY - this.currentBounds.minY)
    const estimatedVisiblePoints = Math.floor((boundsArea / totalArea) * this.currentCoordinates.length)
    const useShapeZooming = this.rendererType === 'pixi' && estimatedVisiblePoints > 200000  // Only use for >200k visible points in PixiJS mode
    
    if (useShapeZooming) {
      // Hide points and show zooming shape
      if (this.scatterContainer) {
        this.scatterContainer.visible = false
      }
      if (this.categoryLabelsContainer) {
        this.categoryLabelsContainer.visible = false
      }
      
      // Store the bounds for this zooming operation
      const zoomingBounds = newBounds
      
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
        // Transform using container scaling (instant!)
        this.transformZoomingShape(oldBounds, newBounds)
      }
      
      // Update axes and grid
      this.renderAxes()
      this.renderGrid()
      
      // Clear any existing timeout
      if (this.zoomTimeout) {
        clearTimeout(this.zoomTimeout)
      }
      
      // Use very short delay to batch wheel events while maintaining responsiveness
      this.zoomTimeout = setTimeout(() => {
        requestAnimationFrame(() => {
          this.finishZooming()
        })
      }, 16) // ~1 frame at 60fps - minimal delay while still batching events
      
    } else {
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
      
      // Update sprite positions immediately for instant visual feedback
      this.translatePointsForZoom(oldBounds, newBounds, mouseX, mouseY)
      
      // Throttle axes/grid/labels updates to avoid re-rendering on every wheel event
      if (this.zoomAxisUpdateTimeout) {
        clearTimeout(this.zoomAxisUpdateTimeout)
      }
      this.zoomAxisUpdateTimeout = setTimeout(() => {
        requestAnimationFrame(() => {
          // For Canvas 2D overlay (ReGL mode), order matters:
          // 1. renderGrid() - clears canvas and draws grid
          // 2. renderAxes() - draws axes on top
          // 3. renderCategoryLabels() or renderContinuousColorLegend() - draws labels/legend on top
          this.renderGrid()
          this.renderAxes()
          
          // Re-render the appropriate legend/labels based on metadata type
          if (this.currentMetadataVector?.data_type === 'DISCRETE') {
            this.renderCategoryLabels()
          } else if (this.currentMetadataVector?.data_type === 'NUMERIC') {
            this.renderContinuousColorLegend()
          }
        })
      }, 100) // Update UI elements after zoom stabilizes
    }
    
    // Return false to ensure no default scroll behavior
    return false
  }
  // Lasso mode handlers
  onLassoMouseDown(event) {
    console.log('========================================')
    console.log('⏱️ [LASSO] Starting lasso selection')
    
    // Detect browser and store it
    this.isFirefox = navigator.userAgent.toLowerCase().indexOf('firefox') > -1
    
    // Stop PIXI render loop during lasso drawing to free up main thread (PixiJS mode only)
    if (this.rendererType === 'pixi' && this.pixiApp) {
      this.pixiApp.ticker.stop()
    }
    
    // Create HTML canvas overlay for lasso drawing
    const plotContainer = document.querySelector('.plot-container')
    if (plotContainer && !this.lassoCanvas) {
      const canvas = this.rendererType === 'regl' ? this.canvas : this.pixiApp.view
      
      this.lassoCanvas = document.createElement('canvas')
      this.lassoCanvas.width = canvas.width
      this.lassoCanvas.height = canvas.height
      this.lassoCanvas.style.position = 'absolute'
      this.lassoCanvas.style.top = '0'
      this.lassoCanvas.style.left = '0'
      this.lassoCanvas.style.pointerEvents = 'none'
      this.lassoCanvas.style.zIndex = '1000' // On top of everything
      plotContainer.appendChild(this.lassoCanvas)
      
      this.lassoCanvasCtx = this.lassoCanvas.getContext('2d')
    }
    
    // Remove PIXI's event system for smooth drawing (PixiJS mode only)
    if (this.rendererType === 'pixi') {
      if (this.pixiApp?.renderer?.events) {
        this.pixiApp.renderer.events.removeEvents()
      }
      if (this.globalDragHandlers && this.pixiApp?.stage) {
        this.pixiApp.stage.off('pointermove', this.globalDragHandlers.move)
      }
    }
    
    this.isDrawingLasso = true
    this.lassoPoints = []
    this.mouseMoveCount = 0
    this.interactionMoveCount = 0
    this.lastMouseMoveTime = performance.now()
    
    // Get mouse position relative to canvas
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    // Cache rect for performance during mouse moves
    const rect = canvas.getBoundingClientRect()
    this.cachedCanvasRect = rect
    
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    
    this.lassoPoints.push({ x, y })
    
    // Clear the overlay canvas
    if (this.lassoCanvasCtx) {
      this.lassoCanvasCtx.clearRect(0, 0, this.lassoCanvas.width, this.lassoCanvas.height)
    }
    
    // Firefox workaround: Poll mouse position at high frequency for smooth drawing
    if (this.isFirefox) {
      this.lastMouseX = x + rect.left
      this.lastMouseY = y + rect.top
      
      // Track last mouse position from any move event
      this.firefoxMouseHandler = (e) => {
        this.lastMouseX = e.clientX
        this.lastMouseY = e.clientY
      }
      document.addEventListener('pointermove', this.firefoxMouseHandler, { capture: true })
      
      // Poll at 250fps
      this.firefoxPollInterval = setInterval(() => {
        if (!this.isDrawingLasso) return
        
        const x = this.lastMouseX - rect.left
        const y = this.lastMouseY - rect.top
        
        const lastPoint = this.lassoPoints[this.lassoPoints.length - 1]
        const distance = this.getDistance(lastPoint, { x, y })
        
        if (distance > 1) {
          this.lassoPoints.push({ x, y })
          this.updateLassoGraphics()
        }
      }, 4)
    }
  }

  onLassoMouseMove(event) {
    if (!this.isDrawingLasso) return
    
    this.mouseMoveCount = (this.mouseMoveCount || 0) + 1
    
    // Firefox uses polling, so skip event-based processing
    if (this.isFirefox) {
      return
    }
    
    // Get coalesced events - these contain ALL positions since last callback!
    const coalescedEvents = event.getCoalescedEvents ? event.getCoalescedEvents() : [event]
    
    const canvas = this.canvas || (this.pixiApp && this.pixiApp.canvas)
    if (!canvas) return
    
    const rect = this.cachedCanvasRect
    if (!rect) return
    
    // Process EVERY coalesced event for maximum smoothness!
    let pointsAdded = 0
    for (const evt of coalescedEvents) {
      const x = evt.clientX - rect.left
      const y = evt.clientY - rect.top
      
    const lastPoint = this.lassoPoints[this.lassoPoints.length - 1]
      const distance = lastPoint ? this.getDistance(lastPoint, { x, y }) : Infinity
    
      // Add every coalesced point (no interpolation needed!)
      if (!lastPoint || distance > 0.5) {
      this.lassoPoints.push({ x, y })
        pointsAdded++
      }
    }
    
    if (pointsAdded > 0) {
      // Log progress
      if (this.lassoPoints.length % 50 === 0) {
        console.log(`⏱️ [LASSO] ${this.lassoPoints.length} points from ${this.mouseMoveCount} callbacks`)
      }
      
      // Update graphics once per callback
      this.updateLassoGraphics()
    }
  }

  onLassoMouseUp(event) {
    if (!this.isDrawingLasso) return
    const completionStart = performance.now()
    
    this.isDrawingLasso = false
    this.cachedCanvasRect = null
    
    // Clear the HTML canvas overlay
    if (this.lassoCanvasCtx) {
      this.lassoCanvasCtx.clearRect(0, 0, this.lassoCanvas.width, this.lassoCanvas.height)
    }
    
    // Re-enable PIXI event system (PixiJS mode only)
    if (this.rendererType === 'pixi') {
      if (this.pixiApp?.renderer?.events) {
        this.pixiApp.renderer.events.setTargetElement(this.pixiApp.view)
      }
      if (this.globalDragHandlers && this.pixiApp?.stage) {
        this.pixiApp.stage.on('pointermove', this.globalDragHandlers.move)
      }
      
      // Restart PIXI render loop now that drawing is complete
      if (this.pixiApp && !this.pixiApp.ticker.started) {
        this.pixiApp.ticker.start()
      }
    }
    
    // Clean up Firefox polling
    if (this.firefoxPollInterval) {
      clearInterval(this.firefoxPollInterval)
      this.firefoxPollInterval = null
    }
    
    if (this.firefoxMouseHandler) {
      document.removeEventListener('pointermove', this.firefoxMouseHandler, { capture: true })
      this.firefoxMouseHandler = null
    }
    
    // Only proceed if we have coordinates to work with
    if (!this.currentCoordinates) {
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
      
      const completionTime = performance.now() - completionStart
      console.log(`⏱️ [LASSO] Total completion: ${completionTime.toFixed(2)}ms`)
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
    
    // Cache rect for performance during mouse moves
    const rect = canvas.getBoundingClientRect()
    this.cachedCanvasRect = rect
    
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
    
    // For large datasets, use panning shape for smooth performance
    const usePanningShape = this.currentCoordinates.length > 100000
    
    if (usePanningShape) {
      // Hide real points during panning for large datasets
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
    const canvas = this.rendererType === 'regl' ? this.canvas : (this.pixiApp && this.pixiApp.view)
    if (!canvas) return
    
    // Use cached rect if available (set when pan starts)
    const rect = this.cachedCanvasRect || canvas.getBoundingClientRect()
    const currentX = event.clientX - rect.left
    const currentY = event.clientY - rect.top
    
    // Calculate pan delta
    const deltaX = currentX - this.panStartX
    const deltaY = currentY - this.panStartY
    
    // Store the mouse delta for label movement
    this.panMouseDeltaX = deltaX
    this.panMouseDeltaY = deltaY
    
    // Convert screen delta to data delta using the same coordinate system as normalization
    const screenWidth = this.rendererType === 'regl' ? this.canvas.width : this.pixiApp.screen.width
    const screenHeight = this.rendererType === 'regl' ? this.canvas.height : this.pixiApp.screen.height
    
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
    // For Canvas 2D overlay (ReGL mode), order matters: grid first (clears), then axes, then labels
    this.renderGrid()
    this.renderAxes()
    
    // In ReGL mode, we need to redraw labels/legend too since renderGrid() clears the canvas
    if (this.rendererType === 'regl') {
      if (this.currentMetadataVector?.data_type === 'DISCRETE') {
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked) {
          this.renderCategoryLabels()
        }
      } else if (this.currentMetadataVector?.data_type === 'NUMERIC') {
        // Re-render continuous color legend during panning
        this.renderContinuousColorLegend()
      }
    }
    
    // Move the points to match the new bounds during panning
    this.updatePointPositions()

    // Don't update category labels during panning in PixiJS mode - they move automatically as PIXI objects
    
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
    this.cachedCanvasRect = null // Clear cached rect
    
    // Store bounds for debug before resetting
    const debugPanStartBounds = this.panStartBounds
    const debugPanOriginalBounds = this.panOriginalBounds
    
    // Bounds are already updated in real-time during panning, no need to recalculate
    
    // Remove the panning shape and its mask if it exists
    if (this.panningShape && this.pixiApp) {
      // Remove the mask first if it exists
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
    
    // Show real points again after panning
    if (this.scatterContainer) {
      this.scatterContainer.visible = true
    }
    
    // Refresh labels/legend after panning with a small delay for smooth transition
    if (this.currentMetadataVector?.data_type === 'DISCRETE') {
      const categoriesCheckbox = document.getElementById('show-categories-checkbox')
      if (categoriesCheckbox && categoriesCheckbox.checked) {
        setTimeout(() => {
          console.log(`🏷️ Refreshing labels after panning`)
          this.renderCategoryLabels()
        }, 50)
      }
    } else if (this.currentMetadataVector?.data_type === 'NUMERIC') {
      // Refresh continuous color legend after panning
      setTimeout(() => {
        console.log(`🎨 Refreshing legend after panning`)
        this.renderContinuousColorLegend()
      }, 50)
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
      console.log('No data available for reset')
      return
    }

    console.log('🔄 Resetting zoom and pan to original view')
    
    // Clear any stored original positions
    this.clearStoredOriginalPositions()
    
    // Reset to original bounds
    const originalBounds = this.calculateBounds(this.currentCoordinates)
    const newBounds = this.getAdjustedBounds(originalBounds)
    this.currentBounds = newBounds
    
    // ReGL PATH: Re-normalize all coordinates with original bounds
    if (this.rendererType === 'regl') {
      console.log('🔄 [ReGL] Resetting view - re-normalizing all coordinates')
      
      if (this.reglRenderer) {
        const screenCoordinates = new Float32Array(this.displayOrder.length * 2)
        
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const [x, y] = this.currentCoordinates[cellIndex]
          screenCoordinates[drawPos * 2] = this.normalizeX(x, newBounds)
          screenCoordinates[drawPos * 2 + 1] = this.normalizeY(y, newBounds)
        }
        
        // Update positions in ReGL
        this.reglRenderer.updatePositions(screenCoordinates)
        this.reglRenderer.render()
        
        // Redraw overlay (grid, axes, labels)
        this.renderGrid()
        this.renderAxes()
        
        // Re-render category labels if visible
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked && this.currentMetadataVector?.data_type === 'DISCRETE') {
          this.renderCategoryLabels()
        }
        
        console.log('🔄 [ReGL] View reset complete')
      }
      return
    }
    
    // PixiJS PATH (original)
    console.log('🔄 Updating sprite positions for reset view')
    
    // Update sprite positions without recreation (much faster!)
    if (this.pointSprites && this.pointSprites.length === this.currentCoordinates.length) {
      const updateStart = performance.now()
      
      for (let i = 0; i < this.pointSprites.length; i++) {
        const sprite = this.pointSprites[i]
        if (sprite) {
          const [x, y] = this.currentCoordinates[i]
          sprite.x = this.normalizeX(x, this.currentBounds)
          sprite.y = this.normalizeY(y, this.currentBounds)
        }
      }
      
      const updateTime = performance.now() - updateStart
      console.log(`🔄 Updated ${this.pointSprites.length} sprite positions in ${updateTime.toFixed(2)}ms`)
    } else {
      // Fallback: no sprites to update, need full render
      console.log('🔄 No sprites available, doing full render')
    this.scatterContainer.removeChildren()
    this.renderPointsWithCurrentColoring()
    }
    
    // Re-render axes and grid with new bounds
    this.renderAxes()
    this.renderGrid()
    
    // Re-render category labels after resetting view
    if (this.categoryLabelsContainer && this.categoryLabelsContainer.visible) {
      this.renderCategoryLabels()
    }
    
    console.log('🔄 Zoom and pan reset to original view')
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
    
    // Calculate scale factors
    const oldWidth = oldBounds.maxX - oldBounds.minX
    const oldHeight = oldBounds.maxY - oldBounds.minY
    const newWidth = newBounds.maxX - newBounds.minX
    const newHeight = newBounds.maxY - newBounds.minY
    
    // Calculate how much to scale the container
    const scaleX = oldWidth / newWidth
    const scaleY = oldHeight / newHeight
    
    // Calculate translation to keep the zoom centered
    // Get screen dimensions
    const screenWidth = this.pixiApp.screen.width
    const screenHeight = this.pixiApp.screen.height
    
    // Calculate the center offset in screen coordinates
    const oldCenterScreenX = screenWidth / 2
    const oldCenterScreenY = screenHeight / 2
    
    // Apply scale to the container (MUCH faster than moving individual points!)
    this.zoomingShape.scale.x = scaleX
    this.zoomingShape.scale.y = scaleY
    
    // Adjust position to keep content centered
    this.zoomingShape.x = oldCenterScreenX - (oldCenterScreenX * scaleX)
    this.zoomingShape.y = oldCenterScreenY - (oldCenterScreenY * scaleY)
  }

  // Create a shape for zooming with specific bounds
  createZoomingShapeWithBounds(bounds) {
    if (!this.pixiApp || !bounds || !this.currentCoordinates) return null
    
    const container = new PIXI.Container()
    
    // Optimized sampling - fewer points since we use container scaling
    // This makes initial creation faster while still showing good representation
    const sampleSize = Math.min(20000, this.currentCoordinates.length)
    
    // Create random sample indices for better distribution representation
    const sampleIndices = new Set()
    const step = Math.floor(this.currentCoordinates.length / sampleSize)
    
    // Mix of uniform and random sampling for best representation
    for (let i = 0; i < this.currentCoordinates.length; i += step) {
      sampleIndices.add(i)
      // Add a random nearby point for better cluster representation
      if (sampleIndices.size < sampleSize) {
        const randomOffset = Math.floor(Math.random() * step)
        const randomIndex = Math.min(i + randomOffset, this.currentCoordinates.length - 1)
        sampleIndices.add(randomIndex)
      }
    }
    
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
    
    // Create individual animated point sprites from sampled indices
    for (const i of sampleIndices) {
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
    
    // Show points and labels/legend again
    if (this.scatterContainer) {
      this.scatterContainer.visible = true
    }
    
    // Re-render labels or legend based on metadata type
    if (this.currentMetadataVector?.data_type === 'DISCRETE') {
      if (this.categoryLabelsContainer) {
        // Check if categories should be visible
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked) {
          setTimeout(() => {
            console.log(`🏷️ Refreshing labels after zooming (delayed)`)
            this.renderCategoryLabels()
          }, 200)
        }
      }
    } else if (this.currentMetadataVector?.data_type === 'NUMERIC') {
      // Refresh continuous color legend after zooming
      setTimeout(() => {
        console.log(`🎨 Refreshing legend after zooming (delayed)`)
        this.renderContinuousColorLegend()
      }, 200)
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
    // Use same sample size as zooming for consistency
    const sampleSize = Math.min(20000, this.currentCoordinates.length)
    
    // Create random sample indices for better distribution representation
    const sampleIndices = new Set()
    const step = Math.floor(this.currentCoordinates.length / sampleSize)
    
    // Mix of uniform and random sampling for best representation
    for (let i = 0; i < this.currentCoordinates.length; i += step) {
      sampleIndices.add(i)
      // Add a random nearby point for better cluster representation
      if (sampleIndices.size < sampleSize) {
        const randomOffset = Math.floor(Math.random() * step)
        const randomIndex = Math.min(i + randomOffset, this.currentCoordinates.length - 1)
        sampleIndices.add(randomIndex)
      }
    }
    
    // Create a simplified point cloud representation
    for (const i of sampleIndices) {
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
    // ===== ReGL PATH: Re-normalize all positions with current bounds =====
    if (this.rendererType === 'regl') {
      if (!this.currentCoordinates || !this.currentBounds || !this.reglRenderer) {
        console.log('Cannot update positions - missing data (ReGL)')
        return
      }
      
      // Re-normalize all coordinates to screen space with current bounds
      // Use displayOrder to maintain proper draw order
      const screenCoordinates = new Float32Array(this.displayOrder.length * 2)
      for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
        const cellIndex = this.displayOrder[drawPos]
        const [x, y] = this.currentCoordinates[cellIndex]
        screenCoordinates[drawPos * 2] = this.normalizeX(x, this.currentBounds)
        screenCoordinates[drawPos * 2 + 1] = this.normalizeY(y, this.currentBounds)
      }
      
      // Fast update using buffer.subdata()
      this.reglRenderer.updatePositions(screenCoordinates)
      this.reglRenderer.render()
      return
    }
    
    // ===== PixiJS PATH (original) =====
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

    const canvas = this.rendererType === 'regl' ? this.canvas : (this.pixiApp && this.pixiApp.view)
    if (!canvas) return

    // ===== ReGL PATH: Re-normalize all positions with new bounds =====
    if (this.rendererType === 'regl') {
      if (!this.currentCoordinates || !this.reglRenderer) {
        console.log('⚠️ [ZOOM] Missing coordinates or bounds')
        return
      }
      
      console.log('🔍 [ZOOM] translatePointsForZoom called', {
        hasCoordinates: !!this.currentCoordinates,
        coordinatesLength: this.currentCoordinates.length,
        hasRenderer: !!this.reglRenderer,
        oldBounds,
        newBounds
      })
      
      // Re-normalize all coordinates to screen space with new bounds
      // Use displayOrder to maintain proper draw order
      const screenCoordinates = new Float32Array(this.displayOrder.length * 2)
      for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
        const cellIndex = this.displayOrder[drawPos]
        const [x, y] = this.currentCoordinates[cellIndex]
        screenCoordinates[drawPos * 2] = this.normalizeX(x, newBounds)
        screenCoordinates[drawPos * 2 + 1] = this.normalizeY(y, newBounds)
      }
      
      // Fast update using buffer.subdata()
      this.reglRenderer.updatePositions(screenCoordinates)
      this.reglRenderer.render()
      
      console.log('✅ [ZOOM] ReGL zoom complete')
      return
    }

    // ===== PixiJS PATH (original) =====
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
        }
      })
    }

    // Translate points in scatterContainer (direct children)
    translatePointsInContainer(this.scatterContainer, 'Direct')
    
    // Also check for points in animatedContainer if it exists
    if (this.animatedContainer && this.animatedContainer.children.length > 0) {
      translatePointsInContainer(this.animatedContainer, 'Animated')
    }
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
    console.log('🔄 forceReRenderPoints called')
    if (this.currentCoordinates && this.scatterContainer) {
      // With zIndex support, we can reuse sprites - just update colors and z-order
      // No need to clear sprite cache anymore!
      console.log('🔄 Calling renderPointsWithCurrentColoring (sprites will be reused with zIndex updates)')
      
      // Just re-render with current sprites
        this.renderPointsWithCurrentColoring()
      
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

    // Just delegate to the main rendering function which handles sprites properly
    // The main function will use the scatterContainer, so we need to temporarily swap it
    const originalContainer = this.scatterContainer
    this.scatterContainer = container
    
    this.renderPointsWithCurrentColoring()
    
    // Restore original container
    this.scatterContainer = originalContainer
  }

  // Render plot axes with labels
  renderAxes() {
    // Dispatch to Canvas 2D version for ReGL mode
    if (this.rendererType === 'regl') {
      return this.renderAxesCanvas2D()
    }
    
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
    // Dispatch to Canvas 2D version for ReGL mode
    if (this.rendererType === 'regl') {
      return this.renderGridCanvas2D()
    }
    
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
    // Dispatch to Canvas 2D version for ReGL mode
    if (this.rendererType === 'regl') {
      return this.renderCategoryLabelsCanvas2D()
    }
    
    const renderStartTime = performance.now()
    
    // Debug: Track where this function is called from
    const stack = new Error().stack
    const caller = stack.split('\n')[2] || 'unknown'
    console.log(`🏷️ renderCategoryLabels called from:`, caller.trim())
    console.log(`🏷️ isPanning: ${this.isPanning}`)
    console.log(`🏷️ rendererType: ${this.rendererType}`)
    
    // Detailed component check
    console.log(`🏷️ Component check:`, {
      hasCategoryLabelsContainer: !!this.categoryLabelsContainer,
      hasCurrentBounds: !!this.currentBounds,
      hasPixiApp: !!this.pixiApp,
      hasCurrentMetadataVector: !!this.currentMetadataVector,
      hasCurrentCoordinates: !!this.currentCoordinates,
      metadataType: this.currentMetadataVector?.data_type
    })
    
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
    
    // Check if the user wants to see category labels
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')
    const shouldShowLabels = categoriesCheckbox ? categoriesCheckbox.checked : false
    
    console.log(`🏷️ Category labels checkbox state: ${shouldShowLabels}`)
    
    // If checkbox is unchecked, hide the container and return early
    if (!shouldShowLabels) {
      this.categoryLabelsContainer.visible = false
    this.categoryLabelsContainer.removeChildren()
      console.log('🏷️ Category labels hidden by user preference')
      return
    }

    // Clear existing labels and make container visible
    this.categoryLabelsContainer.removeChildren()
    this.categoryLabelsContainer.visible = true

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

    // Render labels for each category
    const labelCreationStartTime = performance.now()
    let labelsAdded = 0
    // First, process categories with visible points
    console.log(`🏷️ Total centroids to process: ${Object.keys(centroids).length}`)
    Object.entries(centroids).forEach(([category, centroid]) => {
      
      if (centroid.count > 0) { // Only show labels for categories with points
        // Check if this category is selected by looking at the checkbox state
        const categoryCheckbox = document.querySelector(`.category-checkbox[data-metadata-id="${this.currentMetadataVector.id}"][data-category="${category}"]`)
        
        // If checkbox doesn't exist yet (e.g., when first loading metadata), assume all categories are selected
        if (!categoryCheckbox) {
          // Category is selected by default
        } else {
          const bgColor = categoryCheckbox.style.backgroundColor
        // Check if NOT unselected (unselected is #f3f4f6 or rgb(243, 244, 246))
          const isCategorySelected = bgColor !== '#f3f4f6' && bgColor !== 'rgb(243, 244, 246)'
        
        if (!isCategorySelected) {
          return // Skip rendering label for unselected categories
          }
        }

        
        const screenX = this.normalizeX(centroid.x, this.currentBounds)
        const screenY = this.normalizeY(centroid.y, this.currentBounds)

        // Skip if outside visible area (with some margin)
        const margins = this.getPlotMargins()
        const margin = Math.max(margins.left, margins.right, margins.top, margins.bottom)
        const isOffScreen = screenX < -margin || screenX > width + margin || screenY < -margin || screenY > height + margin
        if (isOffScreen) {
          return
        }

        // Create label with background
        let label
        try {
          label = this.createCategoryLabel(category, centroid.count)
        } catch (error) {
          console.error(`🏷️ ERROR creating label for ${category}:`, error)
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
        
      }
    })
    
    // Note: visibility is already set at the top of this function based on checkbox state
    
    console.log(`🏷️ Labels render complete:`, {
      labelsAdded,
      containerVisible: this.categoryLabelsContainer.visible,
      containerChildren: this.categoryLabelsContainer.children.length,
      containerAlpha: this.categoryLabelsContainer.alpha,
      containerX: this.categoryLabelsContainer.x,
      containerY: this.categoryLabelsContainer.y,
      containerOnStage: this.categoryLabelsContainer.parent === this.pixiApp.stage,
      stageChildren: this.pixiApp.stage.children.length
    })
    
    // Debug: Log first few label positions
    if (labelsAdded > 0) {
      console.log(`🏷️ First 3 label positions:`)
      for (let i = 0; i < Math.min(3, this.categoryLabelsContainer.children.length); i++) {
        const label = this.categoryLabelsContainer.children[i]
        console.log(`  Label ${i}: x=${label.x}, y=${label.y}, visible=${label.visible}, alpha=${label.alpha}`)
      }
    }

    // Update label interaction behavior for newly created labels
    this.updateLabelInteractionMode()

    const labelCreationEndTime = performance.now()
    
    // In ReGL mode, manually trigger PixiJS render to update overlay
    if (this.rendererType === 'regl' && this.pixiApp) {
      console.log('🏷️ Triggering PixiJS overlay render...')
      this.pixiApp.renderer.render(this.pixiApp.stage)
      console.log('🏷️ PixiJS overlay rendered')
    }
    
    const renderEndTime = performance.now()
    
    
  }

  // Canvas 2D version of renderAxes for ReGL mode
  renderAxesCanvas2D() {
    if (!this.overlayCtx || !this.overlayCanvas || !this.currentBounds) return
    
    const ctx = this.overlayCtx
    const { minX, maxX, minY, maxY } = this.currentBounds
    const width = this.overlayCanvas.width
    const height = this.overlayCanvas.height
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
      ctx.fillText(value.toFixed(1), screenX, xAxisY + 7)
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
    ctx.fillText('Dimension 1', width / 2, height - 5)
    
    // Y-axis title (rotated)
    ctx.save()
    ctx.translate(15, height / 2)
    ctx.rotate(-Math.PI / 2)
    ctx.textAlign = 'center'
    ctx.textBaseline = 'bottom'
    ctx.fillText('Dimension 2', 0, 0)
    ctx.restore()
  }

  // Canvas 2D version of renderGrid for ReGL mode
  renderGridCanvas2D() {
    if (!this.overlayCtx || !this.overlayCanvas || !this.currentBounds) return
    
    // Clear canvas first
    this.overlayCtx.clearRect(0, 0, this.overlayCanvas.width, this.overlayCanvas.height)
    
    const ctx = this.overlayCtx
    const { minX, maxX, minY, maxY } = this.currentBounds
    const width = this.overlayCanvas.width
    const height = this.overlayCanvas.height
    const margins = this.getPlotMargins()
    
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
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

  // Canvas 2D version of renderCategoryLabels for ReGL mode
  renderCategoryLabelsCanvas2D() {
    console.log('🏷️ [Canvas2D] renderCategoryLabelsCanvas2D called')
    
    if (!this.overlayCtx || !this.overlayCanvas || !this.currentBounds || !this.currentMetadataVector || !this.currentCoordinates) {
      console.log('🏷️ [Canvas2D] Missing required components')
      return
    }
    
    // Only render labels for discrete metadata
    if (this.currentMetadataVector.data_type !== 'DISCRETE') {
      console.log('🏷️ [Canvas2D] Not discrete metadata, skipping')
      return
    }
    
    // Check if the user wants to see category labels
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')
    const shouldShowLabels = categoriesCheckbox ? categoriesCheckbox.checked : false
    
    console.log(`🏷️ [Canvas2D] Category labels checkbox state: ${shouldShowLabels}`)
    
    if (!shouldShowLabels) {
      console.log('🏷️ [Canvas2D] Category labels hidden by user preference')
      // Clear stored labels when hidden
      this.canvas2DLabels = []
      return
    }
    
    // Initialize labels array if not exists
    if (!this.canvas2DLabels) {
      this.canvas2DLabels = []
    }
    
    const ctx = this.overlayCtx
    const width = this.overlayCanvas.width
    const height = this.overlayCanvas.height
    
    // Get the metadata values and categories
    const values = this.currentMetadataVector.values
    const categories = this.currentMetadataVector.categories
    
    // If categories is undefined, try to get unique values from the values array
    let categoryList = categories
    if (!categoryList || categoryList.length === 0) {
      categoryList = [...new Set(values)]
    }
    
    console.log(`🏷️ [Canvas2D] Found ${categoryList.length} categories`)
    console.log(`🏷️ [Canvas2D] Current bounds:`, this.currentBounds)
    console.log(`🏷️ [Canvas2D] Canvas dimensions: ${width}x${height}`)
    
    // Calculate centroids
    const centroids = this.calculateCategoryCentroids(values, categoryList)
    
    console.log(`🏷️ [Canvas2D] Calculated ${Object.keys(centroids).length} centroids`)
    
    // Get category colors
    const categoryColors = this.getCategoryColors()
    const uniqueCategories = [...new Set(values)]
    const categoryToIndex = {}
    uniqueCategories.forEach((cat, idx) => {
      categoryToIndex[cat] = idx
    })
    
    // Clear old labels array for this rendering
    const newLabels = []
    
    // Render labels for each category
    let labelsDrawn = 0
    let labelsSkipped = 0
    Object.entries(centroids).forEach(([category, centroid]) => {
      if (centroid.count > 0) {
        // Calculate default screen position from centroid
        let screenX = this.normalizeX(centroid.x, this.currentBounds)
        let screenY = this.normalizeY(centroid.y, this.currentBounds)
        
        // Check if this label was previously dragged (has offset)
        const existingLabel = this.canvas2DLabels.find(l => l.category === category)
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
        
        // Get category color
        const categoryIndex = categoryToIndex[category] || 0
        const colorValue = categoryColors[categoryIndex % categoryColors.length]
        
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
    this.canvas2DLabels = newLabels
    
    // If we're currently dragging a label, update the reference to point to the new label object
    if (this.draggingLabel) {
      const newDraggingLabel = newLabels.find(l => l.category === this.draggingLabel.category)
      if (newDraggingLabel) {
        console.log(`🏷️ [Canvas2D] Updated dragging label reference for "${this.draggingLabel.category}"`)
        this.draggingLabel = newDraggingLabel
      }
    }
    
    console.log(`🏷️ [Canvas2D] Drew ${labelsDrawn} category labels (${labelsSkipped} skipped as off-screen)`)
  }

  // Calculate centroids for each category
  calculateCategoryCentroids(values, categories) {
    const calcStartTime = performance.now()
    
    console.log(`🏷️ calculateCategoryCentroids called with ${categories?.length} categories`)
    
    if (!categories || !Array.isArray(categories)) {
      console.log('Categories is not a valid array, returning empty centroids')
      return {}
    }
    
    const centroids = {}
    
    // Initialize centroids
    categories.forEach(category => {
      centroids[category] = { x: 0, y: 0, count: 0 }
    })
    
    // ReGL PATH: Use currentCoordinates directly (no sprites in ReGL mode)
    if (this.rendererType === 'regl' && this.currentCoordinates && values) {
      console.log(`🏷️ Using ReGL path with currentCoordinates (${this.currentCoordinates.length} points)`)
      
      // Get visible cells for filtering
      const visibleSet = this.currentVisibleCells ? new Set(this.currentVisibleCells) : null
      let visiblePoints = 0
      let filteredPoints = 0
      
      // Iterate through all cells using their original indices
      for (let cellIndex = 0; cellIndex < this.currentCoordinates.length; cellIndex++) {
        // Check if this cell is visible (not filtered out)
        const isVisible = !visibleSet || visibleSet.has(cellIndex)
        
        if (isVisible) {
          const category = values[cellIndex]
          if (centroids[category]) {
            const coord = this.currentCoordinates[cellIndex]
            if (coord && coord.length >= 2) {
              centroids[category].x += coord[0]
              centroids[category].y += coord[1]
              centroids[category].count += 1
              visiblePoints++
            }
          }
        } else {
          filteredPoints++
        }
      }
      
      console.log(`🏷️ ReGL: ${visiblePoints} visible points, ${filteredPoints} filtered out`)
      
      // Calculate averages
      Object.keys(centroids).forEach(category => {
        if (centroids[category].count > 0) {
          centroids[category].x /= centroids[category].count
          centroids[category].y /= centroids[category].count
          console.log(`🏷️ ReGL centroid for "${category}": count=${centroids[category].count}, pos=(${centroids[category].x.toFixed(2)}, ${centroids[category].y.toFixed(2)})`)
        }
      })
      
      return centroids
    }
    
    // FAST PATH: Use pointSprites array if available (much faster for large datasets)
    if (this.pointSprites && this.pointSprites.length > 0) {
      console.log(`🏷️ Using fast path with pointSprites array (${this.pointSprites.length} sprites)`)
      
      for (let i = 0; i < this.pointSprites.length; i++) {
        const sprite = this.pointSprites[i]
        if (sprite && sprite.visible && sprite.cellId !== undefined) {
          const category = values[sprite.cellId]
          if (centroids[category]) {
            const coord = this.currentCoordinates[sprite.cellId]
            if (coord && coord.length >= 2) {
              centroids[category].x += coord[0]
              centroids[category].y += coord[1]
              centroids[category].count += 1
            }
          }
        }
      }
      
      // Calculate averages
      Object.keys(centroids).forEach(category => {
        if (centroids[category].count > 0) {
          centroids[category].x /= centroids[category].count
          centroids[category].y /= centroids[category].count
          console.log(`🏷️ Fast path centroid for ${category}: count=${centroids[category].count}, pos=(${centroids[category].x.toFixed(2)}, ${centroids[category].y.toFixed(2)})`)
        }
      })
      
      return centroids
    }

    // Calculate centroids from actual visible points in the scatter container
    if (this.scatterContainer && this.scatterContainer.children) {
        let validPoints = 0

        // Always look for points in the nested container structure
        const pointsToCheck = []
        
        this.scatterContainer.children.forEach((child, index) => {
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
    // Dispatch to Canvas 2D for ReGL mode
    if (this.rendererType === 'regl') {
      return this.renderContinuousColorLegendCanvas2D()
    }
    
    const startTime = performance.now()
    console.log('🎨 Rendering continuous color legend START')
    
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
      console.log('🎨 Not numeric metadata, skipping legend')
      return
    }

    // During panning, don't update legend
    if (this.isPanning) {
      console.log('🎨 Skipping legend updates during panning')
      return
    }

    console.log('🎨 Clearing existing legend...')
    // Clear existing legend
    this.categoryLabelsContainer.removeChildren()

    const { minX, maxX, minY, maxY } = this.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height

    console.log('🎨 Getting metadata values and effective range...')
    // Get metadata values and effective color range
    const values = this.currentMetadataVector.values
    const effectiveRange = this.getEffectiveColorRange()
    const minVal = effectiveRange.min
    const maxVal = effectiveRange.max
    console.log('🎨 Effective range:', { minVal, maxVal })

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
      const color = this.getColorFromGradient(normalizedValue)
      
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

    console.log('🎨 Adding legend to container...')
    // Add legend to the category labels container
    this.categoryLabelsContainer.addChild(legendContainer)
    this.categoryLabelsContainer.visible = true

    const totalTime = performance.now() - startTime
    console.log(`🎨 Continuous color legend rendered successfully in ${totalTime.toFixed(2)}ms`)
    console.log('🎨 renderContinuousColorLegend COMPLETE')
  }

  // Initialize overlay canvas event listeners for gradient legend interaction
  initializeGradientLegendListeners() {
    if (!this.overlayCanvas) {
      console.log('⚠️ Cannot initialize gradient legend listeners: overlayCanvas is null')
      return
    }
    
    console.log('🎨 Initializing gradient legend listeners')
    
    // Get the parent container to listen for events
    const canvasContainer = this.overlayCanvas.parentElement
    if (!canvasContainer) {
      console.log('⚠️ Cannot find canvas container')
      return
    }
    
    // Remove existing listeners if any
    if (this.gradientLegendClickListener) {
      canvasContainer.removeEventListener('click', this.gradientLegendClickListener)
    }
    if (this.gradientLegendMouseMoveListener) {
      canvasContainer.removeEventListener('mousemove', this.gradientLegendMouseMoveListener)
    }
    if (this.gradientLegendMouseLeaveListener) {
      canvasContainer.removeEventListener('mouseleave', this.gradientLegendMouseLeaveListener)
    }
    
    // Click listener - open modal when clicking on legend
    this.gradientLegendClickListener = (event) => {
      if (!this.gradientLegendBounds || !this.currentMetadataVector || this.currentMetadataVector.data_type !== 'NUMERIC') {
        return
      }
      
      const rect = this.overlayCanvas.getBoundingClientRect()
      const x = event.clientX - rect.left
      const y = event.clientY - rect.top
      
      const legend = this.gradientLegendBounds
      if (x >= legend.x && x <= legend.x + legend.width && 
          y >= legend.y && y <= legend.y + legend.height) {
        console.log('🎨 Gradient legend clicked!')
        this.openGradientEditorModal()
        event.stopPropagation()
      }
    }
    
    // Mousemove listener - detect hover and change cursor/color
    this.gradientLegendMouseMoveListener = (event) => {
      if (!this.gradientLegendBounds || !this.currentMetadataVector || this.currentMetadataVector.data_type !== 'NUMERIC') {
        return
      }
      
      const rect = this.overlayCanvas.getBoundingClientRect()
      const x = event.clientX - rect.left
      const y = event.clientY - rect.top
      
      const legend = this.gradientLegendBounds
      const isHovering = x >= legend.x && x <= legend.x + legend.width && 
                        y >= legend.y && y <= legend.y + legend.height
      
      // Update hover state if changed
      if (isHovering !== this.isHoveringGradientLegend) {
        this.isHoveringGradientLegend = isHovering
        this.overlayCanvas.style.cursor = isHovering ? 'pointer' : 'default'
        this.renderContinuousColorLegend()
      }
    }
    
    // Mouseleave listener - reset hover state
    this.gradientLegendMouseLeaveListener = () => {
      if (this.isHoveringGradientLegend) {
        this.isHoveringGradientLegend = false
        this.overlayCanvas.style.cursor = 'default'
        this.renderContinuousColorLegend()
      }
    }
    
    // Add listeners to the container, not the overlay canvas
    canvasContainer.addEventListener('click', this.gradientLegendClickListener)
    canvasContainer.addEventListener('mousemove', this.gradientLegendMouseMoveListener)
    canvasContainer.addEventListener('mouseleave', this.gradientLegendMouseLeaveListener)
    
    // Keep pointer events disabled on overlay to allow pan/zoom on main canvas
    this.overlayCanvas.style.pointerEvents = 'none'
    
    console.log('✅ Gradient legend listeners initialized successfully')
  }

  // Open gradient editor modal
  openGradientEditorModal() {
    const modal = document.getElementById('gradient-editor-modal')
    if (!modal) {
      console.error('❌ Gradient editor modal not found')
      return
    }

    console.log('🎨 Opening gradient editor modal')
    modal.style.display = 'flex'
    
    // Initialize gradient control points if not already set
    if (!this.gradientControlPoints && !this.customGradientControlPoints) {
      this.initializeDefaultGradient()
    }
    
    // Calculate and store min/max values for the current metadata
    if (this.currentMetadataVector && this.currentMetadataVector.values) {
      const values = this.currentMetadataVector.values
      this.gradientMinValue = this.safeMin(values)
      this.gradientMaxValue = this.safeMax(values)
      console.log('🎨 Gradient value range:', { min: this.gradientMinValue, max: this.gradientMaxValue })
    }
    
    // Render the modal gradient preview and control points
    this.renderModalGradientPreview()
    this.renderModalControlPointMarkers()
    this.renderControlPointsList()
  }

  // Close gradient editor modal
  closeGradientEditorModal() {
    const modal = document.getElementById('gradient-editor-modal')
    if (modal) {
      modal.style.display = 'none'
    }
    
    // Close control point editor if open
    this.closeControlPointEditor()
  }

  // Initialize default gradient based on value distribution
  initializeDefaultGradient() {
    if (!this.currentMetadataVector || this.currentMetadataVector.data_type !== 'NUMERIC') {
      return
    }

    const values = this.currentMetadataVector.values
    this.gradientControlPoints = this.determineGradientForValues(values)
  }
  
  // Determine appropriate gradient based on value distribution
  determineGradientForValues(values) {
    // Calculate min and max values
    let minVal = Infinity
    let maxVal = -Infinity
    
    for (let i = 0; i < values.length; i++) {
      const val = values[i]
      if (val < minVal) minVal = val
      if (val > maxVal) maxVal = val
    }
    
    // Store min/max for value conversion
    this.gradientMinValue = minVal
    this.gradientMaxValue = maxVal
    
    // Helper to convert actual value to position
    const valueToPosition = (value) => {
      const range = maxVal - minVal
      if (range === 0) return 0
      return (value - minVal) / range
    }
    
    // Determine gradient type based on value range
    const spansZero = minVal < 0 && maxVal > 0
    const allNegative = maxVal <= 0
    const allPositive = minVal >= 0
    
    console.log('🎨 Determining gradient for values:', { minVal, maxVal, spansZero, allNegative, allPositive })
    
    if (spansZero) {
      // Values span from negative to positive: use diverging gradient (dark blue -> light grey at 0 -> dark red)
      const zeroPosition = valueToPosition(0)
      console.log('🎨 Diverging gradient: zero positioned at', zeroPosition)
      return [
        { position: 0, color: 0x1e3a8a },           // Dark blue (most negative)
        { position: zeroPosition, color: 0xe5e7eb }, // Light grey (at zero)
        { position: 1, color: 0x991b1b }            // Dark red (most positive)
      ]
    } else if (allNegative) {
      // All negative values: dark blue to light grey
      console.log('🎨 All negative gradient: dark blue -> light grey')
      return [
        { position: 0, color: 0x1e3a8a },   // Dark blue (most negative)
        { position: 1, color: 0xe5e7eb }    // Light grey (at zero/least negative)
      ]
    } else if (allPositive) {
      // All positive values: light grey to dark red
      console.log('🎨 All positive gradient: light grey -> dark red')
      // If minimum is exactly 0, position light grey at 0, otherwise at minimum
      const startPosition = minVal === 0 ? 0 : valueToPosition(Math.max(0, minVal))
      return [
        { position: 0, color: 0xe5e7eb },   // Light grey (at zero or minimum)
        { position: 1, color: 0x991b1b }    // Dark red (most positive)
      ]
    } else {
      // Fallback: simple gradient
      return [
        { position: 0, color: 0xdbeafe },   // Light blue
        { position: 1, color: 0x1e40af }    // Dark blue
      ]
    }
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
    const controlPoints = this.customGradientControlPoints || this.gradientControlPoints
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
    const controlPoints = this.customGradientControlPoints || this.gradientControlPoints
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
  
  // Handle clicking on gradient bar to add new control point
  gradientBarClicked(event) {
    const canvas = event.target
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const position = Math.max(0, Math.min(1, x / rect.width))
    
    console.log('🎨 Adding control point at position:', position)
    
    // Get the color at this position by interpolating existing points
    const color = this.getColorFromGradient(position)
    
    // Create custom gradient if it doesn't exist
    if (!this.customGradientControlPoints) {
      this.customGradientControlPoints = this.gradientControlPoints ? [...this.gradientControlPoints] : []
    }
    
    // Add new control point
    this.customGradientControlPoints.push({ position, color })
    
    // Sort and update display
    this.sortControlPoints()
    this.renderModalGradientPreview()
    this.renderModalControlPointMarkers()
    this.renderControlPointsList()
    
    // Apply to visualization
    this.reapplyColorsWithNewGradient()
  }
  
  // Sort control points by position
  sortControlPoints() {
    if (this.customGradientControlPoints) {
      this.customGradientControlPoints.sort((a, b) => a.position - b.position)
    } else if (this.gradientControlPoints) {
      this.gradientControlPoints.sort((a, b) => a.position - b.position)
    }
    
    this.renderModalGradientPreview()
    this.renderModalControlPointMarkers()
  }
  
  // Select a control point for editing
  selectControlPoint(index) {
    this.selectedControlPointIndex = index
    
    const controlPoints = this.customGradientControlPoints || this.gradientControlPoints
    if (!controlPoints || index < 0 || index >= controlPoints.length) return
    
    const point = controlPoints[index]
    
    // Show editor panel
    const editor = document.getElementById('gradient-control-point-editor')
    if (editor) {
      editor.style.display = 'block'
    }
    
    // Populate editor fields
    const positionInput = document.getElementById('gradient-control-point-position')
    const colorInput = document.getElementById('gradient-control-point-color')
    
    if (positionInput) {
      // Convert position (0-1) to actual value
      const actualValue = this.positionToActualValue(point.position)
      positionInput.value = actualValue.toFixed(3)
      
      // Update input min/max attributes to match data range
      if (this.gradientMinValue !== undefined && this.gradientMaxValue !== undefined) {
        positionInput.min = this.gradientMinValue
        positionInput.max = this.gradientMaxValue
        positionInput.step = (this.gradientMaxValue - this.gradientMinValue) / 1000
      }
    }
    
    if (colorInput) {
      colorInput.value = `#${point.color.toString(16).padStart(6, '0')}`
    }
    
    // Update list highlighting
    this.renderControlPointsList()
    
    console.log(`🎨 Selected control point ${index}:`, point)
  }
  
  // Update position of selected control point
  updateControlPointPosition(event) {
    if (this.selectedControlPointIndex === undefined) return
    
    const actualValue = parseFloat(event.target.value)
    if (isNaN(actualValue)) return
    
    // Validate against data range
    if (this.gradientMinValue !== undefined && this.gradientMaxValue !== undefined) {
      if (actualValue < this.gradientMinValue || actualValue > this.gradientMaxValue) return
    }
    
    // Convert actual value to position (0-1)
    const position = this.actualValueToPosition(actualValue)
    
    // Create custom gradient if modifying auto gradient
    if (!this.customGradientControlPoints) {
      this.customGradientControlPoints = this.gradientControlPoints ? [...this.gradientControlPoints] : []
    }
    
    const controlPoints = this.customGradientControlPoints
    if (controlPoints && this.selectedControlPointIndex < controlPoints.length) {
      controlPoints[this.selectedControlPointIndex].position = position
      
      this.sortControlPoints()
      this.reapplyColorsWithNewGradient()
    }
  }
  
  // Convert position (0-1) to actual data value
  positionToActualValue(position) {
    if (this.gradientMinValue === undefined || this.gradientMaxValue === undefined) {
      return position
    }
    return this.gradientMinValue + (position * (this.gradientMaxValue - this.gradientMinValue))
  }
  
  // Convert actual data value to position (0-1)
  actualValueToPosition(actualValue) {
    if (this.gradientMinValue === undefined || this.gradientMaxValue === undefined) {
      return actualValue
    }
    const range = this.gradientMaxValue - this.gradientMinValue
    if (range === 0) return 0
    return (actualValue - this.gradientMinValue) / range
  }
  
  // Get color from gradient control points by interpolating
  getColorFromGradient(normalizedValue) {
    // Handle invalid values
    if (normalizedValue === undefined || normalizedValue === null || isNaN(normalizedValue)) {
      return 0x3b82f6 // Default blue
    }
    
    // Use gradient control points if available
    const controlPoints = this.customGradientControlPoints || this.gradientControlPoints
    
    // Fallback to old color scheme if no gradient defined
    if (!controlPoints || controlPoints.length === 0) {
      return this.valueToColor(normalizedValue)
    }
    
    // Clamp value to 0-1 range
    const clamped = Math.max(0, Math.min(1, normalizedValue))
    
    // Sort control points by position
    const sorted = [...controlPoints].sort((a, b) => a.position - b.position)
    
    // Ensure we have valid control points
    if (sorted.length === 0) {
      return this.valueToColor(normalizedValue)
    }
    
    // Single control point - return its color
    if (sorted.length === 1) {
      return sorted[0].color
    }
    
    // Find the two control points to interpolate between
    let beforePoint = sorted[0]
    let afterPoint = sorted[sorted.length - 1]
    
    for (let i = 0; i < sorted.length - 1; i++) {
      if (clamped >= sorted[i].position && clamped <= sorted[i + 1].position) {
        beforePoint = sorted[i]
        afterPoint = sorted[i + 1]
        break
      }
    }
    
    // Handle edge cases
    if (clamped <= sorted[0].position) {
      return sorted[0].color
    }
    if (clamped >= sorted[sorted.length - 1].position) {
      return sorted[sorted.length - 1].color
    }
    
    // Interpolate between the two colors
    const range = afterPoint.position - beforePoint.position
    if (range === 0) return beforePoint.color
    
    const t = (clamped - beforePoint.position) / range
    
    // Extract RGB components
    const r1 = (beforePoint.color >> 16) & 0xff
    const g1 = (beforePoint.color >> 8) & 0xff
    const b1 = beforePoint.color & 0xff
    
    const r2 = (afterPoint.color >> 16) & 0xff
    const g2 = (afterPoint.color >> 8) & 0xff
    const b2 = afterPoint.color & 0xff
    
    // Linear interpolation
    const r = Math.round(r1 + (r2 - r1) * t)
    const g = Math.round(g1 + (g2 - g1) * t)
    const b = Math.round(b1 + (b2 - b1) * t)
    
    // Combine back into single color
    return (r << 16) | (g << 8) | b
  }
  
  // Update color of selected control point
  updateControlPointColor(event) {
    if (this.selectedControlPointIndex === undefined) return
    
    const hexColor = event.target.value
    const color = parseInt(hexColor.substring(1), 16)
    
    // Create custom gradient if modifying auto gradient
    if (!this.customGradientControlPoints) {
      this.customGradientControlPoints = this.gradientControlPoints ? [...this.gradientControlPoints] : []
    }
    
    const controlPoints = this.customGradientControlPoints
    if (controlPoints && this.selectedControlPointIndex < controlPoints.length) {
      controlPoints[this.selectedControlPointIndex].color = color
      
      this.renderModalGradientPreview()
      this.renderModalControlPointMarkers()
      this.renderControlPointsList()
      this.reapplyColorsWithNewGradient()
    }
  }
  
  // Remove selected control point
  removeControlPoint() {
    if (this.selectedControlPointIndex === undefined) return
    
    // Create custom gradient if modifying auto gradient
    if (!this.customGradientControlPoints) {
      this.customGradientControlPoints = this.gradientControlPoints ? [...this.gradientControlPoints] : []
    }
    
    const controlPoints = this.customGradientControlPoints
    if (controlPoints && this.selectedControlPointIndex < controlPoints.length) {
      // Don't allow removing if only 2 points left
      if (controlPoints.length <= 2) {
        alert('A gradient must have at least 2 control points.')
        return
      }
      
      controlPoints.splice(this.selectedControlPointIndex, 1)
      this.selectedControlPointIndex = undefined
      
      this.closeControlPointEditor()
      this.renderModalGradientPreview()
      this.renderModalControlPointMarkers()
      this.renderControlPointsList()
      this.reapplyColorsWithNewGradient()
    }
  }
  
  // Close control point editor
  closeControlPointEditor() {
    const editor = document.getElementById('gradient-control-point-editor')
    if (editor) {
      editor.style.display = 'none'
    }
    this.selectedControlPointIndex = undefined
    
    // Update the modal display
    this.renderModalGradientPreview()
    this.renderModalControlPointMarkers()
    this.renderControlPointsList()
    
    // Apply changes to the main visualization
    this.reapplyColorsWithNewGradient()
  }
  
  // Reset gradient to default
  resetGradient() {
    console.log('🎨 Resetting gradient to default')
    this.customGradientControlPoints = null
    this.selectedControlPointIndex = undefined
    
    // Reinitialize default gradient
    this.initializeDefaultGradient()
    
    this.closeControlPointEditor()
    this.renderModalGradientPreview()
    this.renderModalControlPointMarkers()
    this.renderControlPointsList()
    this.reapplyColorsWithNewGradient()
  }
  
  // Reapply colors with new gradient
  reapplyColorsWithNewGradient() {
    console.log('🎨 Reapplying colors with new gradient')
    console.log('🎨 Custom gradient points:', this.customGradientControlPoints)
    console.log('🎨 Auto gradient points:', this.gradientControlPoints)
    
    // Update the legend in the plot
    if (this.currentMetadataVector?.data_type === 'NUMERIC') {
      this.renderContinuousColorLegend()
      
      // Recolor all points
      if (this.rendererType === 'regl') {
        console.log('🎨 Recoloring points in ReGL mode')
        this.renderPointsWithCurrentColoringReGL()
      } else {
        console.log('🎨 Recoloring points in PixiJS mode')
        this.renderPointsWithCurrentColoring()
      }
    } else {
      console.log('⚠️ Cannot reapply colors: no numeric metadata vector')
    }
  }

  // Render continuous color legend using Canvas 2D (ReGL mode)
  renderContinuousColorLegendCanvas2D() {
    const startTime = performance.now()
    console.log('🎨 [Canvas2D] Rendering continuous color legend START')
    
    if (!this.overlayCtx || !this.currentBounds || !this.currentMetadataVector || !this.currentCoordinates) {
      console.log('🎨 [Canvas2D] Missing required components for continuous legend')
      return
    }

    // Only render legend for continuous metadata
    if (this.currentMetadataVector.data_type !== 'NUMERIC') {
      console.log('🎨 [Canvas2D] Not numeric metadata, skipping legend')
      return
    }

    // During panning, don't update legend
    if (this.isPanning) {
      console.log('🎨 [Canvas2D] Skipping legend updates during panning')
      return
    }

    // Redraw the entire overlay (grid, axes, legend) to ensure the old legend is cleared
    // This is necessary when the color range is adapted
    console.log('🎨 [Canvas2D] Redrawing full overlay (grid + axes + legend)')
    this.renderGrid() // Clears the canvas
    this.renderAxes() // Draw axes

    const ctx = this.overlayCtx
    const width = this.overlayCanvas.width
    const height = this.overlayCanvas.height

    // Get metadata values and effective color range
    const values = this.currentMetadataVector.values
    const effectiveRange = this.getEffectiveColorRange()
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
    this.gradientLegendBounds = {
      x: bgX,
      y: bgY,
      width: bgWidth,
      height: bgHeight
    }
    
    // Draw semi-transparent background (changes color on hover)
    ctx.save()
    if (this.isHoveringGradientLegend) {
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
    ctx.fillText(this.currentMetadataVector.name, legendX, legendY - 5)
    ctx.restore()

    // Draw color gradient bar
    const numSteps = 100
    
    for (let i = 0; i < numSteps; i++) {
      const normalizedValue = i / (numSteps - 1)
      const color = this.getColorFromGradient(normalizedValue)
      
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


  // Update all range slider counts to reflect combined filtering
  updateAllRangeSliderCounts() {
    // Find all range slider controllers and trigger their count updates
    const rangeSliderElements = document.querySelectorAll('[data-controller~="range-slider"]')
    rangeSliderElements.forEach(element => {
      // Get the Stimulus controller instance
      const controller = this.application?.getControllerForElementAndIdentifier(element, 'range-slider')
      if (controller && typeof controller.updateSelectedCellsCount === 'function') {
        controller.updateSelectedCellsCount()
      }
    })
  }

  // Update sidebar category counts with visual indicators for ALL categorical metadata
  updateSidebarCategoryCounts() {
    // Update counts for ALL categorical metadata, not just the currently colored one
    // This is important when continuous metadata is used for coloring
    
    // Find all category checkboxes
    const allCategoryCheckboxes = document.querySelectorAll('.category-checkbox')
    
    // Convert currentVisibleCells to Set once for O(1) lookups
    const visibleSet = this.currentVisibleCells ? new Set(this.currentVisibleCells) : null
    
    allCategoryCheckboxes.forEach(checkbox => {
      const metadataId = checkbox.dataset.metadataId
      const category = checkbox.dataset.category
      
      // Get the metadata vector for this metadata ID (only if already loaded in memory)
      const metadataVector = this.loadedMetadataVectors[metadataId]
      if (!metadataVector || !metadataVector.values) return
      
      // Find the count span - it's the second span in the parent container
      const parentContainer = checkbox.parentElement.parentElement
      const spans = parentContainer.querySelectorAll('span')
      const countSpan = spans[spans.length - 1] // Last span is the count
      
      if (countSpan) {
        // Count total and visible cells for this category
        let totalCount = 0
        let visibleCount = 0
        
        for (let i = 0; i < metadataVector.values.length; i++) {
          if (metadataVector.values[i] === category) {
            totalCount++
            // O(1) lookup with Set instead of array iteration
            if (!visibleSet || visibleSet.has(i)) {
              visibleCount++
            }
          }
        }
        
        // Update the count display
        countSpan.textContent = visibleCount.toLocaleString()
        
        // Add visual indicators
        if (totalCount > visibleCount) {
          // Some cells are filtered out - show in red
          countSpan.style.color = '#dc2626'
          countSpan.style.fontWeight = '600'
          
          // Add hover tooltip
          const percentage = ((visibleCount / totalCount) * 100).toFixed(1)
          countSpan.title = `${visibleCount.toLocaleString()} of ${totalCount.toLocaleString()} cells (${percentage}% visible after filtering)`
        } else {
          // No filtering - normal appearance
          countSpan.style.color = '#6b7280'
          countSpan.style.fontWeight = '500'
          countSpan.title = `${totalCount.toLocaleString()} cells (100% visible)`
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
        // Skip if drawing lasso (shouldn't be called anyway due to .off())
        if (this.isDrawingLasso) {
          console.warn('⚠️ PIXI stage handler called during lasso! This should not happen.')
          return
        }
        
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
    if (!this.lassoCanvasCtx || this.lassoPoints.length < 2) return
    
    // Draw on HTML canvas overlay (bypasses PIXI entirely)
    const ctx = this.lassoCanvasCtx
    
    // Clear canvas
    ctx.clearRect(0, 0, this.lassoCanvas.width, this.lassoCanvas.height)
    
    // Draw lasso path
    ctx.strokeStyle = '#3b82f6'
    ctx.fillStyle = 'rgba(59, 130, 246, 0.1)'
    ctx.lineWidth = 2
    
    ctx.beginPath()
    ctx.moveTo(this.lassoPoints[0].x, this.lassoPoints[0].y)
    for (let i = 1; i < this.lassoPoints.length; i++) {
      ctx.lineTo(this.lassoPoints[i].x, this.lassoPoints[i].y)
    }
    ctx.stroke()
    ctx.fill()
  }

  selectPointsInLasso() {
    if (!this.currentCoordinates || this.lassoPoints.length < 3) return
    
    console.log(`⏱️ [LASSO] Checking ${this.currentCoordinates.length.toLocaleString()} points`)
    const selectionStart = performance.now()
    
    const selectedIndices = []
    
    // OPTIMIZED: Calculate lasso bounding box for fast rejection
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (const p of this.lassoPoints) {
      if (p.x < minX) minX = p.x
      if (p.x > maxX) maxX = p.x
      if (p.y < minY) minY = p.y
      if (p.y > maxY) maxY = p.y
    }
    
    console.log(`⏱️ [LASSO] Bounding box: [${minX.toFixed(0)}, ${maxX.toFixed(0)}] x [${minY.toFixed(0)}, ${maxY.toFixed(0)}]`)
    
    // ReGL PATH: Check normalized coordinates against lasso polygon
    if (this.rendererType === 'regl' && this.currentBounds) {
      console.log('⏱️ [LASSO] Using ReGL path - checking normalized coordinates')
      
      let bboxRejected = 0
      let polygonChecked = 0
      
      for (let i = 0; i < this.currentCoordinates.length; i++) {
        const [dataX, dataY] = this.currentCoordinates[i]
        
        // Convert data coordinates to screen coordinates
        const x = this.normalizeX(dataX, this.currentBounds)
        const y = this.normalizeY(dataY, this.currentBounds)
        
        // Quick bounding box rejection
        if (x < minX || x > maxX || y < minY || y > maxY) {
          bboxRejected++
          continue
        }
        
        // Expensive polygon test only for points in bounding box
        polygonChecked++
        if (this.isPointInPolygon(x, y, this.lassoPoints)) {
          selectedIndices.push(i)
        }
      }
      
      console.log(`⚡ [ReGL LASSO] BBox rejected: ${bboxRejected.toLocaleString()}, Polygon tested: ${polygonChecked.toLocaleString()}`)
      
    } else if (this.pointSprites && this.pointSprites.length > 0) {
      // OPTIMIZED: Use pointSprites array directly (much faster!)
      let bboxRejected = 0
      let polygonChecked = 0
      
      for (let i = 0; i < this.pointSprites.length; i++) {
        const sprite = this.pointSprites[i]
        if (!sprite || sprite.destroyed || !sprite.visible) continue
        
        const x = sprite.x
        const y = sprite.y
        
        // Quick bounding box rejection (90%+ of points skip expensive polygon test)
        if (x < minX || x > maxX || y < minY || y > maxY) {
          bboxRejected++
          continue
        }
        
        // Expensive polygon test only for points in bounding box
        polygonChecked++
        if (this.isPointInPolygon(x, y, this.lassoPoints)) {
          selectedIndices.push(i)
        }
      }
      
      console.log(`⏱️ [LASSO] BBox rejected: ${bboxRejected.toLocaleString()}, Polygon tested: ${polygonChecked.toLocaleString()}`)
    } else {
      // Fallback to container iteration if sprites not available
      console.log('⚠️ Using fallback container iteration (slower)')
      this.scatterContainer.children.forEach((child) => {
        if (child.isPoint && child.cellId !== undefined) {
          if (this.isPointInPolygon(child.x, child.y, this.lassoPoints)) {
          selectedIndices.push(child.cellId)
        }
      }
    })
    
      if (this.animatedContainer) {
        this.animatedContainer.children.forEach((child) => {
        if (child.isPoint && child.cellId !== undefined) {
            if (this.isPointInPolygon(child.x, child.y, this.lassoPoints)) {
            selectedIndices.push(child.cellId)
          }
        }
      })
      }
    }
    
    const selectionTime = performance.now() - selectionStart
    console.log(`⏱️ [LASSO] Selected ${selectedIndices.length.toLocaleString()} cells in ${selectionTime.toFixed(2)}ms`)
    
    // Add to selected cells set
    selectedIndices.forEach(index => {
      this.selectedCells.add(index)
    })
    
    // Store the current metadata state before deactivating (for restore on cancel/save)
    this.storeMetadataStateBeforeSelection()
    
    // Deactivate the coloring button (turn blue palette button to grey)
    this.resetAllWaterDropButtons()
    this.removeAllCategoryColors()
    this.clearMetadataColoring()
    
    // Update selection count display
    this.updateSelectionCount()
    
    // Update colors of selected points without re-rendering (preserves pan/zoom state)
    this.updateSelectedPointColors()
  }
  // Update colors of selected points without re-rendering (preserves pan/zoom state)
  updateSelectedPointColors() {
    const numPoints = this.rendererType === 'regl' ? this.numPoints : (this.pointSprites?.length || 0)
    console.log(`⏱️ [PERF] updateSelectedPointColors - ${this.selectedCells.size} selected out of ${numPoints} total`)
    const updateStart = performance.now()
    
    // ReGL PATH: Update color buffer
    if (this.rendererType === 'regl') {
      if (!this.reglRenderer || !this.numPoints) {
        console.log('⚠️ No ReGL renderer or points available for color update')
        return
      }
      
      const hasSelections = this.selectedCells.size > 0
      const colorMap = new Map()
      
      if (hasSelections) {
        console.log(`⚡ [ReGL] Updating colors for ${this.selectedCells.size} selected cells`)
        // Set selected cells to red, unselected to faded original color
        // Use displayOrder to correctly map draw positions to cell indices
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          if (this.selectedCells.has(cellIndex)) {
            colorMap.set(drawPos, 0xff0000) // Red
          } else {
            // Keep original color but with reduced alpha (we'll handle this in the shader if needed)
            const originalColor = this.originalPointColors.get(cellIndex) || 0x3b82f6
            colorMap.set(drawPos, originalColor)
          }
        }
      } else {
        console.log(`⚡ [ReGL] Restoring original colors for all ${this.numPoints} cells`)
        // Restore original colors
        // Use displayOrder to correctly map draw positions to cell indices
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const originalColor = this.originalPointColors.get(cellIndex) || 0x3b82f6
          colorMap.set(drawPos, originalColor)
        }
      }
      
      this.reglRenderer.updateColors(colorMap)
      this.reglRenderer.render()
      
      this.previouslySelectedCells = new Set(this.selectedCells)
      const updateTime = performance.now() - updateStart
      console.log(`⚡ [ReGL] Color update completed in ${updateTime.toFixed(2)}ms`)
      return
    }
    
    // PixiJS PATH (original)
    if (!this.pointSprites || this.pointSprites.length === 0) {
      console.log('⚠️ No sprites available for color update')
      return
    }
    
    const hasSelections = this.selectedCells.size > 0
    const wasEmpty = !this.previouslySelectedCells || this.previouslySelectedCells.size === 0
    const isFirstSelection = wasEmpty && hasSelections
    
    console.log(`⏱️ [PERF] isFirstSelection=${isFirstSelection}, hasSelections=${hasSelections}`)
    
    if (isFirstSelection) {
      // First selection: need to update ALL sprites (fade unselected + highlight selected)
      console.log(`⏱️ [PERF] First selection - updating all ${this.pointSprites.length} sprites`)
      const allUpdateStart = performance.now()
      
      for (let i = 0; i < this.pointSprites.length; i++) {
        const sprite = this.pointSprites[i]
        if (!sprite || sprite.destroyed) continue
        
        if (this.selectedCells.has(i)) {
          sprite.tint = 0xff0000
          sprite.alpha = 1.0
        } else {
          sprite.alpha = 0.3 // Fade unselected (keep existing color)
        }
      }
      
      const allUpdateTime = performance.now() - allUpdateStart
      console.log(`  Updated all sprites in ${allUpdateTime.toFixed(2)}ms (${Math.round(this.pointSprites.length / allUpdateTime * 1000).toLocaleString()} sprites/sec)`)
    } else if (hasSelections) {
      // Adding to existing selection: only update newly selected cells
      console.log(`⏱️ [PERF] Incremental selection - updating only ${this.selectedCells.size} selected cells`)
      const incrementalStart = performance.now()
      
      for (const cellId of this.selectedCells) {
        const sprite = this.pointSprites[cellId]
        if (sprite && !sprite.destroyed) {
          sprite.tint = 0xff0000
          sprite.alpha = 1.0
        }
      }
      
      const incrementalTime = performance.now() - incrementalStart
      console.log(`  Updated ${this.selectedCells.size} sprites in ${incrementalTime.toFixed(2)}ms`)
    } else {
      // Clearing selection: restore all to normal
      console.log(`⏱️ [PERF] Clearing selection - restoring all sprites`)
      const clearStart = performance.now()
      
      for (let i = 0; i < this.pointSprites.length; i++) {
        const sprite = this.pointSprites[i]
        if (!sprite || sprite.destroyed) continue
        
        const originalColor = this.originalPointColors.get(i) || 0x3b82f6
        sprite.tint = originalColor
        sprite.alpha = 1.0
      }
      
      const clearTime = performance.now() - clearStart
      console.log(`  Restored all sprites in ${clearTime.toFixed(2)}ms`)
    }
    
    // Store current selection for next comparison
    this.previouslySelectedCells = new Set(this.selectedCells)
    
    const updateTime = performance.now() - updateStart
    console.log(`⏱️ [PERF] Color update completed in ${updateTime.toFixed(2)}ms`)
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
    // Clear HTML canvas overlay
    if (this.lassoCanvasCtx) {
      this.lassoCanvasCtx.clearRect(0, 0, this.lassoCanvas.width, this.lassoCanvas.height)
    }
    
    this.lassoPoints = []
    this.isDrawingLasso = false
    
    // Re-enable PIXI event system (but sprite interactivity stays OFF - still in lasso mode)
    if (this.pixiApp?.renderer?.events) {
      this.pixiApp.renderer.events.setTargetElement(this.pixiApp.view)
    }
    if (this.globalDragHandlers && this.pixiApp?.stage) {
      this.pixiApp.stage.on('pointermove', this.globalDragHandlers.move)
    }
    // Note: sprite interactivity is NOT re-enabled here - it stays disabled until user switches modes
    
    // Clean up Firefox polling if active
    if (this.firefoxPollInterval) {
      clearInterval(this.firefoxPollInterval)
      this.firefoxPollInterval = null
    }
    
    if (this.firefoxMouseHandler) {
      document.removeEventListener('pointermove', this.firefoxMouseHandler, { capture: true })
      this.firefoxMouseHandler = null
    }
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
    
    // Store the current metadata state before deactivating (for restore on cancel/save)
    this.storeMetadataStateBeforeSelection()
    
    // Deactivate the coloring button (turn blue palette button to grey)
    this.resetAllWaterDropButtons()
    this.removeAllCategoryColors()
    this.clearMetadataColoring()
    
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
    
    // Add event listener for category order dropdown and set current value
    const categoryOrderSelect = document.getElementById('category-order-select')
    if (categoryOrderSelect) {
      // Set the selected option based on current preference
      categoryOrderSelect.value = this.categoryOrder
      
      // Add event listener
      categoryOrderSelect.addEventListener('change', (e) => {
        console.log('📊 Category order changed:', e.target.value)
        this.changeCategoryOrder(e)
      })
    }
    
    // Add event listener for numerical order dropdown and set current value
    const numericalOrderSelect = document.getElementById('numerical-order-select')
    if (numericalOrderSelect) {
      // Set the selected option based on current preference
      numericalOrderSelect.value = this.numericalOrder
      
      // Add event listener
      numericalOrderSelect.addEventListener('change', (e) => {
        console.log('📊 Numerical order changed:', e.target.value)
        this.changeNumericalOrder(e)
      })
    }
    
    // Add event listener for auto-preload checkbox
    const autoPreloadCheckbox = document.getElementById('auto-preload-checkbox')
    if (autoPreloadCheckbox) {
      // Set checkbox based on current preference
      autoPreloadCheckbox.checked = this.autoPreloadMetadata
      
      // Add event listener
      autoPreloadCheckbox.addEventListener('change', (e) => {
        this.autoPreloadMetadata = e.target.checked
        console.log('📊 Auto-preload metadata:', this.autoPreloadMetadata)
        
        // If enabled, start preloading now
        if (this.autoPreloadMetadata) {
          console.log('🚀 Starting automatic preload after checkbox enable...')
          this.preloadAllMetadata().catch(error => {
            console.log('Background metadata preload encountered an error:', error)
          })
        }
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
      
      // Get the actual current position of the window using computed position
      const rect = settingsWindow.getBoundingClientRect()
      startLeft = rect.left
      startTop = rect.top
      
      // Set explicit positioning to prevent jump
      settingsWindow.style.left = startLeft + 'px'
      settingsWindow.style.top = startTop + 'px'
      
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
    console.log(`⏱️ [PERF] Updating point size to ${newSize}`)
    const updateStart = performance.now()
    
    // ReGL PATH: Update point size uniform
    if (this.rendererType === 'regl') {
      if (this.reglRenderer) {
        this.reglRenderer.setPointSize(newSize)
        this.reglRenderer.render()
        console.log(`⚡ [ReGL] Updated point size to ${newSize} in ${(performance.now() - updateStart).toFixed(2)}ms`)
      }
      return
    }
    
    // PixiJS PATH (original)
    if (!this.pointSprites || this.pointSprites.length === 0) {
      console.log('No sprites found, will apply on next render')
      return
    }
    
    // Recreate texture at new size for crisp rendering
    if (this.pointTexture) {
      this.pointTexture.destroy(true)
    }
    this.pointTexture = this.createPointTexture(newSize)
    this.lastPointSize = newSize
    
    // Update all sprites to use new texture
    let updatedCount = 0
    for (let i = 0; i < this.pointSprites.length; i++) {
      const sprite = this.pointSprites[i]
      if (sprite && sprite.isPoint && !sprite.destroyed) {
        sprite.texture = this.pointTexture
        // Reset scale to 1.0 since texture is at correct size
        sprite.scale.set(1.0)
          updatedCount++
        }
    }
    
    const updateTime = performance.now() - updateStart
    console.log(`⏱️ [PERF] Updated ${updatedCount.toLocaleString()} sprites to size ${newSize} in ${updateTime.toFixed(2)}ms`)
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
      
      // Re-render axes and grid with new bounds
      this.renderAxes()
      this.renderGrid()
      
      // Re-render category labels after axes toggle (bounds may have changed)
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
    if (!checkbox) {
      console.log('🏷️ toggleCategories: checkbox not found!')
      return
    }
    
    console.log(`🏷️ Toggling categories: ${checkbox.checked}`)
    console.log(`🏷️ Current metadata:`, this.currentMetadataVector ? `${this.currentMetadataVector.name} (${this.currentMetadataVector.data_type})` : 'none')
    
    // Toggle category labels on the plot
    if (this.rendererType === 'regl') {
      // ReGL mode: Labels are drawn on Canvas2D overlay
      console.log('🏷️ [ReGL] Toggling category labels on Canvas2D overlay')
      if (checkbox.checked) {
        console.log('🏷️ [ReGL] Re-rendering category labels...')
        // Redraw overlay with labels
        this.renderGrid()
        this.renderAxes()
        this.renderCategoryLabels()
      } else {
        console.log('🏷️ [ReGL] Clearing category labels')
        // Redraw overlay without labels (renderCategoryLabels will check checkbox and skip)
        this.renderGrid()
        this.renderAxes()
        this.renderCategoryLabels()
      }
    } else if (this.categoryLabelsContainer) {
      // PixiJS mode: Labels are in a PixiJS container
      this.categoryLabelsContainer.visible = checkbox.checked
      console.log(`🏷️ Category labels container visible: ${this.categoryLabelsContainer.visible}`)
      
      // If turning on, make sure labels are rendered
      if (checkbox.checked) {
        console.log('🏷️ Re-rendering category labels...')
        this.renderCategoryLabels()
      } else {
        console.log('🏷️ Hiding category labels')
      }
    } else {
      console.log('🏷️ No categoryLabelsContainer available')
    }
    
    // Find the categories container in the right panel
    const categoriesContainer = document.querySelector('.metadata-categories')
    if (categoriesContainer) {
      categoriesContainer.style.display = checkbox.checked ? 'block' : 'none'
      console.log(`🏷️ Metadata categories panel: ${checkbox.checked ? 'shown' : 'hidden'}`)
    }
    
    console.log('🏷️ Categories toggle complete!')
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

  changeCategoryOrder(event) {
    const newOrder = event.target.value
    console.log(`📊 [CATEGORY ORDER] Changing from '${this.categoryOrder}' to '${newOrder}'`)
    
    if (newOrder === this.categoryOrder) {
      console.log('📊 [CATEGORY ORDER] Order unchanged, skipping update')
      return
    }
    
    this.categoryOrder = newOrder
    
    // Reset the flag so reordering will happen on next render
    this._lastCategoryOrderApplied = null
    
    // Update ALL unfolded categorical metadata panels in the left sidebar
    this.updateAllCategoryDisplayOrders()
    
    // If we have discrete metadata currently displayed, re-render the plot
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'DISCRETE') {
      console.log(`📊 [CATEGORY ORDER] ✅ Discrete metadata active - applying new order`)
      
      // IMPORTANT: Don't recreate color map - keep existing color assignments!
      // The color map should remain stable regardless of sort order
      // We only need to update the z-order (PixiJS) or buffer order (ReGL)
      
      if (this.rendererType === 'regl') {
        // ReGL: Reorder points in buffer for painter's algorithm
        // This function will also redraw the overlay (grid, axes, labels)
        this.reorderPointsForCategoryDisplay()
      } else {
        // PixiJS: Update sprite z-index
      this.renderPointsWithCurrentColoring()
      
      // Re-render category labels
      this.renderCategoryLabels()
      }
      
      console.log('📊 [CATEGORY ORDER] Complete!')
    } else {
      console.log('📊 [CATEGORY ORDER] No discrete metadata active, order preference saved for next use')
    }
  }
  
  // ReGL: Reorder display order based on category (painter's algorithm)
  // Uses displayOrder array - does NOT modify original data
  reorderPointsForCategoryDisplay() {
    if (!this.reglRenderer || !this.currentCoordinates || !this.currentMetadataVector || !this.displayOrder) {
      console.log('⚠️ [ReGL] Cannot reorder - missing data')
      return
    }
    
    console.log('📊 [ReGL] Reordering display order for category...')
    const startTime = performance.now()
    
    const values = this.currentMetadataVector.values
    
    // Calculate category frequencies from CURRENT display order
    const categoryFrequencies = {}
    for (let i = 0; i < this.displayOrder.length; i++) {
      const cellIndex = this.displayOrder[i]
      const category = values[cellIndex]
      categoryFrequencies[category] = (categoryFrequencies[category] || 0) + 1
    }
    
    // Sort categories by frequency
    const sortedCategories = Object.keys(categoryFrequencies).sort((a, b) => {
      const freqA = categoryFrequencies[a]
      const freqB = categoryFrequencies[b]
      
      if (this.categoryOrder === 'smallest-first') {
        return freqA - freqB // Ascending (smallest first = background)
      } else {
        return freqB - freqA // Descending (largest first = background)
      }
    })
    
    console.log(`📊 [ReGL] Category order (${this.categoryOrder}):`, 
                sortedCategories.map(c => `${c}(${categoryFrequencies[c]})`).join(', '))
    
    // Create category -> draw order mapping
    const categoryDrawOrder = {}
    sortedCategories.forEach((category, order) => {
      categoryDrawOrder[category] = order
    })
    
    // Sort the displayOrder array by category
    this.displayOrder.sort((cellA, cellB) => {
      const catA = values[cellA]
      const catB = values[cellB]
      return categoryDrawOrder[catA] - categoryDrawOrder[catB]
    })
    
    console.log(`📊 [ReGL] Reordered displayOrder array (first 5 cells: ${this.displayOrder.slice(0, 5).join(', ')})`)
    
    // Rebuild buffer using new display order
    const screenCoordinates = new Float32Array(this.displayOrder.length * 2)
    const colorMap = new Map()
    
    for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
      const cellIndex = this.displayOrder[drawPos]
      const [dataX, dataY] = this.currentCoordinates[cellIndex]
      
      // Normalize to screen coordinates
      screenCoordinates[drawPos * 2] = this.normalizeX(dataX, this.currentBounds)
      screenCoordinates[drawPos * 2 + 1] = this.normalizeY(dataY, this.currentBounds)
      
      // Get color for this cell
      const color = this.originalPointColors.get(cellIndex) || 0x3b82f6
      colorMap.set(drawPos, color)
    }
    
    // Update ReGL buffers with reordered data
    this.reglRenderer.updatePositions(screenCoordinates)
    this.reglRenderer.updateColors(colorMap)
    this.reglRenderer.render()
    
    // Redraw the Canvas 2D overlay (grid, axes, labels)
    this.renderGrid()
    this.renderAxes()
    this.renderCategoryLabels()
    
    const elapsed = performance.now() - startTime
    console.log(`📊 [ReGL] Reordered ${this.displayOrder.length} points in ${elapsed.toFixed(2)}ms`)
  }
  // Reorder display order based on numeric values (painter's algorithm)
  // Uses displayOrder array - does NOT modify original data
  reorderPointsForNumericDisplay(values, minVal, maxVal) {
    if (!this.reglRenderer || !this.currentCoordinates || !this.currentMetadataVector || !this.displayOrder) {
      console.log('⚠️ [ReGL] Cannot reorder - missing data')
      return
    }
    
    console.log(`📊 [ReGL] Reordering display order for numeric: ${this.numericalOrder}`)
    const startTime = performance.now()
    
    // Compute z-indices for all cells based on their original cell indices
    const zIndices = []
    for (let i = 0; i < this.displayOrder.length; i++) {
      const cellIndex = this.displayOrder[i]
      const value = values[cellIndex]
      // Compute z-index for this cell's value
      const normalizedValue = (maxVal - minVal) > 0 ? (value - minVal) / (maxVal - minVal) : 0.5
      
      let zIndex = 0
      const maxZIndex = 1000
      switch (this.numericalOrder) {
        case 'negative-to-positive':
          zIndex = Math.round(normalizedValue * maxZIndex)
          break
        case 'positive-to-negative':
          zIndex = Math.round((1 - normalizedValue) * maxZIndex)
          break
        case 'abs-min-to-max':
          const absValue = Math.abs(value)
          const absMax = Math.max(Math.abs(minVal), Math.abs(maxVal))
          zIndex = absMax > 0 ? Math.round((absValue / absMax) * maxZIndex) : 0
          break
        case 'abs-max-to-min':
          const absValue2 = Math.abs(value)
          const absMax2 = Math.max(Math.abs(minVal), Math.abs(maxVal))
          zIndex = absMax2 > 0 ? Math.round(((absMax2 - absValue2) / absMax2) * maxZIndex) : 0
          break
      }
      zIndices.push({ cellIndex, zIndex })
    }
    
    // Sort by z-index (lower z-index = drawn first = background)
    zIndices.sort((a, b) => a.zIndex - b.zIndex)
    
    // Update displayOrder array
    for (let i = 0; i < zIndices.length; i++) {
      this.displayOrder[i] = zIndices[i].cellIndex
    }
    
    console.log(`📊 [ReGL] Reordered displayOrder by numeric values (first 5 cells: ${this.displayOrder.slice(0, 5).join(', ')})`)
    
    // Rebuild buffer using new display order
    const screenCoordinates = new Float32Array(this.displayOrder.length * 2)
    const colorMap = new Map()
    
    for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
      const cellIndex = this.displayOrder[drawPos]
      const [dataX, dataY] = this.currentCoordinates[cellIndex]
      
      // Normalize to screen coordinates
      screenCoordinates[drawPos * 2] = this.normalizeX(dataX, this.currentBounds)
      screenCoordinates[drawPos * 2 + 1] = this.normalizeY(dataY, this.currentBounds)
      
      // Get color for this cell
      const color = this.originalPointColors.get(cellIndex) || 0x3b82f6
      colorMap.set(drawPos, color)
    }
    
    // Update ReGL buffers with reordered data
    this.reglRenderer.updatePositions(screenCoordinates)
    this.reglRenderer.updateColors(colorMap)
    this.reglRenderer.render()
    
    // Redraw the Canvas 2D overlay (grid, axes, legend)
    this.renderGrid()
    this.renderAxes()
    this.renderContinuousColorLegend()
    
    const elapsed = performance.now() - startTime
    console.log(`📊 [ReGL] Reordered ${this.displayOrder.length} numeric points in ${elapsed.toFixed(2)}ms`)
  }

  // Update category display order in ALL unfolded metadata panels
  updateAllCategoryDisplayOrders() {
    console.log('📊 Updating category order in all unfolded metadata panels...')
    
    // Find all metadata containers with visible categories
    const metadataContainers = document.querySelectorAll('[data-metadata-item]')
    let updatedCount = 0
    
    metadataContainers.forEach(container => {
      // Find the categories div (the one with padding-left: 32px)
      const categoriesDiv = container.querySelector('div[style*="padding-left: 32px"]')
      
      // Only update if categories are visible (unfolded)
      if (categoriesDiv && categoriesDiv.style.display !== 'none') {
        // Get all category items
        const categoryItems = Array.from(categoriesDiv.children)
        
        if (categoryItems.length === 0) return
        
        // Extract categories and their counts
        const categoriesData = []
        categoryItems.forEach(item => {
          const checkbox = item.querySelector('.category-checkbox')
          if (checkbox) {
            const category = checkbox.dataset.category
            // Extract count from the item's text content
            const countSpan = item.querySelector('span[style*="font-weight: 500"]')
            const count = countSpan ? parseInt(countSpan.textContent) : 0
            categoriesData.push({ category, count, element: item })
          }
        })
        
        // Sort based on current preference
        categoriesData.sort((a, b) => {
          if (this.categoryOrder === 'smallest-first') {
            return a.count - b.count // Ascending (smallest first)
          } else {
            return b.count - a.count // Descending (largest first)
          }
        })
        
        // Re-append in the new sorted order
        categoriesData.forEach(data => {
          categoriesDiv.appendChild(data.element)
        })
        
        updatedCount++
      }
    })
    
    console.log(`📊 Updated category order in ${updatedCount} metadata panel(s)`)
  }

  changeNumericalOrder(event) {
    const newOrder = event.target.value
    console.log(`📊 Changing numerical order from '${this.numericalOrder}' to '${newOrder}'`)
    
    if (newOrder === this.numericalOrder) {
      console.log('📊 Order unchanged, skipping update')
      return
    }
    
    this.numericalOrder = newOrder
    
    // Reset the last order applied flag to force reordering
    this._lastNumericOrderApplied = null
    
    // If we have numeric metadata currently displayed, re-render the plot
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'NUMERIC') {
      console.log('📊 Re-rendering plot with new numerical order...')
      
      // Re-render points with new z-order (colors stay the same)
      if (this.rendererType === 'regl') {
        // For ReGL, call the color rendering function which handles reordering
        this.renderPointsWithCurrentColoringReGL()
      } else {
        // For PixiJS, use the general rendering function
      this.renderPointsWithCurrentColoring()
      }
      
      console.log('📊 Numerical order change complete')
    } else {
      console.log('📊 No numeric metadata active, order preference saved for next use')
    }
  }

  // Pre-compute z-indices for all values at once (much faster than calling calculateNumericZIndex 500k times)
  precomputeNumericZIndices(values, minVal, maxVal) {
    const range = maxVal - minVal
    if (range === 0) {
      // All values are the same, return array of zeros
      return new Array(values.length).fill(0)
    }
    
    const zIndices = new Array(values.length)
    const maxZIndex = 1000
    const invRange = 1.0 / range
    
    switch (this.numericalOrder) {
      case 'negative-to-positive':
        // Lower values = lower z-index = background
        for (let i = 0; i < values.length; i++) {
          zIndices[i] = Math.round((values[i] - minVal) * invRange * maxZIndex)
        }
        break
        
      case 'positive-to-negative':
        // Higher values = lower z-index = background
        for (let i = 0; i < values.length; i++) {
          zIndices[i] = Math.round((maxVal - values[i]) * invRange * maxZIndex)
        }
        break
        
      case 'abs-min-to-max':
        // Smaller absolute values = lower z-index = background
        const absMax = Math.max(Math.abs(minVal), Math.abs(maxVal))
        const invAbsMax = 1.0 / absMax
        for (let i = 0; i < values.length; i++) {
          const absValue = Math.abs(values[i])
          zIndices[i] = Math.round(absValue * invAbsMax * maxZIndex)
        }
        break
        
      case 'abs-max-to-min':
        // Larger absolute values = lower z-index = background
        const absMax2 = Math.max(Math.abs(minVal), Math.abs(maxVal))
        const invAbsMax2 = 1.0 / absMax2
        for (let i = 0; i < values.length; i++) {
          const absValue = Math.abs(values[i])
          zIndices[i] = Math.round((absMax2 - absValue) * invAbsMax2 * maxZIndex)
        }
        break
        
      default:
        // Fallback: all zeros
        zIndices.fill(0)
    }
    
    return zIndices
  }

  // Update category display order in the left panel
  updateCategoryDisplayInLeftPanel(metadataId, sortedCategories) {
    // Find the metadata item container
    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return
    
    // Find the categories div (the one with padding-left: 32px)
    const categoriesDiv = metadataContainer.querySelector('div[style*="padding-left: 32px"]')
    if (!categoriesDiv) return
    
    // Get all category items
    const categoryItems = Array.from(categoriesDiv.children)
    
    // Create a map of category name to element
    const categoryMap = new Map()
    categoryItems.forEach(item => {
      const checkbox = item.querySelector('.category-checkbox')
      if (checkbox) {
        const category = checkbox.dataset.category
        categoryMap.set(category, item)
      }
    })
    
    // Re-append in the new sorted order
    sortedCategories.forEach(category => {
      const item = categoryMap.get(String(category))
      if (item) {
        categoriesDiv.appendChild(item)
      }
    })
    
    console.log('📊 Updated left panel category order')
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
      
      // Clear the selection after saving
      this.selectedCells.clear()
      
      // Restore the metadata state from before the selection
      const wasRestored = this.restoreMetadataStateAfterSelection()
      
      // If no metadata was restored, just update colors to default
      if (!wasRestored) {
        console.log('No metadata to restore after save, updating colors to default')
        this.updateSelectedPointColors()
      }
      
      // Update the cell count display
      this.updateSelectedCellsCount()
      
      // Clear any lasso graphics
      if (this.lassoGraphics) {
        this.lassoGraphics.clear()
        this.lassoGraphics = null
      }
    }
  }

  // Save plot as SVG method
  saveAsSVG() {
    console.log('💾 Saving plot as SVG')
    
    // Check for renderer availability
    const hasRenderer = this.rendererType === 'regl' ? !!this.reglRenderer : (!!this.pixiApp && !!this.scatterContainer)
    
    if (!hasRenderer) {
      alert('No plot available to save')
      return
    }

    try {
      // Create SVG content
      const svgContent = this.generateSVGFromPlot()
      
      // Create and download the SVG file
      this.downloadSVG(svgContent, 'plot.svg')
      
      console.log('💾 SVG saved successfully')
    } catch (error) {
      console.error('Error saving SVG:', error)
      alert('Error saving SVG file')
    }
  }

  // Generate SVG content from the current plot
  generateSVGFromPlot() {
    console.log('💾 Generating SVG from plot...')
    
    // Dispatch to appropriate implementation
    if (this.rendererType === 'regl') {
      return this.generateSVGFromPlotReGL()
    } else {
      return this.generateSVGFromPlotPixi()
    }
  }
  
  // ReGL version of SVG generation
  generateSVGFromPlotReGL() {
    console.log('💾 [ReGL] Generating SVG from ReGL plot')
    
    const width = this.canvas.width
    const height = this.canvas.height
    
    // Start SVG with proper dimensions
    let svg = `<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">`
    
    // Add background
    svg += `<rect width="100%" height="100%" fill="white"/>`
    
    // Add grid (always render if we have bounds)
    if (this.currentBounds) {
      svg += this.generateSVGGridReGL(width, height)
    }
    
    // Add axes (always render if we have bounds)
    if (this.currentBounds) {
      svg += this.generateSVGAxesReGL(width, height)
    }
    
    // Add points from currentCoordinates
    if (this.currentCoordinates && this.originalPointColors) {
      console.log(`💾 [ReGL] Exporting ${this.currentCoordinates.length} points to SVG`)
      
      const pointSize = this.currentPointSize || 4
      
      for (let i = 0; i < this.currentCoordinates.length; i++) {
        const [dataX, dataY] = this.currentCoordinates[i]
        const screenX = this.normalizeX(dataX, this.currentBounds)
        const screenY = this.normalizeY(dataY, this.currentBounds)
        
        // Get color from originalPointColors
        const colorInt = this.originalPointColors.get(i) || 0x3b82f6
        const r = (colorInt >> 16) & 0xFF
        const g = (colorInt >> 8) & 0xFF
        const b = colorInt & 0xFF
        const colorHex = `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`
        
        // Add circle for each point
        svg += `<circle cx="${screenX.toFixed(2)}" cy="${screenY.toFixed(2)}" r="${pointSize}" fill="${colorHex}"/>`
      }
    }
    
    // Add category labels if checkbox is checked
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')
    if (categoriesCheckbox && categoriesCheckbox.checked && this.canvas2DLabels && this.canvas2DLabels.length > 0) {
      svg += this.generateSVGCategoryLabelsReGL()
    }
    
    svg += `</svg>`
    console.log('💾 [ReGL] SVG generation complete')
    return svg
  }
  
  // PixiJS version of SVG generation (original)
  generateSVGFromPlotPixi() {
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
  
  // ReGL version: Generate SVG grid from current bounds
  generateSVGGridReGL(width, height) {
    if (!this.currentBounds) return ''
    
    const { minX, maxX, minY, maxY } = this.currentBounds
    const margins = this.getPlotMargins()
    
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    let svg = ''
    
    // Vertical grid lines
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let value = xStart; value <= xEnd; value += xTickSpacing) {
      const t = (value - minX) / xRange
      const x = margins.left + t * (width - margins.left - margins.right)
      if (x >= margins.left && x <= width - margins.right) {
        svg += `<line x1="${x}" y1="${margins.top}" x2="${x}" y2="${height - margins.bottom}" stroke="rgba(204,204,204,0.3)" stroke-width="1"/>`
      }
    }
    
    // Horizontal grid lines
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const t = (value - minY) / yRange
      const y = margins.top + (height - margins.top - margins.bottom) - t * (height - margins.top - margins.bottom)
      if (y >= margins.top && y <= height - margins.bottom) {
        svg += `<line x1="${margins.left}" y1="${y}" x2="${width - margins.right}" y2="${y}" stroke="rgba(204,204,204,0.3)" stroke-width="1"/>`
      }
    }
    
    return svg
  }
  
  // ReGL version: Generate SVG axes from current bounds
  generateSVGAxesReGL(width, height) {
    if (!this.currentBounds) return ''
    
    const { minX, maxX, minY, maxY } = this.currentBounds
    const margins = this.getPlotMargins()
    const xAxisY = height - margins.bottom
    const yAxisX = margins.left
    
    let svg = ''
    
    // White rectangles to cover margin areas
    svg += `<rect x="0" y="${xAxisY}" width="${width}" height="${height - xAxisY}" fill="white"/>`
    svg += `<rect x="0" y="0" width="${yAxisX}" height="${height}" fill="white"/>`
    
    // Axes lines
    svg += `<line x1="${margins.left}" y1="${xAxisY}" x2="${width - margins.right}" y2="${xAxisY}" stroke="#333333" stroke-width="2" opacity="0.8"/>`
    svg += `<line x1="${yAxisX}" y1="${margins.top}" x2="${yAxisX}" y2="${height - margins.bottom}" stroke="#333333" stroke-width="2" opacity="0.8"/>`
    
    // Tick marks and labels
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    // X-axis ticks
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let value = xStart; value <= xEnd; value += xTickSpacing) {
      const screenX = margins.left + ((value - minX) / xRange) * (width - margins.left - margins.right)
      
      // Tick mark
      svg += `<line x1="${screenX}" y1="${xAxisY}" x2="${screenX}" y2="${xAxisY + 5}" stroke="#333333" stroke-width="1"/>`
      
      // Label
      svg += `<text x="${screenX}" y="${xAxisY + 19}" font-family="Arial" font-size="12" fill="#333333" text-anchor="middle">${value.toFixed(1)}</text>`
    }
    
    // Y-axis ticks
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const screenY = height - margins.bottom - ((value - minY) / yRange) * (height - margins.top - margins.bottom)
      
      // Tick mark
      svg += `<line x1="${yAxisX - 5}" y1="${screenY}" x2="${yAxisX}" y2="${screenY}" stroke="#333333" stroke-width="1"/>`
      
      // Label
      svg += `<text x="${yAxisX - 9}" y="${screenY}" font-family="Arial" font-size="12" fill="#333333" text-anchor="end" dominant-baseline="middle">${value.toFixed(1)}</text>`
    }
    
    // Axis titles
    svg += `<text x="${width / 2}" y="${height - 5}" font-family="Arial" font-size="14" fill="#333333" text-anchor="middle">Dimension 1</text>`
    svg += `<text x="15" y="${height / 2}" font-family="Arial" font-size="14" fill="#333333" text-anchor="middle" transform="rotate(-90, 15, ${height / 2})">Dimension 2</text>`
    
    return svg
  }
  
  // ReGL version: Generate SVG category labels
  generateSVGCategoryLabelsReGL() {
    if (!this.canvas2DLabels || this.canvas2DLabels.length === 0) return ''
    
    let svg = ''
    
    this.canvas2DLabels.forEach(label => {
      const { x, y, bounds, color, category } = label
      
      // Draw background rectangle
      svg += `<rect x="${bounds.x}" y="${bounds.y}" width="${bounds.width}" height="${bounds.height}" fill="rgba(255,255,255,0.9)" stroke="rgb(${color.r},${color.g},${color.b})" stroke-width="2"/>`
      
      // Draw text
      svg += `<text x="${x}" y="${y}" font-family="Arial" font-size="12" fill="#333333" text-anchor="middle" dominant-baseline="middle">${category}</text>`
    })
    
    return svg
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
  // Store metadata state before making a selection
  storeMetadataStateBeforeSelection() {
    // Only store if we haven't already stored (for multiple selections)
    if (this.lastActiveMetadata) {
      console.log('📦 Metadata state already stored, keeping original:', this.lastActiveMetadata)
      return
    }
    
    // Store the current metadata state so we can restore it after cancel/save
    this.lastActiveMetadata = {
      metadataId: this.currentMetadataId,
      metadataVector: this.currentMetadataVector,
      customColorRange: this.customColorRange,
      // Find the currently active water drop button
      activeButton: document.querySelector('[data-action*="waterDropClicked"][data-active="true"]')
    }
    console.log('📦 Stored metadata state before selection:', this.lastActiveMetadata)
  }
  // Restore metadata state after cancel/save selection
  restoreMetadataStateAfterSelection() {
    if (!this.lastActiveMetadata) {
      console.log('No previous metadata state to restore')
      return false
    }
    
    const { metadataId, metadataVector, customColorRange, activeButton } = this.lastActiveMetadata
    
    if (metadataId && metadataVector) {
      console.log('🔄 Restoring metadata coloring:', metadataVector.name)
      
      // Restore the metadata state
      this.currentMetadataId = metadataId
      this.currentMetadataVector = metadataVector
      this.customColorRange = customColorRange
      
      // Clear the color map cache to force fresh color assignment
      this.clearColorMapCache()
      
      // Re-activate the water drop button
      if (activeButton) {
        this.setWaterDropButtonActive(activeButton)
        
        // Re-add category colors if it's discrete metadata
        if (metadataVector.data_type === 'DISCRETE') {
          const metadataContainer = activeButton.closest('[data-metadata-item]')
          if (metadataContainer) {
            this.addCategoryColors(metadataContainer, metadataId)
          }
        }
      }
      
      // Update sprite colors using existing rendering logic (no sprite recreation)
      console.log('🎨 Updating sprite colors with restored metadata')
      this.renderPointsWithCurrentColoring()
      
      // Re-render category labels or color legend
      if (metadataVector.data_type === 'DISCRETE') {
        if (this.categoryLabelsContainer) {
          this.categoryLabelsContainer.visible = true
          this.renderCategoryLabels()
        }
      } else if (metadataVector.data_type === 'NUMERIC') {
        this.renderContinuousColorLegend()
      }
      
      console.log('✅ Metadata coloring restored successfully')
      
      // Clear the stored state
      this.lastActiveMetadata = null
      return true
    } else {
      console.log('No metadata was active before selection')
      // Clear the stored state
      this.lastActiveMetadata = null
      return false
    }
  }

  cancelSelection() {
    console.log('🔄 Canceling selection, reverting to previous coloring scheme')
    
    // Clear the selected cells
    this.selectedCells.clear()
    
    // Restore the metadata state from before the selection
    const wasRestored = this.restoreMetadataStateAfterSelection()
    
    // If no metadata was restored, just update colors to remove selection highlighting
    if (!wasRestored) {
      console.log('No metadata to restore, updating colors to default')
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
      const totalSelectedCount = this.selectedCells ? this.selectedCells.size : 0
      
      if (totalSelectedCount === 0) {
        countElement.textContent = '0'
        countElement.title = 'No cells selected'
        countElement.style.color = ''
        countElement.style.fontWeight = ''
        //console.log(`Updated display to: 0 cells selected`)
      } else if (this.currentVisibleCells && this.currentVisibleCells.length < (this.currentCoordinates?.length || 0)) {
        // Filtering is active - count only selected cells that are also visible
        const visibleSet = new Set(this.currentVisibleCells)
        let visibleSelectedCount = 0
        
        for (const cellId of this.selectedCells) {
          if (visibleSet.has(cellId)) {
            visibleSelectedCount++
          }
        }
        
        // Show visible count in main display
        countElement.textContent = visibleSelectedCount.toLocaleString()
        
        // Visual indicator if some selected cells are filtered out
        if (visibleSelectedCount < totalSelectedCount) {
          countElement.style.color = '#dc2626'
          countElement.style.fontWeight = '600'
          const filteredOut = totalSelectedCount - visibleSelectedCount
          countElement.title = `${visibleSelectedCount.toLocaleString()} cells visible (${totalSelectedCount.toLocaleString()} selected, but ${filteredOut} filtered out by metadata)`
      } else {
          countElement.style.color = ''
          countElement.style.fontWeight = ''
          countElement.title = `${visibleSelectedCount.toLocaleString()} cells selected (all visible)`
        }
        //console.log(`Updated display to: ${visibleSelectedCount} visible of ${totalSelectedCount} selected`)
      } else {
        // No filtering applied - show all selected cells
        countElement.textContent = totalSelectedCount.toLocaleString()
        countElement.style.color = ''
        countElement.style.fontWeight = ''
        countElement.title = `${totalSelectedCount.toLocaleString()} cells selected`
        //console.log(`Updated display to: ${totalSelectedCount} cells selected`)
      }
    } else {
      console.log(`selected-cells-count element not found!`)
    }
    
    // Update the "Add all visible cells" button state
    this.updateAddAllVisibleButtonState()
  }

  // Tooltip methods
  showTooltip(cellId, point) {
    // This method is kept for compatibility with PixiJS mode
    // For RegL mode, we use showSimpleTooltip instead
    
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
    
    // Set tooltip content with fixed/dynamic indicator
    let statusIndicator = ''
    if (this.rendererType === 'regl' && this.isTooltipFixed) {
      statusIndicator = '<br><em style="color: #00ff00;">🔒</em>'
    } else if (this.rendererType === 'regl') {
      //statusIndicator = '<br><em style="color: #ccc;"></em>'
    }
    
    const tooltipHTML = `<strong>${cellName}</strong>${categoryInfo}${statusIndicator}`
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
    
    // Additional safety check - ensure tooltip is within viewport
    if (tooltipLeft < rect.left) {
      tooltipLeft = rect.left + 10
    }
    if (tooltipLeft > rect.right - tooltipWidth) {
      tooltipLeft = rect.right - tooltipWidth - 10
    }
    
    console.log('🎯 [Tooltip] Positioning tooltip at:', { tooltipLeft, tooltipTop, pointX, pointY })
    
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
    console.log('🎯 [Tooltip] Computed style:', {
      display: computedStyle.display,
      visibility: computedStyle.visibility,
      opacity: computedStyle.opacity,
      position: computedStyle.position,
      zIndex: computedStyle.zIndex
    })
    
    // Force tooltip to be visible with maximum z-index
    this.tooltip.style.zIndex = '999999'
    this.tooltip.style.position = 'fixed'
    this.tooltip.style.visibility = 'visible'
    this.tooltip.style.opacity = '1'
    
    // For RegL mode, use proper positioning instead of fixed debug position
    if (this.rendererType === 'regl') {
      console.log('🎯 [Tooltip] Applying RegL positioning and styling')
      
      // Use the calculated position for RegL
      this.tooltip.style.left = `${tooltipLeft}px`
      this.tooltip.style.top = `${tooltipTop}px`
      
      // Different styling for fixed vs dynamic tooltips
      if (this.isTooltipFixed) {
        console.log('🎯 [Tooltip] Applying fixed tooltip styling (green)')
        this.tooltip.style.backgroundColor = 'rgba(0, 100, 0, 0.9)' // Green for fixed
        this.tooltip.style.border = '2px solid #00ff00'
        this.tooltip.style.boxShadow = '0 0 10px rgba(0, 255, 0, 0.5)'
      } else {
        console.log('🎯 [Tooltip] Applying dynamic tooltip styling (black)')
        this.tooltip.style.backgroundColor = 'rgba(0, 0, 0, 0.8)' // Black for dynamic
        this.tooltip.style.border = '1px solid #ccc'
        this.tooltip.style.boxShadow = '0 2px 4px rgba(0, 0, 0, 0.3)'
      }
      
      this.tooltip.style.width = 'auto'
      this.tooltip.style.height = 'auto'
      
      console.log('🎯 [Tooltip] Final RegL tooltip position:', {
        left: this.tooltip.style.left,
        top: this.tooltip.style.top,
        display: this.tooltip.style.display,
        backgroundColor: this.tooltip.style.backgroundColor
      })
      
      // TEMPORARY: Force tooltip to a visible position for debugging
      this.tooltip.style.left = '100px'
      this.tooltip.style.top = '100px'
      this.tooltip.style.backgroundColor = 'red'
      this.tooltip.style.border = '3px solid yellow'
      this.tooltip.style.width = '300px'
      this.tooltip.style.height = '100px'
      console.log('🎯 [Tooltip] FORCED tooltip to visible position for debugging')
    } else {
      // Keep debug positioning for PixiJS mode
      this.tooltip.style.left = '50px'
      this.tooltip.style.top = '50px'
      this.tooltip.style.backgroundColor = 'red'
      this.tooltip.style.border = '3px solid yellow'
      this.tooltip.style.width = '300px'
      this.tooltip.style.height = '100px'
    }
    
    // Tooltip positioned
  }

  hideTooltip() {
    if (this.tooltip) {
      this.tooltip.style.display = 'none'
    }
    // Only reset fixed state if we're not in a fixed tooltip mode
    if (!this.isTooltipFixed) {
      this.fixedTooltipCellId = null
    }
  }

  // Unfix tooltip (called when clicking on empty space)
  unfixTooltip() {
    this.isTooltipFixed = false
    this.fixedTooltipCellId = null
    this.hideSimpleTooltip()
    console.log('🎯 [RegL] Unfixed tooltip')
  }

  // Hide simple tooltip
  hideSimpleTooltip() {
    const existing = document.getElementById('simple-tooltip')
    if (existing) {
      existing.remove()
    }
    // Reset tooltip state when hiding
    this.isTooltipFixed = false
    this.fixedTooltipCellId = null
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
      // Reset tooltip state to re-enable hover detection
      this.isTooltipFixed = false
      this.fixedTooltipCellId = null
      console.log('🗑️ Tooltip closed by user - hover detection re-enabled')
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
    console.log('🎯 [Pick] onPickMouseDown called, rendererType:', this.rendererType)
    
    // In ReGL mode, check for label clicks first
    if (this.rendererType === 'regl' && this.canvas2DLabels && this.canvas2DLabels.length > 0) {
      const canvas = this.canvas
      const rect = canvas.getBoundingClientRect()
      const mouseX = event.clientX - rect.left
      const mouseY = event.clientY - rect.top
      
      console.log(`🏷️ [Drag] Mouse down at (${mouseX}, ${mouseY}), checking ${this.canvas2DLabels.length} labels`)
      
      // Check if clicking on a label
      for (let i = this.canvas2DLabels.length - 1; i >= 0; i--) {
        const label = this.canvas2DLabels[i]
        const bounds = label.bounds
        
        console.log(`🏷️ [Drag] Label "${label.category}" bounds: x=${bounds.x}, y=${bounds.y}, w=${bounds.width}, h=${bounds.height}`)
        
        if (mouseX >= bounds.x && mouseX <= bounds.x + bounds.width &&
            mouseY >= bounds.y && mouseY <= bounds.y + bounds.height) {
          // Clicked on a label - start dragging
          this.draggingLabel = label
          this.labelDragStartX = mouseX
          this.labelDragStartY = mouseY
          this.labelStartOffsetX = label.offsetX
          this.labelStartOffsetY = label.offsetY
          this.clickingOnLabel = true
          console.log(`🏷️ Started dragging label: ${label.category}`)
          return
        }
      }
      
      console.log(`🏷️ [Drag] No label hit at (${mouseX}, ${mouseY})`)
    }
    
    // In pick mode, use fallback detection to find clicked points
    // But don't detect points if we're clicking on a label
    if (this.clickingOnLabel) {
      return
    }
    
    // Safety check for renderer
    if (this.rendererType === 'pixi' && (!this.pixiApp || !this.scatterContainer)) {
      console.log('PIXI app or scatterContainer not available for point detection')
      return
    }
    
    // ReGL mode: implement point detection
    if (this.rendererType === 'regl') {
      // Check if RegL renderer and coordinates are available
      if (!this.reglRenderer || !this.currentCoordinates) {
        console.log('🎯 [RegL] RegL renderer or coordinates not available, skipping point detection')
        return
      }
      this.detectRegLPointClick(event)
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

  // RegL-specific point detection method
  detectRegLPointClick(event) {
    console.log('🎯 [RegL] detectRegLPointClick called')
    
    if (this.interactionMode !== 'pick') {
      console.log('🎯 [RegL] Not in pick mode, current mode:', this.interactionMode)
      return
    }

    const canvas = this.canvas
    if (!canvas || !this.reglRenderer || !this.currentCoordinates) {
      console.log('🎯 [RegL] Missing requirements:', {
        canvas: !!canvas,
        reglRenderer: !!this.reglRenderer,
        currentCoordinates: !!this.currentCoordinates,
        coordinatesLength: this.currentCoordinates?.length
      })
      return
    }

    const rect = canvas.getBoundingClientRect()
    const clickX = event.clientX - rect.left
    const clickY = event.clientY - rect.top

    console.log('🎯 [RegL] Click coordinates:', { clickX, clickY, canvasWidth: canvas.width, canvasHeight: canvas.height })

    // Use current bounds (which include pan/zoom state) instead of calculating from coordinates
    const bounds = this.currentBounds || this.calculateBounds(this.currentCoordinates)
    const margins = this.getPlotMargins()
    
    console.log('🎯 [RegL] Current bounds and margins:', { bounds, margins })
    
    // Convert screen coordinates back to data coordinates using current bounds
    const dataX = bounds.minX + ((clickX - margins.left) / (canvas.width - margins.left - margins.right)) * (bounds.maxX - bounds.minX)
    const dataY = bounds.minY + ((canvas.height - margins.top - margins.bottom - (clickY - margins.top)) / (canvas.height - margins.top - margins.bottom)) * (bounds.maxY - bounds.minY)
    
    console.log('🎯 [RegL] Data coordinates (with pan/zoom):', { dataX, dataY })

    // Calculate tolerance in screen pixels, accounting for point size
    const pointSize = this.currentPointSize || 4
    const screenTolerance = Math.max(pointSize * 2, 10) // At least 2x point size, minimum 10px
    
    // Convert screen tolerance to data coordinates
    const screenWidth = canvas.width - margins.left - margins.right
    const screenHeight = canvas.height - margins.top - margins.bottom
    const dataToleranceX = (screenTolerance / screenWidth) * (bounds.maxX - bounds.minX)
    const dataToleranceY = (screenTolerance / screenHeight) * (bounds.maxY - bounds.minY)
    const maxDistance = Math.max(dataToleranceX, dataToleranceY) // Use the larger tolerance
    
    console.log('🎯 [RegL] Screen-based tolerance:', { 
      pointSize: pointSize,
      screenTolerance: screenTolerance,
      dataToleranceX: dataToleranceX.toFixed(6),
      dataToleranceY: dataToleranceY.toFixed(6),
      maxDistance: maxDistance.toFixed(6),
      screenWidth: screenWidth,
      screenHeight: screenHeight
    })

    // Find closest point
    let closestPointIndex = -1
    let closestDistance = Infinity

    console.log('🎯 [RegL] Searching through', this.currentCoordinates.length, 'points with maxDistance:', maxDistance)

    for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
      const cellIndex = this.displayOrder[drawPos]
      const [x, y] = this.currentCoordinates[cellIndex]
      const distance = Math.sqrt(Math.pow(x - dataX, 2) + Math.pow(y - dataY, 2))
      
      if (drawPos < 5) { // Debug first 5 points
        console.log(`🎯 [RegL] DrawPos ${drawPos} -> Cell ${cellIndex}: (${x}, ${y}), distance: ${distance.toFixed(6)}`)
      }
      
      // Track the closest point
      if (distance < closestDistance) {
        closestDistance = distance
        closestPointIndex = cellIndex // Use the original cell index, not draw position
        console.log(`🎯 [RegL] New closest point: DrawPos ${drawPos} -> Cell ${cellIndex}, distance: ${distance.toFixed(6)}`)
      }
    }

    console.log('🎯 [RegL] Final result:', { closestPointIndex, closestDistance: closestDistance.toFixed(6), maxDistance: maxDistance.toFixed(6) })

    if (closestPointIndex !== -1 && closestDistance <= maxDistance) {
      // Point found within tolerance - fix tooltip to this cell
      console.log('🎯 [RegL] Point found within tolerance! Fixing tooltip to cell', closestPointIndex, 'distance:', closestDistance.toFixed(6))
      this.fixTooltipToCell(closestPointIndex, clickX, clickY)
    } else {
      // No point found within tolerance - hide any existing tooltip
      console.log('🎯 [RegL] No point found within tolerance - hiding tooltip')
      if (this.isTooltipFixed) {
        this.unfixTooltip()
      } else {
        this.hideSimpleTooltip()
      }
    }
  }

  // Fix tooltip to a specific cell (clicked cell)
  fixTooltipToCell(cellId, screenX, screenY) {
    console.log('🎯 [RegL] fixTooltipToCell called with:', { cellId, screenX, screenY })
    
    this.fixedTooltipCellId = cellId
    this.isTooltipFixed = true
    
    // Use the existing showSimpleTooltip method instead of the complex tooltip system
    const cellName = `Cell ${cellId + 1}`
    let categoryInfo = ''
    
    // Get category information if available
    if (this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[cellId] !== undefined) {
      const { data_type, values } = this.currentMetadataVector
      const value = values[cellId]
      
      if (data_type === 'DISCRETE') {
        categoryInfo = `Category: ${value}`
      } else if (data_type === 'NUMERIC') {
        categoryInfo = `Value: ${value.toFixed(3)}`
      }
    }
    
    // Add fixed indicator
    categoryInfo += ' 🔒'
    
    // Create a mock point object for positioning
    const mockPoint = { x: screenX, y: screenY }
    this.showSimpleTooltip(cellName, categoryInfo, mockPoint)
    
    console.log(`🎯 [RegL] Fixed tooltip to cell ${cellId + 1}`)
  }

  // Check if color picker popup or gradient editor is currently open
  isColorPickerOpen() {
    const colorPicker = document.getElementById('color-picker-form')
    const gradientEditor = document.getElementById('gradient-editor-modal')
    const controlPointEditor = document.getElementById('gradient-control-point-editor')
    
    // Check if color picker exists and is visible
    const colorPickerOpen = colorPicker !== null
    
    // Check if gradient editor exists and is visible (display not 'none')
    const gradientEditorOpen = gradientEditor !== null && 
                               gradientEditor.style.display !== 'none' && 
                               gradientEditor.style.display !== ''
    
    // Check if control point editor exists and is visible (display not 'none')
    const controlPointEditorOpen = controlPointEditor !== null && 
                                   controlPointEditor.style.display !== 'none' && 
                                   controlPointEditor.style.display !== ''
    
    return colorPickerOpen || gradientEditorOpen || controlPointEditorOpen
  }

  // Detect point hovering for RegL (dynamic tooltip)
  detectRegLPointHover(event) {
    if (this.interactionMode !== 'pick') return
    
    // Prevent hovering when color picker popup is open
    if (this.isColorPickerOpen()) return

    const canvas = this.canvas
    if (!canvas || !this.reglRenderer || !this.currentCoordinates) return

    const rect = canvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top

    // Use current bounds (which include pan/zoom state) instead of calculating from coordinates
    const bounds = this.currentBounds || this.calculateBounds(this.currentCoordinates)
    const margins = this.getPlotMargins()
    
    // Convert screen coordinates back to data coordinates using current bounds
    const dataX = bounds.minX + ((mouseX - margins.left) / (canvas.width - margins.left - margins.right)) * (bounds.maxX - bounds.minX)
    const dataY = bounds.minY + ((canvas.height - margins.top - margins.bottom - (mouseY - margins.top)) / (canvas.height - margins.top - margins.bottom)) * (bounds.maxY - bounds.minY)

    // Calculate tolerance in screen pixels, accounting for point size (same as click detection)
    const pointSize = this.currentPointSize || 4
    const screenTolerance = Math.max(pointSize * 2, 10) // At least 2x point size, minimum 10px
    
    // Convert screen tolerance to data coordinates
    const screenWidth = canvas.width - margins.left - margins.right
    const screenHeight = canvas.height - margins.top - margins.bottom
    const dataToleranceX = (screenTolerance / screenWidth) * (bounds.maxX - bounds.minX)
    const dataToleranceY = (screenTolerance / screenHeight) * (bounds.maxY - bounds.minY)
    const maxDistance = Math.max(dataToleranceX, dataToleranceY) // Use the larger tolerance

    // Find closest point
    let closestPointIndex = -1
    let closestDistance = Infinity

    for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
      const cellIndex = this.displayOrder[drawPos]
      const [x, y] = this.currentCoordinates[cellIndex]
      const distance = Math.sqrt(Math.pow(x - dataX, 2) + Math.pow(y - dataY, 2))
      
      if (distance < maxDistance && distance < closestDistance) {
        closestDistance = distance
        closestPointIndex = cellIndex // Use the original cell index, not draw position
      }
    }

    if (closestPointIndex !== -1 && closestDistance <= maxDistance) {
      // Point found within tolerance - show dynamic tooltip only if not fixed
      if (!this.isTooltipFixed) {
        const cellName = `Cell ${closestPointIndex + 1}`
        let categoryInfo = ''
        
        // Get category information if available
        if (this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[closestPointIndex] !== undefined) {
          const { data_type, values } = this.currentMetadataVector
          const value = values[closestPointIndex]
          
          if (data_type === 'DISCRETE') {
            categoryInfo = `Category: ${value}`
          } else if (data_type === 'NUMERIC') {
            categoryInfo = `Value: ${value.toFixed(3)}`
          }
        }
        
        // Add hover indicator
        categoryInfo += ''
        
        const mockPoint = { x: mouseX, y: mouseY }
        this.showSimpleTooltip(cellName, categoryInfo, mockPoint)
      }
    } else {
      // No point found within tolerance - hide tooltip only if not fixed
      if (!this.isTooltipFixed) {
        this.hideSimpleTooltip()
      }
    }
  }

  // Checkbox functionality for cell selection
  async toggleMetadataSelection(event) {
    console.log('🔍 [CHECKBOX] toggleMetadataSelection called!')
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const checkbox = event.currentTarget
    const isSelected = checkbox.style.backgroundColor === 'rgb(16, 185, 129)' // #10b981
    
    console.log('🔍 [CHECKBOX] metadataId:', metadataId, 'isSelected:', isSelected)
    
    // Ensure metadata is loaded (from memory or disk)
    let metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector) {
      console.log(`💾 [DISK] Metadata ${metadataId} not in memory, loading from disk...`)
      try {
        metadataVector = await this.loadMetadataVectorFromDisk(metadataId)
        if (!metadataVector) {
          console.error(`💾 [DISK] Failed to load metadata ${metadataId} from disk - trying server fallback...`)
          // Try direct server loading as last resort
          metadataVector = await this.loadSingleMetadataVector(metadataId)
          if (!metadataVector) {
            console.error(`💾 [DISK] Failed to load metadata ${metadataId} from server`)
            return
          }
        }
      } catch (error) {
        console.error(`💾 [DISK] Error loading metadata ${metadataId}:`, error)
        return
      }
    }
    
    // Check if this is categorical or continuous metadata
    const isContinuous = metadataVector?.data_type === 'NUMERIC'
    console.log('🔍 [CHECKBOX] isContinuous:', isContinuous)
    
    // Toggle the checkbox state
    if (isSelected) {
      // Deselect
      checkbox.style.backgroundColor = '#f3f4f6'
      checkbox.querySelector('i').style.display = 'none'
      
      if (isContinuous) {
        // For continuous metadata: disable range selection (clear the range)
        delete this.selectedRanges[metadataId]
        checkbox.title = 'Enable range selection'
        
        // Disable the range slider for this metadata
        this.disableRangeSliderForMetadata(metadataId)
      } else {
        // For categorical metadata: deselect all categories
        this.deselectAllCategoriesForMetadata(metadataId)
      }
    } else {
      // Select
      checkbox.style.backgroundColor = '#10b981'
      checkbox.querySelector('i').style.display = 'block'
      
      if (isContinuous) {
        console.log('🔍 [CHECKBOX] Re-checking continuous metadata')
        checkbox.title = 'Disable range selection'
        
        // Enable the range slider for this metadata first
        this.enableRangeSliderForMetadata(metadataId)
        
        // Read the current values directly from the range slider fields
        const rangeSection = document.querySelector(`[data-metadata-item="${metadataId}"] .metadata-range-section`)
        console.log('🔍 [CHECKBOX] Range section found:', !!rangeSection)
        if (rangeSection) {
          // Find the actual range slider controller element (child of range section)
          const rangeSliderElement = rangeSection.querySelector('[data-controller="range-slider"]')
          console.log('🔍 [CHECKBOX] Range slider element found:', !!rangeSliderElement)
          
          if (rangeSliderElement) {
            const rangeSliderController = this.application.getControllerForElementAndIdentifier(rangeSliderElement, 'range-slider')
            console.log('🔍 [CHECKBOX] Range slider controller found:', !!rangeSliderController)
            
            if (rangeSliderController) {
              // Use the range slider's current values (which should still be set from before)
              const currentMin = rangeSliderController.currentMinValue
              const currentMax = rangeSliderController.currentMaxValue
              console.log('🔍 [CHECKBOX] Range slider current values:', currentMin, currentMax)
              
              this.selectedRanges[metadataId] = {
                min: currentMin,
                max: currentMax
              }
              console.log('🔍 [CHECKBOX] Set selectedRanges to:', this.selectedRanges[metadataId])
              
              // Update the selected cells count
              rangeSliderController.updateSelectedCellsCount()
              console.log('🔍 [CHECKBOX] Updated selected cells count')
            } else {
              console.log('🔍 [CHECKBOX] No range slider controller found!')
            }
          } else {
            console.log('🔍 [CHECKBOX] No range slider element found!')
          }
        } else {
          console.log('🔍 [CHECKBOX] No range section found!')
        }
      } else {
        // For categorical metadata: select all categories
        this.selectAllCategoriesForMetadata(metadataId)
      }
    }
    
    // Update cell filtering
    console.log('🔍 [CHECKBOX] About to call updateCellFiltering')
    console.log('🔍 [CHECKBOX] Current selectedRanges:', this.selectedRanges)
    this.updateCellFiltering()
    console.log('🔍 [CHECKBOX] updateCellFiltering called')
  }

  async toggleCategorySelection(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const category = event.currentTarget.dataset.category
    const checkbox = event.currentTarget
    const isSelected = checkbox.style.backgroundColor === 'rgb(16, 185, 129)' // #10b981
    
    console.log(`🔄 Toggle category selection: ${category}, isSelected: ${isSelected}`)
    
    // Ensure metadata is loaded (from memory or disk)
    let metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector) {
      try {
        metadataVector = await this.loadMetadataVectorFromDisk(metadataId)
        if (!metadataVector) {
          // Try direct server loading as last resort
          metadataVector = await this.loadSingleMetadataVector(metadataId)
          if (!metadataVector) {
            console.error(`Failed to load metadata ${metadataId}`)
            return
          }
        }
      } catch (error) {
        console.error(`Error loading metadata ${metadataId}:`, error)
        return
      }
    }
    
    // Initialize checkboxes for this metadata if not already done (only for discrete)
    if (metadataVector?.data_type === 'DISCRETE' && !this.selectedCategories[metadataId]) {
      await this.initializeCheckboxesForMetadata(metadataId)
    }
    
    // Toggle the checkbox state
    if (isSelected) {
      // Deselect this category
      console.log(`🔄 About to deselect category: ${category}`)
      checkbox.style.backgroundColor = '#f3f4f6'
      checkbox.querySelector('i').style.display = 'none'
      this.deselectCategory(metadataId, category)
    } else {
      // Select this category
      console.log(`🔄 About to select category: ${category}`)
      checkbox.style.backgroundColor = '#10b981'
      checkbox.querySelector('i').style.display = 'block'
      this.selectCategory(metadataId, category)
    }
    
    // Update the metadata checkbox state
    this.updateMetadataCheckboxState(metadataId)
    
    // Update cell filtering
    console.log(`🔄 About to call updateCellFiltering`)
    this.updateCellFiltering()
    console.log(`🔄 updateCellFiltering completed`)
    
    // Note: Category label re-rendering is handled by updateCellFiltering() in ReGL mode
    // (it redraws the entire overlay including labels with new centroids)
    
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
    
    // Update cell filtering (which will re-render labels in ReGL mode)
    this.updateCellFiltering()
  }

  deselectAllCategoriesForMetadata(metadataId) {
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = '#f3f4f6'
      checkbox.querySelector('i').style.display = 'none'
      const category = checkbox.dataset.category
      this.deselectCategory(metadataId, category)
    })
    
    // Update cell filtering (which will re-render labels in ReGL mode)
    this.updateCellFiltering()
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
    console.log(`🔄 Deselecting category: "${category}" for metadata: ${metadataId}`)
    console.log(`🔄 Category type:`, typeof category, `Length:`, category.length)
    console.log(`🔄 Before deselection - selectedCategories[${metadataId}]:`, this.selectedCategories[metadataId])
    console.log(`🔄 Set size before:`, this.selectedCategories[metadataId]?.size)
    
    if (this.selectedCategories && this.selectedCategories[metadataId]) {
      const hadCategory = this.selectedCategories[metadataId].has(category)
      console.log(`🔄 Did the Set contain "${category}"?`, hadCategory)
      
      this.selectedCategories[metadataId].delete(category)
      console.log(`🔄 After deselection - selectedCategories[${metadataId}]:`, this.selectedCategories[metadataId])
      console.log(`🔄 Set size after:`, this.selectedCategories[metadataId]?.size)
    } else {
      console.log(`🔄 No selectedCategories found for metadata: ${metadataId}`)
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

  async initializeCheckboxesForMetadata(metadataId) {
    //console.log(`Initializing checkboxes for metadata: ${metadataId}`)
    
    // Ensure metadata is loaded (from memory or disk)
    let metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector) {
      console.log(`💾 [DISK] Metadata ${metadataId} not in memory, loading from disk...`)
      metadataVector = await this.loadMetadataVectorFromDisk(metadataId)
      if (!metadataVector) {
        console.error(`💾 [DISK] Failed to load metadata ${metadataId} from disk`)
        return
      }
    }
    
    // Only initialize for discrete metadata
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
      
      // Set initial tooltip based on metadata type
      const metadataVector = this.getMetadataVectorById(metadataId)
      if (metadataVector?.data_type === 'NUMERIC') {
        // For continuous metadata, checkbox is checked by default
        metadataCheckbox.title = 'Disable range selection'
      }
    }
    
    // Show all category checkboxes for this metadata
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.display = 'flex'
    })
    
    //console.log(`Showed ${categoryCheckboxes.length} category checkboxes for metadata ${metadataId}`)
  }

  // Enable range slider for continuous metadata
  enableRangeSliderForMetadata(metadataId) {
    const metadataItem = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataItem) return
    
    const rangeSection = metadataItem.querySelector('.metadata-range-section')
    if (!rangeSection) return
    
    // Find all interactive elements in the range slider
    const minInput = rangeSection.querySelector('.range-min-input')
    const maxInput = rangeSection.querySelector('.range-max-input')
    const minHandle = rangeSection.querySelector('.range-slider-min-handle')
    const maxHandle = rangeSection.querySelector('.range-slider-max-handle')
    const adaptButton = rangeSection.querySelector('[data-range-slider-target="adaptColorRangeButton"]')
    
    // Enable all controls
    if (minInput) minInput.disabled = false
    if (maxInput) maxInput.disabled = false
    if (minHandle) minHandle.style.pointerEvents = 'auto'
    if (maxHandle) maxHandle.style.pointerEvents = 'auto'
    if (adaptButton) adaptButton.disabled = false
    
    // Remove visual disabled state
    if (rangeSection) rangeSection.style.opacity = '1'
  }

  // Disable range slider for continuous metadata
  disableRangeSliderForMetadata(metadataId) {
    const metadataItem = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataItem) return
    
    const rangeSection = metadataItem.querySelector('.metadata-range-section')
    if (!rangeSection) return
    
    // Find all interactive elements in the range slider
    const minInput = rangeSection.querySelector('.range-min-input')
    const maxInput = rangeSection.querySelector('.range-max-input')
    const minHandle = rangeSection.querySelector('.range-slider-min-handle')
    const maxHandle = rangeSection.querySelector('.range-slider-max-handle')
    const adaptButton = rangeSection.querySelector('[data-range-slider-target="adaptColorRangeButton"]')
    
    // Disable all controls
    if (minInput) minInput.disabled = true
    if (maxInput) maxInput.disabled = true
    if (minHandle) minHandle.style.pointerEvents = 'none'
    if (maxHandle) maxHandle.style.pointerEvents = 'none'
    if (adaptButton) adaptButton.disabled = true
    
    // Add visual disabled state
    if (rangeSection) rangeSection.style.opacity = '0.5'
  }

  // Optimized method to show/hide points without re-rendering
  updatePointVisibility(filteredIndices) {
    // ReGL path: update point visibility by modifying alpha channel
    if (this.rendererType === 'regl') {
      return this.updatePointVisibilityReGL(filteredIndices)
    }
    
    // PixiJS path
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
  // Update point visibility in ReGL mode by hiding filtered-out points
  updatePointVisibilityReGL(filteredIndices) {
    if (!this.reglRenderer || !this.currentCoordinates) {
      console.log('⚠️ [ReGL] Cannot update visibility - missing renderer or coordinates')
      return
    }
    
    const startTime = performance.now()
    console.log('🎨 [ReGL] Updating point visibility based on filters')
    console.log('🎨 [ReGL] filteredIndices:', filteredIndices ? `Array of ${filteredIndices.length} indices` : 'null (all visible)')
    console.log('🎨 [ReGL] displayOrder length:', this.displayOrder?.length)
    console.log('🎨 [ReGL] originalPointColors size:', this.originalPointColors?.size)
    
    // Convert filteredIndices to Set for O(1) lookup
    // filteredIndices contains ORIGINAL cell indices
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    
    // Create color map to hide/show points based on filtering
    // We'll use the alpha channel approach: set alpha to 0 for hidden points
    const colorMap = new Map()
    let visibleCount = 0
    let hiddenCount = 0
    
    // Sample a few points to debug
    const sampleIndices = [0, 100, 1000, 5000]
    
    // Use displayOrder to map draw positions to cell indices
    for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
      const cellIndex = this.displayOrder[drawPos]
      const shouldBeVisible = !filteredSet || filteredSet.has(cellIndex)
      
      if (shouldBeVisible) {
        // Restore original color (RGB format - alpha will be set to 1.0 by renderer)
        const originalColor = this.originalPointColors.get(cellIndex) || 0x3b82f6
        colorMap.set(drawPos, originalColor)
        visibleCount++
        
        if (sampleIndices.includes(drawPos)) {
          console.log(`🎨 [Sample] drawPos ${drawPos}, cellIndex ${cellIndex}: VISIBLE, color 0x${originalColor.toString(16)}`)
        }
      } else {
        // Hide point by making it fully transparent
        colorMap.set(drawPos, 0x00000000)
        hiddenCount++
        
        if (sampleIndices.includes(drawPos)) {
          console.log(`🎨 [Sample] drawPos ${drawPos}, cellIndex ${cellIndex}: HIDDEN, color 0x00000000`)
        }
      }
    }
    
    console.log(`🎨 [ReGL] About to update ${colorMap.size} colors`)
    
    // Update colors (which includes alpha channel)
    this.reglRenderer.updateColors(colorMap)
    this.reglRenderer.render()
    
    const elapsed = performance.now() - startTime
    console.log(`🎨 [ReGL] Visibility updated: ${visibleCount} visible, ${hiddenCount} hidden in ${elapsed.toFixed(2)}ms`)
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

  // Create a hash of the current filter state for change detection
  getFilterStateHash() {
    const discreteCount = Object.keys(this.selectedCategories || {}).length
    const continuousCount = Object.keys(this.selectedRanges || {}).length
    
    // Convert Sets to Arrays for proper JSON serialization
    const selectedCategoriesForHash = {}
    if (this.selectedCategories) {
      Object.keys(this.selectedCategories).forEach(metadataId => {
        const set = this.selectedCategories[metadataId]
        selectedCategoriesForHash[metadataId] = set ? Array.from(set).sort() : []
      })
    }
    
    return JSON.stringify({
      selectedCategories: selectedCategoriesForHash,
      selectedRanges: this.selectedRanges,
      currentMetadataId: this.currentMetadataId,
      discreteCount,
      continuousCount
    })
  }

  // Create a hash of the current color state for change detection
  getColorStateHash() {
    return JSON.stringify({
      currentMetadataId: this.currentMetadataId,
      currentMetadataType: this.currentMetadataVector?.data_type,
      categoryOrder: this.categoryOrder,
      customColorRange: this.customColorRange,
      currentColorScheme: this.currentColorScheme,
      filteredIndices: this.currentVisibleCells
    })
  }

  // Performance monitoring helper
  recordPerformanceMetrics(operationName, duration) {
    this.performanceMetrics.updateCount++
    this.performanceMetrics.lastUpdateTime = duration
    this.performanceMetrics.maxUpdateTime = Math.max(this.performanceMetrics.maxUpdateTime, duration)
    
    // Calculate rolling average
    const alpha = 0.1 // Smoothing factor
    this.performanceMetrics.averageUpdateTime = 
      (this.performanceMetrics.averageUpdateTime * (1 - alpha)) + (duration * alpha)
    
    // Log performance warnings
    if (duration > 50) { // More than 50ms
      console.warn(`⚠️ [PERF] ${operationName} took ${duration.toFixed(2)}ms (slow)`)
    } else if (duration > 16) { // More than 16ms (60fps threshold)
      console.log(`📊 [PERF] ${operationName} took ${duration.toFixed(2)}ms`)
    }
  }

  // Clear performance caches to prevent memory leaks
  clearPerformanceCaches() {
    this.lastFilteredIndices = null
    this.lastFilterStateHash = null
    this.lastColorUpdateHash = null
    this.colorUpdateCache.clear()
    this.filterCache.clear()
    this.pendingUpdates.clear()
    
    if (this.updateBatchTimer) {
      clearTimeout(this.updateBatchTimer)
      this.updateBatchTimer = null
    }
    
    console.log('🧹 Performance caches cleared')
  }

  updateCellFiltering(shouldUpdateColors = false) {
    console.log('🔍 [FILTERING] updateCellFiltering called with selectedRanges:', this.selectedRanges)
    // Performance optimization: batch multiple updates
    this.scheduleUpdate('filtering', () => {
      this.performCellFilteringUpdate(shouldUpdateColors)
    })
  }

  // Actual filtering update logic (separated for batching)
  performCellFilteringUpdate(shouldUpdateColors = false) {
    // Use incremental filtering for better performance
    const filteredIndices = this.getIncrementalFilteredIndices()
    //console.log('Filtered indices result:', filteredIndices ? `${filteredIndices.length} cells` : 'null (no filtering)')
    
    // Update the current visible cells state
    this.currentVisibleCells = filteredIndices
    
    // Update current selection to only include visible cells
    this.updateSelectionBasedOnFiltering(filteredIndices)
    
    // Update point count display immediately
    this.updatePointCountDisplay(filteredIndices)
    
    // Update sidebar category counts with visual indicators (for ALL categorical metadata)
    this.updateSidebarCategoryCounts()
    
    // Update all range slider counts to reflect combined filtering (for ALL continuous metadata)
    this.updateAllRangeSliderCounts()
    
    // Update manual selection count to show only visible selected cells
    this.updateSelectedCellsCount()
    
    // Update button state after filtering
    this.updateAddAllVisibleButtonState()
    
    // Use requestAnimationFrame for smooth updates
    requestAnimationFrame(() => {
      // If we need to update colors (e.g., color range adapted), render colors first
      if (shouldUpdateColors && this.currentMetadataVector) {
        this.renderPointsWithCurrentColoring()
      } else {
        // Otherwise just update visibility
        this.updatePointVisibility(filteredIndices)
      }
      
      // Re-render category labels after filtering (ReGL mode only)
      // Labels need to move to new centroids of visible cells
      if (this.rendererType === 'regl' && this.currentMetadataVector?.data_type === 'DISCRETE') {
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked) {
          console.log('🏷️ Re-rendering category labels after filtering (centroids may have moved)')
          // Clear and redraw overlay to ensure old labels are removed
          this.renderGrid()
          this.renderAxes()
          this.renderCategoryLabels()
        }
      }
    })
  }

  // Schedule updates for batching to reduce redundant operations
  scheduleUpdate(updateType, updateFunction) {
    // Add to pending updates
    this.pendingUpdates.add(updateType)
    
    // Clear existing timer
    if (this.updateBatchTimer) {
      clearTimeout(this.updateBatchTimer)
    }
    
    // Schedule batch execution
    this.updateBatchTimer = setTimeout(() => {
      this.executeBatchedUpdates()
    }, 16) // ~60fps
  }

  // Execute all pending updates in a single batch
  executeBatchedUpdates() {
    if (this.pendingUpdates.size === 0) return
    
    const startTime = performance.now()
    console.log('🔄 Executing batched updates:', Array.from(this.pendingUpdates))
    
    // Clear pending updates
    this.pendingUpdates.clear()
    
    // Clear timer
    this.updateBatchTimer = null
    
    // Execute the actual updates
    // Note: This is a simplified version - in practice, you'd want to merge
    // multiple update types intelligently
    this.performCellFilteringUpdate(false)
    
    const duration = performance.now() - startTime
    this.recordPerformanceMetrics('BatchedUpdates', duration)
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
    const hasDiscreteSelections = this.selectedCategories && Object.keys(this.selectedCategories).length > 0
    const hasContinuousSelections = this.selectedRanges && Object.keys(this.selectedRanges).length > 0
    
    console.log('🔍 [FILTERING] getIncrementalFilteredIndices called')
    console.log('🔍 [FILTERING] hasDiscreteSelections:', hasDiscreteSelections)
    console.log('🔍 [FILTERING] hasContinuousSelections:', hasContinuousSelections)
    console.log('🔍 [FILTERING] selectedRanges:', this.selectedRanges)
    
    if (!hasDiscreteSelections && !hasContinuousSelections) {
      // No filtering applied, return all cells
      return null
    }

    // Get all metadata that have selections AND have loaded vectors (categorical)
    const discreteMetadataWithSelections = hasDiscreteSelections 
      ? Object.keys(this.selectedCategories).filter(metadataId => {
      const selections = this.selectedCategories[metadataId]
      const hasSelections = selections && selections.size > 0
      const hasLoadedVector = this.loadedMetadataVectors[metadataId] !== undefined
      return hasSelections && hasLoadedVector
    })
      : []
    
    // Get all metadata that have range selections AND have loaded vectors (continuous)
    const continuousMetadataWithSelections = hasContinuousSelections
      ? Object.keys(this.selectedRanges).filter(metadataId => {
          const range = this.selectedRanges[metadataId]
          const hasRange = range && (range.min !== undefined && range.max !== undefined)
          const hasLoadedVector = this.loadedMetadataVectors[metadataId] !== undefined
          return hasRange && hasLoadedVector
        })
      : []

    // Combine both types of metadata with selections
    const metadataWithSelections = [...new Set([...discreteMetadataWithSelections, ...continuousMetadataWithSelections])]

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
      //console.log(`Single metadata incremental filtering for ${metadataId}`)
      // Use getCellsForMetadata which handles both discrete and continuous metadata
      return this.getCellsForMetadata(metadataId)
    }

    // For multiple metadata, we could implement more sophisticated logic
    // For now, return null to trigger full calculation
    return null
  }

  // Get the intersection of selected cells across all metadata (full calculation)
  getFilteredCellIndices() {
    // Performance optimization: check if filter state has changed
    const currentFilterHash = this.getFilterStateHash()
    console.log('🔍 Filter state check:', {
      currentHash: currentFilterHash,
      lastHash: this.lastFilterStateHash,
      hasCachedIndices: this.lastFilteredIndices !== undefined,
      selectedCategories: this.selectedCategories
    })
    
    if (this.lastFilterStateHash === currentFilterHash && this.lastFilteredIndices !== undefined) {
      console.log('🔍 Using cached filtered indices (no filter state change)')
      return this.lastFilteredIndices
    }
    
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
      // Update performance cache
      this.lastFilteredIndices = null
      this.lastFilterStateHash = currentFilterHash
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
      const hasLoadedVector = this.loadedMetadataVectors[metadataId] !== undefined
      
      if (!hasSelections || !hasLoadedVector) return false
      
      // Check if all categories are selected (no constraint)
      const metadataVector = this.loadedMetadataVectors[metadataId]
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
      const hasLoadedVector = this.loadedMetadataVectors[metadataId] !== undefined
      
      if (!hasRange || !hasLoadedVector) return false
      
      // Check if range covers the full range (no constraint)
      const metadataVector = this.loadedMetadataVectors[metadataId]
      if (metadataVector && metadataVector.values) {
        const values = metadataVector.values
        const minVal = this.safeMin(values)
        const maxVal = this.safeMax(values)
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
      // Update performance cache
      this.lastFilteredIndices = null
      this.lastFilterStateHash = currentFilterHash
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
    
    // Update performance cache
    this.lastFilteredIndices = filteredIndices
    this.lastFilterStateHash = currentFilterHash
    
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
    console.log(`🔍 getCellsForMetadataCategories called for metadata ${metadataId}`)
    console.log(`🔍 Selected categories:`, selectedCategories)
    console.log(`🔍 Selected categories type:`, typeof selectedCategories)
    console.log(`🔍 Selected categories size:`, selectedCategories?.size)
    
    // Find the metadata vector for this metadata ID
    const metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector || !metadataVector.values) {
      console.warn(`No metadata vector found for metadata ID: ${metadataId}`)
      return []
    }
    
    console.log(`🔍 Metadata vector found, values length:`, metadataVector.values.length)

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
    
    // Clear metadata coloring cache when embedding changes
    // This ensures colors are recalculated with correct cell indices
    this._cachedColorMap = null
    this.lastColorUpdateHash = null
    this.colorUpdateCache.clear()
    
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
      // Update usage tracker for current metadata
      this.updateMetadataUsage(metadataId)
      return this.currentMetadataVector
    }
    
    // Check stored metadata vectors in memory
    if (this.loadedMetadataVectors && this.loadedMetadataVectors[metadataId]) {
      const vectorData = this.loadedMetadataVectors[metadataId]
      
      // Update usage tracker
      this.updateMetadataUsage(metadataId)
      
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
    
    // If not found in memory, try to load from disk and cache in memory
    // Load from disk and cache in memory for future use
    this.loadMetadataVectorFromDisk(metadataId).then(vectorData => {
      if (vectorData) {
        // Metadata loaded and cached silently
      }
    }).catch(error => {
      console.error(`💾 [DISK] Failed to load metadata ${metadataId} from disk:`, error)
    })
    
    return null // Return null for now, will be available after async load completes
  }

  // Load metadata vector from disk (IndexedDB) when needed
  async loadMetadataVectorFromDisk(metadataId) {
    // Safety check to prevent infinite loops
    if (!this.loadingCallCount) {
      this.loadingCallCount = new Map()
    }
    
    const currentCount = this.loadingCallCount.get(metadataId) || 0
    if (currentCount > 5) {
      console.error(`🚨 INFINITE LOOP DETECTED for metadata ${metadataId}! Stopping to prevent browser crash.`)
      console.error(`Call stack:`, new Error().stack)
      return null
    }
    
    this.loadingCallCount.set(metadataId, currentCount + 1)
    console.log(`💾 [DISK] loadMetadataVectorFromDisk called for ${metadataId} (call #${currentCount + 1})`)
    
    // Check if already loading to prevent duplicate requests
    if (this.loadingMetadataVectors.has(metadataId)) {
      console.log(`💾 [DISK] Metadata ${metadataId} already loading, waiting...`)
      while (this.loadingMetadataVectors.has(metadataId)) {
        await new Promise(resolve => setTimeout(resolve, 100))
      }
      return this.loadedMetadataVectors[metadataId]
    }
    
    try {
      // Load from IndexedDB
      const vectorData = await this.loadMetadataFromIndexedDB(metadataId)
      
      if (!vectorData) {
        console.warn(`💾 [DISK] Metadata vector not found on disk for ID: ${metadataId}`)
        console.log(`💾 [DISK] Attempting to load metadata ${metadataId} from server as fallback...`)
        
        // Fallback: Try to load from server directly
        try {
          const fallbackData = await this.loadSingleMetadataVectorSilently(metadataId)
          if (fallbackData) {
            console.log(`💾 [DISK] Loaded metadata ${metadataId} from server`)
            return fallbackData
          }
        } catch (error) {
          console.error(`💾 [DISK] Fallback loading failed for metadata ${metadataId}:`, error)
        }
        
        return null
      }
      
      console.log(`💾 [DISK] Loaded metadata ${metadataId} from disk`)
      
      // Decompress the data if needed
      if (!vectorData.values) {
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
        
        // Store in memory for future use (but will be cleaned up by memory optimization)
        this.loadedMetadataVectors[metadataId] = decompressedVector
        
        // Update usage tracker
        this.updateMetadataUsage(metadataId)
        
        // Trigger cleanup if we have too many metadata in memory
        this.cleanupUnusedMetadata()
        
        console.log(`💾 [DISK] Decompressed and cached metadata ${metadataId}: ${values.length} values`)
        return decompressedVector
      }
      
      // If already decompressed, store in memory and return
      this.loadedMetadataVectors[metadataId] = vectorData
      
      // Update usage tracker
      this.updateMetadataUsage(metadataId)
      
      // Trigger cleanup if we have too many metadata in memory
      this.cleanupUnusedMetadata()
      
      return vectorData
      
    } catch (error) {
      console.error(`💾 [DISK] Error loading metadata vector ${metadataId} from disk:`, error)
      return null
    }
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
  // Expand continuous metadata panel and show histogram (no coloring)
  expandContinuousMetadataPanel(metadataId, metadataName) {
    console.log('🎚️ Expanding continuous metadata panel for:', metadataId, metadataName)
    
    const metadataCard = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataCard) {
      console.error('❌ Metadata card not found for ID:', metadataId)
      return
    }
    
    const rangeSection = metadataCard.querySelector('.metadata-range-section')
    const chevron = metadataCard.querySelector('svg')
    
    if (!rangeSection || !chevron) {
      console.error('❌ Range section or chevron not found')
      return
    }
    
    // Expand the panel if not already expanded
    if (rangeSection.style.display !== 'block') {
      rangeSection.style.display = 'block'
      chevron.style.transform = 'rotate(90deg)'
    }
    
    // Initialize the range slider data (just for histogram, no coloring)
    this.toggleInlineRangeSlider(metadataId, metadataName)
  }

  toggleInlineRangeSlider(metadataId, metadataName) {
    console.log('🎚️ Initializing inline range slider for metadata:', metadataId, metadataName)
    
    // Load and initialize the range slider data
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
        
      // Initialize the inline range slider with the loaded values (just the histogram, no coloring)
        this.initializeInlineRangeSlider(metadataId, values)
        
      console.log('🎚️ Inline range slider fully initialized (histogram shown, no coloring applied)')
      }).catch(error => {
        console.error('❌ Error loading metadata for inline range slider:', error)
      })
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
      //console.log('🎚️ Values loaded:', values.length, 'values, range:', this.safeMin(values), 'to', this.safeMax(values))
      
      const minVal = this.safeMin(values)
      const maxVal = this.safeMax(values)
      
      // Update modal content
      document.getElementById('range-slider-metadata-name').textContent = metadataName
      document.getElementById('range-slider-current-range').textContent = `${minVal.toFixed(3)} to ${maxVal.toFixed(3)}`
      
      // Initialize modal range slider
      this.initializeModalRangeSlider(minVal, maxVal, values)
      
      // Show modal
      const modal = document.getElementById('range-slider-modal')
      //console.log('🎚️ Modal element found:', modal)
      if (modal) {
        modal.style.display = 'flex'
        //console.log('🎚️ Modal display set to flex')
        
        // Check computed styles
        const computedStyle = window.getComputedStyle(modal)
        /*console.log('🎚️ Modal computed styles:', {
          display: computedStyle.display,
          visibility: computedStyle.visibility,
          opacity: computedStyle.opacity,
          zIndex: computedStyle.zIndex,
          position: computedStyle.position
        })*/
        
        // Check if modal is actually visible
        //console.log('🎚️ Modal offsetParent:', modal.offsetParent)
        //console.log('🎚️ Modal clientWidth:', modal.clientWidth)
        //console.log('🎚️ Modal clientHeight:', modal.clientHeight)
      } else {
        console.error('❌ Range slider modal not found!')
      }
      
      // Setup event listeners
      this.setupRangeSliderEventListeners()
      
      // Automatically apply the full range to show the visualization
      //console.log('🎚️ Applying full range to visualization...')
      this.setColorRange(minVal, maxVal)
      
      // Show loading spinner
      this.showMetadataDropdownSpinner()
      
      this.loadAndVisualizeMetadataVector(metadataId)
        .catch(error => {
          console.error('❌ Error visualizing metadata:', error)
        })
        .finally(() => {
          this.hideMetadataDropdownSpinner()
        })
      
    }).catch(error => {
      console.error('❌ Error loading metadata for range slider:', error)
      alert('Error loading metadata: ' + error.message)
      this.hideMetadataDropdownSpinner()
    })
  }
  
  // Initialize modal range slider with data
  initializeModalRangeSlider(minVal, maxVal, values) {
    //console.log('🎚️ Initializing range slider with:', { minVal, maxVal, valuesLength: values.length })
    
    this.rangeSliderData = {
      min: minVal,
      max: maxVal,
      values: values,
      currentMin: minVal,
      currentMax: maxVal
    }
    
    // Store globally as fallback in case controller data gets cleared
    window.globalRangeSliderData = this.rangeSliderData
    
    //console.log('🎚️ rangeSliderData set:', this.rangeSliderData)
    //console.log('🎚️ Global fallback also set:', window.globalRangeSliderData)
    
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
    
    const maxCount = this.safeMax(histogram)
    
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
    
    // Show loading spinner
    this.showMetadataDropdownSpinner()
    
    // Load and visualize metadata with the selected range
    this.loadAndVisualizeMetadataVector(this.currentRangeSliderMetadataId)
      .catch(error => {
        console.error('❌ Error visualizing metadata:', error)
      })
      .finally(() => {
        this.hideMetadataDropdownSpinner()
      })
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