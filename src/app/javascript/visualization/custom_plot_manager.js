/**
 * Custom Plot Manager Module
 * Handles the 2D custom plot modal functionality
 */

export class CustomPlotManager {
  constructor(controller) {
    this.controller = controller
    // Cache for point positions in violin plots (to avoid recomputing on resize)
    this.violinPointPositions = new Map()
    this.currentPlotPoints = []
    this.currentPickTolerance = 12
    this.currentCanvas = null
    this.canvasEventHandlers = null
    this.currentPlotType = null
    this.lastHoverCellId = null
    this.currentCanvasContext = null
    this.selectionOverlayCanvas = null
    this.selectionOverlayCtx = null
    this.lassoOverlayCanvas = null
    this.lassoOverlayCtx = null
    this.isDrawingLasso = false
    this.customLassoPoints = []
  }

  resolveGeneMetadataIdentifiers(buttonInfo) {
    if (!buttonInfo || !buttonInfo.button) return null

    const gm = this.controller?.geneManager
    const buttonEl = buttonInfo.button

    let stableId = buttonEl.dataset?.geneId || buttonInfo.metadataId
    if (!stableId) return null

    let stableIdStr = String(stableId)
    if (stableIdStr.startsWith('gene_')) {
      stableIdStr = stableIdStr.slice(5)
    }

    const baseKey = gm && typeof gm.getBaseGeneMetadataId === 'function'
      ? gm.getBaseGeneMetadataId(stableIdStr)
      : `gene_${stableIdStr}`

    let layerKey = buttonEl.dataset?.layerMetadataId || buttonInfo.layerMetadataId || null
    if (!layerKey) {
      if (gm && typeof gm.getGeneMetadataId === 'function') {
        layerKey = gm.getGeneMetadataId(stableIdStr, gm.currentMatrixAnnotId)
      } else {
        layerKey = baseKey
      }
    }

    return {
      stableId: stableIdStr,
      baseKey,
      layerKey
    }
  }

