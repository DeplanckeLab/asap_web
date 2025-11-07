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
        const geneIdStr = String(geneId)
        const geneIdNum = Number(geneId)
        const geneMetadataId = `gene_${geneId}`
        
        // First check loadedMetadataVectors
        if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
          xVector = this.controller.loadedMetadataVectors[geneMetadataId]
          console.log(`📊 X-axis: Found gene ${geneId} in loadedMetadataVectors`)
        } else {
          // Try to find in geneExpressionData with all key formats
          let geneData = this.controller.geneManager?.geneExpressionData?.[geneId] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdStr] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdNum]
          
          if (geneData && geneData.values && geneData.values.length > 0) {
            console.log(`📊 X-axis: Found gene ${geneId} in geneExpressionData, creating vector`)
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
          } else {
            // Try to find gene in geneTags
            let gene = this.controller.geneManager?.geneTags?.find(g => 
              g.stableId === geneId || 
              String(g.stableId) === geneIdStr || 
              g.stableId === geneIdNum ||
              String(g.stableId) === String(geneId)
            )
            
            // If not in geneTags, try to get gene info from the button element
            if (!gene && this.controller.selectedXButton.button) {
              const button = this.controller.selectedXButton.button
              const buttonGeneId = button.dataset.geneId
              if (buttonGeneId) {
                // Try to find gene with the button's geneId
                gene = this.controller.geneManager?.geneTags?.find(g => 
                  String(g.stableId) === String(buttonGeneId) || 
                  g.stableId === Number(buttonGeneId)
                )
              }
            }
            
            // If still no gene, try to construct one from available info
            if (!gene) {
              console.warn(`📊 X-axis: Gene ${geneId} not in geneTags, attempting to load directly`)
              // Try to load using the geneId directly - GeneManager might handle it
              if (this.controller.geneManager) {
                try {
                  // Ensure geneExpressionData exists
                  if (!this.controller.geneManager.geneExpressionData) {
                    this.controller.geneManager.geneExpressionData = {}
                    console.warn(`📊 X-axis: geneExpressionData was undefined, initialized as empty object`)
                  }
                  
                  // Check if we can find the gene data by searching all geneExpressionData keys
                  const allGeneKeys = Object.keys(this.controller.geneManager.geneExpressionData)
                  console.log(`📊 X-axis: Searching ${allGeneKeys.length} keys in geneExpressionData for gene ${geneId}`)
                  
                  const matchingKey = allGeneKeys.find(k => {
                    const kStr = String(k)
                    const kNum = Number(k)
                    return kStr === geneIdStr || 
                           k === geneIdStr ||
                           kNum === geneIdNum ||
                           String(kNum) === geneIdStr ||
                           k === geneId ||
                           k === geneIdNum
                  })
                  
                  if (matchingKey) {
                    geneData = this.controller.geneManager.geneExpressionData[matchingKey]
                    console.log(`📊 X-axis: Found gene data under key "${matchingKey}" (original search: ${geneId})`)
                  } else {
                    console.log(`📊 X-axis: Gene ${geneId} not found in existing keys, attempting to load from server`)
                    // Try to load from server using the geneId
                    const geneObj = {
                      stableId: geneIdNum || parseInt(geneId),
                      symbol: this.controller.selectedXButton.metadataName || `Gene ${geneId}`,
                      ensemblId: '',
                      query: this.controller.selectedXButton.metadataName || `Gene ${geneId}`
                    }
                    await this.controller.geneManager.loadGeneExpressionData(geneObj, null)
                    // Check again after loading - try all key formats
                    geneData = this.controller.geneManager?.geneExpressionData?.[geneId] ||
                              this.controller.geneManager?.geneExpressionData?.[geneIdStr] ||
                              this.controller.geneManager?.geneExpressionData?.[geneIdNum]
                    
                    if (!geneData) {
                      // Search all keys again after loading
                      const allKeysAfterLoad = Object.keys(this.controller.geneManager.geneExpressionData || {})
                      const matchingKeyAfterLoad = allKeysAfterLoad.find(k => {
                        const kStr = String(k)
                        const kNum = Number(k)
                        return kStr === geneIdStr || 
                               k === geneIdStr ||
                               kNum === geneIdNum ||
                               String(kNum) === geneIdStr ||
                               k === geneId ||
                               k === geneIdNum
                      })
                      if (matchingKeyAfterLoad) {
                        geneData = this.controller.geneManager.geneExpressionData[matchingKeyAfterLoad]
                        console.log(`📊 X-axis: Found gene data after loading under key "${matchingKeyAfterLoad}"`)
                      }
                    }
                  }
                } catch (error) {
                  console.error(`Failed to load gene expression data for X-axis gene ${geneId}:`, error)
                }
              } else {
                console.error(`📊 X-axis: geneManager is not available`)
              }
            } else {
              // Gene found in geneTags, load it
              try {
            await this.controller.geneManager.loadGeneExpressionData(gene, null)
              } catch (error) {
                console.error(`Failed to load gene expression data for X-axis gene ${geneId}:`, error)
          }
            }
            
            // Check again after loading attempt
          if (this.controller.loadedMetadataVectors[geneMetadataId]) {
            xVector = this.controller.loadedMetadataVectors[geneMetadataId]
              console.log(`📊 X-axis: Gene ${geneId} loaded into loadedMetadataVectors`)
            } else {
              // Check geneExpressionData again with all formats
              geneData = geneData || 
                        this.controller.geneManager?.geneExpressionData?.[geneId] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdStr] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdNum]
              
              if (geneData && geneData.values && geneData.values.length > 0) {
                console.log(`📊 X-axis: Creating vector from geneExpressionData after loading`)
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
        const geneIdStr = String(geneId)
        const geneIdNum = Number(geneId)
        const geneMetadataId = `gene_${geneId}`
        
        // First check loadedMetadataVectors
        if (this.controller.loadedMetadataVectors[geneMetadataId] && this.controller.loadedMetadataVectors[geneMetadataId].values) {
          yVector = this.controller.loadedMetadataVectors[geneMetadataId]
          console.log(`📊 Y-axis: Found gene ${geneId} in loadedMetadataVectors`)
        } else {
          // Try to find in geneExpressionData with all key formats
          let geneData = this.controller.geneManager?.geneExpressionData?.[geneId] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdStr] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdNum]
          
          if (geneData && geneData.values && geneData.values.length > 0) {
            console.log(`📊 Y-axis: Found gene ${geneId} in geneExpressionData, creating vector`)
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
          } else {
            // Try to find gene in geneTags
            let gene = this.controller.geneManager?.geneTags?.find(g => 
              g.stableId === geneId || 
              String(g.stableId) === geneIdStr || 
              g.stableId === geneIdNum ||
              String(g.stableId) === String(geneId)
            )
            
            // If not in geneTags, try to get gene info from the button element
            if (!gene && this.controller.selectedYButton.button) {
              const button = this.controller.selectedYButton.button
              const buttonGeneId = button.dataset.geneId
              if (buttonGeneId) {
                // Try to find gene with the button's geneId
                gene = this.controller.geneManager?.geneTags?.find(g => 
                  String(g.stableId) === String(buttonGeneId) || 
                  g.stableId === Number(buttonGeneId)
                )
              }
            }
            
            // If still no gene, try to construct one from available info
            if (!gene) {
              console.warn(`📊 Y-axis: Gene ${geneId} not in geneTags, attempting to load directly`)
              // Try to load using the geneId directly - GeneManager might handle it
              if (this.controller.geneManager) {
                try {
                  // Ensure geneExpressionData exists
                  if (!this.controller.geneManager.geneExpressionData) {
                    this.controller.geneManager.geneExpressionData = {}
                    console.warn(`📊 Y-axis: geneExpressionData was undefined, initialized as empty object`)
                  }
                  
                  // Check if we can find the gene data by searching all geneExpressionData keys
                  const allGeneKeys = Object.keys(this.controller.geneManager.geneExpressionData)
                  console.log(`📊 Y-axis: Searching ${allGeneKeys.length} keys in geneExpressionData for gene ${geneId}`)
                  
                  const matchingKey = allGeneKeys.find(k => {
                    const kStr = String(k)
                    const kNum = Number(k)
                    return kStr === geneIdStr || 
                           k === geneIdStr ||
                           kNum === geneIdNum ||
                           String(kNum) === geneIdStr ||
                           k === geneId ||
                           k === geneIdNum
                  })
                  
                  if (matchingKey) {
                    geneData = this.controller.geneManager.geneExpressionData[matchingKey]
                    console.log(`📊 Y-axis: Found gene data under key "${matchingKey}" (original search: ${geneId})`)
                  } else {
                    console.log(`📊 Y-axis: Gene ${geneId} not found in existing keys, attempting to load from server`)
                    // Try to load from server using the geneId
                    const geneObj = {
                      stableId: geneIdNum || parseInt(geneId),
                      symbol: this.controller.selectedYButton.metadataName || `Gene ${geneId}`,
                      ensemblId: '',
                      query: this.controller.selectedYButton.metadataName || `Gene ${geneId}`
                    }
                    await this.controller.geneManager.loadGeneExpressionData(geneObj, null)
                    // Check again after loading - try all key formats
                    geneData = this.controller.geneManager?.geneExpressionData?.[geneId] ||
                              this.controller.geneManager?.geneExpressionData?.[geneIdStr] ||
                              this.controller.geneManager?.geneExpressionData?.[geneIdNum]
                    
                    if (!geneData) {
                      // Search all keys again after loading
                      const allKeysAfterLoad = Object.keys(this.controller.geneManager.geneExpressionData || {})
                      const matchingKeyAfterLoad = allKeysAfterLoad.find(k => {
                        const kStr = String(k)
                        const kNum = Number(k)
                        return kStr === geneIdStr || 
                               k === geneIdStr ||
                               kNum === geneIdNum ||
                               String(kNum) === geneIdStr ||
                               k === geneId ||
                               k === geneIdNum
                      })
                      if (matchingKeyAfterLoad) {
                        geneData = this.controller.geneManager.geneExpressionData[matchingKeyAfterLoad]
                        console.log(`📊 Y-axis: Found gene data after loading under key "${matchingKeyAfterLoad}"`)
                      }
                    }
                  }
                } catch (error) {
                  console.error(`Failed to load gene expression data for Y-axis gene ${geneId}:`, error)
                }
              } else {
                console.error(`📊 Y-axis: geneManager is not available`)
              }
            } else {
              // Gene found in geneTags, load it
              try {
            await this.controller.geneManager.loadGeneExpressionData(gene, null)
              } catch (error) {
                console.error(`Failed to load gene expression data for Y-axis gene ${geneId}:`, error)
          }
            }
            
            // Check again after loading attempt
          if (this.controller.loadedMetadataVectors[geneMetadataId]) {
            yVector = this.controller.loadedMetadataVectors[geneMetadataId]
              console.log(`📊 Y-axis: Gene ${geneId} loaded into loadedMetadataVectors`)
            } else {
              // Check geneExpressionData again with all formats
              geneData = geneData || 
                        this.controller.geneManager?.geneExpressionData?.[geneId] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdStr] ||
                        this.controller.geneManager?.geneExpressionData?.[geneIdNum]
              
              if (geneData && geneData.values && geneData.values.length > 0) {
                console.log(`📊 Y-axis: Creating vector from geneExpressionData after loading`)
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
        const xIsGene = this.controller.selectedXButton.isGene
        const yIsGene = this.controller.selectedYButton.isGene
        const xId = this.controller.selectedXButton.metadataId
        const yId = this.controller.selectedYButton.metadataId
        const xName = this.controller.selectedXButton.metadataName
        const yName = this.controller.selectedYButton.metadataName
        
        // Build detailed diagnostic information
        let errorDetails = []
        let consoleDetails = {
          xVector: !!xVector,
          yVector: !!yVector,
          xIsGene,
          yIsGene,
          xId,
          yId,
          xName,
          yName
        }
        
        if (!xVector) {
          if (xIsGene) {
            const xIdStr = String(xId)
            const xIdNum = Number(xId)
            const xMetadataId = `gene_${xId}`
            
            // Check all possible locations
            const xInGeneTags = !!this.controller.geneManager?.geneTags?.find(g => 
              String(g.stableId) === xIdStr || g.stableId === xIdNum || String(g.stableId) === String(xId)
            )
            const xInExpressionData = !!(this.controller.geneManager?.geneExpressionData?.[xId] ||
                                        this.controller.geneManager?.geneExpressionData?.[xIdStr] ||
                                        this.controller.geneManager?.geneExpressionData?.[xIdNum])
            const xInLoadedVectors = !!this.controller.loadedMetadataVectors?.[xMetadataId]
            const xExpressionDataKeys = Object.keys(this.controller.geneManager?.geneExpressionData || {})
            const xLoadedVectorsKeys = Object.keys(this.controller.loadedMetadataVectors || {}).filter(k => k.startsWith('gene_'))
            
            errorDetails.push(`X-axis gene "${xName}" (ID: ${xId}) could not be loaded.`)
            errorDetails.push(`  - In geneTags: ${xInGeneTags}`)
            errorDetails.push(`  - In geneExpressionData: ${xInExpressionData} (checked keys: ${xId}, "${xIdStr}", ${xIdNum})`)
            errorDetails.push(`  - In loadedMetadataVectors: ${xInLoadedVectors} (key: "${xMetadataId}")`)
            
            if (xExpressionDataKeys.length > 0) {
              const matchingKeys = xExpressionDataKeys.filter(k => 
                k === String(xId) || k === String(xIdNum) || Number(k) === xIdNum
              )
              errorDetails.push(`  - Matching geneExpressionData keys: ${matchingKeys.length > 0 ? matchingKeys.join(', ') : 'none'}`)
              errorDetails.push(`  - First 10 geneExpressionData keys: ${xExpressionDataKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push(`  - geneExpressionData is empty or undefined`)
            }
            
            if (xLoadedVectorsKeys.length > 0) {
              errorDetails.push(`  - First 10 loadedMetadataVectors gene keys: ${xLoadedVectorsKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push(`  - No gene keys found in loadedMetadataVectors`)
            }
            
            consoleDetails.xInGeneTags = xInGeneTags
            consoleDetails.xInExpressionData = xInExpressionData
            consoleDetails.xInLoadedVectors = xInLoadedVectors
            consoleDetails.xExpressionDataKeys = xExpressionDataKeys.slice(0, 20)
            consoleDetails.xLoadedVectorsKeys = xLoadedVectorsKeys.slice(0, 20)
            consoleDetails.xCheckedKeys = [xId, xIdStr, xIdNum]
            consoleDetails.xMetadataId = xMetadataId
          } else {
            errorDetails.push(`X-axis metadata "${xName}" (ID: ${xMetadataId}) could not be loaded.`)
            errorDetails.push(`  - The metadata may not exist in the dataset.`)
          }
        }
        
        if (!yVector) {
          if (yIsGene) {
            const yIdStr = String(yId)
            const yIdNum = Number(yId)
            const yMetadataId = `gene_${yId}`
            
            // Check all possible locations
            const yInGeneTags = !!this.controller.geneManager?.geneTags?.find(g => 
              String(g.stableId) === yIdStr || g.stableId === yIdNum || String(g.stableId) === String(yId)
            )
            const yInExpressionData = !!(this.controller.geneManager?.geneExpressionData?.[yId] ||
                                        this.controller.geneManager?.geneExpressionData?.[yIdStr] ||
                                        this.controller.geneManager?.geneExpressionData?.[yIdNum])
            const yInLoadedVectors = !!this.controller.loadedMetadataVectors?.[yMetadataId]
            const yExpressionDataKeys = Object.keys(this.controller.geneManager?.geneExpressionData || {})
            const yLoadedVectorsKeys = Object.keys(this.controller.loadedMetadataVectors || {}).filter(k => k.startsWith('gene_'))
            
            errorDetails.push(`Y-axis gene "${yName}" (ID: ${yId}) could not be loaded.`)
            errorDetails.push(`  - In geneTags: ${yInGeneTags}`)
            errorDetails.push(`  - In geneExpressionData: ${yInExpressionData} (checked keys: ${yId}, "${yIdStr}", ${yIdNum})`)
            errorDetails.push(`  - In loadedMetadataVectors: ${yInLoadedVectors} (key: "${yMetadataId}")`)
            
            if (yExpressionDataKeys.length > 0) {
              const matchingKeys = yExpressionDataKeys.filter(k => 
                k === String(yId) || k === String(yIdNum) || Number(k) === yIdNum
              )
              errorDetails.push(`  - Matching geneExpressionData keys: ${matchingKeys.length > 0 ? matchingKeys.join(', ') : 'none'}`)
              errorDetails.push(`  - First 10 geneExpressionData keys: ${yExpressionDataKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push(`  - geneExpressionData is empty or undefined`)
            }
            
            if (yLoadedVectorsKeys.length > 0) {
              errorDetails.push(`  - First 10 loadedMetadataVectors gene keys: ${yLoadedVectorsKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push(`  - No gene keys found in loadedMetadataVectors`)
            }
            
            // If data exists but vector wasn't created, show why
            if (yInExpressionData) {
              const yGeneData = this.controller.geneManager.geneExpressionData[yId] ||
                               this.controller.geneManager.geneExpressionData[yIdStr] ||
                               this.controller.geneManager.geneExpressionData[yIdNum]
              if (yGeneData) {
                errorDetails.push(`  - geneExpressionData found but: hasValues=${!!yGeneData.values}, valuesLength=${yGeneData.values?.length || 0}`)
              }
            }
            
            consoleDetails.yInGeneTags = yInGeneTags
            consoleDetails.yInExpressionData = yInExpressionData
            consoleDetails.yInLoadedVectors = yInLoadedVectors
            consoleDetails.yExpressionDataKeys = yExpressionDataKeys.slice(0, 20)
            consoleDetails.yLoadedVectorsKeys = yLoadedVectorsKeys.slice(0, 20)
            consoleDetails.yCheckedKeys = [yId, yIdStr, yIdNum]
            consoleDetails.yMetadataId = yMetadataId
          } else {
            errorDetails.push(`Y-axis metadata "${yName}" (ID: ${yMetadataId}) could not be loaded.`)
            errorDetails.push(`  - The metadata may not exist in the dataset.`)
          }
        }
        
        console.error('Failed to load data vectors for 2D plot - Detailed diagnostics:', consoleDetails)
        console.error('Full error details:', errorDetails)
        
        if (loadingDiv) loadingDiv.style.display = 'none'
        alert('Failed to load data for 2D plot\n\n' + errorDetails.join('\n') + '\n\nPlease check the browser console for more details.')
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
    
    // Padding for axes (left, right, top, bottom)
    const leftPadding = 70
    const rightPadding = 20
    const topPadding = 20
    const bottomPadding = 70
    
    // Scale functions
    const scaleX = (x) => leftPadding + ((x - xMin) / xRange) * (width - leftPadding - rightPadding)
    const scaleY = (y) => height - bottomPadding - ((y - yMin) / yRange) * (height - topPadding - bottomPadding)
    
    // Calculate tick spacing
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    // Draw grid lines first (behind everything)
    ctx.strokeStyle = 'rgba(204, 204, 204, 0.3)'
    ctx.lineWidth = 1
    ctx.setLineDash([2, 2])
    
    // Vertical grid lines (aligned with X-axis ticks)
    const xStart = Math.ceil(xMin / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(xMax / xTickSpacing) * xTickSpacing
    for (let value = xStart; value <= xEnd; value += xTickSpacing) {
      const x = scaleX(value)
      if (x >= leftPadding && x <= width - rightPadding) {
        ctx.beginPath()
        ctx.moveTo(x, topPadding)
        ctx.lineTo(x, height - bottomPadding)
        ctx.stroke()
      }
    }
    
    // Horizontal grid lines (aligned with Y-axis ticks)
    const yStart = Math.ceil(yMin / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(yMax / yTickSpacing) * yTickSpacing
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const y = scaleY(value)
      if (y >= topPadding && y <= height - bottomPadding) {
        ctx.beginPath()
        ctx.moveTo(leftPadding, y)
        ctx.lineTo(width - rightPadding, y)
        ctx.stroke()
      }
    }
    
    ctx.setLineDash([])
    
    // Draw axes
    ctx.strokeStyle = '#d1d5db'
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(leftPadding, height - bottomPadding)
    ctx.lineTo(width - rightPadding, height - bottomPadding)
    ctx.moveTo(leftPadding, height - bottomPadding)
    ctx.lineTo(leftPadding, topPadding)
    ctx.stroke()
    
    // Draw tick marks and labels
    ctx.fillStyle = '#374151'
    ctx.font = '11px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    
    // X-axis ticks and labels
    for (let value = xStart; value <= xEnd; value += xTickSpacing) {
      const x = scaleX(value)
      if (x >= leftPadding && x <= width - rightPadding) {
        // Tick mark
        ctx.beginPath()
        ctx.moveTo(x, height - bottomPadding)
        ctx.lineTo(x, height - bottomPadding + 5)
        ctx.stroke()
        
        // Label
        ctx.fillText(this.formatTickValue(value), x, height - bottomPadding + 8)
      }
    }
    
    // Y-axis ticks and labels
    ctx.textAlign = 'right'
    ctx.textBaseline = 'middle'
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const y = scaleY(value)
      if (y >= topPadding && y <= height - bottomPadding) {
        // Tick mark
        ctx.beginPath()
        ctx.moveTo(leftPadding, y)
        ctx.lineTo(leftPadding - 5, y)
        ctx.stroke()
        
        // Label
        ctx.fillText(this.formatTickValue(value), leftPadding - 8, y)
      }
    }
    
    // Draw axis titles
    ctx.fillStyle = '#374151'
    ctx.font = '13px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    const xLabel = this.getAxisLabel(this.controller.selectedXButton)
    const xLines = xLabel.split('\n')
    xLines.forEach((line, index) => {
      ctx.fillText(line, width / 2, height - bottomPadding + 28 + index * 16)
    })
    const yLabel = this.getAxisLabel(this.controller.selectedYButton)
    const yLines = yLabel.split('\n')
    ctx.save()
    ctx.translate(15, height / 2)
    ctx.rotate(-Math.PI / 2)
    ctx.textAlign = 'center'
    yLines.forEach((line, index) => {
      ctx.fillText(line, 0, index * 16)
    })
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
    
    // Calculate tick spacing for Y-axis
    const yTickSpacing = this.calculateTickSpacing(yRange)
    
    // Draw grid lines first (behind everything)
    ctx.strokeStyle = 'rgba(204, 204, 204, 0.3)'
    ctx.lineWidth = 1
    ctx.setLineDash([2, 2])
    
    // Horizontal grid lines (aligned with Y-axis ticks)
    const yStart = Math.ceil(yMin / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(yMax / yTickSpacing) * yTickSpacing
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const y = scaleY(value)
      if (y >= topPadding && y <= height - bottomPadding) {
        ctx.beginPath()
        ctx.moveTo(sidePadding, y)
        ctx.lineTo(width - sidePadding, y)
        ctx.stroke()
      }
    }
    
    ctx.setLineDash([])
    
    // Draw axes
    ctx.strokeStyle = '#d1d5db'
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(sidePadding, height - bottomPadding)
    ctx.lineTo(width - sidePadding, height - bottomPadding)
    ctx.moveTo(sidePadding, height - bottomPadding)
    ctx.lineTo(sidePadding, topPadding)
    ctx.stroke()
    
    // Draw Y-axis tick marks and labels
    ctx.fillStyle = '#374151'
    ctx.font = '11px sans-serif'
    ctx.textAlign = 'right'
    ctx.textBaseline = 'middle'
    for (let value = yStart; value <= yEnd; value += yTickSpacing) {
      const y = scaleY(value)
      if (y >= topPadding && y <= height - bottomPadding) {
        // Tick mark
        ctx.beginPath()
        ctx.moveTo(sidePadding, y)
        ctx.lineTo(sidePadding - 5, y)
        ctx.stroke()
        
        // Label
        ctx.fillText(this.formatTickValue(value), sidePadding - 8, y)
      }
    }
    
    // Draw axis titles
    ctx.fillStyle = '#374151'
    ctx.font = '13px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    const xLabel = this.getAxisLabel(this.controller.selectedXButton)
    const xLines = xLabel.split('\n')
    xLines.forEach((line, index) => {
      ctx.fillText(line, width / 2, height - bottomPadding + maxTextHeight + 15 + index * 16)
    })
    const yLabel = this.getAxisLabel(this.controller.selectedYButton)
    const yLines = yLabel.split('\n')
    ctx.save()
    ctx.translate(15, height / 2)
    ctx.rotate(-Math.PI / 2)
    ctx.textAlign = 'center'
    yLines.forEach((line, index) => {
      ctx.fillText(line, 0, index * 16)
    })
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
  
  // Get axis label with gene symbol and Ensembl ID if available
  getAxisLabel(selectedButton) {
    if (!selectedButton) {
      return 'Unknown'
    }
    if (selectedButton.isGene) {
      const geneId = selectedButton.metadataId
      const geneIdStr = String(geneId)
      const geneIdNum = Number(geneId)
      let symbol = null
      let ensemblId = ''

      if (selectedButton.button) {
        const geneNameFromButton = selectedButton.button.dataset.geneName
        if (geneNameFromButton) {
          symbol = geneNameFromButton
        }
      }

      if (this.controller.geneManager?.geneTags) {
        for (const g of this.controller.geneManager.geneTags) {
          if (String(g.stableId) === geneIdStr || g.stableId === geneId || g.stableId === geneIdNum || String(g.stableId) === String(geneIdNum) || Number(g.stableId) === geneIdNum) {
            symbol = g.symbol || symbol
            ensemblId = g.ensemblId || ensemblId
            break
          }
        }
      }

      if (!symbol || !ensemblId) {
        const geneDiv = document.querySelector(`[data-gene-item="${geneId}"], [data-gene-item="${geneIdStr}"]`)
        if (geneDiv) {
          const header = geneDiv.querySelector('.gene-header')
          if (header) {
            const titleText = header.getAttribute('title') || header.textContent || ''
            const titleMatch = titleText.match(/^(.+?)\s+(FBgn\d+)\s+\{/)
            if (titleMatch) {
              if (!symbol) symbol = titleMatch[1].trim()
              if (!ensemblId) ensemblId = titleMatch[2].trim()
            } else {
              const symbolElement = header.querySelector('div[style*="font-size: 14px"]')
              if (symbolElement && !symbol) {
                const clonedElement = symbolElement.cloneNode(true)
                const ensemblSpan = clonedElement.querySelector('span[style*="monospace"]')
                if (ensemblSpan) {
                  ensemblSpan.remove()
                }
                symbol = clonedElement.textContent.trim()
              }
              const ensemblElement = header.querySelector('span[style*="monospace"]')
              if (ensemblElement && !ensemblId) {
                ensemblId = ensemblElement.textContent.trim()
              }
            }
          }
        }
      }

      if (!symbol) {
        const geneData = this.controller.geneManager?.geneExpressionData?.[geneId] || this.controller.geneManager?.geneExpressionData?.[geneIdStr] || this.controller.geneManager?.geneExpressionData?.[geneIdNum]
        if (geneData && geneData.symbol) {
          symbol = geneData.symbol
        }
      }

      if (!symbol) {
        symbol = selectedButton.metadataName || `Gene ${geneId}`
      }

      let matrixLabel = ''
      if (this.controller.geneManager?.currentMatrixLayer) {
        const layer = this.controller.geneManager.currentMatrixLayer
        matrixLabel = layer
      }

      if (ensemblId && ensemblId.trim() !== '') {
        return matrixLabel ? `Gene expression of ${symbol} ${ensemblId}\n${matrixLabel}` : `Gene expression of ${symbol} ${ensemblId}`
      } else {
        return matrixLabel ? `Gene expression of ${symbol}\n${matrixLabel}` : `Gene expression of ${symbol}`
      }
    }
    return selectedButton.metadataName || 'Unknown'
  }

  // Calculate tick spacing for nice round numbers
  calculateTickSpacing(range) {
    const targetTicks = 6
    const roughSpacing = range / targetTicks
    
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

  // Format tick value for display
  formatTickValue(value) {
    if (Number.isInteger(value)) {
      return value.toString()
    }
    
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



