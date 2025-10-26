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
  cleanupUnusedMetadata() {
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

  // Calculate optimal buffer size based on available memory
  calculateOptimalBufferSize() {
    if (!performance.memory) {
      return 100000 // Default fallback
    }
    
    const memory = performance.memory
    const availableMemory = memory.jsHeapSizeLimit - memory.usedJSHeapSize
    const memoryMB = availableMemory / 1024 / 1024
    
    // Estimate buffer size based on available memory
    // Each point uses ~8 bytes (2 floats for x,y), so 1MB can hold ~125k points
    const estimatedMaxPoints = Math.floor(memoryMB * 125000)
    const optimalBufferSize = Math.min(estimatedMaxPoints, 500000) // Cap at 500k points
    
    console.log(`🧠 [MEMORY] Available: ${memoryMB.toFixed(1)}MB, Optimal buffer: ${optimalBufferSize.toLocaleString()} points`)
    
    return Math.max(optimalBufferSize, 50000) // Minimum 50k points
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
      const request = objectStore.get(metadataId)
      
      return new Promise((resolve, reject) => {
        request.onsuccess = () => {
          if (request.result) {
            const currentLoom = this.controller.currentLoomFile || this.controller.loomFileSelectTarget?.value || this.controller.defaultLoomFileValue
            
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
    
    if (currentCount <= this.controller.maxMetadataInMemory) {
      console.log(`🧠 [Memory] No cleanup needed: ${currentCount}/${this.controller.maxMetadataInMemory} metadata in memory`)
      return
    }
    
    const toRemove = currentCount - this.controller.maxMetadataInMemory
    console.log(`🧠 [Memory] Need to remove ${toRemove} metadata vectors from memory`)
    
    // Get the least recently used metadata
    const lruMetadata = this.getLeastRecentlyUsedMetadata(toRemove)
    
    // Don't remove the current metadata
    const currentMetadataId = this.controller.currentMetadataVector?.id
    const metadataToRemove = lruMetadata.filter(id => id !== currentMetadataId)
    
    let removedCount = 0
    metadataToRemove.forEach(metadataId => {
      if (this.controller.loadedMetadataVectors[metadataId]) {
        delete this.controller.loadedMetadataVectors[metadataId]
        this.controller.metadataUsageTracker.delete(metadataId)
        removedCount++
        console.log(`🧠 [Memory] Removed metadata ${metadataId} from memory`)
      }
    })
    
    console.log(`🧠 [Memory] Cleanup complete: removed ${removedCount} metadata vectors`)
    
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

