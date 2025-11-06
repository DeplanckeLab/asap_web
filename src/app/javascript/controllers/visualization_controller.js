import { Controller } from "@hotwired/stimulus"
import { ReglRenderer } from "visualization/regl_renderer"
import { DataManager } from "visualization/data_manager"
import { ColorManager } from "visualization/color_manager"
import { InteractionHandler } from "visualization/interaction_handler"
import { UIManager } from "visualization/ui_manager"
import { RendererManager } from "visualization/renderer_manager"
import { GradientManager } from "visualization/gradient_manager"
import { MemoryManager } from "visualization/memory_manager"
import { PerformanceManager } from "visualization/performance_manager"
import { DownloadManager } from "visualization/download_manager"
import { GeneManager } from "visualization/gene_manager"
import { CustomPlotManager } from "visualization/custom_plot_manager"

console.log('Visualization controller file loaded - VERSION 3.0 WITH REGL + CATEGORY LABELS')

export default class extends Controller {
  // Only metadataSelect is required, others are optional
  static targets = ["metadataSelect"]
  static values = { 
    embeddingsByLoom: Object,
    defaultLoomFile: String
  }
  
  // Optional targets - manually check with querySelector
  get loomFileSelectTarget() {
    return this.element.querySelector('[data-visualization-target="loomFileSelect"]')
  }
  
  get hasLoomFileSelectTarget() {
    return !!this.loomFileSelectTarget
  }
  
  get embeddingSelectTarget() {
    return this.element.querySelector('[data-visualization-target="embeddingSelect"]')
  }
  
  get hasEmbeddingSelectTarget() {
    return !!this.embeddingSelectTarget
  }

  // Helper method to get project identifier from URL (supports ID, key, or public_id)
  getProjectIdentifier() {
    const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
    return pathMatch ? pathMatch[1] : null
  }

