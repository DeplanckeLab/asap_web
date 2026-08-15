/**
 * Data Manager Module
 * Handles data loading, decompression, and metadata management
 */

export class DataManager {
  constructor(controller) {
    this.controller = controller
  }

  perfLog(eventName, payload = {}, options = {}) {
    if (typeof this.controller.perfLog === 'function') {
      this.controller.perfLog(eventName, payload, options)
    }
  }

  bumpMemoryLoadCounter(metadataId, source) {
    const root = (window.__vizMemoryLoads && typeof window.__vizMemoryLoads === 'object')
      ? window.__vizMemoryLoads
      : {
          total: 0,
          disk: 0,
          network: 0,
          byMetadataId: {},
          lastLoadedMetadataId: null,
          lastSource: null,
          lastLoadedAt: null
        }
    window.__vizMemoryLoads = root

    root.total += 1
    if (source === 'disk') {
      root.disk += 1
    } else if (source === 'network') {
      root.network += 1
    }
    const key = String(metadataId)
    root.byMetadataId[key] = Number(root.byMetadataId[key] || 0) + 1
    root.lastLoadedMetadataId = key
    root.lastSource = source
    root.lastLoadedAt = new Date().toISOString()
  }

  // Data decompression methods
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
        // console.log(`Coordinate ${i + 1}: [${int16View[idx]}, ${int16View[idx + 1]}] -> [${x}, ${y}]`) */
      }
    }
    
    const decompressTime = performance.now() - decompressStart
    const pairsPerSec = Math.round(numPairs / decompressTime * 1000)
    
    this.perfLog('decompress_binary_coordinates', {
      pairs: numPairs,
      durationMs: Number(decompressTime.toFixed(2)),
      pairsPerSecond: pairsPerSec,
      xMin,
      xMax,
      yMin,
      yMax
    }, { cellCount: numPairs })
    
    return coordinates
  }



  // Metadata management
  getLoadedMetadataVector(metadataId) {
    return this.controller.getLoadedMetadataVector(metadataId)
  }


  // Data storage and caching
  clearMetadataData() {
    return this.controller.clearMetadataData()
  }

  // Memory management
  calculateOptimalBufferSize() {
    return this.controller.memoryManager.calculateOptimalBufferSize()
  }

  updateMetadataUsage(metadataId) {
    return this.controller.memoryManager.updateMetadataUsage(metadataId)
  }

  getLeastRecentlyUsedMetadata(limit = 1) {
    return this.controller.memoryManager.getLeastRecentlyUsedMetadata(limit)
  }

  clearOldMetadataFromMemory(currentMetadataId) {
    return this.controller.memoryManager.clearOldMetadataFromMemory(currentMetadataId)
  }

  cleanupUnusedMetadata() {
    return this.controller.memoryManager.cleanupUnusedMetadata()
  }

  optimizeMemoryUsage() {
    return this.controller.memoryManager.optimizeMemoryUsage()
  }

  // Utility methods
  safeMin(arr) {
    if (!arr || arr.length === 0) return undefined
    let min = Infinity
    for (let i = 0; i < arr.length; i++) {
      const value = arr[i]
      if (typeof value === 'number' && Number.isFinite(value) && value < min) {
        min = value
      }
    }
    return Number.isFinite(min) ? min : undefined
  }

  safeMax(arr) {
    if (!arr || arr.length === 0) return undefined
    let max = -Infinity
    for (let i = 0; i < arr.length; i++) {
      const value = arr[i]
      if (typeof value === 'number' && Number.isFinite(value) && value > max) {
        max = value
      }
    }
    return Number.isFinite(max) ? max : undefined
  }

  logMemoryUsage(context = '') {
    return this.controller.memoryManager.logMemoryUsage(context)
  }

  checkMemoryHealth() {
    return this.controller.memoryManager.checkMemoryHealth()
  }

  // Calculate centroids for each category (categories are label strings; values are codes)
  calculateCategoryCentroids(values, categories) {
    const calcStartTime = performance.now()
    
    // console.log(`calculateCategoryCentroids called with ${categories?.length} categories`) */
    
    if (!categories || !Array.isArray(categories)) {
      // console.log('Categories is not a valid array, returning empty centroids') */
      return {}
    }
    
    const centroids = {}
    const labelByCode = categories
    categories.forEach((category) => {
      centroids[category] = { x: 0, y: 0, count: 0 }
    })
    
    // ReGL PATH: Use currentCoordinates directly (no sprites in ReGL mode)
    if (this.controller.rendererType === 'regl' && this.controller.currentCoordinates && values) {
      // console.log(`Using ReGL path with currentCoordinates (${this.controller.currentCoordinates.length} points)`) */
      
      // Get visible cells for filtering
      const visibleSet = this.controller.currentVisibleCells ? new Set(this.controller.currentVisibleCells) : null
      let visiblePoints = 0
      let filteredPoints = 0
      
      // Iterate through all cells using their original indices
      for (let cellIndex = 0; cellIndex < this.controller.currentCoordinates.length; cellIndex++) {
        // Check if this cell is visible (not filtered out)
        const isVisible = !visibleSet || visibleSet.has(cellIndex)
        
        if (isVisible) {
          const code = values[cellIndex]
          const category = labelByCode[code]
          if (category != null && centroids[category]) {
            const coord = this.controller.currentCoordinates[cellIndex]
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
      
      // console.log(`ReGL: ${visiblePoints} visible points, ${filteredPoints} filtered out`) */
      
      // Calculate averages
      Object.keys(centroids).forEach(category => {
        if (centroids[category].count > 0) {
          centroids[category].x /= centroids[category].count
          centroids[category].y /= centroids[category].count
          // console.log(`ReGL centroid for "${category}": count=${centroids[category].count}, pos=(${centroids[category].x.toFixed(2)}, ${centroids[category].y.toFixed(2)})`) */
        }
      })
      
      return centroids
    }

    // Non-ReGL path: same code→label resolution using currentCoordinates when available
    if (this.controller.currentCoordinates && values) {
      const visibleSet = this.controller.currentVisibleCells ? new Set(this.controller.currentVisibleCells) : null
      for (let cellIndex = 0; cellIndex < this.controller.currentCoordinates.length; cellIndex++) {
        if (visibleSet && !visibleSet.has(cellIndex)) continue
        const code = values[cellIndex]
        const category = labelByCode[code]
        if (category == null || !centroids[category]) continue
        const coord = this.controller.currentCoordinates[cellIndex]
        if (coord && coord.length >= 2) {
          centroids[category].x += coord[0]
          centroids[category].y += coord[1]
          centroids[category].count += 1
        }
      }
      Object.keys(centroids).forEach(category => {
        if (centroids[category].count > 0) {
          centroids[category].x /= centroids[category].count
          centroids[category].y /= centroids[category].count
        }
      })
    }

    return centroids
  }

  // Calculate bounds for coordinates
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

  // Update visualization with metadata
  async updateVisualizationWithMetadata() {
    const vizStart = performance.now()
    // console.log('⏱️ [PERF] Step 2: updateVisualizationWithMetadata started') */
    
    if (!this.controller.metadataData) {
      // console.log('No metadata data to visualize') */
      return
    }
    
    // Get embedding ID for caching (use name as key)
    const embeddingId = this.controller.metadataData.name
    
    // Check cache first to avoid re-decompressing
    let decompressedCoords
    const decompressStart = performance.now()
    
    if (this.controller.decompressedCoordinatesCache.has(embeddingId)) {
      // console.log(`⏱️ [PERF] Step 2a: CACHE HIT - Using cached coordinates for ${embeddingId}`) */
      decompressedCoords = this.controller.decompressedCoordinatesCache.get(embeddingId)
      const cacheTime = performance.now() - decompressStart
      // console.log(`⏱️ [PERF] Step 2a: Cache retrieval: ${cacheTime.toFixed(2)}ms`) */
      this.perfLog('embedding_coordinates_cache_hit', {
        embeddingId,
        cacheLookupMs: Number(cacheTime.toFixed(2)),
        points: Array.isArray(decompressedCoords) ? decompressedCoords.length : 0
      }, { cellCount: Array.isArray(decompressedCoords) ? decompressedCoords.length : 0 })
    } else {
      // console.log(`⏱️ [PERF] Step 2a: CACHE MISS - Decompressing ${embeddingId}`) */
      // Decompress and cache (this method has its own internal logging)
      decompressedCoords = this.decompressBinaryCoordinates(this.controller.metadataData.binaryData)
      this.controller.decompressedCoordinatesCache.set(embeddingId, decompressedCoords)
      const decompressTime = performance.now() - decompressStart
      // console.log(`⏱️ [PERF] Step 2a: Total decompress + cache: ${decompressTime.toFixed(2)}ms`) */
      this.perfLog('embedding_coordinates_cache_miss', {
        embeddingId,
        decompressAndCacheMs: Number(decompressTime.toFixed(2)),
        points: Array.isArray(decompressedCoords) ? decompressedCoords.length : 0
      }, { cellCount: Array.isArray(decompressedCoords) ? decompressedCoords.length : 0 })
    }
    
    // Initialize scatter plot
    const plotStart = performance.now()
    await this.controller.rendererManager.initializeScatterPlot(decompressedCoords)
    const plotTime = performance.now() - plotStart
    // console.log(`⏱️ [PERF] Plot initialization completed in ${plotTime.toFixed(2)}ms`) */
    const vizTime = performance.now() - vizStart
    // console.log(`⏱️ [PERF] Step 2: updateVisualizationWithMetadata completed in ${vizTime.toFixed(2)}ms`) */
    this.perfLog('update_visualization_with_metadata', {
      embeddingId,
      points: Array.isArray(decompressedCoords) ? decompressedCoords.length : 0,
      plotInitMs: Number(plotTime.toFixed(2)),
      totalMs: Number(vizTime.toFixed(2))
    }, { cellCount: Array.isArray(decompressedCoords) ? decompressedCoords.length : 0 })
  }

  // Load a single metadata vector on demand
  async loadSingleMetadataVector(metadataId, options = {}) {
    // console.log(`=== LOADING SINGLE METADATA VECTOR: ${metadataId} ===`) */
    // console.log(`Call stack:`, new Error().stack) */
    
    // Check if already loaded in memory
    if (this.controller.loadedMetadataVectors[metadataId]) {
      // console.log(`💾 Metadata vector ${metadataId} already in memory`) */
      const cachedData = this.controller.loadedMetadataVectors[metadataId]
      // console.log('Cached data:', cachedData) */
      // console.log('Cached compressed_data:', cachedData.compressed_data) */
      // console.log('Cached compression_info:', cachedData.compression_info) */
      const enrichedData = this.ensureMetadataVectorValues(metadataId, cachedData)
      // Update status icon to show it's in memory
      this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
      return enrichedData
    }
    
    // Try to load from IndexedDB (disk storage) first
    // Always check disk before network to avoid unnecessary downloads
    if (!this.controller.loadingMetadataVectors.has(metadataId)) {
      // console.log(`🔍 [DEBUG] About to call loadMetadataFromIndexedDB for ${metadataId}`) */
      const indexDBStart = performance.now()
      const diskData = await this.controller.memoryManager.loadMetadataFromIndexedDB(metadataId)
      const indexDBEnd = performance.now()
      const indexDBDuration = (indexDBEnd - indexDBStart).toFixed(2)
      // console.log(`🔍 [DEBUG] loadMetadataFromIndexedDB completed for ${metadataId} in ${indexDBDuration}ms`) */
      if (diskData) {
        // Silently load from disk (reduced logging)
        // console.log(`💾 ✅ Loaded metadata ${metadataId} from IndexedDB (disk) - saved bandwidth!`) */
        
        // Remove IndexedDB metadata fields before returning
        const cleanData = { ...diskData }
        delete cleanData.loomFile
        delete cleanData.timestamp
        
        this.controller.loadedMetadataVectors[metadataId] = cleanData
        this.bumpMemoryLoadCounter(metadataId, 'disk')
        const enrichedData = this.ensureMetadataVectorValues(metadataId, cleanData)
        // Update status icon to show it's in memory (loaded from disk)
        this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
        return enrichedData
      }
    }
    
    // Check if currently loading — wait for the owner request; never clear its loading flag.
    if (this.controller.loadingMetadataVectors.has(metadataId)) {
      const waitStart = Date.now()
      while (this.controller.loadingMetadataVectors.has(metadataId)) {
        const inMemoryVector = this.controller.loadedMetadataVectors[metadataId]
        if (inMemoryVector) {
          this.perfLog('metadata_wait_short_circuit', {
            metadataId: metadataId ? String(metadataId) : null,
            waitMs: Date.now() - waitStart
          })
          return this.ensureMetadataVectorValues(metadataId, inMemoryVector)
        }
        await new Promise(resolve => setTimeout(resolve, 50))
      }

      if (this.controller.loadedMetadataVectors[metadataId]) {
        return this.ensureMetadataVectorValues(metadataId, this.controller.loadedMetadataVectors[metadataId])
      }

      // Concurrent attempt finished without memory data; try disk once more, then fall through to network.
      const diskDataAfterWait = await this.controller.memoryManager.loadMetadataFromIndexedDB(metadataId)
      if (diskDataAfterWait) {
        const cleanData = { ...diskDataAfterWait }
        delete cleanData.loomFile
        delete cleanData.timestamp
        this.controller.loadedMetadataVectors[metadataId] = cleanData
        this.bumpMemoryLoadCounter(metadataId, 'disk')
        const enrichedData = this.ensureMetadataVectorValues(metadataId, cleanData)
        this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
        return enrichedData
      }
    }
    
    // Mark as loading and update status icon to show downloading
    this.controller.loadingMetadataVectors.add(metadataId)
    this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'downloading')
    
    try {
      // Prefer explicit loom for this metadata; do not guess from a stale selector.
      const loomFile = options.loomFile
        || (typeof this.controller.getLoomFileForMetadataRequest === 'function'
          ? this.controller.getLoomFileForMetadataRequest(metadataId)
          : null)
        || (this.controller.hasLoomFileSelectTarget ? this.controller.loomFileSelectTarget.value : this.controller.defaultLoomFileValue)
      
      // Build the URL for the single metadata vector endpoint
      // Extract project identifier from URL (supports ID, key, or public_id)
      const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
      const projectIdentifier = pathMatch ? pathMatch[1] : null
      const url = `/projects/${encodeURIComponent(projectIdentifier)}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
      // console.log(`Fetching single metadata vector from URL: ${url}`)
      
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
      // console.log('Received single metadata vector data:', data) */
      
      // Store the loaded metadata vector
      const vectorData = data.metadata_vectors[metadataId]
      if (vectorData) {
        // FIRST: Store in memory cache immediately
        this.controller.loadedMetadataVectors[metadataId] = vectorData
        this.bumpMemoryLoadCounter(metadataId, 'network')
        const enrichedData = this.ensureMetadataVectorValues(metadataId, vectorData)
        const dataToPersist = { ...vectorData }
        if (dataToPersist.values && dataToPersist.compressed_data) {
          delete dataToPersist.values
        }
        
        // Update status icon to show it's in memory
        this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
        
        // SECOND: Store in IndexedDB for future sessions (async, don't wait)
        this.controller.memoryManager.storeMetadataInIndexedDB(metadataId, dataToPersist).catch(error => {
          console.error(`Failed to store metadata ${metadataId} in IndexedDB:`, error)
        })
        
        // Silently cached (reduced logging)
        // console.log(`💾 ✅ Loaded and cached metadata vector ${metadataId} (memory + disk)`) */
        return enrichedData
      } else {
        throw new Error(`No metadata vector found for ID: ${metadataId}`)
      }
    } catch (error) {
      console.error(`Failed to load metadata vector ${metadataId}:`, error)
      // Update status icon to show load failure.
      this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'error')
      throw error
    } finally {
      // Always clean up loading state
      this.controller.loadingMetadataVectors.delete(metadataId)
    }
  }

  // Decompress discrete metadata vector from binary data
  isDiscreteMetadata(vector) {
    const dataType = vector?.data_type
    return dataType === 'DISCRETE' || dataType === 'STRING'
  }

  getCategoryLabels(vector) {
    const categories = vector?.compression_info?.categories
    if (Array.isArray(categories) && categories.length > 0) {
      return categories
    }
    return null
  }

  allocateCategoryCodeArray(cellCount, categoryCount) {
    if (categoryCount <= 0x100) return new Uint8Array(cellCount)
    if (categoryCount <= 0x10000) return new Uint16Array(cellCount)
    return new Uint32Array(cellCount)
  }

  // Discrete values are category codes (TypedArray). Labels live in compression_info.categories.
  getCategoryCode(vector, cellIndex) {
    return vector.values[cellIndex]
  }

  getCategoryLabel(vector, cellIndex) {
    const labels = this.getCategoryLabels(vector)
    const code = this.getCategoryCode(vector, cellIndex)
    if (!labels) {
      throw new Error('Discrete metadata is missing compression_info.categories')
    }
    return labels[code]
  }

  labelToCode(vector, label) {
    const labels = this.getCategoryLabels(vector)
    if (!labels) {
      throw new Error('Discrete metadata is missing compression_info.categories')
    }
    const needle = String(label)
    for (let i = 0; i < labels.length; i++) {
      if (String(labels[i]) === needle) return i
    }
    return -1
  }

  codesMatchingLabels(vector, labelSet) {
    const labels = this.getCategoryLabels(vector)
    if (!labels) {
      throw new Error('Discrete metadata is missing compression_info.categories')
    }
    const selected = new Set(Array.from(labelSet).map(String))
    const codes = new Set()
    for (let i = 0; i < labels.length; i++) {
      if (selected.has(String(labels[i]))) codes.add(i)
    }
    return codes
  }

  decompressDiscreteMetadataVector(binaryData, compressionInfo) {
    // Handle optimized case: single category (no data needed)
    if (compressionInfo.single_category) {
      const { categories, category_index, length } = compressionInfo
      if (!Array.isArray(categories) || categories.length === 0) {
        throw new Error('Single-category discrete metadata is missing compression_info.categories')
      }
      const code = category_index || 0
      const codes = this.allocateCategoryCodeArray(length, categories.length)
      codes.fill(code)
      return codes
    }
    
    // Check if binaryData is valid
    if (!binaryData) {
      throw new Error('Binary data is null or undefined')
    }
    
    const { categories, bit_width, cell_count } = compressionInfo
    if (!Array.isArray(categories) || categories.length === 0) {
      throw new Error('Discrete metadata is missing compression_info.categories')
    }
    const codes = this.allocateCategoryCodeArray(cell_count, categories.length)
    
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
    
    // Read category codes based on bit width (keep as TypedArray — do not expand to strings)
    switch (bit_width) {
      case 1:
        // Special case: unpack 8 indices per byte for 1-bit encoding
        for (let i = 0; i < cell_count; i++) {
          const byteIndex = Math.floor(i / 8)
          const bitIndex = i % 8
          const byte = view.getUint8(byteIndex)
          codes[i] = (byte >> bitIndex) & 1
        }
        break
      case 8:
        for (let i = 0; i < cell_count; i++) {
          codes[i] = view.getUint8(i)
        }
        break
      case 16:
        for (let i = 0; i < cell_count; i++) {
          codes[i] = view.getUint16(i * 2, true) // little-endian
        }
        break
      case 32:
        for (let i = 0; i < cell_count; i++) {
          codes[i] = view.getUint32(i * 4, true) // little-endian
        }
        break
      default:
        throw new Error(`Unsupported bit width: ${bit_width}`)
    }
    
    return codes
  }

  // Decompress continuous metadata vector from binary data
  decompressContinuousMetadataVector(binaryData, compressionInfo) {
    // console.log('Decompressing continuous metadata vector:', compressionInfo)
    
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
    
    // console.log(`Decompressed ${cell_count} continuous values:`, {
     // first10: numericValues.slice(0, 10),
     // range: `${numericValues[0]?.toFixed(3)} to ${numericValues[cell_count-1]?.toFixed(3)}`,
     // actualRange: `${this.safeMin(numericValues).toFixed(3)} to ${this.safeMax(numericValues).toFixed(3)}`
     // })*/ */
    
    return numericValues
  }

  normalizeMetadataCompressionInfo(raw) {
    if (raw == null) return null
    if (typeof raw === 'object' && !Array.isArray(raw)) return raw
    if (typeof raw === 'string') {
      try {
        return JSON.parse(raw)
      } catch (e) {
        return null
      }
    }
    return null
  }

  ensureMetadataVectorValues(metadataId, vectorData) {
    if (!vectorData) {
      return null
    }

    const isDiscrete = vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING'
    const hasValues = vectorData.values && typeof vectorData.values.length === 'number' && vectorData.values.length > 0
    // Legacy IndexedDB entries may still store per-cell category name strings.
    // Discrete values must be TypedArray category codes.
    const hasLegacyStringCategories = isDiscrete && hasValues && typeof vectorData.values[0] === 'string'
    
    if (hasValues && !hasLegacyStringCategories) {
      const expectedLength = vectorData.compression_info?.cell_count
      if (!expectedLength || vectorData.values.length === expectedLength || vectorData.values.length > 0) {
        return vectorData
      }
    }
    
    let compressionInfo = this.normalizeMetadataCompressionInfo(vectorData.compression_info)
    if (compressionInfo && typeof vectorData.compression_info === 'string') {
      vectorData.compression_info = compressionInfo
    }

    if (compressionInfo && compressionInfo.type === 'error') {
      console.warn(
        `[DataManager] Metadata ${metadataId} compression failed on server: ${compressionInfo.code || 'error'} ${compressionInfo.message || ''}`
      )
      vectorData.compression_info = compressionInfo
      return vectorData
    }

    if (
      vectorData.data_type === 'NUMERIC' &&
      compressionInfo &&
      compressionInfo.zero_range === true &&
      Number.isFinite(compressionInfo.min_val) &&
      typeof compressionInfo.cell_count === 'number' &&
      compressionInfo.cell_count > 0
    ) {
      const fill = compressionInfo.min_val
      const n = compressionInfo.cell_count
      vectorData.values = new Array(n).fill(fill)
      vectorData.compression_info = compressionInfo
      if (this.controller.loadedMetadataVectors) {
        this.controller.loadedMetadataVectors[metadataId] = vectorData
      }
      return vectorData
    }

    if (!compressionInfo) {
      if (typeof vectorData.compression_info === 'string' && vectorData.compression_info.length > 0) {
        console.warn(
          `[DataManager] Metadata ${metadataId} has non-JSON compression_info string; re-fetch may be needed after server update`
        )
      } else {
        console.warn(`⚠️ [DataManager] Metadata ${metadataId} is missing compression_info - cannot ensure values are loaded`)
      }
      return vectorData
    }

    // Convert legacy per-cell category name strings to TypedArray codes.
    if (hasLegacyStringCategories) {
      const labels = Array.isArray(compressionInfo.categories) ? compressionInfo.categories : null
      if (!labels || labels.length === 0) {
        throw new Error(`Discrete metadata ${metadataId} has string values but no compression_info.categories`)
      }
      const labelToCode = new Map(labels.map((label, code) => [String(label), code]))
      const codes = this.allocateCategoryCodeArray(vectorData.values.length, labels.length)
      for (let i = 0; i < vectorData.values.length; i++) {
        const code = labelToCode.get(String(vectorData.values[i]))
        if (code === undefined) {
          throw new Error(`Discrete metadata ${metadataId} has unknown category label at cell ${i}`)
        }
        codes[i] = code
      }
      vectorData.values = codes
      if (this.controller.loadedMetadataVectors) {
        this.controller.loadedMetadataVectors[metadataId] = vectorData
      }
      return vectorData
    }
    
    const hasCompressedPayload = !!vectorData.compressed_data || compressionInfo.single_category
    if (!hasCompressedPayload) {
      console.warn(`⚠️ [DataManager] Metadata ${metadataId} has no values or compressed_data available`)
      return vectorData
    }
    
    try {
      let values = null
      if (vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING') {
        values = this.decompressDiscreteMetadataVector(vectorData.compressed_data, compressionInfo)
      } else if (vectorData.data_type === 'NUMERIC') {
        values = this.decompressContinuousMetadataVector(vectorData.compressed_data, compressionInfo)
      } else {
        console.warn(`⚠️ [DataManager] Unknown data type for metadata ${metadataId}: ${vectorData.data_type}`)
        return vectorData
      }
      
      if (values && typeof values.length === 'number') {
        vectorData.values = values
        // Replace the cached entry to guarantee future consumers see the values as well
        if (this.controller.loadedMetadataVectors) {
          this.controller.loadedMetadataVectors[metadataId] = vectorData
        }
      } else {
        console.warn(`⚠️ [DataManager] Decompression of metadata ${metadataId} produced invalid values`, values)
      }
    } catch (error) {
      console.error(`❌ [DataManager] Failed to ensure values for metadata ${metadataId}:`, error)
    }
    
    return vectorData
  }

  // Load and visualize metadata vector for a specific metadata ID
  async loadAndVisualizeMetadataVector(metadataId, options = {}) {
    const startedAt = performance.now()
    this.controller.checkpointTrace('loadAndVisualizeMetadataVector:start', {
      metadataId: metadataId ? String(metadataId) : null,
      isApplyingCheckpointState: !!this.controller.isApplyingCheckpointState
    })

    // console.log(`🔍 [DEBUG] Loading and visualizing metadata vector for ID: ${metadataId}`) */
    // console.log(`🔍 [DEBUG] Current state before load:`) */
    // console.log(`🔍 [DEBUG] - loadedMetadataVectors keys:`, Object.keys(this.controller.loadedMetadataVectors || {})) */
    // console.log(`🔍 [DEBUG] - loadingMetadataVectors size:`, this.controller.loadingMetadataVectors?.size || 0) */
    
    // Ensure metadata is loaded into memory for fast access
    let vectorData = await this.loadSingleMetadataVector(metadataId, options)
    
    if (!vectorData) {
      console.error('❌ Failed to load metadata vector for:', metadataId)
      console.error('❌ loadedMetadataVectors keys:', Object.keys(this.controller.loadedMetadataVectors))
      console.error('❌ loadingMetadataVectors:', Array.from(this.controller.loadingMetadataVectors))
      console.error('❌ IndexedDB available:', !!this.controller.db)
      
      // Try to diagnose the issue
      if (this.controller.loadingMetadataVectors.has(metadataId)) {
        console.error('❌ DIAGNOSIS: Metadata is still marked as loading - this indicates a race condition!')
      }
      this.controller.checkpointTrace('loadAndVisualizeMetadataVector:missing-data', {
        metadataId: metadataId ? String(metadataId) : null,
        loadingMetadataVectors: Array.from(this.controller.loadingMetadataVectors || [])
      })
      return
    }
    
    // console.log(`✅ [DEBUG] Successfully received vectorData, proceeding with decompression...`) */
    
    // console.log('✅ Successfully loaded metadata vector:', {
     // id: vectorData.id || metadataId,
     // name: vectorData.name,
     // dataType: vectorData.data_type,
     // hasValues: !!vectorData.values,
     // hasCompressedData: !!vectorData.compressed_data,
     // valuesLength: vectorData.values?.length
     // }) */
    
    // Normalize compression_info (object or JSON string). No bare English sentences from the server.
    const parsedInfo = this.normalizeMetadataCompressionInfo(vectorData.compression_info)
    if (parsedInfo) {
      vectorData.compression_info = parsedInfo
    }
    if (vectorData.compression_info && vectorData.compression_info.type === 'error') {
      return
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
            // console.log('Created mock compression_info for NUMERIC data:', vectorData.compression_info) */
          }
        }
      }
      
      // If still no valid data, try to reload
      if (!hasCompressedData && !hasUncompressedData) {
        // Clear the corrupted cache entry and try to reload
        delete this.controller.loadedMetadataVectors[metadataId]
        // console.log('Cleared corrupted cache entry, retrying load...')
        const retryData = await this.loadSingleMetadataVector(metadataId, options)
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
        // console.log(`Using uncompressed data: ${values.length} values for ${vectorData.name}`) */
      } else if (hasCompressedData) {
        // Data is compressed, decompress it
        if (vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING') {
          values = this.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else if (vectorData.data_type === 'NUMERIC') {
          values = this.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else {
          console.error('Unknown data type:', vectorData.data_type)
          return
        }
      } else {
        console.error('No valid data found in metadata vector')
        this.controller.checkpointTrace('loadAndVisualizeMetadataVector:no-valid-data', {
          metadataId: metadataId ? String(metadataId) : null
        })
        return
      }
    } catch (error) {
      console.error('Error processing metadata vector:', error)
      // Clear the corrupted cache entry
      delete this.controller.loadedMetadataVectors[metadataId]
      this.controller.checkpointTrace('loadAndVisualizeMetadataVector:processing-error', {
        metadataId: metadataId ? String(metadataId) : null,
        error: String(error?.message || error)
      })
      return
    }
    
    // console.log(`Successfully decompressed ${values.length} values for ${vectorData.name}`)
    
    // Store the decompressed values for visualization
    this.controller.currentMetadataVector = {
      id: metadataId,
      name: vectorData.name,
      data_type: vectorData.data_type,
      values: values,
      compression_info: vectorData.compression_info
    }
    
    // Update adapt color range button visibility for all range sliders
    this.controller.updateAllRangeSliderButtonAppearances()
    
    try {
      // console.log(`✅ [DEBUG] Set currentMetadataVector at:`, new Error().stack) */
    } catch (e) {
      // console.log(`✅ [DEBUG] Set currentMetadataVector (stack not available):`, e) */
    }
    // console.log(`✅ [DEBUG] Set currentMetadataVector:`, {
     // id: this.controller.currentMetadataVector.id,
     // name: this.controller.currentMetadataVector.name,
     // dataType: this.controller.currentMetadataVector.data_type,
     // valuesLength: this.controller.currentMetadataVector.values?.length
     // }) */
    
    // Also store in loadedMetadataVectors for filtering
    this.controller.loadedMetadataVectors[metadataId] = this.controller.currentMetadataVector
    
    // console.log(`✅ [DEBUG] [Instance ${this.controller.instanceId}] Stored in loadedMetadataVectors. New keys:`, Object.keys(this.controller.loadedMetadataVectors)) */
    // console.log(`✅ [DEBUG] Immediately after storing - loadedMetadataVectors[${metadataId}] exists:`, !!this.controller.loadedMetadataVectors[metadataId]) */
    
    // Update usage tracker for LRU
    this.controller.memoryManager.updateMetadataUsage(metadataId)
    
    // Cleanup old metadata if we exceed the buffer size
    this.controller.memoryManager.cleanupUnusedMetadata()
    
    // Note: We keep metadata in memory during the session for fast switching
    // IndexedDB is used for persistence across page reloads
    // LRU cleanup ensures we don't exceed maxMetadataInMemory
    
    // Show checkboxes for this metadata now that it's loaded
    // console.log(`🔍 [DEBUG] Calling showCheckboxesForMetadata for metadata ${metadataId}`) */
    this.controller.uiManager.showCheckboxesForMetadata(metadataId)
    this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
    
    // Clear incremental state when new metadata is loaded
    this.controller.clearIncrementalState()
    
    // Clear performance caches for new metadata
    this.controller.clearPerformanceCaches()
    
    // Note: Don't clean up stale selections - they should be preserved
    // If metadata is needed for filtering but not in memory, it will be loaded on demand
    
    // Don't clear checkbox selections - preserve them when switching metadata
    // This allows users to maintain their filter selections across different visualizations
    
    // Update settings window state
    this.controller.uiManager.updateCategoriesCheckboxState()
    
    // Also store the metadata ID for color mapping
    this.controller.currentMetadataId = metadataId

    // Clear the cached color map since we have new metadata
    this.controller.colorManager.clearColorMapCache()
    
    // Clear old category labels before rendering new metadata
    if (this.controller.categoryLabelsContainer) {
      this.controller.categoryLabelsContainer.removeChildren()
    }
    
    // Initialize gradient BEFORE updating visualization for continuous metadata
    if (this.controller.currentMetadataVector?.data_type === 'NUMERIC') {
      // Load stored gradient for this metadata (or initialize default if none exists)
      this.controller.gradientManager.loadGradientForMetadata(metadataId)
      
      // Force reordering of points when switching metadata (values are different even if order preference is same)
      this.controller._lastNumericOrderApplied = null
      // console.log('📊 [ORDERING] Reset _lastNumericOrderApplied to force reordering for new metadata') */
    }
    
    // Update visualization with metadata coloring
    this.controller.updateVisualizationWithMetadataVector()
    
    // Initialize checkboxes for the new metadata (only for discrete)
    // NOTE: Don't auto-select categories when loading metadata - let user choose
    if (this.controller.currentMetadataVector?.data_type === 'DISCRETE' || this.controller.currentMetadataVector?.data_type === 'STRING') {
      // Just show the checkboxes without selecting them
      // this.controller.uiManager.initializeAllCheckboxes()
      // console.log('📋 Discrete metadata loaded - checkboxes available for user selection') */
      
      // Update category distribution bars for all visible metadata sections
      this.updateAllCategoryDistributions()
    } else if (this.controller.currentMetadataVector?.data_type === 'NUMERIC') {
      // console.log('📊 Continuous metadata loaded - updating distribution bars') */
      
      // Update distribution bars for continuous coloring
      this.updateAllCategoryDistributions()
    }
    
    // Update cell filtering after loading metadata vector
    // Pass shouldUpdateColors=true for continuous metadata to ensure colors are rendered after filtering
    const shouldUpdateColors = this.controller.currentMetadataVector?.data_type === 'NUMERIC'
    this.updateCellFiltering(shouldUpdateColors)

    // Initialize gradient legend listeners for continuous metadata
    if (this.controller.currentMetadataVector?.data_type === 'NUMERIC') {
      this.controller.gradientManager.initializeGradientLegendListeners()
    } else {
      // Remove gradient legend listeners when switching to categorical metadata
      this.controller.gradientManager.removeGradientLegendListeners()
      
      // Disable pointer events on overlay for discrete metadata
      // This allows interactions with the plot below
      if (this.controller.overlayCanvas) {
        this.controller.overlayCanvas.style.pointerEvents = 'none'
      }
    }
    
    // Final check - is the data still in memory at the end of this function?
    // console.log(`✅ [DEBUG] [Instance ${this.controller.instanceId}] END of loadAndVisualizeMetadataVector - loadedMetadataVectors keys:`, Object.keys(this.controller.loadedMetadataVectors)) */
    // console.log(`✅ [DEBUG] END - loadedMetadataVectors[${metadataId}] still exists:`, !!this.controller.loadedMetadataVectors[metadataId]) */
    this.controller.checkpointTrace('loadAndVisualizeMetadataVector:done', {
      metadataId: metadataId ? String(metadataId) : null,
      currentMetadataId: this.controller.currentMetadataId ? String(this.controller.currentMetadataId) : null,
      metadataType: this.controller.currentMetadataVector?.data_type || null
    })
    this.perfLog('load_and_visualize_metadata_vector', {
      metadataId: metadataId ? String(metadataId) : null,
      metadataName: vectorData?.name || null,
      dataType: vectorData?.data_type || null,
      valuesCount: Array.isArray(values) ? values.length : 0,
      totalMs: Number((performance.now() - startedAt).toFixed(2))
    }, { cellCount: Array.isArray(values) ? values.length : 0 })
  }

  // Update cell filtering with performance optimization
  updateCellFiltering(shouldUpdateColors = false) {
    // console.log('🔍 [FILTERING] updateCellFiltering called with selectedRanges:', this.controller.selectedRanges) */
    // Performance optimization: batch multiple updates
    this.controller.scheduleUpdate('filtering', () => {
      this.performCellFilteringUpdate(shouldUpdateColors)
    })
  }

  // Actual filtering update logic (separated for batching)
  performCellFilteringUpdate(shouldUpdateColors = false) {
    const perfEnabled = this.controller.perfLoggingEnabled?.() === true
    const t0 = perfEnabled ? performance.now() : 0
    if (perfEnabled) {
      this.controller.logPerf('pipeline_performCellFiltering_enter', 0, {
        shouldUpdateColors: !!shouldUpdateColors
      })
    }

    // Use incremental filtering for better performance
    const filteredIndices = this.getIncrementalFilteredIndices()
    const previousVisibleCells = this.controller.currentVisibleCells
    const hadFilterBefore = Array.isArray(previousVisibleCells)
    const hasFilterNow = Array.isArray(filteredIndices)
    const filterModeChanged = hadFilterBefore !== hasFilterNow

    // Update the current visible cells state
    this.controller.currentVisibleCells = filteredIndices
    if (!filteredIndices) {
      this.controller.currentVisibleMask = null
    } else {
      this.ensureVisibleMask(filteredIndices)
    }
    this.bumpFilterGeneration()
    
    // Update current selection to only include visible cells
    this.updateSelectionBasedOnFiltering(filteredIndices)
    
    // Update point count display immediately
    this.controller.uiManager.updatePointCountDisplay(filteredIndices)
    
    // Refresh selection summary after every filtering action.
    this.controller.updateSelectionCount()
    
    // Update global filter summary (count and switch state)
    this.controller.uiManager.updateGlobalFilterSummary()

    // Defer expensive O(n) sidebar/plot UI so the scatter visibility update can run first.
    if (hasFilterNow || hadFilterBefore || filterModeChanged) {
      this.scheduleFilterSidebarRefresh()
    }

    if (perfEnabled) {
      this.controller.logPerf('pipeline_performCellFiltering_syncDone', performance.now() - t0, {
        shouldUpdateColors: !!shouldUpdateColors,
        hasFilterNow,
        hadFilterBefore,
        filterModeChanged,
        filteredCount: filteredIndices ? filteredIndices.length : null
      })
    }
    
    // Use requestAnimationFrame for smooth updates
    if (perfEnabled) {
      this.controller.logPerf('pipeline_performCellFiltering_rafScheduled', 0, {
        shouldUpdateColors: !!shouldUpdateColors,
        hasFilterNow,
        hadFilterBefore,
        filterModeChanged
      })
    }
    const rafScheduleTime = performance.now()
    requestAnimationFrame(async () => {
      const rafStart = performance.now()
      if (perfEnabled) {
        this.controller.logPerf('pipeline_performCellFiltering_rafStart', rafStart - rafScheduleTime, {
          shouldUpdateColors: !!shouldUpdateColors,
          gapSinceScheduleMs: Number((rafStart - rafScheduleTime).toFixed(2))
        })
      }

      // Debug: Check what metadata is being filtered
      const isGeneFiltering = filteredIndices !== null && 
                             this.controller.selectedRanges && 
                             Object.keys(this.controller.selectedRanges).some(id => id.startsWith('gene_'))
      
      if (isGeneFiltering) {
        // console.log('🧬 [FILTER] Gene filtering detected - checking renderer state...') */
      }
      
      // Only update visualization if renderer is ready
      // For ReGL: check if coordinates and displayOrder are set (these are set when renderScatterPlot is called)
      // Also check if renderer has internal state (positions/colors) as fallback
      const readinessStart = perfEnabled ? performance.now() : 0
      const hasCanvas = this.controller.canvas && 
                       this.controller.canvas.width > 0 && 
                       this.controller.canvas.height > 0
      
      if (isGeneFiltering) {
        // console.log('🧬 [FILTER] Canvas check:', {
         // hasCanvas,
         // canvasWidth: this.controller.canvas?.width,
         // canvasHeight: this.controller.canvas?.height,
         // canvasExists: !!this.controller.canvas
         // }) */
      }
      
      // Check if renderer has internal state (positions or colors)
      // This is critical - renderer may have state even if currentCoordinates/displayOrder are missing
      let hasRendererState = false
      let rendererNumPoints = 0
      if (this.controller.reglRenderer) {
        // Log renderer instance identity for debugging scope issues
        const rendererId = this.controller.reglRenderer.canvas?.id || 
                          `canvas_${this.controller.reglRenderer.canvas?.width}x${this.controller.reglRenderer.canvas?.height}` ||
                          'unknown'
        // console.log('🎨 [FILTER] Renderer instance check:', {
         // rendererExists: !!this.controller.reglRenderer,
         // rendererInstanceId: this.controller.reglRenderer.instanceId || 'no-instance-id',
         // rendererId: rendererId,
         // rendererCanvas: this.controller.reglRenderer.canvas,
         // controllerCanvas: this.controller.canvas,
         // sameInstance: this.controller.reglRenderer.canvas === this.controller.canvas,
         // numPoints: this.controller.reglRenderer.numPoints,
         // hasPositions: !!this.controller.reglRenderer.positions,
         // positionsLength: this.controller.reglRenderer.positions?.length,
         // hasColors: !!this.controller.reglRenderer.colors,
         // colorsLength: this.controller.reglRenderer.colors?.length,
         // hasPositionBuffer: !!this.controller.reglRenderer.positionBuffer,
         // hasColorBuffer: !!this.controller.reglRenderer.colorBuffer,
         // reglExists: !!this.controller.reglRenderer.regl
         // }) */
        
        if (this.controller.reglRenderer.numPoints > 0) {
          hasRendererState = true
          rendererNumPoints = this.controller.reglRenderer.numPoints
        } else if (this.controller.reglRenderer.positions && this.controller.reglRenderer.positions.length > 0) {
          hasRendererState = true
          rendererNumPoints = this.controller.reglRenderer.positions.length / 2
        } else if (this.controller.reglRenderer.colors && this.controller.reglRenderer.colors.length > 0) {
          hasRendererState = true
          rendererNumPoints = this.controller.reglRenderer.colors.length / 4
        }
      } else {
        // console.log('🎨 [FILTER] Renderer instance is null or undefined') */
      }
      
      // Renderer is ready if we have ANY of these:
      // 1. currentCoordinates AND displayOrder exist (normal case - metadata loaded)
      // 2. OR canvas exists AND renderer has internal state (can infer displayOrder from renderer)
      // 3. OR we have coordinates in cache (can restore from cache)
      // 4. OR we have metadataData (can decompress coordinates)
      // 5. OR renderer has positions (can restore coordinates from positions)
      const hasCoordinatesInController = this.controller.currentCoordinates && 
                                        this.controller.currentCoordinates.length > 0
      const hasCoordinatesInCache = this.controller.decompressedCoordinatesCache && 
                                    this.controller.decompressedCoordinatesCache.size > 0
      const hasMetadataData = !!this.controller.metadataData
      const hasRendererPositions = this.controller.reglRenderer && 
                                   this.controller.reglRenderer.positions && 
                                   this.controller.reglRenderer.positions.length > 0
      const hasCoordinatesAvailable = hasCoordinatesInController || 
                                     hasCoordinatesInCache || 
                                     hasMetadataData ||
                                     hasRendererPositions
      
      let reglReady = this.controller.rendererType === 'regl' && 
                       this.controller.reglRenderer && 
                       hasCanvas &&
                       ((this.controller.currentCoordinates && 
                         this.controller.displayOrder &&
                         this.controller.displayOrder.length > 0) || 
                        hasRendererState ||
                        hasCoordinatesAvailable)  // If we have coordinates available, we can restore/initialize
      
      let isRendererReady = reglReady
      
      // CRITICAL: If renderer has state but currentCoordinates/displayOrder are missing,
      // create displayOrder from renderer state BEFORE checking isRendererReady
      // This handles the case where plot was rendered but coordinates weren't stored
      if (hasRendererState && rendererNumPoints > 0 && 
          (!this.controller.displayOrder || this.controller.displayOrder.length === 0)) {
        // console.log('🎨 [FILTER] Renderer has state but displayOrder missing - creating from renderer state') */
        this.controller.displayOrder = new Array(rendererNumPoints)
        for (let i = 0; i < rendererNumPoints; i++) {
          this.controller.displayOrder[i] = i
        }
        // console.log('🎨 [FILTER] Created displayOrder from renderer state:', rendererNumPoints, 'points') */
        
        // Re-evaluate isRendererReady now that displayOrder exists
        reglReady = this.controller.rendererType === 'regl' && 
                   this.controller.reglRenderer && 
                   hasCanvas &&
                   ((this.controller.currentCoordinates && 
                     this.controller.displayOrder &&
                     this.controller.displayOrder.length > 0) || 
                    hasRendererState ||
                    hasCoordinatesAvailable)
        isRendererReady = reglReady
      }
      
      // console.log('🎨 [FILTER] About to update visualization:', {
       // rendererType: this.controller.rendererType,
       // hasReglRenderer: !!this.controller.reglRenderer,
       // hasCanvas: hasCanvas,
       // canvasWidth: this.controller.canvas?.width || 0,
       // canvasHeight: this.controller.canvas?.height || 0,
       // hasCurrentCoordinates: !!this.controller.currentCoordinates,
       // currentCoordinatesLength: this.controller.currentCoordinates?.length || 0,
       // hasDisplayOrder: !!this.controller.displayOrder,
       // displayOrderLength: this.controller.displayOrder?.length || 0,
       // hasRendererState: !!hasRendererState,
       // rendererNumPoints: this.controller.reglRenderer?.numPoints || 0,
       // rendererPositionsLength: this.controller.reglRenderer?.positions?.length || 0,
       // rendererColorsLength: this.controller.reglRenderer?.colors?.length || 0,
       // hasScatterContainer: !!this.controller.scatterContainer,
       // isRendererReady: isRendererReady,
       // filteredIndicesCount: filteredIndices ? filteredIndices.length : 'null',
       // shouldUpdateColors: shouldUpdateColors,
       // reglReady: reglReady
       // }) */
      
      if (!isRendererReady) {
        // Renderer not ready - try to restore/initialize state if we have coordinates available
        if (this.controller.rendererType === 'regl' && 
            this.controller.reglRenderer && 
            hasCanvas &&
            hasCoordinatesAvailable) {
          
          // If renderer has internal state (positions/colors), we can infer numPoints
          // and create displayOrder without needing currentCoordinates
          const rendererHasPositions = this.controller.reglRenderer.positions && this.controller.reglRenderer.positions.length > 0
          const rendererHasColors = this.controller.reglRenderer.colors && this.controller.reglRenderer.colors.length > 0
          
          if (rendererHasPositions || rendererHasColors) {
            // Renderer has state - infer numPoints and create displayOrder
            let numPoints = 0
            if (this.controller.reglRenderer.numPoints > 0) {
              numPoints = this.controller.reglRenderer.numPoints
            } else if (rendererHasPositions) {
              numPoints = this.controller.reglRenderer.positions.length / 2
              this.controller.reglRenderer.numPoints = numPoints
            } else if (rendererHasColors) {
              numPoints = this.controller.reglRenderer.colors.length / 4
              this.controller.reglRenderer.numPoints = numPoints
            }
            
            if (numPoints > 0 && (!this.controller.displayOrder || this.controller.displayOrder.length === 0)) {
              // console.log('🎨 [FILTER] Creating displayOrder from renderer state:', numPoints, 'points') */
              this.controller.displayOrder = new Array(numPoints)
              for (let i = 0; i < numPoints; i++) {
                this.controller.displayOrder[i] = i
              }
              // console.log('🎨 [FILTER] displayOrder created, proceeding with visibility update') */
              // Continue with visibility update
            } else if (numPoints === 0) {
              // console.log('🎨 [FILTER] Cannot infer numPoints from renderer state') */
              // console.log('🎨 [FILTER] Skipping visualization update - renderer not ready yet') */
              return
            } else {
              // displayOrder already exists, proceed
              // console.log('🎨 [FILTER] displayOrder exists, proceeding with visibility update') */
            }
          } else {
            // No renderer state - but plot is visible, so renderer must have been used
            // Check if we can get coordinates from the last rendered embedding
            // The coordinates should be in decompressedCoordinatesCache if an embedding was loaded
            // console.log('🎨 [FILTER] Renderer has no internal state but plot is visible - attempting to restore') */
            // console.log('🎨 [FILTER] Checking cache and metadataData:', {
             // hasMetadataData: !!this.controller.metadataData,
             // metadataDataName: this.controller.metadataData?.name,
             // hasCache: !!this.controller.decompressedCoordinatesCache,
             // cacheSize: this.controller.decompressedCoordinatesCache?.size || 0,
             // cacheKeys: this.controller.decompressedCoordinatesCache ? Array.from(this.controller.decompressedCoordinatesCache.keys()) : []
             // }) */
            
            let coordinatesToRestore = null
            
            // First, try to get coordinates using metadataData.name (if available)
            if (this.controller.metadataData && this.controller.metadataData.name && this.controller.decompressedCoordinatesCache) {
              const embeddingId = this.controller.metadataData.name
              coordinatesToRestore = this.controller.decompressedCoordinatesCache.get(embeddingId)
              if (coordinatesToRestore) {
                // console.log('🎨 [FILTER] Found coordinates in cache for embeddingId:', embeddingId, 'length:', coordinatesToRestore.length) */
              } else {
                // console.log('🎨 [FILTER] No coordinates in cache for embeddingId:', embeddingId) */
              }
            }
            
            // If not found, try any available coordinates in cache
            if (!coordinatesToRestore && this.controller.decompressedCoordinatesCache && this.controller.decompressedCoordinatesCache.size > 0) {
              const firstKey = this.controller.decompressedCoordinatesCache.keys().next().value
              if (firstKey) {
                coordinatesToRestore = this.controller.decompressedCoordinatesCache.get(firstKey)
                if (coordinatesToRestore) {
                  // console.log('🎨 [FILTER] Found coordinates in cache (first available):', firstKey, 'length:', coordinatesToRestore.length) */
                }
              }
            }
            
            // If still no coordinates, try to decompress from metadataData if available
            if (!coordinatesToRestore && this.controller.metadataData) {
              // console.log('🎨 [FILTER] No coordinates in cache - attempting to decompress from metadataData...') */
              try {
                const decompressedCoords = this.decompressBinaryCoordinates(this.controller.metadataData.binaryData)
                if (decompressedCoords && decompressedCoords.length > 0) {
                  // Cache them for next time
                  const embeddingId = this.controller.metadataData.name
                  if (!this.controller.decompressedCoordinatesCache) {
                    this.controller.decompressedCoordinatesCache = new Map()
                  }
                  this.controller.decompressedCoordinatesCache.set(embeddingId, decompressedCoords)
                  coordinatesToRestore = decompressedCoords
                  // console.log('🎨 [FILTER] Decompressed coordinates from metadataData:', decompressedCoords.length, 'points') */
                }
              } catch (error) {
                console.error('🎨 [FILTER] Failed to decompress coordinates from metadataData:', error)
              }
            }
            
            // If still no coordinates, check if we can get them from the renderer's canvas dimensions
            // This handles the case where the plot is visible but coordinates weren't stored
            if (!coordinatesToRestore && this.controller.canvas && 
                this.controller.canvas.width > 0 && this.controller.canvas.height > 0) {
              // console.log('🎨 [FILTER] Plot is visible but no coordinates - checking if we can infer from renderer...') */
              // If renderer has positions, we can restore coordinates from them
              if (this.controller.reglRenderer && this.controller.reglRenderer.positions && 
                  this.controller.reglRenderer.positions.length > 0) {
                const numPoints = this.controller.reglRenderer.positions.length / 2
                // console.log(`🎨 [FILTER] Found ${numPoints} points in renderer positions - restoring coordinates...`) */
                // Create coordinates from positions (they're in screen space, but we can use them)
                coordinatesToRestore = new Array(numPoints)
                for (let i = 0; i < numPoints; i++) {
                  coordinatesToRestore[i] = [
                    this.controller.reglRenderer.positions[i * 2],
                    this.controller.reglRenderer.positions[i * 2 + 1]
                  ]
                }
                // console.log(`🎨 [FILTER] Restored ${coordinatesToRestore.length} coordinates from renderer positions`) */
              }
            }
            
            // If still no coordinates, check if controller has coordinates stored from a previous render
            if (!coordinatesToRestore) {
              // console.log('🎨 [FILTER] No coordinates in cache, metadataData, or renderer positions - checking if controller has coordinates stored...') */
              
              // Last resort: Check if controller has coordinates stored from a previous render
              // Even if renderer state is lost, controller might still have coordinates
              if (this.controller.currentCoordinates && this.controller.currentCoordinates.length > 0) {
                // console.log('🎨 [FILTER] Found coordinates in controller.currentCoordinates:', this.controller.currentCoordinates.length) */
                coordinatesToRestore = this.controller.currentCoordinates
              } else {
                // Check if plot is visible (canvas exists) - this means an embedding WAS loaded at some point
                const plotIsVisible = this.controller.canvas && 
                                    this.controller.canvas.width > 0 && 
                                    this.controller.canvas.height > 0 &&
                                    this.controller.canvas.parentElement &&
                                    this.controller.canvas.parentElement.offsetWidth > 0
                
                console.error('❌ [FILTER] CRITICAL ERROR: Renderer has lost its state!')
                console.error('❌ [FILTER] Renderer instance:', this.controller.reglRenderer?.instanceId || 'unknown')
                if (this.controller.reglRenderer?.createdAt) {
                  const ageMs = Date.now() - this.controller.reglRenderer.createdAt
                  const ageSec = (ageMs / 1000).toFixed(1)
                  console.error('❌ [FILTER] Renderer was created:', this.controller.reglRenderer.createdAtTime, `(${ageSec}s ago)`)
                }
                console.error('❌ [FILTER] Renderer state:', {
                  numPoints: this.controller.reglRenderer?.numPoints || 0,
                  hasPositions: !!this.controller.reglRenderer?.positions,
                  positionsLength: this.controller.reglRenderer?.positions?.length || 0,
                  hasColors: !!this.controller.reglRenderer?.colors,
                  colorsLength: this.controller.reglRenderer?.colors?.length || 0,
                  hasCurrentCoordinates: false,
                  currentCoordinatesLength: 0,
                  hasDisplayOrder: false,
                  displayOrderLength: 0,
                  hasMetadataData: !!this.controller.metadataData,
                  metadataDataName: this.controller.metadataData?.name,
                  cacheSize: this.controller.decompressedCoordinatesCache?.size || 0,
                  plotIsVisible: plotIsVisible
                })
                
                // Provide specific guidance based on the state
                if (!this.controller.metadataData) {
                  console.error('❌ [FILTER] ROOT CAUSE: No embedding has been loaded!')
                  console.error('❌ [FILTER] The renderer was created during page initialization but never initialized with coordinates')
                  console.error('❌ [FILTER] SOLUTION: Load an embedding from the dropdown menu before filtering by gene expression')
                  console.error('❌ [FILTER] NOTE: Gene expression filtering requires an embedding to be loaded first')
                } else if (plotIsVisible) {
                  console.error('❌ [FILTER] ROOT CAUSE: Plot is visible but renderer state was lost!')
                  console.error('❌ [FILTER] This suggests the renderer was recreated or state was cleared')
                  console.error('❌ [FILTER] Embedding data exists but coordinates were not restored')
                  console.error('❌ [FILTER] This may be a bug - please report this issue')
                } else {
                  console.error('❌ [FILTER] ROOT CAUSE: Renderer was created but never initialized with coordinates')
                  console.error('❌ [FILTER] Embedding data exists but renderer state is missing')
                  console.error('❌ [FILTER] This suggests initializeScatterPlot() was never called or failed')
                }
                
                console.error('❌ [FILTER] The plot will not update - please reload the page or load an embedding')
                console.error('❌ [FILTER] Call stack when error was detected:')
                console.trace('❌ [FILTER] Renderer state loss detection')
                return
              }
            }
            
            if (coordinatesToRestore && coordinatesToRestore.length > 0) {
              // console.log('🎨 [FILTER] Restoring coordinates and re-rendering plot...') */
              this.controller.currentCoordinates = coordinatesToRestore
              await this.controller.renderScatterPlot(coordinatesToRestore)
              // console.log('🎨 [FILTER] Coordinates restored, proceeding with visibility update') */
              // After restoring, we now have renderer state, so continue with the update below
              // Don't return - fall through to the visibility update code
            } else {
              console.error('❌ [FILTER] CRITICAL ERROR: Cannot restore renderer state!')
              console.error('❌ [FILTER] - Cache is empty')
              console.error('❌ [FILTER] - currentCoordinates missing')
              console.error('❌ [FILTER] - Cannot decompress from metadataData')
              console.error('❌ [FILTER] - Renderer has no state (numPoints:', this.controller.reglRenderer?.numPoints || 0, ')')
              console.error('❌ [FILTER] The plot will not update - please reload the page or load an embedding')
              return
            }
          }
        } else {
          // Renderer not ready and no coordinates available - skip visualization update
          // console.log('🎨 [FILTER] Skipping visualization update - renderer not ready and no coordinates available') */
          // console.log('🎨 [FILTER] State:', {
           // hasRenderer: !!this.controller.reglRenderer,
           // hasCanvas: hasCanvas,
           // hasCoordinatesInController: hasCoordinatesInController,
           // hasCoordinatesInCache: hasCoordinatesInCache,
           // hasMetadataData: hasMetadataData
           // }) */
          return
        }
      }
      
      // If no filters are active, we are not forcing a color update,
      // AND the filter mode didn't just change (e.g. from filtered to unfiltered),
      // skip the visibility pipeline entirely.
      if (!hasFilterNow && !shouldUpdateColors && !filterModeChanged) {
        if (perfEnabled) {
          this.controller.logPerf('pipeline_performCellFiltering_rafSkip', performance.now() - rafStart, {
            readinessMs: Number((performance.now() - readinessStart).toFixed(2)),
            reason: 'no-filter-no-color-update'
          })
        }
        return
      }

      // If we need to update colors (e.g., color range adapted), render colors first
      if (shouldUpdateColors && this.controller.currentMetadataVector) {
        const colorStart = perfEnabled ? performance.now() : 0
        this.controller.renderPointsWithCurrentColoring()
        if (perfEnabled) {
          this.controller.logPerf('pipeline_performCellFiltering_rafColoring', performance.now() - colorStart, {
            metadataId: this.controller.currentMetadataVector?.id ?? null
          })
        }
      } else {
        const visibilityStart = perfEnabled ? performance.now() : 0
        await this.controller.updatePointVisibility(filteredIndices)
        if (perfEnabled) {
          this.controller.logPerf('pipeline_performCellFiltering_rafVisibility', performance.now() - visibilityStart, {
            filteredCount: filteredIndices ? filteredIndices.length : null
          })
        }
      }
      
      // Re-render category labels after filtering (ReGL mode only)
      // Labels need to move to new centroids of visible cells
      if (this.controller.rendererType === 'regl' && (this.controller.currentMetadataVector?.data_type === 'DISCRETE' || this.controller.currentMetadataVector?.data_type === 'STRING')) {
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked) {
          // console.log('🏷️ Re-rendering category labels after filtering (centroids may have moved)') */
          // Clear and redraw overlay to ensure old labels are removed
          this.controller.rendererManager.renderGrid()
          this.controller.rendererManager.renderAxes()
          this.controller.rendererManager.renderCategoryLabels()
        }
      }
      
      // Refresh 2D plot if open (filtering may have changed which points are visible)
      this.controller.customPlotManager.refresh2DPlotIfOpen()

      if (perfEnabled) {
        this.controller.logPerf('pipeline_performCellFiltering_rafDone', performance.now() - rafStart, {
          shouldUpdateColors: !!shouldUpdateColors,
          hasFilterNow,
          filterModeChanged
        })
      }
    })
  }

  // Incremental filtering - much faster for small changes
  getIncrementalFilteredIndices() {
    if (this.controller.globalFiltersEnabled === false) {
      this.controller.currentVisibleMask = null
      return null
    }
    
    const hasDiscreteSelections = this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0
    const hasContinuousSelections = this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0
    
    if (!hasDiscreteSelections && !hasContinuousSelections) {
      this.controller.currentVisibleMask = null
      return null
    }

    // Get all metadata that have actual constraining selections AND have loaded vectors (categorical)
    const discreteMetadataWithSelections = hasDiscreteSelections 
      ? Object.keys(this.controller.selectedCategories).filter(metadataId => {
      const selections = this.controller.selectedCategories[metadataId]
      if (!selections) {
        return false
      }
      if (!this.hasUsableMetadataVectorValues(metadataId)) {
        return false
      }
      
      return this.isDiscreteSelectionConstraining(metadataId, selections)
    })
      : []
    
    // Get all metadata that have constraining range selections AND have loaded vectors (continuous)
    const continuousMetadataWithSelections = hasContinuousSelections
      ? Object.keys(this.controller.selectedRanges).filter(metadataId => {
          const range = this.controller.selectedRanges[metadataId]
          const hasRange = range && (range.min !== undefined && range.max !== undefined)
          if (!hasRange || !this.hasUsableMetadataVectorValues(metadataId)) return false
          return this.isContinuousSelectionConstraining(metadataId, range)
        })
      : []

    // Combine both types of metadata with selections
    const metadataWithSelections = [...new Set([...discreteMetadataWithSelections, ...continuousMetadataWithSelections])]

    if (metadataWithSelections.length === 0) {
      this.controller.currentVisibleMask = null
      return null
    }

    // Create current filter state
    const currentFilterState = this.controller.createFilterCacheKey()
    
    // If this is the same as last state, return current visible cells
    if (this.controller.lastFilterState === currentFilterState && this.controller.currentVisibleCells) {
      this.ensureVisibleMask(this.controller.currentVisibleCells)
      return this.controller.currentVisibleCells
    }

    // If we have no current visible cells, do full calculation
    if (!this.controller.currentVisibleCells) {
      const result = this.getFilteredCellIndices()
      this.controller.lastFilterState = currentFilterState
      return result
    }

    // Try incremental update
    const incrementalResult = this.tryIncrementalUpdate(metadataWithSelections)
    if (incrementalResult !== null) {
      this.syncVisibleMaskFromIndices(incrementalResult)
      this.controller.lastFilterState = currentFilterState
      return incrementalResult
    }

    // Fall back to full calculation
    const result = this.getFilteredCellIndices()
    this.controller.lastFilterState = currentFilterState
    return result
  }

  // Try to do an incremental update
  tryIncrementalUpdate(metadataWithSelections) {
    // For now, let's implement a simple case: single metadata changes
    if (metadataWithSelections.length === 1) {
      const metadataId = metadataWithSelections[0]
      // console.log(`Single metadata incremental filtering for ${metadataId}`)
      // Use getCellsForMetadata which handles both discrete and continuous metadata
      return this.controller.getCellsForMetadata(metadataId)
    }

    // For multiple metadata, we could implement more sophisticated logic
    // For now, return null to trigger full calculation
    return null
  }

  // Update current selection to only include cells that are currently visible (not filtered out)
  updateSelectionBasedOnFiltering(filteredIndices) {
    if (!this.controller.selectedCells || this.controller.selectedCells.size === 0) {
      return
    }

    if (!filteredIndices) {
      return
    }

    const visibleMask = this.ensureVisibleMask(filteredIndices)
    const filteredSelection = new Set()
    this.controller.selectedCells.forEach(cellId => {
      if (visibleMask && visibleMask[cellId]) {
        filteredSelection.add(cellId)
      }
    })

    this.controller.selectedCells = filteredSelection
    this.controller.uiManager.updateSelectedCellsCount()
    this.controller.updateSelectedPointColors()
  }

  scheduleFilterSidebarRefresh() {
    if (this._filterSidebarRefreshTimer) {
      clearTimeout(this._filterSidebarRefreshTimer)
    }
    this._filterSidebarRefreshTimer = setTimeout(() => {
      this._filterSidebarRefreshTimer = null
      const perfEnabled = this.controller.perfLoggingEnabled?.() === true
      const t0 = perfEnabled ? performance.now() : 0
      this.controller.uiManager.updateSidebarCategoryCounts()
      this.controller.uiManager.updateAllRangeSliderCounts()
      this.updateAllCategoryDistributions()
      this.redrawAllDensityPlots()
      if (perfEnabled) {
        this.controller.logPerf('pipeline_filterSidebarRefresh', performance.now() - t0, {})
      }
    }, 32)
  }

  // Get the intersection of selected cells across all metadata (full calculation)
  getFilteredCellIndices() {
    if (this.controller.globalFiltersEnabled === false) {
      this.controller.lastFilteredIndices = null
      this.controller.lastFilterStateHash = null
      this.controller.currentVisibleMask = null
      return null
    }
    
    // Performance optimization: check if filter state has changed
    const currentFilterHash = this.getFilterStateHash()
    
    if (this.controller.lastFilterStateHash === currentFilterHash && this.controller.lastFilteredIndices !== undefined) {
      this.ensureVisibleMask(this.controller.lastFilteredIndices)
      return this.controller.lastFilteredIndices
    }
    
    const startTime = performance.now()
    const hasDiscreteSelections = this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0
    const hasContinuousSelections = this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0
    
    if (!hasDiscreteSelections && !hasContinuousSelections) {
      this.controller.lastFilteredIndices = null
      this.controller.lastFilterStateHash = currentFilterHash
      this.controller.currentVisibleMask = null
      return null
    }

    // Create cache key from current selections
    const cacheKey = this.controller.createFilterCacheKey()
    if (this.controller.filterCache.has(cacheKey)) {
      const cached = this.controller.filterCache.get(cacheKey)
      this.syncVisibleMaskFromIndices(cached)
      return cached
    }

    const discreteMetadataWithConstraints = Object.keys(this.controller.selectedCategories).filter(metadataId => {
      const selections = this.controller.selectedCategories[metadataId]
      if (!selections || !this.hasUsableMetadataVectorValues(metadataId)) {
        return false
      }

      return this.isDiscreteSelectionConstraining(metadataId, selections)
    })

    const continuousMetadataWithConstraints = Object.keys(this.controller.selectedRanges).filter(metadataId => {
      const range = this.controller.selectedRanges[metadataId]
      const hasRange = range && (range.min !== undefined && range.max !== undefined)
      if (!hasRange || !this.hasUsableMetadataVectorValues(metadataId)) return false

      return this.isContinuousSelectionConstraining(metadataId, range)
    })

    const allMetadataWithConstraints = [...new Set([...discreteMetadataWithConstraints, ...continuousMetadataWithConstraints])]

    if (allMetadataWithConstraints.length === 0) {
      this.controller.lastFilteredIndices = null
      this.controller.lastFilterStateHash = currentFilterHash
      this.controller.currentVisibleMask = null
      return null
    }

    const cellCount = this.getFilterUniverseSize(allMetadataWithConstraints)
    if (!cellCount || cellCount <= 0) {
      this.controller.lastFilteredIndices = null
      this.controller.lastFilterStateHash = currentFilterHash
      this.controller.currentVisibleMask = null
      return null
    }

    // Intersect constraints with Uint8Array masks — avoids building huge Sets of indices.
    let resultMask = null
    for (let i = 0; i < allMetadataWithConstraints.length; i++) {
      const metadataId = allMetadataWithConstraints[i]
      const constraintMask = this.buildConstraintMask(metadataId, cellCount)
      if (!constraintMask) {
        console.warn(`FILTERING ISSUE: metadata ${metadataId} has no usable values; skipping this constraint`)
        continue
      }
      if (!resultMask) {
        resultMask = constraintMask
      } else {
        for (let cell = 0; cell < cellCount; cell++) {
          if (resultMask[cell] !== 0 && constraintMask[cell] === 0) {
            resultMask[cell] = 0
          }
        }
      }
    }

    if (!resultMask) {
      this.controller.lastFilteredIndices = null
      this.controller.lastFilterStateHash = currentFilterHash
      this.controller.currentVisibleMask = null
      return null
    }

    this.controller.currentVisibleMask = resultMask
    const filteredIndices = this.maskToIndices(resultMask)

    this.controller.filterCache.set(cacheKey, filteredIndices)
    this.controller.lastFilteredIndices = filteredIndices
    this.controller.lastFilterStateHash = currentFilterHash

    const totalTime = performance.now() - startTime
    if (this.controller.perfLoggingEnabled?.() === true) {
      this.controller.logPerf('pipeline_getFilteredCellIndices', totalTime, {
        cellCount,
        constraintCount: allMetadataWithConstraints.length,
        filteredCount: filteredIndices.length
      })
    }

    return filteredIndices
  }

  getFilterUniverseSize(metadataIds = null) {
    if (Array.isArray(this.controller.currentCoordinates) && this.controller.currentCoordinates.length > 0) {
      return this.controller.currentCoordinates.length
    }
    if (this.controller.reglRenderer?.numPoints > 0) {
      return this.controller.reglRenderer.numPoints
    }
    if (this.controller.numPoints > 0) {
      return this.controller.numPoints
    }
    const ids = metadataIds || [
      ...Object.keys(this.controller.selectedCategories || {}),
      ...Object.keys(this.controller.selectedRanges || {})
    ]
    for (let i = 0; i < ids.length; i++) {
      const vector = this.getMetadataVectorById(ids[i])
      if (vector?.values?.length) return vector.values.length
    }
    return 0
  }

  buildConstraintMask(metadataId, cellCount) {
    if (this.controller.selectedCategories[metadataId] !== undefined) {
      return this.buildDiscreteConstraintMask(metadataId, cellCount)
    }
    if (this.controller.selectedRanges[metadataId]) {
      return this.buildContinuousConstraintMask(metadataId, cellCount, this.controller.selectedRanges[metadataId])
    }
    return null
  }

  buildDiscreteConstraintMask(metadataId, cellCount) {
    const metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector?.values) return null
    const values = metadataVector.values
    const selectedCodes = this.codesMatchingLabels(metadataVector, this.controller.selectedCategories[metadataId])
    const labels = this.getCategoryLabels(metadataVector)
    const lookupSize = Array.isArray(labels) ? labels.length : 0
    const codeLookup = lookupSize > 0 ? new Uint8Array(lookupSize) : null
    if (codeLookup) {
      selectedCodes.forEach((code) => {
        if (code >= 0 && code < codeLookup.length) codeLookup[code] = 1
      })
    }
    const mask = new Uint8Array(cellCount)
    const len = Math.min(cellCount, values.length)
    if (codeLookup) {
      for (let index = 0; index < len; index++) {
        const code = values[index]
        if (code >= 0 && code < codeLookup.length && codeLookup[code]) {
          mask[index] = 1
        }
      }
    } else {
      for (let index = 0; index < len; index++) {
        if (selectedCodes.has(values[index])) mask[index] = 1
      }
    }
    return mask
  }

  buildContinuousConstraintMask(metadataId, cellCount, range) {
    const metadataVector = this.getMetadataVectorById(metadataId)
    if (!metadataVector?.values) return null
    const values = metadataVector.values
    const min = range.min
    const max = range.max
    const mask = new Uint8Array(cellCount)
    const len = Math.min(cellCount, values.length)
    for (let index = 0; index < len; index++) {
      const value = values[index]
      if (value >= min && value <= max) mask[index] = 1
    }
    return mask
  }

  maskToIndices(mask) {
    let count = 0
    for (let i = 0; i < mask.length; i++) {
      if (mask[i]) count++
    }
    const indices = new Array(count)
    let j = 0
    for (let i = 0; i < mask.length; i++) {
      if (mask[i]) indices[j++] = i
    }
    return indices
  }

  syncVisibleMaskFromIndices(filteredIndices) {
    if (!filteredIndices) {
      this.controller.currentVisibleMask = null
      return null
    }
    let cellCount = this.getFilterUniverseSize()
    if (!cellCount) {
      let maxIdx = -1
      for (let i = 0; i < filteredIndices.length; i++) {
        const idx = filteredIndices[i]
        if (idx > maxIdx) maxIdx = idx
      }
      cellCount = maxIdx + 1
    }
    if (!cellCount) {
      this.controller.currentVisibleMask = null
      return null
    }
    const mask = new Uint8Array(cellCount)
    for (let i = 0; i < filteredIndices.length; i++) {
      const idx = filteredIndices[i]
      if (idx >= 0 && idx < cellCount) mask[idx] = 1
    }
    this.controller.currentVisibleMask = mask
    return mask
  }

  ensureVisibleMask(filteredIndices = this.controller.currentVisibleCells) {
    if (!filteredIndices) {
      this.controller.currentVisibleMask = null
      return null
    }
    const existing = this.controller.currentVisibleMask
    const cellCount = this.getFilterUniverseSize()
    if (existing && (!cellCount || existing.length === cellCount)) {
      return existing
    }
    return this.syncVisibleMaskFromIndices(filteredIndices)
  }

  // Clean up stale selections for metadata that are no longer loaded
  cleanupStaleSelections() {
    // Clean up selectedCategories
    const staleCategories = Object.keys(this.controller.selectedCategories).filter(metadataId => {
      return !this.controller.loadedMetadataVectors[metadataId]
    })
    
    staleCategories.forEach(metadataId => {
      // console.log(`🧹 Cleaning up stale category selections for metadata ${metadataId}`) */
      delete this.controller.selectedCategories[metadataId]
    })
    
    // Clean up selectedRanges  
    const staleRanges = Object.keys(this.controller.selectedRanges).filter(metadataId => {
      return !this.controller.loadedMetadataVectors[metadataId]
    })
    
    staleRanges.forEach(metadataId => {
      // console.log(`🧹 Cleaning up stale range selections for metadata ${metadataId}`) */
      delete this.controller.selectedRanges[metadataId]
    })
    
    if (staleCategories.length > 0 || staleRanges.length > 0) {
      // console.log(`🧹 Cleaned up ${staleCategories.length} stale category selections and ${staleRanges.length} stale range selections`) */
    }
  }

  // Calculate which metadata currently contribute active filtering constraints
  collectFilterConstraints() {
    const result = {
      discrete: [],
      continuous: []
    }
    
    if (this.controller.selectedCategories) {
      Object.keys(this.controller.selectedCategories).forEach(metadataId => {
        const selections = this.controller.selectedCategories[metadataId]
        if (!selections) {
          return
        }
        if (this.isDiscreteSelectionConstraining(metadataId, selections)) {
          result.discrete.push(metadataId)
        }
      })
    }
    
    if (this.controller.selectedRanges) {
      Object.keys(this.controller.selectedRanges).forEach(metadataId => {
        const range = this.getSelectedRange(metadataId)
        if (!range || range.min === undefined || range.max === undefined) {
          return
        }
        if (this.isContinuousSelectionConstraining(metadataId, range)) {
          result.continuous.push(metadataId)
        }
      })
    }
    
    return result
  }

  getDiscreteCategoryUniverse(metadataId, metadataVector = null) {
    const vector = metadataVector || (
      this.controller.loadedMetadataVectors
        ? (this.controller.loadedMetadataVectors[metadataId] || this.controller.loadedMetadataVectors[String(metadataId)])
        : null
    )

    if (vector?.compression_info?.categories && Array.isArray(vector.compression_info.categories) && vector.compression_info.categories.length > 0) {
      return vector.compression_info.categories.map((category) => String(category))
    }
    if (vector?.compression_info?.single_category) {
      const categories = Array.isArray(vector.compression_info.categories)
        ? vector.compression_info.categories
        : []
      return categories.map((category) => String(category))
    }
    if (vector?.values) {
      const labels = this.getCategoryLabels(vector)
      if (!labels) {
        throw new Error(`Discrete metadata ${metadataId} has values but no compression_info.categories`)
      }
      // values are category codes — map unique codes to labels
      const observed = []
      const seen = new Set()
      const codes = vector.values
      for (let i = 0; i < codes.length; i++) {
        const code = codes[i]
        if (seen.has(code)) continue
        seen.add(code)
        observed.push(String(labels[code]))
      }
      return observed
    }

    const metadataElement = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataElement) return null

    const fromDomCheckboxes = Array.from(
      metadataElement.querySelectorAll(`.category-checkbox[data-metadata-id="${metadataId}"][data-category]`)
    ).map((el) => String(el.dataset.category || '')).filter((value) => value.length > 0)
    if (fromDomCheckboxes.length > 0) {
      return Array.from(new Set(fromDomCheckboxes))
    }

    return null
  }

  // Categories that actually appear on cells. Used to decide if a selection filters any cells.
  // Prefer this over nber_cats / compression length: a "full" unique-value selection is not a filter
  // even when compression lists extra zero-count categories.
  getObservedDiscreteCategories(metadataId, metadataVector = null) {
    const vector = metadataVector || (
      this.controller.loadedMetadataVectors
        ? (this.controller.loadedMetadataVectors[metadataId] || this.controller.loadedMetadataVectors[String(metadataId)])
        : null
    )
    if (vector?.values) {
      if (Array.isArray(vector._observedCategories)) {
        return vector._observedCategories
      }
      const labels = this.getCategoryLabels(vector)
      if (!labels) {
        throw new Error(`Discrete metadata ${metadataId} has values but no compression_info.categories`)
      }
      const observed = []
      const seen = new Set()
      const codes = vector.values
      const labelCount = labels.length
      for (let i = 0; i < codes.length; i++) {
        const code = codes[i]
        if (seen.has(code)) continue
        seen.add(code)
        observed.push(String(labels[code]))
        // All category codes observed — no need to scan remaining cells.
        if (seen.size >= labelCount) break
      }
      vector._observedCategories = observed
      return observed
    }
    return null
  }

  // Continuous slider / filter extents. Prefer compression_info (O(1)); fall back to one cached scan.
  getContinuousValueExtents(metadataId, metadataVector = null) {
    const vector = metadataVector || (
      this.controller.loadedMetadataVectors
        ? (this.controller.loadedMetadataVectors[metadataId] || this.controller.loadedMetadataVectors[String(metadataId)])
        : null
    )
    if (!vector || !vector.values) return null

    const info = vector.compression_info
    if (
      info &&
      Number.isFinite(Number(info.min_val)) &&
      Number.isFinite(Number(info.max_val))
    ) {
      return { min: Number(info.min_val), max: Number(info.max_val) }
    }

    if (
      vector._valueExtents &&
      Number.isFinite(vector._valueExtents.min) &&
      Number.isFinite(vector._valueExtents.max)
    ) {
      return vector._valueExtents
    }

    const min = this.safeMin(vector.values)
    const max = this.safeMax(vector.values)
    if (!Number.isFinite(min) || !Number.isFinite(max)) return null
    vector._valueExtents = { min, max }
    return vector._valueExtents
  }

  getDiscreteCategoryUniverseSize(metadataId) {
    const universe = this.getDiscreteCategoryUniverse(metadataId)
    if (Array.isArray(universe) && universe.length > 0) {
      return universe.length
    }
    return null
  }

  hasUsableMetadataVectorValues(metadataId) {
    const vector = this.getMetadataVectorById(metadataId)
    return !!(vector && vector.values)
  }

  isDiscreteSelectionConstraining(metadataId, selections = null) {
    const selected = selections || this.controller.selectedCategories?.[metadataId]
    if (!selected) return false
    if (selected.size === 0) return true

    const selectedSet = new Set(Array.from(selected).map(String))
    const observed = this.getObservedDiscreteCategories(metadataId)
    if (Array.isArray(observed) && observed.length > 0) {
      return !observed.every((category) => selectedSet.has(String(category)))
    }

    // Without observed values, only treat as a filter when we know the full checkbox universe
    // and the selection does not cover it. Do not use data-categories-count alone: unique-value
    // initializations are smaller than nber_cats and would flash as fake filters on reload.
    const universe = this.getDiscreteCategoryUniverse(metadataId)
    if (!Array.isArray(universe) || universe.length === 0) return false
    return !universe.every((category) => selectedSet.has(String(category)))
  }

  isContinuousSelectionConstraining(metadataId, range = null) {
    const selectedRange = range || this.getSelectedRange(metadataId)
    if (!selectedRange || selectedRange.min === undefined || selectedRange.max === undefined) return false
    if (!Number.isFinite(Number(selectedRange.min)) || !Number.isFinite(Number(selectedRange.max))) return false

    const extents = this.getContinuousValueExtents(metadataId)
    if (!extents) return false

    return !this.isContinuousRangeFullCoverage(
      selectedRange.min,
      selectedRange.max,
      extents.min,
      extents.max
    )
  }

  // Shared tolerance for "full range" decisions (slider UI, selectedRanges, global filter tool).
  // Must stay consistent: a green "full range" checkbox must not leave a ghost filter in the tool.
  getContinuousRangeEpsilon(minVal, maxVal) {
    const span = Math.abs(Number(maxVal) - Number(minVal))
    if (!Number.isFinite(span) || span <= 0) return 1e-12
    return Math.max(span * 0.001, 1e-12)
  }

  isContinuousRangeFullCoverage(rangeMin, rangeMax, fullMin, fullMax) {
    if (![rangeMin, rangeMax, fullMin, fullMax].every((v) => Number.isFinite(Number(v)))) return false
    const epsilon = this.getContinuousRangeEpsilon(fullMin, fullMax)
    return Number(rangeMin) <= Number(fullMin) + epsilon && Number(rangeMax) >= Number(fullMax) - epsilon
  }

  getSelectedRange(metadataId) {
    if (!this.controller.selectedRanges || metadataId == null || metadataId === '') return null
    const id = String(metadataId)
    if (this.controller.selectedRanges[id] != null) return this.controller.selectedRanges[id]
    const asNum = Number(id)
    if (Number.isFinite(asNum) && this.controller.selectedRanges[asNum] != null) {
      return this.controller.selectedRanges[asNum]
    }
    return null
  }

  clearSelectedRange(metadataId) {
    if (!this.controller.selectedRanges || metadataId == null || metadataId === '') return false
    const id = String(metadataId)
    let cleared = false
    Object.keys(this.controller.selectedRanges).forEach((key) => {
      if (String(key) === id) {
        delete this.controller.selectedRanges[key]
        cleared = true
      }
    })
    if (cleared) this.controller.markCheckpointMatchDirty?.()
    return cleared
  }

  setSelectedRange(metadataId, range) {
    if (metadataId == null || metadataId === '' || !range) return
    const id = String(metadataId)
    if (!this.controller.selectedRanges) this.controller.selectedRanges = {}
    this.clearSelectedRange(id)
    this.controller.selectedRanges[id] = {
      min: Number(range.min),
      max: Number(range.max)
    }
    this.controller.markCheckpointMatchDirty?.()
  }

  // Count how many metadata have filtering constraints, regardless of global toggle state
  getDefinedFilterCount() {
    const { discrete, continuous } = this.collectFilterConstraints()
    return discrete.length + continuous.length
  }
  
  // Count active filters taking the global toggle into account
  getActiveFilterCount() {
    if (this.controller.globalFiltersEnabled === false) {
      return 0
    }
    
    return this.getDefinedFilterCount()
  }
  
  // Provide a lightweight summary of active filters for tooltips or diagnostics
  getFilterConstraintSummary() {
    const { discrete, continuous } = this.collectFilterConstraints()
    
    return {
      discrete,
      continuous,
      total: discrete.length + continuous.length
    }
  }

  getFilterDetails() {
    const details = []
    const { discrete, continuous } = this.collectFilterConstraints()
    const filtersEnabled = this.controller.globalFiltersEnabled !== false
    
    const formatNumber = value => {
      if (value === undefined || value === null || Number.isNaN(value)) {
        return '—'
      }
      
      if (Math.abs(value) >= 1000 || Math.abs(value) < 0.01) {
        return Number(value).toExponential(2)
      }
      
      return Number(value).toFixed(3).replace(/\.?0+$/, '')
    }
    
    const resolveName = metadataId => {
      return this.getMetadataNameById(metadataId) ||
             this.controller.loadedMetadataVectors?.[metadataId]?.name ||
             `Metadata ${metadataId}`
    }
    
    discrete.forEach(metadataId => {
      const selections = this.controller.selectedCategories?.[metadataId]
      const selectedValues = selections ? Array.from(selections) : []
      const allCategories = this.getDiscreteCategoryUniverse(metadataId)
      let totalCategories = Array.isArray(allCategories) && allCategories.length > 0
        ? allCategories.length
        : this.getDiscreteCategoryUniverseSize(metadataId)
      
      let summaryMode = 'selected'
      let summaryCount = selectedValues.length
      let summaryList = selectedValues
      
      if (totalCategories !== null) {
        const unselectedCount = totalCategories - selectedValues.length
        if (unselectedCount < selectedValues.length) {
          summaryMode = 'unselected'
          summaryCount = unselectedCount
          if (allCategories) {
            const selectedSet = new Set(selectedValues)
            summaryList = allCategories.filter(cat => !selectedSet.has(cat))
          } else {
            summaryList = []
          }
        }
      }

      const item = {
        metadataId,
        type: 'categorical',
        name: resolveName(metadataId),
        selectedCount: selectedValues.length,
        totalCount: totalCategories,
        summaryMode,
        summaryCount,
        summaryValues: summaryList ? summaryList.slice(0, 6) : [],
        hiddenValueCount: summaryList ? Math.max(summaryList.length - 6, 0) : 0,
        isEmptySelection: selectedValues.length === 0,
        active: filtersEnabled
      }
      
      details.push(item)
    })
    
    continuous.forEach(metadataId => {
      const range = this.controller.selectedRanges?.[metadataId]
      if (!range) return
      
      const metadataVector = this.controller.loadedMetadataVectors?.[metadataId]
      let minVal = null
      let maxVal = null
      
      if (metadataVector && metadataVector.values) {
        minVal = this.safeMin(metadataVector.values)
        maxVal = this.safeMax(metadataVector.values)
      }
      
      details.push({
        metadataId,
        type: 'continuous',
        name: resolveName(metadataId),
        range: {
          min: range.min,
          max: range.max,
          formattedMin: formatNumber(range.min),
          formattedMax: formatNumber(range.max)
        },
        fullRange: {
          min: minVal,
          max: maxVal,
          formattedMin: minVal !== null ? formatNumber(minVal) : null,
          formattedMax: maxVal !== null ? formatNumber(maxVal) : null
        },
        active: filtersEnabled
      })
    })
    
    return details
  }

  // Get a summary of current filtering constraints
  getFilteringSummary() {
    if (!this.controller.selectedCategories || Object.keys(this.controller.selectedCategories).length === 0) {
      return null
    }

    const summary = []
    Object.keys(this.controller.selectedCategories).forEach(metadataId => {
      const selections = this.controller.selectedCategories[metadataId]
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
    const discreteCount = Object.keys(this.controller.selectedCategories || {}).length
    const continuousCount = Object.keys(this.controller.selectedRanges || {}).length
    
    // Convert Sets to Arrays for proper JSON serialization
    const selectedCategoriesForHash = {}
    if (this.controller.selectedCategories) {
      Object.keys(this.controller.selectedCategories).forEach(metadataId => {
        const set = this.controller.selectedCategories[metadataId]
        selectedCategoriesForHash[metadataId] = set ? Array.from(set).sort() : []
      })
    }
    
    return JSON.stringify({
      selectedCategories: selectedCategoriesForHash,
      selectedRanges: this.controller.selectedRanges,
      currentMetadataId: this.controller.currentMetadataId,
      discreteCount,
      continuousCount,
      globalFiltersEnabled: this.controller.globalFiltersEnabled !== false
    })
  }

  // Create a hash of the current color state for change detection
  getColorStateHash() {
    // Include gradient control points in hash so cache is invalidated when gradient changes
    const gradientPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    const gradientHash = gradientPoints ? JSON.stringify(gradientPoints.map(p => ({ position: p.position, color: p.color }))) : null
    
    return JSON.stringify({
      currentMetadataId: this.controller.currentMetadataId,
      currentMetadataType: this.controller.currentMetadataVector?.data_type,
      discretePaletteId: this.controller.discretePaletteId,
      categoryOrder: this.controller.categoryOrder,
      customColorRange: this.controller.customColorRange,
      currentColorScheme: this.controller.currentColorScheme,
      filterGeneration: this.controller.filterGeneration || 0,
      selectionGeneration: this.controller.selectionGeneration || 0,
      gradientHash: gradientHash
    })
  }

  bumpFilterGeneration() {
    this.controller.filterGeneration = (this.controller.filterGeneration || 0) + 1
    this.controller.markCheckpointMatchDirty?.()
  }

  // Get total count for a category
  getTotalCountForCategory(categoryName) {
    if (!this.controller.currentMetadataVector || !this.controller.currentMetadataVector.values) {
      return 0
    }

    const vector = this.controller.currentMetadataVector
    const code = this.labelToCode(vector, categoryName)
    if (code < 0) return 0
    
    let count = 0
    const values = vector.values
    for (let i = 0; i < values.length; i++) {
      if (values[i] === code) {
        count++
      }
    }
    return count
  }

  // Get visible count for a category (considering current filtering)
  getVisibleCountForCategory(categoryName) {
    if (!this.controller.currentMetadataVector || !this.controller.currentMetadataVector.values) {
      return 0
    }
    
    // If no filtering is applied, return total count
    if (!this.controller.currentVisibleCells || this.controller.currentVisibleCells.length === this.controller.currentMetadataVector.values.length) {
      return this.getTotalCountForCategory(categoryName)
    }

    const vector = this.controller.currentMetadataVector
    const code = this.labelToCode(vector, categoryName)
    if (code < 0) return 0
    
    // Count visible cells for this category
    let visibleCount = 0
    const values = vector.values
    for (let i = 0; i < this.controller.currentVisibleCells.length; i++) {
      const cellIndex = this.controller.currentVisibleCells[i]
      if (values[cellIndex] === code) {
        visibleCount++
      }
    }
    
    return visibleCount
  }

  // Get metadata name by ID
  getMetadataNameById(metadataId) {
    const button = document.querySelector(`[data-metadata-id="${metadataId}"][data-metadata-name]`)
    return button ? button.dataset.metadataName : null
  }

  // Get metadata vector by ID (IDs may be number or string depending on source; cache keys must match).
  getMetadataVectorById (rawMetadataId) {
    if (rawMetadataId == null || rawMetadataId === '') return null

    const asNum = Number(rawMetadataId)
    const idsToTry = [rawMetadataId]
    if (Number.isFinite(asNum)) idsToTry.push(asNum)
    idsToTry.push(String(rawMetadataId))

    const currentId = this.controller.currentMetadataId
    const currentMatches =
      currentId === rawMetadataId ||
      (Number.isFinite(asNum) && currentId === asNum) ||
      String(currentId) === String(rawMetadataId)

    if (currentMatches && this.controller.currentMetadataVector) {
      this.controller.memoryManager.updateMetadataUsage(rawMetadataId)
      return this.controller.currentMetadataVector
    }

    const vecs = this.controller.loadedMetadataVectors
    if (!vecs) return null

    let cacheKey = null
    let vectorData = null
    for (let i = 0; i < idsToTry.length; i++) {
      const k = idsToTry[i]
      if (vecs[k] != null) {
        cacheKey = k
        vectorData = vecs[k]
        break
      }
    }
    if (!vectorData) return null

    this.controller.memoryManager.updateMetadataUsage(cacheKey)

    if (vectorData.values) {
      return vectorData
    }

    const isInvalidCompression = vectorData.compression_info &&
      typeof vectorData.compression_info === 'string' &&
      (vectorData.compression_info.includes('No categories available') ||
        vectorData.compression_info.includes('Failed to parse'))

    if (isInvalidCompression) {
      console.warn(`⚠️ [DataManager] Metadata ${rawMetadataId} has invalid compression_info: ${vectorData.compression_info}`)
      console.warn('⚠️ [DataManager] Removing from cache - will reload from server')
      delete vecs[cacheKey]
      return null
    }

    if (vectorData.compression_info && typeof vectorData.compression_info === 'object' &&
        (vectorData.compressed_data || vectorData.compression_info.single_category)) {
      try {
        let values
        if (vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING') {
          values = this.decompressDiscreteMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else if (vectorData.data_type === 'NUMERIC') {
          values = this.decompressContinuousMetadataVector(vectorData.compressed_data, vectorData.compression_info)
        } else {
          console.warn(`Unknown data type for metadata ${rawMetadataId}: ${vectorData.data_type}`)
          return null
        }

        const resolvedId = vectorData.id != null ? vectorData.id : (Number.isFinite(asNum) ? asNum : rawMetadataId)
        const decompressedVector = {
          id: resolvedId,
          name: vectorData.name,
          data_type: vectorData.data_type,
          values: values,
          compression_info: vectorData.compression_info
        }

        vecs[cacheKey] = decompressedVector
        return decompressedVector
      } catch (error) {
        console.error(`Error decompressing metadata vector ${rawMetadataId}:`, error)
        return null
      }
    }

    return vectorData
  }

  // Preload metadata vector on hover for better UX
  preloadMetadataVector(event) {
    if (window.ENABLE_METADATA_HOVER_PRELOAD !== true) {
      return
    }

    if (this.controller.isApplyingCheckpointState) {
      return
    }

    const button = event.currentTarget
    const metadataId = button.dataset.metadataId
    if (!metadataId) return
    
    // Debounce: Only preload if mouse stays on element for 300ms
    // This prevents UI lag when quickly moving mouse over items
    if (this.controller.preloadTimeout) {
      clearTimeout(this.controller.preloadTimeout)
    }
    
    this.controller.preloadTimeout = setTimeout(() => {
    // Only preload if not already loaded and not currently loading
    if (!this.controller.loadedMetadataVectors[metadataId] && !this.controller.loadingMetadataVectors.has(metadataId)) {
      // console.log(`🚀 Preloading metadata vector ${metadataId} on hover`) */
      // Load silently without showing spinners
      this.controller.loadSingleMetadataVectorSilently(metadataId).catch(error => {
        // console.log(`Preload failed for metadata ${metadataId}:`, error.message) */
        // Don't show error to user for preloading failures
      })
      }
    }, 1000) // 1000ms delay - only preload if user hovers for 1 second
  }
  
  // Cancel preload if user quickly moves away
  cancelPreload(event) {
    if (window.ENABLE_METADATA_HOVER_PRELOAD !== true) {
      return
    }

    if (this.controller.preloadTimeout) {
      clearTimeout(this.controller.preloadTimeout)
      this.controller.preloadTimeout = null
    }
  }

  // Extract current screen positions (coordinate extraction)
  extractCurrentScreenPositions(currentBounds, coordinateCount) {
    // Recreate positions from bounds and coordinates (no retained per-point draw objects)
    // console.log('Extracting current screen positions (recreating from bounds)')
    return currentBounds
  }

  // Get loaded metadata vector for a specific metadata ID
  getLoadedMetadataVector(metadataId) {
    if (!this.controller.loadedMetadataVectors) {
      // console.log('No metadata vectors loaded yet') */
      return null
    }
    
    const vectorData = this.controller.loadedMetadataVectors[metadataId]
    if (!vectorData) {
      // console.log(`No loaded vector found for metadata ID: ${metadataId}`) */
      return null
    }
    
    // console.log(`Retrieved loaded vector for ${vectorData.name}:`, vectorData.compression_info)
    return vectorData
  }

  // Store binary metadata data
  async storeBinaryMetadataData(data) {
    // Store the binary coordinate data for later use
    // The coordinates are stored as 16-bit signed integers in binary format
    // Each coordinate pair takes 4 bytes (2 bytes for x, 2 bytes for y)
    
    this.controller.metadataData = {
      id: data.id,
      name: data.name,
      cellCount: data.cellCount,
      binaryData: data.binaryData, // ArrayBuffer with binary data
      loadedAt: Date.now()
    }
    
    const binarySize = data.binaryData.byteLength
    const expectedSize = data.cellCount * 4 // 4 bytes per coordinate pair (2 coordinates * 2 bytes each)
    const compressionRatio = (data.cellCount * 2 * 8) / (binarySize * 8) // bits comparison
    
    // console.log(`Stored binary metadata data for ${data.name}:`, {
     // cellCount: data.cellCount,
     // binarySize: binarySize,
     // expectedSize: expectedSize,
     // compressionRatio: compressionRatio.toFixed(2) + 'x',
     // memoryEfficiency: ((1 - binarySize / (data.cellCount * 2 * 8)) * 100).toFixed(1) + '%'
     // })*/ */
    
    // Recalculate optimal buffer size now that we have cell count
    // This updates from the default (5) to the actual optimal size
    if (this.controller.maxMetadataInMemory <= 5) {
      const newBufferSize = this.controller.memoryManager.calculateOptimalBufferSize()
      if (newBufferSize > this.controller.maxMetadataInMemory) {
        // console.log(`🧠 [MEMORY] Recalculating buffer size with cell count ${data.cellCount.toLocaleString()}`) */
        // console.log(`🧠 [MEMORY] Updated buffer size: ${this.controller.maxMetadataInMemory} → ${newBufferSize} metadata vectors`) */
        this.controller.maxMetadataInMemory = newBufferSize
      }
    }
    
    // Check if there are active filters BEFORE rendering to avoid glitch
    const hasActiveFilters = (this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0) ||
                             (this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0)
    // console.log(`📊 [EMBEDDING] Active filters check (before render):`, {
     // hasSelectedCategories: !!(this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0),
     // hasSelectedRanges: !!(this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0),
     // hasActiveFilters: hasActiveFilters
     // }) */
    
    // Update visualization with the new coordinate data
    // console.log(`📊 [EMBEDDING] Updating visualization with new coordinates...`) */
    await this.updateVisualizationWithMetadata()
    // console.log(`📊 [EMBEDDING] Visualization updated, checking for active coloring and filters...`) */
    
    // IMPORTANT: Apply filters IMMEDIATELY after plot initialization to avoid glitch
    // Do this BEFORE coloring so filtered points are hidden from the start
    if (hasActiveFilters) {
      // console.log(`🔍 [EMBEDDING] Applying filters immediately after embedding switch (before coloring)...`) */
      // Calculate filtered indices synchronously
      const filteredIndices = this.getIncrementalFilteredIndices()
      
      // Update the current visible cells state immediately
      this.controller.currentVisibleCells = filteredIndices
    this.bumpFilterGeneration()
      
      // Update visualization synchronously to hide filtered points immediately
      // This prevents the glitch where all points are briefly visible
      if (this.controller.reglRenderer && this.controller.displayOrder && this.controller.displayOrder.length > 0) {
        const visibleSet = filteredIndices ? new Set(filteredIndices) : null
        const colorMap = new Map()
        
        // Hide filtered-out points immediately by setting their colors to transparent
        for (let drawPos = 0; drawPos < this.controller.displayOrder.length; drawPos++) {
          const cellIndex = this.controller.displayOrder[drawPos]
          const isVisible = !visibleSet || visibleSet.has(cellIndex)
          
          if (!isVisible) {
            // Hide filtered-out points immediately
            colorMap.set(drawPos, 0x00000000)
          } else {
            // Keep default color for visible points (will be updated by coloring next)
            colorMap.set(drawPos, 0x3b82f6)
          }
        }
        
        // Update colors synchronously to hide filtered points immediately
        this.controller.reglRenderer.updateColors(colorMap)
        this.controller.reglRenderer.render()
        // console.log(`🔍 [EMBEDDING] Filtered points hidden immediately (${filteredIndices ? filteredIndices.length : 'all'} visible)`) */
      }
      
      // Now do the full filtering update (which includes UI updates) asynchronously
      // This won't cause a glitch since we've already hidden the points
      this.performCellFilteringUpdate(false)
      // console.log(`🔍 [EMBEDDING] Filters applied immediately`) */
    } else {
      // console.log(`📊 [EMBEDDING] No active filters to reapply`) */
    }
    
    // If there's a currently active metadata vector (coloring), reapply it to the new embedding
    if (this.controller.currentMetadataVector && this.controller.currentMetadataId) {
      // console.log(`🎨 [EMBEDDING] Reapplying metadata coloring after embedding switch: ${this.controller.currentMetadataVector.name}`) */
      // console.log(`🎨 [EMBEDDING] Current metadata type: ${this.controller.currentMetadataVector.data_type}`) */
      // console.log(`🎨 [EMBEDDING] Display order length: ${this.controller.displayOrder?.length}`) */
      this.controller.updateVisualizationWithMetadataVector()
      // console.log(`🎨 [EMBEDDING] Coloring reapplied successfully`) */
    } else {
      // console.log(`📊 [EMBEDDING] No active coloring to reapply (currentMetadataVector: ${!!this.controller.currentMetadataVector}, currentMetadataId: ${this.controller.currentMetadataId})`) */
    }
    
    // If there are selected cells, update colors to show them on top
    // updateSelectedPointColors will handle reordering displayOrder
    // Use double requestAnimationFrame to ensure this happens after all rendering is complete
    if (this.controller.selectedCells && this.controller.selectedCells.size > 0) {
      // console.log(`📊 [EMBEDDING] Scheduling selected cells update after embedding switch (${this.controller.selectedCells.size} selected)`) */
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          // Double-check that renderer is still ready and selected cells still exist
          if (this.controller.reglRenderer && this.controller.displayOrder && 
              this.controller.selectedCells && this.controller.selectedCells.size > 0) {
            // console.log(`📊 [EMBEDDING] Updating selected cells display (${this.controller.selectedCells.size} selected)`) */
            this.controller.updateSelectedPointColors()
          }
        })
      })
    }
  }

  // Clear metadata data
  clearMetadataData() {
    this.controller.metadataData = null
    // console.log('Cleared metadata data')
    
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
  
  // Update category distribution bars for all visible (expanded) metadata sections
  updateAllCategoryDistributions() {
    const perfEnabled = this.controller.perfLoggingEnabled?.() === true
    const t0 = perfEnabled ? performance.now() : 0
    let drawn = 0
    let skipped = 0
    
    // Find all expanded metadata sections
    const expandedSections = document.querySelectorAll('[data-metadata-item]')
    
    expandedSections.forEach(section => {
      const metadataId = parseInt(section.dataset.metadataItem)
      
      // Check if this section is expanded by checking if the categories div is visible
      // (not by checking canvas visibility, as canvases might be hidden when no coloring is active)
      const header = section.querySelector('[data-action*="toggleMetadata"]')
      if (!header) {
        skipped += 1
        return
      }

      const categoriesDiv =
        section.querySelector('[style*="padding-left: 32px"]') || header.nextElementSibling
      if (!categoriesDiv || categoriesDiv.style.display === 'none') {
        // Section is not expanded, skip it
        skipped += 1
        return
      }
      
      // Section is expanded, update its distributions
      // This will show/hide canvases based on whether coloring is active
      const canvases = section.querySelectorAll('.category-distribution-canvas')
      
      if (canvases.length > 0) {
        this.controller.drawCategoryDistributions(metadataId)
        drawn += 1
      } else {
        skipped += 1
      }
    })

    if (typeof this.controller.drawSelectionDistribution === 'function') {
      this.controller.drawSelectionDistribution()
    }

    if (perfEnabled) {
      this.controller.logPerf('pipeline_updateAllCategoryDistributions', performance.now() - t0, {
        sectionCount: expandedSections.length,
        drawn,
        skipped
      })
    }
  }
  
  // Redraw all density plots (histograms in range sliders) to reflect filtered cells
  redrawAllDensityPlots() {
    // Find all range slider controllers and redraw their density plots
    const rangeSliderElements = document.querySelectorAll('[data-controller~="range-slider"]')
    rangeSliderElements.forEach(element => {
      const controller = this.controller.application?.getControllerForElementAndIdentifier(element, 'range-slider')
      if (controller && typeof controller.drawDensityPlot === 'function') {
        controller.drawDensityPlot()
      }
    })
  }
}
