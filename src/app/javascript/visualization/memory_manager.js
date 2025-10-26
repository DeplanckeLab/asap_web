export class MemoryManager {
  constructor(controller) {
    this.controller = controller
  }

  // Log memory usage for debugging
  logMemoryUsage(context = '') {
    if (performance.memory) {
      const memory = performance.memory
      const used = (memory.usedJSHeapSize / 1024 / 1024).toFixed(2)
      const total = (memory.totalJSHeapSize / 1024 / 1024).toFixed(2)
      const limit = (memory.jsHeapSizeLimit / 1024 / 1024).toFixed(2)
      
      console.log(`🧠 [MEMORY] ${context}: Used: ${used}MB / Total: ${total}MB / Limit: ${limit}MB`)
      
      // Check if we're approaching the limit
      const usagePercent = (memory.usedJSHeapSize / memory.jsHeapSizeLimit) * 100
      if (usagePercent > 80) {
        console.warn(`⚠️ [MEMORY] High memory usage: ${usagePercent.toFixed(1)}% of limit`)
      }
    } else {
      console.log(`🧠 [MEMORY] ${context}: Memory API not available`)
    }
  }

  // Check memory health and trigger cleanup if needed
  checkMemoryHealth() {
    if (!performance.memory) return true
    
    const memory = performance.memory
    const usagePercent = (memory.usedJSHeapSize / memory.jsHeapSizeLimit) * 100
    
    if (usagePercent > 90) {
      console.warn(`🚨 [MEMORY] Critical memory usage: ${usagePercent.toFixed(1)}% of limit`)
      this.cleanupUnusedMetadata()
      return false
    } else if (usagePercent > 75) {
      console.log(`⚠️ [MEMORY] High memory usage: ${usagePercent.toFixed(1)}% of limit`)
      this.optimizeMemoryUsage()
      return true
    }
    
    return true
  }

  // Initialize IndexedDB for metadata storage
  initializeIndexedDB() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open('ASAPMetadataDB', 1)
      
      request.onerror = () => {
        console.error('❌ [INDEXEDDB] Failed to open database')
        reject(request.error)
      }
      
      request.onsuccess = () => {
        this.controller.db = request.result
        console.log('✅ [INDEXEDDB] Database opened successfully')
        resolve()
      }
      
      request.onupgradeneeded = (event) => {
        const db = event.target.result
        
        // Create object store for metadata
        if (!db.objectStoreNames.contains('metadata')) {
          const metadataStore = db.createObjectStore('metadata', { keyPath: 'id' })
          metadataStore.createIndex('timestamp', 'timestamp', { unique: false })
          console.log('✅ [INDEXEDDB] Metadata store created')
        }
        
        // Create object store for coordinates
        if (!db.objectStoreNames.contains('coordinates')) {
          const coordinatesStore = db.createObjectStore('coordinates', { keyPath: 'id' })
          console.log('✅ [INDEXEDDB] Coordinates store created')
        }
      }
    })
  }

  // Clear old metadata from memory to free up space
  clearOldMetadataFromMemory(currentMetadataId) {
    const maxMemoryItems = 5 // Keep only 5 metadata vectors in memory
    
    if (Object.keys(this.controller.loadedMetadataVectors).length <= maxMemoryItems) {
      return // Not enough items to clean up
    }
    
    console.log('🧹 [MEMORY] Cleaning up old metadata from memory...')
    
    // Get metadata usage timestamps
    const metadataUsage = Object.keys(this.controller.loadedMetadataVectors)
      .filter(id => id !== currentMetadataId) // Don't remove current metadata
      .map(id => ({
        id,
        lastUsed: this.controller.metadataUsageTracker[id] || 0,
        size: this.controller.loadedMetadataVectors[id]?.values?.length || 0
      }))
      .sort((a, b) => a.lastUsed - b.lastUsed) // Oldest first
    
    // Remove oldest unused metadata
    const itemsToRemove = metadataUsage.slice(0, metadataUsage.length - maxMemoryItems + 1)
    
    itemsToRemove.forEach(({ id, size }) => {
      console.log(`🗑️ [MEMORY] Removing metadata ${id} (${size} values)`)
      delete this.controller.loadedMetadataVectors[id]
      delete this.controller.metadataUsageTracker[id]
    })
    
    console.log(`✅ [MEMORY] Cleaned up ${itemsToRemove.length} metadata vectors`)
  }

  // Clean up unused metadata from memory
  cleanupUnusedMetadataAggressive() {
    console.log('🧹 [MEMORY] Starting cleanup of unused metadata...')
    
    const currentTime = Date.now()
    const maxAge = 5 * 60 * 1000 // 5 minutes
    const maxItems = 3 // Keep only 3 items in memory
    
    // Get all metadata with usage info
    const metadataItems = Object.keys(this.controller.loadedMetadataVectors)
      .map(id => ({
        id,
        lastUsed: this.controller.metadataUsageTracker[id] || 0,
        age: currentTime - (this.controller.metadataUsageTracker[id] || 0),
        size: this.controller.loadedMetadataVectors[id]?.values?.length || 0
      }))
      .sort((a, b) => a.lastUsed - b.lastUsed) // Oldest first
    
    // Remove old or excess metadata
    const itemsToRemove = metadataItems
      .filter(item => item.age > maxAge || item.id !== this.controller.currentMetadataId)
      .slice(0, Math.max(0, metadataItems.length - maxItems))
    
    itemsToRemove.forEach(({ id, size, age }) => {
      console.log(`🗑️ [MEMORY] Removing metadata ${id} (${size} values, ${Math.round(age/1000)}s old)`)
      delete this.controller.loadedMetadataVectors[id]
      delete this.controller.metadataUsageTracker[id]
    })
    
    console.log(`✅ [MEMORY] Cleaned up ${itemsToRemove.length} metadata vectors`)
    
    // Force garbage collection if available
    if (window.gc) {
      window.gc()
      console.log('🗑️ [MEMORY] Forced garbage collection')
    }
  }

  // Optimize memory usage by cleaning up and compressing data
  optimizeMemoryUsage() {
    console.log('⚡ [MEMORY] Optimizing memory usage...')
    
    // Clean up unused metadata
    this.cleanupUnusedMetadata()
    
    // Clear color map cache if it's too large
    if (this.controller.colorMapCache && Object.keys(this.controller.colorMapCache).length > 10) {
      console.log('🗑️ [MEMORY] Clearing color map cache')
      this.controller.colorMapCache = {}
    }
    
    // Clear original point colors if too many
    if (this.controller.originalPointColors && this.controller.originalPointColors.size > 10000) {
      console.log('🗑️ [MEMORY] Clearing original point colors cache')
      this.controller.originalPointColors.clear()
    }
    
    // Force garbage collection if available
    if (window.gc) {
      window.gc()
      console.log('🗑️ [MEMORY] Forced garbage collection')
    }
    
    this.logMemoryUsage('After optimization')
  }

  // Get cell count from IndexedDB (for early buffer size calculation)
  async getCellCountFromDatabase() {
    if (!this.controller.db) {
      return 0
    }
    
    try {
      // Try to get cell count from coordinates store first (embeddings)
      const coordTransaction = this.controller.db.transaction(['coordinates'], 'readonly')
      const coordStore = coordTransaction.objectStore('coordinates')
      const coordRequest = coordStore.openCursor()
      
      const coordResult = await new Promise((resolve) => {
        coordRequest.onsuccess = (event) => {
          const cursor = event.target.result
          if (cursor) {
            const data = cursor.value
            if (data.cellCount) {
              console.log(`🧠 [MEMORY] Found cell count in coordinates store: ${data.cellCount.toLocaleString()}`)
              resolve(data.cellCount)
              return
            }
          }
          resolve(0)
        }
        coordRequest.onerror = () => resolve(0)
      })
      
      if (coordResult > 0) return coordResult
      
      // If not found, try metadata store
      const metaTransaction = this.controller.db.transaction(['metadata'], 'readonly')
      const metaStore = metaTransaction.objectStore('metadata')
      const metaRequest = metaStore.openCursor()
      
      const metaResult = await new Promise((resolve) => {
        metaRequest.onsuccess = (event) => {
          const cursor = event.target.result
          if (cursor) {
            const data = cursor.value
            // Metadata vectors have values array
            if (data.values && Array.isArray(data.values)) {
              console.log(`🧠 [MEMORY] Found cell count in metadata store: ${data.values.length.toLocaleString()}`)
              resolve(data.values.length)
              return
            }
          }
          resolve(0)
        }
        metaRequest.onerror = () => resolve(0)
      })
      
      return metaResult
    } catch (error) {
      console.error('🧠 [MEMORY] Error getting cell count from database:', error)
      return 0
    }
  }

  // Calculate optimal buffer size based on available memory
  calculateOptimalBufferSize(knownCellCount = null) {
    // Calculate optimal number of METADATA VECTORS to keep in memory
    // Based on: actual cell count, available memory, and safety margin
    
    const DEFAULT_BUFFER_SIZE = 5
    const MIN_BUFFER_SIZE = 3
    const MEMORY_ALLOCATION_MB = 300 // Allocate up to 300MB for metadata cache
    
    // Get cell count from current coordinates or metadata
    let cellCount = knownCellCount || 0
    
    if (cellCount === 0 && this.controller.currentCoordinates) {
      cellCount = this.controller.currentCoordinates.length
    } else if (cellCount === 0 && this.controller.metadataData) {
      cellCount = this.controller.metadataData.cellCount
    }
    
    // If no coordinates loaded yet, try to estimate from any loaded metadata vector
    if (cellCount === 0 && this.controller.loadedMetadataVectors) {
      const loadedIds = Object.keys(this.controller.loadedMetadataVectors)
      if (loadedIds.length > 0) {
        const firstMetadata = this.controller.loadedMetadataVectors[loadedIds[0]]
        if (firstMetadata && firstMetadata.values) {
          cellCount = firstMetadata.values.length
          console.log(`🧠 [MEMORY] Using cell count from loaded metadata: ${cellCount.toLocaleString()}`)
        }
      }
    }
    
    // If still no cell count, try to get from cached binary data
    if (cellCount === 0 && this.controller.binaryDataCache && this.controller.binaryDataCache.size > 0) {
      const firstEntry = this.controller.binaryDataCache.values().next().value
      if (firstEntry && firstEntry.coordinates) {
        cellCount = firstEntry.coordinates.length
        console.log(`🧠 [MEMORY] Using cell count from cached coordinates: ${cellCount.toLocaleString()}`)
      }
    }
    
    if (cellCount === 0) {
      console.log(`🧠 [MEMORY] No cell count available yet, using default buffer size: ${DEFAULT_BUFFER_SIZE} metadata vectors`)
      console.log(`🧠 [MEMORY] Buffer size will be recalculated once data is loaded`)
      return DEFAULT_BUFFER_SIZE
    }
    
    // Estimate bytes per metadata vector
    // - Discrete metadata: ~4 bytes per cell (string indices)
    // - Continuous metadata: ~8 bytes per cell (float64)
    // - Use worst case (continuous) for safety
    const bytesPerCell = 8
    const bytesPerVector = cellCount * bytesPerCell
    const mbPerVector = bytesPerVector / (1024 * 1024)
    
    // Check available memory
    let allocatedMB = MEMORY_ALLOCATION_MB
    
    if (performance.memory) {
      // Use actual available memory if API is available
      const memory = performance.memory
      const availableMemory = memory.jsHeapSizeLimit - memory.usedJSHeapSize
      const availableMB = availableMemory / (1024 * 1024)
      
      // Use the lesser of: configured allocation or 10% of available memory
      allocatedMB = Math.min(MEMORY_ALLOCATION_MB, availableMB * 0.10)
      
      console.log(`🧠 [MEMORY] Available: ${availableMB.toFixed(1)}MB, Using: ${allocatedMB.toFixed(1)}MB for cache`)
    } else {
      console.log(`🧠 [MEMORY] performance.memory not available, using fixed allocation: ${allocatedMB}MB`)
    }
    
    // Calculate how many vectors fit in allocated memory
    const optimalCount = Math.floor(allocatedMB / mbPerVector)
    const finalCount = Math.max(MIN_BUFFER_SIZE, optimalCount)
    
    console.log(`🧠 [MEMORY] Cell count: ${cellCount.toLocaleString()}, ~${mbPerVector.toFixed(2)}MB per vector`)
    console.log(`🧠 [MEMORY] Optimal metadata buffer: ${finalCount} vectors (${(finalCount * mbPerVector).toFixed(1)}MB total)`)
    
    return finalCount
  }

  // Update metadata usage tracker
  updateMetadataUsage(metadataId) {
    this.controller.metadataUsageTracker[metadataId] = Date.now()
  }

  // Get least recently used metadata for cleanup
  getLeastRecentlyUsedMetadata(limit = 1) {
    const metadataUsage = Object.keys(this.controller.metadataUsageTracker)
      .map(id => ({
        id,
        lastUsed: this.controller.metadataUsageTracker[id]
      }))
      .sort((a, b) => a.lastUsed - b.lastUsed)
    
    return metadataUsage.slice(0, limit)
  }

  // Store metadata vector in IndexedDB (disk storage)
  async storeMetadataInIndexedDB(metadataId, vectorData) {
    if (!this.controller.db) return false
    
    try {
      const transaction = this.controller.db.transaction(['metadata'], 'readwrite')
      const objectStore = transaction.objectStore('metadata')
      
      // Add loom file info for cache invalidation
      const dataToStore = {
        id: metadataId,
        loomFile: this.controller.currentLoomFile,
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
    if (!this.controller.db) {
      console.log(`💾 IndexedDB not available for metadata ${metadataId}`)
      return null
    }
    
    try {
      const transaction = this.controller.db.transaction(['metadata'], 'readonly')
      const objectStore = transaction.objectStore('metadata')
      
      // Convert to number if it's a string (IndexedDB stores as number)
      const numericId = typeof metadataId === 'string' ? parseInt(metadataId) : metadataId
      const request = objectStore.get(numericId)
      
      return new Promise((resolve, reject) => {
        request.onsuccess = () => {
          if (request.result) {
            const currentLoom = this.controller.currentLoomFile || this.controller.loomFileSelectTarget?.value || this.controller.defaultLoomFileValue
            
            // console.log(`💾 IndexedDB lookup for ${metadataId}:`, {
            //   found: true,
            //   storedLoomFile: request.result.loomFile,
            //   currentLoomFile: currentLoom,
            //   match: request.result.loomFile === currentLoom
            // })
            
            if (request.result.loomFile === currentLoom) {
              // console.log(`💾 ✅ Loaded metadata ${metadataId} from IndexedDB (disk storage)`)
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

  // Store embedding coordinates in IndexedDB (disk storage)
  async storeCoordinatesInIndexedDB(metadataId, coordinateData) {
    if (!this.controller.db) return false
    
    try {
      const transaction = this.controller.db.transaction(['coordinates'], 'readwrite')
      const objectStore = transaction.objectStore('coordinates')
      
      // Convert ArrayBuffer to base64 for storage
      const binaryString = String.fromCharCode.apply(null, new Uint8Array(coordinateData.binaryData))
      const base64Data = btoa(binaryString)
      
      // Add loom file info for cache invalidation
      const dataToStore = {
        id: metadataId,
        name: coordinateData.name,
        cellCount: coordinateData.cellCount,
        binaryData: base64Data, // Store as base64 string
        loomFile: this.controller.currentLoomFile,
        timestamp: Date.now()
      }
      
      objectStore.put(dataToStore)
      
      return new Promise((resolve, reject) => {
        transaction.oncomplete = () => {
          console.log(`💾 Stored coordinates ${metadataId} in IndexedDB (${(coordinateData.binaryData.byteLength / 1024).toFixed(1)}KB)`)
          resolve(true)
        }
        transaction.onerror = () => {
          console.error(`💾 Failed to store coordinates ${metadataId} in IndexedDB`)
          reject(false)
        }
      })
    } catch (error) {
      console.error('💾 Error storing coordinates in IndexedDB:', error)
      return false
    }
  }
  
  // Load embedding coordinates from IndexedDB (disk storage)
  async loadCoordinatesFromIndexedDB(metadataId) {
    if (!this.controller.db) {
      console.log(`💾 IndexedDB not available for coordinates ${metadataId}`)
      return null
    }
    
    try {
      const transaction = this.controller.db.transaction(['coordinates'], 'readonly')
      const objectStore = transaction.objectStore('coordinates')
      const request = objectStore.get(metadataId)
      
      return new Promise((resolve, reject) => {
        request.onsuccess = () => {
          if (request.result) {
            const currentLoom = this.controller.currentLoomFile || this.controller.loomFileSelectTarget?.value || this.controller.defaultLoomFileValue
            
            console.log(`💾 IndexedDB lookup for coordinates ${metadataId}:`, {
              found: true,
              storedLoomFile: request.result.loomFile,
              currentLoomFile: currentLoom,
              match: request.result.loomFile === currentLoom
            })
            
            if (request.result.loomFile === currentLoom) {
              console.log(`💾 ✅ Loaded coordinates ${metadataId} from IndexedDB (disk storage)`)
              
              // Convert base64 back to ArrayBuffer
              const binaryString = atob(request.result.binaryData)
              const bytes = new Uint8Array(binaryString.length)
              for (let i = 0; i < binaryString.length; i++) {
                bytes[i] = binaryString.charCodeAt(i)
              }
              
              // Return in same format as network fetch
              resolve({
                id: request.result.id,
                name: request.result.name,
                cellCount: request.result.cellCount,
                binaryData: bytes.buffer
              })
            } else {
              console.log(`💾 ⚠️ Loom file mismatch, ignoring cached coordinates for ${metadataId}`)
              resolve(null) // Wrong loom file
            }
          } else {
            console.log(`💾 Coordinates ${metadataId} not found in IndexedDB`)
            resolve(null)
          }
        }
        request.onerror = () => {
          console.error(`💾 Failed to load coordinates ${metadataId} from IndexedDB:`, request.error)
          resolve(null)
        }
      })
    } catch (error) {
      console.error('💾 Error loading coordinates from IndexedDB:', error)
      return null
    }
  }

  // Clear all IndexedDB cache (useful for debugging or when data is corrupted)
  async clearIndexedDBCache() {
    if (!this.controller.db) {
      console.log('💾 IndexedDB not available')
      return
    }
    
    try {
      const transaction = this.controller.db.transaction(['metadata'], 'readwrite')
      const objectStore = transaction.objectStore('metadata')
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

  // Clean up unused metadata from memory
  cleanupUnusedMetadata() {
    const currentCount = Object.keys(this.controller.loadedMetadataVectors).length
    console.log(`🧠 [Memory] cleanupUnusedMetadata() called - current count: ${currentCount}, max: ${this.controller.maxMetadataInMemory}`)
    console.log(`🧠 [Memory] Current keys:`, Object.keys(this.controller.loadedMetadataVectors))
    
    if (currentCount <= this.controller.maxMetadataInMemory) {
      console.log(`🧠 [Memory] No cleanup needed: ${currentCount}/${this.controller.maxMetadataInMemory} metadata in memory`)
      return
    }
    
    const toRemove = currentCount - this.controller.maxMetadataInMemory
    console.log(`🧠 [Memory] Need to remove ${toRemove} metadata vectors from memory`)
    
    // Get the least recently used metadata
    const lruMetadata = this.getLeastRecentlyUsedMetadata(toRemove)
    console.log(`🧠 [Memory] LRU metadata to consider removing:`, lruMetadata)
    
    // Don't remove the current metadata
    const currentMetadataId = this.controller.currentMetadataVector?.id
    console.log(`🧠 [Memory] Current metadata ID:`, currentMetadataId)
    const metadataToRemove = lruMetadata.filter(id => id !== currentMetadataId)
    console.log(`🧠 [Memory] Final list to remove:`, metadataToRemove)
    
    let removedCount = 0
    metadataToRemove.forEach(metadataId => {
      if (this.controller.loadedMetadataVectors[metadataId]) {
        console.log(`🧠 [Memory] Deleting metadata ${metadataId} from loadedMetadataVectors`)
        delete this.controller.loadedMetadataVectors[metadataId]
        this.controller.metadataUsageTracker.delete(metadataId)
        removedCount++
        console.log(`🧠 [Memory] Removed metadata ${metadataId} from memory`)
      }
    })
    
    console.log(`🧠 [Memory] Cleanup complete: removed ${removedCount} metadata vectors`)
    console.log(`🧠 [Memory] Remaining keys:`, Object.keys(this.controller.loadedMetadataVectors))
    
    // Force garbage collection if available
    if (window.gc) {
      window.gc()
      console.log('🧠 [Memory] Forced garbage collection')
    }
  }

  // Clear IndexedDB cache
  clearIndexedDBCache() {
    if (!this.controller.db) {
      console.log('❌ [MEMORY] No IndexedDB connection available')
      return Promise.resolve()
    }

    return new Promise((resolve, reject) => {
      const transaction = this.controller.db.transaction(['metadata'], 'readwrite')
      const objectStore = transaction.objectStore('metadata')
      const clearRequest = objectStore.clear()

      clearRequest.onsuccess = () => {
        console.log('🗄️ [MEMORY] IndexedDB cache cleared successfully')
        resolve()
      }

      clearRequest.onerror = () => {
        console.error('❌ [MEMORY] Failed to clear IndexedDB cache:', clearRequest.error)
        reject(clearRequest.error)
      }
    })
  }
}