  connect() {
    // Generate unique ID for this controller instance
    this.instanceId = Math.random().toString(36).substring(7)
    console.log(`🚀 Visualization controller connected - Instance ID: ${this.instanceId}`)
    console.trace(`🚀 Visualization controller connect() call stack:`)
    
    // Check if this is a reconnection (modules already initialized)
    const isReconnection = this.dataManager && this.geneManager && this.memoryManager
    
    // Check if renderer already exists with state before initializing canvas
    if (this.reglRenderer) {
      const hasState = this.reglRenderer.numPoints > 0 || 
                       (this.reglRenderer.positions && this.reglRenderer.positions.length > 0) ||
                       (this.reglRenderer.colors && this.reglRenderer.colors.length > 0)
      console.log(`🚀 [CONNECT] Renderer already exists:`, {
        rendererInstanceId: this.reglRenderer.instanceId,
        hasState: hasState,
        numPoints: this.reglRenderer.numPoints,
        hasPositions: !!this.reglRenderer.positions,
        hasColors: !!this.reglRenderer.colors,
        isReconnection: isReconnection
      })
      
      if (hasState && isReconnection) {
        console.log(`🚀 [CONNECT] Reconnection detected with renderer state - skipping initializeCanvas() to preserve state`)
        // Don't call initializeCanvas() if renderer already has state and modules are initialized
        // This prevents destroying the renderer during Stimulus reconnection
        return // Skip the rest of connect() initialization that might recreate the renderer
      }
    }
    
    // DEBUG: Add direct event listener to measure Stimulus overhead
    setTimeout(() => {
      const metadataHeaders = document.querySelectorAll('[data-action*="toggleMetadata"]')
      console.log(`🔍 [DEBUG] Found ${metadataHeaders.length} metadata headers with toggleMetadata action`)
      
      metadataHeaders.forEach((header, index) => {
        if (index === 0) { // Only instrument the first one for testing
          header.addEventListener('click', (e) => {
            const directCallTime = performance.now()
            console.log(`⚡ [DIRECT] Direct listener called at: ${directCallTime.toFixed(2)}ms (event timestamp: ${e.timeStamp.toFixed(2)}ms)`)
            console.log(`⚡ [DIRECT] Direct listener delay: ${(directCallTime - e.timeStamp).toFixed(2)}ms`)
          }, { capture: true }) // Use capture to run BEFORE Stimulus
        }
      })
    }, 1000)
    
    // Initialize modules
    this.dataManager = new DataManager(this)
    this.colorManager = new ColorManager(this)
    this.rendererManager = new RendererManager(this)
    this.interactionHandler = new InteractionHandler(this, this.rendererManager)
    this.uiManager = new UIManager(this)
    this.gradientManager = new GradientManager(this)
    this.memoryManager = new MemoryManager(this)
    this.performanceManager = new PerformanceManager(this)
    this.downloadManager = new DownloadManager(this)
    this.geneManager = new GeneManager(this)
    this.customPlotManager = new CustomPlotManager(this)
    
    // RENDERER CHOICE: 'regl' only
    this.rendererType = 'regl' // 🎯 Using ReGL for better performance
    // CRITICAL: Don't overwrite existing renderer if it has state
    // Only initialize to null if it doesn't exist
    if (this.reglRenderer === undefined) {
    this.reglRenderer = null // Will hold ReGL renderer instance
    }
    this.pixiApp = null // Not used, kept for compatibility
    
    // Initialize canvas and renderer (only if renderer doesn't already have state)
    // This check is now in connect() above, but we still need to call it if renderer doesn't exist or has no state
    if (!this.reglRenderer || 
        (this.reglRenderer.numPoints === 0 && 
         (!this.reglRenderer.positions || this.reglRenderer.positions.length === 0) &&
         (!this.reglRenderer.colors || this.reglRenderer.colors.length === 0))) {
    this.initializeCanvas()
    } else {
      console.log(`🚀 [CONNECT] Skipping initializeCanvas() - renderer has state`)
    }
    
    // Initialize IndexedDB for storing metadata on disk instead of memory
    this.memoryManager.initializeIndexedDB()
    
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
    
    // Color cache for visibility updates (performance optimization)
    this.cachedColorsByCellIndex = new Map() // Cache colors by cell index for fast lookup
    this.lastColoringMetadataId = null // Track which metadata was used for last color calculation
    this.lastColorRange = null // Track color range for continuous metadata
    
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
    
    // Initialize resize handling
    this.resizeHandler = this.handleWindowResize.bind(this)
    this.resizeTimeout = null
    this.isResizing = false
    
    // Performance optimization: store existing points for visibility updates and fast color switching
    this.pointSprites = null // Array of sprite objects for fast updates (replaces existingPoints)
    this.pointTexture = null // Shared texture for all point sprites
    this.lastMetadataVector = null // Track last metadata for optimization
    this.lastPointSize = null // Track last point size for optimization
    this.visibilityOnlyUpdate = false // When true, try to only toggle visibility
    this.spritesRenderType = null // Track what type of rendering created current sprites: 'discrete', 'numeric', or 'default'
    
    // Track selected x and y buttons for 2D plot modal
    this.selectedXButton = null
    this.selectedYButton = null
    
    // Cache for decompressed embedding coordinates (avoid re-decompressing)
    this.decompressedCoordinatesCache = new Map() // Key: embeddingId, Value: decompressed coordinates
    
    // Cache for binary embedding data (avoid re-fetching from network)
    this.binaryDataCache = new Map() // Key: embeddingId, Value: { name, cellCount, binaryData }
    
    // Expose controller globally for range slider access
    // CRITICAL: Only overwrite window.visualizationController if:
    // 1. It doesn't exist yet, OR
    // 2. The existing one has no state (was never initialized), OR  
    // 3. This instance has state (preserve the one with state)
    const existingController = window.visualizationController
    const existingHasState = existingController?.reglRenderer?.numPoints > 0 || 
                             (existingController?.reglRenderer?.positions && existingController.reglRenderer.positions.length > 0) ||
                             (existingController?.reglRenderer?.colors && existingController.reglRenderer.colors.length > 0)
    const thisHasState = this.reglRenderer?.numPoints > 0 || 
                         (this.reglRenderer?.positions && this.reglRenderer.positions.length > 0) ||
                         (this.reglRenderer?.colors && this.reglRenderer.colors.length > 0)
    
    if (!existingController || !existingHasState || thisHasState) {
      // Only set if no existing controller, or existing has no state, or this one has state
      if (existingController && existingHasState && !thisHasState) {
        console.log('🚀 [CONNECT] Preserving existing visualization controller with state in window.visualizationController')
        console.log('🚀 [CONNECT] Existing renderer ID:', existingController.reglRenderer?.instanceId)
        console.log('🚀 [CONNECT] This renderer ID:', this.reglRenderer?.instanceId || 'none')
        // Don't overwrite - keep the existing one
      } else {
    window.visualizationController = this
        console.log('🚀 [CONNECT] Set window.visualizationController to this instance')
      }
    } else {
      console.log('🚀 [CONNECT] Keeping existing visualization controller with state in window.visualizationController')
      console.log('🚀 [CONNECT] Existing renderer ID:', existingController.reglRenderer?.instanceId)
    }
    
    // Expose emergency diagnostic function
    window.runEmergencyDiagnostic = () => this.performanceManager.runEmergencyDiagnostic()
    
    // Expose metadata status checking functions for debugging
    window.checkMetadataStatus = () => this.checkAllMetadataStatusBeforePreload()
    window.checkSpecificMetadataStatus = (metadataId) => this.checkSpecificMetadataStatus(metadataId)
    
    // Expose cell count debugging function
    window.getCellCount = () => {
      const cellCount = this.getCellCountFromServerData()
      console.log(`🔍 [DEBUG] Current cell count: ${cellCount.toLocaleString()}`)
      console.log(`🔍 [DEBUG] Current buffer size: ${this.maxMetadataInMemory}`)
      console.log(`🔍 [DEBUG] EmbeddingsByLoomValue:`, this.embeddingsByLoomValue)
      return cellCount
    }
    
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
          this.colorManager.clearCategoryColorsCache()
        } else {
          console.error('Still no colors after delay')
        }
      }, 1000)
    } else {
      //console.log('Global colors are available!')
      // Clear cache to get fresh colors
      this.colorManager.clearCategoryColorsCache()
    }
    
    // Set the default loom file selection
    // Stimulus will automatically set this.loomFileSelectTarget
    console.log('🔍 [DEBUG] Loom file select target found:', !!this.loomFileSelectTarget)
    if (this.loomFileSelectTarget) {
      console.log('🔍 [DEBUG] Loom file select target value:', this.loomFileSelectTarget.value)
    }
    
    console.log('🔍 [DEBUG] Loom file setup in connect:', {
      hasDefaultLoomFileValue: this.hasDefaultLoomFileValue,
      hasLoomFileSelectTarget: !!this.loomFileSelectTarget,
      defaultLoomFileValue: this.defaultLoomFileValue,
      loomFileSelectTarget: this.loomFileSelectTarget,
      hasEmbeddingsByLoomValue: this.hasEmbeddingsByLoomValue,
      embeddingsByLoomValue: this.embeddingsByLoomValue
    })
    
    // Get the loom file from the form selection, not a hardcoded fallback
    let loomFileToUse = null
    
    // First, try to get from the form selection
    if (this.loomFileSelectTarget && this.loomFileSelectTarget.value) {
      loomFileToUse = this.loomFileSelectTarget.value
      console.log('🔍 [DEBUG] Using loom file from form selection:', loomFileToUse)
    }
    // Then try the default value
    else if (this.defaultLoomFileValue) {
      loomFileToUse = this.defaultLoomFileValue
      console.log('🔍 [DEBUG] Using loom file from default value:', loomFileToUse)
    }
    // Only use fallback if nothing else is available
    else {
      loomFileToUse = 'parsing/output.loom'
      console.log('🔍 [DEBUG] Using loom file fallback:', loomFileToUse)
    }
    
    this.currentLoomFile = loomFileToUse
    console.log('🔍 [DEBUG] Final loom file set:', this.currentLoomFile)
    
    // Ensure embeddingsByLoomValue is not null
    if (!this.embeddingsByLoomValue) {
      this.embeddingsByLoomValue = {}
      console.log('🔍 [DEBUG] Set empty embeddingsByLoomValue as fallback')
    }
    
    // If we also have a target, set its value and add change listener
    if (this.loomFileSelectTarget) {
      this.loomFileSelectTarget.value = loomFileToUse
      console.log('🔍 [DEBUG] Set loom file target value:', this.loomFileSelectTarget.value)
      
      // Debug: Check what options are available
      console.log('🔍 [DEBUG] Loom file select options:', Array.from(this.loomFileSelectTarget.options).map(opt => ({
        value: opt.value,
        text: opt.text,
        selected: opt.selected
      })))
      
      // Add change listener to update currentLoomFile when user changes selection
      this.loomFileSelectTarget.addEventListener('change', (event) => {
        this.currentLoomFile = event.target.value
        console.log('🔍 [DEBUG] Loom file changed to:', this.currentLoomFile)
        this.uiManager.updateEmbeddings()
      })
      
      this.uiManager.updateEmbeddings()
      
      // Auto-load the first available embedding on page load
      setTimeout(() => {
        if (this.hasMetadataSelectTarget) {
          const firstOption = this.metadataSelectTarget.querySelector('option[value]:not([value=""])')
          if (firstOption) {
            console.log('🚀 Auto-loading first embedding on page load:', firstOption.textContent)
            this.metadataSelectTarget.value = firstOption.value
            this.uiManager.updateMetadata()
          }
        }
      }, 100) // Small delay to ensure DOM is ready
    } else {
      console.log('🔍 [DEBUG] No loom file select target available, but using fallback value')
    }
    
    // Add click outside listener to close dropdowns
    this.boundCloseDropdowns = this.closeAllDropdowns.bind(this)
    document.addEventListener('click', this.boundCloseDropdowns)
    
    // Initialize draggable dividers
    setTimeout(() => {
      this.initializeDraggableDivider() // Metadata divider
      this.initializeRightPanelDivider() // Gene Expression / Selections divider
    }, 500)
    
    // Add window resize listener
    window.addEventListener('resize', this.resizeHandler)
    
    // Initialize metadata vectors storage
    console.log('🚨 [DEBUG] Initializing loadedMetadataVectors = {} in connect()')
    console.trace('Call stack:')
    this.loadedMetadataVectors = {}
    this.loadingMetadataVectors = new Set() // Track which vectors are currently loading
    
    // Store gradients per metadata ID (metadataId -> { gradientControlPoints, customGradientControlPoints })
    this.metadataGradients = new Map()
    
    // Memory management for metadata vectors
    this.metadataUsageTracker = new Map() // Track when metadata was last accessed
    this.maxMetadataInMemory = 5 // Default buffer size, will be adjusted based on dataset size
    
    // Initialize interaction mode state
    this.interactionMode = 'pan' // 'pick', 'pan', 'lasso', or 'zoom'
    this.selectedCells = new Set()
    this.originalPointColors = new Map() // Store original colors for reset functionality
    this.draggingLabel = null // Track which label is being dragged
    this.clickingOnLabel = false // Track if we're clicking on a label
    //console.log(`Initializing currentPointSize to: 1.0 (was: ${this.currentPointSize})`)
    this.currentPointSize = 8.0 // Store current point size for consistent rendering (increased for debugging)
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
    this.lastTooltipPosition = null // Last position of the fixed tooltip
    
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
      this.uiManager.initializeTooltip()
      this.initializeResizers()
      // Initialize the selection count display
      this.uiManager.updateSelectedCellsCount()
    }, 100)
    
    // Create diagnostic button after a delay (fallback in case preloading doesn't complete)
    setTimeout(() => {
      this.performanceManager.createDiagnosticButton()
    }, 3000) // Wait 3 seconds after connection
    
    // Start automatic preloading if enabled
    if (this.autoPreloadMetadata) {
      console.log('🚀 Starting automatic metadata preloading...')
      console.log('🔍 [DEBUG] Loom file state before preloading:', {
        currentLoomFile: this.currentLoomFile,
        defaultLoomFileValue: this.defaultLoomFileValue,
        hasLoomFileSelectTarget: this.hasLoomFileSelectTarget,
        loomFileSelectValue: this.loomFileSelectTarget?.value,
        embeddingsByLoomValue: !!this.embeddingsByLoomValue
      })
      
      // Add a small delay to ensure loom file is set, then check all metadata status before preloading
      setTimeout(async () => {
        try {
          // Check status of all metadata before preloading
          await this.checkAllMetadataStatusBeforePreload()
          
          // Then start preloading (wait for it to complete)
          await this.preloadAllMetadata()
        } catch (error) {
          console.log('Background metadata preload encountered an error:', error)
        }
      }, 200) // Slightly longer delay to ensure UI is fully ready
    }
  }

  disconnect() {
    // Remove click outside listener when controller disconnects
    if (this.boundCloseDropdowns) {
      document.removeEventListener('click', this.boundCloseDropdowns)
    }
    
    // Remove window resize listener
    if (this.resizeHandler) {
      window.removeEventListener('resize', this.resizeHandler)
    }
    
    // Remove interaction event listeners
    this.removeInteractionEventListeners()
    
    // Clean up any existing PIXI app
    if (this.pixiApp) {
      this.pixiApp.destroy(true)
      this.pixiApp = null
    }
  }
  
  // Delegates to ui_manager to avoid duplication
  updateMetadata() {
    this.uiManager.updateMetadata()
  }

  async loadMetadataCoordinates(metadataId) {
    const fetchStart = performance.now()
    
    try {
      // Check in-memory cache first!
      if (this.binaryDataCache.has(metadataId)) {
        console.log(`⏱️ [PERF] Step 1: BINARY CACHE HIT - Skipping network fetch for ${metadataId}`)
        const cachedData = this.binaryDataCache.get(metadataId)
        const cacheTime = performance.now() - fetchStart
        console.log(`⏱️ [PERF] Step 1: Binary cache retrieval: ${cacheTime.toFixed(2)}ms (saved ~5s download!)`)
        
        // Use cached binary data
        this.dataManager.storeBinaryMetadataData(cachedData)
        return
      }
      
      // Check IndexedDB (disk storage) for embeddings - this is the key fix!
      console.log(`⏱️ [PERF] Step 1a: Checking IndexedDB for coordinates ${metadataId}...`)
      const diskData = await this.memoryManager.loadCoordinatesFromIndexedDB(metadataId)
      if (diskData) {
        const diskTime = performance.now() - fetchStart
        console.log(`⏱️ [PERF] Step 1a: IndexedDB HIT for ${metadataId} - ${diskTime.toFixed(2)}ms (saved network fetch!)`)
        
        // Store in memory cache for next time
        this.binaryDataCache.set(metadataId, diskData)
        
        // Use cached binary data
        this.dataManager.storeBinaryMetadataData(diskData)
        return
      }
      
      console.log(`⏱️ [PERF] Step 1b: IndexedDB MISS - Starting network fetch for ${metadataId}`)
      
      // Get the current loom file selection
      const loomFile = this.getCurrentLoomFileForRequest()
      
      // Build the URL for the metadata coordinates endpoint
      const projectIdentifier = this.getProjectIdentifier()
      const url = `/projects/${encodeURIComponent(projectIdentifier)}/metadata_coordinates?metadata_id=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
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
      
      // Cache binary data in memory for instant retrieval next time
      this.binaryDataCache.set(metadataId, dataObject)
      console.log(`⏱️ [PERF] Cached binary data in memory for ${metadataName} (${(arrayBuffer.byteLength / 1024).toFixed(1)}KB)`)
      
      // Also store in IndexedDB (disk) for persistent cache across page reloads!
      this.memoryManager.storeCoordinatesInIndexedDB(metadataId, dataObject).catch(error => {
        console.warn('Failed to store coordinates in IndexedDB:', error)
      })
      console.log(`⏱️ [PERF] Stored coordinates in IndexedDB for ${metadataName} (will survive page reload)`)
      
      // Store the binary coordinate data
      this.dataManager.storeBinaryMetadataData(dataObject)
      
    } catch (error) {
      console.error('Error loading metadata coordinates:', error)
      alert(`Failed to load metadata coordinates: ${error.message}`)
    }
  }

  // Silent version of loadMetadataCoordinates - only caches without displaying
  async loadMetadataCoordinatesSilently(metadataId, metadataName = 'unknown') {
    try {
      // Check memory cache first - if already cached, nothing to do
      if (this.binaryDataCache.has(metadataId)) {
        return { success: true, cached: true }
      }
      
      // Check IndexedDB (disk storage) for embeddings
      const diskData = await this.memoryManager.loadCoordinatesFromIndexedDB(metadataId)
      if (diskData) {
        console.log(`  ✅ Loaded from IndexedDB: ${metadataName}`)
        // Store in memory cache for next time
        this.binaryDataCache.set(metadataId, diskData)
        return { success: true, cached: true }
      }
      
      // Get the current loom file selection
      const loomFile = this.getCurrentLoomFileForRequest()
      
      // Build the URL for the metadata coordinates endpoint
      const projectIdentifier = this.getProjectIdentifier()
      const url = `/projects/${encodeURIComponent(projectIdentifier)}/metadata_coordinates?metadata_id=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
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
      
      // Cache binary data in memory (but DON'T call storeBinaryMetadataData - that would display it)
      this.binaryDataCache.set(metadataId, dataObject)
      
      // Also store in IndexedDB (disk) for persistent cache
      this.memoryManager.storeCoordinatesInIndexedDB(metadataId, dataObject).catch(error => {
        console.warn('Failed to store coordinates in IndexedDB:', error)
      })
      
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




  async renderScatterPlot(coordinates) {

    if (!this.reglRenderer) return
    
    const startTime = performance.now()
    console.log(`🎯 [ReGL] Rendering ${coordinates.length.toLocaleString()} points...`)
    
    // Calculate bounds for normalization
    const originalBounds = this.dataManager.calculateBounds(coordinates)
    //const bounds = originalBounds
    this.currentBounds = originalBounds
    // ALWAYS preserve currentCoordinates - this is critical for filtering
    this.currentCoordinates = coordinates
    console.log(`🎯 [ReGL] Stored currentCoordinates: ${coordinates.length} points`)
    
    // Reset ordering flags so they'll be reapplied for this new embedding
    this._lastCategoryOrderApplied = null
    this._lastNumericOrderApplied = null
    this._lastNumericMetadataId = null // Track which metadata the ordering was applied to
    
    // Initialize display order array (identity mapping initially)
    // displayOrder[drawPosition] = originalCellIndex
    this.displayOrder = new Array(coordinates.length)
    for (let i = 0; i < coordinates.length; i++) {
      this.displayOrder[i] = i
    }
    
    // Flag that display order was reset - color cache needs to rebuild colorMap from originalPointColors
    this._displayOrderWasReset = true
    
    console.log(`🎯 [ReGL] Initialized display order (identity: 0, 1, 2, ...)`)
    
    // Normalize coordinates to screen space (0 to canvas size)
    const canvas = this.canvas
    const screenCoordinates = new Float32Array(coordinates.length * 2)
    
    for (let i = 0; i < coordinates.length; i++) {
      const [x, y] = coordinates[i]
      screenCoordinates[i * 2] = this.interactionHandler.normalizeX(x, originalBounds)
      screenCoordinates[i * 2 + 1] = this.interactionHandler.normalizeY(y, originalBounds)
    }
    
    console.log('🔍 DEBUG: Coordinate normalization:', {
      numPoints: coordinates.length,
      bounds: originalBounds,
      canvasSize: { width: this.canvas.width, height: this.canvas.height },
      firstFewCoords: coordinates.slice(0, 3),
      firstFewScreenCoords: Array.from(screenCoordinates.slice(0, 6))
    })
    
    // Set positions in ReGL renderer
    this.reglRenderer.setPositions(screenCoordinates)
    
    // Set initial point size
    this.reglRenderer.setPointSize(this.currentPointSize || 4)
    
    // Render first frame
    console.log('🔍 DEBUG: About to render first frame')
    this.reglRenderer.render()
    console.log('🔍 DEBUG: First frame rendered')
    
    // Render grid and axes using PixiJS overlay
    this.rendererManager.renderGrid()
    this.rendererManager.renderAxes()
    this.rendererManager.renderCategoryLabels() // ✅ Category labels work in ReGL mode!
    
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


  
  // Used by showTooltip and renderCategoryLabels
  // FIXED: Now correctly identifies which metadata is used for coloring vs filtering
  // This prevents new dots from appearing with wrong colors when filtering constraints are relaxed














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
      const loomFile = this.getCurrentLoomFileForRequest()
      
      // Build the URL for the metadata vectors endpoint (single request for all)
      const projectIdentifier = this.getProjectIdentifier()
      const url = `/projects/${encodeURIComponent(projectIdentifier)}/metadata_vectors?metadata_ids=${metadataIds.join(',')}&loom_file=${encodeURIComponent(loomFile || '')}`
      
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
      const loomFile = this.getCurrentLoomFileForRequest()
      
      // Special debugging for sex and age metadata
      const metadataName = this.dataManager.getMetadataNameById(metadataId)
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
      const projectIdentifier = this.getProjectIdentifier()
      const url = `/projects/${encodeURIComponent(projectIdentifier)}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
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
        
        // Update status icon to show it's in memory (green check)
        console.log(`🔍 [MEMORY] Metadata ${metadataId} loaded to memory in loadSingleMetadataVector - setting to green`)
        this.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
        
        const info = vectorData.compression_info
        //console.log(`Successfully loaded metadata ${vectorData.name} silently (${info.type}): ${info.binary_size} bytes, ${info.compression_ratio}x compression`)
        
        // THEN: Store in IndexedDB for disk storage (fire and forget)
        this.memoryManager.storeMetadataInIndexedDB(metadataId, vectorData).catch(error => {
          console.warn('Failed to store in IndexedDB:', error)
        })
        
        // Show checkboxes for this metadata now that it's loaded
        this.uiManager.showCheckboxesForMetadata(metadataId)
        
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




  // Update metadata usage tracker

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
        const transaction = this.db.transaction(['metadata'], 'readonly')
        const objectStore = transaction.objectStore('metadata')
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


  // Clean up unused metadata from memory

  // Preload metadata vector directly to disk (IndexedDB) without keeping in memory
  async preloadMetadataToDisk(metadataId) {
    console.log(`💾 [DISK] Preloading metadata ${metadataId} directly to disk...`)
    
    // Check if already stored on disk
    const existingData = await this.memoryManager.loadMetadataFromIndexedDB(metadataId)
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
      console.log(`🔍 [DEBUG] Starting preloadMetadataToDisk for metadata ${metadataId}`)
      
      // Use the original logic from the working version
      const loomFile = this.getCurrentLoomFileForRequest()
      
      console.log(`🔍 [DEBUG] Using original loom file logic: loomFile="${loomFile}"`)
      
      if (!loomFile) {
        throw new Error(`No loom file available for metadata ${metadataId}`)
      }
      
      console.log(`🔍 [DEBUG] Loom file detection for metadata ${metadataId}:`, {
        currentLoomFile: this.currentLoomFile,
        defaultLoomFileValue: this.defaultLoomFileValue,
        loomFileSelectTarget: !!this.loomFileSelectTarget,
        loomFileSelectValue: this.loomFileSelectTarget?.value,
        embeddingsByLoomValue: !!this.embeddingsByLoomValue,
        availableLoomFiles: this.embeddingsByLoomValue ? Object.keys(this.embeddingsByLoomValue) : [],
        finalLoomFile: loomFile
      })
      
      if (!loomFile) {
        throw new Error(`No loom file available for metadata ${metadataId}. Available loom files: ${this.embeddingsByLoomValue ? Object.keys(this.embeddingsByLoomValue).join(', ') : 'none'}. This should not happen with the fallback logic.`)
      }
      
      // Build the URL for the single metadata vector endpoint
      const projectIdentifier = this.getProjectIdentifier()
      const url = `/projects/${encodeURIComponent(projectIdentifier)}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile)}`
      
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
        const storeSuccess = await this.memoryManager.storeMetadataInIndexedDB(metadataId, vectorData)
        
        if (storeSuccess) {
          const info = vectorData.compression_info
          console.log(`💾 [DISK] Successfully stored metadata ${vectorData.name} to disk (${info.type}): ${info.binary_size} bytes`)
          
          // Update status icon to show it's in database (orange check)
          const orangeTime = performance.now()
          console.log(`🔍 [DISK] Setting ${metadataId} to in-db (orange) after disk storage at ${orangeTime.toFixed(2)}ms`)
          console.log(`🔍 [DEBUG] Disk storage completed for metadata ${metadataId} (${vectorData.name})`)
          this.uiManager.updateMetadataStatusIcon(metadataId, 'in-db')
          
          // Show checkboxes for this metadata now that it's available on disk
          this.uiManager.showCheckboxesForMetadata(metadataId)
          
          return { success: true, cached: false, size: info.binary_size, orangeTime: orangeTime }
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
    const memoryInfo = this.memoryManager.logMemoryUsage('Performance Assessment')
    
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
          largestMetadata = { id, name: this.dataManager.getMetadataNameById(id), size }
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
    this.memoryManager.cleanupUnusedMetadata()
    
    console.log(`🔧 [PERF] LRU-based memory optimization complete`)
    console.log(`  📊 Buffer size: ${this.maxMetadataInMemory} metadata vectors`)
    console.log(`  💾 All metadata is available on disk via IndexedDB`)
    console.log(`  🧠 LRU system automatically manages memory usage`)
    
    // Log memory usage after optimization
    setTimeout(() => {
      this.memoryManager.logMemoryUsage('After LRU memory optimization')
    }, 1000)
  }

  // Get current loom file with consistent handling of empty strings
  getCurrentLoomFile() {
    const loomFile = this.currentLoomFile || this.loomFileSelectTarget?.value || this.defaultLoomFileValue
    
    // Debug logging to help identify the issue
    if (loomFile === '') {
      console.warn('⚠️ [DEBUG] Loom file is empty string!', {
        currentLoomFile: this.currentLoomFile,
        loomFileSelectValue: this.loomFileSelectTarget?.value,
        defaultLoomFileValue: this.defaultLoomFileValue,
        hasLoomFileSelectTarget: this.hasLoomFileSelectTarget,
        loomFileSelectOptions: this.loomFileSelectTarget ? Array.from(this.loomFileSelectTarget.options).map(opt => ({ value: opt.value, text: opt.text, selected: opt.selected })) : 'N/A'
      })
    }
    
    // Normalize empty string to null for consistent comparison
    return loomFile === '' ? null : loomFile
  }

  // Get current loom file for requests (no fallback - let errors be visible)
  getCurrentLoomFileForRequest() {
    const loomFile = this.getCurrentLoomFile()
    if (!loomFile) {
      console.error('❌ [ERROR] No loom file available for request!', {
        currentLoomFile: this.currentLoomFile,
        loomFileSelectValue: this.loomFileSelectTarget?.value,
        defaultLoomFileValue: this.defaultLoomFileValue,
        hasLoomFileSelectTarget: this.hasLoomFileSelectTarget
      })
      throw new Error('No loom file available for request - check loom file selection')
    }
    return loomFile
  }

  // Get cell count from server-side data (embeddingsByLoomValue)
  getCellCountFromServerData() {
    // Try to get cell count from embeddingsByLoomValue first
    if (this.embeddingsByLoomValue) {
      const currentLoom = this.getCurrentLoomFile() || this.defaultLoomFileValue
      const loomData = this.embeddingsByLoomValue[currentLoom]
      
      if (loomData && Array.isArray(loomData) && loomData.length > 0) {
        // Get the first embedding to check its cell count
        const firstEmbedding = loomData[0]
        if (firstEmbedding && firstEmbedding.cellCount) {
          console.log(`🧠 [Memory] Found cell count from embeddingsByLoomValue: ${firstEmbedding.cellCount.toLocaleString()}`)
          return firstEmbedding.cellCount
        }
      }
    }
    
    // Fallback: try to get from any loaded metadata
    if (this.currentCoordinates && this.currentCoordinates.length > 0) {
      console.log(`🧠 [Memory] Using cell count from current coordinates: ${this.currentCoordinates.length.toLocaleString()}`)
      return this.currentCoordinates.length
    }
    
    // Fallback: try to get from metadataData
    if (this.metadataData && this.metadataData.cellCount) {
      console.log(`🧠 [Memory] Using cell count from metadataData: ${this.metadataData.cellCount.toLocaleString()}`)
      return this.metadataData.cellCount
    }
    
    console.log(`🧠 [Memory] No cell count available from server data`)
    return 0
  }

  // Check if metadata is already stored in IndexedDB (optimized for speed)
  async checkMetadataInDatabase(metadataId) {
    if (!this.db) {
      return false
    }

    try {
      const transaction = this.db.transaction(['metadata'], 'readonly')
      const objectStore = transaction.objectStore('metadata')
      const numericMetadataId = parseInt(metadataId)
      const getRequest = objectStore.get(numericMetadataId)
      
      return new Promise((resolve) => {
        getRequest.onsuccess = () => {
          if (getRequest.result) {
            // Check if the loom file matches (for cache invalidation)
            const currentLoom = this.getCurrentLoomFile()
            const storedLoom = getRequest.result.loomFile
            
            // Handle both null values (empty strings) as equivalent
            const storedLoomNormalized = storedLoom === '' ? null : storedLoom
            if (storedLoomNormalized === currentLoom) {
              resolve(true)
            } else {
              resolve(false) // Wrong loom file, treat as not cached
            }
          } else {
            resolve(false) // Not found in database
          }
        }
        getRequest.onerror = () => {
          resolve(false) // Assume not in database if error occurs
        }
      })
    } catch (error) {
      return false
    }
  }

  // Check status of all metadata before preloading starts
  async checkAllMetadataStatusBeforePreload() {
    console.log('🔍 [STATUS] Checking status of all metadata before preloading...')
    
    try {
      // Get all metadata buttons from the UI
      let metadataButtons = document.querySelectorAll('button[data-metadata-id]')
      
      // If no buttons found, wait a bit and try again (UI might not be ready yet)
      if (metadataButtons.length === 0) {
        console.log('🔍 [STATUS] No metadata buttons found yet, waiting 500ms and retrying...')
        await new Promise(resolve => setTimeout(resolve, 500))
        metadataButtons = document.querySelectorAll('button[data-metadata-id]')
        
        if (metadataButtons.length === 0) {
          console.log('🔍 [STATUS] Still no metadata buttons found, skipping status check')
          return
        }
      }

      console.log(`🔍 [STATUS] Checking status for ${metadataButtons.length} metadata items before preloading...`)
      
      // Process all metadata status checks in parallel since DB checks are now instant
      const startTime = performance.now()
      const allPromises = Array.from(metadataButtons).map(button => this.checkSingleMetadataStatus(button))
      await Promise.all(allPromises)
      const endTime = performance.now()
      
      console.log(`🔍 [STATUS] Completed status check for all ${metadataButtons.length} metadata items in ${(endTime - startTime).toFixed(2)}ms`)
      
      console.log('🔍 [STATUS] Completed status check for all metadata before preloading')
    } catch (error) {
      console.error('Error in metadata status checking before preload:', error)
    }
  }

  // Check status of a single metadata item and update its icon
  async checkSingleMetadataStatus(button) {
    const metadataId = button.dataset.metadataId
    if (!metadataId) return

    try {
      // Check if metadata is in memory first (fastest check)
      const isInMemory = this.dataManager.getMetadataVectorById(metadataId)
      if (isInMemory) {
        console.log(`🔍 [STATUS] Metadata ${metadataId} found in memory - setting to green`)
        this.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
        return
      }

      // Check if metadata is in database (IndexedDB) - now optimized for speed
      const dbCheckStart = performance.now()
      const isInDatabase = await this.checkMetadataInDatabase(metadataId)
      const dbCheckTime = performance.now() - dbCheckStart
      
      if (isInDatabase) {
        console.log(`🔍 [STATUS] Metadata ${metadataId} found in database but not in memory - setting to orange`)
        this.uiManager.updateMetadataStatusIcon(metadataId, 'in-db')
        return
      }

      // Metadata is not loaded anywhere
      this.uiManager.updateMetadataStatusIcon(metadataId, 'not-loaded')
    } catch (error) {
      console.error(`Error checking status for metadata ${metadataId}:`, error)
      this.uiManager.updateMetadataStatusIcon(metadataId, 'not-loaded')
    }
  }

  // Check status for a specific metadata item and update its icon immediately
  async checkSpecificMetadataStatus(metadataId) {
    const button = document.querySelector(`button[data-metadata-id="${metadataId}"]`)
    if (button) {
      await this.checkSingleMetadataStatus(button)
    }
  }

  // Preload all metadata (embeddings + metadata vectors) for instant switching
  async preloadAllMetadata() {
    console.log('🚀 [PERF] Starting background preload of all metadata...')
    
    // Debug loom file state at start of preloading
    console.log('🔍 [DEBUG] Loom file state at preload start:', {
      currentLoomFile: this.currentLoomFile,
      defaultLoomFileValue: this.defaultLoomFileValue,
      hasLoomFileSelectTarget: this.hasLoomFileSelectTarget,
      loomFileSelectValue: this.loomFileSelectTarget?.value,
      embeddingsByLoomValue: !!this.embeddingsByLoomValue,
      availableLoomFiles: this.embeddingsByLoomValue ? Object.keys(this.embeddingsByLoomValue) : []
    })
    
    // Get cell count from server-side data for accurate buffer size calculation
    const cellCount = this.getCellCountFromServerData()
    
    // Calculate and set optimal buffer size based on dataset characteristics
    this.maxMetadataInMemory = this.memoryManager.calculateOptimalBufferSize(cellCount)
    console.log(`🧠 [Memory] Set memory buffer size to ${this.maxMetadataInMemory} metadata vectors`)
    if (cellCount > 0) {
      console.log(`🧠 [Memory] Used cell count from server data: ${cellCount.toLocaleString()}`)
    }
    
    // Separate metadata by type for ordered preloading
    const visualizationEmbeddings = []
    const categoricalMetadata = []
    const continuousMetadata = []
    
    // 1. Get visualization embeddings from dropdown (2D/3D coordinate data)
    const embeddingDropdown = document.getElementById('metadata-select-dropdown')
    console.log(`🔍 [DEBUG] Embedding dropdown found:`, !!embeddingDropdown)
    
    if (embeddingDropdown) {
      const options = embeddingDropdown.querySelectorAll('option[value]:not([value=""])')
      console.log(`🔍 [DEBUG] Found ${options.length} embedding options in dropdown`)
      
      options.forEach((option, index) => {
        const embeddingId = option.value
        const embeddingName = option.textContent.trim() // Remove extra whitespace
        console.log(`🔍 [DEBUG] Option ${index + 1}: ID="${embeddingId}", Name="${embeddingName}"`)
        
        // Only add valid embeddings (non-empty ID and name, and not just whitespace)
        // Also check if ID is a valid number (embeddings should have numeric IDs)
        if (embeddingId && embeddingId.trim() && embeddingName && embeddingName.trim() && !isNaN(parseInt(embeddingId.trim()))) {
          visualizationEmbeddings.push({ id: embeddingId.trim(), name: embeddingName })
        } else {
          console.log(`🔍 [DEBUG] Skipping invalid embedding: ID="${embeddingId}", Name="${embeddingName}" (ID is not a valid number)`)
        }
      })
    } else {
      console.log(`🔍 [DEBUG] No embedding dropdown found with ID 'metadata-select-dropdown'`)
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
      if (metadataType === 'DISCRETE' || metadataType === 'STRING') {
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
        if (metadataType === 'DISCRETE' || metadataType === 'STRING') {
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
    
    const totalMetadataCount = categoricalMetadata.length + continuousMetadata.length
    
    console.log(`🚀 [PERF] Found metadata to preload:`)
    console.log(`  - ${visualizationEmbeddings.length} visualization embeddings:`, visualizationEmbeddings.slice(0, 3).map(e => e.name))
    console.log(`  - ${categoricalMetadata.length} categorical metadata`)
    console.log(`  - ${continuousMetadata.length} continuous metadata`)
    console.log(`  - Total metadata: ${totalMetadataCount}, Buffer size: ${this.maxMetadataInMemory}`)
    
    // If total metadata count is less than buffer size, preload ALL metadata
    const shouldPreloadAllMetadata = totalMetadataCount <= this.maxMetadataInMemory
    if (shouldPreloadAllMetadata) {
      console.log(`🚀 [MEMORY] Total metadata (${totalMetadataCount}) ≤ buffer size (${this.maxMetadataInMemory}) → Preloading ALL metadata!`)
    } else {
      console.log(`🚀 [MEMORY] Total metadata (${totalMetadataCount}) > buffer size (${this.maxMetadataInMemory}) → Selective preloading (LRU will manage)`)
    }
    
    // Special logging for sex and age in final lists
    const allMetadataToPreload = [...categoricalMetadata, ...continuousMetadata]
    const sexAgeMetadata = allMetadataToPreload.filter(id => {
      const name = this.dataManager.getMetadataNameById(id)
      return name && (name.toLowerCase().includes('sex') || name.toLowerCase().includes('age'))
    })
    
    if (sexAgeMetadata.length > 0) {
      console.log(`🔍 [SEX/AGE DEBUG] Sex/Age metadata found in preload list:`, sexAgeMetadata.map(id => this.dataManager.getMetadataNameById(id)))
    } else {
      console.log(`🔍 [SEX/AGE DEBUG] No sex/age metadata found in preload list!`)
    }
    
    let embeddingCount = 0
    let categoricalCount = 0
    let continuousCount = 0
    let skippedCount = 0
    
    // PHASE 1: Preload visualization embeddings (coordinate data)
    // These are cached silently in binaryDataCache without displaying
    console.log(`\n📊 [Phase 1] Preloading ${visualizationEmbeddings.length} embeddings...`)
    console.log(`🔍 [DEBUG] Embedding list:`, visualizationEmbeddings.map(e => ({ id: e.id, name: e.name, trimmedName: e.name.trim() })))
    
    // Don't filter out embeddings - they were working before
    // The issue is likely with loom file detection, not the embeddings themselves
    const validEmbeddings = visualizationEmbeddings
    
    console.log(`🔍 [DEBUG] Valid embeddings after filtering: ${validEmbeddings.length}/${visualizationEmbeddings.length}`)
    console.log(`🔍 [DEBUG] Valid embedding list:`, validEmbeddings.map(e => ({ id: e.id, name: e.name.trim() })))
    
    for (const embedding of validEmbeddings) {
      try {
        console.log(`  📥 Loading: ${embedding.name} (ID: ${embedding.id})`)
        
        // Process all embeddings - they were working before
        
        // Check if embedding is already cached before trying to load
        const isAlreadyCached = this.binaryDataCache.has(embedding.id)
        if (isAlreadyCached) {
          console.log(`  ⏭️  Already cached: ${embedding.name}`)
          embeddingCount++
          continue
        }
        
        const result = await this.loadMetadataCoordinatesSilently(embedding.id, embedding.name)
        
        if (result.success) {
          embeddingCount++
          if (result.cached) {
            console.log(`  ⏭️  Already cached: ${embedding.name}`)
          } else {
            console.log(`  ✅ Cached: ${embedding.name} (${result.size}) - ${embeddingCount}/${validEmbeddings.length}`)
          }
        } else {
          console.log(`  ❌ Failed: ${embedding.name} - ${result.error}`)
          console.log(`  🔍 [DEBUG] Failed embedding details:`, { id: embedding.id, name: embedding.name, error: result.error })
        }
      } catch (error) {
        console.log(`  ❌ Failed: ${embedding.name} - ${error.message}`)
        console.log(`  🔍 [DEBUG] Failed embedding details:`, { id: embedding.id, name: embedding.name, error: error.message, stack: error.stack })
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
    
    // If we should preload all to memory, first get list of what's already in database
    let metadataInDatabase = new Set()
    if (shouldPreloadAllMetadata && this.db) {
      console.log(`\n🔍 [MEMORY] Checking which metadata are already in database...`)
      try {
        const transaction = this.db.transaction(['metadata'], 'readonly')
        const objectStore = transaction.objectStore('metadata')
        const getAllRequest = objectStore.getAll()
        
        await new Promise((resolve) => {
          getAllRequest.onsuccess = () => {
            const allItems = getAllRequest.result
            const currentLoom = this.getCurrentLoomFile()
            
            // Filter by matching loom file
            allItems.forEach(item => {
              const itemLoomNormalized = item.loomFile === '' ? null : item.loomFile
              if (itemLoomNormalized === currentLoom && item.id) {
                metadataInDatabase.add(item.id.toString())
              }
            })
            
            console.log(`🔍 [MEMORY] Found ${metadataInDatabase.size} metadata in database for loom: ${currentLoom}`)
            resolve()
          }
          getAllRequest.onerror = () => {
            console.error('Error getting metadata list from database')
            resolve()
          }
        })
      } catch (error) {
        console.error('Error checking database:', error)
      }
    }
    
    if (orderedMetadata.length > 0) {
      console.log(`\n🏷️ [Phase 2] Preloading all ${orderedMetadata.length} metadata vectors...`)
      if (shouldPreloadAllMetadata) {
        console.log(`💾 [PERF] Preloading to MEMORY + DISK (all ${totalMetadataCount} metadata fit in buffer)`)
        console.log(`💾 [PERF] ${metadataInDatabase.size}/${totalMetadataCount} already in database, will load to memory`)
      } else {
        console.log(`💾 [PERF] Preloading to DISK only (${totalMetadataCount} metadata > ${this.maxMetadataInMemory} buffer limit)`)
      }
      
      // Reduce batch size to prevent server overload and add retry logic
      const batchSize = 1 // Reduced from 3 to 1 to prevent server overload
      const maxRetries = 2
      
      for (let i = 0; i < orderedMetadata.length; i += batchSize) {
        const batch = orderedMetadata.slice(i, i + batchSize)
        
        // Load batch sequentially (not in parallel) to reduce server load
        for (let batchIndex = 0; batchIndex < batch.length; batchIndex++) {
          const metadataId = batch[batchIndex]
          const metadataStartTime = performance.now()
          console.log(`🔍 [TIMING] Starting processing metadata ${metadataId} at ${metadataStartTime.toFixed(2)}ms`)
          // Skip if already loaded in memory or currently loading
          if (this.loadedMetadataVectors[metadataId] || this.loadingMetadataVectors.has(metadataId)) {
            // Special logging for sex and age
            const metadataName = this.dataManager.getMetadataNameById(metadataId)
            if (metadataName && (metadataName.toLowerCase().includes('sex') || metadataName.toLowerCase().includes('age'))) {
              console.log(`🔍 [SEX/AGE DEBUG] Skipping ${metadataName} (${metadataId}) - already loaded/loading`)
            }
            continue
          }

          // If we should preload all to memory, only load if it's in database
          if (shouldPreloadAllMetadata) {
            const metadataName = this.dataManager.getMetadataNameById(metadataId)
            
            // Check if this metadata is in the database
            if (metadataInDatabase.has(metadataId.toString())) {
              // Update status icon to show it's downloading
              this.uiManager.updateMetadataStatusIcon(metadataId, 'downloading')
              
              // Silently load from disk to memory (only log every 10th)
              const memoryLoadStart = performance.now()
              console.log(`🔍 [MEMORY] Starting memory load for existing metadata ${metadataId} at ${memoryLoadStart.toFixed(2)}ms`)
              console.log(`🔍 [DEBUG] About to call loadSingleMetadataVector for existing metadata ${metadataId}`)
              try {
                const metadata = await this.dataManager.loadSingleMetadataVector(metadataId)
                const memoryLoadEnd = performance.now()
                const memoryLoadDuration = (memoryLoadEnd - memoryLoadStart).toFixed(2)
                console.log(`🔍 [MEMORY] Completed memory load for existing metadata ${metadataId} in ${memoryLoadDuration}ms`)
                console.log(`🔍 [DEBUG] loadSingleMetadataVector returned for existing metadata ${metadataId}:`, metadata ? 'success' : 'failed')
                if (metadata) {
                  const globalIndex = i + batchIndex
                  if (globalIndex < categoricalMetadata.length) {
                    categoricalCount++
                    // Log progress every 10 items
                    if (categoricalCount % 10 === 0 || categoricalCount === categoricalMetadata.length) {
                      console.log(`  💾→🧠 Loaded ${categoricalCount}/${categoricalMetadata.length} categorical metadata to memory`)
                    }
                  } else {
                    continuousCount++
                    // Log progress every 5 items
                    if (continuousCount % 5 === 0 || continuousCount === continuousMetadata.length) {
                      console.log(`  💾→🧠 Loaded ${continuousCount}/${continuousMetadata.length} continuous metadata to memory`)
                    }
                  }
                  
                  // Update status icon to show it's in memory (green check) - this is new data loaded during preloading
                  console.log(`🔍 [PRELOAD] Setting ${metadataId} to in-memory (green) during preloading`)
                  this.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
                  
                  // Show checkboxes for loaded metadata
                  this.uiManager.showCheckboxesForMetadata(metadataId)
                }
                
                const metadataEndTime = performance.now()
                const metadataDuration = (metadataEndTime - metadataStartTime).toFixed(2)
                console.log(`🔍 [TIMING] Completed processing existing metadata ${metadataId} in ${metadataDuration}ms`)
              } catch (error) {
                console.error(`  ❌ Failed to load ${metadataId} to memory:`, error)
              }
            } else {
              skippedCount++
            }
            continue
          }
          
          // For disk-only preload, check if already in database first
          console.log(`🔍 [DEBUG] About to check if metadata ${metadataId} is in database...`)
          const isInDatabase = await this.checkMetadataInDatabase(metadataId)
          console.log(`🔍 [DEBUG] checkMetadataInDatabase result for ${metadataId}:`, isInDatabase)
          if (isInDatabase) {
            const metadataName = this.dataManager.getMetadataNameById(metadataId)
            console.log(`  ⏭️  Already in database: ${metadataName || metadataId} - skipping preload`)
            
            // Status icon already updated during initial status check - no need to update again
            
            // Still show checkboxes for metadata that's already in database
            console.log(`🔍 [DEBUG] Showing checkboxes for already-cached metadata ${metadataId}`)
            this.uiManager.showCheckboxesForMetadata(metadataId)
            
            const metadataEndTime = performance.now()
            const metadataDuration = (metadataEndTime - metadataStartTime).toFixed(2)
            console.log(`🔍 [TIMING] Completed processing skipped metadata ${metadataId} in ${metadataDuration}ms`)
            
            skippedCount++
            continue
          }
          
          // Special logging for sex and age before loading
          const metadataName = this.dataManager.getMetadataNameById(metadataId)
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
              
              // Load from server to disk (IndexedDB)
              // If we have enough buffer space, also load into memory for instant access
              let result
              if (shouldPreloadAllMetadata) {
                // Load into memory AND disk
                result = await this.dataManager.loadSingleMetadataVector(metadataId)
                if (result) {
                  result = { success: true, metadataId, name: result.name }
                } else {
                  result = { success: false, metadataId }
                }
              } else {
                // Update status icon to show it's downloading
                this.uiManager.updateMetadataStatusIcon(metadataId, 'downloading')
                
                // Load to disk only
                result = await this.preloadMetadataToDisk(metadataId)
              }
              
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
                
                // Try to load the newly stored metadata to memory if there's space
                console.log(`🔍 [MEMORY] Attempting to load metadata ${metadataId} to memory after disk storage`)
                const newMetadataLoadStart = performance.now()
                console.log(`🔍 [MEMORY] Starting memory load for new metadata ${metadataId} at ${newMetadataLoadStart.toFixed(2)}ms`)
                try {
                  const memoryMetadata = await this.dataManager.loadSingleMetadataVector(metadataId)
                  const newMetadataLoadEnd = performance.now()
                  const newMetadataLoadDuration = (newMetadataLoadEnd - newMetadataLoadStart).toFixed(2)
                  console.log(`🔍 [MEMORY] Completed memory load for new metadata ${metadataId} in ${newMetadataLoadDuration}ms`)
                  console.log(`🔍 [MEMORY] loadSingleMetadataVector result for ${metadataId}:`, memoryMetadata ? 'success' : 'failed')
                  if (memoryMetadata) {
                    const greenTime = performance.now()
                    const orangeDuration = result.orangeTime ? (greenTime - result.orangeTime).toFixed(2) : 'unknown'
                    console.log(`🔍 [MEMORY] Loaded newly stored metadata ${metadataId} to memory`)
                    // Update status icon to show it's in memory (green check)
                    console.log(`🔍 [MEMORY] Setting ${metadataId} to in-memory (green) after memory loading at ${greenTime.toFixed(2)}ms`)
                    console.log(`🔍 [DEBUG] Memory loading completed for metadata ${metadataId}`)
                    console.log(`⏱️ [TIMER] Orange status duration for ${metadataId}: ${orangeDuration}ms`)
                    this.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
                    
                    // Show checkboxes for newly loaded metadata
                    this.uiManager.showCheckboxesForMetadata(metadataId)
                  } else {
                    console.log(`🔍 [MEMORY] loadSingleMetadataVector returned null/undefined for ${metadataId}`)
                  }
                } catch (error) {
                  console.log(`🔍 [MEMORY] Could not load metadata ${metadataId} to memory (buffer full or error):`, error.message)
                  console.log(`🔍 [MEMORY] Error details:`, error)
                }
                
                success = true
                const metadataEndTime = performance.now()
                const metadataDuration = (metadataEndTime - metadataStartTime).toFixed(2)
                console.log(`🔍 [TIMING] Completed processing metadata ${metadataId} in ${metadataDuration}ms`)
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
    console.log(`  ⏭️  ${skippedCount} items skipped (already in database)`)
    this.memoryManager.logMemoryUsage('After preloading all metadata')
    
    // Performance assessment after preloading
    await this.assessPerformanceAfterPreload()
    
    // Create diagnostic button for troubleshooting
    this.performanceManager.createDiagnosticButton()
  }

  // Update visualization with metadata vector coloring
  updateVisualizationWithMetadataVector() {
    // Check for renderer availability (either ReGL or PixiJS)
    const hasRenderer = !!this.reglRenderer
    
    if (!this.currentMetadataVector || !hasRenderer) {
      console.log('Cannot update visualization - missing data or renderer')
      return
    }
    
    //console.log(`Updating visualization with ${this.currentMetadataVector.name} (${this.currentMetadataVector.data_type})`)
    
    const { data_type, values, compression_info } = this.currentMetadataVector
    
    // Get existing coordinates for coloring
    // CRITICAL: If coordinates are missing but renderer has state, try to restore them
    if (!this.currentCoordinates || this.currentCoordinates.length === 0) {
      console.log('⚠️ No coordinates available for coloring - attempting to restore from renderer state')
      
      // Try to restore from renderer if it has positions
      if (this.reglRenderer && this.reglRenderer.positions && this.reglRenderer.positions.length > 0) {
        // positions is Float32Array: [x1, y1, x2, y2, ...]
        // We need to convert back to [[x, y], [x, y], ...] format
        const numPoints = this.reglRenderer.positions.length / 2
        console.log(`🔄 Restoring ${numPoints} coordinates from renderer positions`)
        
        // Get bounds from currentBounds if available, or calculate from renderer
        let bounds = this.currentBounds
        if (!bounds && this.reglRenderer.positions) {
          let minX = Infinity, maxX = -Infinity
          let minY = Infinity, maxY = -Infinity
          for (let i = 0; i < this.reglRenderer.positions.length; i += 2) {
            minX = Math.min(minX, this.reglRenderer.positions[i])
            maxX = Math.max(maxX, this.reglRenderer.positions[i])
            minY = Math.min(minY, this.reglRenderer.positions[i + 1])
            maxY = Math.max(maxY, this.reglRenderer.positions[i + 1])
          }
          bounds = { minX, maxX, minY, maxY }
        }
        
        // Convert positions back to coordinate pairs (denormalize from screen space)
        // This requires interactionHandler to denormalize, but we can use a simpler approach:
        // Store the positions as-is and ensure displayOrder exists
        this.currentCoordinates = new Array(numPoints)
        for (let i = 0; i < numPoints; i++) {
          // positions are in screen space, but we need original space
          // For now, use positions as-is (they're already normalized)
          this.currentCoordinates[i] = [
            this.reglRenderer.positions[i * 2],
            this.reglRenderer.positions[i * 2 + 1]
          ]
        }
        
        // Ensure displayOrder exists
        if (!this.displayOrder || this.displayOrder.length === 0) {
          this.displayOrder = new Array(numPoints)
          for (let i = 0; i < numPoints; i++) {
            this.displayOrder[i] = i
          }
        }
        
        console.log(`✅ Restored ${numPoints} coordinates from renderer state`)
      } else {
        console.error('❌ No coordinates available for coloring and cannot restore from renderer')
      return
      }
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
    
    // Update category distribution bar plots for all unfolded metadata sections
    // This ensures bar plots are shown when coloring is active
    this.dataManager.updateAllCategoryDistributions()
    
  }

  // Render all points using the current coloring scheme
  renderPointsWithCurrentColoring() {
    console.log('🎨 [RENDER] renderPointsWithCurrentColoring() called')
    console.log('🎨 [RENDER] State check:', {
      hasReglRenderer: !!this.reglRenderer,
      hasCurrentCoordinates: !!this.currentCoordinates,
      currentCoordinatesLength: this.currentCoordinates?.length || 0,
      currentMetadataVector: this.currentMetadataVector?.id || 'none',
      currentMetadataId: this.currentMetadataId || 'none'
    })

    // Performance optimization: check if color state has changed
    const currentColorHash = this.dataManager.getColorStateHash()
    if (this.lastColorUpdateHash === currentColorHash && this.colorUpdateCache.has('lastColorMap')) {
      console.log('🎨 [RENDER] Using cached color update (no color state change)')
      const cachedColorMap = this.colorUpdateCache.get('lastColorMap')
      
      // IMPORTANT: If display order was reset (e.g., after embedding switch),
      // we need to rebuild the colorMap from originalPointColors using the new display order
      if (this._displayOrderWasReset) {
        console.log('🎨 [ReGL] Display order was reset, rebuilding colorMap from originalPointColors')
        const colorMap = new Map()
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const color = this.originalPointColors.get(cellIndex) || 0x3b82f6
          colorMap.set(drawPos, color)
        }
        this.reglRenderer.updateColors(colorMap)
        this.reglRenderer.render()
        
        // Clear the flag and update cache with new colorMap
        this._displayOrderWasReset = false
        this.colorUpdateCache.set('lastColorMap', colorMap)
        
        // Refresh 2D plot if open
        this.customPlotManager.refresh2DPlotIfOpen()
        return
      }
      
      this.reglRenderer.updateColors(cachedColorMap)
      this.reglRenderer.render()
      
      // Refresh 2D plot if open
      this.customPlotManager.refresh2DPlotIfOpen()
      return
    }
    
    // console.log('🎨 [ReGL] Updating point colors based on metadata')
    const startTime = performance.now()
    
    if (!this.reglRenderer || !this.currentCoordinates) {
      console.log('⚠️ [ReGL] Cannot update colors - missing renderer or coordinates')
      return
    }
    
    const colorMap = new Map()
    
    // Get current filtered indices to hide invisible points
    const filteredIndices = this.dataManager.getIncrementalFilteredIndices()
    const visibleSet = filteredIndices ? new Set(filteredIndices) : null
    console.log(`🎨 [ReGL] Filtered indices:`, filteredIndices ? `${filteredIndices.length} visible cells` : 'all visible')
    
    // Check if we have metadata coloring active
    // FIXED: Use getColoringMetadataVector() to get the correct metadata for coloring
    const coloringMetadataVector = this.colorManager.getColoringMetadataVector()
    console.log('🎨 [RENDER] Checking for coloring metadata vector:', {
      hasColoringMetadataVector: !!coloringMetadataVector,
      coloringMetadataVectorId: coloringMetadataVector?.id || 'none',
      coloringMetadataVectorName: coloringMetadataVector?.name || 'none',
      currentMetadataVectorId: this.currentMetadataVector?.id || 'none',
      currentMetadataId: this.currentMetadataId || 'none'
    })
    
    if (coloringMetadataVector) {
      console.log(`🎨 [RENDER] Applying ${coloringMetadataVector.data_type} metadata colors for: ${coloringMetadataVector.name}`)
      
      if (coloringMetadataVector.data_type === 'DISCRETE' || coloringMetadataVector.data_type === 'STRING') {
        // Discrete metadata coloring with category ordering
        const categoryColors = this.colorManager.getCategoryColors()
        
        // Build category-to-index map using DOM order (same as legend)
        const domOrderCategories = this.getCategoriesForMetadata(coloringMetadataVector.id)
        let categoryToIndex = {}
        
        if (domOrderCategories && domOrderCategories.length > 0) {
          // Use DOM order for consistent color assignment
          const categoryNames = domOrderCategories.map(cat => cat.name)
          categoryNames.forEach((cat, idx) => {
            categoryToIndex[cat] = idx
          })
        } else {
          // Fallback to Set order if DOM not available
          const uniqueCategories = [...new Set(coloringMetadataVector.values)]
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
            const category = coloringMetadataVector.values[cellIndex]
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
        
        // Cache colors for fast visibility updates
        this.colorManager.calculateAndCacheColors(coloringMetadataVector)
        
        // Update colors in ReGL
        this.reglRenderer.updateColors(colorMap)
        this.reglRenderer.render()
        
        // Check if we need to reorder points for category display
        // Only reorder if this is the first time loading this metadata or if order preference changed
        const needsReordering = !this._lastCategoryOrderApplied || this._lastCategoryOrderApplied !== this.categoryOrder
        
        if (needsReordering) {
          console.log('📊 [ReGL] Applying category display order (first time or order changed)...')
          console.log(`📊 [ReGL] originalPointColors size: ${this.originalPointColors.size}, displayOrder length: ${this.displayOrder.length}`)
          this._lastCategoryOrderApplied = this.categoryOrder
          
          // Reorder points in buffer (this will re-render and redraw overlay)
          this.reorderPointsForCategoryDisplay()
          
          // Redraw overlay is handled by reorderPointsForCategoryDisplay
          const elapsed = performance.now() - startTime
          console.log(`🎨 [ReGL] Color update with reordering completed in ${elapsed.toFixed(2)}ms`)
          
          // Refresh 2D plot if open
          this.customPlotManager.refresh2DPlotIfOpen()
          return // Early exit - reordering already rendered everything
        }
        
      } else if (coloringMetadataVector.data_type === 'NUMERIC') {
        // Continuous/numeric metadata coloring
        const values = coloringMetadataVector.values
        const compressionInfo = coloringMetadataVector.compression_info
        
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
            
            // Handle edge case: if range is 0 (all values same), use 0.5
            // Otherwise normalize to 0-1 range
            let normalizedValue
            if (range > 0) {
              normalizedValue = (value - minVal) / range
              // Clamp to valid range to handle floating point precision issues
              normalizedValue = Math.max(0, Math.min(1, normalizedValue))
            } else {
              normalizedValue = 0.5
            }
            
            const color = this.gradientManager.getColorFromGradient(normalizedValue)
            
            colorMap.set(drawPos, color)
            this.originalPointColors.set(cellIndex, color) // Store by cell index
          } else {
            // Hide filtered-out points
            colorMap.set(drawPos, 0x00000000)
          }
        }
        
        // Cache colors for fast visibility updates
        this.colorManager.calculateAndCacheColors(coloringMetadataVector)
        
        console.log(`🎨 [ReGL] Applied continuous colors to ${colorMap.size} points (including hidden ones)`)
        
        // Update colors in ReGL (but don't render yet, we'll reorder first)
        this.reglRenderer.updateColors(colorMap)
        
        // Check if we need to reorder points for numeric display
        // Force reordering if:
        // 1. Order hasn't been applied yet
        // 2. Order preference changed
        // 3. Metadata changed (values are different even if order preference is same)
        const metadataChanged = !this._lastNumericMetadataId || this._lastNumericMetadataId !== coloringMetadataVector.id
        const orderChanged = !this._lastNumericOrderApplied || this._lastNumericOrderApplied !== this.numericalOrder
        const needsReordering = orderChanged || metadataChanged
        
        if (needsReordering) {
          console.log('📊 [ReGL] Applying numeric display order (first time, order changed, or metadata changed)...')
          console.log('📊 [ReGL] Order changed:', orderChanged, 'Metadata changed:', metadataChanged)
          this._lastNumericOrderApplied = this.numericalOrder
          this._lastNumericMetadataId = coloringMetadataVector.id
          
          // Reorder points in buffer based on z-index (this will re-render and redraw overlay)
          this.reorderPointsForNumericDisplay(values, minVal, maxVal)
          
          // Redraw overlay and legend is handled by reorderPointsForNumericDisplay
          const elapsed = performance.now() - startTime
          console.log(`🎨 [ReGL] Color update with numeric reordering completed in ${elapsed.toFixed(2)}ms`)
          
          // Refresh 2D plot if open
          this.customPlotManager.refresh2DPlotIfOpen()
          return // Early exit - reordering already rendered everything
        } else {
          // Just render without reordering
          this.reglRenderer.render()
          
          // Render continuous color legend
          this.renderContinuousColorLegend()
          
          // Refresh 2D plot if open
          this.customPlotManager.refresh2DPlotIfOpen()
        }
      }
    } else {
      // Default blue coloring
      console.log('🎨 [RENDER] Applying default blue colors (no coloring metadata vector)')
      console.log('🎨 [RENDER] Default blue coloring details:', {
        displayOrderLength: this.displayOrder?.length || 0,
        visibleSetSize: visibleSet?.size || 'all',
        defaultColor: '0x3b82f6'
      })
      const defaultColor = 0x3b82f6
      let visibleCount = 0
      let hiddenCount = 0
      
      for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
        const cellIndex = this.displayOrder[drawPos]
        const isVisible = !visibleSet || visibleSet.has(cellIndex)
        
        if (isVisible) {
          colorMap.set(drawPos, defaultColor)
          this.originalPointColors.set(cellIndex, defaultColor) // Store by cell index
          visibleCount++
        } else {
          // Hide filtered-out points
          colorMap.set(drawPos, 0x00000000)
          hiddenCount++
        }
      }
      
      console.log('🎨 [RENDER] Default blue coloring applied:', {
        totalPoints: this.displayOrder.length,
        visiblePoints: visibleCount,
        hiddenPoints: hiddenCount,
        colorMapSize: colorMap.size
      })
      
      // Update colors in ReGL
      console.log('🎨 [RENDER] Updating ReGL renderer with default blue colors...')
      this.reglRenderer.updateColors(colorMap)
      this.reglRenderer.render()
      console.log('🎨 [RENDER] ReGL renderer updated and rendered')
      
      // Refresh 2D plot if open
      this.customPlotManager.refresh2DPlotIfOpen()
    }
    
    // Redraw the Canvas 2D overlay (grid, axes, labels/legend) to ensure everything is visible
    // Order matters: grid first (clears), then axes, then labels/legend
    this.rendererManager.renderGrid()
    this.rendererManager.renderAxes()
    if (this.currentMetadataVector) {
      if (this.currentMetadataVector.data_type === 'DISCRETE' || this.currentMetadataVector.data_type === 'STRING') {
        this.rendererManager.renderCategoryLabels()
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
    
    // Refresh 2D plot if open
    this.customPlotManager.refresh2DPlotIfOpen()
    
    // Refresh fixed tooltip if one is displayed
    this.refreshFixedTooltipIfNeeded()
  }


  // Color points for continuous metadata
  colorPointsContinuous(values, compressionInfo) {
    /*console.log('Coloring points for continuous metadata:', {
      range: `${compressionInfo.min_val} to ${compressionInfo.max_val}`,
      actualRange: `${this.dataManager.safeMin(values).toFixed(3)} to ${this.dataManager.safeMax(values).toFixed(3)}`
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
      
      const screenX = this.interactionHandler.normalizeX(coord[0], this.currentBounds)
      const screenY = this.interactionHandler.normalizeY(coord[1], this.currentBounds)
      
      graphics.beginFill(color)
      graphics.drawCircle(screenX, screenY, this.currentPointSize)
      graphics.endFill()
    })
    
    this.scatterContainer.addChild(graphics)
    
    // Update point count display
    this.uiManager.updatePointCountDisplay(null)
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


/*
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
*/

  // Set custom color range for continuous metadata
  setColorRange(min, max) {
    if (min >= max) {
      console.error('Invalid color range: min must be less than max')
      return
    }
    
    this.customColorRange = { min, max }
    
    // If we have continuous metadata active, re-render the visualization and legend
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'NUMERIC') {
      //this.forceReRenderPoints()
      this.renderContinuousColorLegend()
    }
    
    console.log('🎨 Color range set to:', { min, max })
  }

  // Reset color range to auto (use data min/max)
  resetColorRange() {
    this.customColorRange = null
    
    // If we have continuous metadata active, re-render the visualization and legend
    if (this.currentMetadataVector && this.currentMetadataVector.data_type === 'NUMERIC') {
      //this.forceReRenderPoints()
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
    
    // Update category distribution bar plots to reflect the new color range
    // This ensures bar plots show the correct gradient when color range changes
    if (this.currentMetadataVector?.data_type === 'NUMERIC') {
      this.dataManager.updateAllCategoryDistributions()
    }
  }

  // Redraw the entire visualization (used by inline range slider)
  /*redrawVisualization() {
    console.log('🎨 Redrawing visualization...')
    
    if (this.currentMetadataVector) {
      //this.forceReRenderPoints()
      
      // Update the appropriate legend
      if (this.currentMetadataVector.data_type === 'NUMERIC') {
        this.renderContinuousColorLegend()
      } else {
        this.renderDiscreteColorLegend()
      }
    }
  }
*/

  // Initialize inline range slider with metadata values
  initializeInlineRangeSlider(metadataId, values) {
    const isGene = metadataId && metadataId.startsWith('gene_')
    const logPrefix = isGene ? '🧬 [SLIDER INIT]' : '🎚️ [SLIDER INIT]'
    
    // Check renderer state BEFORE initialization (for debugging)
    if (isGene) {
      console.log(`${logPrefix} Renderer state BEFORE initializeInlineRangeSlider (gene):`, {
        hasReglRenderer: !!this.reglRenderer,
        rendererInstanceId: this.reglRenderer?.instanceId || 'none',
        numPoints: this.reglRenderer?.numPoints || 0,
        hasPositions: !!this.reglRenderer?.positions,
        positionsLength: this.reglRenderer?.positions?.length || 0,
        hasCurrentCoordinates: !!this.currentCoordinates,
        currentCoordinatesLength: this.currentCoordinates?.length || 0
      })
    }
    
    console.log(`${logPrefix} Initializing inline range slider for metadata:`, metadataId)
    
    if (!values || !Array.isArray(values)) {
      console.error(`❌ ${logPrefix} Invalid values provided to initializeInlineRangeSlider:`, values)
      return
    }
    
    const minVal = this.dataManager.safeMin(values)
    const maxVal = this.dataManager.safeMax(values)
    
    console.log(`${logPrefix} Calculated min/max values:`, { minVal, maxVal, valuesLength: values.length })
    
    // Check if there's an existing selected range for this metadata - preserve it!
    const existingRange = this.selectedRanges?.[metadataId]
    const currentMin = existingRange?.min ?? minVal
    const currentMax = existingRange?.max ?? maxVal
    
    if (existingRange) {
      console.log(`${logPrefix} Preserving existing range for slider:`, existingRange)
    }
    
    // Store the data with preserved range if it exists
    if (!this.inlineRangeSliderData) {
      this.inlineRangeSliderData = {}
      console.log(`${logPrefix} Created inlineRangeSliderData object`)
    }
    
    this.inlineRangeSliderData[metadataId] = {
      min: minVal,
      max: maxVal,
      currentMin: currentMin,
      currentMax: currentMax,
      values: values
    }
    
    console.log(`${logPrefix} Stored in inlineRangeSliderData:`, {
      metadataId,
      min: minVal,
      max: maxVal,
      currentMin,
      currentMax,
      valuesLength: values.length,
      allKeys: Object.keys(this.inlineRangeSliderData)
    })
    
    // Verify loadedMetadataVectors has this metadata (critical for filtering)
    if (isGene) {
      const hasInLoadedVectors = !!this.loadedMetadataVectors?.[metadataId]
      console.log(`${logPrefix} Verification - loadedMetadataVectors has ${metadataId}:`, hasInLoadedVectors)
      if (!hasInLoadedVectors) {
        console.error(`❌ ${logPrefix} CRITICAL: ${metadataId} NOT in loadedMetadataVectors!`)
        console.error(`❌ ${logPrefix} loadedMetadataVectors keys:`, Object.keys(this.loadedMetadataVectors || {}))
      }
    }
    
    // Find the range slider controller and update its values
    const rangeSliderElement = document.querySelector(`[data-range-slider-metadata-id-value="${metadataId}"]`)
    console.log(`${logPrefix} Looking for range slider element:`, rangeSliderElement)
    
    if (rangeSliderElement) {
      const controller = this.application.getControllerForElementAndIdentifier(rangeSliderElement, 'range-slider')
      console.log('🎚️ Found range slider controller:', controller)
      
      if (controller) {
        // CRITICAL: Ensure the range slider controller has the correct visualization controller reference
        // Pass this instance directly to avoid getting a stale reference
        controller.visualizationController = this
        controller.dataManager = this.dataManager
        controller.rendererManager = this.rendererManager
        console.log('🎚️ Updated range slider controller with visualization controller instance:', this.instanceId)
        
        controller.minValue = minVal
        controller.maxValue = maxVal
        controller.currentMinValue = currentMin  // Use preserved value
        controller.currentMaxValue = currentMax  // Use preserved value
        controller.initializeSlider()
        console.log('🎚️ Range slider controller initialized successfully with range:', { currentMin, currentMax })
        
        // Update button appearance to show/hide based on coloring state
        controller.updateButtonAppearance()
        
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

  
  // Clear metadata coloring and return to default blue points
  clearMetadataColoring() {
    console.log('🎨 [CLEAR COLORING] clearMetadataColoring() called')
    console.log('🎨 [CLEAR COLORING] Current filter state:', {
      currentVisibleCells: this.currentVisibleCells ? `${this.currentVisibleCells.length} cells` : 'null (all visible)',
      hasFilter: !!this.currentVisibleCells
    })
    console.log('🎨 [CLEAR COLORING] Checking prerequisites:', {
      rendererType: this.rendererType,
      reglRenderer: !!this.reglRenderer,
      pixiRendererId: this.reglRenderer?.instanceId || 'none',
      pixiApp: !!this.pixiApp,
      scatterContainer: !!this.scatterContainer,
      currentCoordinates: !!this.currentCoordinates,
      currentCoordinatesLength: this.currentCoordinates?.length || 0,
      currentBounds: !!this.currentBounds,
      currentMetadataVectorId: this.currentMetadataVector?.id || 'none',
      currentMetadataId: this.currentMetadataId || 'none'
    })
    
    // Check for renderer availability (either ReGL or PixiJS)
    const hasRenderer = !!this.reglRenderer
    
    if (!hasRenderer || !this.currentCoordinates || !this.currentBounds) {
      console.error('🎨 [CLEAR COLORING] ❌ Cannot clear coloring - missing prerequisites:', {
        hasRenderer,
        hasCurrentCoordinates: !!this.currentCoordinates,
        hasCurrentBounds: !!this.currentBounds
      })
      return
    }
    
    console.log('🎨 [CLEAR COLORING] All prerequisites met, proceeding to clear coloring')
    console.log('🎨 [CLEAR COLORING] Clearing metadata coloring, returning to default blue')
    console.log('🎨 [CLEAR COLORING] Before clearing - currentMetadataVector:', {
      id: this.currentMetadataVector?.id || 'none',
      name: this.currentMetadataVector?.name || 'none',
      dataType: this.currentMetadataVector?.data_type || 'none'
    })
    console.trace('🎨 [CLEAR COLORING] Call stack:')
    
    // Clear current metadata vector
    const oldMetadataId = this.currentMetadataVector?.id || this.currentMetadataId || 'none'
    this.currentMetadataVector = null
    this.currentMetadataId = null
    console.log('🎨 [CLEAR COLORING] Cleared currentMetadataVector and currentMetadataId (was:', oldMetadataId, ')')
    
    // Clear custom color range
    const oldCustomColorRange = this.customColorRange
    this.customColorRange = null
    console.log('🎨 [CLEAR COLORING] Cleared customColorRange (was:', oldCustomColorRange, ')')
    
    // Update adapt color range button visibility for all range sliders
    console.log('🎨 [CLEAR COLORING] Updating range slider button appearances...')
    this.updateAllRangeSliderButtonAppearances()
    console.log('🎨 [CLEAR COLORING] Range slider button appearances updated')
    
    // Clear the cached color map since we're clearing metadata
    console.log('🎨 [CLEAR COLORING] Clearing color map cache...')
    this.colorManager.clearColorMapCache()
    console.log('🎨 [CLEAR COLORING] Color map cache cleared')
    
    // Render points with default blue coloring based on renderer type
    console.log('🎨 [CLEAR COLORING] Calling renderPointsWithCurrentColoring() to render default blue...')
    console.log('🎨 [CLEAR COLORING] Filter state before renderPointsWithCurrentColoring:', {
      currentVisibleCells: this.currentVisibleCells ? `${this.currentVisibleCells.length} cells` : 'null (all visible)',
      hasFilter: !!this.currentVisibleCells
    })
    try {
    this.renderPointsWithCurrentColoring()
      console.log('🎨 [CLEAR COLORING] renderPointsWithCurrentColoring() completed successfully')
      console.log('🎨 [CLEAR COLORING] Filter state after renderPointsWithCurrentColoring:', {
        currentVisibleCells: this.currentVisibleCells ? `${this.currentVisibleCells.length} cells` : 'null (all visible)',
        hasFilter: !!this.currentVisibleCells
      })
    } catch (error) {
      console.error('🎨 [CLEAR COLORING] ❌ Error in renderPointsWithCurrentColoring():', error)
      console.error('🎨 [CLEAR COLORING] Error stack:', error.stack)
    }
    
    
    // Clear any existing legend (both discrete and continuous)
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.removeChildren()
      this.categoryLabelsContainer.visible = false
    }
    
    // Hide all category distribution bar plots when coloring is cleared
    const allCanvases = document.querySelectorAll('.category-distribution-canvas')
    allCanvases.forEach(canvas => {
      canvas.style.display = 'none'
    })
    
    console.log('🎨 Successfully cleared metadata coloring')
  }
  /*
  // Clear all loaded metadata vectors cache (use when switching projects or clearing all data)
  clearLoadedMetadataVectorsCache() {
    //console.log('Clearing all loaded metadata vectors cache')
    this.loadedMetadataVectors = {}
    this.loadingMetadataVectors.clear()
  }
  */
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
    // Log the event timestamp to see if there's a delay before this function is called
    const eventTime = event.timeStamp
    const callTime = performance.now()
    const delay = callTime - eventTime
    
    console.log(`⏱️ [TOGGLE] Event fired at: ${eventTime.toFixed(2)}ms`)
    console.log(`⏱️ [TOGGLE] Function called at: ${callTime.toFixed(2)}ms`)
    console.log(`⏱️ [TOGGLE] ⚠️ DELAY between event and function call: ${delay.toFixed(2)}ms`)
    
    if (delay > 100) {
      console.error(`❌ [TOGGLE] CRITICAL: ${delay.toFixed(2)}ms delay! Something is severely blocking the main thread!`)
      console.error(`❌ [TOGGLE] Possible causes:`)
      console.error(`   1. Heavy synchronous computation running`)
      console.error(`   2. Large data structure being processed`)
      console.error(`   3. Stimulus framework overhead`)
      console.error(`   4. Browser extension interference`)
      console.error(`   5. Garbage collection pause`)
      
      // Log current state to help diagnose
      console.error(`❌ [TOGGLE] Current state:`, {
        loadedMetadataCount: Object.keys(this.loadedMetadataVectors || {}).length,
        binaryCacheSize: this.binaryDataCache?.size || 0,
        interactionMode: this.interactionMode,
        isDrawingLasso: this.isDrawingLasso,
        isPanning: this.isPanning
      })
      
      // Check memory usage if available
      if (performance.memory) {
        const memMB = (performance.memory.usedJSHeapSize / 1024 / 1024).toFixed(1)
        const limitMB = (performance.memory.jsHeapSizeLimit / 1024 / 1024).toFixed(1)
        console.error(`❌ [TOGGLE] Memory: ${memMB}MB / ${limitMB}MB (${((performance.memory.usedJSHeapSize / performance.memory.jsHeapSizeLimit) * 100).toFixed(1)}% used)`)
        
        if (performance.memory.usedJSHeapSize > performance.memory.jsHeapSizeLimit * 0.9) {
          console.error(`❌ [TOGGLE] WARNING: Memory usage is very high! This could cause GC pauses.`)
        }
      }
      
      // Recommendation
      console.error(`❌ [TOGGLE] RECOMMENDATION: Open Chrome DevTools > Performance tab, record, then click to fold/unfold to see what's blocking the thread.`)
    }
    
    const perfStart = performance.now()
    console.log('⏱️ [TOGGLE] Starting metadata fold/unfold...')
    
    const headerElement = event.currentTarget
    const chevron = headerElement.querySelector('.fa-chevron-right')
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
    
    console.log(`⏱️ [TOGGLE] Type: ${isContinuousMetadata ? 'Continuous' : 'Categorical'}, Action: ${isExpanding ? 'Expanding' : 'Collapsing'}`)
    
    if (isExpanding) {
      const chevronTime = performance.now()
      chevron.style.transform = 'rotate(90deg)'
      console.log(`⏱️ [TOGGLE] Chevron rotation: ${(performance.now() - chevronTime).toFixed(2)}ms`)
      
      if (isContinuousMetadata) {
        // Handle continuous metadata - show range section with smooth transition
        const displayTime = performance.now()
        rangeSection.style.display = 'block'
        rangeSection.style.maxHeight = '0px'
        rangeSection.style.opacity = '0'
        rangeSection.style.overflow = 'hidden'
        rangeSection.style.transition = 'max-height 0.3s ease-out, opacity 0.2s ease-out'
        
        // Trigger reflow to ensure transition works
        rangeSection.offsetHeight
        
        // Expand with animation
        rangeSection.style.maxHeight = '500px'
        rangeSection.style.opacity = '1'
        console.log(`⏱️ [TOGGLE] Display change: ${(performance.now() - displayTime).toFixed(2)}ms`)
        
        // Get metadata info and initialize the range slider
        const metadataItem = headerElement.closest('[data-metadata-item]')
        if (metadataItem) {
          const metadataId = metadataItem.dataset.metadataItem
          const metadataName = headerElement.querySelector('[data-metadata-name]')?.dataset.metadataName || 'Unknown'
          
          console.log('🎚️ Expanding continuous metadata:', metadataId, metadataName)
          
          // Initialize the inline range slider
          const sliderTime = performance.now()
          this.toggleInlineRangeSlider(metadataId, metadataName)
          console.log(`⏱️ [TOGGLE] Range slider init: ${(performance.now() - sliderTime).toFixed(2)}ms`)
          
          // Preload metadata for continuous metadata (for future coloring)
          const memCheckTime = performance.now()
          const metadataVector = this.dataManager.getMetadataVectorById(metadataId)
          const isInMemory = !!metadataVector
          console.log(`⏱️ [TOGGLE] Memory check: ${(performance.now() - memCheckTime).toFixed(2)}ms, In memory: ${isInMemory}`)
          
          if (!isInMemory) {
            // Not in memory - load it silently
            const loadTime = performance.now()
            console.log(`⏱️ [TOGGLE] Preloading continuous metadata from disk/network...`)
            this.loadSingleMetadataVectorSilently(metadataId).catch(error => {
              console.log(`Failed to preload continuous metadata vector ${metadataId}:`, error.message)
            })
          }
        }
      } else {
        // Handle categorical metadata - show categories with smooth transition
        const displayTime = performance.now()
        categoriesDiv.style.display = 'block'
        categoriesDiv.style.maxHeight = '0px'
        categoriesDiv.style.opacity = '0'
        categoriesDiv.style.overflow = 'hidden'
        categoriesDiv.style.transition = 'max-height 0.3s ease-out, opacity 0.2s ease-out'
        
        // Trigger reflow to ensure transition works
        categoriesDiv.offsetHeight
        
        // Expand with animation
        categoriesDiv.style.maxHeight = '2000px' // Larger for categories list
        categoriesDiv.style.opacity = '1'
        console.log(`⏱️ [TOGGLE] Display change: ${(performance.now() - displayTime).toFixed(2)}ms`)
        
        // Load metadata vector when expanding categories (for future coloring)
        const metadataItem = headerElement.closest('[data-metadata-item]')
        if (metadataItem) {
          const metadataId = metadataItem.dataset.metadataItem
          
          // Check if metadata is actually accessible (not just in loadedMetadataVectors)
          const memCheckTime = performance.now()
          const metadataVector = this.dataManager.getMetadataVectorById(metadataId)
          const isInMemory = !!metadataVector
          console.log(`⏱️ [TOGGLE] Memory check: ${(performance.now() - memCheckTime).toFixed(2)}ms, In memory: ${isInMemory}`)
          
          if (isInMemory) {
            // Already in memory - just initialize checkboxes (no loading needed)
            const checkboxTime = performance.now()
            this.initializeCheckboxesForMetadata(metadataId).then(() => {
              console.log(`⏱️ [TOGGLE] Checkbox init: ${(performance.now() - checkboxTime).toFixed(2)}ms`)
              
              // Draw category distribution bar plots
              this.drawCategoryDistributions(metadataId)
              
              // Only update filtering if there are active selections
              if (this.selectedCategories[metadataId] && this.selectedCategories[metadataId].size > 0) {
                const filterTime = performance.now()
                this.dataManager.updateCellFiltering()
                console.log(`⏱️ [TOGGLE] Filtering: ${(performance.now() - filterTime).toFixed(2)}ms`)
              } else {
                console.log(`⏱️ [TOGGLE] Skipped filtering (no active selections)`)
              }
              
              console.log(`⏱️ [TOGGLE] ✅ Total time: ${(performance.now() - perfStart).toFixed(2)}ms`)
            })
          } else {
            // Not in memory - load it first (immediate loading for click)
            const loadTime = performance.now()
            console.log(`⏱️ [TOGGLE] Loading metadata from disk/network...`)
            this.loadSingleMetadataVectorSilently(metadataId).then(() => {
              console.log(`⏱️ [TOGGLE] Load time: ${(performance.now() - loadTime).toFixed(2)}ms`)
              
              const checkboxTime = performance.now()
              this.initializeCheckboxesForMetadata(metadataId).then(() => {
                console.log(`⏱️ [TOGGLE] Checkbox init: ${(performance.now() - checkboxTime).toFixed(2)}ms`)
                
                // Draw category distribution bar plots
                this.drawCategoryDistributions(metadataId)
                
                if (this.selectedCategories[metadataId] && this.selectedCategories[metadataId].size > 0) {
                  const filterTime = performance.now()
                  this.dataManager.updateCellFiltering()
                  console.log(`⏱️ [TOGGLE] Filtering: ${(performance.now() - filterTime).toFixed(2)}ms`)
                }
                
                console.log(`⏱️ [TOGGLE] ✅ Total time: ${(performance.now() - perfStart).toFixed(2)}ms`)
              })
            }).catch(error => {
              console.log(`Failed to load metadata vector ${metadataId} on expansion:`, error.message)
              console.log(`⏱️ [TOGGLE] ❌ Failed after: ${(performance.now() - perfStart).toFixed(2)}ms`)
            })
          }
        }
      }
    } else {
      const collapseTime = performance.now()
      chevron.style.transform = 'rotate(0deg)'
      
      if (isContinuousMetadata) {
        // Collapse with animation
        rangeSection.style.maxHeight = '0px'
        rangeSection.style.opacity = '0'
        
        // Hide after transition completes
        setTimeout(() => {
          rangeSection.style.display = 'none'
        }, 300) // Match transition duration
      } else {
        // Collapse with animation
        categoriesDiv.style.maxHeight = '0px'
        categoriesDiv.style.opacity = '0'
        
        // Hide after transition completes
        setTimeout(() => {
          categoriesDiv.style.display = 'none'
        }, 300) // Match transition duration
      }
      
      console.log(`⏱️ [TOGGLE] ✅ Collapse time: ${(performance.now() - collapseTime).toFixed(2)}ms`)
      console.log(`⏱️ [TOGGLE] ✅ Total time: ${(performance.now() - perfStart).toFixed(2)}ms`)
    }
    
    // Don't automatically select or color - just expand/collapse the panel
    // The water drop button is used for coloring
    
    // Check if browser repaint is the bottleneck
    requestAnimationFrame(() => {
      console.log(`⏱️ [TOGGLE] ✅ After browser repaint: ${(performance.now() - perfStart).toFixed(2)}ms`)
    })
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

  // Initialize draggable divider for right panel (Gene Expression / Selections)
  initializeRightPanelDivider() {
    const divider = document.getElementById('right-panel-divider')
    if (!divider) {
      console.error('Right panel divider element not found')
      return
    }
    
    // Find panels
    const geneExpressionPanel = document.getElementById('gene-expression-panel')
    const selectionsPanel = document.getElementById('selections-panel')
    const container = divider.parentElement // right-panel
    
    if (!geneExpressionPanel || !selectionsPanel || !container) {
      console.error('Required elements for right panel divider not found', { 
        geneExpressionPanel: !!geneExpressionPanel, 
        selectionsPanel: !!selectionsPanel, 
        container: !!container 
      })
      return
    }
    
    console.log('Right panel divider initialization - elements found:', {
      divider: !!divider,
      geneExpressionPanel: !!geneExpressionPanel,
      selectionsPanel: !!selectionsPanel,
      container: !!container
    })
    
    let isDragging = false
    let startY = 0
    let startHeight = 0
    
    // Minimum heights for panels (in pixels)
    const minPanelHeight = 100
    
    const startDrag = (e) => {
      console.log('Right panel divider: startDrag triggered', e)
      isDragging = true
      startY = e.clientY || (e.touches && e.touches[0] ? e.touches[0].clientY : 0)
      startHeight = geneExpressionPanel.offsetHeight
      
      console.log('Right panel divider: Start drag', { startY, startHeight, panelHeight: geneExpressionPanel.offsetHeight })
      
      // Disable transition during drag for smoother movement
      divider.style.transition = 'none'
      geneExpressionPanel.style.transition = 'none'
      selectionsPanel.style.transition = 'none'
      
      // Add visual feedback
      document.body.style.cursor = 'row-resize'
      divider.style.backgroundColor = '#6B7280'
      
      // Prevent text selection during drag
      document.body.style.userSelect = 'none'
      
      if (e.preventDefault) e.preventDefault()
      if (e.stopPropagation) e.stopPropagation()
    }
    
    const doDrag = (e) => {
      if (!isDragging) return
      
      const clientY = e.clientY || (e.touches && e.touches[0] ? e.touches[0].clientY : startY)
      const deltaY = clientY - startY
      const newHeight = startHeight + deltaY
      
      // Calculate container height
      const containerHeight = container.offsetHeight - divider.offsetHeight
      
      // Apply constraints
      const constrainedHeight = Math.max(minPanelHeight, Math.min(newHeight, containerHeight - minPanelHeight))
      
      // Update gene expression panel height (use pixels for more precise control)
      geneExpressionPanel.style.height = constrainedHeight + 'px'
      geneExpressionPanel.style.flex = 'none' // Override flex: 1
      
      // Selections panel will automatically take remaining space due to flex: 1
      selectionsPanel.style.flex = '1 1 0%'
      selectionsPanel.style.minHeight = `${minPanelHeight}px`
      
      if (e.preventDefault) e.preventDefault()
    }
    
    const stopDrag = () => {
      if (!isDragging) return
      
      isDragging = false
      
      // Re-enable transitions
      divider.style.transition = ''
      geneExpressionPanel.style.transition = ''
      selectionsPanel.style.transition = ''
      
      // Remove visual feedback
      document.body.style.cursor = ''
      divider.style.backgroundColor = ''
      document.body.style.userSelect = ''
      
      console.log('Right panel divider: Stop drag')
    }
    
    // Event listeners - use capture phase to ensure we catch the event
    // Test if divider is clickable
    divider.addEventListener('click', (e) => {
      console.log('Right panel divider: Click detected', e)
    })
    
    divider.addEventListener('mousedown', startDrag, true)
    
    // Also try without capture as fallback
    divider.addEventListener('mousedown', (e) => {
      console.log('Right panel divider: mousedown (non-capture) detected', e)
    }, false)
    document.addEventListener('mousemove', doDrag)
    document.addEventListener('mouseup', stopDrag)
    document.addEventListener('mouseleave', stopDrag)
    
    // Also handle touch events for mobile
    const handleTouchStart = (e) => {
      if (e.touches.length === 1) {
        startDrag(e)
      }
    }
    const handleTouchMove = (e) => {
      if (isDragging && e.touches.length === 1) {
        doDrag(e)
      }
    }
    const handleTouchEnd = () => {
      stopDrag()
    }
    
    divider.addEventListener('touchstart', handleTouchStart, { passive: false })
    document.addEventListener('touchmove', handleTouchMove, { passive: false })
    document.addEventListener('touchend', handleTouchEnd)
    document.addEventListener('touchcancel', handleTouchEnd)
    
    console.log('Right panel draggable divider initialized with event listeners')
  }

  // Handle water drop button clicks
  waterDropClicked(event) {
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
    this.uiManager.showMetadataDropdownSpinner()
    
    // For continuous metadata, set the color range before visualizing
    if (button.dataset.metadataType === 'NUMERIC') {
      console.log('🎚️ Handling NUMERIC metadata for coloring')
      // Load the metadata first to get the range
      this.dataManager.loadSingleMetadataVector(metadataId).then(vectorData => {
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
              const minVal = this.dataManager.safeMin(values)
              const maxVal = this.dataManager.safeMax(values)
              console.log('🎚️ Setting full color range for continuous metadata:', minVal, maxVal)
              this.setColorRange(minVal, maxVal)
            }
            
            // Now load and visualize
            console.log('🎚️ Calling loadAndVisualizeMetadataVector for metadataId:', metadataId)
            return this.dataManager.loadAndVisualizeMetadataVector(metadataId)
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
        this.uiManager.hideMetadataDropdownSpinner()
      })
    } else {
      // For discrete metadata, just load and visualize directly
      console.log('📋 Calling loadAndVisualizeMetadataVector for discrete metadataId:', metadataId)
      this.dataManager.loadAndVisualizeMetadataVector(metadataId)
        .catch(error => {
          console.error('❌ Error loading metadata:', error)
        })
        .finally(() => {
          this.uiManager.hideMetadataDropdownSpinner()
        })
    }
    
    //console.log('=== WATER DROP CLICK COMPLETE ===')
  }
  
  // Handle gene expression coloring (similar to waterDropClicked but for genes)
  async geneWaterDropClicked(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const button = event.currentTarget
    const geneId = button.dataset.geneId
    const geneName = button.dataset.geneName
    const geneMetadataId = `gene_${geneId}`
    const isCurrentlyActive = button.dataset.active === 'true'
    
    console.log('🧬 Gene water drop clicked:', { geneId, geneName, geneMetadataId, isCurrentlyActive })
    
    if (isCurrentlyActive) {
      // Button is already active - deselect it
      console.log('🧬 Gene button is already active - deselecting...')
      this.resetAllWaterDropButtons()
      this.removeAllCategoryColors()
      this.clearMetadataColoring()
      return
    }
    
    // Get gene expression data from GeneManager
    const geneManager = this.geneManager
    if (!geneManager) {
      console.error('❌ GeneManager not available')
      alert('Gene manager not initialized.')
      return
    }
    
    // Try to find expression data - handle both string and number keys
    let expressionData = null
    const geneIdNum = parseInt(geneId)
    const geneIdStr = String(geneId)
    
    if (geneManager.geneExpressionData) {
      expressionData = geneManager.geneExpressionData[geneId] || 
                       geneManager.geneExpressionData[geneIdNum] || 
                       geneManager.geneExpressionData[geneIdStr]
    }
    
    // If data not found in memory, try IndexedDB first (fast disk access)
    if (!expressionData && this.memoryManager) {
      console.log('🧬 Expression data not in memory, checking IndexedDB...')
      const dbData = await this.memoryManager.loadGeneExpressionFromIndexedDB(geneIdStr)
      if (dbData && dbData.values && dbData.values.length > 0) {
        // Found in database - load into memory immediately
        const stableIdKey = geneIdStr
        geneManager.geneExpressionData[stableIdKey] = {
          values: dbData.values,
          stats: dbData.stats || geneManager.calculateExpressionStats(dbData.values),
          geneIndex: dbData.geneIndex,
          stableId: dbData.stableId || geneIdNum,
          symbol: dbData.symbol || geneName
        }
        
        // Also store with numeric key for compatibility
        if (!isNaN(geneIdNum)) {
          geneManager.geneExpressionData[geneIdNum] = geneManager.geneExpressionData[stableIdKey]
        }
        
        // Store in loadedMetadataVectors so filtering system can find it
        const geneMetadataId = `gene_${geneIdStr}`
        if (!this.loadedMetadataVectors) {
          this.loadedMetadataVectors = {}
        }
        const minVal = this.dataManager.safeMin(dbData.values)
        const maxVal = this.dataManager.safeMax(dbData.values)
        this.loadedMetadataVectors[geneMetadataId] = {
          id: geneMetadataId,
          name: dbData.symbol || geneName,
          display_name: dbData.symbol || geneName,
          data_type: 'NUMERIC',
          values: dbData.values,
          compression_info: {
            min_val: minVal,
            max_val: maxVal,
            data_type: 'NUMERIC'
          }
        }
        
        // Update status icon
        if (this.uiManager) {
          this.uiManager.updateGeneStatusIcon(geneIdStr, 'in-memory')
        }
        
        expressionData = geneManager.geneExpressionData[stableIdKey]
        console.log('🧬 Loaded gene expression from IndexedDB into memory')
      }
    }
    
    // If still not found, try to load from server
    if (!expressionData) {
      console.log('🧬 Expression data not found in memory or IndexedDB, attempting to load from server...')
      
      // First, try to find the gene in the DOM to extract gene information
      const geneDiv = document.querySelector(`[data-gene-item="${geneId}"], [data-gene-item="${geneIdNum}"]`)
      
      let gene = null
      
      if (geneDiv) {
        // Extract gene info from the DOM
        const header = geneDiv.querySelector('.gene-header')
        const geneNameFromDom = header?.querySelector('div[title]')?.getAttribute('title') || geneName
        
        // Try to parse gene info from the title or find it in geneTags
        const geneTag = geneManager.geneTags?.find(g => 
          String(g.stableId) === geneIdStr || 
          String(g.stableId) === String(geneIdNum) ||
          g.stableId === geneIdNum
        )
        
        if (geneTag) {
          gene = geneTag
        } else {
          // Construct gene object from available info
          // Try to extract Ensembl ID from the DOM if available
          const geneText = header?.textContent || ''
          const ensemblMatch = geneText.match(/(FBgn\d+)/)
          const ensemblId = ensemblMatch ? ensemblMatch[1] : null
          
          gene = {
            symbol: geneName,
            ensemblId: ensemblId || '',
            stableId: geneIdNum || parseInt(geneId),
            query: geneName
          }
        }
        
        if (gene) {
          console.log('🧬 Found gene, loading expression data from server...', gene)
          const resultsContainer = document.getElementById('gene-expression-results')
          if (resultsContainer) {
            // Load the data from server
            await geneManager.loadGeneExpressionData(gene, resultsContainer)
            // Try again to get the data with all possible keys
            expressionData = geneManager.geneExpressionData[gene.stableId] ||
                             geneManager.geneExpressionData[String(gene.stableId)] ||
                             geneManager.geneExpressionData[geneId] ||
                             geneManager.geneExpressionData[geneIdNum] ||
                             geneManager.geneExpressionData[geneIdStr]
          }
        }
      }
    }
    
    if (!expressionData) {
      console.error('❌ Gene expression data not available for gene:', geneId)
      console.error('Available gene IDs in expressionData:', Object.keys(geneManager.geneExpressionData || {}))
      console.error('Available gene tags:', geneManager.geneTags?.map(g => ({ symbol: g.symbol, stableId: g.stableId })))
      
      // Check if there's a loading or error state
      const statusIcon = document.querySelector(`.gene-status-icon[data-gene-id="${geneId}"], .gene-status-icon[data-gene-id="${geneIdNum}"]`)
      if (statusIcon) {
        const isVisible = statusIcon.style.display !== 'none' && statusIcon.style.display !== ''
        const title = statusIcon.title || ''
        const bgColor = statusIcon.style.backgroundColor || ''
        
        if (isVisible && bgColor.includes('rgb(220, 38, 38)')) {
          // Error state (red background)
          alert(`Expression data failed to load: ${title.replace('Error: ', '')}`)
        } else if (isVisible && bgColor.includes('rgb(156, 163, 175)')) {
          // Loading state (gray background)
          alert('Expression data is still loading. Please wait a moment and try again.')
        } else {
          // Status icon exists but not in error/loading state - might have failed silently
          alert('Expression data not available for this gene. Please check if the data loaded successfully (look for the status icon).')
        }
      } else {
        // No status icon found - gene might not have been loaded yet
        alert('Expression data not available for this gene. The gene may need to be added first, or the data may have failed to load.')
      }
      return
    }
    
    const values = expressionData.values
    
    if (!values || values.length === 0) {
      console.error('❌ No expression values available for gene:', geneId)
      alert('No expression values available for this gene.')
      return
    }
    
    // Reset all water drop buttons
    this.resetAllWaterDropButtons()
    this.hideAllResetButtons()
    this.removeAllCategoryColors()
    
    // Set this button to active
    this.setWaterDropButtonActive(button)
    
    // Only show spinner if data needs to be loaded (not already in memory)
    const wasLoading = !expressionData
    if (wasLoading) {
      this.uiManager.showMetadataDropdownSpinner()
    }
    
    // Calculate min/max for color range
    const minVal = this.dataManager.safeMin(values)
    const maxVal = this.dataManager.safeMax(values)
    
    // Check for existing range
    const existingRange = this.selectedRanges?.[geneMetadataId]
    
    if (existingRange) {
      console.log('🧬 Preserving existing range for gene:', existingRange)
      this.setColorRange(existingRange.min, existingRange.max)
    } else {
      console.log('🧬 Setting full color range for gene:', minVal, maxVal)
      this.setColorRange(minVal, maxVal)
    }
    
    // Create a metadata-like vector object for the visualization system
    const geneMetadataVector = {
      id: geneMetadataId,
      name: geneName,
      display_name: geneName,
      data_type: 'NUMERIC',
      values: values,
      compression_info: {
        min_val: minVal,
        max_val: maxVal,
        data_type: 'NUMERIC'
      },
      nber_rows: 1,
      nber_cols: values.length
    }
    
    // Store in loaded metadata vectors (similar to how metadata is stored)
    // Use controller.loadedMetadataVectors (not dataManager.loadedMetadataVectors) so filtering system can find it
    if (!this.loadedMetadataVectors) {
      this.loadedMetadataVectors = {}
    }
    this.loadedMetadataVectors[geneMetadataId] = geneMetadataVector
    
    // Set as current metadata vector
    this.currentMetadataVector = geneMetadataVector
    this.currentMetadataId = geneMetadataId
    
    // Clear cached color map
    this.colorManager.clearColorMapCache()
    
    // Update adapt color range button visibility for all range sliders
    this.updateAllRangeSliderButtonAppearances()
    
    // Initialize gradient for gene expression (synchronous - just loads from storage)
    this.gradientManager.loadGradientForMetadata(geneMetadataId)
    
    // Force reordering of points
    this._lastNumericOrderApplied = null
    
    // Update visualization with gene expression coloring (synchronous when data in memory)
    this.updateVisualizationWithMetadataVector()
    
    // Update distribution bars (synchronous)
    this.dataManager.updateAllCategoryDistributions()
    
    // Update cell filtering after loading gene vector (same as continuous metadata)
    // Pass shouldUpdateColors=true for gene expression to ensure colors are rendered after filtering
    // This ensures renderer state is properly initialized and coordinates are available for filtering
    const shouldUpdateColors = true
    this.dataManager.updateCellFiltering(shouldUpdateColors)
    
    // Hide spinner only if we showed it
    if (wasLoading) {
      this.uiManager.hideMetadataDropdownSpinner()
    }
    
    console.log('🧬 Gene expression coloring applied successfully', wasLoading ? '(after loading)' : '(instant from memory)')
  }
  
  // Reset all water drop buttons to grey (including gene buttons)
  resetAllWaterDropButtons() {
    //console.log('resetAllWaterDropButtons: Starting...')
    const allButtons = document.querySelectorAll('[data-action*="waterDropClicked"], [data-action*="geneWaterDropClicked"]')
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
  
  // Reset all x buttons to inactive state
  resetAllXButtons() {
    const allXButtons = document.querySelectorAll('.categorical-x-btn, .continuous-x-btn, .gene-x-btn')
    allXButtons.forEach((button) => {
      button.style.color = '#9ca3af'
      button.style.backgroundColor = ''
      button.dataset.active = 'false'
    })
  }
  
  // Set an x button to active (blue)
  setXButtonActive(button) {
    button.style.color = '#3b82f6'
    button.style.backgroundColor = '#dbeafe'
    button.dataset.active = 'true'
  }
  
  // Reset all y buttons to inactive state
  resetAllYButtons() {
    const allYButtons = document.querySelectorAll('.continuous-y-btn, .gene-y-btn')
    allYButtons.forEach((button) => {
      button.style.color = '#9ca3af'
      button.style.backgroundColor = ''
      button.dataset.active = 'false'
    })
  }
  
  // Set a y button to active (blue)
  setYButtonActive(button) {
    button.style.color = '#3b82f6'
    button.style.backgroundColor = '#dbeafe'
    button.dataset.active = 'true'
  }
  
  // Handle x button clicks
  xButtonClicked(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const button = event.currentTarget
    const isCurrentlyActive = button.dataset.active === 'true'
    
    if (isCurrentlyActive) {
      // Button is already active - deselect it
      this.resetAllXButtons()
      this.selectedXButton = null
      this.customPlotManager.close2DPlotModal()
      return
    }
    
    // Button is not active - select it
    // Reset all x buttons first
    this.resetAllXButtons()
    
    // Set this button to active
    this.setXButtonActive(button)
    
    // Store selected x button info
    let metadataName = 'Unknown'
    if (button.dataset.geneId) {
      // For genes, try to get name from gene manager
      const geneId = button.dataset.geneId
      const gene = this.geneManager?.geneTags?.find(g => String(g.stableId) === String(geneId))
      metadataName = gene?.symbol || button.dataset.geneName || `Gene ${geneId}`
    } else {
      // For metadata, get from DOM or dataset
      const metadataItem = button.closest('[data-metadata-item]')
      if (metadataItem) {
        const nameElement = metadataItem.querySelector('div[style*="font-size: 14px"][title]')
        metadataName = nameElement?.textContent?.trim() || nameElement?.getAttribute('title') || button.dataset.metadataName || 'Unknown'
      } else {
        metadataName = button.dataset.metadataName || 'Unknown'
      }
    }
    
    this.selectedXButton = {
      button: button,
      metadataId: button.dataset.metadataId || button.dataset.geneId,
      isGene: !!button.dataset.geneId,
      metadataName: metadataName
    }
    
    // Check if both x and y are selected
    this.customPlotManager.checkAndOpen2DPlotModal()
  }
  
  // Handle y button clicks
  yButtonClicked(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const button = event.currentTarget
    const isCurrentlyActive = button.dataset.active === 'true'
    
    if (isCurrentlyActive) {
      // Button is already active - deselect it
      this.resetAllYButtons()
      this.selectedYButton = null
      this.customPlotManager.close2DPlotModal()
      return
    }
    
    // Button is not active - select it
    // Reset all y buttons first
    this.resetAllYButtons()
    
    // Set this button to active
    this.setYButtonActive(button)
    
    // Store selected y button info
    let metadataName = 'Unknown'
    if (button.dataset.geneId) {
      // For genes, try to get name from gene manager
      const geneId = button.dataset.geneId
      const gene = this.geneManager?.geneTags?.find(g => String(g.stableId) === String(geneId))
      metadataName = gene?.symbol || button.dataset.geneName || `Gene ${geneId}`
    } else {
      // For metadata, get from DOM or dataset
      const metadataItem = button.closest('[data-metadata-item]')
      if (metadataItem) {
        const nameElement = metadataItem.querySelector('div[style*="font-size: 14px"][title]')
        metadataName = nameElement?.textContent?.trim() || nameElement?.getAttribute('title') || button.dataset.metadataName || 'Unknown'
      } else {
        metadataName = button.dataset.metadataName || 'Unknown'
      }
    }
    
    this.selectedYButton = {
      button: button,
      metadataId: button.dataset.metadataId || button.dataset.geneId,
      isGene: !!button.dataset.geneId,
      metadataName: metadataName
    }
    
    // Check if both x and y are selected
    this.customPlotManager.checkAndOpen2DPlotModal()
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
        this.rendererManager.renderCategoryLabels()
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
          this.rendererManager.renderCategoryLabels()
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

  // Initialize canvas and ReGL renderer
  initializeCanvas() {
    const plotContainer = document.querySelector('.plot-container')
    if (!plotContainer) {
      console.log('🔄 [CANVAS] Plot container not found, skipping canvas initialization')
      return
    }
    
    // CRITICAL: Check if renderer already exists with state
    // If it does, we should NOT recreate it - this would destroy the state!
    if (this.reglRenderer) {
      const hasState = this.reglRenderer.numPoints > 0 || 
                       (this.reglRenderer.positions && this.reglRenderer.positions.length > 0) ||
                       (this.reglRenderer.colors && this.reglRenderer.colors.length > 0)
      
      if (hasState) {
        console.log('🔄 [CANVAS] Renderer already exists with state, skipping initialization:', {
          rendererInstanceId: this.reglRenderer.instanceId,
          numPoints: this.reglRenderer.numPoints,
          hasPositions: !!this.reglRenderer.positions,
          hasColors: !!this.reglRenderer.colors
        })
        return
      } else {
        // Renderer exists but has no state - check if plot is visible
        // If plot is visible, something is wrong - we shouldn't replace the renderer
        const plotContainer = document.querySelector('.plot-container')
        const plotVisible = plotContainer && plotContainer.offsetWidth > 0 && plotContainer.offsetHeight > 0
        const hasCanvasInDOM = this.canvas && this.canvas.parentElement
        
        if (plotVisible || hasCanvasInDOM) {
          console.error('🔄 [CANVAS] CRITICAL: Renderer has no state but plot is visible!')
          console.error('🔄 [CANVAS] This suggests the renderer reference is wrong or state was lost.')
          console.error('🔄 [CANVAS] Renderer instance:', this.reglRenderer.instanceId)
          console.error('🔄 [CANVAS] Plot visible:', plotVisible, 'Canvas in DOM:', hasCanvasInDOM)
          console.trace('🔄 [CANVAS] Stack trace for initializeCanvas call')
          // Don't recreate - preserve the renderer reference even if it seems wrong
          // The actual rendering might be working with a different renderer instance
          return
        } else {
          console.log('🔄 [CANVAS] Renderer exists but has no state, and plot is not visible, will recreate:', {
            rendererInstanceId: this.reglRenderer.instanceId
          })
        }
      }
    }
    
    // Check if canvas already exists and is valid
    if (this.canvas && this.canvas.parentElement === plotContainer) {
      console.log('🔄 [CANVAS] Canvas already exists, reusing it')
      // Canvas already exists, just ensure renderer is set up
      if (!this.reglRenderer) {
        console.log('🔄 [CANVAS] Creating renderer for existing canvas')
        console.trace('🔄 [CANVAS] Stack trace for renderer creation in initializeCanvas')
        this.reglRenderer = new ReglRenderer(this.canvas)
        console.log(`🔄 [CANVAS] New renderer created: ${this.reglRenderer.instanceId}`)
      } else {
        console.log('🔄 [CANVAS] Renderer already exists, preserving:', {
          rendererInstanceId: this.reglRenderer.instanceId,
          numPoints: this.reglRenderer.numPoints,
          hasPositions: !!this.reglRenderer.positions,
          hasColors: !!this.reglRenderer.colors
        })
      }
      return
    }
    
    console.log('🔄 [CANVAS] Initializing canvas and ReGL renderer...')
    
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
    
    // Store canvas reference
    this.canvas = canvas
    
    // Initialize ReGL renderer
    console.log('🔄 [CANVAS] Initializing ReGL renderer...')
    console.trace('🔄 [CANVAS] Stack trace for renderer creation in initializeCanvas (new canvas)')
    this.reglRenderer = new ReglRenderer(canvas)
    console.log(`🔄 [CANVAS] New renderer created: ${this.reglRenderer.instanceId}`)
    
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
    
    this.overlayCanvas = overlayCanvas
    this.overlayCtx = overlayCanvas.getContext('2d')
    
    console.log('🔄 [CANVAS] Canvas initialization completed:', {
      canvas: { width: canvas.width, height: canvas.height },
      overlayCanvas: { width: overlayCanvas.width, height: overlayCanvas.height }
    })
  } // End of initializeCanvas

  // Handle window resize with debouncing
  async handleWindowResize() {
    // Debounce resize events to avoid excessive redraws during drag
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout)
    }
    
    // Use a longer debounce to prevent flickering during drag
    this.resizeTimeout = setTimeout(() => {
      console.log('🔄 [RESIZE] Window resized, redrawing plot...')
      
      // Check if canvas and renderer are ready
      if (!this.canvas || !this.reglRenderer) {
        console.log('🔄 [RESIZE] Canvas or renderer not ready, skipping resize')
        return
      }
      
      // Prevent resize during active mouse interactions (panning, lasso, etc.)
      if (this.isPanning || this.isDrawingLasso || this.isZooming) {
        console.log('🔄 [RESIZE] Mouse interaction in progress, skipping resize')
        return
      }
      
      // Simply call redrawPlot - it will handle everything
      this.redrawPlot()
    }, 300) // 300ms debounce to prevent flickering during drag
  }
  
  // Redraw the plot after resize
  async redrawPlot() {
    console.log('🔄 [RESIZE] Starting redrawPlot - forcing complete reinitialization...')
    
    // Check if we have coordinates
    if (!this.currentCoordinates) {
      console.log('🔄 [RESIZE] Cannot redraw - missing coordinates')
      return
    }
    
    const plotContainer = document.querySelector('.plot-container')
    if (!plotContainer) {
      console.log('🔄 [RESIZE] Plot container not found')
      return
    }
    
    // Get new dimensions from container
    const newWidth = plotContainer.clientWidth
    const newHeight = plotContainer.clientHeight
    
    console.log('🔄 [RESIZE] Resizing to', newWidth, 'x', newHeight)
    
    if (newWidth <= 0 || newHeight <= 0) {
      console.log('🔄 [RESIZE] Invalid dimensions, skipping resize')
      return
    }
    
    // Preserve current state (bounds for pan/zoom, displayOrder for filtering, filtering/coloring state)
    const preservedBounds = this.currentBounds
    const preservedDisplayOrder = this.displayOrder ? [...this.displayOrder] : null
    const preservedMetadataVector = this.currentMetadataVector
    const preservedMetadataId = this.currentMetadataId
    
    // Preserve filtering state (selectedCategories and selectedRanges)
    const preservedSelectedCategories = this.selectedCategories && Object.keys(this.selectedCategories).length > 0 ? {} : null
    if (preservedSelectedCategories && this.selectedCategories) {
      for (const [metadataId, categorySet] of Object.entries(this.selectedCategories)) {
        preservedSelectedCategories[metadataId] = new Set(categorySet)
      }
    }
    const preservedSelectedRanges = this.selectedRanges && Object.keys(this.selectedRanges).length > 0 ? { ...this.selectedRanges } : null
    
    console.log('🔄 [RESIZE] Preserved bounds:', preservedBounds)
    console.log('🔄 [RESIZE] Preserved displayOrder length:', preservedDisplayOrder ? preservedDisplayOrder.length : null)
    console.log('🔄 [RESIZE] Preserved filtering state:', {
      selectedCategories: preservedSelectedCategories ? Object.keys(preservedSelectedCategories).length : 0,
      selectedRanges: preservedSelectedRanges ? Object.keys(preservedSelectedRanges).length : 0
    })
    
    // Force destroy existing renderer to ensure complete reinitialization
    if (this.reglRenderer) {
      console.log('🔄 [RESIZE] Destroying existing renderer for complete reinitialization')
      this.reglRenderer.destroy()
      this.reglRenderer = null
    }
    
    // Clear canvas references so they get recreated with correct size
    this.canvas = null
    this.overlayCanvas = null
    this.overlayCtx = null
    
    // Reset canvas listeners flag
    this.canvasListenersSetup = false
    
    // Clear cached canvas rect
    this.cachedCanvasRect = null
    
    // Check if filtering is active - if so, add white overlay to hide canvas during resize
    const hasActiveFiltering = (preservedSelectedCategories && Object.keys(preservedSelectedCategories).length > 0) ||
                               (preservedSelectedRanges && Object.keys(preservedSelectedRanges).length > 0)
    
    // Restore filtering state BEFORE initialization
    if (hasActiveFiltering) {
      // Restore selectedCategories
      if (preservedSelectedCategories) {
        this.selectedCategories = {}
        for (const [metadataId, categorySet] of Object.entries(preservedSelectedCategories)) {
          this.selectedCategories[metadataId] = new Set(categorySet)
        }
        console.log('🔄 [RESIZE] Restored selectedCategories for', Object.keys(this.selectedCategories).length, 'metadata')
      }
      
      // Restore selectedRanges
      if (preservedSelectedRanges) {
        this.selectedRanges = { ...preservedSelectedRanges }
        console.log('🔄 [RESIZE] Restored selectedRanges for', Object.keys(this.selectedRanges).length, 'metadata')
      }
    }
    
    // Reinitialize the scatter plot from scratch - this will create new canvas/renderer with correct size
    console.log('🔄 [RESIZE] Reinitializing scatter plot from scratch with', this.currentCoordinates.length, 'coordinates...')
    await this.rendererManager.initializeScatterPlot(this.currentCoordinates)
    
    // Add white overlay AFTER initialization to cover canvas during resize (container might be cleared during init)
    let resizeOverlay = null
    if (hasActiveFiltering) {
      console.log('🔄 [RESIZE] Adding white overlay to prevent glitch during resize...')
      const plotContainer = document.querySelector('.plot-container')
      if (plotContainer) {
        // Remove any existing overlay first
        const existingOverlay = document.getElementById('resize-filter-overlay')
        if (existingOverlay) {
          existingOverlay.remove()
        }
        
        // Create white overlay div
        resizeOverlay = document.createElement('div')
        resizeOverlay.id = 'resize-filter-overlay'
        // Ensure plot container has position relative for absolute positioning to work
        if (getComputedStyle(plotContainer).position === 'static') {
          plotContainer.style.position = 'relative'
        }
        resizeOverlay.style.cssText = 'position: absolute; top: 0; left: 0; right: 0; bottom: 0; width: 100%; height: 100%; background-color: white; z-index: 99999; pointer-events: none;'
        plotContainer.appendChild(resizeOverlay)
        console.log('🔄 [RESIZE] White overlay added, plotContainer:', {
          container: plotContainer,
          containerPosition: getComputedStyle(plotContainer).position,
          overlay: resizeOverlay,
          overlayStyle: resizeOverlay.style.cssText,
          containerChildren: plotContainer.children.length
        })
      } else {
        console.warn('🔄 [RESIZE] Plot container not found!')
      }
    }
    
    // Restore preserved bounds and reapply them
    if (preservedBounds) {
      console.log('🔄 [RESIZE] Restoring preserved bounds and re-normalizing positions...')
      this.currentBounds = preservedBounds
      
      // Restore display order if it was preserved
      if (preservedDisplayOrder && preservedDisplayOrder.length === this.currentCoordinates.length) {
        this.displayOrder = preservedDisplayOrder
        console.log('🔄 [RESIZE] Restored displayOrder with', preservedDisplayOrder.length, 'entries')
      }
      
      // Re-normalize all positions with preserved bounds for the new canvas size
      if (this.reglRenderer && this.interactionHandler) {
        const coordinatesToUse = this.displayOrder ? this.displayOrder.map(i => this.currentCoordinates[i]) : this.currentCoordinates
        const screenCoordinates = new Float32Array(coordinatesToUse.length * 2)
        
        for (let i = 0; i < coordinatesToUse.length; i++) {
          const [x, y] = coordinatesToUse[i]
          screenCoordinates[i * 2] = this.interactionHandler.normalizeX(x, preservedBounds)
          screenCoordinates[i * 2 + 1] = this.interactionHandler.normalizeY(y, preservedBounds)
        }
        
        // Update positions in renderer with preserved bounds
        this.reglRenderer.setPositions(screenCoordinates)
        
        // Don't render yet if filtering is active - wait for filtering to be applied
        if (!preservedSelectedCategories && !preservedSelectedRanges) {
          this.reglRenderer.render()
        }
        
        // Redraw overlay elements with preserved bounds
        if (this.rendererManager) {
          this.rendererManager.renderGrid()
          this.rendererManager.renderAxes()
          
          if (preservedMetadataVector) {
            // Restore metadata vector reference
            this.currentMetadataVector = preservedMetadataVector
            this.currentMetadataId = preservedMetadataId
            
            if (preservedMetadataVector.data_type === 'DISCRETE' || preservedMetadataVector.data_type === 'STRING') {
              this.rendererManager.renderCategoryLabels()
            } else if (preservedMetadataVector.data_type === 'NUMERIC') {
              this.renderContinuousColorLegend()
            }
          }
        }
        
        console.log('🔄 [RESIZE] Bounds restored and positions re-normalized')
      }
    }
    
    // Restore metadata vector reference before filtering (needed for filtering logic)
    if (preservedMetadataVector && preservedMetadataId) {
      this.currentMetadataVector = preservedMetadataVector
      this.currentMetadataId = preservedMetadataId
    }
    
    // Now apply filtering (will update visibility and render)
    if (hasActiveFiltering) {
      // Reapply filtering - this will update visibility based on preserved filters
      if (this.dataManager) {
        console.log('🔄 [RESIZE] Reapplying filtering after bounds restoration...')
        // Trigger filtering update (this uses requestAnimationFrame internally)
        this.dataManager.updateCellFiltering()
        
        // Wait for the filtering's internal requestAnimationFrame to complete
        // Then apply coloring and remove overlay
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            // After filtering is applied, restore coloring if needed
            if (preservedMetadataVector && preservedMetadataId && this.reglRenderer) {
              console.log('🔄 [RESIZE] Reapplying coloring after filtering...')
              this.renderPointsWithCurrentColoring()
            }
            
            // Remove white overlay after both filtering and coloring are applied
            // Use one more requestAnimationFrame to ensure rendering is complete
            requestAnimationFrame(() => {
              if (resizeOverlay && resizeOverlay.parentNode) {
                resizeOverlay.remove()
                console.log('🔄 [RESIZE] White overlay removed after filtering and coloring applied')
              }
            })
          })
        })
      }
    } else {
      // No filtering - restore coloring
      if (preservedMetadataVector && preservedMetadataId) {
        console.log('🔄 [RESIZE] Restoring coloring state (no filtering)...')
        if (this.reglRenderer) {
          console.log('🔄 [RESIZE] Reapplying coloring...')
          this.renderPointsWithCurrentColoring()
        }
      }
    }
    
    console.log('🔄 [RESIZE] Redraw completed')
  }
  
  /*  async redrawPlot() {
    console.log('🔄 [RESIZE] Starting simple redrawPlot...')
    
    // Check if we have the necessary components
    if (!this.reglRenderer || !this.currentCoordinates) {
      console.log('🔄 [RESIZE] Cannot redraw - missing renderer or coordinates')
      return
    }
    
    // Get current canvas dimensions
    const canvas = this.canvas
    if (!canvas) {
      console.log('🔄 [RESIZE] No canvas found')
      return
    }
    
    const rect = canvas.getBoundingClientRect()
    const newWidth = Math.round(rect.width)
    const newHeight = Math.round(rect.height)
    
    console.log('🔄 [RESIZE] Resizing canvas from', this.canvas.width, 'x', this.canvas.height, 'to', newWidth, 'x', newHeight)
    
    // Check if canvas dimensions are valid
    if (newWidth <= 0 || newHeight <= 0) {
      console.log('🔄 [RESIZE] Invalid canvas dimensions, skipping resize')
      return
    }
    
    // Update overlay canvas to match
    if (this.overlayCanvas) {
      this.overlayCanvas.width = newWidth
      this.overlayCanvas.height = newHeight
      this.overlayCtx.clearRect(0, 0, newWidth, newHeight)
    }
    
    // Reset coordinate normalization debug flags to see fresh debug info
    if (this.interactionHandler) {
      this.interactionHandler._normalizeLogged = false
      this.interactionHandler._normalizeYLogged = false
    }
    
    // Clear cached canvas rect to force fresh calculation after resize
    this.cachedCanvasRect = null
    
    // If renderer exists and has state, resize it and re-normalize positions to new dimensions
    // This prevents shift by recalculating positions with the new canvas dimensions
    if (this.reglRenderer && this.reglRenderer.numPoints > 0 && this.currentCoordinates && this.currentBounds) {
      console.log('🔄 [RESIZE] Resizing existing renderer and re-normalizing positions...')
      
      const oldWidth = this.canvas.width
      const oldHeight = this.canvas.height
      
      // Update canvas dimensions
      this.canvas.width = newWidth
      this.canvas.height = newHeight
      
      // Re-normalize all positions to the new canvas dimensions
      // This is critical to prevent shift when other operations happen
      const screenCoordinates = new Float32Array(this.currentCoordinates.length * 2)
      for (let i = 0; i < this.currentCoordinates.length; i++) {
        const [x, y] = this.currentCoordinates[i]
        screenCoordinates[i * 2] = this.interactionHandler.normalizeX(x, this.currentBounds)
        screenCoordinates[i * 2 + 1] = this.interactionHandler.normalizeY(y, this.currentBounds)
      }
      
      // Update positions in renderer with new normalized coordinates
      this.reglRenderer.setPositions(screenCoordinates)
      
      // Update viewport and render
      this.reglRenderer.resize(newWidth, newHeight)
      this.reglRenderer.render()
      
      // Redraw overlay
      this.rendererManager.renderGrid()
      this.rendererManager.renderAxes()
      if (this.currentMetadataVector) {
        if (this.currentMetadataVector.data_type === 'DISCRETE' || this.currentMetadataVector.data_type === 'STRING') {
          this.rendererManager.renderCategoryLabels()
        } else if (this.currentMetadataVector.data_type === 'NUMERIC') {
          this.renderContinuousColorLegend()
        }
      }
      console.log('🔄 [RESIZE] Renderer resized and positions re-normalized from', oldWidth, 'x', oldHeight, 'to', newWidth, 'x', newHeight)
      return
    }
    
    // Call the same method as when switching visualization metadata
    // This will properly reinitialize the scatter plot with the new canvas dimensions
    console.log('🔄 [RESIZE] Calling updateMetadata like metadata switch...')
    this.updateMetadata()
    
    console.log('🔄 [RESIZE] Simple redraw completed')
  }
*/
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
      const originalBounds = this.dataManager.calculateBounds(this.currentCoordinates)
      this.currentBounds = originalBounds
      //console.log('Initialized currentBounds in setInteractionMode:', this.currentBounds)
    }
    
    // Update cursor based on mode
    const canvas = this.canvas
    if (canvas) {
      if (mode === 'lasso') {
        canvas.style.cursor = 'crosshair'
      } else if (mode === 'pan') {
        canvas.style.cursor = 'grab'
      } else if (mode === 'pick') {
        canvas.style.cursor = 'pointer'
      }
    }
    
    // Update control instructions
    this.updateControlInstructions()
    
    // Remove existing event listeners and add new ones
    this.removeInteractionEventListeners()
    this.addInteractionEventListeners()
    
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
    const canvas = this.canvas
    if (!canvas) {
      console.log('⚠️ No canvas available for interaction listeners')
      console.log('🔍 [DEBUG] Canvas state:', {
        canvas: !!this.canvas,
        reglRenderer: !!this.reglRenderer,
        interactionMode: this.interactionMode
      })
      return
    }
    
    console.log('✅ [DEBUG] Adding interaction event listeners to canvas:', {
      canvas: !!canvas,
      width: canvas.width,
      height: canvas.height,
      interactionMode: this.interactionMode
    })
    
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
    
    // Add pointermove to CANVAS only (not document) to avoid blocking main thread when hovering over UI
    canvas.addEventListener('pointermove', this.boundMouseMove)
    this.canvasMoveListenerAdded = true
    
    console.log('✅ Event listeners registered - pointermove on CANVAS only (not document)')
    
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
    const canvas = this.canvas
    if (!canvas) return
    
    if (this.boundMouseDown) {
      canvas.removeEventListener('pointerdown', this.boundMouseDown)
    }
    if (this.boundMouseMove) {
      // Remove from canvas if we added it there
      if (this.canvasMoveListenerAdded && canvas) {
        canvas.removeEventListener('pointermove', this.boundMouseMove)
        this.canvasMoveListenerAdded = false
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
    console.log('🔍 [DEBUG] Interaction mouse down:', {
      eventType: event.type,
      interactionMode: this.interactionMode,
      canvas: !!this.canvas,
      target: event.target?.tagName
    })
    if (this.interactionMode === 'lasso') {
      this.onLassoMouseDown(event)
    } else if (this.interactionMode === 'pan') {
      this.onPanMouseDown(event)
    } else if (this.interactionMode === 'pick') {
      this.onPickMouseDown(event)
    }
  }

  onInteractionMouseMove(event) {
    // Track how often this is called (for debugging performance issues)
    if (!this.mouseMoveCount) this.mouseMoveCount = 0
    this.mouseMoveCount++
    
    if (this.mouseMoveCount % 100 === 0) {
      console.log(`⚠️ [PERF] onInteractionMouseMove called ${this.mouseMoveCount} times - this might be blocking the main thread!`)
    }
    
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
      this.rendererManager.renderGrid()
      this.rendererManager.renderAxes()
      this.rendererManager.renderCategoryLabels()
      
      return
    }
    
    // Handle point hovering in pick mode (ReGL) - THROTTLED to prevent blocking main thread
    if (this.interactionMode === 'pick' && this.rendererType === 'regl' && !this.isTooltipFixed) {
      // Throttle hover detection to max 60fps (every 16ms)
      const now = performance.now()
      if (!this.lastHoverCheckTime || (now - this.lastHoverCheckTime) >= 16) {
        this.lastHoverCheckTime = now
        this.detectRegLPointHover(event)
      }
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
    const canvas = this.canvas
    const rect = canvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    
    // Basic zoom implementation with faster increments, zooming around mouse cursor
    const delta = event.deltaY > 0 ? 1.05 : 0.95
    
    // Get canvas dimensions
    const canvasWidth = this.canvas.width
    const canvasHeight = this.canvas.height
    
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
          this.rendererManager.renderGrid()
          this.rendererManager.renderAxes()
          
          // Re-render the appropriate legend/labels based on metadata type
          if (this.currentMetadataVector?.data_type === 'DISCRETE' || this.currentMetadataVector?.data_type === 'STRING') {
            this.rendererManager.renderCategoryLabels()
          } else if (this.currentMetadataVector?.data_type === 'NUMERIC') {
            this.renderContinuousColorLegend()
          }
        })
      }, 100) // Update UI elements after zoom stabilizes
    
    
    // Return false to ensure no default scroll behavior
    return false
  }
  // Lasso mode handlers
  onLassoMouseDown(event) {
    console.log('========================================')
    console.log('⏱️ [LASSO] Starting lasso selection')
    console.log('🔍 [DEBUG] Lasso mouse down called:', {
      eventType: event.type,
      interactionMode: this.interactionMode,
      isDrawingLasso: this.isDrawingLasso,
      canvas: !!this.canvas
    })
    
    // Detect browser and store it
    //this.isFirefox = navigator.userAgent.toLowerCase().indexOf('firefox') > -1
    
   
    
    // Create HTML canvas overlay for lasso drawing
    const plotContainer = document.querySelector('.plot-container')
    if (plotContainer && !this.lassoCanvas) {
      const canvas = this.canvas
      
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
    
   
    
    this.isDrawingLasso = true
    this.lassoPoints = []
    this.mouseMoveCount = 0
    this.interactionMoveCount = 0
    this.lastMouseMoveTime = performance.now()
    
    // Get mouse position relative to canvas
    const canvas = this.canvas 
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
    
    const canvas = this.canvas
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
    const canvas = this.canvas
    if (!canvas) return
    
    // Cache rect for performance during mouse moves
    const rect = canvas.getBoundingClientRect()
    this.cachedCanvasRect = rect
    
    this.panStartX = event.clientX - rect.left
    this.panStartY = event.clientY - rect.top
    
    // Store current bounds
    this.panStartBounds = { ...this.currentBounds }
    
    // Store original bounds for consistent pan scaling
    this.panOriginalBounds = this.dataManager.calculateBounds(this.currentCoordinates)
    
    
    // Note: Panning shape optimization is not needed in ReGL mode
    // ReGL handles large datasets efficiently without needing a simplified shape
    
    // Change cursor to grabbing
    const panCanvas = this.canvas
    if (panCanvas) {
      panCanvas.style.cursor = 'grabbing'
    }
  }

  onPanMouseMove(event) {
    if (!this.isPanning) return
    
    // Get current mouse position
    const canvas = this.canvas
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
    const screenWidth = this.canvas.width
    const screenHeight = this.canvas.height
    
    // Debug: Log panning calculation parameters
    // console.log('🔍 [PAN DEBUG] Panning calculation:', {
    //   deltaX, deltaY,
    //   screenWidth, screenHeight,
    //   panStartBounds: this.panStartBounds,
    //   canvasRect: this.cachedCanvasRect,
    //   currentBounds: this.currentBounds
    // })
    
    // Use canvas buffer size for pan calculation to match coordinate normalization
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
    this.rendererManager.renderGrid()
    this.rendererManager.renderAxes()
    
    // In ReGL mode, we need to redraw labels/legend too since renderGrid() clears the canvas
      if (this.currentMetadataVector?.data_type === 'DISCRETE' || this.currentMetadataVector?.data_type === 'STRING') {
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked) {
          this.rendererManager.renderCategoryLabels()
        }
      } else if (this.currentMetadataVector?.data_type === 'NUMERIC') {
        // Re-render continuous color legend during panning
        this.renderContinuousColorLegend()
      }
    
    
    // Move the points to match the new bounds during panning
    this.updatePointPositions()

    // Note: Panning shape not needed in ReGL mode
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
          this.rendererManager.renderCategoryLabels()
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
    const stopCanvas = this.canvas
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
    
    // Reset to original bounds
    const originalBounds = this.dataManager.calculateBounds(this.currentCoordinates)
    const newBounds = originalBounds
    this.currentBounds = newBounds
    
    // ReGL PATH: Re-normalize all coordinates with original bounds
    
      console.log('🔄 [ReGL] Resetting view - re-normalizing all coordinates')
      
      if (this.reglRenderer) {
        const screenCoordinates = new Float32Array(this.displayOrder.length * 2)
        
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const [x, y] = this.currentCoordinates[cellIndex]
          screenCoordinates[drawPos * 2] = this.interactionHandler.normalizeX(x, newBounds)
          screenCoordinates[drawPos * 2 + 1] = this.interactionHandler.normalizeY(y, newBounds)
        }
        
        // Update positions in ReGL
        this.reglRenderer.updatePositions(screenCoordinates)
        this.reglRenderer.render()
        
        // Redraw overlay (grid, axes, labels)
        this.rendererManager.renderGrid()
        this.rendererManager.renderAxes()
        
        // Re-render category labels if visible
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked && this.currentMetadataVector?.data_type === 'DISCRETE') {
          this.rendererManager.renderCategoryLabels()
        }
        
        console.log('🔄 [ReGL] View reset complete')
      }
      return
    
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

  
  updatePointPositions() {
    // ===== ReGL PATH: Re-normalize all positions with current bounds =====
   
      if (!this.currentCoordinates || !this.currentBounds || !this.reglRenderer) {
        console.log('Cannot update positions - missing data (ReGL)')
        return
      }
      
      // console.log('🔍 [UPDATE POSITIONS] Re-normalizing coordinates with:', {
      //   canvasSize: { width: this.canvas.width, height: this.canvas.height },
      //   bounds: this.currentBounds,
      //   numPoints: this.currentCoordinates.length
      // })
      
      // Re-normalize all coordinates to screen space with current bounds
      // Use displayOrder to maintain proper draw order
      const screenCoordinates = new Float32Array(this.displayOrder.length * 2)
      for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
        const cellIndex = this.displayOrder[drawPos]
        const [x, y] = this.currentCoordinates[cellIndex]
        screenCoordinates[drawPos * 2] = this.interactionHandler.normalizeX(x, this.currentBounds)
        screenCoordinates[drawPos * 2 + 1] = this.interactionHandler.normalizeY(y, this.currentBounds)
      }
      
      // Fast update using buffer.subdata()
      this.reglRenderer.updatePositions(screenCoordinates)
      this.reglRenderer.render()
      return
   
  }

  // Translate existing point positions for pan operations
  translatePointPositions() {
    if (!this.panStartBounds || !this.currentBounds) return

    const canvas = this.canvas
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

    const canvas = this.canvas
    if (!canvas) return

    // ===== ReGL PATH: Re-normalize all positions with new bounds =====
   
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
        screenCoordinates[drawPos * 2] = this.interactionHandler.normalizeX(x, newBounds)
        screenCoordinates[drawPos * 2 + 1] = this.interactionHandler.normalizeY(y, newBounds)
      }
      
      // Fast update using buffer.subdata()
      this.reglRenderer.updatePositions(screenCoordinates)
      this.reglRenderer.render()
      
      console.log('✅ [ZOOM] ReGL zoom complete')
      return
    
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





  // Render continuous color legend for continuous metadata
  renderContinuousColorLegend() {
    // Dispatch to Canvas 2D for ReGL mode
      return this.rendererManager.renderContinuousColorLegendCanvas2D()
    }
    

  // Initialize overlay canvas event listeners for gradient legend interaction
  initializeGradientLegendListeners() {
    this.gradientManager.initializeGradientLegendListeners()
  }

  // Initialize default gradient based on value distribution

  // Open gradient editor modal

  // Initialize default gradient based on value distribution
  
  
  // Handle clicking on gradient bar to add new control point
  gradientBarClicked(event) {
    this.gradientManager.gradientBarClicked(event)
  }
  
  // Sort control points by position
  sortControlPoints() {
    if (this.customGradientControlPoints) {
      this.customGradientControlPoints.sort((a, b) => a.position - b.position)
    } else if (this.gradientControlPoints) {
      this.gradientControlPoints.sort((a, b) => a.position - b.position)
    }
    
    this.rendererManager.renderModalGradientPreview()
    this.rendererManager.renderModalControlPointMarkers()
  }
  
  // Select a control point for editing
  selectControlPoint(index) {
    // Delegate to gradientManager
    this.gradientManager.selectControlPoint(index)
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
      
      // Sort and update display
      controlPoints.sort((a, b) => a.position - b.position)
      
      // Save gradient for current metadata
      this.gradientManager.saveGradientForMetadata(this.currentMetadataId)
      
      // Update selected index after sorting
      const sortedIndex = controlPoints.findIndex(p => 
        Math.abs(p.position - position) < 0.0001
      )
      if (sortedIndex >= 0) {
        this.selectedControlPointIndex = sortedIndex
      }
      
      this.gradientManager.updateGradientDisplay()
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
    console.log('🎨 updateControlPointColor CALLED')
    console.log('🎨 updateControlPointColor: this controller instance', this)
    console.log('🎨 updateControlPointColor: selectedControlPointIndex', this.selectedControlPointIndex)
    console.log('🎨 updateControlPointColor: customGradientControlPoints', this.customGradientControlPoints)
    console.log('🎨 updateControlPointColor: gradientControlPoints', this.gradientControlPoints)
    console.log('🎨 updateControlPointColor: has gradientManager', !!this.gradientManager)
    
    // Try to find the main controller instance that has the gradient state
    let mainController = this
    const mainVisualizationDiv = document.querySelector('[data-controller="visualization"][data-visualization-embeddings-by-loom-value]')
    if (mainVisualizationDiv && mainVisualizationDiv !== this.element) {
      try {
        const mainControllerInstance = this.application.getControllerForElementAndIdentifier(mainVisualizationDiv, 'visualization')
        if (mainControllerInstance && mainControllerInstance !== this) {
          console.log('🎨 updateControlPointColor: Found main controller instance, using it')
          mainController = mainControllerInstance
        }
      } catch (e) {
        console.warn('🎨 ⚠️ updateControlPointColor: Could not get main controller', e)
      }
    }
    
    // Use main controller's state
    if (mainController !== this) {
      console.log('🎨 updateControlPointColor: Switching to main controller instance')
      console.log('🎨 updateControlPointColor: mainController.selectedControlPointIndex', mainController.selectedControlPointIndex)
      console.log('🎨 updateControlPointColor: mainController.customGradientControlPoints', mainController.customGradientControlPoints)
      console.log('🎨 updateControlPointColor: mainController.gradientControlPoints', mainController.gradientControlPoints)
    }
    
    const hexColor = event.target.value
    const color = parseInt(hexColor.substring(1), 16)
    console.log('🎨 updateControlPointColor: new color', hexColor, '(', color, ')')
    
    // Initialize targetIndex from selectedControlPointIndex
    let targetIndex = mainController.selectedControlPointIndex
    
    // Use main controller's gradient arrays
    if (!mainController.customGradientControlPoints && !mainController.gradientControlPoints) {
      console.warn('🎨 ⚠️ updateControlPointColor: Both gradient arrays undefined in main controller! Trying to recover...')
      
      // Try to access through gradientManager which might have the state
      if (mainController.gradientManager) {
        console.log('🎨 updateControlPointColor: gradientManager exists, checking its controller state')
        // The gradientManager's controller should be the same instance
        if (mainController.gradientManager.controller) {
          if (mainController.gradientManager.controller.customGradientControlPoints) {
            mainController.customGradientControlPoints = JSON.parse(JSON.stringify(mainController.gradientManager.controller.customGradientControlPoints))
            console.log('🎨 updateControlPointColor: Recovered customGradientControlPoints from gradientManager', mainController.customGradientControlPoints)
          }
          if (mainController.gradientManager.controller.gradientControlPoints && !mainController.gradientControlPoints) {
            mainController.gradientControlPoints = JSON.parse(JSON.stringify(mainController.gradientManager.controller.gradientControlPoints))
            console.log('🎨 updateControlPointColor: Recovered gradientControlPoints from gradientManager', mainController.gradientControlPoints)
          }
        }
      }
      
      // If still undefined, try to reinitialize
      if (!this.customGradientControlPoints && !this.gradientControlPoints) {
        console.warn('🎨 ⚠️ updateControlPointColor: Still undefined, trying to reinitialize...')
        if (this.currentMetadataVector?.data_type === 'NUMERIC') {
          this.colorManager.initializeDefaultGradient()
          console.log('🎨 updateControlPointColor: After reinit, gradientControlPoints', this.gradientControlPoints)
        } else {
          console.error('🎨 ❌ updateControlPointColor: Cannot initialize - currentMetadataVector:', this.currentMetadataVector)
          // Try one more thing - get the controller from the modal element
          const modal = document.getElementById('gradient-editor-modal')
          if (modal) {
            try {
              const modalController = this.application.getControllerForElementAndIdentifier(modal, 'visualization')
              if (modalController && modalController !== this) {
                console.log('🎨 updateControlPointColor: Found different controller instance, using its state')
                if (modalController.customGradientControlPoints) {
                  this.customGradientControlPoints = JSON.parse(JSON.stringify(modalController.customGradientControlPoints))
                  console.log('🎨 updateControlPointColor: Copied customGradientControlPoints from modal controller')
                }
                if (modalController.gradientControlPoints && !this.gradientControlPoints) {
                  this.gradientControlPoints = JSON.parse(JSON.stringify(modalController.gradientControlPoints))
                  console.log('🎨 updateControlPointColor: Copied gradientControlPoints from modal controller')
                }
                if (modalController.selectedControlPointIndex !== undefined) {
                  const recoveredIndex = modalController.selectedControlPointIndex
                  if (targetIndex === undefined) {
                    targetIndex = recoveredIndex
                  }
                  this.selectedControlPointIndex = recoveredIndex
                  console.log('🎨 updateControlPointColor: Copied selectedControlPointIndex from modal controller', recoveredIndex)
                }
                // Also copy currentMetadataVector if we don't have it
                if (!this.currentMetadataVector && modalController.currentMetadataVector) {
                  this.currentMetadataVector = modalController.currentMetadataVector
                  console.log('🎨 updateControlPointColor: Copied currentMetadataVector from modal controller')
                }
              }
            } catch (e) {
              console.warn('🎨 ⚠️ updateControlPointColor: Error getting modal controller', e)
            }
          }
          if (!this.customGradientControlPoints && !this.gradientControlPoints) {
            console.error('🎨 ❌ updateControlPointColor: Cannot proceed - no gradient data available')
            return
          }
        }
      }
    }
    
    // Ensure we have a custom gradient array - create a deep copy if needed
    if (!this.customGradientControlPoints) {
      console.log('🎨 updateControlPointColor: creating custom gradient from', this.gradientControlPoints)
      if (this.gradientControlPoints && this.gradientControlPoints.length > 0) {
        // Create deep copy of control points
        this.customGradientControlPoints = this.gradientControlPoints.map(p => ({
          position: p.position,
          color: p.color
        }))
        console.log('🎨 updateControlPointColor: Created custom gradient', this.customGradientControlPoints)
      } else {
        console.error('🎨 ❌ updateControlPointColor: no gradientControlPoints to copy after reinit!')
        return
      }
    }
    
    // If selectedControlPointIndex is undefined, try to recover it from data attributes
    // This can happen if the selection was lost but the editor is still open
    if (targetIndex === undefined) {
      console.warn('🎨 ⚠️ updateControlPointColor: selectedControlPointIndex is undefined, trying to recover from data attributes')
      
      // Try to get from color input data attribute first
      const colorInput = event.target
      if (colorInput && colorInput.dataset.controlPointIndex !== undefined) {
        targetIndex = parseInt(colorInput.dataset.controlPointIndex, 10)
        console.log('🎨 updateControlPointColor: Recovered index from color input data attribute', targetIndex)
        mainController.selectedControlPointIndex = targetIndex
      } else {
        // Try to get from editor data attribute
        const editor = document.getElementById('gradient-control-point-editor')
        if (editor && editor.dataset.selectedControlPointIndex !== undefined) {
          targetIndex = parseInt(editor.dataset.selectedControlPointIndex, 10)
          console.log('🎨 updateControlPointColor: Recovered index from editor data attribute', targetIndex)
          mainController.selectedControlPointIndex = targetIndex
        } else {
          // Fallback: try to find by reading the position input value
          const positionInput = document.getElementById('gradient-control-point-position')
          if (positionInput && positionInput.value) {
            const actualValue = parseFloat(positionInput.value)
            if (!isNaN(actualValue)) {
              const position = mainController.actualValueToPosition(actualValue)
              console.log('🎨 updateControlPointColor: Found position from input', position)
              
              // Find control point closest to this position
              const sorted = [...mainController.customGradientControlPoints].sort((a, b) => a.position - b.position)
              for (let i = 0; i < sorted.length; i++) {
                if (Math.abs(sorted[i].position - position) < 0.01) {
                  // Find the original index
                  targetIndex = mainController.customGradientControlPoints.findIndex(p => 
                    p.position === sorted[i].position && p.color === sorted[i].color
                  )
                  console.log('🎨 updateControlPointColor: Found matching control point at index', targetIndex)
                  mainController.selectedControlPointIndex = targetIndex
                  break
                }
              }
            }
          }
        }
      }
    }
    
    if (targetIndex === undefined || targetIndex < 0) {
      console.error('🎨 ❌ updateControlPointColor: Cannot determine which control point to update')
      return
    }
    
    console.log('🎨 updateControlPointColor: updating index', targetIndex, 'to color', hexColor, '(', color, ')')
    
    const controlPoints = mainController.customGradientControlPoints
    console.log('🎨 updateControlPointColor: controlPoints before update', JSON.parse(JSON.stringify(controlPoints)))
    console.log('🎨 updateControlPointColor: targetIndex', targetIndex, 'length', controlPoints ? controlPoints.length : 0)
    
    if (!controlPoints || controlPoints.length === 0) {
      console.warn('🎨 ⚠️ updateControlPointColor: controlPoints is empty or null')
      return
    }
    
    if (targetIndex < 0 || targetIndex >= controlPoints.length) {
      console.warn('🎨 ⚠️ updateControlPointColor: invalid index', {
        targetIndex: targetIndex,
        controlPointsLength: controlPoints.length
      })
      return
    }
    
    // Update the color on main controller
    controlPoints[targetIndex].color = color
    console.log('🎨 updateControlPointColor: controlPoints after update', JSON.parse(JSON.stringify(controlPoints)))
    console.log('🎨 updateControlPointColor: mainController.customGradientControlPoints reference check', mainController.customGradientControlPoints === controlPoints)
    console.log('🎨 updateControlPointColor: mainController.customGradientControlPoints after update', JSON.parse(JSON.stringify(mainController.customGradientControlPoints)))
    
    // Verify the update persisted before rendering
    if (mainController.customGradientControlPoints[targetIndex].color !== color) {
      console.error('🎨 ❌ updateControlPointColor: Color update failed!')
      return
    }
    
    // Save gradient for current metadata
    mainController.gradientManager.saveGradientForMetadata(mainController.currentMetadataId)
    
    // Update display using main controller
    mainController.gradientManager.updateGradientDisplay()
    console.log('🎨 updateControlPointColor: mainController.customGradientControlPoints after updateGradientDisplay', JSON.parse(JSON.stringify(mainController.customGradientControlPoints)))
  }
  
  // Remove selected control point
  removeControlPoint() {
    // Delegate to gradientManager
    this.gradientManager.removeControlPoint()
  }
  
  // Close control point editor
  closeControlPointEditor() {
    const editor = document.getElementById('gradient-control-point-editor')
    if (editor) {
      editor.style.display = 'none'
    }
    this.selectedControlPointIndex = undefined
    
    // Update the modal display
    this.rendererManager.renderModalGradientPreview()
    this.rendererManager.renderModalControlPointMarkers()
    this.rendererManager.renderControlPointsList()
    
    // Apply changes to the main visualization
    this.reapplyColorsWithNewGradient()
  }
  
  // Reset gradient to default
  resetGradient() {
    console.log('🎨 Resetting gradient to default')
    this.customGradientControlPoints = null
    this.selectedControlPointIndex = undefined
    
    // Reinitialize default gradient
    this.colorManager.initializeDefaultGradient()
    
    // Save the reset gradient for current metadata
    this.gradientManager.saveGradientForMetadata(this.currentMetadataId)
    
    this.closeControlPointEditor()
    this.rendererManager.renderModalGradientPreview()
    this.rendererManager.renderModalControlPointMarkers()
    this.rendererManager.renderControlPointsList()
    this.reapplyColorsWithNewGradient()
  }
  
  // Reapply colors with new gradient
  reapplyColorsWithNewGradient() {
    console.log('🎨 Reapplying colors with new gradient')
    console.log('🎨 Custom gradient points:', this.customGradientControlPoints)
    console.log('🎨 Auto gradient points:', this.gradientControlPoints)
    
    // Preserve custom gradient points - they should not be reset by this function
    const preservedCustomPoints = this.customGradientControlPoints ? 
      JSON.parse(JSON.stringify(this.customGradientControlPoints)) : null
    
    // CRITICAL: Invalidate color cache to force recalculation with new gradient
    // The cache is based on a hash that might not include gradient changes
    console.log('🎨 Invalidating color cache to force recalculation with new gradient')
    this.lastColorUpdateHash = null
    this.colorUpdateCache.clear()
    
    // Update the legend in the plot
    if (this.currentMetadataVector?.data_type === 'NUMERIC') {
      console.log('🎨 Updating legend, scatter plot, and bar plots with new gradient')
      
      // Update the continuous color legend
      this.renderContinuousColorLegend()
      
      // Recolor all scatter plot points based on the new gradient
      // renderPointsWithCurrentColoring() handles both ReGL and PixiJS renderers internally
      console.log('🎨 Recoloring scatter plot points (renderer type:', this.rendererType, ')')
      this.renderPointsWithCurrentColoring()
      
      // Redraw category distribution bar plots to reflect new gradient
      console.log('🎨 Updating all category distribution bar plots')
      this.dataManager.updateAllCategoryDistributions()
     
    } else {
      console.log('⚠️ Cannot reapply colors: no numeric metadata vector')
    }
    
    // Restore custom gradient points if they got lost
    if (!this.customGradientControlPoints && preservedCustomPoints) {
      console.warn('🎨 ⚠️ reapplyColorsWithNewGradient: Custom gradient points were lost! Restoring...')
      this.customGradientControlPoints = preservedCustomPoints
    }
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


  // Get visible count for a category (considering current filtering)
  getVisibleCountForCategory(categoryName) {
    if (!this.currentMetadataVector || !this.currentMetadataVector.values) {
      return 0
    }
    
    // If no filtering is applied, return total count
    if (!this.currentVisibleCells || this.currentVisibleCells.length === this.currentMetadataVector.values.length) {
      return this.dataManager.getTotalCountForCategory(categoryName)
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


  // Convert hex color to PIXI color number
  convertHexToPixiColor(hexColor) {
    if (!hexColor) return 0xcccccc // Default grey if no color
    // Remove # if present and convert to number
    const hex = hexColor.replace('#', '')
    return parseInt(hex, 16)
  }

  updateLassoGraphics() {
    if (!this.lassoCanvasCtx || this.lassoPoints.length < 2) return
    
    // Draw on HTML canvas overlay
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
    
    console.log('[LASSO] selectPointsInLasso called')
    console.log('[LASSO] Current filter state:', {
      currentVisibleCells: this.currentVisibleCells ? `${this.currentVisibleCells.length} cells` : 'null (all visible)',
      hasFilter: !!this.currentVisibleCells
    })
    
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
        const x = this.interactionHandler.normalizeX(dataX, this.currentBounds)
        const y = this.interactionHandler.normalizeY(dataY, this.currentBounds)
        
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
    
    // Store current filter state before clearing coloring
    const filterStateBeforeClear = this.currentVisibleCells ? new Set(this.currentVisibleCells) : null
    console.log('[LASSO] Storing filter state before clearMetadataColoring:', {
      hasFilter: !!filterStateBeforeClear,
      filterSize: filterStateBeforeClear ? filterStateBeforeClear.size : 'null'
    })
    
    // Deactivate the coloring button (turn blue palette button to grey)
    this.resetAllWaterDropButtons()
    this.removeAllCategoryColors()
    this.clearMetadataColoring()
    
    // Verify filter state after clearMetadataColoring
    console.log('[LASSO] Filter state after clearMetadataColoring:', {
      currentVisibleCells: this.currentVisibleCells ? `${this.currentVisibleCells.length} cells` : 'null (all visible)',
      hasFilter: !!this.currentVisibleCells,
      filterPreserved: filterStateBeforeClear ? 
        (this.currentVisibleCells ? 
          (this.currentVisibleCells.length === filterStateBeforeClear.size) : false) : 
        (!this.currentVisibleCells)
    })
    
    // Update selection count display
    this.updateSelectionCount()
    
    // Update colors of selected points without re-rendering (preserves pan/zoom state)
    this.updateSelectedPointColors()
  }
  // Update colors of selected points without re-rendering (preserves pan/zoom state)
  updateSelectedPointColors() {
    const numPoints = this.rendererType === 'regl' ? this.numPoints : (this.pointSprites?.length || 0)
    console.log(`⏱️ [PERF] updateSelectedPointColors - ${this.selectedCells.size} selected out of ${numPoints} total`)
    
    // Get current filter state
    const filteredIndices = this.dataManager.getIncrementalFilteredIndices()
    const visibleSet = filteredIndices ? new Set(filteredIndices) : null
    console.log('[UPDATE COLORS] Filter state in updateSelectedPointColors:', {
      filteredIndices: filteredIndices ? `${filteredIndices.length} cells` : 'null (all visible)',
      currentVisibleCells: this.currentVisibleCells ? `${this.currentVisibleCells.length} cells` : 'null (all visible)',
      hasFilter: !!visibleSet
    })
    
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
        // IMPORTANT: Respect current filter - hide filtered-out cells
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const isVisible = !visibleSet || visibleSet.has(cellIndex)
          
          if (!isVisible) {
            // Hide filtered-out points
            colorMap.set(drawPos, 0x00000000)
            continue
          }
          
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
        // IMPORTANT: Respect current filter - hide filtered-out cells
        for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
          const cellIndex = this.displayOrder[drawPos]
          const isVisible = !visibleSet || visibleSet.has(cellIndex)
          
          if (!isVisible) {
            // Hide filtered-out points
            colorMap.set(drawPos, 0x00000000)
            continue
          }
          
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
    this.uiManager.updateSelectedCellsCount()
    
    // Update point colors to show selection
    this.updateSelectedPointColors()
    
    // Update button state
    this.uiManager.updateAddAllVisibleButtonState()
  }

  // Update the state of the "Add all visible cells" button

  // Settings Window Methods - delegate to UIManager
  toggleSettingsWindow() {
    this.uiManager.toggleSettingsWindow()
  }




  toggleAxes() {
    this.uiManager.toggleAxes()
  }

  toggleGrid() {
    this.uiManager.toggleGrid()
  }

  toggleCategories() {
    this.uiManager.toggleCategories()
  }

  // Preload metadata vector - delegate to DataManager
  preloadMetadataVector(event) {
    // Pass the event directly to DataManager which expects event.currentTarget
    this.dataManager.preloadMetadataVector(event)
  }

  // Cancel preload - delegate to DataManager
  cancelPreload(event) {
    this.dataManager.cancelPreload(event)
  }

  // Close gradient editor modal - delegate to GradientManager
  closeGradientEditorModal() {
    this.gradientManager.closeGradientEditorModal()
  }

  // Open memory diagnostic window
  async openMemoryDiagnostic() {
    await this.performanceManager.openMemoryDiagnostic()
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
      screenCoordinates[drawPos * 2] = this.interactionHandler.normalizeX(dataX, this.currentBounds)
      screenCoordinates[drawPos * 2 + 1] = this.interactionHandler.normalizeY(dataY, this.currentBounds)
      
      // Get color for this cell
      const color = this.originalPointColors.get(cellIndex) || 0x3b82f6
      colorMap.set(drawPos, color)
    }
    
    // Update ReGL buffers with reordered data
    this.reglRenderer.updatePositions(screenCoordinates)
    this.reglRenderer.updateColors(colorMap)
    this.reglRenderer.render()
    
    // Redraw the Canvas 2D overlay (grid, axes, labels)
    this.rendererManager.renderGrid()
    this.rendererManager.renderAxes()
    this.rendererManager.renderCategoryLabels()
    
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
      screenCoordinates[drawPos * 2] = this.interactionHandler.normalizeX(dataX, this.currentBounds)
      screenCoordinates[drawPos * 2 + 1] = this.interactionHandler.normalizeY(dataY, this.currentBounds)
      
      // Get color for this cell
      const color = this.originalPointColors.get(cellIndex) || 0x3b82f6
      colorMap.set(drawPos, color)
    }
    
    // Update ReGL buffers with reordered data
    this.reglRenderer.updatePositions(screenCoordinates)
    this.reglRenderer.updateColors(colorMap)
    this.reglRenderer.render()
    
    // Redraw the Canvas 2D overlay (grid, axes, legend)
    this.rendererManager.renderGrid()
    this.rendererManager.renderAxes()
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
      this.uiManager.updateSelectedCellsCount()
      
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
    const hasRenderer = !!this.reglRenderer
    
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
        const screenX = this.interactionHandler.normalizeX(dataX, this.currentBounds)
        const screenY = this.interactionHandler.normalizeY(dataY, this.currentBounds)
        
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
      const { color: metadataColor } = this.colorManager.getColorAndAlpha(point.cellId)
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
    const margins = this.rendererManager.getPlotMargins()
    
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.rendererManager.calculateTickSpacing(xRange)
    const yTickSpacing = this.rendererManager.calculateTickSpacing(yRange)
    
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
    const margins = this.rendererManager.getPlotMargins()
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
    const xTickSpacing = this.rendererManager.calculateTickSpacing(xRange)
    const yTickSpacing = this.rendererManager.calculateTickSpacing(yRange)
    
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
      this.colorManager.clearColorMapCache()
      
      // Update adapt color range button visibility for all range sliders
      this.updateAllRangeSliderButtonAppearances()
      
      // Re-activate the water drop button
      if (activeButton) {
        this.setWaterDropButtonActive(activeButton)
        
        // Re-add category colors if it's discrete metadata
        if (metadataVector.data_type === 'DISCRETE' || metadataVector.data_type === 'STRING') {
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
          this.rendererManager.renderCategoryLabels()
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
    this.uiManager.updateSelectedCellsCount()
    
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

  // Tooltip methods
  showTooltip(cellId, point) {
    // This method is kept for compatibility with PixiJS mode
    // For RegL mode, we use showSimpleTooltip instead
    
    // Get cell information
    const cellName = cellId.toString() // Generate cell name from ID
    
    // Get category information if available
    let categoryInfo = ''
    if (this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[cellId] !== undefined) {
      const { data_type, values } = this.currentMetadataVector
      const value = values[cellId]
      
      if (data_type === 'DISCRETE' || data_type === 'STRING') {
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

  showSimpleTooltip(cellName, categoryInfo, point, cellId = null, isFixed = false) {
    // Remove any existing simple tooltip
    const existing = document.getElementById('simple-tooltip')
    if (existing) {
      existing.remove()
    }
    
    // Get plot container for positioning
    const plotContainer = document.querySelector('.plot-container')
    const rect = plotContainer ? plotContainer.getBoundingClientRect() : { left: 0, top: 0, width: 600, height: 400 }
    
    // Position tooltip - use last position if available (for both fixed and hover), otherwise calculate default position
    let tooltipLeft, tooltipTop
    if (this.lastTooltipPosition) {
      tooltipLeft = this.lastTooltipPosition.left
      tooltipTop = this.lastTooltipPosition.top
    } else {
      // Default position: above the plot, centered horizontally
      const margins = this.rendererManager.getPlotMargins()
      tooltipLeft = rect.left + (rect.width / 2) - 100
      tooltipTop = rect.top - margins.top - 20
    }
    
    // Create tooltip container
    const tooltip = document.createElement('div')
    tooltip.id = 'simple-tooltip'
    tooltip.style.cssText = `
      position: fixed !important;
      top: ${tooltipTop}px !important;
      left: ${tooltipLeft}px !important;
      background: rgba(0, 0, 0, 0.9) !important;
      color: white !important;
      padding: 8px 8px 12px 8px !important;
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
    
    // Make tooltip draggable if fixed (will be moved to drag handle)
    let dragHandle = null
    let isDragging = false
    let currentX
    let currentY
    let initialX
    let initialY
    
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
      display: flex !important;
      align-items: center !important;
      justify-content: center !important;
    `
    closeButton.onclick = () => {
      tooltip.remove()
      this.isTooltipFixed = false
      this.fixedTooltipCellId = null
      console.log('Tooltip closed by user - hover detection re-enabled')
    }
    
    // Create header with title, drag handle, and lock icon
    const header = document.createElement('div')
    header.style.cssText = `
      display: flex !important;
      align-items: center !important;
      padding: 4px 30px 8px 8px !important;
      border-bottom: 1px solid rgba(255, 255, 255, 0.2) !important;
      margin-bottom: 8px !important;
      cursor: ${isFixed ? 'move' : 'default'} !important;
    `
    
    // Create drag handle if tooltip is fixed (visual indicator only)
    if (isFixed) {
      dragHandle = document.createElement('i')
      dragHandle.className = 'fas fa-grip-vertical drag-handle'
      dragHandle.style.cssText = `
        cursor: move !important;
        font-size: 14px !important;
        color: #9ca3af !important;
        margin-right: 8px !important;
        user-select: none !important;
        line-height: 1 !important;
        display: flex !important;
        align-items: center !important;
      `
      
      header.appendChild(dragHandle)
    }
    
    const title = document.createElement('div')
    title.textContent = 'Cell Inspector'
    title.style.cssText = `
      font-weight: 600 !important;
      font-size: 13px !important;
      color: white !important;
      flex: 1 !important;
      display: flex !important;
      align-items: center !important;
      user-select: none !important;
    `
    header.appendChild(title)
    
    // Create lock icon if tooltip is fixed (positioned absolutely to align with close button)
    if (isFixed) {
      const lockIcon = document.createElement('span')
      lockIcon.className = 'lock-icon'
      lockIcon.innerHTML = '🔒'
      lockIcon.style.cssText = `
        position: absolute !important;
        top: 4px !important;
        right: 32px !important;
        font-size: 14px !important;
        color: white !important;
        display: flex !important;
        align-items: center !important;
      `
      tooltip.appendChild(lockIcon)
    }
    
    tooltip.appendChild(header)
    
    // Set up drag handlers for fixed tooltip (entire header is draggable)
    if (isFixed) {
      header.onmousedown = (e) => {
        // Don't start drag if clicking on close button or lock icon
        if (e.target === closeButton || e.target.closest('.lock-icon')) {
          return
        }
        
        e.preventDefault()
        e.stopPropagation()
        isDragging = true
        const rect = tooltip.getBoundingClientRect()
        initialX = e.clientX - rect.left
        initialY = e.clientY - rect.top
      }
      
      document.onmouseup = () => {
        isDragging = false
      }
      
      document.onmousemove = (e) => {
        if (!isDragging) return
        
        e.preventDefault()
        currentX = e.clientX - initialX
        currentY = e.clientY - initialY
        
        tooltip.style.left = currentX + 'px'
        tooltip.style.top = currentY + 'px'
        
        // Store the position for next time
        this.lastTooltipPosition = { left: currentX, top: currentY }
      }
    }
    
    // Create content
    const content = document.createElement('div')
    content.style.cssText = `
      padding-right: 25px !important;
    `
    
    // Create table for information
    const table = document.createElement('table')
    table.style.cssText = `
      width: 100% !important;
      border-collapse: collapse !important;
        font-size: 12px !important;
      margin-top: 4px !important;
    `
    
    // Add cell ID row
    const nameRow = document.createElement('tr')
    const nameLabelCell = document.createElement('td')
    nameLabelCell.textContent = 'Cell index'
    nameLabelCell.style.cssText = 'font-weight: 600 !important; padding: 2px 8px 2px 0 !important; color: white !important;'
    const nameValueCell = document.createElement('td')
    nameValueCell.textContent = cellName
    nameValueCell.style.cssText = 'padding: 2px 0 !important; color: #e5e7eb !important;'
    nameRow.appendChild(nameLabelCell)
    nameRow.appendChild(nameValueCell)
    table.appendChild(nameRow)
    
    // Always add CellID row to tooltip (with loading state if not available)
    if (cellId !== null) {
      const cellIdRow = document.createElement('tr')
      const cellIdLabelCell = document.createElement('td')
      cellIdLabelCell.textContent = 'CellID'
      cellIdLabelCell.style.cssText = 'font-weight: 600 !important; padding: 2px 8px 2px 0 !important; color: white !important;'
      const cellIdValueCell = document.createElement('td')
      
      let cellIdValue = null
      let cellIdMetadataId = null
      let isLoading = false
      
      // First, search in loaded metadata vectors
      if (this.loadedMetadataVectors) {
        for (const [metadataId, vectorData] of Object.entries(this.loadedMetadataVectors)) {
          // Search for CellID metadata (case-insensitive, handles "CellID", "Cell ID", etc.)
          const metadataName = vectorData.name ? vectorData.name.toLowerCase().replace(/\s+/g, '') : ''
          if (metadataName === 'cellid' || metadataName.includes('cellid')) {
            // Check if metadata has invalid compression info
            const hasInvalidCompression = vectorData.compression_info && 
              typeof vectorData.compression_info === 'string' &&
              (vectorData.compression_info.includes('No categories available') || 
               vectorData.compression_info.includes('Failed to parse'))
            
            // If invalid, remove it to force reload (will happen on next check)
            if (hasInvalidCompression) {
              console.log(`🔧 [Tooltip] CellID metadata has invalid compression, will reload on next access`)
              delete this.loadedMetadataVectors[metadataId]
              continue
            }
            
            const cellIdVector = this.dataManager.getMetadataVectorById(metadataId)
            if (cellIdVector && cellIdVector.values && cellIdVector.values[cellId] !== undefined) {
              cellIdValue = cellIdVector.values[cellId]
              cellIdMetadataId = metadataId
              break
            }
          }
        }
      }
      
      // If not found in loaded vectors, try to find CellID metadata button in UI and load it
      if (!cellIdValue) {
        const cellIdButtons = document.querySelectorAll('button[data-metadata-name]')
        for (const button of cellIdButtons) {
          const metadataName = (button.dataset.metadataName || '').toLowerCase().replace(/\s+/g, '')
          if (metadataName === 'cellid' || metadataName.includes('cellid')) {
            const metadataId = button.dataset.metadataId
            if (metadataId) {
              // Check if metadata exists but has invalid compression info
              const existingVector = this.loadedMetadataVectors?.[metadataId]
              const hasInvalidCompression = existingVector && 
                typeof existingVector.compression_info === 'string' &&
                (existingVector.compression_info.includes('No categories available') || 
                 existingVector.compression_info.includes('Failed to parse'))
              
              // If invalid, remove it to force reload
              if (hasInvalidCompression) {
                console.log(`🔧 [Tooltip] CellID metadata has invalid compression, forcing reload`)
                delete this.loadedMetadataVectors[metadataId]
                // Also try to remove from IndexedDB cache if memoryManager exists
                if (this.memoryManager) {
                  // Try to clear from IndexedDB if the method exists
                  if (typeof this.memoryManager.clearMetadataFromIndexedDB === 'function') {
                    this.memoryManager.clearMetadataFromIndexedDB(metadataId).catch(() => {})
                  } else if (this.memoryManager.store && this.memoryManager.store.delete) {
                    // Fallback: try direct IndexedDB deletion
                    this.memoryManager.store.delete(metadataId).catch(() => {})
                  }
                }
              }
              
              // Try to get the metadata vector (this will load it if needed)
              const cellIdVector = this.dataManager.getMetadataVectorById(metadataId)
              
              // If still no values and we have metadata ID, try loading from server
              if ((!cellIdVector || !cellIdVector.values) && metadataId) {
                console.log(`🔧 [Tooltip] CellID not in memory, attempting to load from server`)
                isLoading = true
                // Load asynchronously and update tooltip when ready
                this.loadSingleMetadataVectorSilently(metadataId).then(() => {
                  // Reload the tooltip with updated data
                  this.hideSimpleTooltip()
                  this.showSimpleTooltip(cellName, categoryInfo, point, cellId, isFixed)
                  console.log(`🔧 [Tooltip] CellID metadata loaded successfully, tooltip refreshed`)
                }).catch(err => {
                  console.error(`🔧 [Tooltip] Failed to load CellID metadata:`, err)
                })
              } else if (cellIdVector && cellIdVector.values && cellIdVector.values[cellId] !== undefined) {
                cellIdValue = cellIdVector.values[cellId]
                cellIdMetadataId = metadataId
                break
              }
            }
          }
        }
      }
      
      // Set cell content based on availability
      if (cellIdValue !== null) {
        cellIdValueCell.textContent = cellIdValue
        cellIdValueCell.style.cssText = 'padding: 2px 0 !important; color: #e5e7eb !important;'
      } else {
        // Show loading spinner
        cellIdValueCell.innerHTML = '<i class="fas fa-spinner fa-spin" style="margin-right: 4px;"></i><span style="font-style: italic;">Loading...</span>'
        cellIdValueCell.style.cssText = 'padding: 2px 0 !important; color: #9ca3af !important;'
      }
      
      cellIdRow.appendChild(cellIdLabelCell)
      cellIdRow.appendChild(cellIdValueCell)
      table.appendChild(cellIdRow)
    }
    
    // Add category/value row - use current metadata if cellId provided, otherwise use passed categoryInfo
    let finalCategoryInfo = categoryInfo
    if (cellId !== null && this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[cellId] !== undefined) {
      const { data_type, values } = this.currentMetadataVector
      const value = values[cellId]
      
      if (data_type === 'DISCRETE' || data_type === 'STRING') {
        finalCategoryInfo = value
      } else if (data_type === 'NUMERIC') {
        finalCategoryInfo = value.toFixed(3)
      }
    }
    
    if (finalCategoryInfo !== null && finalCategoryInfo !== undefined && finalCategoryInfo !== '') {
      const categoryRow = document.createElement('tr')
      const categoryLabelCell = document.createElement('td')
      const { data_type } = this.currentMetadataVector || {}
      categoryLabelCell.textContent = data_type === 'NUMERIC' ? 'Value' : 'Category'
      categoryLabelCell.style.cssText = 'font-weight: 600 !important; padding: 2px 8px 2px 0 !important; color: white !important;'
      const categoryValueCell = document.createElement('td')
      categoryValueCell.textContent = finalCategoryInfo
      categoryValueCell.style.cssText = 'padding: 2px 0 !important; color: #e5e7eb !important;'
      categoryRow.appendChild(categoryLabelCell)
      categoryRow.appendChild(categoryValueCell)
      table.appendChild(categoryRow)
    }
    
    content.appendChild(table)
    tooltip.appendChild(content)
    tooltip.appendChild(closeButton)
    document.body.appendChild(tooltip)
    
    // Store initial position for tooltips (if not already stored)
    if (!this.lastTooltipPosition) {
      this.lastTooltipPosition = { left: tooltipLeft, top: tooltipTop }
    }
  }

  // Refresh fixed tooltip if needed (called after coloring changes)
  refreshFixedTooltipIfNeeded() {
    if (!this.isTooltipFixed || this.fixedTooltipCellId === null) {
      return
    }
    
    // Check if tooltip exists in DOM
    const existing = document.getElementById('simple-tooltip')
    if (!existing) {
      return
    }
    
    // Recreate the tooltip with updated information
    // Get current category info
    let categoryInfo = null
    if (this.currentMetadataVector && this.currentMetadataVector.values && this.currentMetadataVector.values[this.fixedTooltipCellId] !== undefined) {
      const { data_type, values } = this.currentMetadataVector
      const value = values[this.fixedTooltipCellId]
      
      if (data_type === 'DISCRETE' || data_type === 'STRING') {
        categoryInfo = value
      } else if (data_type === 'NUMERIC') {
        categoryInfo = value.toFixed(3)
      }
    }
    
    // Use existing position from DOM
    const rect = existing.getBoundingClientRect()
    const point = { x: rect.left, y: rect.top }
    
    // Recreate tooltip with updated data
    const cellName = this.fixedTooltipCellId.toString()
    this.showSimpleTooltip(cellName, categoryInfo, point, this.fixedTooltipCellId, true)
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
    
      // Check if RegL renderer and coordinates are available
      if (!this.reglRenderer || !this.currentCoordinates) {
        console.log('🎯 [RegL] RegL renderer or coordinates not available, skipping point detection')
        return
      }
      this.detectRegLPointClick(event)
    
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
    const bounds = this.currentBounds || this.dataManager.calculateBounds(this.currentCoordinates)
    const margins = this.rendererManager.getPlotMargins()
    
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
    
    // Get cell information
    const cellName = cellId.toString()
    
    // Create a mock point object for positioning
    const mockPoint = { x: screenX, y: screenY }
    
    // Tooltip will read current metadata directly, and isFixed=true will show lock icon
    this.showSimpleTooltip(cellName, null, mockPoint, cellId, true)
    
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
    const bounds = this.currentBounds || this.dataManager.calculateBounds(this.currentCoordinates)
    const margins = this.rendererManager.getPlotMargins()
    
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
        const cellName = closestPointIndex.toString()
        
        const mockPoint = { x: mouseX, y: mouseY }
        // Tooltip will read current metadata directly, isFixed=false so no lock icon
        this.showSimpleTooltip(cellName, null, mockPoint, closestPointIndex, false)
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
    let metadataVector = this.dataManager.getMetadataVectorById(metadataId)
    if (!metadataVector) {
      console.log(`💾 [DISK] Metadata ${metadataId} not in memory, loading from disk...`)
      try {
        metadataVector = await this.loadMetadataVectorFromDisk(metadataId)
        if (!metadataVector) {
          console.error(`💾 [DISK] Failed to load metadata ${metadataId} from disk - trying server fallback...`)
          // Try direct server loading as last resort
          metadataVector = await this.dataManager.loadSingleMetadataVector(metadataId)
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
    // Note: Also check for orange (#f59e0b) which indicates a subrange selection
    const isSelectedGreen = checkbox.style.backgroundColor === 'rgb(16, 185, 129)' // #10b981 green
    const isSelectedOrange = checkbox.style.backgroundColor === 'rgb(245, 158, 11)' // #f59e0b orange
    const isAnySelected = isSelectedGreen || isSelectedOrange
    
    if (isAnySelected) {
      // Deselect - store the current range for later restoration
      checkbox.style.backgroundColor = '#f3f4f6'
      checkbox.querySelector('i').style.display = 'none'
      
      if (isContinuous) {
        // Track that this metadata was explicitly unchecked
        if (!this.uncheckedMetadata) this.uncheckedMetadata = new Set()
        this.uncheckedMetadata.add(metadataId)
        
        // Store the current range before clearing it (for restoration when re-checking)
        if (!this.savedRanges) this.savedRanges = {}
        
        const rangeSliderElement = document.querySelector(`[data-metadata-item="${metadataId}"] [data-controller="range-slider"]`)
        if (rangeSliderElement) {
          const rangeSliderController = this.application.getControllerForElementAndIdentifier(rangeSliderElement, 'range-slider')
          if (rangeSliderController) {
            // Check if the slider has been initialized with real data
            // If minValue and maxValue are still the default (0 and 1), it means the slider wasn't initialized
            const hasRealData = !(rangeSliderController.minValue === 0 && rangeSliderController.maxValue === 1)
            
            if (hasRealData) {
              // Save the current slider values
              this.savedRanges[metadataId] = {
                min: rangeSliderController.currentMinValue,
                max: rangeSliderController.currentMaxValue,
                fullMin: rangeSliderController.minValue,
                fullMax: rangeSliderController.maxValue
              }
              console.log('🔍 [CHECKBOX] Saved range for restoration:', this.savedRanges[metadataId])
            } else {
              // Slider exists but wasn't initialized with real data yet
              this.savedRanges[metadataId] = null // null means "use full range when restoring"
              console.log('🔍 [CHECKBOX] Slider not initialized with real data - will use full range on restore')
            }
          }
        } else {
          // Slider doesn't exist yet (metadata was never unfolded)
          // Mark that we need to use full range when checking later
          this.savedRanges[metadataId] = null // null means "use full range when restoring"
          console.log('🔍 [CHECKBOX] No slider found - will use full range on restore')
        }
        
        // For continuous metadata: disable range selection (clear the range)
        delete this.selectedRanges[metadataId]
        checkbox.title = 'Enable range selection'
        
        // Disable the range slider for this metadata
        this.uiManager.disableRangeSliderForMetadata(metadataId)
      } else {
        // For categorical metadata: save current selections and clear them to disable filtering
        if (!this.savedCategorySelections) this.savedCategorySelections = {}
        
        // Save the current category selections for restoration
        if (this.selectedCategories && this.selectedCategories[metadataId]) {
          this.savedCategorySelections[metadataId] = new Set(this.selectedCategories[metadataId])
          console.log('🔍 [CHECKBOX] Saved category selections:', Array.from(this.savedCategorySelections[metadataId]))
          
          // Clear the selections to disable filtering
          this.selectedCategories[metadataId].clear()
          console.log('🔍 [CHECKBOX] Cleared selectedCategories to disable filtering')
        }
        
        // Disable the category checkboxes visually
        this.uiManager.disableCategoryCheckboxesForMetadata(metadataId)
      }
    } else {
      // Select - restore previous range if it was a subrange, otherwise use full range
      checkbox.querySelector('i').style.display = 'block'
      
      if (isContinuous) {
        console.log('🔍 [CHECKBOX] Re-checking continuous metadata')
        
        // Remove from unchecked tracking set FIRST
        if (this.uncheckedMetadata) {
          this.uncheckedMetadata.delete(metadataId)
        }
        
        // Set checkbox to green initially (will be changed to orange if subrange)
        checkbox.style.backgroundColor = '#10b981'
        checkbox.title = 'Disable range selection'
        
        // Enable the range slider for this metadata first
        this.uiManager.enableRangeSliderForMetadata(metadataId)
        
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
              // Check if we have a saved range (from previous uncheck)
              let currentMin, currentMax
              
              if (this.savedRanges && metadataId in this.savedRanges) {
                if (this.savedRanges[metadataId] === null) {
                  // null means use full range (metadata was unchecked before being unfolded)
                  // Make sure the slider has valid min/max values
                  if (rangeSliderController.minValue !== undefined && rangeSliderController.maxValue !== undefined) {
                    currentMin = rangeSliderController.minValue
                    currentMax = rangeSliderController.maxValue
                    console.log('🔍 [CHECKBOX] Using full range (was unchecked before unfold):', currentMin, currentMax)
                    
                    // Update the slider to show the full range
                    rangeSliderController.currentMinValue = currentMin
                    rangeSliderController.currentMaxValue = currentMax
                    rangeSliderController.updateSliderUI()
                  } else {
                    // Slider not fully initialized yet, use current values as fallback
                    currentMin = rangeSliderController.currentMinValue
                    currentMax = rangeSliderController.currentMaxValue
                    console.log('🔍 [CHECKBOX] Slider not fully initialized, using current values:', currentMin, currentMax)
                  }
                } else {
                  // Restore the saved range
                  currentMin = this.savedRanges[metadataId].min
                  currentMax = this.savedRanges[metadataId].max
                  console.log('🔍 [CHECKBOX] Restoring saved range:', currentMin, currentMax)
                  
                  // Update the slider to show the restored range
                  rangeSliderController.currentMinValue = currentMin
                  rangeSliderController.currentMaxValue = currentMax
                  rangeSliderController.updateSliderUI()
                }
              } else {
                // No saved range, use current slider values (full range by default)
                currentMin = rangeSliderController.currentMinValue
                currentMax = rangeSliderController.currentMaxValue
                console.log('🔍 [CHECKBOX] Using current slider values:', currentMin, currentMax)
              }
              
              this.selectedRanges[metadataId] = {
                min: currentMin,
                max: currentMax
              }
              console.log('🔍 [CHECKBOX] Set selectedRanges to:', this.selectedRanges[metadataId])
              
              // Update checkbox color based on whether it's a subrange
              // This will change it to orange if it's a subrange, or keep it green if full range
              rangeSliderController.updateCheckboxColor()
              
              // Update the selected cells count
              rangeSliderController.updateSelectedCellsCount()
              console.log('🔍 [CHECKBOX] Updated selected cells count')
            } else {
              console.log('🔍 [CHECKBOX] No range slider controller found!')
              // Already set to green above
            }
          } else {
            console.log('🔍 [CHECKBOX] No range slider element found!')
            // Already set to green above
          }
        } else {
          console.log('🔍 [CHECKBOX] No range section found!')
          // Already set to green above
        }
      } else {
        // For categorical metadata: restore selections and re-enable checkboxes
        
        // Restore the saved category selections
        if (this.savedCategorySelections && this.savedCategorySelections[metadataId]) {
          if (!this.selectedCategories) this.selectedCategories = {}
          if (!this.selectedCategories[metadataId]) {
            this.selectedCategories[metadataId] = new Set()
          }
          
          // Restore each saved category
          this.savedCategorySelections[metadataId].forEach(category => {
            this.selectedCategories[metadataId].add(category)
          })
          console.log('🔍 [CHECKBOX] Restored category selections:', Array.from(this.selectedCategories[metadataId]))
        }
        
        // Re-enable the category checkboxes
        this.uiManager.enableCategoryCheckboxesForMetadata(metadataId)
        
        // Determine checkbox color based on whether all categories are selected
        if (this.selectedCategories && this.selectedCategories[metadataId]) {
          const allCategoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
          const totalCategories = allCategoryCheckboxes.length
          const selectedCount = this.selectedCategories[metadataId].size
          
          if (selectedCount === totalCategories) {
            // All categories selected - green
            checkbox.style.backgroundColor = '#10b981'
            console.log(`🔍 [CHECKBOX] All ${totalCategories} categories selected - green`)
          } else if (selectedCount > 0) {
            // Some categories selected - orange
            checkbox.style.backgroundColor = '#f59e0b'
            console.log(`🔍 [CHECKBOX] ${selectedCount}/${totalCategories} categories selected - orange`)
          } else {
            // No categories selected - should not happen, but default to green
            checkbox.style.backgroundColor = '#10b981'
          }
        } else {
          // No categories selected or not initialized - default to green
          checkbox.style.backgroundColor = '#10b981'
        }
      }
    }
    
    // Update cell filtering
    console.log('🔍 [CHECKBOX] About to call updateCellFiltering')
    console.log('🔍 [CHECKBOX] Current selectedRanges:', this.selectedRanges)
    this.dataManager.updateCellFiltering()
    console.log('🔍 [CHECKBOX] updateCellFiltering called')
  }

  async toggleSelectAllCategories(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const checkbox = event.currentTarget
    
    // Check if filtering is enabled
    const filterSwitch = document.querySelector(`.metadata-filter-switch[data-metadata-id="${metadataId}"]`)
    const isFilterEnabled = filterSwitch && filterSwitch.dataset.filterEnabled === 'true'
    
    if (!isFilterEnabled) {
      console.log(`🔄 Select all/none blocked - filtering is disabled`)
      return
    }
    
    // Determine current state based on checkmark visibility
    const icon = checkbox.querySelector('i')
    const hasCheckmark = icon && icon.style.display !== 'none'
    
    console.log(`🔄 Toggle select all categories for metadata ${metadataId}, current state: ${hasCheckmark ? 'checked' : 'unchecked'}`)
    
    if (hasCheckmark) {
      // Deselect all categories
      this.deselectAllCategoriesForMetadata(metadataId)
      checkbox.style.backgroundColor = 'white'
      checkbox.style.borderColor = '#d1d5db'
      if (icon) {
        icon.style.display = 'none'
      }
    } else {
      // Select all categories
      this.selectAllCategoriesForMetadata(metadataId)
      checkbox.style.backgroundColor = 'white'
      checkbox.style.borderColor = '#d1d5db'
      if (icon) {
        icon.style.display = 'block'
        icon.style.color = '#10b981' // green checkmark
      }
    }
  }

  async toggleMetadataFilter(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const filterSwitch = event.currentTarget
    const isEnabled = filterSwitch.dataset.filterEnabled === 'true'
    
    console.log(`🔄 Toggle metadata filter for ${metadataId}, current state: ${isEnabled ? 'ON' : 'OFF'}`)
    
    const selectAllCheckbox = document.querySelector(`.metadata-select-all-checkbox[data-metadata-id="${metadataId}"]`)
    const switchToggle = filterSwitch.querySelector('div')
    
    if (isEnabled) {
      // Turn OFF - disable filtering (show all cells)
      filterSwitch.dataset.filterEnabled = 'false'
      filterSwitch.style.backgroundColor = '#d1d5db' // gray
      switchToggle.style.transform = 'translateX(0px)' // move to left
      
      // Save current selections and remove the metadata from selectedCategories
      // (removing it entirely means "no constraint" = show all cells)
      if (!this.savedCategorySelections) this.savedCategorySelections = {}
      if (this.selectedCategories && this.selectedCategories[metadataId]) {
        this.savedCategorySelections[metadataId] = new Set(this.selectedCategories[metadataId])
        delete this.selectedCategories[metadataId]
      }
      
      // Disable the select all checkbox
      if (selectAllCheckbox) {
        selectAllCheckbox.style.opacity = '0.5'
        selectAllCheckbox.style.cursor = 'not-allowed'
      }
      
      // Disable category checkboxes
      this.uiManager.disableCategoryCheckboxesForMetadata(metadataId)
    } else {
      // Turn ON - enable filtering
      filterSwitch.dataset.filterEnabled = 'true'
      filterSwitch.style.backgroundColor = '#10b981' // green
      switchToggle.style.transform = 'translateX(14px)' // move to right
      
      // Restore saved selections
      if (this.savedCategorySelections && this.savedCategorySelections[metadataId]) {
        if (!this.selectedCategories) this.selectedCategories = {}
        if (!this.selectedCategories[metadataId]) {
          this.selectedCategories[metadataId] = new Set()
        }
        this.savedCategorySelections[metadataId].forEach(category => {
          this.selectedCategories[metadataId].add(category)
        })
      }
      
      // Enable the select all checkbox
      if (selectAllCheckbox) {
        selectAllCheckbox.style.opacity = '1'
        selectAllCheckbox.style.cursor = 'pointer'
        // Update its color based on selections
        this.updateSelectAllCheckboxState(metadataId)
      }
      
      // Enable category checkboxes
      this.uiManager.enableCategoryCheckboxesForMetadata(metadataId)
    }
    
    // Update filtering
    this.dataManager.updateCellFiltering()
  }

  async toggleContinuousMetadataFilter(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const filterSwitch = event.currentTarget
    const isEnabled = filterSwitch.dataset.filterEnabled === 'true'
    
    console.log(`🔄 Toggle continuous metadata filter for ${metadataId}, current state: ${isEnabled ? 'ON' : 'OFF'}`)
    
    const switchToggle = filterSwitch.querySelector('div')
    
    if (isEnabled) {
      // Turn OFF - disable filtering (show all cells)
      filterSwitch.dataset.filterEnabled = 'false'
      filterSwitch.style.backgroundColor = '#d1d5db' // gray
      switchToggle.style.transform = 'translateX(0px)' // move to left
      
      // Disable the range slider controls (but not the histogram)
      const metadataItem = document.querySelector(`[data-metadata-item="${metadataId}"]`)
      if (metadataItem) {
        const rangeSliderDiv = metadataItem.querySelector('[data-controller="range-slider"]')
        if (rangeSliderDiv) {
          // Disable input fields
          const inputs = rangeSliderDiv.querySelectorAll('input[type="number"]')
          inputs.forEach(input => {
            input.disabled = true
            input.style.opacity = '0.5'
            input.style.cursor = 'not-allowed'
          })
          
          // Disable slider handles and change to gray
          const handles = rangeSliderDiv.querySelectorAll('.range-slider-min-handle, .range-slider-max-handle')
          handles.forEach(handle => {
            handle.style.opacity = '0.5'
            handle.style.pointerEvents = 'none'
            handle.style.cursor = 'not-allowed'
            handle.style.backgroundColor = '#d1d5db' // gray
          })
          
      // Change active track to light gray
      const activeTrack = rangeSliderDiv.querySelector('[data-range-slider-target="activeTrack"]')
      if (activeTrack) {
        activeTrack.style.backgroundColor = '#d1d5db' // light gray
      }
      
      // Store filter disabled state for histogram rendering
      if (!this.disabledFilters) this.disabledFilters = new Set()
      this.disabledFilters.add(metadataId)
      
      // Redraw histogram with gray overlay
      const rangeSliderController = this.application.getControllerForElementAndIdentifier(
        rangeSliderDiv,
        'range-slider'
      )
      if (rangeSliderController && rangeSliderController.drawDensityPlot) {
        rangeSliderController.drawDensityPlot()
      }
      
      // Disable palette button
          const paletteButton = rangeSliderDiv.querySelector('[data-range-slider-target="adaptColorRangeButton"]')
          if (paletteButton) {
            paletteButton.disabled = true
            paletteButton.style.opacity = '0.5'
            paletteButton.style.cursor = 'not-allowed'
          }
        }
      }
      
      // Save current range and remove it from selectedRanges
      // (removing it entirely means "no constraint" = show all cells)
      if (!this.savedRanges) this.savedRanges = {}
      if (this.selectedRanges && this.selectedRanges[metadataId]) {
        this.savedRanges[metadataId] = { ...this.selectedRanges[metadataId] }
        delete this.selectedRanges[metadataId]
      }
    } else {
      // Turn ON - enable filtering
      filterSwitch.dataset.filterEnabled = 'true'
      filterSwitch.style.backgroundColor = '#10b981' // green
      switchToggle.style.transform = 'translateX(14px)' // move to right
      
      // Enable the range slider controls (but not the histogram)
      const metadataItem = document.querySelector(`[data-metadata-item="${metadataId}"]`)
      if (metadataItem) {
        const rangeSliderDiv = metadataItem.querySelector('[data-controller="range-slider"]')
        if (rangeSliderDiv) {
          // Enable input fields
          const inputs = rangeSliderDiv.querySelectorAll('input[type="number"]')
          inputs.forEach(input => {
            input.disabled = false
            input.style.opacity = '1'
            input.style.cursor = 'default'
          })
          
          // Enable slider handles and restore blue color
          const handles = rangeSliderDiv.querySelectorAll('.range-slider-min-handle, .range-slider-max-handle')
          handles.forEach(handle => {
            handle.style.opacity = '1'
            handle.style.pointerEvents = 'auto'
            handle.style.cursor = 'grab'
            handle.style.backgroundColor = '#3b82f6' // blue
          })
          
          // Restore active track to blue
          const activeTrack = rangeSliderDiv.querySelector('[data-range-slider-target="activeTrack"]')
          if (activeTrack) {
            activeTrack.style.backgroundColor = '#3b82f6' // blue
          }
          
          // Remove filter disabled state for histogram rendering
          if (this.disabledFilters) {
            this.disabledFilters.delete(metadataId)
          }
          
          // Redraw histogram with blue overlay
          const rangeSliderController = this.application.getControllerForElementAndIdentifier(
            rangeSliderDiv,
            'range-slider'
          )
          if (rangeSliderController && rangeSliderController.drawDensityPlot) {
            rangeSliderController.drawDensityPlot()
          }
          
          // Enable palette button
          const paletteButton = rangeSliderDiv.querySelector('[data-range-slider-target="adaptColorRangeButton"]')
          if (paletteButton) {
            paletteButton.disabled = false
            paletteButton.style.opacity = '1'
            paletteButton.style.cursor = 'pointer'
          }
        }
      }
      
      // Restore saved range
      if (this.savedRanges && this.savedRanges[metadataId]) {
        if (!this.selectedRanges) this.selectedRanges = {}
        this.selectedRanges[metadataId] = { ...this.savedRanges[metadataId] }
      } else {
        // No saved range - initialize with full range from slider
        const rangeSection = document.querySelector(`.metadata-range-section[data-metadata-id="${metadataId}"]`)
        if (rangeSection) {
          const rangeSliderController = this.application.getControllerForElementAndIdentifier(
            rangeSection.querySelector('[data-controller="range-slider"]'),
            'range-slider'
          )
          if (rangeSliderController) {
            const min = rangeSliderController.minValue
            const max = rangeSliderController.maxValue
            if (!this.selectedRanges) this.selectedRanges = {}
            this.selectedRanges[metadataId] = { min, max }
          }
        }
      }
    }
    
    // Update filtering
    this.dataManager.updateCellFiltering()
  }

  updateSelectAllCheckboxState(metadataId) {
    const selectAllCheckbox = document.querySelector(`.metadata-select-all-checkbox[data-metadata-id="${metadataId}"]`)
    if (!selectAllCheckbox) return
    
    const allCategoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    const totalCategories = allCategoryCheckboxes.length
    const selectedCount = this.selectedCategories && this.selectedCategories[metadataId] ? this.selectedCategories[metadataId].size : 0
    
    const icon = selectAllCheckbox.querySelector('i')
    
    if (selectedCount === 0) {
      // None selected - white background, no checkmark
      selectAllCheckbox.style.backgroundColor = 'white'
      selectAllCheckbox.style.borderColor = '#d1d5db'
      if (icon) {
        icon.style.display = 'none'
      }
    } else if (selectedCount === totalCategories) {
      // All selected - white background, green checkmark
      selectAllCheckbox.style.backgroundColor = 'white'
      selectAllCheckbox.style.borderColor = '#d1d5db'
      if (icon) {
        icon.style.display = 'block'
        icon.style.color = '#10b981' // green
      }
    } else {
      // Some selected - orange background, white checkmark
      selectAllCheckbox.style.backgroundColor = '#f59e0b' // orange
      selectAllCheckbox.style.borderColor = '#f59e0b'
      if (icon) {
        icon.style.display = 'block'
        icon.style.color = 'white'
      }
    }
  }

  async toggleCategorySelection(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const metadataId = event.currentTarget.dataset.metadataId
    const category = event.currentTarget.dataset.category
    const checkbox = event.currentTarget
    
    // Check if filtering is enabled
    const filterSwitch = document.querySelector(`.metadata-filter-switch[data-metadata-id="${metadataId}"]`)
    const isFilterEnabled = filterSwitch && filterSwitch.dataset.filterEnabled === 'true'
    
    if (!isFilterEnabled) {
      console.log(`🔄 Category selection blocked - filtering is disabled`)
      return
    }
    
    // Check if selected by looking at the checkmark visibility and color
    const icon = checkbox.querySelector('i')
    const isSelected = icon && icon.style.display !== 'none' && icon.style.color === 'rgb(16, 185, 129)' // #10b981
    
    console.log(`🔄 Toggle category selection: ${category}, isSelected: ${isSelected}`)
    
    // Ensure metadata is loaded (from memory or disk)
    let metadataVector = this.dataManager.getMetadataVectorById(metadataId)
    if (!metadataVector) {
      try {
        metadataVector = await this.loadMetadataVectorFromDisk(metadataId)
        if (!metadataVector) {
          // Try direct server loading as last resort
          metadataVector = await this.dataManager.loadSingleMetadataVector(metadataId)
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
    if ((metadataVector?.data_type === 'DISCRETE' || metadataVector?.data_type === 'STRING') && !this.selectedCategories[metadataId]) {
      await this.initializeCheckboxesForMetadata(metadataId)
    }
    
    // Toggle the checkbox state
    if (isSelected) {
      // Deselect this category
      console.log(`🔄 About to deselect category: ${category}`)
      checkbox.style.backgroundColor = 'white'
      const icon = checkbox.querySelector('i')
      icon.style.display = 'none'
      this.deselectCategory(metadataId, category)
    } else {
      // Select this category
      console.log(`🔄 About to select category: ${category}`)
      checkbox.style.backgroundColor = 'white'
      const icon = checkbox.querySelector('i')
      icon.style.display = 'block'
      icon.style.color = '#10b981' // green checkmark
      this.selectCategory(metadataId, category)
    }
    
    // Update the select all checkbox state
    this.updateSelectAllCheckboxState(metadataId)
    
    // Update filter switch visibility (show/hide based on selection)
    this.uiManager.updateFilterSwitchVisibility(metadataId)
    
    // Update cell filtering
    console.log(`🔄 About to call updateCellFiltering`)
    this.dataManager.updateCellFiltering()
    console.log(`🔄 updateCellFiltering completed`)
    
    // Note: Category label re-rendering is handled by updateCellFiltering() in ReGL mode
    // (it redraws the entire overlay including labels with new centroids)
    
    console.log(`🔄 toggleCategorySelection function completed`)
  }

  async selectAllCategoriesForMetadata(metadataId) {
    console.log(`🔍 [SELECT ALL] Selecting all categories for metadata ${metadataId}`)
    
    // Debug: Check what's in memory
    console.log(`🔍 [SELECT ALL] currentMetadataId:`, this.currentMetadataId)
    console.log(`🔍 [SELECT ALL] currentMetadataVector exists:`, !!this.currentMetadataVector)
    console.log(`🔍 [SELECT ALL] loadedMetadataVectors keys:`, Object.keys(this.loadedMetadataVectors || {}))
    console.log(`🔍 [SELECT ALL] loadedMetadataVectors[${metadataId}] exists:`, !!this.loadedMetadataVectors?.[metadataId])
    
    // Get the metadata vector to access ALL categories
    let metadataVector = this.dataManager.getMetadataVectorById(metadataId)
    console.log(`🔍 [SELECT ALL] getMetadataVectorById returned:`, !!metadataVector)
    console.log(`🔍 [SELECT ALL] metadataVector.values exists:`, !!metadataVector?.values)
    
    // If metadata exists but values are not decompressed, decompress it manually
    if (metadataVector && !metadataVector.values && metadataVector.compression_info) {
      console.log(`🔍 [SELECT ALL] Metadata exists but not decompressed, decompressing...`)
      const compressionInfo = metadataVector.compression_info
      
      // Handle single_category compression (all cells have the same value)
      if (compressionInfo.single_category) {
        const category = compressionInfo.categories[compressionInfo.category_index]
        const length = compressionInfo.length
        metadataVector.values = new Array(length).fill(category)
        console.log(`🔍 [SELECT ALL] Decompressed single_category: ${category} (${length} cells)`)
      } else {
        console.error(`🔍 [SELECT ALL] Unknown compression format:`, compressionInfo)
        return
      }
    }
    
    // If not in memory at all, load it first
    if (!metadataVector) {
      console.log(`🔍 [SELECT ALL] Metadata not in memory, loading...`)
      try {
        metadataVector = await this.loadMetadataVectorFromDisk(metadataId)
        if (!metadataVector) {
          // Try loading from server as fallback
          await this.dataManager.loadSingleMetadataVector(metadataId)
          metadataVector = this.dataManager.getMetadataVectorById(metadataId)
        }
      } catch (error) {
        console.error(`🔍 [SELECT ALL] Failed to load metadata ${metadataId}:`, error)
        return
      }
    }
    
    if (!metadataVector || !metadataVector.values) {
      console.error(`🔍 [SELECT ALL] No metadata vector values found for ${metadataId}`)
      console.error(`🔍 [SELECT ALL] metadataVector:`, metadataVector)
      return
    }
    
    // Initialize selectedCategories if needed
    if (!this.selectedCategories) {
      this.selectedCategories = {}
    }
    if (!this.selectedCategories[metadataId]) {
      this.selectedCategories[metadataId] = new Set()
    }
    
    // Add ALL unique categories from the metadata vector
    const allCategories = [...new Set(metadataVector.values)]
    allCategories.forEach(category => {
      this.selectedCategories[metadataId].add(category)
    })
    
    console.log(`🔍 [SELECT ALL] Selected ${this.selectedCategories[metadataId].size} categories`)
    
    // Update the visual state of category checkboxes in the HTML
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = 'white'
      const icon = checkbox.querySelector('i')
      icon.style.display = 'block'
      icon.style.color = '#10b981' // green checkmark
    })
    
    // Update filter switch visibility (hide when all selected)
    this.uiManager.updateFilterSwitchVisibility(metadataId)
    
    // Update cell filtering (which will re-render labels in ReGL mode)
    this.dataManager.updateCellFiltering()
  }

  deselectAllCategoriesForMetadata(metadataId) {
    console.log(`🔍 [DESELECT ALL] Deselecting all categories for metadata ${metadataId}`)
    
    // Clear ALL categories from the Set (not just the ones in HTML)
    if (this.selectedCategories && this.selectedCategories[metadataId]) {
      this.selectedCategories[metadataId].clear()
      console.log(`🔍 [DESELECT ALL] Cleared all categories from selectedCategories`)
    }
    
    // Update the visual state of category checkboxes in the HTML
    const categoryCheckboxes = document.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"]`)
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = 'white'
      checkbox.querySelector('i').style.display = 'none'
    })
    
    console.log(`🔍 [DESELECT ALL] Updated ${categoryCheckboxes.length} visible checkboxes`)
    
    // Update filter switch visibility (show when not all selected)
    this.uiManager.updateFilterSwitchVisibility(metadataId)
    
    // Update cell filtering (which will re-render labels in ReGL mode)
    this.dataManager.updateCellFiltering()
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


  async initializeCheckboxesForMetadata(metadataId) {
    console.log(`🔍 [INIT] Initializing checkboxes for metadata: ${metadataId}`)
    
    // Ensure metadata is loaded (from memory or disk)
    let metadataVector = this.dataManager.getMetadataVectorById(metadataId)
    if (!metadataVector) {
      console.log(`💾 [DISK] Metadata ${metadataId} not in memory, loading from disk...`)
      metadataVector = await this.loadMetadataVectorFromDisk(metadataId)
      if (!metadataVector) {
        console.error(`💾 [DISK] Failed to load metadata ${metadataId} from disk`)
        return
      }
    }
    
    // Only initialize for discrete metadata
    if (!metadataVector || (metadataVector.data_type !== 'DISCRETE' && metadataVector.data_type !== 'STRING')) {
      console.log(`Skipping checkbox initialization for non-discrete metadata: ${metadataId}`)
      return
    }
    
    // Only initialize if not already initialized
    if (this.selectedCategories[metadataId]) {
      console.log(`🔍 [INIT] Checkboxes already initialized for metadata ${metadataId}, skipping`)
      return
    }
    
    // Initialize the selected categories for this metadata
    // Get ALL unique categories from the actual metadata vector, not just from HTML
    this.selectedCategories[metadataId] = new Set()
    
    if (metadataVector.values && Array.isArray(metadataVector.values)) {
      // Get all unique categories from the metadata values
      const allCategories = [...new Set(metadataVector.values)]
      allCategories.forEach(category => {
        this.selectedCategories[metadataId].add(category)
      })
      console.log(`🔍 [INIT] Initialized ${this.selectedCategories[metadataId].size} categories from metadata vector for ${metadataId}`)
    } else {
      console.error(`🔍 [INIT] No values found in metadata vector for ${metadataId}`)
    }
    
    // Update point count display after initializing checkboxes
    this.dataManager.updateCellFiltering()
    
    // Show the filter switch now that we have a selection
    this.uiManager.updateFilterSwitchVisibility(metadataId)
  }


  // Enable range slider for continuous metadata

  // Optimized method to show/hide points without re-rendering
  async updatePointVisibility(filteredIndices) {
    console.log('🎨 [VISIBILITY] updatePointVisibility called:', {
      rendererType: this.rendererType,
      filteredIndicesCount: filteredIndices ? filteredIndices.length : 'null',
      hasScatterContainer: !!this.scatterContainer,
      scatterContainerChildren: this.scatterContainer?.children?.length
    })
    
    // ReGL path: update point visibility by modifying alpha channel
    if (this.rendererType === 'regl') {
      console.log('🎨 [VISIBILITY] Using ReGL path')
      return this.updatePointVisibilityReGL(filteredIndices)
    }
    
    // PixiJS path
    if (!this.scatterContainer || !this.scatterContainer.children) {
      console.log('🎨 [VISIBILITY] No scatter container or children - cannot update visibility')
      return
    }
    
    console.log('🎨 [VISIBILITY] Using PixiJS path')

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
  // OPTIMIZED: Uses cached colors and only recalculates when coloring metadata changes
  async updatePointVisibilityReGL(filteredIndices) {
    console.log('🎨 [ReGL] updatePointVisibilityReGL called:', {
      hasReglRenderer: !!this.reglRenderer,
      hasCurrentCoordinates: !!this.currentCoordinates,
      currentCoordinatesLength: this.currentCoordinates?.length || 0,
      hasDisplayOrder: !!this.displayOrder,
      displayOrderLength: this.displayOrder?.length || 0,
      filteredIndicesCount: filteredIndices ? filteredIndices.length : 'null'
    })
    
    // Check if renderer is ready: must have renderer
    if (!this.reglRenderer) {
      console.log('🎨 [ReGL] Cannot update visibility - missing renderer')
      return
    }
    
    // Log renderer state for debugging
    console.log('🎨 [ReGL] Renderer direct state check:', {
      numPoints: this.reglRenderer.numPoints,
      hasPositions: !!this.reglRenderer.positions,
      positionsLength: this.reglRenderer.positions?.length,
      hasColors: !!this.reglRenderer.colors,
      colorsLength: this.reglRenderer.colors?.length,
      hasPositionBuffer: !!this.reglRenderer.positionBuffer,
      hasColorBuffer: !!this.reglRenderer.colorBuffer,
      hasRegl: !!this.reglRenderer.regl
    })
    
    // Verify renderer is connected to the canvas
    if (this.canvas && this.reglRenderer.canvas !== this.canvas) {
      console.warn('🎨 [ReGL] WARNING: Renderer canvas does not match controller canvas!')
      console.warn('🎨 [ReGL] Controller canvas:', this.canvas)
      console.warn('🎨 [ReGL] Renderer canvas:', this.reglRenderer.canvas)
      console.warn('🎨 [ReGL] This may indicate the renderer was recreated')
    }
    
    // If displayOrder doesn't exist, we need to create it
    // But we need to know how many points there are
    if (!this.displayOrder || this.displayOrder.length === 0) {
      // Try to determine number of points from renderer state
      // Same logic as in regl_renderer.js render() method
      let numPoints = 0
      
      // First check renderer's direct properties (most reliable)
      if (this.reglRenderer.numPoints && this.reglRenderer.numPoints > 0) {
        numPoints = this.reglRenderer.numPoints
        console.log('🎨 [ReGL] Using renderer.numPoints:', numPoints)
      } else if (this.reglRenderer.positions && this.reglRenderer.positions.length > 0) {
        // positions is a Float32Array: [x1, y1, x2, y2, ...], so numPoints = length / 2
        numPoints = this.reglRenderer.positions.length / 2
        console.log('🎨 [ReGL] Inferring numPoints from positions array length:', numPoints, '(positions length:', this.reglRenderer.positions.length, ')')
        // Update numPoints in renderer for consistency
        this.reglRenderer.numPoints = numPoints
      } else if (this.currentCoordinates && this.currentCoordinates.length > 0) {
        // Fallback: use currentCoordinates if available
        numPoints = this.currentCoordinates.length
        console.log('🎨 [ReGL] Using currentCoordinates length for numPoints:', numPoints)
      } else if (this.numPoints && this.numPoints > 0) {
        // Fallback: use controller's stored numPoints (set in renderScatterPlot)
        numPoints = this.numPoints
        console.log('🎨 [ReGL] Using controller numPoints:', numPoints)
      } else if (this.reglRenderer.colors && this.reglRenderer.colors.length > 0) {
        // Fallback: infer from colors array length (colors is RGBA, so numPoints = length / 4)
        numPoints = this.reglRenderer.colors.length / 4
        console.log('🎨 [ReGL] Inferring numPoints from colors array length:', numPoints, '(colors length:', this.reglRenderer.colors.length, ')')
        // Update numPoints in renderer for consistency
        this.reglRenderer.numPoints = numPoints
      } else if (this.decompressedCoordinatesCache) {
        // Try to get coordinates from cache
        console.log('🎨 [ReGL] Checking decompressedCoordinatesCache:', {
          cacheExists: !!this.decompressedCoordinatesCache,
          cacheSize: this.decompressedCoordinatesCache.size,
          cacheKeys: Array.from(this.decompressedCoordinatesCache.keys())
        })
        
        // If metadataData is not available, use the first (or only) entry in the cache
        let cachedCoords = null
        if (this.metadataData && this.metadataData.name) {
          const embeddingId = this.metadataData.name
          console.log('🎨 [ReGL] Looking for embeddingId in cache:', embeddingId)
          cachedCoords = this.decompressedCoordinatesCache.get(embeddingId)
          if (cachedCoords) {
            console.log('🎨 [ReGL] Found coordinates in cache for embeddingId:', embeddingId, 'length:', cachedCoords.length)
          } else {
            console.log('🎨 [ReGL] No coordinates found in cache for embeddingId:', embeddingId)
          }
        } else {
          // No metadataData, but cache exists - use first entry
          console.log('🎨 [ReGL] metadataData not available, trying first cache entry')
          const firstCacheKey = this.decompressedCoordinatesCache.keys().next().value
          if (firstCacheKey) {
            console.log('🎨 [ReGL] Using first cache entry:', firstCacheKey)
            cachedCoords = this.decompressedCoordinatesCache.get(firstCacheKey)
            if (cachedCoords) {
              console.log('🎨 [ReGL] Found coordinates in first cache entry, length:', cachedCoords.length)
            } else {
              console.log('🎨 [ReGL] First cache entry exists but coordinates are null/undefined')
            }
          } else {
            console.log('🎨 [ReGL] Cache exists but has no keys')
          }
        }
        if (cachedCoords && cachedCoords.length > 0) {
          numPoints = cachedCoords.length
          console.log('🎨 [ReGL] Using cached decompressed coordinates length for numPoints:', numPoints)
        } else {
          console.log('🎨 [ReGL] Could not get coordinates from cache')
        }
      }
      
      if (numPoints === 0) {
        // Renderer has no positions and no coordinates available
        // This means the plot hasn't been rendered yet, or renderer state is lost
        console.log('🎨 [ReGL] Cannot determine number of points - renderer not initialized')
        console.log('🎨 [ReGL] Renderer state:', {
          hasNumPoints: !!this.reglRenderer.numPoints,
          numPoints: this.reglRenderer.numPoints,
          hasPositions: !!this.reglRenderer.positions,
          positionsLength: this.reglRenderer.positions?.length,
          hasPositionBuffer: !!this.reglRenderer.positionBuffer,
          hasColorBuffer: !!this.reglRenderer.colorBuffer,
          hasCurrentCoordinates: !!this.currentCoordinates,
          currentCoordinatesLength: this.currentCoordinates?.length,
          hasMetadataData: !!this.metadataData,
          hasDecompressedCache: !!this.decompressedCoordinatesCache,
          cacheSize: this.decompressedCoordinatesCache?.size || 0
        })
        
        // If plot is visible (canvas exists and has been drawn), try to restore state
        // Try multiple sources for coordinates:
        // 1. currentCoordinates (if available)
        // 2. decompressedCoordinatesCache (if metadataData exists)
        // 3. Any coordinates in the cache (use first available)
        let coordinatesToUse = null
        
        if (this.currentCoordinates && this.currentCoordinates.length > 0) {
          coordinatesToUse = this.currentCoordinates
          console.log('🎨 [ReGL] Found coordinates in currentCoordinates:', coordinatesToUse.length)
        } else if (this.metadataData && this.metadataData.name && this.decompressedCoordinatesCache) {
          const embeddingId = this.metadataData.name
          coordinatesToUse = this.decompressedCoordinatesCache.get(embeddingId)
          if (coordinatesToUse) {
            console.log('🎨 [ReGL] Found coordinates in cache for embeddingId:', embeddingId, 'length:', coordinatesToUse.length)
          }
        } else if (this.decompressedCoordinatesCache && this.decompressedCoordinatesCache.size > 0) {
          // Try any available coordinates in cache
          const firstKey = this.decompressedCoordinatesCache.keys().next().value
          if (firstKey) {
            coordinatesToUse = this.decompressedCoordinatesCache.get(firstKey)
            if (coordinatesToUse) {
              console.log('🎨 [ReGL] Found coordinates in cache (first available):', firstKey, 'length:', coordinatesToUse.length)
            }
          }
        }
        
        if (this.canvas && coordinatesToUse && coordinatesToUse.length > 0) {
          console.log('🎨 [ReGL] Plot is visible but renderer state missing - attempting to restore state by re-rendering')
          console.log('🎨 [ReGL] Re-rendering with', coordinatesToUse.length, 'coordinates')
          // Store coordinates for next time
          this.currentCoordinates = coordinatesToUse
          // Re-render to restore renderer state
          await this.renderScatterPlot(coordinatesToUse)
          // After re-rendering, numPoints should be available
          numPoints = coordinatesToUse.length
          console.log('🎨 [ReGL] State restored, numPoints:', numPoints)
        } else {
          console.log('🎨 [ReGL] Cannot restore state - missing coordinates or canvas')
          console.log('🎨 [ReGL] Available sources:', {
            hasCanvas: !!this.canvas,
            hasCurrentCoordinates: !!this.currentCoordinates,
            currentCoordinatesLength: this.currentCoordinates?.length || 0,
            hasMetadataData: !!this.metadataData,
            metadataDataName: this.metadataData?.name,
            hasDecompressedCache: !!this.decompressedCoordinatesCache,
            cacheSize: this.decompressedCoordinatesCache?.size || 0,
            cacheKeys: this.decompressedCoordinatesCache ? Array.from(this.decompressedCoordinatesCache.keys()) : []
          })
          // Skip update - plot will update when renderScatterPlot is called
          return
        }
      }
      
      if (numPoints > 0) {
        console.log('🎨 [ReGL] Creating identity displayOrder for', numPoints, 'points')
        this.displayOrder = new Array(numPoints)
        for (let i = 0; i < numPoints; i++) {
          this.displayOrder[i] = i
        }
        
        // If renderer has no colorBuffer, we can't update colors
        // But if colors array exists, we can create the buffer
        if (!this.reglRenderer.colorBuffer) {
          if (this.reglRenderer.colors && this.reglRenderer.colors.length > 0) {
            // Colors array exists but buffer is missing - create it
            console.log('🎨 [ReGL] Colors array exists but colorBuffer missing, creating buffer...')
            this.reglRenderer.colorBuffer = this.reglRenderer.regl.buffer(this.reglRenderer.colors)
            console.log('🎨 [ReGL] Color buffer created')
          } else {
            console.warn('🎨 [ReGL] WARNING: Renderer has no colorBuffer and no colors array')
            console.warn('🎨 [ReGL] Renderer buffer state:', {
              hasPositionBuffer: !!this.reglRenderer.positionBuffer,
              hasColorBuffer: !!this.reglRenderer.colorBuffer,
              hasPositions: !!this.reglRenderer.positions,
              positionsLength: this.reglRenderer.positions?.length,
              hasColors: !!this.reglRenderer.colors,
              colorsLength: this.reglRenderer.colors?.length,
              numPoints: this.reglRenderer.numPoints,
              hasRegl: !!this.reglRenderer.regl,
              canvasExists: !!this.canvas,
              canvasWidth: this.canvas?.width,
              canvasHeight: this.canvas?.height
            })
            console.warn('🎨 [ReGL] Skipping visibility update - renderer needs colors/buffers set via renderScatterPlot()')
            return
          }
        }
        
        // Position buffer is needed for rendering, but not for color updates
        // If it's missing, we can still update colors (they'll be applied on next render)
        if (!this.reglRenderer.positionBuffer) {
          console.warn('🎨 [ReGL] WARNING: Position buffer missing, but proceeding with color update')
        }
      } else {
        console.log('🎨 [ReGL] Cannot update visibility - numPoints is 0')
        return
      }
    }
    
    const startTime = performance.now()
    console.log('🎨 [ReGL] Updating point visibility based on filters')
    console.log('🎨 [ReGL] filteredIndices:', filteredIndices ? `Array of ${filteredIndices.length} indices` : 'null (all visible)')
    if (filteredIndices && filteredIndices.length > 0) {
      console.log('🎨 [ReGL] First 10 filtered indices:', filteredIndices.slice(0, 10))
      console.log('🎨 [ReGL] Last 10 filtered indices:', filteredIndices.slice(-10))
    }
    console.log('🎨 [ReGL] displayOrder length:', this.displayOrder?.length)
    
    // Convert filteredIndices to Set for O(1) lookup
    // filteredIndices contains ORIGINAL cell indices
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    console.log('🎨 [ReGL] filteredSet created:', filteredSet ? `Set with ${filteredSet.size} indices` : 'null (all visible)')
    if (filteredSet && filteredSet.size > 0) {
      const sampleIndices = Array.from(filteredSet).slice(0, 5)
      console.log('🎨 [ReGL] Sample indices in filteredSet:', sampleIndices)
    }
    
    // Get the metadata vector that is actually being used for coloring
    const coloringMetadataVector = this.colorManager.getColoringMetadataVector()
    console.log('🎨 [ReGL] Coloring metadata:', coloringMetadataVector ? coloringMetadataVector.id : 'none')
    
    // Check if we need to recalculate colors (only when coloring metadata changes)
    const needsColorRecalculation = this.colorManager.shouldRecalculateColors(coloringMetadataVector)
    
    // Also check if cache is empty - if so, populate it
    const cacheEmpty = !this.cachedColorsByCellIndex || this.cachedColorsByCellIndex.size === 0
    console.log('🎨 [ReGL] Color cache state:', {
      exists: !!this.cachedColorsByCellIndex,
      size: this.cachedColorsByCellIndex?.size || 0,
      isEmpty: cacheEmpty,
      needsRecalculation: needsColorRecalculation
    })
    
    if (needsColorRecalculation || cacheEmpty) {
      if (cacheEmpty) {
        console.log('🎨 [ReGL] Color cache is empty, populating with default or calculated colors')
      } else {
      console.log('🎨 [ReGL] Recalculating colors due to coloring metadata change')
      }
      this.colorManager.calculateAndCacheColors(coloringMetadataVector)
      console.log('🎨 [ReGL] Color cache after population:', {
        size: this.cachedColorsByCellIndex?.size || 0,
        hasSample: this.cachedColorsByCellIndex?.has(0) || false,
        sampleColor: this.cachedColorsByCellIndex?.get(0)?.toString(16) || 'none'
      })
    }
    
    // Create color map to hide/show points based on filtering
    // We'll use the alpha channel approach: set alpha to 0 for hidden points
    const colorMap = new Map()
    let visibleCount = 0
    let hiddenCount = 0
    
    console.log(`🎨 [ReGL] Building color map for ${this.displayOrder.length} points, filteredSet size: ${filteredSet ? filteredSet.size : 'null (all visible)'}`)
    
    // Sample a few points to debug visibility logic
    const samplePositions = [0, 100, 1000, 5000, 10000]
    
    // Use displayOrder to map draw positions to cell indices
    for (let drawPos = 0; drawPos < this.displayOrder.length; drawPos++) {
      const cellIndex = this.displayOrder[drawPos]
      const shouldBeVisible = !filteredSet || filteredSet.has(cellIndex)
      
      if (shouldBeVisible) {
        // Use cached color (much faster than recalculating)
        const cachedColor = this.cachedColorsByCellIndex.get(cellIndex) || 0x3b82f6
        colorMap.set(drawPos, cachedColor)
        visibleCount++
        
        if (samplePositions.includes(drawPos)) {
          console.log(`🎨 [ReGL] Sample drawPos ${drawPos}: cellIndex=${cellIndex}, VISIBLE, color=0x${cachedColor.toString(16)}`)
        }
      } else {
        // Hide point by making it fully transparent
        colorMap.set(drawPos, 0x00000000)
        hiddenCount++
        
        if (samplePositions.includes(drawPos)) {
          console.log(`🎨 [ReGL] Sample drawPos ${drawPos}: cellIndex=${cellIndex}, HIDDEN (not in filteredSet), color=0x00000000`)
        }
      }
    }
    
    console.log(`🎨 [ReGL] Color map built: ${visibleCount} visible, ${hiddenCount} hidden, total: ${colorMap.size}`)
    console.log('🎨 [ReGL] Sample color map entries:', {
      first5: Array.from(colorMap.entries()).slice(0, 5).map(([pos, color]) => `pos${pos}=0x${color.toString(16)}`),
      last5: Array.from(colorMap.entries()).slice(-5).map(([pos, color]) => `pos${pos}=0x${color.toString(16)}`)
    })
    console.log(`🎨 [ReGL] About to call updateColors with ${colorMap.size} color updates`)
    
    // Update colors (which includes alpha channel)
    const updateColorsStart = performance.now()
    this.reglRenderer.updateColors(colorMap)
    const updateColorsTime = performance.now() - updateColorsStart
    console.log(`🎨 [ReGL] updateColors completed in ${updateColorsTime.toFixed(2)}ms`)
    
    const renderStart = performance.now()
    this.reglRenderer.render()
    const renderTime = performance.now() - renderStart
    console.log(`🎨 [ReGL] render() completed in ${renderTime.toFixed(2)}ms`)
    
    console.log(`🎨 [ReGL] Visibility update completed`)
    
    const elapsed = performance.now() - startTime
    console.log(`🎨 [ReGL] Total visibility update time: ${visibleCount} visible, ${hiddenCount} hidden in ${elapsed.toFixed(2)}ms`)
  }

  // Update the point count display with detailed filtering information

  // Get a summary of current filtering constraints

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
    this.dataManager.performCellFilteringUpdate(false)
    
    const duration = performance.now() - startTime
    this.recordPerformanceMetrics('BatchedUpdates', duration)
  }




  // Get cell indices for a given metadata (handles both discrete and continuous)
  getCellsForMetadata(metadataId) {
    // Check if this is discrete metadata (including empty Set which means "show nothing")
    if (this.selectedCategories[metadataId] !== undefined) {
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
    let metadataVector = this.dataManager.getMetadataVectorById(metadataId)
    if (!metadataVector || !metadataVector.values) {
      console.warn(`No metadata vector found for metadata ID: ${metadataId}`)
      console.log(`💾 Metadata ${metadataId} not in memory - selections will be ignored for now`)
      console.log(`💡 Tip: Load this metadata to apply the filtering`)
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
    // Debug logging for gene filtering
    if (metadataId && metadataId.startsWith('gene_')) {
      console.log(`🔍 [GENE FILTER] getCellsForMetadataRange called for gene: ${metadataId}`)
      console.log(`🔍 [GENE FILTER] Range:`, range)
      console.log(`🔍 [GENE FILTER] loadedMetadataVectors keys:`, Object.keys(this.loadedMetadataVectors || {}))
      console.log(`🔍 [GENE FILTER] Has gene in loadedMetadataVectors:`, !!this.loadedMetadataVectors?.[metadataId])
    }
    
    // Find the metadata vector for this metadata ID
    const metadataVector = this.dataManager.getMetadataVectorById(metadataId)
    if (!metadataVector || !metadataVector.values) {
      console.warn(`No metadata vector found for metadata ID: ${metadataId}`)
      if (metadataId && metadataId.startsWith('gene_')) {
        console.error(`❌ [GENE FILTER] CRITICAL: Gene metadata vector not found!`)
        console.error(`❌ [GENE FILTER] loadedMetadataVectors:`, this.loadedMetadataVectors)
        console.error(`❌ [GENE FILTER] currentMetadataVector:`, this.currentMetadataVector)
      }
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
    const hadFilter = !!this.currentVisibleCells
    const filterSize = this.currentVisibleCells ? this.currentVisibleCells.length : 0
    const hasActiveFilterCriteria = (this.selectedCategories && Object.keys(this.selectedCategories).length > 0) ||
                                    (this.selectedRanges && Object.keys(this.selectedRanges).length > 0)
    
    console.log('[CLEAR STATE] clearIncrementalState called', {
      hadFilter: hadFilter,
      filterSize: filterSize,
      hasActiveFilterCriteria: hasActiveFilterCriteria,
      selectedCategories: this.selectedCategories ? Object.keys(this.selectedCategories).length : 0,
      selectedRanges: this.selectedRanges ? Object.keys(this.selectedRanges).length : 0
    })
    
    // Clear cache and state (needed for recalculation)
    this.lastFilterState = null
    this.filterCache.clear()
    
    // Clear metadata coloring cache when embedding changes
    // This ensures colors are recalculated with correct cell indices
    this._cachedColorMap = null
    this.lastColorUpdateHash = null
    this.colorUpdateCache.clear()
    
    // IMPORTANT: Only clear currentVisibleCells if there are no active filter criteria
    // If filter criteria exist, we should preserve the filter results OR trigger recalculation
    // Setting to null here causes the filter to appear "lost" even though criteria are preserved
    if (!hasActiveFilterCriteria) {
      // No active filters - safe to clear
      this.currentVisibleCells = null
      console.log('[CLEAR STATE] Cleared currentVisibleCells (no active filter criteria)')
    } else {
      // Active filter criteria exist - keep currentVisibleCells but mark cache as invalid
      // The filter will be recalculated on next updateCellFiltering() call
      console.log('[CLEAR STATE] Preserved currentVisibleCells (active filter criteria exist, will be recalculated)')
      // Note: currentVisibleCells is kept, but lastFilterState is cleared so it will be recalculated
    }
  }

  // Clear all checkbox selections when switching metadata
  clearAllCheckboxSelections() {
    // Clear the selected categories for all metadata
    this.selectedCategories = {}
    
    // Also clear continuous ranges to avoid intersection issues
    this.selectedRanges = {}
    
    // Reset all checkbox visual states
    const metadataCheckboxes = document.querySelectorAll('.metadata-checkbox')
    metadataCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = '#10b981' // Green (selected)
      const icon = checkbox.querySelector('i')
      if (icon) {
        icon.style.display = 'block'
      }
    })
    
    const categoryCheckboxes = document.querySelectorAll('.category-checkbox')
    categoryCheckboxes.forEach(checkbox => {
      checkbox.style.backgroundColor = 'white' // White background
      const icon = checkbox.querySelector('i')
      if (icon) {
        icon.style.display = 'block'
        icon.style.color = '#10b981' // Green checkmark
      }
    })
    
    console.log('🔄 Cleared all selections (categories and ranges)')
  }

  // Helper method to get metadata vector by ID
  getMetadataVectorById(metadataId) {
    // Check if it's the current metadata vector (fully loaded and decompressed)
    if (this.currentMetadataId === metadataId && this.currentMetadataVector) {
      // Update usage tracker for current metadata
      this.memoryManager.updateMetadataUsage(metadataId)
      return this.currentMetadataVector
    }
    
    // Check stored metadata vectors in memory
    if (this.loadedMetadataVectors && this.loadedMetadataVectors[metadataId]) {
      const vectorData = this.loadedMetadataVectors[metadataId]
      
      // Update usage tracker
      this.memoryManager.updateMetadataUsage(metadataId)
      
      // If it's already decompressed (has values), return it
      if (vectorData.values) {
        return vectorData
      }
      
      // If it's compressed, decompress it on demand
      try {
        let values
        if (vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING') {
          values = this.dataManager.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else if (vectorData.data_type === 'NUMERIC') {
          values = this.dataManager.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
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
      const result = this.loadedMetadataVectors[metadataId]
      if (!result) {
        console.error(`💾 [DISK] RACE CONDITION: Metadata ${metadataId} finished loading but not found in loadedMetadataVectors!`)
        console.error(`💾 [DISK] loadedMetadataVectors keys:`, Object.keys(this.loadedMetadataVectors))
      }
      return result
    }
    
    // Mark as loading to prevent race conditions
    this.loadingMetadataVectors.add(metadataId)
    
    try {
      // Load from IndexedDB
      const vectorData = await this.memoryManager.loadMetadataFromIndexedDB(metadataId)
      
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
        if (vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING') {
          values = this.dataManager.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else if (vectorData.data_type === 'NUMERIC') {
          values = this.dataManager.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
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
        
        // Status icon already updated during initial status check - no need to update again
        
        // Update usage tracker
        this.memoryManager.updateMetadataUsage(metadataId)
        
        // Trigger cleanup if we have too many metadata in memory
        this.memoryManager.cleanupUnusedMetadata()
        
        console.log(`💾 [DISK] Decompressed and cached metadata ${metadataId}: ${values.length} values`)
        return decompressedVector
      }
      
      // If already decompressed, store in memory and return
      this.loadedMetadataVectors[metadataId] = vectorData
      
      // Status icon already updated during initial status check - no need to update again
      
      // Update usage tracker
      this.memoryManager.updateMetadataUsage(metadataId)
      
      // Trigger cleanup if we have too many metadata in memory
      this.memoryManager.cleanupUnusedMetadata()
      
      return vectorData
      
    } catch (error) {
      console.error(`💾 [DISK] Error loading metadata vector ${metadataId} from disk:`, error)
      return null
    } finally {
      // Always remove from loading set, even if there was an error
      this.loadingMetadataVectors.delete(metadataId)
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
      if (vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING') {
        values = this.dataManager.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
      } else if (vectorData.data_type === 'NUMERIC') {
        values = this.dataManager.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
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
      this.dataManager.loadSingleMetadataVector(metadataId).then(vectorData => {
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
        
      // Check renderer state after initialization (for debugging - compare with gene initialization)
      console.log('🎚️ [CONTINUOUS INIT] Checking renderer state after initialization...')
      const continuousRendererState = {
        hasReglRenderer: !!this.reglRenderer,
        rendererInstanceId: this.reglRenderer?.instanceId || 'none',
        numPoints: this.reglRenderer?.numPoints || 0,
        hasPositions: !!this.reglRenderer?.positions,
        positionsLength: this.reglRenderer?.positions?.length || 0,
        hasCurrentCoordinates: !!this.currentCoordinates,
        currentCoordinatesLength: this.currentCoordinates?.length || 0,
        hasDisplayOrder: !!this.displayOrder,
        displayOrderLength: this.displayOrder?.length || 0
      }
      console.log('🎚️ [CONTINUOUS INIT] Renderer state:', continuousRendererState)
        
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
    this.dataManager.loadSingleMetadataVector(metadataId).then(vectorData => {
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
      //console.log('🎚️ Values loaded:', values.length, 'values, range:', this.dataManager.safeMin(values), 'to', this.dataManager.safeMax(values))
      
      const minVal = this.dataManager.safeMin(values)
      const maxVal = this.dataManager.safeMax(values)
      
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
      this.uiManager.showMetadataDropdownSpinner()
      
      this.dataManager.loadAndVisualizeMetadataVector(metadataId)
        .catch(error => {
          console.error('❌ Error visualizing metadata:', error)
        })
        .finally(() => {
          this.uiManager.hideMetadataDropdownSpinner()
        })
      
    }).catch(error => {
      console.error('❌ Error loading metadata for range slider:', error)
      alert('Error loading metadata: ' + error.message)
      this.uiManager.hideMetadataDropdownSpinner()
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
    
    const maxCount = this.dataManager.safeMax(histogram)
    
    // Draw histogram
    ctx.fillStyle = '#3b82f6'
    ctx.strokeStyle = '#1d4ed8'
    ctx.lineWidth = 1
    
    const margins = this.rendererManager.getPlotMargins()
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
    
    const margins = this.rendererManager.getPlotMargins()
    const plotWidth = width - margins.left - margins.right
    const plotHeight = height - margins.top - margins.bottom
    const categoryWidth = plotWidth / numCategories
    const startX = margins.left
    const startY = margins.top
    
    // Get color palette
    const colors = this.colorManager.getCategoryColors()
    
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
    this.uiManager.showMetadataDropdownSpinner()
    
    // Load and visualize metadata with the selected range
    this.dataManager.loadAndVisualizeMetadataVector(this.currentRangeSliderMetadataId)
      .catch(error => {
        console.error('❌ Error visualizing metadata:', error)
      })
      .finally(() => {
        this.uiManager.hideMetadataDropdownSpinner()
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

  // Draw category distribution bar plots (cumulative stacked bars showing coloring metadata distribution)
  drawCategoryDistributions(metadataId) {
    // Get the metadata vector that's being displayed (the one with categories)
    const displayedMetadataVector = this.dataManager.getMetadataVectorById(metadataId)
    if (!displayedMetadataVector || !displayedMetadataVector.values || displayedMetadataVector.data_type !== 'DISCRETE') {
      return
    }
    
    // Get all canvases for this metadata
    const canvases = document.querySelectorAll(`.category-distribution-canvas[data-metadata-id="${metadataId}"]`)
    
    // Get the metadata vector used for coloring (currentMetadataVector)
    const coloringMetadataVector = this.currentMetadataVector
    if (!coloringMetadataVector || !coloringMetadataVector.values) {
      // No coloring active, hide bar plots to make categories more compact
      canvases.forEach(canvas => {
        canvas.style.display = 'none'
      })
      return
    }
    
    // Show bar plots when coloring is active
    canvases.forEach(canvas => {
      canvas.style.display = 'block'
    })
    
    // Check if coloring is continuous or categorical
    if (coloringMetadataVector.data_type === 'NUMERIC') {
      // Draw continuous distribution (gradient bar)
      this.drawContinuousDistributions(metadataId, displayedMetadataVector, coloringMetadataVector)
      return
    } else if (coloringMetadataVector.data_type !== 'DISCRETE') {
      // Unknown type, don't draw
      return
    }
    
    // Get filtered cell indices (if any filters are active)
    const filteredIndices = this.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    
    // Count occurrences of each coloring category (filtered only)
    const coloringCategoryCounts = {}
    const totalCells = coloringMetadataVector.values.length
    
    for (let i = 0; i < coloringMetadataVector.values.length; i++) {
      if (!filteredSet || filteredSet.has(i)) {
        const category = coloringMetadataVector.values[i]
        coloringCategoryCounts[category] = (coloringCategoryCounts[category] || 0) + 1
      }
    }
    
    // Sort coloring categories by count (largest first) to match plot ordering
    const sortedColoringCategories = Object.keys(coloringCategoryCounts).sort((a, b) => {
      return (coloringCategoryCounts[b] || 0) - (coloringCategoryCounts[a] || 0)
    })
    
    // Get category colors from color manager
    const categoryColors = this.colorManager.getCategoryColors(sortedColoringCategories.length)
    
    canvases.forEach(canvas => {
      const displayedCategory = canvas.dataset.category
      
      // Find all cells that belong to this displayed category (filtered only)
      const cellsInDisplayedCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInDisplayedCategory.push(i)
        }
      }
      
      // Count how many cells in this displayed category belong to each coloring category
      const distributionCounts = {}
      cellsInDisplayedCategory.forEach(cellIndex => {
        const coloringCategory = coloringMetadataVector.values[cellIndex]
        distributionCounts[coloringCategory] = (distributionCounts[coloringCategory] || 0) + 1
      })
      
      // Store segment information for tooltip
      const segments = []
      let currentX = 0
      
      sortedColoringCategories.forEach((coloringCategory, index) => {
        const count = distributionCounts[coloringCategory] || 0
        if (count > 0) {
          const percentage = (count / cellsInDisplayedCategory.length) * 100
          const segmentWidth = (percentage / 100) * canvas.getBoundingClientRect().width
          
          segments.push({
            category: coloringCategory,
            count: count,
            percentage: percentage,
            startX: currentX,
            endX: currentX + segmentWidth,
            color: categoryColors[index % categoryColors.length]
          })
          
          currentX += segmentWidth
        }
      })
      
      // Store segments data on canvas for tooltip
      canvas.dataset.segments = JSON.stringify(segments)
      
      // Set canvas size
      const rect = canvas.getBoundingClientRect()
      canvas.width = rect.width * window.devicePixelRatio
      canvas.height = rect.height * window.devicePixelRatio
      
      const ctx = canvas.getContext('2d')
      ctx.scale(window.devicePixelRatio, window.devicePixelRatio)
      
      // Draw background (light gray)
      ctx.fillStyle = '#f3f4f6'
      ctx.fillRect(0, 0, rect.width, rect.height)
      
      // Draw cumulative stacked bar
      segments.forEach(segment => {
        const colorValue = segment.color
        const color = typeof colorValue === 'string' ? colorValue : `#${colorValue.toString(16).padStart(6, '0')}`
        
        ctx.fillStyle = color
        const segmentWidth = segment.endX - segment.startX
        ctx.fillRect(segment.startX, 0, segmentWidth, rect.height)
      })
      
      // Add mousemove event listener for tooltip
      // Remove old listeners if they exist (to handle switching between categorical and continuous)
      if (canvas._tooltipHandler) {
        canvas.removeEventListener('mousemove', canvas._tooltipHandler)
        canvas.removeEventListener('mouseleave', canvas._tooltipLeaveHandler)
      }
      
      canvas.style.cursor = 'pointer'
      
      // Create custom tooltip element if it doesn't exist
      let tooltip = document.getElementById('category-bar-tooltip')
      if (!tooltip) {
        tooltip = document.createElement('div')
        tooltip.id = 'category-bar-tooltip'
        tooltip.style.cssText = `
          position: fixed;
          background-color: rgba(0, 0, 0, 0.85);
          color: white;
          padding: 6px 10px;
          border-radius: 4px;
          font-size: 12px;
          pointer-events: none;
          z-index: 10000;
          display: none;
          white-space: nowrap;
          box-shadow: 0 2px 8px rgba(0,0,0,0.2);
        `
        document.body.appendChild(tooltip)
      }
      
      // Create tooltip handler for categorical data
      const tooltipHandler = (e) => {
        const rect = canvas.getBoundingClientRect()
        const x = e.clientX - rect.left
        const segments = JSON.parse(canvas.dataset.segments || '[]')
        
        // Find which segment the mouse is over
        const hoveredSegment = segments.find(seg => x >= seg.startX && x < seg.endX)
        
        if (hoveredSegment) {
          const tooltipText = `${hoveredSegment.category} (${hoveredSegment.count} cells, ${hoveredSegment.percentage.toFixed(1)}%)`
          tooltip.textContent = tooltipText
          tooltip.style.display = 'block'
          tooltip.style.left = `${e.clientX + 10}px`
          tooltip.style.top = `${e.clientY + 10}px`
        } else {
          tooltip.style.display = 'none'
        }
      }
      
      const leaveHandler = () => {
        tooltip.style.display = 'none'
      }
      
      canvas.addEventListener('mousemove', tooltipHandler)
      canvas.addEventListener('mouseleave', leaveHandler)
      
      // Store handlers for later removal (using object properties, not dataset)
      canvas._tooltipHandler = tooltipHandler
      canvas._tooltipLeaveHandler = leaveHandler
    })
  }

  // Draw continuous distribution (histogram-like bar showing value distribution)
  drawContinuousDistributions(metadataId, displayedMetadataVector, coloringMetadataVector) {
    console.log('🎨 [BAR PLOTS] drawContinuousDistributions called for metadata:', metadataId)
    console.log('🎨 [BAR PLOTS] Current gradient points:', this.customGradientControlPoints || this.gradientControlPoints)
    
    // Get filtered cell indices (if any filters are active)
    const filteredIndices = this.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    
    // Get all canvases for this metadata
    const canvases = document.querySelectorAll(`.category-distribution-canvas[data-metadata-id="${metadataId}"]`)
    
    // Show bar plots when coloring is active
    canvases.forEach(canvas => {
      canvas.style.display = 'block'
    })
    
    // Use the same color range logic as the scatter plot
    // This ensures the gradient mapping is identical
    const effectiveRange = this.getEffectiveColorRange()
    let globalMin, globalMax
    
    if (effectiveRange && coloringMetadataVector.id === this.currentMetadataVector?.id) {
      // Use the effective color range (respects "Adapt color range" setting)
      globalMin = effectiveRange.min
      globalMax = effectiveRange.max
    } else if (coloringMetadataVector.compression_info) {
      // Use compression info range
      globalMin = coloringMetadataVector.compression_info.min_val
      globalMax = coloringMetadataVector.compression_info.max_val
    } else {
      // Fallback: calculate from filtered values
      const filteredColoringValues = coloringMetadataVector.values.filter((v, idx) => {
        return v !== null && v !== undefined && !isNaN(v) && (!filteredSet || filteredSet.has(idx))
      })
      globalMin = Math.min(...filteredColoringValues)
      globalMax = Math.max(...filteredColoringValues)
    }
    
    canvases.forEach(canvas => {
      const displayedCategory = canvas.dataset.category
      
      // Find all cells that belong to this displayed category (filtered only)
      const cellsInDisplayedCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInDisplayedCategory.push(i)
        }
      }
      
      // Get continuous values for these cells
      const values = cellsInDisplayedCategory.map(cellIndex => coloringMetadataVector.values[cellIndex])
      
      // Calculate statistics
      const validValues = values.filter(v => v !== null && v !== undefined && !isNaN(v))
      if (validValues.length === 0) {
        // No valid values, draw empty bar
        const rect = canvas.getBoundingClientRect()
        canvas.width = rect.width * window.devicePixelRatio
        canvas.height = rect.height * window.devicePixelRatio
        const ctx = canvas.getContext('2d')
        ctx.scale(window.devicePixelRatio, window.devicePixelRatio)
        ctx.fillStyle = '#f3f4f6'
        ctx.fillRect(0, 0, rect.width, rect.height)
        canvas.dataset.bins = JSON.stringify([])
        canvas.dataset.stats = JSON.stringify({ min: 0, max: 0, mean: 0, median: 0, count: 0 })
        return
      }
      
      const min = Math.min(...validValues)
      const max = Math.max(...validValues)
      const mean = validValues.reduce((a, b) => a + b, 0) / validValues.length
      const sortedValues = [...validValues].sort((a, b) => a - b)
      const median = sortedValues[Math.floor(sortedValues.length / 2)]
      
      // Store stats for download
      canvas.dataset.stats = JSON.stringify({ min, max, mean, median, count: validValues.length })
      
      // Create bins for histogram (use 20 bins across the global range)
      const numBins = 20
      const binWidth = (globalMax - globalMin) / numBins
      const bins = Array(numBins).fill(0)
      
      validValues.forEach(value => {
        const binIndex = Math.min(Math.floor((value - globalMin) / binWidth), numBins - 1)
        bins[binIndex]++
      })
      
      // Store bin information for tooltip
      const binData = bins.map((count, index) => ({
        start: globalMin + index * binWidth,
        end: globalMin + (index + 1) * binWidth,
        count: count,
        percentage: (count / validValues.length) * 100
      }))
      canvas.dataset.bins = JSON.stringify(binData)
      
      // Set canvas size
      const rect = canvas.getBoundingClientRect()
      canvas.width = rect.width * window.devicePixelRatio
      canvas.height = rect.height * window.devicePixelRatio
      
      const ctx = canvas.getContext('2d')
      ctx.scale(window.devicePixelRatio, window.devicePixelRatio)
      
      // Draw background (light gray)
      ctx.fillStyle = '#f3f4f6'
      ctx.fillRect(0, 0, rect.width, rect.height)
      
      // Get the actual gradient being used in the plot
      const controlPoints = this.customGradientControlPoints || this.gradientControlPoints || [
        { position: 0, color: 0x0000ff },
        { position: 0.5, color: 0x00ff00 },
        { position: 1, color: 0xff0000 }
      ]
      
      // Convert control points to hex strings if they're numbers
      const normalizedControlPoints = controlPoints.map(cp => ({
        position: cp.position,
        color: typeof cp.color === 'number' ? `#${cp.color.toString(16).padStart(6, '0')}` : cp.color
      }))
      
      // Helper function to get color at a specific position in the gradient
      const getColorAtPosition = (position) => {
        // Find the two control points that surround this position
        let lowerPoint = normalizedControlPoints[0]
        let upperPoint = normalizedControlPoints[normalizedControlPoints.length - 1]
        
        for (let i = 0; i < normalizedControlPoints.length - 1; i++) {
          if (position >= normalizedControlPoints[i].position && position <= normalizedControlPoints[i + 1].position) {
            lowerPoint = normalizedControlPoints[i]
            upperPoint = normalizedControlPoints[i + 1]
            break
          }
        }
        
        // Interpolate between the two colors
        const t = (position - lowerPoint.position) / (upperPoint.position - lowerPoint.position)
        const lower = this.hexToRgb(lowerPoint.color)
        const upper = this.hexToRgb(upperPoint.color)
        
        const r = Math.round(lower.r + (upper.r - lower.r) * t)
        const g = Math.round(lower.g + (upper.g - lower.g) * t)
        const b = Math.round(lower.b + (upper.b - lower.b) * t)
        
        return `rgb(${r}, ${g}, ${b})`
      }
      
      // Draw histogram bars with proportional widths
      let currentX = 0
      bins.forEach((count, index) => {
        if (count > 0) {
          // Calculate width proportional to the number of cells in this bin
          const proportion = count / validValues.length
          const segmentWidth = proportion * rect.width
          
          // Get color for this bin based on its actual value position in the selected range
          // The gradient maps globalMin to 0 and globalMax to 1
          const binCenterValue = globalMin + (index + 0.5) * binWidth
          const binPosition = (binCenterValue - globalMin) / (globalMax - globalMin)
          const color = getColorAtPosition(binPosition)
          
          ctx.fillStyle = color
          ctx.fillRect(currentX, 0, segmentWidth, rect.height)
          
          currentX += segmentWidth
        }
      })
      
      // Add mousemove event listener for tooltip
      // Remove old listeners if they exist (to handle switching between categorical and continuous)
      if (canvas._tooltipHandler) {
        canvas.removeEventListener('mousemove', canvas._tooltipHandler)
        canvas.removeEventListener('mouseleave', canvas._tooltipLeaveHandler)
      }
      
      canvas.style.cursor = 'pointer'
      
      // Create custom tooltip element if it doesn't exist
      let tooltip = document.getElementById('category-bar-tooltip')
      if (!tooltip) {
        tooltip = document.createElement('div')
        tooltip.id = 'category-bar-tooltip'
        tooltip.style.cssText = `
          position: fixed;
          background-color: rgba(0, 0, 0, 0.85);
          color: white;
          padding: 6px 10px;
          border-radius: 4px;
          font-size: 12px;
          pointer-events: none;
          z-index: 10000;
          display: none;
          white-space: nowrap;
          box-shadow: 0 2px 8px rgba(0,0,0,0.2);
        `
        document.body.appendChild(tooltip)
      }
      
      // Create tooltip handler for continuous data
      const tooltipHandler = (e) => {
        const rect = canvas.getBoundingClientRect()
        const x = e.clientX - rect.left
        const bins = JSON.parse(canvas.dataset.bins || '[]')
        const stats = JSON.parse(canvas.dataset.stats || '{}')
        
        // Calculate cumulative widths to find which bin was hovered
        let cumulativeWidth = 0
        let hoveredBin = null
        
        for (const bin of bins) {
          if (bin.count > 0) {
            const segmentWidth = (bin.count / stats.count) * rect.width
            if (x >= cumulativeWidth && x < cumulativeWidth + segmentWidth) {
              hoveredBin = bin
              break
            }
            cumulativeWidth += segmentWidth
          }
        }
        
        if (hoveredBin) {
          const tooltipText = `Range: ${hoveredBin.start.toFixed(2)} - ${hoveredBin.end.toFixed(2)} (${hoveredBin.count} cells, ${hoveredBin.percentage.toFixed(1)}%)`
          tooltip.textContent = tooltipText
          tooltip.style.display = 'block'
          tooltip.style.left = `${e.clientX + 10}px`
          tooltip.style.top = `${e.clientY + 10}px`
        } else {
          // Show overall stats
          const tooltipText = `Min: ${stats.min?.toFixed(2)}, Max: ${stats.max?.toFixed(2)}, Mean: ${stats.mean?.toFixed(2)}, Median: ${stats.median?.toFixed(2)} (${stats.count} cells)`
          tooltip.textContent = tooltipText
          tooltip.style.display = 'block'
          tooltip.style.left = `${e.clientX + 10}px`
          tooltip.style.top = `${e.clientY + 10}px`
        }
      }
      
      const leaveHandler = () => {
        tooltip.style.display = 'none'
      }
      
      canvas.addEventListener('mousemove', tooltipHandler)
      canvas.addEventListener('mouseleave', leaveHandler)
      
      // Store handlers for later removal (using object properties, not dataset)
      canvas._tooltipHandler = tooltipHandler
      canvas._tooltipLeaveHandler = leaveHandler
    })
  }
  
  // Helper function to convert hex color to RGB
  hexToRgb(hex) {
    const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex)
    return result ? {
      r: parseInt(result[1], 16),
      g: parseInt(result[2], 16),
      b: parseInt(result[3], 16)
    } : { r: 0, g: 0, b: 0 }
  }
  // Delegate download to DownloadManager
  async downloadGlobalDistribution(event) {
    return this.downloadManager.downloadGlobalDistribution(event)
  }

  async downloadGeneExpression(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const button = event.currentTarget
    const geneId = button.dataset.geneId
    const geneMetadataId = button.dataset.metadataId || `gene_${geneId}`
    
    console.log('🧬 Download gene expression:', { geneId, geneMetadataId })
    
    // Get gene expression data from GeneManager
    const geneManager = this.geneManager
    if (!geneManager || !geneManager.geneExpressionData || !geneManager.geneExpressionData[geneId]) {
      console.error('❌ Gene expression data not available for gene:', geneId)
      alert('Expression data not available for this gene.')
      return
    }
    
    const expressionData = geneManager.geneExpressionData[geneId]
    const values = expressionData.values
    
    if (!values || values.length === 0) {
      alert('No expression values available for this gene.')
      return
    }
    
    // Get filtered cell indices (if any filters are active)
    const filteredIndices = this.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const hasFilters = filteredSet !== null
    
    // Calculate statistics
    const stats = expressionData.stats || {}
    const minVal = Math.min(...values.filter(v => !isNaN(v) && isFinite(v)))
    const maxVal = Math.max(...values.filter(v => !isNaN(v) && isFinite(v)))
    const meanVal = stats.mean || 0
    const medianVal = stats.median || 0
    const stdDevVal = stats.stdDev || 0
    
    // Find gene symbol
    const geneTag = geneManager.geneTags.find(g => String(g.stableId) === String(geneId))
    const geneSymbol = geneTag?.symbol || geneId
    
    // Create CSV content
    let csvContent = `Gene Expression Data: ${geneSymbol}\n`
    csvContent += `Gene ID: ${geneId}\n`
    csvContent += `Total Cells: ${values.length}\n`
    csvContent += `Min: ${minVal.toFixed(4)}\n`
    csvContent += `Max: ${maxVal.toFixed(4)}\n`
    csvContent += `Mean: ${meanVal.toFixed(4)}\n`
    csvContent += `Median: ${medianVal.toFixed(4)}\n`
    csvContent += `Std Dev: ${stdDevVal.toFixed(4)}\n\n`
    
    if (hasFilters) {
      csvContent += `Filtered Cells: ${filteredIndices.length}\n\n`
    }
    
    csvContent += `Cell Index,Expression Value${hasFilters ? ',Filtered' : ''}\n`
    
    values.forEach((value, index) => {
      const isFiltered = hasFilters ? filteredSet.has(index) : true
      if (!hasFilters || isFiltered) {
        csvContent += `${index},${value.toFixed(6)}${hasFilters ? `,${isFiltered ? 'Yes' : 'No'}` : ''}\n`
      }
    })
    
    // Download file
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' })
    const link = document.createElement('a')
    const url = URL.createObjectURL(blob)
    link.setAttribute('href', url)
    link.setAttribute('download', `gene_${geneId}_expression.csv`)
    link.style.visibility = 'hidden'
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    
    console.log('🧬 Gene expression data downloaded')
  }

  // Old implementation moved to DownloadManager
  // The following methods are kept for reference but delegated:
  /*
  async downloadGlobalDistribution(event) {
    event.stopPropagation()
    
    const button = event.currentTarget
    const metadataId = parseInt(button.dataset.metadataId)
    
    // Get the displayed metadata vector
    const displayedMetadataVector = this.dataManager.getMetadataVectorById(metadataId)
    if (!displayedMetadataVector || !displayedMetadataVector.values || displayedMetadataVector.data_type !== 'DISCRETE') {
      console.warn('Cannot download: metadata must be categorical')
      return
    }
    
    // Get filtered cell indices (if any filters are active)
    const filteredIndices = this.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const hasFilters = filteredSet !== null
    
    // Get all unique categories and count them (total and filtered)
    const uniqueCategories = [...new Set(displayedMetadataVector.values)]
    const totalCategoryCounts = {}
    const filteredCategoryCounts = {}
    
    displayedMetadataVector.values.forEach((cat, idx) => {
      totalCategoryCounts[cat] = (totalCategoryCounts[cat] || 0) + 1
      if (!hasFilters || filteredSet.has(idx)) {
        filteredCategoryCounts[cat] = (filteredCategoryCounts[cat] || 0) + 1
      }
    })
    
    // Sort categories by filtered count (or total if no filters)
    const sortedCategories = uniqueCategories.sort((a, b) => {
      const countA = hasFilters ? (filteredCategoryCounts[a] || 0) : (totalCategoryCounts[a] || 0)
      const countB = hasFilters ? (filteredCategoryCounts[b] || 0) : (totalCategoryCounts[b] || 0)
      return countB - countA
    })
    
    // Load SheetJS library
    if (!window.XLSX) {
      try {
        await this.loadSheetJS()
      } catch (error) {
        console.warn('Could not load Excel library')
        return
      }
    }
    
    const wb = window.XLSX.utils.book_new()
    const totalCells = displayedMetadataVector.values.length
    const filteredTotalCells = hasFilters ? filteredSet.size : totalCells
    
    // Sheet 0: Active Filters (if filters exist)
    if (hasFilters) {
      this.addFiltersSheet(wb)
    }
    
    // Sheet 1 (or 2 if filters exist): Category Summary (with total and filtered counts)
    const summaryData = hasFilters 
      ? [['Category', 'Total Cells', 'Total %', 'Filtered Cells', 'Filtered %']]
      : [['Category', 'Cell Count', 'Percentage']]
    
    sortedCategories.forEach(category => {
      const totalCount = totalCategoryCounts[category] || 0
      const totalPercentage = parseFloat(((totalCount / totalCells) * 100).toFixed(2))
      
      if (hasFilters) {
        const filteredCount = filteredCategoryCounts[category] || 0
        const filteredPercentage = filteredTotalCells > 0 
          ? parseFloat(((filteredCount / filteredTotalCells) * 100).toFixed(2)) 
          : 0
        summaryData.push([category, totalCount, totalPercentage, filteredCount, filteredPercentage])
      } else {
        summaryData.push([category, totalCount, totalPercentage])
      }
    })
    const ws1 = window.XLSX.utils.aoa_to_sheet(summaryData)
    window.XLSX.utils.book_append_sheet(wb, ws1, 'Categories')
    
    // Check if there's active coloring
    const coloringMetadataVector = this.currentMetadataVector
    if (coloringMetadataVector && coloringMetadataVector.values) {
      if (coloringMetadataVector.data_type === 'DISCRETE' || coloringMetadataVector.data_type === 'STRING') {
        // Sheet 2: Categorical Distribution
        await this.addCategoricalDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
      } else if (coloringMetadataVector.data_type === 'NUMERIC') {
        // Sheet 2: Continuous Distribution (bins)
        await this.addContinuousDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
        // Sheet 3: Summary statistics for each category
        await this.addContinuousSummarySheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
      }
    }
    
    // Create filename
    const projectKey = this.getProjectKey()
    const displayedMetadataName = this.sanitizeFilename(displayedMetadataVector.name || 'metadata')
    const coloringSuffix = coloringMetadataVector 
      ? `_colored-by_${this.sanitizeFilename(coloringMetadataVector.name)}` 
      : ''
    const filename = `${projectKey}_${displayedMetadataName}_all-categories${coloringSuffix}.xlsx`
    
    // Write and download
    window.XLSX.writeFile(wb, filename)
    
    console.log(`Downloaded global distribution for ${displayedMetadataVector.name}`)
  }
  
  // Add filters sheet to workbook
  addFiltersSheet(wb) {
    const filtersData = [['Filter Type', 'Metadata', 'Filter Details']]
    
    // Add categorical filters
    if (this.selectedCategories && Object.keys(this.selectedCategories).length > 0) {
      for (const [metadataId, selectedCats] of Object.entries(this.selectedCategories)) {
        if (selectedCats && selectedCats.size > 0) {
          const metadataVector = this.dataManager.getMetadataVectorById(parseInt(metadataId))
          if (metadataVector) {
            const metadataName = metadataVector.name || `Metadata ${metadataId}`
            const allCategories = [...new Set(metadataVector.values)]
            
            // Only add if not all categories are selected (i.e., it's actually filtering)
            if (selectedCats.size < allCategories.length) {
              const selectedList = [...selectedCats].join(', ')
              const filterDetail = `Selected ${selectedCats.size} of ${allCategories.length} categories: ${selectedList}`
              filtersData.push(['Categorical', metadataName, filterDetail])
            }
          }
        }
      }
    }
    
    // Add continuous (range) filters
    if (this.selectedRanges && Object.keys(this.selectedRanges).length > 0) {
      for (const [metadataId, range] of Object.entries(this.selectedRanges)) {
        if (range && range.min !== undefined && range.max !== undefined) {
          // Check if this filter is disabled
          if (this.disabledFilters && this.disabledFilters.has(parseInt(metadataId))) {
            continue // Skip disabled filters
          }
          
          const metadataVector = this.dataManager.getMetadataVectorById(parseInt(metadataId))
          if (metadataVector) {
            const metadataName = metadataVector.name || `Metadata ${metadataId}`
            const values = metadataVector.values.filter(v => v !== null && v !== undefined && !isNaN(v))
            const globalMin = Math.min(...values)
            const globalMax = Math.max(...values)
            
            // Check if it's a subrange (not the full range)
            const isFullRange = (Math.abs(range.min - globalMin) < 0.0001 && Math.abs(range.max - globalMax) < 0.0001)
            if (!isFullRange) {
              const filterDetail = `Range: ${range.min.toFixed(4)} to ${range.max.toFixed(4)} (full range: ${globalMin.toFixed(4)} to ${globalMax.toFixed(4)})`
              filtersData.push(['Continuous', metadataName, filterDetail])
            }
          }
        }
      }
    }
    
    // Only add the sheet if there are actual filters (more than just the header row)
    if (filtersData.length > 1) {
      const ws = window.XLSX.utils.aoa_to_sheet(filtersData)
      window.XLSX.utils.book_append_sheet(wb, ws, 'Active Filters')
    }
  }
  
  // Add categorical distribution sheet to workbook
  async addCategoricalDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet) {
    // Get coloring categories (from filtered cells only)
    const coloringCategoryCounts = {}
    coloringMetadataVector.values.forEach((cat, idx) => {
      if (!filteredSet || filteredSet.has(idx)) {
        coloringCategoryCounts[cat] = (coloringCategoryCounts[cat] || 0) + 1
      }
    })
    const sortedColoringCategories = Object.keys(coloringCategoryCounts).sort((a, b) => {
      return (coloringCategoryCounts[b] || 0) - (coloringCategoryCounts[a] || 0)
    })
    
    // Create distribution data
    const distributionData = [['Category', ...sortedColoringCategories.map(cat => `${cat} (count)`), ...sortedColoringCategories.map(cat => `${cat} (%)`)]]
    
    sortedCategories.forEach(displayedCategory => {
      const row = [displayedCategory]
      
      // Find cells in this category (filtered only)
      const cellsInCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInCategory.push(i)
        }
      }
      
      // Count distribution
      const distribution = {}
      cellsInCategory.forEach(cellIndex => {
        const coloringCat = coloringMetadataVector.values[cellIndex]
        distribution[coloringCat] = (distribution[coloringCat] || 0) + 1
      })
      
      // Add counts
      sortedColoringCategories.forEach(coloringCat => {
        row.push(distribution[coloringCat] || 0)
      })
      
      // Add percentages
      sortedColoringCategories.forEach(coloringCat => {
        const count = distribution[coloringCat] || 0
        const percentage = cellsInCategory.length > 0 ? parseFloat(((count / cellsInCategory.length) * 100).toFixed(2)) : 0
        row.push(percentage)
      })
      
      distributionData.push(row)
    })
    
    const ws = window.XLSX.utils.aoa_to_sheet(distributionData)
    window.XLSX.utils.book_append_sheet(wb, ws, 'Distribution')
  }
  
  // Add continuous distribution sheet to workbook
  async addContinuousDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet) {
    // Get global min/max (from filtered cells only)
    const filteredValues = coloringMetadataVector.values.filter((v, idx) => {
      return v !== null && v !== undefined && !isNaN(v) && (!filteredSet || filteredSet.has(idx))
    })
    const globalMin = Math.min(...filteredValues)
    const globalMax = Math.max(...filteredValues)
    const numBins = 20
    const binWidth = (globalMax - globalMin) / numBins
    
    // Create bin ranges header
    const binRanges = []
    for (let i = 0; i < numBins; i++) {
      const start = globalMin + i * binWidth
      const end = globalMin + (i + 1) * binWidth
      binRanges.push(`${start.toFixed(2)}-${end.toFixed(2)}`)
    }
    
    const distributionData = [['Category', ...binRanges.map(r => `${r} (count)`), ...binRanges.map(r => `${r} (%)`)]]
    
    sortedCategories.forEach(displayedCategory => {
      const row = [displayedCategory]
      
      // Find cells in this category (filtered only)
      const cellsInCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInCategory.push(i)
        }
      }
      
      // Get values and create bins
      const values = cellsInCategory.map(idx => coloringMetadataVector.values[idx])
      const validValues = values.filter(v => v !== null && v !== undefined && !isNaN(v))
      const bins = Array(numBins).fill(0)
      
      validValues.forEach(value => {
        const binIndex = Math.min(Math.floor((value - globalMin) / binWidth), numBins - 1)
        bins[binIndex]++
      })
      
      // Add counts
      bins.forEach(count => row.push(count))
      
      // Add percentages
      bins.forEach(count => {
        const percentage = validValues.length > 0 ? parseFloat(((count / validValues.length) * 100).toFixed(2)) : 0
        row.push(percentage)
      })
      
      distributionData.push(row)
    })
    
    const ws = window.XLSX.utils.aoa_to_sheet(distributionData)
    window.XLSX.utils.book_append_sheet(wb, ws, 'Distribution')
  }
  
  // Add continuous summary statistics sheet to workbook
  async addContinuousSummarySheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet) {
    const summaryData = [['Category', 'Cell Count', 'Min', 'Max', 'Mean', 'Median', 'Q1', 'Q3', 'Std Dev']]
    
    sortedCategories.forEach(displayedCategory => {
      // Find cells in this category (filtered only)
      const cellsInCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInCategory.push(i)
        }
      }
      
      // Get values
      const values = cellsInCategory.map(idx => coloringMetadataVector.values[idx])
      const validValues = values.filter(v => v !== null && v !== undefined && !isNaN(v))
      
      if (validValues.length === 0) {
        summaryData.push([displayedCategory, 0, 0, 0, 0, 0, 0, 0, 0])
        return
      }
      
      // Calculate statistics
      const min = Math.min(...validValues)
      const max = Math.max(...validValues)
      const mean = validValues.reduce((a, b) => a + b, 0) / validValues.length
      const sortedValues = [...validValues].sort((a, b) => a - b)
      const median = sortedValues[Math.floor(sortedValues.length / 2)]
      const q1 = sortedValues[Math.floor(sortedValues.length * 0.25)]
      const q3 = sortedValues[Math.floor(sortedValues.length * 0.75)]
      const stdDev = Math.sqrt(validValues.reduce((sum, val) => sum + Math.pow(val - mean, 2), 0) / validValues.length)
      
      summaryData.push([
        displayedCategory,
        validValues.length,
        parseFloat(min.toFixed(4)),
        parseFloat(max.toFixed(4)),
        parseFloat(mean.toFixed(4)),
        parseFloat(median.toFixed(4)),
        parseFloat(q1.toFixed(4)),
        parseFloat(q3.toFixed(4)),
        parseFloat(stdDev.toFixed(4))
      ])
    })
    
    const ws = window.XLSX.utils.aoa_to_sheet(summaryData)
    window.XLSX.utils.book_append_sheet(wb, ws, 'Summary Stats')
  }
  
  */
  // All download-related methods have been moved to DownloadManager

  // Initialize resizable column dividers
  initializeResizers() {
    const leftPanel = document.getElementById('left-panel')
    const rightPanel = document.getElementById('right-panel')
    const mainPanel = document.getElementById('main-panel')
    const leftResizer = document.getElementById('left-resizer')
    const rightResizer = document.getElementById('right-resizer')
    
    if (!leftPanel || !rightPanel || !mainPanel || !leftResizer || !rightResizer) {
      console.warn('Resizer elements not found')
      return
    }
    
    let isResizingLeft = false
    let isResizingRight = false
    let startX = 0
    let startLeftWidth = 0
    let startRightWidth = 0
    
    // Left resizer
    leftResizer.addEventListener('mousedown', (e) => {
      isResizingLeft = true
      startX = e.clientX
      startLeftWidth = leftPanel.offsetWidth
      document.body.style.cursor = 'col-resize'
      document.body.style.userSelect = 'none'
      e.preventDefault()
    })
    
    // Right resizer
    rightResizer.addEventListener('mousedown', (e) => {
      isResizingRight = true
      startX = e.clientX
      startRightWidth = rightPanel.offsetWidth
      document.body.style.cursor = 'col-resize'
      document.body.style.userSelect = 'none'
      e.preventDefault()
    })
    
    // Mouse move handler
    document.addEventListener('mousemove', (e) => {
      if (isResizingLeft) {
        const deltaX = e.clientX - startX
        const newWidth = Math.max(200, Math.min(800, startLeftWidth + deltaX))
        leftPanel.style.width = `${newWidth}px`
        
        // Trigger plot redraw
        if (this.reglRenderer) {
          requestAnimationFrame(() => {
            this.redrawPlot()
          })
        }
      } else if (isResizingRight) {
        const deltaX = e.clientX - startX
        const newWidth = Math.max(200, Math.min(800, startRightWidth - deltaX))
        rightPanel.style.width = `${newWidth}px`
        
        // Trigger plot redraw
        if (this.reglRenderer) {
          requestAnimationFrame(() => {
            this.redrawPlot()
          })
        }
      }
    })
    
    // Mouse up handler
    document.addEventListener('mouseup', () => {
      if (isResizingLeft || isResizingRight) {
        isResizingLeft = false
        isResizingRight = false
        document.body.style.cursor = ''
        document.body.style.userSelect = ''
        
        // Final resize update
        if (this.reglRenderer) {
          setTimeout(() => {
            this.redrawPlot()
            // Refresh histograms and barplots when column resizing ends
            // (bins/bar widths depend on the size of the plot)
            this.refreshHistogramsAndBarplots()
          }, 100)
        } else {
          // Even if there's no reglRenderer, we should refresh histograms and barplots
          this.refreshHistogramsAndBarplots()
        }
      }
    })
  }

  // Refresh all histograms and barplots (useful when column size changes)
  refreshHistogramsAndBarplots() {
    // Use requestAnimationFrame to ensure the browser has updated the layout
    // before we try to read canvas dimensions
    requestAnimationFrame(() => {
      // Refresh all histograms (from range slider controllers)
      const rangeSliderElements = document.querySelectorAll('[data-controller~="range-slider"]')
      rangeSliderElements.forEach(element => {
        const controller = this.application?.getControllerForElementAndIdentifier(element, 'range-slider')
        if (controller && typeof controller.drawDensityPlot === 'function') {
          controller.drawDensityPlot()
        }
      })
      
      // Refresh all barplots (category distributions)
      if (this.dataManager && typeof this.dataManager.updateAllCategoryDistributions === 'function') {
        this.dataManager.updateAllCategoryDistributions()
      }
    })
  }

  // Update adapt color range button visibility for all range sliders
  updateAllRangeSliderButtonAppearances() {
    // Find all range slider controllers and trigger their button appearance updates
    const rangeSliderElements = document.querySelectorAll('[data-controller~="range-slider"]')
    rangeSliderElements.forEach(element => {
      // Get the Stimulus controller instance
      const controller = this.application?.getControllerForElementAndIdentifier(element, 'range-slider')
      if (controller && typeof controller.updateButtonAppearance === 'function') {
        controller.updateButtonAppearance()
      }
    })
  }

}