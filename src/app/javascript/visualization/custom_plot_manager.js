/**
 * Custom Plot Manager Module
 * Handles the 2D custom plot modal functionality
 */

export class CustomPlotManager {
  constructor(controller) {
    this.controller = controller
    // Cache for point positions in violin plots (to avoid recomputing on resize)
    this.violinPointPositions = new Map()
  }

  // Check if both x and y are selected and open modal
  checkAndOpen2DPlotModal() {
    if (this.controller.selectedXButton && this.controller.selectedYButton) {
      console.log('📊 Both x and y buttons selected, opening 2D plot modal...')
      this.open2DPlotModal()
    }
  }
  
  // Close 2D plot modal
  close2DPlotModal(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const modal = document.getElementById('2d-plot-modal')
    if (modal) {
      modal.style.display = 'none'
    }
  }
  
  // Make 2D plot modal draggable
  make2DPlotModalDraggable() {
    const modal = document.getElementById('2d-plot-modal')
    const header = document.getElementById('2d-plot-header')
    const closeBtn = document.getElementById('close-2d-plot-modal')
    
    if (!modal || !header) return
    
    // Add direct event listener for close button (like settings window)
    if (closeBtn) {
      closeBtn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        modal.style.display = 'none'
      })
    }
    
    let isDragging = false
    let currentX = 0
    let currentY = 0
    let initialX = 0
    let initialY = 0
    
    const startDrag = (e) => {
      // Don't start drag if clicking on the close button
      if (e.target.closest('#close-2d-plot-modal')) {
        return
      }
      
      if (e.button !== 0 && e.type !== 'touchstart') return // Only left mouse button
      
      isDragging = true
      initialX = e.type === 'mousedown' ? e.clientX : e.touches[0].clientX
      initialY = e.type === 'mousedown' ? e.clientY : e.touches[0].clientY
      
      // Get current position
      const rect = modal.getBoundingClientRect()
      currentX = rect.left
      currentY = rect.top
      
      // Prevent text selection
      e.preventDefault()
    }
    
    const drag = (e) => {
      if (!isDragging) return
      
      e.preventDefault()
      
      const x = e.type === 'mousemove' ? e.clientX : e.touches[0].clientX
      const y = e.type === 'mousemove' ? e.clientY : e.touches[0].clientY
      
      const dx = x - initialX
      const dy = y - initialY
      
      const newX = currentX + dx
      const newY = currentY + dy
      
      // Keep modal within viewport
      const maxX = window.innerWidth - modal.offsetWidth
      const maxY = window.innerHeight - modal.offsetHeight
      
      modal.style.left = Math.max(0, Math.min(newX, maxX)) + 'px'
      modal.style.top = Math.max(0, Math.min(newY, maxY)) + 'px'
      modal.style.transform = 'none' // Remove center transform when dragging
    }
    
    const stopDrag = () => {
      isDragging = false
    }
    
    header.addEventListener('mousedown', startDrag)
    header.addEventListener('touchstart', startDrag)
    
    document.addEventListener('mousemove', drag)
    document.addEventListener('touchmove', drag)
    
    document.addEventListener('mouseup', stopDrag)
    document.addEventListener('touchend', stopDrag)
  }
  
  // Make 2D plot modal resizable
  make2DPlotModalResizable() {
    const modal = document.getElementById('2d-plot-modal')
    const resizeRight = document.getElementById('2d-plot-resize-right')
    const resizeBottom = document.getElementById('2d-plot-resize-bottom')
    const resizeCorner = document.getElementById('2d-plot-resize-corner')
    
    if (!modal) return
    
    let isResizing = false
    let resizeType = null // 'right', 'bottom', 'corner'
    let startX = 0
    let startY = 0
    let startWidth = 0
    let startHeight = 0
    let startLeft = 0
    let startTop = 0
    
    const startResize = (e, type) => {
      if (e.button !== 0 && e.type !== 'touchstart') return
      
      isResizing = true
      resizeType = type
      startX = e.type === 'mousedown' ? e.clientX : e.touches[0].clientX
      startY = e.type === 'mousedown' ? e.clientY : e.touches[0].clientY
      
      const rect = modal.getBoundingClientRect()
      startWidth = rect.width
      startHeight = rect.height
      startLeft = rect.left
      startTop = rect.top
      
      e.preventDefault()
      e.stopPropagation()
    }
    
    const doResize = (e) => {
      if (!isResizing) return
      
      e.preventDefault()
      
      const currentX = e.type === 'mousemove' ? e.clientX : e.touches[0].clientX
      const currentY = e.type === 'mousemove' ? e.clientY : e.touches[0].clientY
      
      const deltaX = currentX - startX
      const deltaY = currentY - startY
      
      let newWidth = startWidth
      let newHeight = startHeight
      let newLeft = startLeft
      let newTop = startTop
      
      if (resizeType === 'right' || resizeType === 'corner') {
        newWidth = startWidth + deltaX
      }
      
      if (resizeType === 'bottom' || resizeType === 'corner') {
        newHeight = startHeight + deltaY
      }
      
      // Apply constraints
      const minWidth = 400
      const minHeight = 300
      const maxWidth = window.innerWidth - 20
      const maxHeight = window.innerHeight - 20
      
      newWidth = Math.max(minWidth, Math.min(newWidth, maxWidth))
      newHeight = Math.max(minHeight, Math.min(newHeight, maxHeight))
      
      // Apply new size
      modal.style.width = newWidth + 'px'
      modal.style.height = newHeight + 'px'
      modal.style.transform = 'none' // Remove center transform when resizing
      
      // Adjust position if needed to keep within viewport
      const rect = modal.getBoundingClientRect()
      if (rect.right > window.innerWidth) {
        modal.style.left = (window.innerWidth - newWidth) + 'px'
      }
      if (rect.bottom > window.innerHeight) {
        modal.style.top = (window.innerHeight - newHeight) + 'px'
      }
      if (rect.left < 0) {
        modal.style.left = '0px'
      }
      if (rect.top < 0) {
        modal.style.top = '0px'
      }
      
      // Update canvas size when modal is resized
      this.update2DPlotCanvasSize()
    }
    
    const stopResize = () => {
      if (isResizing) {
        isResizing = false
        resizeType = null
        // Update canvas size after resize completes
        this.update2DPlotCanvasSize()
      }
    }
    
    // Right edge resize
    if (resizeRight) {
      resizeRight.addEventListener('mousedown', (e) => startResize(e, 'right'))
      resizeRight.addEventListener('touchstart', (e) => startResize(e, 'right'))
    }
    
    // Bottom edge resize
    if (resizeBottom) {
      resizeBottom.addEventListener('mousedown', (e) => startResize(e, 'bottom'))
      resizeBottom.addEventListener('touchstart', (e) => startResize(e, 'bottom'))
    }
    
    // Corner resize
    if (resizeCorner) {
      resizeCorner.addEventListener('mousedown', (e) => startResize(e, 'corner'))
      resizeCorner.addEventListener('touchstart', (e) => startResize(e, 'corner'))
    }
    
    document.addEventListener('mousemove', doResize)
    document.addEventListener('touchmove', doResize)
    document.addEventListener('mouseup', stopResize)
    document.addEventListener('touchend', stopResize)
  }
  
  // Update 2D plot canvas size based on modal size
  update2DPlotCanvasSize() {
    const canvas = document.getElementById('2d-plot-canvas')
    const modal = document.getElementById('2d-plot-modal')
    
    if (!canvas || !modal || modal.style.display === 'none') return
    
    const contentArea = canvas.parentElement.parentElement
    const contentRect = contentArea.getBoundingClientRect()
    const availableWidth = contentRect.width - 32 // padding
    const availableHeight = contentRect.height - 32 // padding
    
    // Set canvas size (use available space, but allow horizontal scroll if wider)
    const canvasWidth = Math.max(availableWidth, 600) // Minimum 600px width
    const canvasHeight = Math.max(availableHeight, 400) // Minimum 400px height
    
    canvas.width = canvasWidth
    canvas.height = canvasHeight
    canvas.style.width = canvasWidth + 'px'
    canvas.style.height = canvasHeight + 'px'
    
    // Re-render the plot if data is already loaded
    if (this.controller.selectedXButton && this.controller.selectedYButton) {
      this.refresh2DPlotIfOpen()
    }
  }
  
  // Open 2D plot modal and render plot
  async open2DPlotModal() {
    if (!this.controller.selectedXButton || !this.controller.selectedYButton) {
      console.error('Cannot open 2D plot modal - x or y button not selected')
      return
    }
    
    const modal = document.getElementById('2d-plot-modal')
    if (!modal) {
      console.error('2D plot modal not found in DOM')
      return
    }
    
    // Initialize dragging and resizing (only once)
    if (!modal.dataset.draggableInitialized) {
      this.make2DPlotModalDraggable()
      this.make2DPlotModalResizable()
      modal.dataset.draggableInitialized = 'true'
    }
    
    // Show modal and loading indicator
    modal.style.display = 'flex'
    const loadingDiv = document.getElementById('2d-plot-loading')
    const canvas = document.getElementById('2d-plot-canvas')
    if (loadingDiv) loadingDiv.style.display = 'block'
    if (canvas) canvas.style.display = 'none'
    
    
    try {
      // Load x and y data vectors
      const xMetadataId = this.controller.selectedXButton.isGene ? `gene_${this.controller.selectedXButton.metadataId}` : this.controller.selectedXButton.metadataId
      const yMetadataId = this.controller.selectedYButton.isGene ? `gene_${this.controller.selectedYButton.metadataId}` : this.controller.selectedYButton.metadataId
      
      console.log('📊 Loading data for 2D plot:', { xMetadataId, yMetadataId })
      
      // Load x vector
      let xVector = null
      if (this.controller.selectedXButton.isGene) {
        // Load gene expression data
        const geneId = this.controller.selectedXButton.metadataId
        const geneMetadataId = `gene_${geneId}`
        if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
          xVector = this.controller.loadedMetadataVectors[geneMetadataId]
        } else {
          // Load gene data - find the gene and load its expression
          const gene = this.controller.geneManager.geneTags?.find(g => g.stableId === geneId || String(g.stableId) === String(geneId))
          if (gene) {
            await this.controller.geneManager.loadGeneExpressionData(gene, null)
          }
          // GeneManager stores data in loadedMetadataVectors when gene is loaded
          // Also check geneExpressionData as fallback
          if (this.controller.loadedMetadataVectors[geneMetadataId]) {
            xVector = this.controller.loadedMetadataVectors[geneMetadataId]
          } else if (this.controller.geneManager.geneExpressionData[geneId]) {
            // Create vector from gene expression data
            const geneData = this.controller.geneManager.geneExpressionData[geneId]
            const minVal = this.controller.dataManager.safeMin(geneData.values)
            const maxVal = this.controller.dataManager.safeMax(geneData.values)
            xVector = {
              id: geneMetadataId,
              name: geneData.symbol || `Gene ${geneId}`,
              display_name: geneData.symbol || `Gene ${geneId}`,
              data_type: 'NUMERIC',
              values: geneData.values,
              compression_info: {
                min_val: minVal,
                max_val: maxVal,
                data_type: 'NUMERIC'
              }
            }
            this.controller.loadedMetadataVectors[geneMetadataId] = xVector
          }
        }
      } else {
        // Load metadata vector
        xVector = await this.controller.dataManager.loadSingleMetadataVector(xMetadataId)
        if (xVector) {
          // Ensure values are decompressed
          if (!xVector.values && xVector.compressed_data) {
            // Decompress if needed
            if (xVector.data_type === 'DISCRETE' || xVector.data_type === 'STRING') {
              xVector.values = this.controller.dataManager.decompressDiscreteMetadataVector(xVector.compressed_data, xVector.compression_info)
            } else if (xVector.data_type === 'NUMERIC') {
              xVector.values = this.controller.dataManager.decompressContinuousMetadataVector(xVector.compressed_data, xVector.compression_info)
            }
          }
          this.controller.loadedMetadataVectors[xMetadataId] = xVector
        }
      }
      
      // Load y vector
      let yVector = null
      if (this.controller.selectedYButton.isGene) {
        // Load gene expression data
        const geneId = this.controller.selectedYButton.metadataId
        const geneMetadataId = `gene_${geneId}`
        if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
          yVector = this.controller.loadedMetadataVectors[geneMetadataId]
        } else {
          // Load gene data - find the gene and load its expression
          const gene = this.controller.geneManager.geneTags?.find(g => g.stableId === geneId || String(g.stableId) === String(geneId))
          if (gene) {
            await this.controller.geneManager.loadGeneExpressionData(gene, null)
          }
          // GeneManager stores data in loadedMetadataVectors when gene is loaded
          // Also check geneExpressionData as fallback
          if (this.controller.loadedMetadataVectors[geneMetadataId]) {
            yVector = this.controller.loadedMetadataVectors[geneMetadataId]
          } else if (this.controller.geneManager.geneExpressionData[geneId]) {
            // Create vector from gene expression data
            const geneData = this.controller.geneManager.geneExpressionData[geneId]
            const minVal = this.controller.dataManager.safeMin(geneData.values)
            const maxVal = this.controller.dataManager.safeMax(geneData.values)
            yVector = {
              id: geneMetadataId,
              name: geneData.symbol || `Gene ${geneId}`,
              display_name: geneData.symbol || `Gene ${geneId}`,
              data_type: 'NUMERIC',
              values: geneData.values,
              compression_info: {
                min_val: minVal,
                max_val: maxVal,
                data_type: 'NUMERIC'
              }
            }
            this.controller.loadedMetadataVectors[geneMetadataId] = yVector
          }
        }
      } else {
        // Load metadata vector
        yVector = await this.controller.dataManager.loadSingleMetadataVector(yMetadataId)
        if (yVector) {
          // Ensure values are decompressed
          if (!yVector.values && yVector.compressed_data) {
            // Decompress if needed
            if (yVector.data_type === 'DISCRETE' || yVector.data_type === 'STRING') {
              yVector.values = this.controller.dataManager.decompressDiscreteMetadataVector(yVector.compressed_data, yVector.compression_info)
            } else if (yVector.data_type === 'NUMERIC') {
              yVector.values = this.controller.dataManager.decompressContinuousMetadataVector(yVector.compressed_data, yVector.compression_info)
            }
          }
          this.controller.loadedMetadataVectors[yMetadataId] = yVector
        }
      }
      
      if (!xVector || !yVector) {
        console.error('Failed to load data vectors for 2D plot', { xVector: !!xVector, yVector: !!yVector })
        if (loadingDiv) loadingDiv.style.display = 'none'
        alert('Failed to load data for 2D plot')
        return
      }
      
      // Ensure both vectors have values
      if (!xVector.values || !yVector.values) {
        console.error('Vectors missing values', { 
          xHasValues: !!xVector.values, 
          yHasValues: !!yVector.values,
          xVector,
          yVector
        })
        if (loadingDiv) loadingDiv.style.display = 'none'
        alert('Failed to decompress data for 2D plot')
        return
      }
      
      // Get filtered indices
      const filteredIndices = this.controller.dataManager.getIncrementalFilteredIndices()
      
      // Determine plot type and render
      const isXCategorical = xVector.data_type === 'DISCRETE' || xVector.data_type === 'STRING'
      const isYCategorical = yVector.data_type === 'DISCRETE' || yVector.data_type === 'STRING'
      
      // Hide loading, show canvas
      if (loadingDiv) loadingDiv.style.display = 'none'
      if (canvas) {
        canvas.style.display = 'block'
        
        // Calculate canvas size based on modal content area
        const contentArea = canvas.parentElement.parentElement
        const contentRect = contentArea.getBoundingClientRect()
        const availableWidth = contentRect.width - 32 // padding
        const availableHeight = contentRect.height - 32 // padding
        
        // Set canvas size (use available space, but allow horizontal scroll if wider)
        const canvasWidth = Math.max(availableWidth, 600) // Minimum 600px width
        const canvasHeight = Math.max(availableHeight, 400) // Minimum 400px height
        
        canvas.width = canvasWidth
        canvas.height = canvasHeight
        canvas.style.width = canvasWidth + 'px'
        canvas.style.height = canvasHeight + 'px'
      }
      
      if (isXCategorical) {
        // Render violin plot
        await this.renderViolinPlot2D(canvas, xVector, yVector, filteredIndices)
      } else {
        // Render scatter plot (both numerical)
        await this.renderScatterPlot2D(canvas, xVector, yVector, filteredIndices)
      }
      
    } catch (error) {
      console.error('Error opening 2D plot modal:', error)
      if (loadingDiv) loadingDiv.style.display = 'none'
      alert('Error loading 2D plot: ' + error.message)
    }
  }
  
  // Helper to get decompressed values from a vector
  getVectorValues(vector) {
    if (vector.values) {
      return vector.values
    }
    
    // Need to decompress
    if (vector.compressed_data && vector.compression_info) {
      if (vector.data_type === 'DISCRETE' || vector.data_type === 'STRING') {
        return this.controller.dataManager.decompressDiscreteMetadataVector(vector.compressed_data, vector.compression_info)
      } else if (vector.data_type === 'NUMERIC') {
        return this.controller.dataManager.decompressContinuousMetadataVector(vector.compressed_data, vector.compression_info)
      }
    }
    
    console.error('Cannot get values from vector:', vector)
    return null
  }
  
  // Helper to get gene expression values
  async getGeneExpressionValues(geneId) {
    const geneMetadataId = `gene_${geneId}`
    
    // Check if already loaded
    if (this.controller.loadedMetadataVectors[geneMetadataId]?.values) {
      return this.controller.loadedMetadataVectors[geneMetadataId].values
    }
    
    // Load gene expression
    await this.controller.geneManager.loadGeneExpression(geneId)
    
    // Check again after loading
    if (this.controller.loadedMetadataVectors[geneMetadataId]?.values) {
      return this.controller.loadedMetadataVectors[geneMetadataId].values
    }
    
    // Fallback to geneExpressionData
    if (this.controller.geneManager.geneExpressionData[geneId]?.values) {
      return this.controller.geneManager.geneExpressionData[geneId].values
    }
    
    console.error('Failed to load gene expression for', geneId)
    return null
  }
  
  // Refresh 2D plot modal if it's open (called when coloring changes)
  async refresh2DPlotIfOpen() {
    const modal = document.getElementById('2d-plot-modal')
    if (!modal || modal.style.display === 'none') {
      return // Modal is not open
    }
    
    // Check if we have both x and y buttons selected
    if (!this.controller.selectedXButton || !this.controller.selectedYButton) {
      return
    }
    
    console.log('📊 Refreshing 2D plot modal due to coloring change')
    
    try {
      // Get the canvas and data vectors
      const canvas = document.getElementById('2d-plot-canvas')
      if (!canvas) return
      
      // Get filtered indices
      const filteredIndices = this.controller.dataManager?.getIncrementalFilteredIndices()
      
      // Load x and y data vectors (same as open2DPlotModal)
      const xMetadataId = this.controller.selectedXButton.isGene ? `gene_${this.controller.selectedXButton.metadataId}` : this.controller.selectedXButton.metadataId
      const yMetadataId = this.controller.selectedYButton.isGene ? `gene_${this.controller.selectedYButton.metadataId}` : this.controller.selectedYButton.metadataId
      
      // Load x vector
      let xVector = null
      if (this.controller.selectedXButton.isGene) {
        const geneId = this.controller.selectedXButton.metadataId
        const geneMetadataId = `gene_${geneId}`
        if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
          xVector = this.controller.loadedMetadataVectors[geneMetadataId]
        } else {
          const gene = this.controller.geneManager.geneTags?.find(g => g.stableId === geneId || String(g.stableId) === String(geneId))
          if (gene) {
            await this.controller.geneManager.loadGeneExpressionData(gene, null)
          }
          if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
            xVector = this.controller.loadedMetadataVectors[geneMetadataId]
          } else if (this.controller.geneManager.geneExpressionData[geneId]?.values) {
            // Store in loadedMetadataVectors for consistency
            const geneVector = {
              id: geneMetadataId,
              name: gene.symbol,
              values: this.controller.geneManager.geneExpressionData[geneId].values,
              data_type: 'NUMERIC',
              compression_info: this.controller.geneManager.geneExpressionData[geneId].compression_info
            }
            this.controller.loadedMetadataVectors[geneMetadataId] = geneVector
            xVector = geneVector
          }
        }
      } else {
        xVector = await this.controller.dataManager.loadSingleMetadataVector(xMetadataId)
      }
      
      // Load y vector
      let yVector = null
      if (this.controller.selectedYButton.isGene) {
        const geneId = this.controller.selectedYButton.metadataId
        const geneMetadataId = `gene_${geneId}`
        if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
          yVector = this.controller.loadedMetadataVectors[geneMetadataId]
        } else {
          const gene = this.controller.geneManager.geneTags?.find(g => g.stableId === geneId || String(g.stableId) === String(geneId))
          if (gene) {
            await this.controller.geneManager.loadGeneExpressionData(gene, null)
          }
          if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
            yVector = this.controller.loadedMetadataVectors[geneMetadataId]
          } else if (this.controller.geneManager.geneExpressionData[geneId]?.values) {
            // Store in loadedMetadataVectors for consistency
            const geneVector = {
              id: geneMetadataId,
              name: gene.symbol,
              values: this.controller.geneManager.geneExpressionData[geneId].values,
              data_type: 'NUMERIC',
              compression_info: this.controller.geneManager.geneExpressionData[geneId].compression_info
            }
            this.controller.loadedMetadataVectors[geneMetadataId] = geneVector
            yVector = geneVector
          }
        }
      } else {
        yVector = await this.controller.dataManager.loadSingleMetadataVector(yMetadataId)
      }
      
      if (!xVector || !yVector) {
        console.error('Cannot refresh 2D plot - missing vectors')
        return
      }
      
      // Determine plot type and render
      const isXCategorical = xVector.data_type === 'DISCRETE' || xVector.data_type === 'STRING'
      
      if (isXCategorical) {
        // Render violin plot
        await this.renderViolinPlot2D(canvas, xVector, yVector, filteredIndices)
      } else {
        // Render scatter plot (both numerical)
        await this.renderScatterPlot2D(canvas, xVector, yVector, filteredIndices)
      }
    } catch (error) {
      console.error('Error refreshing 2D plot:', error)
    }
  }
  
  // Render scatter plot for 2D modal (both x and y are numerical)
  async renderScatterPlot2D(canvas, xVector, yVector, filteredIndices) {
    console.log('📊 Rendering scatter plot 2D')
    
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    
    // Clear canvas
    ctx.clearRect(0, 0, width, height)
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(0, 0, width, height)
    
    // Get values
    const xValues = this.getVectorValues(xVector)
    const yValues = this.getVectorValues(yVector)
    
    if (!xValues || !yValues || xValues.length !== yValues.length) {
      console.error('Invalid data for scatter plot')
      return
    }
    
    // Apply filtering
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const dataPoints = []
    for (let i = 0; i < xValues.length; i++) {
      if (!filteredSet || filteredSet.has(i)) {
        dataPoints.push({
          x: xValues[i],
          y: yValues[i],
          cellIndex: i
        })
      }
    }
    
    if (dataPoints.length === 0) {
      ctx.fillStyle = '#6b7280'
      ctx.font = '16px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('No data points to display', width / 2, height / 2)
      return
    }
    
    // Calculate bounds
    const xMin = Math.min(...dataPoints.map(p => p.x))
    const xMax = Math.max(...dataPoints.map(p => p.x))
    const yMin = Math.min(...dataPoints.map(p => p.y))
    const yMax = Math.max(...dataPoints.map(p => p.y))
    
    const xRange = xMax - xMin || 1
    const yRange = yMax - yMin || 1
    
    // Padding for axes
    const padding = 60
    
    // Scale functions
    const scaleX = (x) => padding + ((x - xMin) / xRange) * (width - 2 * padding)
    const scaleY = (y) => height - padding - ((y - yMin) / yRange) * (height - 2 * padding)
    
    // Draw axes
    ctx.strokeStyle = '#d1d5db'
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(padding, height - padding)
    ctx.lineTo(width - padding, height - padding)
    ctx.moveTo(padding, height - padding)
    ctx.lineTo(padding, padding)
    ctx.stroke()
    
    // Draw axis labels
    ctx.fillStyle = '#374151'
    ctx.font = '12px sans-serif'
    ctx.textAlign = 'center'
    ctx.fillText(this.controller.selectedXButton.metadataName, width / 2, height - 10)
    ctx.save()
    ctx.translate(15, height / 2)
    ctx.rotate(-Math.PI / 2)
    ctx.fillText(this.controller.selectedYButton.metadataName, 0, 0)
    ctx.restore()
    
    // Get coloring metadata vector for point colors
    const coloringVector = this.controller.colorManager?.getColoringMetadataVector()
    
    // Draw points
    const pointSize = 2
    for (const point of dataPoints) {
      const x = scaleX(point.x)
      const y = scaleY(point.y)
      
      // Get color for this point
      let color = '#3b82f6' // Default blue
      if (coloringVector) {
        const { color: pointColor } = this.controller.colorManager.getColorAndAlpha(point.cellIndex, coloringVector)
        // Convert hex number to CSS color string
        color = '#' + pointColor.toString(16).padStart(6, '0')
      }
      
      ctx.fillStyle = color
      ctx.beginPath()
      ctx.arc(x, y, pointSize, 0, Math.PI * 2)
      ctx.fill()
    }
    
    console.log('📊 Scatter plot rendered with', dataPoints.length, 'points')
  }
  
  // Render violin plot for 2D modal (x is categorical)
  async renderViolinPlot2D(canvas, xVector, yVector, filteredIndices) {
    console.log('📊 Rendering violin plot 2D')
    
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    
    // Clear canvas
    ctx.clearRect(0, 0, width, height)
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(0, 0, width, height)
    
    // Get values
    const xValues = this.getVectorValues(xVector)
    const yValues = this.getVectorValues(yVector)
    
    if (!xValues || !yValues || xValues.length !== yValues.length) {
      console.error('Invalid data for violin plot')
      return
    }
    
    // Apply filtering
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const dataByCategory = {}
    for (let i = 0; i < xValues.length; i++) {
      if (!filteredSet || filteredSet.has(i)) {
        const category = xValues[i]
        if (!dataByCategory[category]) {
          dataByCategory[category] = []
        }
        dataByCategory[category].push({
          y: yValues[i],
          cellIndex: i
        })
      }
    }
    
    const categories = Object.keys(dataByCategory).sort()
    if (categories.length === 0) {
      ctx.fillStyle = '#6b7280'
      ctx.font = '16px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('No data points to display', width / 2, height / 2)
      return
    }
    
    // Calculate layout - need to measure text for bottom padding
    const topPadding = 60
    const sidePadding = 60
    
    // Measure text to determine bottom padding needed for diagonal labels
    ctx.font = '11px sans-serif'
    ctx.textAlign = 'left'
    ctx.textBaseline = 'top'
    let maxTextWidth = 0
    let maxTextHeight = 0
    let longestCategory = ''
    const angle = -Math.PI / 4 // -45 degrees
    categories.forEach((category) => {
      const metrics = ctx.measureText(category)
      const textWidth = metrics.width
      const textHeight = 11 // font size
      // Calculate rotated text dimensions
      // For -45 degree rotation, text extends in +x and -y direction
      const rotatedWidth = Math.abs(textWidth * Math.cos(angle)) + Math.abs(textHeight * Math.sin(angle))
      const rotatedHeight = Math.abs(textWidth * Math.sin(angle)) + Math.abs(textHeight * Math.cos(angle))
      if (textWidth > maxTextWidth) {
        maxTextWidth = textWidth
        longestCategory = category
      }
      maxTextHeight = Math.max(maxTextHeight, rotatedHeight)
    })
    
    // Measure the longest category for positioning
    const longestTextWidth = ctx.measureText(longestCategory).width
    
    const bottomPadding = Math.max(60, maxTextHeight + 30) // Add extra space for rotated text
    const categoryWidth = (width - 2 * sidePadding) / categories.length
    const violinWidth = categoryWidth * 0.6
    const plotHeight = height - topPadding - bottomPadding
    
    // Calculate y bounds
    let yMin = Infinity
    let yMax = -Infinity
    for (const category of categories) {
      for (const point of dataByCategory[category]) {
        yMin = Math.min(yMin, point.y)
        yMax = Math.max(yMax, point.y)
      }
    }
    const yRange = yMax - yMin || 1
    
    const scaleY = (y) => height - bottomPadding - ((y - yMin) / yRange) * plotHeight
    
    // Draw axes
    ctx.strokeStyle = '#d1d5db'
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(sidePadding, height - bottomPadding)
    ctx.lineTo(width - sidePadding, height - bottomPadding)
    ctx.moveTo(sidePadding, height - bottomPadding)
    ctx.lineTo(sidePadding, topPadding)
    ctx.stroke()
    
    // Draw axis labels
    ctx.fillStyle = '#374151'
    ctx.font = '12px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    // Place axis title below the plot area (not in the middle)
    ctx.fillText(this.controller.selectedXButton.metadataName, width / 2, height - bottomPadding + maxTextHeight + 15)
    ctx.save()
    ctx.translate(15, height / 2)
    ctx.rotate(-Math.PI / 2)
    ctx.fillText(this.controller.selectedYButton.metadataName, 0, 0)
    ctx.restore()
    
    // Get category colors from categorical metadata
    const categoryColors = window.CATEGORY_COLORS || []
    const categoryColorMap = {}
    categories.forEach((cat, idx) => {
      categoryColorMap[cat] = categoryColors[idx % categoryColors.length]
    })
    
    // Get coloring metadata vector for point colors
    const coloringVector = this.controller.colorManager?.getColoringMetadataVector()
    
    // Create a deterministic random function for consistent point positions
    const seededRandom = (seed) => {
      const x = Math.sin(seed) * 10000
      return x - Math.floor(x)
    }
    
    // Draw points first (so violin lines appear above)
    const pointSize = 1.0 // Smaller radius
    const pointAreaWidth = violinWidth * 0.6 // Narrower area for points (was 0.8)
    
    // Create a cache key based on the current data to detect when to clear cache
    const cacheKey = `${categories.join(',')}_${filteredIndices ? filteredIndices.length : 'all'}`
    if (!this.violinPointPositions.has('cacheKey') || this.violinPointPositions.get('cacheKey') !== cacheKey) {
      // Clear cache if data changed
      this.violinPointPositions.clear()
      this.violinPointPositions.set('cacheKey', cacheKey)
    }
    
    categories.forEach((category, catIndex) => {
      const categoryData = dataByCategory[category]
      const centerX = sidePadding + (catIndex + 0.5) * categoryWidth
      
      // Draw points with cached positions
      for (const point of categoryData) {
        // Create a unique key for this point's relative offset (normalized, not absolute)
        const positionKey = `${category}_${point.cellIndex}`
        
        // Get or compute relative offset (normalized between -0.5 and 0.5)
        let relativeOffset
        if (!this.violinPointPositions.has(positionKey)) {
          // Compute new relative offset using seeded random for consistency
          const seed = category.charCodeAt(0) * 1000 + point.cellIndex
          relativeOffset = (seededRandom(seed) - 0.5) // Normalized offset
          this.violinPointPositions.set(positionKey, relativeOffset)
        } else {
          // Use cached relative offset
          relativeOffset = this.violinPointPositions.get(positionKey)
        }
        
        // Apply offset to current centerX and pointAreaWidth
        const pointX = centerX + relativeOffset * pointAreaWidth
        const y = scaleY(point.y)
        
        // Get color for this point from current coloring
        let color = '#3b82f6' // Default blue
        if (coloringVector) {
          const { color: pointColor } = this.controller.colorManager.getColorAndAlpha(point.cellIndex, coloringVector)
          // Convert hex number to CSS color string
          color = '#' + pointColor.toString(16).padStart(6, '0')
        }
        
        ctx.fillStyle = color
        ctx.beginPath()
        ctx.arc(pointX, y, pointSize, 0, Math.PI * 2)
        ctx.fill()
      }
    })
    
    // Draw violins after points (so they appear above)
    categories.forEach((category, catIndex) => {
      const categoryData = dataByCategory[category]
      const centerX = sidePadding + (catIndex + 0.5) * categoryWidth
      
      // Calculate kernel density estimate for violin shape
      const density = this.calculateDensity(categoryData.map(p => p.y), yMin, yMax, 50)
      const maxDensity = Math.max(...density.map(d => d.density))
      
      // Draw violin outline
      const outlineColor = categoryColorMap[category] || '#3b82f6'
      ctx.strokeStyle = outlineColor
      ctx.lineWidth = 2
      ctx.beginPath()
      
      // Right side of violin
      for (let i = 0; i < density.length; i++) {
        const x = centerX + (density[i].density / maxDensity) * (violinWidth / 2)
        const y = scaleY(density[i].value)
        if (i === 0) {
          ctx.moveTo(x, y)
        } else {
          ctx.lineTo(x, y)
        }
      }
      
      // Left side of violin
      for (let i = density.length - 1; i >= 0; i--) {
        const x = centerX - (density[i].density / maxDensity) * (violinWidth / 2)
        const y = scaleY(density[i].value)
        ctx.lineTo(x, y)
      }
      
      ctx.closePath()
      ctx.stroke()
      
      // Draw category label diagonally
      // Position so that each text ends at its own centerX
      // Use right alignment so the text ends at the translation point (0,0 after rotation)
      ctx.fillStyle = '#374151'
      ctx.font = '11px sans-serif'
      ctx.textAlign = 'right'
      ctx.textBaseline = 'bottom' // Use bottom baseline so text extends upward from the point
      ctx.save()
      // Translate to centerX (where text should end) and position vertically
      const textEndX = centerX
      const textEndY = height - bottomPadding + 25 // Position lower (closer to bottom)
      ctx.translate(textEndX, textEndY)
      ctx.rotate(angle)
      // With right alignment, text ends at (0,0) in rotated coordinates
      ctx.fillText(category, 0, 0)
      ctx.restore()
    })
    
    console.log('📊 Violin plot rendered with', categories.length, 'categories')
  }
  
  // Calculate kernel density estimate for violin plots
  calculateDensity(values, min, max, bins) {
    const bandwidth = (max - min) / 20 // Kernel bandwidth
    const binSize = (max - min) / bins
    const density = []
    
    for (let i = 0; i < bins; i++) {
      const binCenter = min + (i + 0.5) * binSize
      let sum = 0
      
      for (const value of values) {
        // Gaussian kernel
        const diff = (value - binCenter) / bandwidth
        sum += Math.exp(-0.5 * diff * diff)
      }
      
      density.push({
        value: binCenter,
        density: sum / (values.length * bandwidth * Math.sqrt(2 * Math.PI))
      })
    }
    
    return density
  }
}



