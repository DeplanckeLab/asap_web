export class PerformanceManager {
  constructor(controller) {
    this.controller = controller
  }

  // Record performance metrics for operations
  recordPerformanceMetrics(operationName, duration) {
    this.controller.performanceMetrics.updateCount++
    this.controller.performanceMetrics.lastUpdateTime = duration
    this.controller.performanceMetrics.maxUpdateTime = Math.max(this.controller.performanceMetrics.maxUpdateTime, duration)
    
    console.log(`📊 [PERF] ${operationName}: ${duration.toFixed(2)}ms (Total updates: ${this.controller.performanceMetrics.updateCount})`)
  }

  // Assess performance after preloading
  async assessPerformanceAfterPreload() {
    console.log(`\n🔍 [PERF] Assessing performance after preloading...`)
    
    // Memory usage analysis
    const memoryInfo = this.controller.memoryManager.logMemoryUsage('Performance Assessment')
    
    // Count loaded metadata vectors and estimate memory usage
    const loadedMetadataCount = Object.keys(this.controller.loadedMetadataVectors).length
    const loadingCount = this.controller.loadingMetadataVectors.size
    
    console.log(`📊 [PERF] Loaded metadata vectors: ${loadedMetadataCount}`)
    console.log(`📊 [PERF] Currently loading: ${loadingCount}`)
    
    // Estimate total memory usage
    let totalEstimatedMemory = 0
    Object.values(this.controller.loadedMetadataVectors).forEach(vector => {
      if (vector.values) {
        // Estimate memory usage: 4 bytes per float + overhead
        const estimatedSize = vector.values.length * 4 / 1024 / 1024 // MB
        totalEstimatedMemory += estimatedSize
      }
    })
    
    console.log(`📊 [PERF] Estimated metadata memory usage: ${totalEstimatedMemory.toFixed(2)}MB`)
    
    // Performance recommendations
    if (loadedMetadataCount > 10) {
      console.log(`⚠️ [PERF] High metadata count (${loadedMetadataCount}) - consider enabling auto-cleanup`)
    }
    
    if (totalEstimatedMemory > 100) {
      console.log(`⚠️ [PERF] High memory usage (${totalEstimatedMemory.toFixed(2)}MB) - consider reducing buffer size`)
    }
    
    // Check if memory optimization is needed
    if (loadedMetadataCount > this.controller.maxMetadataInMemory || totalEstimatedMemory > 200) {
      console.log(`🔧 [PERF] Triggering memory optimization...`)
      this.controller.memoryManager.optimizeMemoryUsage()
    }
    
    return {
      loadedMetadataCount,
      totalEstimatedMemory,
      memoryInfo
    }
  }

  // Run emergency diagnostic
  runEmergencyDiagnostic() {
    console.log(`🚨 [EMERGENCY DIAGNOSTIC] Starting...`)
    
    console.log(`🔍 Loading call counts:`, this.controller.loadingCallCount ? Object.fromEntries(this.controller.loadingCallCount) : 'None')
    console.log(`🔍 Current metadata ID:`, this.controller.currentMetadataId)
    console.log(`🔍 Current coordinates length:`, this.controller.currentCoordinates?.length || 0)
    console.log(`🔍 Current visible cells:`, this.controller.currentVisibleCells?.length || 0)
    console.log(`🔍 Selected cells:`, this.controller.selectedCells?.size || 0)
    console.log(`🔍 Loaded metadata vectors:`, Object.keys(this.controller.loadedMetadataVectors))
    console.log(`🔍 Currently loading:`, Array.from(this.controller.loadingMetadataVectors))
    
    // Check renderer state
    console.log(`🔍 Renderer type:`, this.controller.rendererType)
    console.log(`🔍 ReGL renderer:`, !!this.controller.reglRenderer)
    console.log(`🔍 PIXI app:`, !!this.controller.pixiApp)
    
    // Check canvas state
    const canvas = document.querySelector('canvas')
    if (canvas) {
      console.log(`🔍 Canvas dimensions:`, canvas.width, 'x', canvas.height)
      console.log(`🔍 Canvas style:`, canvas.style.cssText)
    } else {
      console.log(`❌ Canvas not found!`)
    }
    
    // Check plot container
    const plotContainer = document.querySelector('.plot-container')
    if (plotContainer) {
      console.log(`🔍 Plot container found:`, plotContainer.className)
      console.log(`🔍 Plot container dimensions:`, plotContainer.offsetWidth, 'x', plotContainer.offsetHeight)
    } else {
      console.log(`❌ Plot container not found!`)
    }
    
    // Memory check
    this.controller.memoryManager.logMemoryUsage('Emergency Diagnostic')
    
    console.log(`🚨 [EMERGENCY DIAGNOSTIC] Complete`)
  }

  // Create diagnostic button for troubleshooting
  createDiagnosticButton() {
    console.log('🔍 [DIAGNOSTIC] Creating diagnostic button...')
    
    // Hide the diagnostic button - return early without creating it
    return
    
    // Check if button already exists
    let diagnosticBtn = document.getElementById('emergency-diagnostic-btn')
    if (diagnosticBtn) {
      console.log('🔍 [DIAGNOSTIC] Button already exists, removing old one')
      diagnosticBtn.remove()
    }
    
    // Create new diagnostic button
    diagnosticBtn = document.createElement('button')
    diagnosticBtn.id = 'emergency-diagnostic-btn'
    diagnosticBtn.textContent = '🚨 Emergency Diagnostic'
    diagnosticBtn.style.cssText = `
      position: fixed;
      top: 10px;
      right: 10px;
      z-index: 10000;
      background: #dc2626;
      color: white;
      border: none;
      padding: 8px 12px;
      border-radius: 4px;
      font-size: 12px;
      cursor: pointer;
      box-shadow: 0 2px 4px rgba(0,0,0,0.3);
    `
    
    diagnosticBtn.addEventListener('click', () => {
      this.runEmergencyDiagnostic()
    })
    
    document.body.appendChild(diagnosticBtn)
    console.log('🔍 [DIAGNOSTIC] Emergency diagnostic button created')
    
    // Auto-hide after 30 seconds
    setTimeout(() => {
      if (diagnosticBtn && diagnosticBtn.parentNode) {
        diagnosticBtn.remove()
        console.log('🔍 [DIAGNOSTIC] Button auto-hidden after 30 seconds')
      }
    }, 30000)
    
    console.log('🔍 [DIAGNOSTIC] You can also call window.showDiagnosticButton() to manually show the button')
  }

  // Show diagnostic button manually
  showDiagnosticButton() {
    this.createDiagnosticButton()
  }

  // Run emergency diagnostic
  runEmergencyDiagnostic() {
    console.log(`🚨 [EMERGENCY DIAGNOSTIC] Starting...`)
    
    console.log(`🔍 Loading call counts:`, this.controller.loadingCallCount ? Object.fromEntries(this.controller.loadingCallCount) : 'None')
    console.log(`🔍 Currently loading:`, Array.from(this.controller.loadingMetadataVectors))
    console.log(`🔍 Loaded in memory:`, Object.keys(this.controller.loadedMetadataVectors))
    
    // Check for problematic metadata
    if (this.controller.loadingCallCount) {
      const problematicMetadata = Array.from(this.controller.loadingCallCount.entries())
        .filter(([id, count]) => count > 3)
        .map(([id, count]) => `${id} (${count} calls)`)
      
      if (problematicMetadata.length > 0) {
        console.error(`🚨 PROBLEMATIC METADATA:`, problematicMetadata)
      }
    }
    
    console.log(`🚨 [EMERGENCY DIAGNOSTIC] Complete`)
  }

  // Open memory diagnostic window
  async openMemoryDiagnostic() {
    // Remove existing diagnostic window if it exists
    const existingWindow = document.getElementById('memory-diagnostic-window')
    if (existingWindow) {
      existingWindow.remove()
    }

    // Create diagnostic window
    const diagnosticWindow = document.createElement('div')
    diagnosticWindow.id = 'memory-diagnostic-window'
    diagnosticWindow.style.cssText = `
      position: fixed;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      width: 600px;
      max-height: 80vh;
      background: white;
      border: 2px solid #3b82f6;
      border-radius: 8px;
      box-shadow: 0 10px 25px rgba(0, 0, 0, 0.3);
      z-index: 10000;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      overflow-y: auto;
    `

    // Get diagnostic data (async)
    const diagnosticData = await this.gatherMemoryDiagnosticData()

    // Create window content
    diagnosticWindow.innerHTML = `
      <div style="padding: 20px; border-bottom: 1px solid #e5e7eb;">
        <div style="display: flex; justify-content: space-between; align-items: center;">
          <h3 style="margin: 0; color: #1f2937; font-size: 18px;">🧠 Memory & Database Diagnostic</h3>
          <button id="close-diagnostic-window" style="
            background: #ef4444;
            color: white;
            border: none;
            border-radius: 4px;
            padding: 6px 12px;
            cursor: pointer;
            font-size: 12px;
          ">✕ Close</button>
        </div>
      </div>
      
      <div style="padding: 20px;">
        <div style="margin-bottom: 20px;">
          <h4 style="margin: 0 0 10px 0; color: #374151; font-size: 16px;">📊 Memory Status</h4>
          <div style="background: #f9fafb; padding: 15px; border-radius: 6px; border-left: 4px solid #3b82f6;">
            <div style="margin-bottom: 8px;"><strong>Total in Memory:</strong> ${diagnosticData.memoryCount} items (${diagnosticData.metadataCount} metadata + ${diagnosticData.embeddingCount} embeddings)</div>
            <div style="margin-bottom: 8px;"><strong>Metadata Buffer:</strong> ${diagnosticData.metadataCount}/${diagnosticData.maxMetadataInMemory} (${diagnosticData.memoryUsage}% full)</div>
            <div style="margin-bottom: 8px;"><strong>Currently Loading:</strong> ${diagnosticData.loadingCount}</div>
            <div><strong>Available Embeddings:</strong> ${diagnosticData.totalEmbeddingsAvailable}</div>
          </div>
        </div>

        <div style="margin-bottom: 20px;">
          <h4 style="margin: 0 0 10px 0; color: #374151; font-size: 16px;">🗄️ Database Storage</h4>
          <div style="background: #f9fafb; padding: 15px; border-radius: 6px; border-left: 4px solid #10b981;">
            <div style="margin-bottom: 8px;"><strong>IndexedDB Available:</strong> ${diagnosticData.indexedDBAvailable ? '✅ Yes' : '❌ No'}</div>
            <div style="margin-bottom: 8px;"><strong>Stored in DB:</strong> ${diagnosticData.dbCount} items</div>
            <div style="margin-bottom: 8px;"><strong>DB Storage Size:</strong> ${diagnosticData.dbSize}</div>
            <div style="margin-bottom: 8px;"><strong>Current Loom File:</strong> ${diagnosticData.currentLoomFile || 'Unknown'}</div>
            <div><strong>DB Items with Matching Loom:</strong> ${diagnosticData.matchingLoomCount} items</div>
          </div>
        </div>

        <div style="margin-bottom: 20px;">
          <h4 style="margin: 0 0 10px 0; color: #374151; font-size: 16px;">📈 Metadata Breakdown</h4>
          <div style="background: #f9fafb; padding: 15px; border-radius: 6px; border-left: 4px solid #8b5cf6;">
            <div style="margin-bottom: 8px;"><strong>Continuous (Numeric):</strong> ${diagnosticData.continuousCount} in memory, ${diagnosticData.continuousDBCount} in DB</div>
            <div style="margin-bottom: 8px;"><strong>Categorical (Discrete):</strong> ${diagnosticData.categoricalCount} in memory, ${diagnosticData.categoricalDBCount} in DB</div>
            <div style="margin-bottom: 8px;"><strong>Currently Active Metadata:</strong> ${diagnosticData.currentMetadataLoaded ? '1' : '0'} loaded</div>
            <div style="margin-bottom: 8px;"><strong>Embeddings (Coordinates):</strong> ${diagnosticData.embeddingCount} cached, ${diagnosticData.currentEmbeddingLoaded ? '1' : '0'} currently loaded (${diagnosticData.totalEmbeddingsAvailable} available)</div>
          </div>
        </div>

        <div style="margin-bottom: 20px;">
          <h4 style="margin: 0 0 10px 0; color: #374151; font-size: 16px;">🔍 Debug Info</h4>
          <div style="background: #f9fafb; padding: 15px; border-radius: 6px; border-left: 4px solid #f59e0b; font-family: monospace; font-size: 11px;">
            <div style="margin-bottom: 4px;"><strong>binaryDataCache exists:</strong> ${diagnosticData.debugInfo?.hasBinaryDataCache || 'unknown'}</div>
            <div style="margin-bottom: 4px;"><strong>binaryDataCache size:</strong> ${diagnosticData.debugInfo?.binaryDataCacheSize || 'unknown'}</div>
            <div style="margin-bottom: 4px;"><strong>binaryDataCache keys:</strong> ${diagnosticData.debugInfo?.binaryDataCacheKeys || 'none'}</div>
            <div style="margin-bottom: 4px;"><strong>metadataData exists:</strong> ${diagnosticData.debugInfo?.hasMetadataData || 'unknown'}</div>
            <div style="margin-bottom: 4px;"><strong>metadataData name:</strong> ${diagnosticData.debugInfo?.metadataDataName || 'none'}</div>
            <div style="margin-bottom: 4px;"><strong>loadedMetadataVectors keys:</strong> ${diagnosticData.debugInfo?.loadedMetadataVectorsKeys || 'none'}</div>
            <div style="margin-bottom: 4px;"><strong>embeddingsByLoomValue keys:</strong> ${diagnosticData.debugInfo?.embeddingsByLoomValueKeys || 'none'}</div>
          </div>
        </div>

        <div style="margin-bottom: 20px;">
          <h4 style="margin: 0 0 10px 0; color: #374151; font-size: 16px;">⚡ Performance</h4>
          <div style="background: #f9fafb; padding: 15px; border-radius: 6px; border-left: 4px solid #f59e0b;">
            <div style="margin-bottom: 8px;"><strong>Update Count:</strong> ${diagnosticData.updateCount}</div>
            <div style="margin-bottom: 8px;"><strong>Last Update Time:</strong> ${diagnosticData.lastUpdateTime}ms</div>
            <div style="margin-bottom: 8px;"><strong>Max Update Time:</strong> ${diagnosticData.maxUpdateTime}ms</div>
            <div><strong>Average Update Time:</strong> ${diagnosticData.avgUpdateTime}ms</div>
          </div>
        </div>

        <div>
          <h4 style="margin: 0 0 10px 0; color: #374151; font-size: 16px;">🔧 Actions</h4>
          <div style="display: flex; gap: 10px;">
            <button id="clear-memory-cache" style="
              background: #ef4444;
              color: white;
              border: none;
              border-radius: 4px;
              padding: 8px 16px;
              cursor: pointer;
              font-size: 12px;
            ">Clear Memory Cache</button>
            <button id="clear-db-cache" style="
              background: #f59e0b;
              color: white;
              border: none;
              border-radius: 4px;
              padding: 8px 16px;
              cursor: pointer;
              font-size: 12px;
            ">Clear DB Cache</button>
            <button id="refresh-diagnostic" style="
              background: #3b82f6;
              color: white;
              border: none;
              border-radius: 4px;
              padding: 8px 16px;
              cursor: pointer;
              font-size: 12px;
            ">Refresh</button>
            <button id="list-db-items" style="
              background: #8b5cf6;
              color: white;
              border: none;
              border-radius: 4px;
              padding: 8px 16px;
              cursor: pointer;
              font-size: 12px;
            ">List DB Items</button>
            <button id="inspect-memory" style="
              background: #10b981;
              color: white;
              border: none;
              border-radius: 4px;
              padding: 8px 16px;
              cursor: pointer;
              font-size: 12px;
            ">Inspect Memory (Console)</button>
          </div>
        </div>
      </div>
    `

    // Add backdrop first
    const backdrop = document.createElement('div')
    backdrop.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background: rgba(0, 0, 0, 0.5);
      z-index: 9999;
    `
    backdrop.addEventListener('click', () => {
      diagnosticWindow.remove()
      backdrop.remove()
    })
    document.body.appendChild(backdrop)

    // Add diagnostic window to page
    document.body.appendChild(diagnosticWindow)

    // Add event listeners after DOM is updated
    setTimeout(() => {
      const closeBtn = document.getElementById('close-diagnostic-window')
      const clearMemoryBtn = document.getElementById('clear-memory-cache')
      const clearDBBtn = document.getElementById('clear-db-cache')
      const refreshBtn = document.getElementById('refresh-diagnostic')

      if (closeBtn) {
        closeBtn.addEventListener('click', () => {
          diagnosticWindow.remove()
          backdrop.remove()
        })
      }

      if (clearMemoryBtn) {
        clearMemoryBtn.addEventListener('click', async () => {
          this.clearMemoryCache()
          await this.openMemoryDiagnostic() // Refresh the window
        })
      }

      if (clearDBBtn) {
        clearDBBtn.addEventListener('click', async () => {
          this.clearDBCache()
          await this.openMemoryDiagnostic() // Refresh the window
        })
      }

      if (refreshBtn) {
        refreshBtn.addEventListener('click', async () => {
          await this.openMemoryDiagnostic() // Refresh the window
        })
      }

      const listDBBtn = document.getElementById('list-db-items')
      if (listDBBtn) {
        listDBBtn.addEventListener('click', async () => {
          await this.listDatabaseItems()
        })
      }

      const inspectMemoryBtn = document.getElementById('inspect-memory')
      if (inspectMemoryBtn) {
        inspectMemoryBtn.addEventListener('click', () => {
          console.log('🔍 [MANUAL INSPECT] Inspecting memory directly...')
          console.log('🔍 [MANUAL INSPECT] controller:', this.controller)
          console.log('🔍 [MANUAL INSPECT] controller.instanceId:', this.controller.instanceId)
          console.log('🔍 [MANUAL INSPECT] controller.identifier:', this.controller.identifier)
          console.log('🔍 [MANUAL INSPECT] controller.element:', this.controller.element)
          console.log('🔍 [MANUAL INSPECT] typeof loadedMetadataVectors:', typeof this.controller.loadedMetadataVectors)
          console.log('🔍 [MANUAL INSPECT] loadedMetadataVectors is null?:', this.controller.loadedMetadataVectors === null)
          console.log('🔍 [MANUAL INSPECT] loadedMetadataVectors is undefined?:', this.controller.loadedMetadataVectors === undefined)
          console.log('🔍 [MANUAL INSPECT] loadedMetadataVectors:', this.controller.loadedMetadataVectors)
          console.log('🔍 [MANUAL INSPECT] loadedMetadataVectors keys:', Object.keys(this.controller.loadedMetadataVectors || {}))
          console.log('🔍 [MANUAL INSPECT] binaryDataCache:', this.controller.binaryDataCache)
          console.log('🔍 [MANUAL INSPECT] binaryDataCache.size:', this.controller.binaryDataCache?.size)
          console.log('🔍 [MANUAL INSPECT] metadataData:', this.controller.metadataData)
          console.log('🔍 [MANUAL INSPECT] currentMetadataVector:', this.controller.currentMetadataVector)
          console.log('🔍 [MANUAL INSPECT] currentMetadataId:', this.controller.currentMetadataId)
          console.log('🔍 [MANUAL INSPECT] embeddingsByLoomValue:', this.controller.embeddingsByLoomValue)
          console.log('🔍 [MANUAL INSPECT] Coloring metadata vector:', this.controller.colorManager?.getColoringMetadataVector())
          alert('Check browser console (F12) for detailed memory inspection')
        })
      }
    }, 10)
  }

  // Gather diagnostic data
  async gatherMemoryDiagnosticData() {
    console.log('🔍 [DIAGNOSTIC] Gathering memory diagnostic data...')
    
    // Debug: Log all relevant controller properties
    // Try to get size safely
    let binaryDataCacheSize = 'unknown'
    let binaryDataCacheKeys = []
    try {
      if (this.controller.binaryDataCache) {
        console.log('🔍 [DIAGNOSTIC] binaryDataCache details:', {
          constructor: this.controller.binaryDataCache.constructor.name,
          hasSize: 'size' in this.controller.binaryDataCache,
          size: this.controller.binaryDataCache.size,
          sizeType: typeof this.controller.binaryDataCache.size
        })
        binaryDataCacheSize = this.controller.binaryDataCache.size
        binaryDataCacheKeys = Array.from(this.controller.binaryDataCache.keys())
      } else {
        console.log('🔍 [DIAGNOSTIC] binaryDataCache is falsy:', this.controller.binaryDataCache)
      }
    } catch (e) {
      console.error('Error accessing binaryDataCache:', e)
    }
    
    // Also check metadataData safely
    let hasMetadataData = 'unknown'
    let metadataDataName = 'none'
    try {
      hasMetadataData = !!this.controller.metadataData
      if (this.controller.metadataData) {
        metadataDataName = this.controller.metadataData.name || 'no name'
      }
      console.log('🔍 [DIAGNOSTIC] metadataData details:', {
        exists: !!this.controller.metadataData,
        name: metadataDataName
      })
    } catch (e) {
      console.error('Error accessing metadataData:', e)
    }
    
    console.log('🔍 [DIAGNOSTIC] Controller properties:', {
      hasLoadedMetadataVectors: !!this.controller.loadedMetadataVectors,
      loadedMetadataVectorsKeys: Object.keys(this.controller.loadedMetadataVectors || {}),
      hasBinaryDataCache: !!this.controller.binaryDataCache,
      binaryDataCacheType: typeof this.controller.binaryDataCache,
      binaryDataCacheConstructor: this.controller.binaryDataCache ? this.controller.binaryDataCache.constructor.name : 'N/A',
      binaryDataCacheSize: binaryDataCacheSize,
      binaryDataCacheKeys: binaryDataCacheKeys,
      hasEmbeddingsByLoomValue: !!this.controller.embeddingsByLoomValue,
      embeddingsByLoomValueKeys: this.controller.embeddingsByLoomValue ? Object.keys(this.controller.embeddingsByLoomValue) : [],
      hasLoadingMetadataVectors: !!this.controller.loadingMetadataVectors,
      loadingMetadataVectorsSize: this.controller.loadingMetadataVectors ? this.controller.loadingMetadataVectors.size : 0
    })
    
    console.log('🔍 [DIAGNOSTIC] About to calculate counts...')
    console.log('🔍 [DIAGNOSTIC] this.controller:', this.controller)
    console.log('🔍 [DIAGNOSTIC] this.controller.loadedMetadataVectors:', this.controller.loadedMetadataVectors)
    console.log('🔍 [DIAGNOSTIC] typeof loadedMetadataVectors:', typeof this.controller.loadedMetadataVectors)
    console.log('🔍 [DIAGNOSTIC] Object.keys(loadedMetadataVectors):', Object.keys(this.controller.loadedMetadataVectors || {}))
    
    const metadataCount = Object.keys(this.controller.loadedMetadataVectors || {}).length
    console.log('🔍 [DIAGNOSTIC] Calculated metadataCount:', metadataCount)
    
    const embeddingCount = typeof binaryDataCacheSize === 'number' ? binaryDataCacheSize : 0
    const currentEmbeddingLoaded = !!this.controller.metadataData // Check if currently loaded embedding exists
    const currentMetadataLoaded = !!this.controller.currentMetadataVector // Check if currently loaded metadata exists
    const memoryCount = metadataCount + embeddingCount + (currentMetadataLoaded ? 1 : 0) // Total items in memory
    const loadingCount = this.controller.loadingMetadataVectors ? this.controller.loadingMetadataVectors.size : 0
    
    console.log('🔍 [DIAGNOSTIC] Final counts:', { metadataCount, embeddingCount, currentMetadataLoaded, memoryCount })
    const maxMemory = this.controller.maxMetadataInMemory || 10
    const memoryUsage = Math.round((metadataCount / maxMemory) * 100)
    
    console.log('🔍 [DIAGNOSTIC] Counts:', { metadataCount, embeddingCount, memoryCount, loadingCount, currentEmbeddingLoaded })

    // Count metadata types
    let continuousCount = 0
    let categoricalCount = 0
    let continuousDBCount = 0
    let categoricalDBCount = 0

    Object.values(this.controller.loadedMetadataVectors || {}).forEach(metadata => {
      if (metadata.data_type === 'NUMERIC') continuousCount++
      else if (metadata.data_type === 'DISCRETE') categoricalCount++
    })

    // Get total available embedding count (different from cached embeddings)
    const totalEmbeddingsAvailable = this.controller.embeddingsByLoomValue ? 
      Object.values(this.controller.embeddingsByLoomValue).reduce((total, embeddings) => total + embeddings.length, 0) : 0

    // Get performance metrics
    const updateCount = this.controller.performanceMetrics?.updateCount || 0
    const lastUpdateTime = this.controller.performanceMetrics?.lastUpdateTime || 0
    const maxUpdateTime = this.controller.performanceMetrics?.maxUpdateTime || 0
    const avgUpdateTime = this.controller.performanceMetrics?.avgUpdateTime || 0

    // Query IndexedDB for actual counts
    let dbCount = 0
    let dbSize = 'Unknown'
    let continuousDBCountActual = 0
    let categoricalDBCountActual = 0
    let matchingLoomCount = 0
    let currentLoomFile = 'Unknown'

    if (this.controller.db) {
      try {
        // Get current loom file - use more robust method
        console.log('🔍 [DEBUG] Diagnostic loom file detection:', {
          currentLoomFile: this.controller.currentLoomFile,
          defaultLoomFileValue: this.controller.defaultLoomFileValue
        })
        
        // If currentLoomFile is not set, try to get it from the same logic as connect method
        if (!this.controller.currentLoomFile) {
          console.log('🔍 [DEBUG] currentLoomFile not set, using fallback logic')
          const fallbackLoomFile = this.controller.defaultLoomFileValue || 'parsing/output.loom'
          console.log('🔍 [DEBUG] Using fallback loom file:', fallbackLoomFile)
          currentLoomFile = fallbackLoomFile
        } else {
          currentLoomFile = this.controller.currentLoomFile
        }
        
        // Note: We avoid accessing loomFileSelectTarget directly to prevent Stimulus errors
        // The currentLoomFile should already be set correctly by the controller's connect method
        
        console.log('🔍 [DEBUG] Final diagnostic loom file:', currentLoomFile)
        
        // First, try to count items
        try {
          const transaction = this.controller.db.transaction(['metadata'], 'readonly')
          const objectStore = transaction.objectStore('metadata')
          const countRequest = objectStore.count()
          
          await new Promise((resolve, reject) => {
            countRequest.onsuccess = () => {
              dbCount = countRequest.result
              console.log(`📊 Database count: ${dbCount} items`)
              resolve()
            }
            countRequest.onerror = () => {
              console.error('Error counting IndexedDB items:', countRequest.error)
              dbCount = 0 // Set to 0 instead of error
              resolve() // Don't reject, just continue
            }
          })
        } catch (countError) {
          console.error('Error in count transaction:', countError)
          dbCount = 0
        }

        // Then, try to get all items for detailed analysis
        try {
          const transaction = this.controller.db.transaction(['metadata'], 'readonly')
          const objectStore = transaction.objectStore('metadata')
          const getAllRequest = objectStore.getAll()
          
          await new Promise((resolve, reject) => {
            getAllRequest.onsuccess = () => {
              const allItems = getAllRequest.result || []
              console.log(`📊 Retrieved ${allItems.length} items from database`)
              
              allItems.forEach(item => {
                if (item.data_type === 'NUMERIC') {
                  continuousDBCountActual++
                } else if (item.data_type === 'DISCRETE') {
                  categoricalDBCountActual++
                }
                
                // Check if loom file matches
                if (item.loomFile === currentLoomFile) {
                  matchingLoomCount++
                }
              })
              
              console.log(`📊 Matching loom items: ${matchingLoomCount}/${allItems.length}`)
              resolve()
            }
            getAllRequest.onerror = () => {
              console.error('Error getting IndexedDB items:', getAllRequest.error)
              resolve() // Don't reject, just continue
            }
          })
        } catch (getAllError) {
          console.error('Error in getAll transaction:', getAllError)
        }

        // Calculate approximate size (separate try-catch)
        try {
          const sizeRequest = navigator.storage && navigator.storage.estimate ? navigator.storage.estimate() : null
          if (sizeRequest) {
            const estimate = await sizeRequest
            dbSize = `${Math.round(estimate.usage / 1024 / 1024)} MB used / ${Math.round(estimate.quota / 1024 / 1024)} MB available`
          } else {
            dbSize = 'Storage API not available'
          }
        } catch (sizeError) {
          console.error('Error calculating storage size:', sizeError)
          dbSize = 'Unable to calculate'
        }
      } catch (error) {
        console.error('Error in database query:', error)
        // Don't set to 'Error', just use default values
        dbCount = 0
        dbSize = 'Query failed'
      }
    }

    return {
      memoryCount,
      metadataCount,
      embeddingCount,
      currentEmbeddingLoaded,
      currentMetadataLoaded,
      loadingCount,
      maxMemory,
      maxMetadataInMemory: maxMemory,
      memoryUsage,
      continuousCount,
      categoricalCount,
      continuousDBCount: continuousDBCountActual,
      categoricalDBCount: categoricalDBCountActual,
      totalEmbeddingsAvailable,
      updateCount,
      lastUpdateTime,
      maxUpdateTime,
      avgUpdateTime,
      indexedDBAvailable: !!this.controller.db,
      dbCount,
      dbSize,
      currentLoomFile,
      matchingLoomCount,
      debugInfo: {
        hasBinaryDataCache: !!this.controller.binaryDataCache,
        binaryDataCacheSize: binaryDataCacheSize,
        binaryDataCacheKeys: binaryDataCacheKeys.join(', ') || 'none',
        loadedMetadataVectorsKeys: Object.keys(this.controller.loadedMetadataVectors || {}).join(', ') || 'none',
        embeddingsByLoomValueKeys: this.controller.embeddingsByLoomValue ? Object.keys(this.controller.embeddingsByLoomValue).join(', ') || 'none' : 'none',
        hasMetadataData: hasMetadataData,
        metadataDataName: metadataDataName
      }
    }
  }

  // Clear memory cache
  clearMemoryCache() {
    console.log('🚨 [DEBUG] clearMemoryCache() called - clearing all memory!')
    console.trace('Call stack:')
    this.controller.loadedMetadataVectors = {}
    this.controller.binaryDataCache.clear()
    this.controller.metadataUsageTracker = {}
    console.log('Memory cache cleared')
  }

  // Clear database cache
  clearDBCache() {
    if (this.controller.memoryManager) {
      this.controller.memoryManager.clearIndexedDBCache()
    }
    console.log('Database cache cleared')
  }

  // List all items in the database
  async listDatabaseItems() {
    console.log('🔍 [DEBUG] Starting database listing...')
    console.log('🔍 [DEBUG] Controller db:', !!this.controller.db)
    console.log('🔍 [DEBUG] Controller:', this.controller)
    
    if (!this.controller.db) {
      console.log('❌ IndexedDB not available')
      return
    }

    try {
      console.log('🔍 [DEBUG] Creating transaction...')
      const transaction = this.controller.db.transaction(['metadata'], 'readonly')
      const objectStore = transaction.objectStore('metadata')
      
      console.log('🔍 [DEBUG] Object store created, getting all items...')
      const getAllRequest = objectStore.getAll()
      
      await new Promise((resolve, reject) => {
        getAllRequest.onsuccess = () => {
          console.log('🔍 [DEBUG] getAll request successful')
          const allItems = getAllRequest.result
          // If currentLoomFile is not set, try to get it from the same logic as connect method
          let currentLoom = 'Unknown'
          if (!this.controller.currentLoomFile) {
            console.log('🔍 [DEBUG] currentLoomFile not set in database listing, using fallback logic')
            const fallbackLoomFile = this.controller.defaultLoomFileValue || 'parsing/output.loom'
            console.log('🔍 [DEBUG] Using fallback loom file for database listing:', fallbackLoomFile)
            currentLoom = fallbackLoomFile
          } else {
            currentLoom = this.controller.currentLoomFile
          }
          
          // Note: We avoid accessing loomFileSelectTarget directly to prevent Stimulus errors
          // The currentLoom should already be set correctly by the fallback logic above
          
          console.log(`\n🗄️ [DATABASE LIST] Found ${allItems.length} items in IndexedDB:`)
          console.log(`📁 Current Loom File: ${currentLoom}`)
          console.log('=' * 80)
          
          if (allItems.length === 0) {
            console.log('📭 No items found in database')
          } else {
            allItems.forEach((item, index) => {
              const isMatching = item.loomFile === currentLoom
              const status = isMatching ? '✅ MATCH' : '❌ MISMATCH'
              console.log(`${index + 1}. ${item.name || 'Unknown'} (ID: ${item.id})`)
              console.log(`   Type: ${item.data_type || 'Unknown'}`)
              console.log(`   Loom: ${item.loomFile || 'Unknown'} ${status}`)
              console.log(`   Timestamp: ${new Date(item.timestamp || 0).toLocaleString()}`)
              console.log('')
            })
            
            const matchingItems = allItems.filter(item => item.loomFile === currentLoom)
            console.log(`📊 Summary: ${matchingItems.length}/${allItems.length} items match current loom file`)
          }
          
          resolve()
        }
        getAllRequest.onerror = () => {
          console.error('❌ Error listing database items:', getAllRequest.error)
          console.error('❌ Error details:', {
            name: getAllRequest.error?.name,
            message: getAllRequest.error?.message,
            code: getAllRequest.error?.code
          })
          reject(getAllRequest.error)
        }
      })
    } catch (error) {
      console.error('❌ Error in listDatabaseItems:', error)
      console.error('❌ Error stack:', error.stack)
    }
  }
}