  // Check if both x and y are selected and open modal
  checkAndOpen2DPlotModal() {
    if (this.controller.selectedXButton && this.controller.selectedYButton) {
      // console.log('Both x and y buttons selected, opening 2D plot modal...')
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
    this.detachCanvasInteractions()
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
  
  setupCanvasInteractions(canvas) {
    if (!canvas) return
    if (this.currentCanvas && this.currentCanvas !== canvas) {
      this.detachCanvasInteractions()
    }
    if (!this.canvasEventHandlers) {
      this.canvasEventHandlers = {
        mousemove: (event) => this.handleCanvasMouseMove(event),
        click: (event) => this.handleCanvasClick(event),
        mouseleave: () => this.handleCanvasMouseLeave(),
        mousedown: (event) => this.handleCanvasMouseDown(event),
        mouseup: (event) => this.handleCanvasMouseUp(event)
      }
    }
    if (this.currentCanvas !== canvas) {
      canvas.addEventListener('mousemove', this.canvasEventHandlers.mousemove)
      canvas.addEventListener('click', this.canvasEventHandlers.click)
      canvas.addEventListener('mouseleave', this.canvasEventHandlers.mouseleave)
      canvas.addEventListener('mousedown', this.canvasEventHandlers.mousedown)
      canvas.addEventListener('mouseup', this.canvasEventHandlers.mouseup)
      this.currentCanvas = canvas
      this.handleInteractionModeChange(this.controller.interactionMode)
    }
    this.ensureSelectionOverlay(canvas)
  }
  
  detachCanvasInteractions() {
    if (this.currentCanvas && this.canvasEventHandlers) {
      this.currentCanvas.removeEventListener('mousemove', this.canvasEventHandlers.mousemove)
      this.currentCanvas.removeEventListener('click', this.canvasEventHandlers.click)
      this.currentCanvas.removeEventListener('mouseleave', this.canvasEventHandlers.mouseleave)
      this.currentCanvas.removeEventListener('mousedown', this.canvasEventHandlers.mousedown)
      this.currentCanvas.removeEventListener('mouseup', this.canvasEventHandlers.mouseup)
    }
    this.currentCanvas = null
    this.lastHoverCellId = null
    this.currentPlotPoints = []
    this.removeOverlays()
  }
  
  handleInteractionModeChange(mode) {
    if (!this.currentCanvas) return
    if (mode === 'pick') {
      this.currentCanvas.style.cursor = 'pointer'
    } else {
      this.currentCanvas.style.cursor = 'default'
      if (!this.controller.isTooltipFixed && typeof this.controller.hideSimpleTooltip === 'function') {
        this.controller.hideSimpleTooltip()
      }
      this.lastHoverCellId = null
      if (mode !== 'lasso') {
        this.isDrawingLasso = false
        this.customLassoPoints = []
        this.clearLassoOverlay()
      }
      if (mode === 'lasso' && this.currentCanvas) {
        this.currentCanvas.style.cursor = 'crosshair'
      }
    }
  }
  
  handleCanvasMouseMove(event) {
    if (!this.currentCanvas) {
      return
    }
    const mode = this.controller.interactionMode
    if (mode === 'lasso') {
      this.currentCanvas.style.cursor = 'crosshair'
      if (!this.isDrawingLasso) {
        return
      }
      const rect = this.currentCanvas.getBoundingClientRect()
      const mouseX = event.clientX - rect.left
      const mouseY = event.clientY - rect.top
      const lastPoint = this.customLassoPoints[this.customLassoPoints.length - 1]
      if (!lastPoint || this.getDistanceBetweenPoints(lastPoint, { x: mouseX, y: mouseY }) >= 1.5) {
        this.customLassoPoints.push({ x: mouseX, y: mouseY })
        this.drawLassoPath()
      }
      return
    }
    if (!this.currentPlotPoints || this.currentPlotPoints.length === 0) {
      return
    }
    if (mode !== 'pick') {
      this.currentCanvas.style.cursor = 'default'
      if (!this.controller.isTooltipFixed && typeof this.controller.hideSimpleTooltip === 'function') {
        this.controller.hideSimpleTooltip()
      }
      this.lastHoverCellId = null
      return
    }
    this.currentCanvas.style.cursor = 'pointer'
    if (this.controller.isTooltipFixed) {
      return
    }
    const rect = this.currentCanvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    const closest = this.findClosestPoint(mouseX, mouseY)
    if (!closest) {
      if (!this.controller.isTooltipFixed && typeof this.controller.hideSimpleTooltip === 'function') {
        this.controller.hideSimpleTooltip()
      }
      this.lastHoverCellId = null
      return
    }
    const tooltipLeft = event.clientX + 12
    const tooltipTop = event.clientY + 12
    const hasMoved = !this.controller.lastTooltipPosition ||
      Math.abs(this.controller.lastTooltipPosition.left - tooltipLeft) > 2 ||
      Math.abs(this.controller.lastTooltipPosition.top - tooltipTop) > 2
    if (this.lastHoverCellId !== closest.point.cellIndex || hasMoved) {
      this.controller.lastTooltipPosition = { left: tooltipLeft, top: tooltipTop }
      const cellId = closest.point.cellIndex
      const cellName = cellId.toString()
      if (typeof this.controller.showSimpleTooltip === 'function') {
        this.controller.showSimpleTooltip(cellName, null, { x: tooltipLeft, y: tooltipTop }, cellId, false)
      }
      this.lastHoverCellId = cellId
    }
  }
  
  handleCanvasClick(event) {
    if (!this.currentCanvas || !this.currentPlotPoints || this.currentPlotPoints.length === 0) {
      return
    }
    if (this.controller.interactionMode === 'lasso') {
      return
    }
    if (this.controller.interactionMode !== 'pick') {
      return
    }
    const rect = this.currentCanvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    const closest = this.findClosestPoint(mouseX, mouseY)
    if (!closest) {
      if (this.controller.isTooltipFixed && typeof this.controller.unfixTooltip === 'function') {
        this.controller.unfixTooltip()
      } else if (typeof this.controller.hideSimpleTooltip === 'function') {
        this.controller.hideSimpleTooltip()
      }
      this.lastHoverCellId = null
      return
    }
    event.preventDefault()
    event.stopPropagation()
    const tooltipLeft = event.clientX + 12
    const tooltipTop = event.clientY + 12
    this.controller.lastTooltipPosition = { left: tooltipLeft, top: tooltipTop }
    if (typeof this.controller.fixTooltipToCell === 'function') {
      this.controller.fixTooltipToCell(closest.point.cellIndex, mouseX, mouseY)
    } else if (typeof this.controller.showSimpleTooltip === 'function') {
      const cellId = closest.point.cellIndex
      const cellName = cellId.toString()
      this.controller.isTooltipFixed = true
      this.controller.fixedTooltipCellId = cellId
      this.controller.showSimpleTooltip(cellName, null, { x: tooltipLeft, y: tooltipTop }, cellId, true)
    }
    this.lastHoverCellId = closest.point.cellIndex
  }
  
  handleCanvasMouseLeave() {
    if (this.currentCanvas) {
      this.currentCanvas.style.cursor = 'default'
    }
    if (this.isDrawingLasso) {
      this.finishCustomLassoSelection(false)
    }
    if (this.controller && !this.controller.isTooltipFixed && typeof this.controller.hideSimpleTooltip === 'function') {
      this.controller.hideSimpleTooltip()
    }
    this.lastHoverCellId = null
  }

  handleCanvasMouseDown(event) {
    if (!this.currentCanvas) return
    if (this.controller.interactionMode !== 'lasso') return
    if (event.button !== 0) return
    event.preventDefault()
    const rect = this.currentCanvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    this.isDrawingLasso = true
    this.customLassoPoints = [{ x: mouseX, y: mouseY }]
    this.ensureLassoOverlay(this.currentCanvas)
    this.drawLassoPath()
  }

  handleCanvasMouseUp(event) {
    if (!this.isDrawingLasso) return
    if (this.controller.interactionMode !== 'lasso') {
      this.finishCustomLassoSelection(false)
      return
    }
    event.preventDefault()
    const rect = this.currentCanvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    const lastPoint = this.customLassoPoints[this.customLassoPoints.length - 1]
    if (!lastPoint || this.getDistanceBetweenPoints(lastPoint, { x: mouseX, y: mouseY }) >= 1) {
      this.customLassoPoints.push({ x: mouseX, y: mouseY })
    }
    this.finishCustomLassoSelection(true)
  }

  finishCustomLassoSelection(applySelection) {
    if (!this.isDrawingLasso) return
    this.isDrawingLasso = false
    this.drawLassoPath(true)
    if (applySelection) {
      this.applyCustomLassoSelection()
    }
    setTimeout(() => {
      this.clearLassoOverlay()
      this.customLassoPoints = []
    }, 300)
  }

  applyCustomLassoSelection() {
    if (!this.currentPlotPoints || this.currentPlotPoints.length === 0) {
      return
    }
    if (!this.customLassoPoints || this.customLassoPoints.length < 3) {
      return
    }

    let minX = Infinity
    let maxX = -Infinity
    let minY = Infinity
    let maxY = -Infinity
    for (const point of this.customLassoPoints) {
      if (point.x < minX) minX = point.x
      if (point.x > maxX) maxX = point.x
      if (point.y < minY) minY = point.y
      if (point.y > maxY) maxY = point.y
    }

    const selectedIndices = []
    for (const point of this.currentPlotPoints) {
      if (point.canvasX < minX || point.canvasX > maxX || point.canvasY < minY || point.canvasY > maxY) {
        continue
      }
      if (this.controller && typeof this.controller.isPointInPolygon === 'function') {
        if (this.controller.isPointInPolygon(point.canvasX, point.canvasY, this.customLassoPoints)) {
          selectedIndices.push(point.cellIndex)
        }
      }
    }

    if (selectedIndices.length > 0 && typeof this.controller.applySelectionFromIndices === 'function') {
      this.controller.applySelectionFromIndices(selectedIndices, {
        source: 'custom-plot-lasso',
        replaceExisting: false,
        updateCustomPlot: true
      })
    }
  }

  onSelectionUpdated() {
    if (!this.currentCanvas) return
    this.drawSelectionHighlights()
  }

  getDistanceBetweenPoints(pointA, pointB) {
    if (!pointA || !pointB) return Infinity
    const dx = pointB.x - pointA.x
    const dy = pointB.y - pointA.y
    return Math.sqrt(dx * dx + dy * dy)
  }

  ensureOverlayCanvas(baseCanvas, type) {
    if (!baseCanvas) return null
    const parent = baseCanvas.parentElement
    if (!parent) return null
    const computedStyle = window.getComputedStyle(parent)
    if (computedStyle.position === 'static') {
      parent.style.position = 'relative'
    }

    let overlayCanvas
    if (type === 'selection') {
      overlayCanvas = this.selectionOverlayCanvas
      if (!overlayCanvas) {
        overlayCanvas = document.createElement('canvas')
        overlayCanvas.style.position = 'absolute'
        overlayCanvas.style.top = '0'
        overlayCanvas.style.left = '0'
        overlayCanvas.style.pointerEvents = 'none'
        overlayCanvas.style.zIndex = '3'
        parent.appendChild(overlayCanvas)
        this.selectionOverlayCanvas = overlayCanvas
        this.selectionOverlayCtx = overlayCanvas.getContext('2d')
      }
    } else if (type === 'lasso') {
      overlayCanvas = this.lassoOverlayCanvas
      if (!overlayCanvas) {
        overlayCanvas = document.createElement('canvas')
        overlayCanvas.style.position = 'absolute'
        overlayCanvas.style.top = '0'
        overlayCanvas.style.left = '0'
        overlayCanvas.style.pointerEvents = 'none'
        overlayCanvas.style.zIndex = '4'
        parent.appendChild(overlayCanvas)
        this.lassoOverlayCanvas = overlayCanvas
        this.lassoOverlayCtx = overlayCanvas.getContext('2d')
      }
    }

    if (!overlayCanvas) return null

    overlayCanvas.width = baseCanvas.width
    overlayCanvas.height = baseCanvas.height
    overlayCanvas.style.width = baseCanvas.style.width || `${baseCanvas.width}px`
    overlayCanvas.style.height = baseCanvas.style.height || `${baseCanvas.height}px`

    if (type === 'selection') {
      return this.selectionOverlayCtx
    }
    if (type === 'lasso') {
      return this.lassoOverlayCtx
    }
    return null
  }

  ensureSelectionOverlay(canvas) {
    return this.ensureOverlayCanvas(canvas, 'selection')
  }

  ensureLassoOverlay(canvas) {
    return this.ensureOverlayCanvas(canvas, 'lasso')
  }

  drawSelectionHighlights() {
    if (!this.currentCanvas) return
    const ctx = this.ensureSelectionOverlay(this.currentCanvas)
    if (!ctx) return
    ctx.clearRect(0, 0, this.currentCanvas.width, this.currentCanvas.height)
    const selectedCells = this.controller?.selectedCells
    if (!selectedCells || selectedCells.size === 0) {
      return
    }
    ctx.fillStyle = '#ff0000'
    for (const point of this.currentPlotPoints) {
      if (selectedCells.has(point.cellIndex)) {
        const radius = Math.max(point.radius || 2, 2)
        ctx.beginPath()
        ctx.arc(point.canvasX, point.canvasY, radius, 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }

  clearLassoOverlay() {
    if (this.lassoOverlayCtx && this.lassoOverlayCanvas) {
      this.lassoOverlayCtx.clearRect(0, 0, this.lassoOverlayCanvas.width, this.lassoOverlayCanvas.height)
    }
  }

  drawLassoPath(closePath = false) {
    if (!this.currentCanvas) return
    const ctx = this.ensureLassoOverlay(this.currentCanvas)
    if (!ctx) return
    ctx.clearRect(0, 0, this.lassoOverlayCanvas.width, this.lassoOverlayCanvas.height)
    if (!this.customLassoPoints || this.customLassoPoints.length === 0) return

    ctx.lineWidth = 1.5
    ctx.strokeStyle = '#3b82f6'
    ctx.fillStyle = 'rgba(59, 130, 246, 0.15)'

    ctx.beginPath()
    ctx.moveTo(this.customLassoPoints[0].x, this.customLassoPoints[0].y)
    for (let i = 1; i < this.customLassoPoints.length; i++) {
      ctx.lineTo(this.customLassoPoints[i].x, this.customLassoPoints[i].y)
    }
    if (closePath && this.customLassoPoints.length >= 3) {
      ctx.closePath()
      ctx.fill()
    }
    ctx.stroke()
  }

  removeOverlays() {
    if (this.selectionOverlayCanvas && this.selectionOverlayCanvas.parentElement) {
      this.selectionOverlayCanvas.parentElement.removeChild(this.selectionOverlayCanvas)
    }
    if (this.lassoOverlayCanvas && this.lassoOverlayCanvas.parentElement) {
      this.lassoOverlayCanvas.parentElement.removeChild(this.lassoOverlayCanvas)
    }
    this.selectionOverlayCanvas = null
    this.selectionOverlayCtx = null
    this.lassoOverlayCanvas = null
    this.lassoOverlayCtx = null
  }
  
  findClosestPoint(mouseX, mouseY) {
    if (!this.currentPlotPoints || this.currentPlotPoints.length === 0) {
      return null
    }
    let closestPoint = null
    let minDistSq = Infinity
    for (const point of this.currentPlotPoints) {
      const dx = point.canvasX - mouseX
      const dy = point.canvasY - mouseY
      const distSq = dx * dx + dy * dy
      if (distSq < minDistSq) {
        minDistSq = distSq
        closestPoint = point
      }
    }
    if (!closestPoint) {
      return null
    }
    const distance = Math.sqrt(minDistSq)
    const tolerance = Math.max(this.currentPickTolerance, closestPoint.radius ? closestPoint.radius * 5 : this.currentPickTolerance)
    if (distance <= tolerance) {
      return { point: closestPoint, distance }
    }
    return null
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
      const xButtonInfo = this.controller.selectedXButton
      const yButtonInfo = this.controller.selectedYButton
      const xIsGene = !!xButtonInfo?.isGene
      const yIsGene = !!yButtonInfo?.isGene
      const xGeneInfo = xIsGene ? this.resolveGeneMetadataIdentifiers(xButtonInfo) : null
      const yGeneInfo = yIsGene ? this.resolveGeneMetadataIdentifiers(yButtonInfo) : null

      const xMetadataId = xIsGene ? (xGeneInfo?.layerKey || xGeneInfo?.baseKey || xButtonInfo.metadataId) : xButtonInfo.metadataId
      const yMetadataId = yIsGene ? (yGeneInfo?.layerKey || yGeneInfo?.baseKey || yButtonInfo.metadataId) : yButtonInfo.metadataId

      // console.log('Loading data for 2D plot:', {
      //   xMetadataId,
      //   yMetadataId,
      //   xStableId: xGeneInfo?.stableId,
      //   yStableId: yGeneInfo?.stableId,
      //   xBaseMetadataId: xGeneInfo?.baseKey,
      //   yBaseMetadataId: yGeneInfo?.baseKey,
      //   currentLayer: this.controller?.geneManager?.currentMatrixLayer,
      //   currentAnnotId: this.controller?.geneManager?.currentMatrixAnnotId
      // })
      
      // Load x vector
      let xVector = null
      if (xIsGene) {
        if (!xGeneInfo) {
          console.warn('X-axis: Unable to resolve gene metadata identifiers', xButtonInfo)
        } else {
          const stableId = xGeneInfo.stableId
          const stableIdNum = Number(stableId)
          const candidateKeys = [...new Set([xGeneInfo.layerKey, xGeneInfo.baseKey].filter(Boolean))]
          const geneDataStore = this.controller.geneManager?.geneExpressionData || {}

          for (const key of candidateKeys) {
            if (this.controller.loadedMetadataVectors?.[key]?.values) {
              xVector = this.controller.loadedMetadataVectors[key]
              // console.log(`X-axis: Found gene ${stableId} in loadedMetadataVectors using key ${key}`)
              break
            }
          }

          if (!xVector) {
            let geneData = geneDataStore[stableId] || geneDataStore[stableIdNum]

            if (geneData && geneData.values && geneData.values.length > 0) {
              // console.log(`X-axis: Found gene ${stableId} in geneExpressionData`)
            } else {
              let gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === stableId || Number(g.stableId) === stableIdNum)

              if (!gene && xButtonInfo.button) {
                const buttonGeneId = xButtonInfo.button.dataset?.geneId
                if (buttonGeneId) {
                  gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === String(buttonGeneId) || Number(g.stableId) === Number(buttonGeneId))
                }
              }

              if (!gene) {
                console.warn(`X-axis: Gene ${stableId} not found in geneTags; attempting lazy load`)
                if (this.controller.geneManager) {
                  try {
                    const geneObj = {
                      stableId: stableIdNum || parseInt(stableId, 10),
                      symbol: xButtonInfo.metadataName || `Gene ${stableId}`,
                      ensemblId: '',
                      query: xButtonInfo.metadataName || `Gene ${stableId}`
                    }
                    await this.controller.geneManager.loadGeneExpressionData(geneObj, null)
                    geneData = this.controller.geneManager?.geneExpressionData?.[stableId] || this.controller.geneManager?.geneExpressionData?.[stableIdNum]
                  } catch (error) {
                    console.error(`X-axis: Failed to lazily load gene ${stableId}`, error)
                  }
                }
              } else {
                try {
                  await this.controller.geneManager.loadGeneExpressionData(gene, null)
                  geneData = this.controller.geneManager?.geneExpressionData?.[stableId] || this.controller.geneManager?.geneExpressionData?.[stableIdNum]
                } catch (error) {
                  console.error(`X-axis: Error loading gene ${stableId} from geneTags`, error)
                }
              }
            }

            if (geneData && geneData.values && geneData.values.length > 0) {
              const minVal = this.controller.dataManager.safeMin(geneData.values)
              const maxVal = this.controller.dataManager.safeMax(geneData.values)
              xVector = {
                id: xGeneInfo.layerKey,
                name: geneData.symbol || `Gene ${stableId}`,
                display_name: geneData.symbol || `Gene ${stableId}`,
                data_type: 'NUMERIC',
                values: geneData.values,
                compression_info: {
                  min_val: minVal,
                  max_val: maxVal,
                  data_type: 'NUMERIC'
                }
              }
              if (!this.controller.loadedMetadataVectors) {
                this.controller.loadedMetadataVectors = {}
              }
              candidateKeys.forEach(key => {
                this.controller.loadedMetadataVectors[key] = xVector
              })
            }
          }
        }
      } else {
        xVector = await this.controller.dataManager.loadSingleMetadataVector(xMetadataId)
        if (xVector) {
          if (!xVector.values && xVector.compressed_data) {
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
      if (yIsGene) {
        if (!yGeneInfo) {
          console.warn('Y-axis: Unable to resolve gene metadata identifiers', yButtonInfo)
        } else {
          const stableId = yGeneInfo.stableId
          const stableIdNum = Number(stableId)
          const candidateKeys = [...new Set([yGeneInfo.layerKey, yGeneInfo.baseKey].filter(Boolean))]
          const geneDataStore = this.controller.geneManager?.geneExpressionData || {}

          for (const key of candidateKeys) {
            if (this.controller.loadedMetadataVectors?.[key]?.values) {
              yVector = this.controller.loadedMetadataVectors[key]
              // console.log(`Y-axis: Found gene ${stableId} in loadedMetadataVectors using key ${key}`)
              break
            }
          }

          if (!yVector) {
            let geneData = geneDataStore[stableId] || geneDataStore[stableIdNum]

            if (geneData && geneData.values && geneData.values.length > 0) {
              // console.log(`Y-axis: Found gene ${stableId} in geneExpressionData`)
            } else {
              let gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === stableId || Number(g.stableId) === stableIdNum)

              if (!gene && yButtonInfo.button) {
                const buttonGeneId = yButtonInfo.button.dataset?.geneId
                if (buttonGeneId) {
                  gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === String(buttonGeneId) || Number(g.stableId) === Number(buttonGeneId))
                }
              }

              if (!gene) {
                console.warn(`Y-axis: Gene ${stableId} not found in geneTags; attempting lazy load`)
                if (this.controller.geneManager) {
                  try {
                    const geneObj = {
                      stableId: stableIdNum || parseInt(stableId, 10),
                      symbol: yButtonInfo.metadataName || `Gene ${stableId}`,
                      ensemblId: '',
                      query: yButtonInfo.metadataName || `Gene ${stableId}`
                    }
                    await this.controller.geneManager.loadGeneExpressionData(geneObj, null)
                    geneData = this.controller.geneManager?.geneExpressionData?.[stableId] || this.controller.geneManager?.geneExpressionData?.[stableIdNum]
                  } catch (error) {
                    console.error(`Y-axis: Failed to lazily load gene ${stableId}`, error)
                  }
                }
              } else {
                try {
                  await this.controller.geneManager.loadGeneExpressionData(gene, null)
                  geneData = this.controller.geneManager?.geneExpressionData?.[stableId] || this.controller.geneManager?.geneExpressionData?.[stableIdNum]
                } catch (error) {
                  console.error(`Y-axis: Error loading gene ${stableId} from geneTags`, error)
                }
              }
            }

            if (geneData && geneData.values && geneData.values.length > 0) {
              const minVal = this.controller.dataManager.safeMin(geneData.values)
              const maxVal = this.controller.dataManager.safeMax(geneData.values)
              yVector = {
                id: yGeneInfo.layerKey,
                name: geneData.symbol || `Gene ${stableId}`,
                display_name: geneData.symbol || `Gene ${stableId}`,
                data_type: 'NUMERIC',
                values: geneData.values,
                compression_info: {
                  min_val: minVal,
                  max_val: maxVal,
                  data_type: 'NUMERIC'
                }
              }
              if (!this.controller.loadedMetadataVectors) {
                this.controller.loadedMetadataVectors = {}
              }
              candidateKeys.forEach(key => {
                this.controller.loadedMetadataVectors[key] = yVector
              })
            }
          }
        }
      } else {
        yVector = await this.controller.dataManager.loadSingleMetadataVector(yMetadataId)
        if (yVector) {
          if (!yVector.values && yVector.compressed_data) {
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
        const xButtonInfo = this.controller.selectedXButton
        const yButtonInfo = this.controller.selectedYButton
        const xIsGene = !!xButtonInfo?.isGene
        const yIsGene = !!yButtonInfo?.isGene
        const xGeneInfo = xIsGene ? this.resolveGeneMetadataIdentifiers(xButtonInfo) : null
        const yGeneInfo = yIsGene ? this.resolveGeneMetadataIdentifiers(yButtonInfo) : null
        const xStableId = xGeneInfo?.stableId || xButtonInfo?.button?.dataset?.geneId || xButtonInfo?.metadataId
        const yStableId = yGeneInfo?.stableId || yButtonInfo?.button?.dataset?.geneId || yButtonInfo?.metadataId
        const xLayerKey = xGeneInfo?.layerKey || (xStableId ? `gene_${xStableId}` : xButtonInfo?.metadataId)
        const yLayerKey = yGeneInfo?.layerKey || (yStableId ? `gene_${yStableId}` : yButtonInfo?.metadataId)
        const xBaseKey = xGeneInfo?.baseKey || (xStableId ? `gene_${xStableId}` : xButtonInfo?.metadataId)
        const yBaseKey = yGeneInfo?.baseKey || (yStableId ? `gene_${yStableId}` : yButtonInfo?.metadataId)
        const xName = xButtonInfo?.metadataName
        const yName = yButtonInfo?.metadataName
        
        // Build detailed diagnostic information
        let errorDetails = []
        let consoleDetails = {
          xVector: !!xVector,
          yVector: !!yVector,
          xIsGene,
          yIsGene,
          xStableId,
          yStableId,
          xLayerKey,
          yLayerKey,
          xBaseKey,
          yBaseKey,
          currentLayer: this.controller?.geneManager?.currentMatrixLayer,
          currentAnnotId: this.controller?.geneManager?.currentMatrixAnnotId
        }
        
        if (!xVector) {
          if (xIsGene) {
            const stableIdStr = String(xStableId)
            const stableIdNum = Number(stableIdStr)
            
            const xInGeneTags = !!this.controller.geneManager?.geneTags?.find(g => 
              String(g.stableId) === stableIdStr || Number(g.stableId) === stableIdNum
            )
            const geneDataStore = this.controller.geneManager?.geneExpressionData || {}
            const xInExpressionData = !!(geneDataStore[stableIdStr] || geneDataStore[stableIdNum])
            const xInLoadedVectors = !!(this.controller.loadedMetadataVectors?.[xLayerKey] || this.controller.loadedMetadataVectors?.[xBaseKey])
            const xExpressionDataKeys = Object.keys(geneDataStore)
            const xLoadedVectorsKeys = Object.keys(this.controller.loadedMetadataVectors || {}).filter(k => k.startsWith('gene_'))
            
            errorDetails.push(`X-axis gene "${xName}" (stable ID: ${stableIdStr}) could not be loaded.`)
            errorDetails.push(`  - In geneTags: ${xInGeneTags}`)
            errorDetails.push(`  - In geneExpressionData: ${xInExpressionData} (checked keys: ${[stableIdStr, stableIdNum].join(', ')})`)
            errorDetails.push(`  - In loadedMetadataVectors: ${xInLoadedVectors} (checked: ${[xLayerKey, xBaseKey].filter(Boolean).join(', ') || 'none'})`)
            
            if (xExpressionDataKeys.length > 0) {
              const matchingKeys = xExpressionDataKeys.filter(k => 
                k === stableIdStr || Number(k) === stableIdNum
              )
              errorDetails.push(`  - Matching geneExpressionData keys: ${matchingKeys.length > 0 ? matchingKeys.join(', ') : 'none'}`)
              errorDetails.push(`  - First 10 geneExpressionData keys: ${xExpressionDataKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push('  - geneExpressionData is empty or undefined')
            }
            
            if (xLoadedVectorsKeys.length > 0) {
              errorDetails.push(`  - First 10 loadedMetadataVectors gene keys: ${xLoadedVectorsKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push('  - No gene keys found in loadedMetadataVectors')
            }
            
            if (xInExpressionData) {
              const xGeneData = geneDataStore[stableIdStr] || geneDataStore[stableIdNum]
              if (xGeneData) {
                errorDetails.push(`  - geneExpressionData found but: hasValues=${!!xGeneData.values}, valuesLength=${xGeneData.values?.length || 0}`)
              }
            }
            
            consoleDetails.xInGeneTags = xInGeneTags
            consoleDetails.xInExpressionData = xInExpressionData
            consoleDetails.xInLoadedVectors = xInLoadedVectors
            consoleDetails.xExpressionDataKeys = xExpressionDataKeys.slice(0, 20)
            consoleDetails.xLoadedVectorsKeys = xLoadedVectorsKeys.slice(0, 20)
          } else {
            errorDetails.push(`X-axis metadata "${xName}" (ID: ${xLayerKey}) could not be loaded.`)
            errorDetails.push('  - The metadata may not exist in the dataset.')
          }
        }
        
        if (!yVector) {
          if (yIsGene) {
            const stableIdStr = String(yStableId)
            const stableIdNum = Number(stableIdStr)
            
            const yInGeneTags = !!this.controller.geneManager?.geneTags?.find(g => 
              String(g.stableId) === stableIdStr || Number(g.stableId) === stableIdNum
            )
            const geneDataStore = this.controller.geneManager?.geneExpressionData || {}
            const yInExpressionData = !!(geneDataStore[stableIdStr] || geneDataStore[stableIdNum])
            const yInLoadedVectors = !!(this.controller.loadedMetadataVectors?.[yLayerKey] || this.controller.loadedMetadataVectors?.[yBaseKey])
            const yExpressionDataKeys = Object.keys(geneDataStore)
            const yLoadedVectorsKeys = Object.keys(this.controller.loadedMetadataVectors || {}).filter(k => k.startsWith('gene_'))
            
            errorDetails.push(`Y-axis gene "${yName}" (stable ID: ${stableIdStr}) could not be loaded.`)
            errorDetails.push(`  - In geneTags: ${yInGeneTags}`)
            errorDetails.push(`  - In geneExpressionData: ${yInExpressionData} (checked keys: ${[stableIdStr, stableIdNum].join(', ')})`)
            errorDetails.push(`  - In loadedMetadataVectors: ${yInLoadedVectors} (checked: ${[yLayerKey, yBaseKey].filter(Boolean).join(', ') || 'none'})`)
            
            if (yExpressionDataKeys.length > 0) {
              const matchingKeys = yExpressionDataKeys.filter(k => 
                k === stableIdStr || Number(k) === stableIdNum
              )
              errorDetails.push(`  - Matching geneExpressionData keys: ${matchingKeys.length > 0 ? matchingKeys.join(', ') : 'none'}`)
              errorDetails.push(`  - First 10 geneExpressionData keys: ${yExpressionDataKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push('  - geneExpressionData is empty or undefined')
            }
            
            if (yLoadedVectorsKeys.length > 0) {
              errorDetails.push(`  - First 10 loadedMetadataVectors gene keys: ${yLoadedVectorsKeys.slice(0, 10).join(', ')}`)
            } else {
              errorDetails.push('  - No gene keys found in loadedMetadataVectors')
            }
            
            if (yInExpressionData) {
              const yGeneData = geneDataStore[stableIdStr] || geneDataStore[stableIdNum]
              if (yGeneData) {
                errorDetails.push(`  - geneExpressionData found but: hasValues=${!!yGeneData.values}, valuesLength=${yGeneData.values?.length || 0}`)
              }
            }
            
            consoleDetails.yInGeneTags = yInGeneTags
            consoleDetails.yInExpressionData = yInExpressionData
            consoleDetails.yInLoadedVectors = yInLoadedVectors
            consoleDetails.yExpressionDataKeys = yExpressionDataKeys.slice(0, 20)
            consoleDetails.yLoadedVectorsKeys = yLoadedVectorsKeys.slice(0, 20)
          } else {
            errorDetails.push(`Y-axis metadata "${yName}" (ID: ${yLayerKey}) could not be loaded.`)
            errorDetails.push('  - The metadata may not exist in the dataset.')
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
    
    // console.log('Refreshing 2D plot modal due to coloring change')
    
    try {
      // Get the canvas and data vectors
      const canvas = document.getElementById('2d-plot-canvas')
      if (!canvas) return
      
      const xButtonInfo = this.controller.selectedXButton
      const yButtonInfo = this.controller.selectedYButton
      const xIsGene = !!xButtonInfo?.isGene
      const yIsGene = !!yButtonInfo?.isGene
      const xGeneInfo = xIsGene ? this.resolveGeneMetadataIdentifiers(xButtonInfo) : null
      const yGeneInfo = yIsGene ? this.resolveGeneMetadataIdentifiers(yButtonInfo) : null
      const xMetadataId = xIsGene ? (xGeneInfo?.layerKey || xGeneInfo?.baseKey || xButtonInfo.metadataId) : xButtonInfo.metadataId
      const yMetadataId = yIsGene ? (yGeneInfo?.layerKey || yGeneInfo?.baseKey || yButtonInfo.metadataId) : yButtonInfo.metadataId
      
      // Log current layer usage for verification
      // console.log('Refreshing 2D plot with metadata IDs:', {
      //   xMetadataId,
      //   yMetadataId,
      //   xStableId: xGeneInfo?.stableId,
      //   yStableId: yGeneInfo?.stableId,
      //   currentLayer: this.controller?.geneManager?.currentMatrixLayer,
      //   currentAnnotId: this.controller?.geneManager?.currentMatrixAnnotId
      // })
      
      // Get filtered indices
      const filteredIndices = this.controller.dataManager?.getIncrementalFilteredIndices()
      
      // Load x vector
      let xVector = null
      if (xIsGene) {
        if (!xGeneInfo) {
          console.warn('Refresh X-axis: Unable to resolve gene metadata identifiers', xButtonInfo)
        } else {
          const stableId = xGeneInfo.stableId
          const stableIdNum = Number(stableId)
          const candidateKeys = [...new Set([xGeneInfo.layerKey, xGeneInfo.baseKey].filter(Boolean))]
          const geneDataStore = this.controller.geneManager?.geneExpressionData || {}

          for (const key of candidateKeys) {
            if (this.controller.loadedMetadataVectors?.[key]?.values) {
              xVector = this.controller.loadedMetadataVectors[key]
              break
            }
          }

          if (!xVector) {
            let geneData = geneDataStore[stableId] || geneDataStore[stableIdNum]
            if (!geneData || !geneData.values || geneData.values.length === 0) {
              let gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === stableId || Number(g.stableId) === stableIdNum)
              if (!gene && xButtonInfo.button?.dataset?.geneId) {
                const buttonGeneId = xButtonInfo.button.dataset.geneId
                gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === String(buttonGeneId) || Number(g.stableId) === Number(buttonGeneId))
              }

              if (gene) {
                await this.controller.geneManager.loadGeneExpressionData(gene, null)
                geneData = this.controller.geneManager?.geneExpressionData?.[stableId] || this.controller.geneManager?.geneExpressionData?.[stableIdNum]
              }
            }

            if (geneData && geneData.values && geneData.values.length > 0) {
              const minVal = this.controller.dataManager.safeMin(geneData.values)
              const maxVal = this.controller.dataManager.safeMax(geneData.values)
              xVector = {
                id: xGeneInfo.layerKey,
                name: geneData.symbol || `Gene ${stableId}`,
                data_type: 'NUMERIC',
                values: geneData.values,
                compression_info: {
                  min_val: minVal,
                  max_val: maxVal,
                  data_type: 'NUMERIC'
                }
              }
              if (!this.controller.loadedMetadataVectors) {
                this.controller.loadedMetadataVectors = {}
              }
              candidateKeys.forEach(key => {
                this.controller.loadedMetadataVectors[key] = xVector
              })
            }
          }
        }
      } else {
        xVector = await this.controller.dataManager.loadSingleMetadataVector(xMetadataId)
      }
      
      // Load y vector
      let yVector = null
      if (yIsGene) {
        if (!yGeneInfo) {
          console.warn('Refresh Y-axis: Unable to resolve gene metadata identifiers', yButtonInfo)
        } else {
          const stableId = yGeneInfo.stableId
          const stableIdNum = Number(stableId)
          const candidateKeys = [...new Set([yGeneInfo.layerKey, yGeneInfo.baseKey].filter(Boolean))]
          const geneDataStore = this.controller.geneManager?.geneExpressionData || {}

          for (const key of candidateKeys) {
            if (this.controller.loadedMetadataVectors?.[key]?.values) {
              yVector = this.controller.loadedMetadataVectors[key]
              break
            }
          }

          if (!yVector) {
            let geneData = geneDataStore[stableId] || geneDataStore[stableIdNum]
            if (!geneData || !geneData.values || geneData.values.length === 0) {
              let gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === stableId || Number(g.stableId) === stableIdNum)
              if (!gene && yButtonInfo.button?.dataset?.geneId) {
                const buttonGeneId = yButtonInfo.button.dataset.geneId
                gene = this.controller.geneManager?.geneTags?.find(g => String(g.stableId) === String(buttonGeneId) || Number(g.stableId) === Number(buttonGeneId))
              }

              if (gene) {
                await this.controller.geneManager.loadGeneExpressionData(gene, null)
                geneData = this.controller.geneManager?.geneExpressionData?.[stableId] || this.controller.geneManager?.geneExpressionData?.[stableIdNum]
              }
            }

            if (geneData && geneData.values && geneData.values.length > 0) {
              const minVal = this.controller.dataManager.safeMin(geneData.values)
              const maxVal = this.controller.dataManager.safeMax(geneData.values)
              yVector = {
                id: yGeneInfo.layerKey,
                name: geneData.symbol || `Gene ${stableId}`,
                data_type: 'NUMERIC',
                values: geneData.values,
                compression_info: {
                  min_val: minVal,
                  max_val: maxVal,
                  data_type: 'NUMERIC'
                }
              }
              if (!this.controller.loadedMetadataVectors) {
                this.controller.loadedMetadataVectors = {}
              }
              candidateKeys.forEach(key => {
                this.controller.loadedMetadataVectors[key] = yVector
              })
            }
          }
        }
      } else {
        yVector = await this.controller.dataManager.loadSingleMetadataVector(yMetadataId)
      }
      
      if (!xVector || !yVector) {
        console.error('Cannot refresh 2D plot - missing vectors', { xVectorExists: !!xVector, yVectorExists: !!yVector })
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
    // console.log('Rendering scatter plot 2D')
    
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    this.currentCanvasContext = ctx
    
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
    let xMin = Infinity
    let xMax = -Infinity
    let yMin = Infinity
    let yMax = -Infinity
    for (let i = 0; i < xValues.length; i++) {
      if (!filteredSet || filteredSet.has(i)) {
        const x = xValues[i]
        const y = yValues[i]
        dataPoints.push({
          x,
          y,
          cellIndex: i
        })
        if (x < xMin) xMin = x
        if (x > xMax) xMax = x
        if (y < yMin) yMin = y
        if (y > yMax) yMax = y
      }
    }
    
    if (dataPoints.length === 0) {
      ctx.fillStyle = '#6b7280'
      ctx.font = '16px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('No data points to display', width / 2, height / 2)
      return
    }
    
    // Calculate bounds (ensure finite defaults)
    if (!Number.isFinite(xMin) || !Number.isFinite(xMax) || !Number.isFinite(yMin) || !Number.isFinite(yMax)) {
      console.error('Unable to determine bounds for scatter plot', { xMin, xMax, yMin, yMax })
      return
    }
    
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
    const plotPoints = []
    for (const point of dataPoints) {
      const canvasX = scaleX(point.x)
      const canvasY = scaleY(point.y)
      
      // Get color for this point
      let color = '#3b82f6' // Default blue
      if (coloringVector && this.controller.colorManager && typeof this.controller.colorManager.getColorAndAlpha === 'function') {
        const { color: pointColor } = this.controller.colorManager.getColorAndAlpha(point.cellIndex, coloringVector)
        // Convert hex number to CSS color string
        color = '#' + pointColor.toString(16).padStart(6, '0')
      }
      
      ctx.fillStyle = color
      ctx.beginPath()
      ctx.arc(canvasX, canvasY, pointSize, 0, Math.PI * 2)
      ctx.fill()
      plotPoints.push({ cellIndex: point.cellIndex, canvasX, canvasY, radius: pointSize })
    }
    
    if (plotPoints.length > 0) {
      this.currentPlotPoints = plotPoints
      this.currentPickTolerance = Math.max(pointSize * 4, 12)
      this.currentPlotType = 'scatter'
    } else {
      this.currentPlotPoints = []
    }
    this.setupCanvasInteractions(canvas)
    this.drawSelectionHighlights()
    
    // console.log('Scatter plot rendered with', dataPoints.length, 'points')
  }
  
  // Render violin plot for 2D modal (x is categorical)
  async renderViolinPlot2D(canvas, xVector, yVector, filteredIndices) {
    // console.log('Rendering violin plot 2D')
    
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    this.currentCanvasContext = ctx
    
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
    const plotPoints = []
    
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
        if (coloringVector && this.controller.colorManager && typeof this.controller.colorManager.getColorAndAlpha === 'function') {
          const { color: pointColor } = this.controller.colorManager.getColorAndAlpha(point.cellIndex, coloringVector)
          // Convert hex number to CSS color string
          color = '#' + pointColor.toString(16).padStart(6, '0')
        }
        
        ctx.fillStyle = color
        ctx.beginPath()
        ctx.arc(pointX, y, pointSize, 0, Math.PI * 2)
        ctx.fill()
        plotPoints.push({ cellIndex: point.cellIndex, canvasX: pointX, canvasY: y, radius: pointSize })
      }
    })
    if (plotPoints.length > 0) {
      this.currentPlotPoints = plotPoints
      this.currentPickTolerance = Math.max(pointSize * 6, 14)
      this.currentPlotType = 'violin'
    } else {
      this.currentPlotPoints = []
    }
    this.setupCanvasInteractions(canvas)
    this.drawSelectionHighlights()
    
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
    
    // console.log('Violin plot rendered with', categories.length, 'categories')
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



