// Data Manager Module for Visualization
// Handles data loading, decompression, and metadata management

export class DataManager {
  constructor(controller) {
    this.controller = controller
    this.loadedMetadataVectors = {}
    this.currentMetadataVector = null
    this.currentMetadataId = null
    this.currentCoordinates = null
    this.currentBounds = null
  }

  // Load metadata coordinates
  async loadMetadataCoordinates(metadataId) {
    try {
      // Show loading spinner
      this.controller.showLoadingSpinner(metadataId)

      const response = await fetch(`/projects/${this.controller.projectId}/metadata/${metadataId}/coordinates`, {
        method: 'GET',
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        }
      })

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }

      const data = await response.json()
      
      // Store binary data
      this.storeBinaryMetadataData(data)
      
      // Hide loading spinner
      this.controller.hideLoadingSpinner(metadataId)
      
      // Update visualization
      this.updateVisualizationWithMetadata()
      
    } catch (error) {
      console.error('Error loading metadata coordinates:', error)
      this.controller.hideLoadingSpinner(metadataId)
    }
  }

  // Store binary metadata data
  storeBinaryMetadataData(data) {
    // Store coordinates
    if (data.coordinates) {
      this.controller.coordinates = data.coordinates
    }

    // Store metadata vectors
    if (data.metadata_vectors) {
      data.metadata_vectors.forEach(vector => {
        this.loadedMetadataVectors[vector.id] = vector
      })
    }

    // Store embeddings
    if (data.embeddings) {
      this.controller.embeddings = data.embeddings
    }
  }

  // Clear metadata data
  clearMetadataData() {
    this.controller.coordinates = null
    this.loadedMetadataVectors = {}
    this.controller.embeddings = null
    this.currentMetadataVector = null
    this.currentMetadataId = null
    this.currentCoordinates = null
    this.currentBounds = null
  }

  // Update visualization with metadata
  updateVisualizationWithMetadata() {
    if (this.controller.coordinates) {
      // Decompress coordinates
      const decompressedCoordinates = this.decompressBinaryCoordinates(this.controller.coordinates)
      
      // Update visualization
      this.controller.updateScatterPlot(decompressedCoordinates)
    }
  }

  // Decompress binary coordinates
  decompressBinaryCoordinates(arrayBuffer) {
    if (!arrayBuffer) return []

    try {
      // Convert ArrayBuffer to Uint8Array
      const uint8Array = new Uint8Array(arrayBuffer)
      
      // Create a new Uint8Array with the correct length
      const coordinates = new Float32Array(uint8Array.length / 4)
      
      // Convert bytes to float32 values
      for (let i = 0; i < coordinates.length; i++) {
        const byteIndex = i * 4
        const bytes = uint8Array.slice(byteIndex, byteIndex + 4)
        const view = new DataView(bytes.buffer)
        coordinates[i] = view.getFloat32(0, true) // little-endian
      }
      
      // Convert to coordinate pairs
      const coordinatePairs = []
      for (let i = 0; i < coordinates.length; i += 2) {
        coordinatePairs.push([coordinates[i], coordinates[i + 1]])
      }
      
      return coordinatePairs
    } catch (error) {
      console.error('Error decompressing coordinates:', error)
      return []
    }
  }

  // Get loaded metadata vector
  getLoadedMetadataVector(metadataId) {
    return this.loadedMetadataVectors[metadataId] || null
  }

  // Decompress discrete metadata vector
  decompressDiscreteMetadataVector(binaryData, compressionInfo) {
    if (!compressionInfo) return null
    
    // Handle optimized case: single category (no data needed)
    if (compressionInfo.single_category) {
      const { categories, category_index, length } = compressionInfo
      const categoryValue = categories[category_index] || 'Unknown'
      const values = new Array(length).fill(categoryValue)
      console.log(`Optimized single-category metadata: ${length} cells, all "${categoryValue}"`)
      return {
        values: values,
        categories: categories,
        data_type: 'DISCRETE'
      }
    }
    
    if (!binaryData) return null

    try {
      // Convert ArrayBuffer to Uint8Array
      const uint8Array = new Uint8Array(binaryData)
      
      // Decompress based on compression type
      if (compressionInfo.type === 'run_length') {
        return this.decompressRunLength(uint8Array, compressionInfo)
      } else if (compressionInfo.type === 'dictionary') {
        return this.decompressDictionary(uint8Array, compressionInfo)
      } else {
        console.error('Unknown compression type:', compressionInfo.type)
        return null
      }
    } catch (error) {
      console.error('Error decompressing discrete metadata vector:', error)
      return null
    }
  }

  // Decompress run-length encoded data
  decompressRunLength(uint8Array, compressionInfo) {
    const values = []
    let i = 0
    
    while (i < uint8Array.length) {
      const value = uint8Array[i]
      const count = uint8Array[i + 1]
      
      for (let j = 0; j < count; j++) {
        values.push(compressionInfo.categories[value])
      }
      
      i += 2
    }
    
    return {
      values: values,
      categories: compressionInfo.categories,
      data_type: 'DISCRETE'
    }
  }

  // Decompress dictionary encoded data
  decompressDictionary(uint8Array, compressionInfo) {
    const values = []
    
    for (let i = 0; i < uint8Array.length; i++) {
      const index = uint8Array[i]
      values.push(compressionInfo.categories[index])
    }
    
    return {
      values: values,
      categories: compressionInfo.categories,
      data_type: 'DISCRETE'
    }
  }

  // Decompress continuous metadata vector
  decompressContinuousMetadataVector(binaryData, compressionInfo) {
    if (!binaryData || !compressionInfo) return null

    try {
      // Convert ArrayBuffer to Float32Array
      const float32Array = new Float32Array(binaryData)
      
      return {
        values: Array.from(float32Array),
        compression_info: compressionInfo,
        data_type: 'CONTINUOUS'
      }
    } catch (error) {
      console.error('Error decompressing continuous metadata vector:', error)
      return null
    }
  }

  // Load and visualize metadata vector
  async loadAndVisualizeMetadataVector(metadataId) {
    try {
      // Show loading spinner
      this.controller.showLoadingSpinner(metadataId)

      const response = await fetch(`/projects/${this.controller.projectId}/metadata/${metadataId}/vector`, {
        method: 'GET',
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        }
      })

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }

      const vectorData = await response.json()
      
      // Validate response
      if (!vectorData.compressed_data || !vectorData.compression_info) {
        throw new Error('Invalid vector data received')
      }

      // Decompress metadata vector
      let decompressedVector
      if (vectorData.data_type === 'DISCRETE') {
        decompressedVector = this.decompressDiscreteMetadataVector(
          vectorData.compressed_data,
          vectorData.compression_info
        )
      } else if (vectorData.data_type === 'CONTINUOUS') {
        decompressedVector = this.decompressContinuousMetadataVector(
          vectorData.compressed_data,
          vectorData.compression_info
        )
      } else {
        throw new Error(`Unknown data type: ${vectorData.data_type}`)
      }

      if (!decompressedVector) {
        throw new Error('Failed to decompress metadata vector')
      }

      // Set current metadata
      this.currentMetadataId = metadataId
      this.currentMetadataVector = decompressedVector
      this.controller.clearColorMapCache()
      this.loadedMetadataVectors[metadataId] = this.currentMetadataVector
      this.controller.showCheckboxesForMetadata(metadataId)
      this.controller.clearIncrementalState()
      this.controller.updateCategoriesCheckboxState()

      // Hide loading spinner
      this.controller.hideLoadingSpinner(metadataId)

      // Render points with new coloring
      this.controller.renderPointsWithCurrentColoring()

      // Update legend
      this.controller.addCategoryColors(
        document.querySelector(`[data-metadata-item="${metadataId}"]`),
        metadataId
      )

      // Update filtering
      this.controller.updateCellFiltering()

    } catch (error) {
      console.error('Error loading metadata vector:', error)
      this.controller.hideLoadingSpinner(metadataId)
    }
  }

  // Get metadata vector by ID (with decompression on demand)
  getMetadataVectorById(metadataId) {
    // Check if already loaded
    if (this.loadedMetadataVectors[metadataId]) {
      return this.loadedMetadataVectors[metadataId]
    }

    // Check if we have the raw data
    const rawVector = this.controller.loadedMetadataVectors[metadataId]
    if (!rawVector) {
      return null
    }

    // Decompress on demand
    let decompressedVector
    if (rawVector.data_type === 'DISCRETE') {
      decompressedVector = this.decompressDiscreteMetadataVector(
        rawVector.compressed_data,
        rawVector.compression_info
      )
    } else if (rawVector.data_type === 'CONTINUOUS') {
      decompressedVector = this.decompressContinuousMetadataVector(
        rawVector.compressed_data,
        rawVector.compression_info
      )
    }

    if (decompressedVector) {
      this.loadedMetadataVectors[metadataId] = decompressedVector
      return decompressedVector
    }

    return null
  }

  // Clear metadata coloring
  clearMetadataColoring() {
    this.currentMetadataId = null
    this.currentMetadataVector = null
    this.controller.clearColorMapCache()
    
    // Hide checkboxes
    this.controller.hideAllCheckboxes()
    
    // Clear selection
    this.controller.selectedCells = new Set()
    this.controller.updateSelectedCellsCount()
    
    // Re-render with default coloring
    this.controller.renderPointsWithCurrentColoring()
  }

  // Clear loaded metadata vectors cache
  clearLoadedMetadataVectorsCache() {
    this.loadedMetadataVectors = {}
  }

  // Detect embedding method change
  detectEmbeddingMethodChange(newCoordinates) {
    if (!this.currentCoordinates || this.currentCoordinates.length !== newCoordinates.length) {
      return true
    }

    // Compare coordinate statistics to detect embedding method changes
    const oldStats = this.calculateCoordinateStats(this.currentCoordinates)
    const newStats = this.calculateCoordinateStats(newCoordinates)

    // If statistics are significantly different, it's likely a different embedding method
    const threshold = 0.1 // 10% difference threshold
    const meanDiff = Math.abs(oldStats.meanX - newStats.meanX) / Math.abs(oldStats.meanX)
    const stdDiff = Math.abs(oldStats.stdX - newStats.stdX) / Math.abs(oldStats.stdX)

    return meanDiff > threshold || stdDiff > threshold
  }

  // Calculate coordinate statistics
  calculateCoordinateStats(coordinates) {
    if (coordinates.length === 0) {
      return { meanX: 0, meanY: 0, stdX: 0, stdY: 0 }
    }

    let sumX = 0, sumY = 0
    coordinates.forEach(([x, y]) => {
      sumX += x
      sumY += y
    })

    const meanX = sumX / coordinates.length
    const meanY = sumY / coordinates.length

    let sumSqX = 0, sumSqY = 0
    coordinates.forEach(([x, y]) => {
      sumSqX += (x - meanX) ** 2
      sumSqY += (y - meanY) ** 2
    })

    const stdX = Math.sqrt(sumSqX / coordinates.length)
    const stdY = Math.sqrt(sumSqY / coordinates.length)

    return { meanX, meanY, stdX, stdY }
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

  // Get adjusted bounds (with margins for axes)
  getAdjustedBounds(originalBounds) {
    if (!originalBounds || !this.controller.axesContainer || !this.controller.axesContainer.visible) {
      return originalBounds
    }

    const { minX, maxX, minY, maxY } = originalBounds
    const width = this.controller.pixiApp.screen.width
    const height = this.controller.pixiApp.screen.height

    // Calculate margins needed for axes
    const leftMargin = 60   // Space for Y-axis labels
    const bottomMargin = 60 // Space for X-axis labels

    // Calculate the data range that fits in the available space
    const availableWidth = width - leftMargin - 20  // 20px right margin
    const availableHeight = height - bottomMargin - 20 // 20px top margin

    // Calculate the data range per pixel
    const dataWidth = maxX - minX
    const dataHeight = maxY - minY
    const dataPerPixelX = dataWidth / (width - 100) // Original calculation
    const dataPerPixelY = dataHeight / (height - 100) // Original calculation

    // Adjust bounds to account for margins
    const adjustedMinX = minX - (leftMargin * dataPerPixelX)
    const adjustedMaxX = maxX + (20 * dataPerPixelX)
    const adjustedMinY = minY - (20 * dataPerPixelY)
    const adjustedMaxY = maxY + (bottomMargin * dataPerPixelY)

    return {
      minX: adjustedMinX,
      maxX: adjustedMaxX,
      minY: adjustedMinY,
      maxY: adjustedMaxY
    }
  }

  // Normalize X coordinate to screen space
  normalizeX(x, bounds) {
    return ((x - bounds.minX) / (bounds.maxX - bounds.minX)) * this.controller.pixiApp.screen.width
  }

  // Normalize Y coordinate to screen space
  normalizeY(y, bounds) {
    return ((y - bounds.minY) / (bounds.maxY - bounds.minY)) * this.controller.pixiApp.screen.height
  }

  // Cleanup method
  destroy() {
    this.loadedMetadataVectors = {}
    this.currentMetadataVector = null
    this.currentMetadataId = null
    this.currentCoordinates = null
    this.currentBounds = null
  }
}
