/**
 * Data Manager Module
 * Handles data loading, decompression, and metadata management
 */

export class DataManager {
  constructor(controller) {
    this.controller = controller
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
        console.log(`  Coordinate ${i + 1}: [${int16View[idx]}, ${int16View[idx + 1]}] -> [${x}, ${y}]`)
      }
    }
    
    const decompressTime = performance.now() - decompressStart
    const pairsPerSec = Math.round(numPairs / decompressTime * 1000)
    
    console.log(`⏱️ [PERF] Binary decompression: ${numPairs.toLocaleString()} pairs in ${decompressTime.toFixed(2)}ms (${pairsPerSec.toLocaleString()} pairs/sec)`)
    console.log(`  Range: X[${xMin.toFixed(2)}, ${xMax.toFixed(2)}] Y[${yMin.toFixed(2)}, ${yMax.toFixed(2)}]`)
    
    return coordinates
  }



  // Metadata management
  getLoadedMetadataVector(metadataId) {
    return this.controller.getLoadedMetadataVector(metadataId)
  }


  // Data storage and caching
  storeBinaryMetadataData(data) {
    return this.controller.storeBinaryMetadataData(data)
  }

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

  logMemoryUsage(context = '') {
    return this.controller.memoryManager.logMemoryUsage(context)
  }

  checkMemoryHealth() {
    return this.controller.memoryManager.checkMemoryHealth()
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
    if (this.controller.rendererType === 'regl' && this.controller.currentCoordinates && values) {
      console.log(`🏷️ Using ReGL path with currentCoordinates (${this.controller.currentCoordinates.length} points)`)
      
      // Get visible cells for filtering
      const visibleSet = this.controller.currentVisibleCells ? new Set(this.controller.currentVisibleCells) : null
      let visiblePoints = 0
      let filteredPoints = 0
      
      // Iterate through all cells using their original indices
      for (let cellIndex = 0; cellIndex < this.controller.currentCoordinates.length; cellIndex++) {
        // Check if this cell is visible (not filtered out)
        const isVisible = !visibleSet || visibleSet.has(cellIndex)
        
        if (isVisible) {
          const category = values[cellIndex]
          if (centroids[category]) {
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
  updateVisualizationWithMetadata() {
    const vizStart = performance.now()
    console.log('⏱️ [PERF] Step 2: updateVisualizationWithMetadata started')
    
    if (!this.controller.metadataData) {
      console.log('No metadata data to visualize')
      return
    }
    
    // Get embedding ID for caching (use name as key)
    const embeddingId = this.controller.metadataData.name
    
    // Check cache first to avoid re-decompressing
    let decompressedCoords
    const decompressStart = performance.now()
    
    if (this.controller.decompressedCoordinatesCache.has(embeddingId)) {
      console.log(`⏱️ [PERF] Step 2a: CACHE HIT - Using cached coordinates for ${embeddingId}`)
      decompressedCoords = this.controller.decompressedCoordinatesCache.get(embeddingId)
      const cacheTime = performance.now() - decompressStart
      console.log(`⏱️ [PERF] Step 2a: Cache retrieval: ${cacheTime.toFixed(2)}ms`)
    } else {
      console.log(`⏱️ [PERF] Step 2a: CACHE MISS - Decompressing ${embeddingId}`)
      // Decompress and cache (this method has its own internal logging)
      decompressedCoords = this.decompressBinaryCoordinates(this.controller.metadataData.binaryData)
      this.controller.decompressedCoordinatesCache.set(embeddingId, decompressedCoords)
      const decompressTime = performance.now() - decompressStart
      console.log(`⏱️ [PERF] Step 2a: Total decompress + cache: ${decompressTime.toFixed(2)}ms`)
    }
    
    // Initialize scatter plot
    const plotStart = performance.now()
    this.controller.rendererManager.initializeScatterPlot(decompressedCoords)
    const plotTime = performance.now() - plotStart
    console.log(`⏱️ [PERF] Plot initialization completed in ${plotTime.toFixed(2)}ms`)
    const vizTime = performance.now() - vizStart
    console.log(`⏱️ [PERF] Step 2: updateVisualizationWithMetadata completed in ${vizTime.toFixed(2)}ms`)
  }

  // Load a single metadata vector on demand
  async loadSingleMetadataVector(metadataId) {
    // console.log(`=== LOADING SINGLE METADATA VECTOR: ${metadataId} ===`)
    // console.log(`Call stack:`, new Error().stack)
    
    // Check if already loaded in memory
    if (this.controller.loadedMetadataVectors[metadataId]) {
      console.log(`💾 Metadata vector ${metadataId} already in memory`)
      const cachedData = this.controller.loadedMetadataVectors[metadataId]
      console.log('Cached data:', cachedData)
      console.log('Cached compressed_data:', cachedData.compressed_data)
      console.log('Cached compression_info:', cachedData.compression_info)
      // Update status icon to show it's in memory
      this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
      return cachedData
    }
    
    // Try to load from IndexedDB (disk storage) first
    // Always check disk before network to avoid unnecessary downloads
    if (!this.controller.loadingMetadataVectors.has(metadataId)) {
      console.log(`🔍 [DEBUG] About to call loadMetadataFromIndexedDB for ${metadataId}`)
      const indexDBStart = performance.now()
      const diskData = await this.controller.memoryManager.loadMetadataFromIndexedDB(metadataId)
      const indexDBEnd = performance.now()
      const indexDBDuration = (indexDBEnd - indexDBStart).toFixed(2)
      console.log(`🔍 [DEBUG] loadMetadataFromIndexedDB completed for ${metadataId} in ${indexDBDuration}ms`)
      if (diskData) {
        // Silently load from disk (reduced logging)
        // console.log(`💾 ✅ Loaded metadata ${metadataId} from IndexedDB (disk) - saved bandwidth!`)
        
        // Remove IndexedDB metadata fields before returning
        const cleanData = { ...diskData }
        delete cleanData.loomFile
        delete cleanData.timestamp
        
        this.controller.loadedMetadataVectors[metadataId] = cleanData
        // Update status icon to show it's in memory (loaded from disk)
        this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
        return cleanData
      }
    }
    
    // Check if currently loading
    if (this.controller.loadingMetadataVectors.has(metadataId)) {
      //console.log(`Metadata vector ${metadataId} is currently loading, waiting...`)
      // Wait for the loading to complete
      while (this.controller.loadingMetadataVectors.has(metadataId)) {
        await new Promise(resolve => setTimeout(resolve, 100))
      }
      return this.controller.loadedMetadataVectors[metadataId]
    }
    
    // Mark as loading and update status icon to show downloading
    this.controller.loadingMetadataVectors.add(metadataId)
    this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'downloading')
    
    try {
      // Get the current loom file
      const loomFile = this.controller.hasLoomFileSelectTarget ? this.controller.loomFileSelectTarget.value : this.controller.defaultLoomFileValue
      
      // Build the URL for the single metadata vector endpoint
      // Extract project identifier from URL (supports ID, key, or public_id)
      const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
      const projectIdentifier = pathMatch ? pathMatch[1] : null
      const url = `/projects/${encodeURIComponent(projectIdentifier)}/metadata_vectors?metadata_ids=${metadataId}&loom_file=${encodeURIComponent(loomFile || '')}`
      
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
        this.controller.loadedMetadataVectors[metadataId] = vectorData
        
        // Update status icon to show it's in memory
        this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'in-memory')
        
        // SECOND: Store in IndexedDB for future sessions (async, don't wait)
        this.controller.memoryManager.storeMetadataInIndexedDB(metadataId, vectorData).catch(error => {
          console.error(`Failed to store metadata ${metadataId} in IndexedDB:`, error)
        })
        
        // Silently cached (reduced logging)
        // console.log(`💾 ✅ Loaded and cached metadata vector ${metadataId} (memory + disk)`)
        return vectorData
      } else {
        throw new Error(`No metadata vector found for ID: ${metadataId}`)
      }
    } catch (error) {
      console.error(`Failed to load metadata vector ${metadataId}:`, error)
      // Update status icon to show error (gray with question mark)
      this.controller.uiManager.updateMetadataStatusIcon(metadataId, 'not-loaded')
      throw error
    } finally {
      // Always clean up loading state
      this.controller.loadingMetadataVectors.delete(metadataId)
    }
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

  // Load and visualize metadata vector for a specific metadata ID
  async loadAndVisualizeMetadataVector(metadataId) {
    console.log(`🔍 [DEBUG] Loading and visualizing metadata vector for ID: ${metadataId}`)
    console.log(`🔍 [DEBUG] Current state before load:`)
    console.log(`🔍 [DEBUG] - loadedMetadataVectors keys:`, Object.keys(this.controller.loadedMetadataVectors || {}))
    console.log(`🔍 [DEBUG] - loadingMetadataVectors size:`, this.controller.loadingMetadataVectors?.size || 0)
    
    // Ensure metadata is loaded into memory for fast access
    let vectorData = await this.loadSingleMetadataVector(metadataId)
    
    if (!vectorData) {
      console.error('❌ Failed to load metadata vector for:', metadataId)
      console.error('❌ loadedMetadataVectors keys:', Object.keys(this.controller.loadedMetadataVectors))
      console.error('❌ loadingMetadataVectors:', Array.from(this.controller.loadingMetadataVectors))
      console.error('❌ IndexedDB available:', !!this.controller.db)
      
      // Try to diagnose the issue
      if (this.controller.loadingMetadataVectors.has(metadataId)) {
        console.error('❌ DIAGNOSIS: Metadata is still marked as loading - this indicates a race condition!')
      }
      
      return
    }
    
    console.log(`✅ [DEBUG] Successfully received vectorData, proceeding with decompression...`)
    
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
        delete this.controller.loadedMetadataVectors[metadataId]
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
        return
      }
    } catch (error) {
      console.error('Error processing metadata vector:', error)
      // Clear the corrupted cache entry
      delete this.controller.loadedMetadataVectors[metadataId]
      return
    }
    
    //console.log(`Successfully decompressed ${values.length} values for ${vectorData.name}`)
    
    // Store the decompressed values for visualization
    this.controller.currentMetadataVector = {
      id: metadataId,
      name: vectorData.name,
      data_type: vectorData.data_type,
      values: values,
      compression_info: vectorData.compression_info
    }
    
    try {
      console.log(`✅ [DEBUG] Set currentMetadataVector at:`, new Error().stack)
    } catch (e) {
      console.log(`✅ [DEBUG] Set currentMetadataVector (stack not available):`, e)
    }
    console.log(`✅ [DEBUG] Set currentMetadataVector:`, {
      id: this.controller.currentMetadataVector.id,
      name: this.controller.currentMetadataVector.name,
      dataType: this.controller.currentMetadataVector.data_type,
      valuesLength: this.controller.currentMetadataVector.values?.length
    })
    
    // Also store in loadedMetadataVectors for filtering
    this.controller.loadedMetadataVectors[metadataId] = this.controller.currentMetadataVector
    
    console.log(`✅ [DEBUG] [Instance ${this.controller.instanceId}] Stored in loadedMetadataVectors. New keys:`, Object.keys(this.controller.loadedMetadataVectors))
    console.log(`✅ [DEBUG] Immediately after storing - loadedMetadataVectors[${metadataId}] exists:`, !!this.controller.loadedMetadataVectors[metadataId])
    
    // Update usage tracker for LRU
    this.controller.memoryManager.updateMetadataUsage(metadataId)
    
    // Cleanup old metadata if we exceed the buffer size
    this.controller.memoryManager.cleanupUnusedMetadata()
    
    // Note: We keep metadata in memory during the session for fast switching
    // IndexedDB is used for persistence across page reloads
    // LRU cleanup ensures we don't exceed maxMetadataInMemory
    
    // Show checkboxes for this metadata now that it's loaded
    console.log(`🔍 [DEBUG] Calling showCheckboxesForMetadata for metadata ${metadataId}`)
    this.controller.uiManager.showCheckboxesForMetadata(metadataId)
    
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
      console.log('📊 [ORDERING] Reset _lastNumericOrderApplied to force reordering for new metadata')
    }
    
    // Update visualization with metadata coloring
    this.controller.updateVisualizationWithMetadataVector()
    
    // Initialize checkboxes for the new metadata (only for discrete)
    // NOTE: Don't auto-select categories when loading metadata - let user choose
    if (this.controller.currentMetadataVector?.data_type === 'DISCRETE' || this.controller.currentMetadataVector?.data_type === 'STRING') {
      // Just show the checkboxes without selecting them
      // this.controller.uiManager.initializeAllCheckboxes()
      console.log('📋 Discrete metadata loaded - checkboxes available for user selection')
      
      // Update category distribution bars for all visible metadata sections
      this.updateAllCategoryDistributions()
    } else if (this.controller.currentMetadataVector?.data_type === 'NUMERIC') {
      console.log('📊 Continuous metadata loaded - updating distribution bars')
      
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
      // Disable pointer events on overlay for discrete metadata
      // This allows interactions with the plot below
      if (this.controller.overlayCanvas) {
        this.controller.overlayCanvas.style.pointerEvents = 'none'
      }
    }
    
    // Final check - is the data still in memory at the end of this function?
    console.log(`✅ [DEBUG] [Instance ${this.controller.instanceId}] END of loadAndVisualizeMetadataVector - loadedMetadataVectors keys:`, Object.keys(this.controller.loadedMetadataVectors))
    console.log(`✅ [DEBUG] END - loadedMetadataVectors[${metadataId}] still exists:`, !!this.controller.loadedMetadataVectors[metadataId])
  }

  // Update cell filtering with performance optimization
  updateCellFiltering(shouldUpdateColors = false) {
    // console.log('🔍 [FILTERING] updateCellFiltering called with selectedRanges:', this.controller.selectedRanges)
    // Performance optimization: batch multiple updates
    this.controller.scheduleUpdate('filtering', () => {
      this.performCellFilteringUpdate(shouldUpdateColors)
    })
  }

  // Actual filtering update logic (separated for batching)
  performCellFilteringUpdate(shouldUpdateColors = false) {
    // Use incremental filtering for better performance
    const filteredIndices = this.getIncrementalFilteredIndices()
    //console.log('Filtered indices result:', filteredIndices ? `${filteredIndices.length} cells` : 'null (no filtering)')
    
    // Update the current visible cells state
    this.controller.currentVisibleCells = filteredIndices
    
    // Update current selection to only include visible cells
    this.updateSelectionBasedOnFiltering(filteredIndices)
    
    // Update point count display immediately
    this.controller.uiManager.updatePointCountDisplay(filteredIndices)
    
    // Update sidebar category counts with visual indicators (for ALL categorical metadata)
    this.controller.uiManager.updateSidebarCategoryCounts()
    
    // Update all range slider counts to reflect combined filtering (for ALL continuous metadata)
    this.controller.uiManager.updateAllRangeSliderCounts()
    
    // Update manual selection count to show only visible selected cells
    this.controller.uiManager.updateSelectedCellsCount()
    
    // Update button state after filtering
    this.controller.uiManager.updateAddAllVisibleButtonState()
    
    // Update category distribution bar plots to reflect filtered cells
    this.updateAllCategoryDistributions()
    
    // Use requestAnimationFrame for smooth updates
    requestAnimationFrame(() => {
      // If we need to update colors (e.g., color range adapted), render colors first
      if (shouldUpdateColors && this.controller.currentMetadataVector) {
        this.controller.renderPointsWithCurrentColoring()
      } else {
        // Otherwise just update visibility
        this.controller.updatePointVisibility(filteredIndices)
      }
      
      // Re-render category labels after filtering (ReGL mode only)
      // Labels need to move to new centroids of visible cells
      if (this.controller.rendererType === 'regl' && (this.controller.currentMetadataVector?.data_type === 'DISCRETE' || this.controller.currentMetadataVector?.data_type === 'STRING')) {
        const categoriesCheckbox = document.getElementById('show-categories-checkbox')
        if (categoriesCheckbox && categoriesCheckbox.checked) {
          console.log('🏷️ Re-rendering category labels after filtering (centroids may have moved)')
          // Clear and redraw overlay to ensure old labels are removed
          this.controller.rendererManager.renderGrid()
          this.controller.rendererManager.renderAxes()
          this.controller.rendererManager.renderCategoryLabels()
        }
      }
    })
  }

  // Incremental filtering - much faster for small changes
  getIncrementalFilteredIndices() {
    const hasDiscreteSelections = this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0
    const hasContinuousSelections = this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0
    
    // console.log('🔍 [FILTERING] getIncrementalFilteredIndices called')
    // console.log('🔍 [FILTERING] hasDiscreteSelections:', hasDiscreteSelections)
    // console.log('🔍 [FILTERING] hasContinuousSelections:', hasContinuousSelections)
    // console.log('🔍 [FILTERING] selectedRanges:', this.controller.selectedRanges)
    
    if (!hasDiscreteSelections && !hasContinuousSelections) {
      // No filtering applied, return all cells
      return null
    }

    // Get all metadata that have selections AND have loaded vectors (categorical)
    const discreteMetadataWithSelections = hasDiscreteSelections 
      ? Object.keys(this.controller.selectedCategories).filter(metadataId => {
      const selections = this.controller.selectedCategories[metadataId]
      const hasLoadedVector = this.controller.loadedMetadataVectors[metadataId] !== undefined
      
      // Important: Empty Set (size === 0) is a valid constraint meaning "show nothing"
      // Don't filter it out or delete it
      if (!selections) {
        return false
      }
      
      return hasLoadedVector
    })
      : []
    
    // Get all metadata that have range selections AND have loaded vectors (continuous)
    const continuousMetadataWithSelections = hasContinuousSelections
      ? Object.keys(this.controller.selectedRanges).filter(metadataId => {
          const range = this.controller.selectedRanges[metadataId]
          const hasRange = range && (range.min !== undefined && range.max !== undefined)
          const hasLoadedVector = this.controller.loadedMetadataVectors[metadataId] !== undefined
          return hasRange && hasLoadedVector
        })
      : []

    // Combine both types of metadata with selections
    const metadataWithSelections = [...new Set([...discreteMetadataWithSelections, ...continuousMetadataWithSelections])]

    if (metadataWithSelections.length === 0) {
      return null
    }

    // Create current filter state
    const currentFilterState = this.controller.createFilterCacheKey()
    
    // If this is the same as last state, return current visible cells
    if (this.controller.lastFilterState === currentFilterState && this.controller.currentVisibleCells) {
      //console.log('Using cached incremental result')
      return this.controller.currentVisibleCells
    }

    // If we have no current visible cells, do full calculation
    if (!this.controller.currentVisibleCells) {
      //console.log('No current visible cells - doing full calculation')
      const result = this.getFilteredCellIndices()
      this.controller.lastFilterState = currentFilterState
      return result
    }

    // Try incremental update
    const incrementalResult = this.tryIncrementalUpdate(metadataWithSelections)
    if (incrementalResult !== null) {
      //console.log('Using incremental update')
      this.controller.lastFilterState = currentFilterState
      return incrementalResult
    }

    // Fall back to full calculation
    //console.log('Fallback to full calculation')
    const result = this.getFilteredCellIndices()
    this.controller.lastFilterState = currentFilterState
    return result
  }

  // Try to do an incremental update
  tryIncrementalUpdate(metadataWithSelections) {
    // For now, let's implement a simple case: single metadata changes
    if (metadataWithSelections.length === 1) {
      const metadataId = metadataWithSelections[0]
      //console.log(`Single metadata incremental filtering for ${metadataId}`)
      // Use getCellsForMetadata which handles both discrete and continuous metadata
      return this.controller.getCellsForMetadata(metadataId)
    }

    // For multiple metadata, we could implement more sophisticated logic
    // For now, return null to trigger full calculation
    return null
  }

  // Update current selection to only include cells that are currently visible (not filtered out)
  updateSelectionBasedOnFiltering(filteredIndices) {
    //console.log(`updateSelectionBasedOnFiltering called with filteredIndices:`, filteredIndices ? filteredIndices.length : 'null')
    //console.log(`Current selectedCells size:`, this.controller.selectedCells ? this.controller.selectedCells.size : 'null')
    
    if (!this.controller.selectedCells || this.controller.selectedCells.size === 0) {
      // No current selection, nothing to update
      console.log(`No current selection to update`)
      return
    }

    const originalSelectionSize = this.controller.selectedCells.size
    
    if (!filteredIndices) {
      // No filtering applied - all cells are visible, keep current selection
      // console.log(`Selection unchanged: ${originalSelectionSize} cells (no filtering)`)
      return
    }

    // Create a set of visible cell indices for O(1) lookup
    const visibleCellsSet = new Set(filteredIndices)
    
    // Filter the current selection to only include visible cells
    const filteredSelection = new Set()
    this.controller.selectedCells.forEach(cellId => {
      if (visibleCellsSet.has(cellId)) {
        filteredSelection.add(cellId)
      }
    })
    
    // Update the current selection
    this.controller.selectedCells = filteredSelection
    
    const newSelectionSize = this.controller.selectedCells.size
    //console.log(`Selection updated: ${originalSelectionSize} → ${newSelectionSize} cells (filtered)`)
    
    // Update the selection count display
    this.controller.uiManager.updateSelectedCellsCount()
    
    // Update point colors to reflect the new selection
    this.controller.updateSelectedPointColors()
  }

  // Get the intersection of selected cells across all metadata (full calculation)
  getFilteredCellIndices() {
    // Performance optimization: check if filter state has changed
    const currentFilterHash = this.getFilterStateHash()
    console.log('🔍 Filter state check:', {
      currentHash: currentFilterHash,
      lastHash: this.controller.lastFilterStateHash,
      hasCachedIndices: this.controller.lastFilteredIndices !== undefined,
      selectedCategories: this.controller.selectedCategories
    })
    
    if (this.controller.lastFilterStateHash === currentFilterHash && this.controller.lastFilteredIndices !== undefined) {
      console.log('🔍 Using cached filtered indices (no filter state change)')
      return this.controller.lastFilteredIndices
    }
    
    const startTime = performance.now()
    const hasDiscreteSelections = this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0
    const hasContinuousSelections = this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0
    
    console.log('🔍 getFilteredCellIndices called:', {
      hasDiscreteSelections,
      hasContinuousSelections,
      selectedCategories: this.controller.selectedCategories,
      selectedRanges: this.controller.selectedRanges
    })
    
    if (!hasDiscreteSelections && !hasContinuousSelections) {
      // No filtering applied, return all cells
      // console.log('🔍 No selections found, returning null (no filtering)')
      // Update performance cache
      this.controller.lastFilteredIndices = null
      this.controller.lastFilterStateHash = currentFilterHash
      return null
    }

    // Create cache key from current selections
    const cacheKey = this.controller.createFilterCacheKey()
    if (this.controller.filterCache.has(cacheKey)) {
      //console.log('Using cached filter result')
      return this.controller.filterCache.get(cacheKey)
    }

    // Check if there are any actual constraints (this will be done more precisely below)
    // We'll check for constraints in the filtering logic below

    // Get all metadata that have actual constraints (not all categories/values selected)
    console.log(`🔍 [FILTER] selectedCategories keys:`, Object.keys(this.controller.selectedCategories))
    Object.keys(this.controller.selectedCategories).forEach(id => {
      console.log(`🔍 [FILTER] selectedCategories[${id}] size:`, this.controller.selectedCategories[id]?.size)
    })
    
    const discreteMetadataWithConstraints = Object.keys(this.controller.selectedCategories).filter(metadataId => {
      const selections = this.controller.selectedCategories[metadataId]
      const hasLoadedVector = this.controller.loadedMetadataVectors[metadataId] !== undefined
      
      console.log(`🔍 [FILTER] Checking metadata ${metadataId}: selections.size=${selections?.size}, hasLoadedVector=${hasLoadedVector}`)
      
      if (!selections || !hasLoadedVector) {
        console.log(`🔍 [FILTER] Metadata ${metadataId} skipped (no selections or no vector)`)
        return false
      }
      
      // Special case: Empty Set means "show nothing" - this IS a constraint
      if (selections.size === 0) {
        console.log(`🔍 [FILTER] Metadata ${metadataId} has empty selection - will show no cells`)
        return true // Include as a constraint (will result in 0 cells)
      }
      
      // Check if all categories are selected (no constraint)
      const metadataVector = this.controller.loadedMetadataVectors[metadataId]
      if (metadataVector && metadataVector.values) {
        const availableCategories = [...new Set(metadataVector.values)]
        const allSelected = availableCategories.every(category => selections.has(category))
        console.log(`🔍 [FILTER] Metadata ${metadataId}: ${selections.size}/${availableCategories.length} categories selected, allSelected=${allSelected}`)
        return !allSelected // Only include if not all categories are selected
      }
      
      return true
    })
    
    console.log(`🔍 [FILTER] discreteMetadataWithConstraints:`, discreteMetadataWithConstraints)

    const continuousMetadataWithConstraints = Object.keys(this.controller.selectedRanges).filter(metadataId => {
      const range = this.controller.selectedRanges[metadataId]
      const hasRange = range && (range.min !== undefined && range.max !== undefined)
      const hasLoadedVector = this.controller.loadedMetadataVectors[metadataId] !== undefined
      
      if (!hasRange || !hasLoadedVector) return false
      
      // Check if range covers the full range (no constraint)
      const metadataVector = this.controller.loadedMetadataVectors[metadataId]
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

    //console.log(`All metadata in selectedCategories:`, Object.keys(this.controller.selectedCategories))
    //console.log(`Loaded metadata vectors:`, Object.keys(this.controller.loadedMetadataVectors))
    //console.log(`Current metadata ID:`, this.controller.currentMetadataId)

    if (allMetadataWithConstraints.length === 0) {
      // No metadata has actual constraints, return all cells
      // console.log('🔍 No metadata with constraints found, returning null (no filtering)')
      // Update performance cache
      this.controller.lastFilteredIndices = null
      this.controller.lastFilterStateHash = currentFilterHash
      return null
    }

    console.log('🔍 Metadata with constraints:', allMetadataWithConstraints)

    // Start with cells that match the first metadata's constraints
    const firstMetadataId = allMetadataWithConstraints[0]
    let filteredIndices = this.controller.getCellsForMetadata(firstMetadataId)
    console.log(`🔍 First metadata ${firstMetadataId} filtered indices:`, filteredIndices ? filteredIndices.length : 'null')

    // Intersect with each subsequent metadata's constraints using Set for O(1) lookups
    for (let i = 1; i < allMetadataWithConstraints.length; i++) {
      const metadataId = allMetadataWithConstraints[i]
      const cellsForThisMetadata = this.controller.getCellsForMetadata(metadataId)
      console.log(`🔍 Metadata ${metadataId} filtered indices:`, cellsForThisMetadata ? cellsForThisMetadata.length : 'null')
      
      // Convert to Set for O(1) lookup instead of O(n) includes()
      const cellsSet = new Set(cellsForThisMetadata)
      
      // Intersection: keep only cells that are in both sets
      const beforeIntersection = filteredIndices.length
      filteredIndices = filteredIndices.filter(cellIndex => cellsSet.has(cellIndex))
      console.log(`🔍 After intersection with ${metadataId}: ${filteredIndices.length} (was ${beforeIntersection})`)
      
      // If we get 0 cells, log more details to help debug
      if (filteredIndices.length === 0) {
        console.warn(`⚠️ FILTERING ISSUE: Intersection resulted in 0 cells!`)
        console.warn(`⚠️ First metadata had ${beforeIntersection} cells`)
        console.warn(`⚠️ Second metadata had ${cellsForThisMetadata?.length || 0} cells`)
        console.warn(`⚠️ This suggests no overlap between constraints`)
      }
    }

    console.log(`🔍 Final filtered ${filteredIndices ? filteredIndices.length : 'null'} cells from ${this.controller.currentCoordinates?.length || 0} total cells`)
    
    // Cache the result
    this.controller.filterCache.set(cacheKey, filteredIndices)
    
    // Update performance cache
    this.controller.lastFilteredIndices = filteredIndices
    this.controller.lastFilterStateHash = currentFilterHash
    
    const totalTime = performance.now() - startTime
    console.log(`🚀 [PERF] getFilteredCellIndices completed in ${totalTime.toFixed(2)}ms`)
    
    return filteredIndices
  }

  // Clean up stale selections for metadata that are no longer loaded
  cleanupStaleSelections() {
    // Clean up selectedCategories
    const staleCategories = Object.keys(this.controller.selectedCategories).filter(metadataId => {
      return !this.controller.loadedMetadataVectors[metadataId]
    })
    
    staleCategories.forEach(metadataId => {
      console.log(`🧹 Cleaning up stale category selections for metadata ${metadataId}`)
      delete this.controller.selectedCategories[metadataId]
    })
    
    // Clean up selectedRanges  
    const staleRanges = Object.keys(this.controller.selectedRanges).filter(metadataId => {
      return !this.controller.loadedMetadataVectors[metadataId]
    })
    
    staleRanges.forEach(metadataId => {
      console.log(`🧹 Cleaning up stale range selections for metadata ${metadataId}`)
      delete this.controller.selectedRanges[metadataId]
    })
    
    if (staleCategories.length > 0 || staleRanges.length > 0) {
      console.log(`🧹 Cleaned up ${staleCategories.length} stale category selections and ${staleRanges.length} stale range selections`)
    }
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
      continuousCount
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
      categoryOrder: this.controller.categoryOrder,
      customColorRange: this.controller.customColorRange,
      currentColorScheme: this.controller.currentColorScheme,
      filteredIndices: this.controller.currentVisibleCells,
      gradientHash: gradientHash // Include gradient in hash for proper cache invalidation
    })
  }

  // Get total count for a category
  getTotalCountForCategory(categoryName) {
    if (!this.controller.currentMetadataVector || !this.controller.currentMetadataVector.values) {
      return 0
    }
    
    let count = 0
    for (let i = 0; i < this.controller.currentMetadataVector.values.length; i++) {
      if (this.controller.currentMetadataVector.values[i] === categoryName) {
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
    
    // Count visible cells for this category
    let visibleCount = 0
    for (let i = 0; i < this.controller.currentVisibleCells.length; i++) {
      const cellIndex = this.controller.currentVisibleCells[i]
      if (this.controller.currentMetadataVector.values[cellIndex] === categoryName) {
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

  // Get metadata vector by ID
  getMetadataVectorById(metadataId) {
    // Check if it's the current metadata vector (fully loaded and decompressed)
    if (this.controller.currentMetadataId === metadataId && this.controller.currentMetadataVector) {
      // Update usage tracker for current metadata
      this.controller.memoryManager.updateMetadataUsage(metadataId)
      return this.controller.currentMetadataVector
    }
    
    // Check stored metadata vectors in memory
    if (this.controller.loadedMetadataVectors && this.controller.loadedMetadataVectors[metadataId]) {
      const vectorData = this.controller.loadedMetadataVectors[metadataId]
      
      // Update usage tracker
      this.controller.memoryManager.updateMetadataUsage(metadataId)
      
      // If it's already decompressed (has values), return it
      if (vectorData.values) {
        return vectorData
      }
      
      // Check if compression_info is invalid (error string instead of object)
      const isInvalidCompression = vectorData.compression_info && 
        typeof vectorData.compression_info === 'string' &&
        (vectorData.compression_info.includes('No categories available') || 
         vectorData.compression_info.includes('Failed to parse'))
      
      // If invalid compression, remove from cache and return null to force reload
      if (isInvalidCompression) {
        console.warn(`⚠️ [DataManager] Metadata ${metadataId} has invalid compression_info: ${vectorData.compression_info}`)
        console.warn(`⚠️ [DataManager] Removing from cache - will reload from server`)
        delete this.controller.loadedMetadataVectors[metadataId]
        return null
      }
      
      // If it's compressed, decompress it on demand (matching original controller logic)
      // Handle both regular compression and single_category optimization
      if (vectorData.compression_info && typeof vectorData.compression_info === 'object' && 
          (vectorData.compressed_data || vectorData.compression_info.single_category)) {
        // console.log(`💾 [MEMORY] Decompressing metadata ${metadataId} from memory...`)
        try {
          let values
          if (vectorData.data_type === 'DISCRETE' || vectorData.data_type === 'STRING') {
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
          this.controller.loadedMetadataVectors[metadataId] = decompressedVector
          
          // console.log(`💾 [MEMORY] Decompressed and cached metadata ${metadataId}: ${values.length} values`)
          return decompressedVector
          
        } catch (error) {
          console.error(`Error decompressing metadata vector ${metadataId}:`, error)
          return null
        }
      }
      
      return vectorData
    }
    
    // If metadata is not in memory but we need it (e.g., for filtering), try to load it
    console.log(`💾 Metadata ${metadataId} not in memory, attempting to load...`)
    
    // Note: This is a synchronous method, so we can't await here
    // We'll need to handle this case differently in the filtering logic
    return null
  }

  // Preload metadata vector on hover for better UX
  preloadMetadataVector(event) {
    const button = event.currentTarget
    const metadataId = button.dataset.metadataId
    
    // Debounce: Only preload if mouse stays on element for 300ms
    // This prevents UI lag when quickly moving mouse over items
    if (this.controller.preloadTimeout) {
      clearTimeout(this.controller.preloadTimeout)
    }
    
    this.controller.preloadTimeout = setTimeout(() => {
    // Only preload if not already loaded and not currently loading
    if (!this.controller.loadedMetadataVectors[metadataId] && !this.controller.loadingMetadataVectors.has(metadataId)) {
      console.log(`🚀 Preloading metadata vector ${metadataId} on hover`)
      // Load silently without showing spinners
      this.controller.loadSingleMetadataVectorSilently(metadataId).catch(error => {
        console.log(`Preload failed for metadata ${metadataId}:`, error.message)
        // Don't show error to user for preloading failures
      })
      }
    }, 1000) // 1000ms delay - only preload if user hovers for 1 second
  }
  
  // Cancel preload if user quickly moves away
  cancelPreload(event) {
    if (this.controller.preloadTimeout) {
      clearTimeout(this.controller.preloadTimeout)
      this.controller.preloadTimeout = null
    }
  }

  // Extract current screen positions (coordinate extraction)
  extractCurrentScreenPositions(currentBounds, coordinateCount) {
    // Since we can't easily extract positions from individual PIXI Graphics objects,
    // we'll recreate the positions using the current bounds and coordinates
    // This is a limitation of PIXI Graphics - we need to store positions differently
    //console.log('Extracting current screen positions (recreating from bounds)')
    return currentBounds
  }

  // Get loaded metadata vector for a specific metadata ID
  getLoadedMetadataVector(metadataId) {
    if (!this.controller.loadedMetadataVectors) {
      console.log('No metadata vectors loaded yet')
      return null
    }
    
    const vectorData = this.controller.loadedMetadataVectors[metadataId]
    if (!vectorData) {
      console.log(`No loaded vector found for metadata ID: ${metadataId}`)
      return null
    }
    
    //console.log(`Retrieved loaded vector for ${vectorData.name}:`, vectorData.compression_info)
    return vectorData
  }

  // Store binary metadata data
  storeBinaryMetadataData(data) {
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
    
    /*console.log(`Stored binary metadata data for ${data.name}:`, {
      cellCount: data.cellCount,
      binarySize: binarySize,
      expectedSize: expectedSize,
      compressionRatio: compressionRatio.toFixed(2) + 'x',
      memoryEfficiency: ((1 - binarySize / (data.cellCount * 2 * 8)) * 100).toFixed(1) + '%'
    })*/
    
    // Recalculate optimal buffer size now that we have cell count
    // This updates from the default (5) to the actual optimal size
    if (this.controller.maxMetadataInMemory <= 5) {
      const newBufferSize = this.controller.memoryManager.calculateOptimalBufferSize()
      if (newBufferSize > this.controller.maxMetadataInMemory) {
        console.log(`🧠 [MEMORY] Recalculating buffer size with cell count ${data.cellCount.toLocaleString()}`)
        console.log(`🧠 [MEMORY] Updated buffer size: ${this.controller.maxMetadataInMemory} → ${newBufferSize} metadata vectors`)
        this.controller.maxMetadataInMemory = newBufferSize
      }
    }
    
    // Update visualization with the new coordinate data
    console.log(`📊 [EMBEDDING] Updating visualization with new coordinates...`)
    this.updateVisualizationWithMetadata()
    console.log(`📊 [EMBEDDING] Visualization updated, checking for active coloring...`)
    
    // If there's a currently active metadata vector (coloring), reapply it to the new embedding
    if (this.controller.currentMetadataVector && this.controller.currentMetadataId) {
      console.log(`🎨 [EMBEDDING] Reapplying metadata coloring after embedding switch: ${this.controller.currentMetadataVector.name}`)
      console.log(`🎨 [EMBEDDING] Current metadata type: ${this.controller.currentMetadataVector.data_type}`)
      console.log(`🎨 [EMBEDDING] Display order length: ${this.controller.displayOrder?.length}`)
      this.controller.updateVisualizationWithMetadataVector()
      console.log(`🎨 [EMBEDDING] Coloring reapplied successfully`)
    } else {
      console.log(`📊 [EMBEDDING] No active coloring to reapply (currentMetadataVector: ${!!this.controller.currentMetadataVector}, currentMetadataId: ${this.controller.currentMetadataId})`)
    }
  }

  // Clear metadata data
  clearMetadataData() {
    this.controller.metadataData = null
    //console.log('Cleared metadata data')
    
    // Clear PIXI.js visualization
    if (this.controller.pixiApp) {
      this.controller.pixiApp.destroy(true)
      this.controller.pixiApp = null
      this.controller.scatterContainer = null
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
  
  // Update category distribution bars for all visible (expanded) metadata sections
  updateAllCategoryDistributions() {
    console.log('🎨 [BAR PLOTS] updateAllCategoryDistributions called')
    
    // Find all expanded metadata sections
    const expandedSections = document.querySelectorAll('[data-metadata-item]')
    console.log('🎨 [BAR PLOTS] Found sections:', expandedSections.length)
    
    expandedSections.forEach(section => {
      const metadataId = parseInt(section.dataset.metadataItem)
      
      // Check if this section is expanded by checking if the categories div is visible
      // (not by checking canvas visibility, as canvases might be hidden when no coloring is active)
      const header = section.querySelector('[data-action*="toggleMetadata"]')
      if (!header) return
      
      const categoriesDiv = header.nextElementSibling
      if (!categoriesDiv || categoriesDiv.style.display === 'none') {
        // Section is not expanded, skip it
        return
      }
      
      // Section is expanded, update its distributions
      // This will show/hide canvases based on whether coloring is active
      const canvases = section.querySelectorAll('.category-distribution-canvas')
      console.log(`🎨 [BAR PLOTS] Metadata ${metadataId}: ${canvases.length} canvases found, section expanded`)
      
      if (canvases.length > 0) {
        console.log(`🎨 [BAR PLOTS] Redrawing distributions for metadata ${metadataId}`)
        this.controller.drawCategoryDistributions(metadataId)
      }
    })
  }
}
