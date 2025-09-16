// PIXI.js Rendering Module for Visualization
// Handles all PIXI.js related rendering operations

export class PixiRenderer {
  constructor(controller) {
    this.controller = controller
    this.pixiApp = null
    this.scatterContainer = null
    this.axesContainer = null
    this.gridContainer = null
    this.categoryLabelsContainer = null
    this.animatedContainer = null
  }

  // Initialize PIXI application
  async initializePixiScatterPlot(coordinates) {
    const canvas = this.controller.canvas
    if (!canvas) {
      console.error('Canvas element not found')
      return
    }

    // Import PIXI dynamically
    const PIXI = await import('pixi.js')
    this.PIXI = PIXI

    // Create PIXI application
    this.pixiApp = new PIXI.Application({
      view: canvas,
      width: canvas.clientWidth,
      height: canvas.clientHeight,
      backgroundColor: 0xffffff,
      antialias: true,
      resolution: window.devicePixelRatio || 1,
      autoDensity: true
    })

    // Create containers for different layers
    this.scatterContainer = new PIXI.Container()
    this.axesContainer = new PIXI.Container()
    this.gridContainer = new PIXI.Container()
    this.categoryLabelsContainer = new PIXI.Container()

    // Add containers to stage in correct order (bottom to top)
    this.pixiApp.stage.addChild(this.gridContainer)
    this.pixiApp.stage.addChild(this.axesContainer)
    this.pixiApp.stage.addChild(this.scatterContainer)
    this.pixiApp.stage.addChild(this.categoryLabelsContainer)

    // Calculate bounds and render
    const originalBounds = this.controller.calculateBounds(coordinates)
    const bounds = this.controller.getAdjustedBounds(originalBounds)
    this.controller.currentBounds = bounds
    this.controller.currentCoordinates = coordinates

    // Render axes, grid, and category labels
    this.renderAxes()
    this.renderGrid()
    this.renderCategoryLabels()

    // Set point properties
    const pointSize = this.controller.currentPointSize
    const pointColor = 0x3b82f6 // Blue color

    // Render points individually to support pan/zoom optimization
    for (let i = 0; i < coordinates.length; i++) {
      const [x, y] = coordinates[i]
      
      // Normalize coordinates to screen space
      const screenX = this.normalizeX(x, bounds)
      const screenY = this.normalizeY(y, bounds)
      
      // Create individual point graphics
      const point = new PIXI.Graphics()
      point.beginFill(pointColor)
      point.drawCircle(0, 0, pointSize)
      point.endFill()
      point.x = screenX
      point.y = screenY
      
      // Store cell ID and mark as point for later reference
      point.cellId = i
      point.isPoint = true
      
      // Store original color for reset functionality
      this.controller.storeOriginalPointColor(i, pointColor)
      
      // Add hover functionality
      point.interactive = true
      point.buttonMode = false
      point.on('pointerover', () => this.controller.showTooltip(i, point))
      point.on('pointerout', () => this.controller.hideTooltip())
      point.on('pointerdown', (event) => this.controller.onPointClick(i, point, event))
      
      this.scatterContainer.addChild(point)
    }

    // Add interaction handlers
    this.controller.addInteractionHandlers()
    this.controller.setupGlobalDragHandlers()

    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = coordinates.length.toLocaleString()
    }

    //console.log(`PIXI scatter plot initialized with ${coordinates.length} points`)
  }

  // Render scatter plot with new coordinates
  async renderScatterPlot(coordinates) {
    if (!this.pixiApp) {
      await this.initializePixiScatterPlot(coordinates)
      return
    }

    // Calculate bounds
    const originalBounds = this.controller.calculateBounds(coordinates)
    const bounds = this.controller.getAdjustedBounds(originalBounds)
    this.controller.currentBounds = bounds
    this.controller.currentCoordinates = coordinates

    // Render axes, grid, and category labels
    this.renderAxes()
    this.renderGrid()
    this.renderCategoryLabels()

    // Clear existing points
    this.scatterContainer.removeChildren()

    // Set point properties
    const pointSize = this.controller.currentPointSize
    const pointColor = 0x3b82f6 // Blue color

    // Render points individually to support pan/zoom optimization
    for (let i = 0; i < coordinates.length; i++) {
      const [x, y] = coordinates[i]
      
      // Normalize coordinates to screen space
      const screenX = this.normalizeX(x, bounds)
      const screenY = this.normalizeY(y, bounds)
      
      // Create individual point graphics
      const point = new PIXI.Graphics()
      point.beginFill(pointColor)
      point.drawCircle(0, 0, pointSize)
      point.endFill()
      point.x = screenX
      point.y = screenY
      
      // Store cell ID and mark as point for later reference
      point.cellId = i
      point.isPoint = true
      
      // Store original color for reset functionality
      this.controller.storeOriginalPointColor(i, pointColor)
      
      // Add hover functionality
      point.interactive = true
      point.buttonMode = false
      point.on('pointerover', () => this.controller.showTooltip(i, point))
      point.on('pointerout', () => this.controller.hideTooltip())
      point.on('pointerdown', (event) => this.controller.onPointClick(i, point, event))
      
      this.scatterContainer.addChild(point)
    }

    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = coordinates.length.toLocaleString()
    }

    //console.log(`Rendered scatter plot with ${coordinates.length} points`)
  }

  // Update scatter plot with new coordinates (with animation if needed)
  async updateScatterPlot(coordinates) {
    if (!this.pixiApp) {
      await this.renderScatterPlot(coordinates)
      return
    }

    // Check if we need animation
    const shouldAnimate = this.controller.detectEmbeddingMethodChange(coordinates)
    
    if (!shouldAnimate) {
      // No animation needed, just update coordinates
      this.controller.currentCoordinates = coordinates
      
      // Re-render with new coordinates using current coloring
      this.controller.renderPointsWithCurrentColoring()
      
      // Reapply filtering after coordinate update
      this.controller.updateCellFiltering()
      
      // Update point count display
      const pointCountElement = document.getElementById('point-count')
      if (pointCountElement) {
        pointCountElement.textContent = coordinates.length.toLocaleString()
      }
      return
    }

    //console.log('Different embedding method detected, creating animated transition')
    
    // Clear incremental filtering state when embedding changes
    this.controller.clearIncrementalState()

    // Calculate new bounds
    const originalNewBounds = this.controller.calculateBounds(coordinates)
    const newBounds = this.controller.getAdjustedBounds(originalNewBounds)
    
    // Store current bounds and coordinates for transition
    const currentBounds = this.controller.currentBounds || newBounds
    const previousCoordinates = this.controller.currentCoordinates || coordinates

    // Update current bounds and coordinates
    this.controller.currentBounds = newBounds
    this.controller.currentCoordinates = coordinates

    // Render axes, grid, and category labels with new bounds
    this.renderAxes()
    this.renderGrid()
    this.renderCategoryLabels()
    
    // Clean up any existing animated container
    if (this.animatedContainer) {
      this.scatterContainer.removeChild(this.animatedContainer)
    }

    // Clear all existing individual points before animation
    this.scatterContainer.removeChildren()

    // Create individual point sprites for animation using previous coordinates
    this.createAnimatedPoints(previousCoordinates, coordinates, currentBounds, newBounds)

    // Update point count display
    const pointCountElement = document.getElementById('point-count')
    if (pointCountElement) {
      pointCountElement.textContent = coordinates.length.toLocaleString()
    }
  }

  // Create animated points for embedding transitions
  createAnimatedPoints(previousCoordinates, newCoordinates, fromBounds, toBounds) {
    const pointSize = this.controller.currentPointSize
    const animationDuration = 4000 // 4 seconds for very smooth transition

    // Create a container for animated points
    const animatedContainer = new this.PIXI.Container()
    this.scatterContainer.addChild(animatedContainer)
    this.animatedContainer = animatedContainer

    // Clear existing category labels during animation
    if (this.categoryLabelsContainer) {
      this.categoryLabelsContainer.removeChildren()
    }

    // Create individual point sprites
    const points = []
    let maxMovement = 0
    const minLength = Math.min(previousCoordinates.length, newCoordinates.length)

    // Sort point indices by category size (largest categories first) if we have metadata coloring
    let sortedIndices = Array.from({ length: minLength }, (_, i) => i)
    
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.data_type === 'DISCRETE' && this.controller.currentMetadataVector.values) {
      const values = this.controller.currentMetadataVector.values
      
      // Calculate category frequencies for layering (larger categories first)
      const categoryFrequencies = {}
      values.forEach(value => {
        categoryFrequencies[value] = (categoryFrequencies[value] || 0) + 1
      })
      
      // Sort point indices by category size (largest categories first, so they render in background)
      sortedIndices = sortedIndices.sort((a, b) => {
        const categoryA = values[a]
        const categoryB = values[b]
        const freqA = categoryFrequencies[categoryA]
        const freqB = categoryFrequencies[categoryB]
        return freqB - freqA // Descending order (largest first)
      })
    }
    
    // Create points in sorted order (largest categories first)
    sortedIndices.forEach(i => {
      const [prevX, prevY] = previousCoordinates[i]
      const [newX, newY] = newCoordinates[i]
      
      // Calculate start and end positions
      const startX = this.normalizeX(prevX, fromBounds)
      const startY = this.normalizeY(prevY, fromBounds)
      const endX = this.normalizeX(newX, toBounds)
      const endY = this.normalizeY(newY, toBounds)
      
      // Track maximum movement for debugging
      const movement = Math.sqrt((endX - startX) ** 2 + (endY - startY) ** 2)
      maxMovement = Math.max(maxMovement, movement)
      
      // Determine point color using centralized color function
      const pointColor = this.controller.getPointColor(i)
      
      // Create point sprite
      const point = new this.PIXI.Graphics()
      point.beginFill(pointColor)
      point.drawCircle(0, 0, pointSize)
      point.endFill()
      
      // Set initial position
      point.x = startX
      point.y = startY
      
      // Store cell ID and mark as point for later reference
      point.cellId = i
      point.isPoint = true
      
      // Store original color for reset functionality
      this.controller.storeOriginalPointColor(i, pointColor)
      
      // Add hover functionality
      point.interactive = true
      point.buttonMode = false
      point.on('pointerover', () => this.controller.showTooltip(i, point))
      point.on('pointerout', () => this.controller.hideTooltip())
      point.on('pointerdown', (event) => this.controller.onPointClick(i, point, event))
      
      animatedContainer.addChild(point)
      points.push({ sprite: point, startX, startY, endX, endY })
    })

    // Get current filtered indices to respect filtering during animation
    const currentFilteredIndices = this.controller.getIncrementalFilteredIndices()
    const filteredSet = currentFilteredIndices ? new Set(currentFilteredIndices) : null

    // Animate all points
    const startTime = Date.now()
    const animate = () => {
      const elapsed = Date.now() - startTime
      const progress = Math.min(1, elapsed / animationDuration)
      
      points.forEach(({ sprite, startX, startY, endX, endY }) => {
        sprite.x = startX + (endX - startX) * progress
        sprite.y = startY + (endY - startY) * progress
        
        // Respect filtering during animation
        if (filteredSet) {
          sprite.visible = filteredSet.has(sprite.cellId)
        }
      })
      
      if (progress < 1) {
        requestAnimationFrame(animate)
      } else {
        // Animation complete, convert to efficient graphics object
        this.convertToGraphicsObject(newCoordinates, toBounds, animatedContainer)
        
        // Re-render category labels after animation
        this.renderCategoryLabels()
        
        // Reapply filtering after embedding change
        this.controller.updateCellFiltering()
      }
    }

    // Start animation
    animate()
  }

  // Convert animated points back to efficient graphics object
  convertToGraphicsObject(newCoordinates, bounds, animatedContainer) {
    // Remove animated container
    this.scatterContainer.removeChild(animatedContainer)
    
    // Clear existing points
    this.scatterContainer.removeChildren()
    
    // Create new efficient graphics object
    const graphics = new this.PIXI.Graphics()
    graphics.beginFill(0x3b82f6) // Default blue color
    
    // Add all points to single graphics object for better performance
    for (let i = 0; i < newCoordinates.length; i++) {
      const [x, y] = newCoordinates[i]
      const screenX = this.normalizeX(x, bounds)
      const screenY = this.normalizeY(y, bounds)
      graphics.drawCircle(screenX, screenY, this.controller.currentPointSize)
    }
    
    graphics.endFill()
    this.scatterContainer.addChild(graphics)
  }

  // Render axes
  renderAxes() {
    if (!this.axesContainer || !this.controller.currentBounds || !this.pixiApp) {
      return
    }

    // Clear existing axes
    this.axesContainer.removeChildren()

    if (!this.axesContainer.visible) {
      return
    }

    const { minX, maxX, minY, maxY } = this.controller.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height

    // Calculate margins needed for axes
    const leftMargin = 60   // Space for Y-axis labels
    const bottomMargin = 60 // Space for X-axis labels

    // X-axis (bottom)
    const xAxisY = height - bottomMargin
    const xAxis = new this.PIXI.Graphics()
    xAxis.lineStyle(2, 0x374151) // Dark gray color
    xAxis.moveTo(leftMargin, xAxisY)
    xAxis.lineTo(width, xAxisY)
    this.axesContainer.addChild(xAxis)

    // Y-axis (left)
    const yAxisX = leftMargin
    const yAxis = new this.PIXI.Graphics()
    yAxis.lineStyle(2, 0x374151) // Dark gray color
    yAxis.moveTo(yAxisX, 0)
    yAxis.lineTo(yAxisX, height - bottomMargin)
    this.axesContainer.addChild(yAxis)

    // Add axis labels and tick marks
    this.addAxisLabels(minX, maxX, minY, maxY, width, height)
    this.addTickMarks(minX, maxX, minY, maxY, width, height)
  }

  // Add axis labels
  addAxisLabels(minX, maxX, minY, maxY, width, height) {
    const leftMargin = 60
    const bottomMargin = 60

    // X-axis label
    const xAxisLabel = new this.PIXI.Text('Dimension 1', {
      fontFamily: 'Arial, sans-serif',
      fontSize: 12,
      fill: 0x374151
    })
    xAxisLabel.x = (width / 2) + leftMargin
    xAxisLabel.y = height - 5
    xAxisLabel.anchor.set(0.5, 1)
    this.axesContainer.addChild(xAxisLabel)

    // Y-axis label
    const yAxisLabel = new this.PIXI.Text('Dimension 2', {
      fontFamily: 'Arial, sans-serif',
      fontSize: 12,
      fill: 0x374151
    })
    yAxisLabel.x = leftMargin - 15
    yAxisLabel.y = height / 2
    yAxisLabel.anchor.set(0.5, 0.5)
    yAxisLabel.rotation = -Math.PI / 2
    this.axesContainer.addChild(yAxisLabel)
  }

  // Add tick marks and values
  addTickMarks(minX, maxX, minY, maxY, width, height) {
    const leftMargin = 60
    const bottomMargin = 60

    // Calculate tick spacing
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)

    // X-axis ticks
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let x = xStart; x <= xEnd; x += xTickSpacing) {
      const screenX = leftMargin + ((x - minX) / (maxX - minX)) * (width - leftMargin)
      const xAxisY = height - bottomMargin

      // Tick mark
      const tick = new this.PIXI.Graphics()
      tick.lineStyle(1, 0x374151)
      tick.moveTo(screenX, xAxisY - 5)
      tick.lineTo(screenX, xAxisY + 5)
      this.axesContainer.addChild(tick)

      // Tick value
      const tickValue = new this.PIXI.Text(this.formatTickValue(x), {
        fontFamily: 'Arial, sans-serif',
        fontSize: 10,
        fill: 0x6b7280
      })
      tickValue.x = screenX
      tickValue.y = xAxisY + 15
      tickValue.anchor.set(0.5, 0)
      this.axesContainer.addChild(tickValue)
    }

    // Y-axis ticks
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let y = yStart; y <= yEnd; y += yTickSpacing) {
      const screenY = ((y - minY) / (maxY - minY)) * (height - bottomMargin)
      const yAxisX = leftMargin

      // Tick mark
      const tick = new this.PIXI.Graphics()
      tick.lineStyle(1, 0x374151)
      tick.moveTo(yAxisX - 5, screenY)
      tick.lineTo(yAxisX + 5, screenY)
      this.axesContainer.addChild(tick)

      // Tick value
      const tickValue = new this.PIXI.Text(this.formatTickValue(y), {
        fontFamily: 'Arial, sans-serif',
        fontSize: 10,
        fill: 0x6b7280
      })
      tickValue.x = yAxisX - 10
      tickValue.y = screenY + 3
      tickValue.anchor.set(1, 0.5)
      this.axesContainer.addChild(tickValue)
    }
  }

  // Calculate tick spacing for nice round numbers
  calculateTickSpacing(range) {
    const roughTickCount = 5
    const roughSpacing = range / roughTickCount
    
    // Find the order of magnitude
    const magnitude = Math.pow(10, Math.floor(Math.log10(roughSpacing)))
    
    // Normalize to 1-10 range
    const normalized = roughSpacing / magnitude
    
    // Choose nice spacing
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

  // Format tick values to remove unnecessary decimals
  formatTickValue(value) {
    // If it's an integer, don't show decimals
    if (Number.isInteger(value)) {
      return value.toString()
    }
    
    // Otherwise, show up to 2 decimal places, removing trailing zeros
    return parseFloat(value.toFixed(2)).toString()
  }

  // Render grid
  renderGrid() {
    if (!this.gridContainer || !this.controller.currentBounds || !this.pixiApp) {
      return
    }

    // Clear existing grid
    this.gridContainer.removeChildren()

    if (!this.gridContainer.visible) {
      return
    }

    const { minX, maxX, minY, maxY } = this.controller.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height

    // Calculate margins needed for axes
    const leftMargin = 60   // Space for Y-axis labels
    const bottomMargin = 60 // Space for X-axis labels

    // Calculate tick spacing
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)

    // Vertical grid lines
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let x = xStart; x <= xEnd; x += xTickSpacing) {
      const screenX = leftMargin + ((x - minX) / (maxX - minX)) * (width - leftMargin)
      
      const gridLine = new this.PIXI.Graphics()
      gridLine.lineStyle(1, 0xe5e7eb, 0.6) // Light gray with transparency
      gridLine.setLineDash([2, 2]) // Dotted line
      gridLine.moveTo(screenX, 0)
      gridLine.lineTo(screenX, height - bottomMargin)
      this.gridContainer.addChild(gridLine)
    }

    // Horizontal grid lines
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let y = yStart; y <= yEnd; y += yTickSpacing) {
      const screenY = ((y - minY) / (maxY - minY)) * (height - bottomMargin)
      
      const gridLine = new this.PIXI.Graphics()
      gridLine.lineStyle(1, 0xe5e7eb, 0.6) // Light gray with transparency
      gridLine.setLineDash([2, 2]) // Dotted line
      gridLine.moveTo(leftMargin, screenY)
      gridLine.lineTo(width, screenY)
      this.gridContainer.addChild(gridLine)
    }
  }

  // Render category labels
  renderCategoryLabels() {
    if (!this.categoryLabelsContainer || !this.controller.currentBounds || !this.pixiApp || !this.controller.currentMetadataVector || !this.controller.currentCoordinates) {
      return
    }

    // Only render labels for discrete metadata
    if (this.controller.currentMetadataVector.data_type !== 'DISCRETE') {
      return
    }

    // Clear existing labels
    this.categoryLabelsContainer.removeChildren()

    const { minX, maxX, minY, maxY } = this.controller.currentBounds
    const width = this.pixiApp.screen.width
    const height = this.pixiApp.screen.height

    // Get the metadata values and categories
    const values = this.controller.currentMetadataVector.values
    const categories = this.controller.currentMetadataVector.categories
    
    // If categories is undefined, try to get unique values from the values array
    let categoryList = categories
    if (!categoryList || categoryList.length === 0) {
      categoryList = [...new Set(values)]
    }

    // Calculate centroids from currently visible points in the current view
    const centroids = this.calculateCategoryCentroids(values, categoryList)

    // Render labels for each category
    let labelsAdded = 0
    Object.entries(centroids).forEach(([category, centroid]) => {
      if (centroid.count > 0) { // Only show labels for categories with points
        const screenX = this.normalizeX(centroid.x, this.controller.currentBounds)
        const screenY = this.normalizeY(centroid.y, this.controller.currentBounds)

        // Skip if outside visible area (with some margin)
        const margin = 50
        if (screenX < -margin || screenX > width + margin || screenY < -margin || screenY > height + margin) {
          return
        }

        // Create label with background
        const label = this.createCategoryLabel(category, centroid.count)
        label.x = screenX
        label.y = screenY
        this.categoryLabelsContainer.addChild(label)
        labelsAdded++
      }
    })

    //console.log(`Total labels added: ${labelsAdded}`)
  }

  // Calculate centroids for each category
  calculateCategoryCentroids(values, categories) {
    if (!categories || !Array.isArray(categories)) {
      return {}
    }
    
    const centroids = {}
    
    // Initialize centroids
    categories.forEach(category => {
      centroids[category] = { x: 0, y: 0, count: 0 }
    })

    // Calculate centroids from actual visible points in the scatter container
    if (this.scatterContainer && this.scatterContainer.children) {
      this.scatterContainer.children.forEach((point) => {
        if (point.isPoint && point.visible && point.cellId !== undefined) {
          const category = values[point.cellId]
          if (centroids[category]) {
            // Convert screen coordinates back to data coordinates for centroid calculation
            const dataX = this.controller.currentBounds.minX + (point.x / this.pixiApp.screen.width) * (this.controller.currentBounds.maxX - this.controller.currentBounds.minX)
            const dataY = this.controller.currentBounds.minY + (point.y / this.pixiApp.screen.height) * (this.controller.currentBounds.maxY - this.controller.currentBounds.minY)
            
            centroids[category].x += dataX
            centroids[category].y += dataY
            centroids[category].count += 1
          }
        }
      })
    }

    // Calculate average coordinates (centroids)
    Object.keys(centroids).forEach(category => {
      if (centroids[category].count > 0) {
        centroids[category].x /= centroids[category].count
        centroids[category].y /= centroids[category].count
      }
    })

    return centroids
  }

  // Create a category label with background
  createCategoryLabel(categoryName, count) {
    const container = new this.PIXI.Container()

    // Create background rectangle
    const background = new this.PIXI.Graphics()
    
    // Get category color for border
    const categoryIndex = this.controller.currentMetadataVector.categories.indexOf(categoryName)
    const borderColor = this.controller.getCategoryColor(categoryName, categoryIndex, this.controller.currentMetadataVector.name)
    const borderColorNumber = this.convertHexToPixiColor(borderColor)
    
    // Create text
    const text = new this.PIXI.Text(categoryName, {
      fontFamily: 'Arial, sans-serif',
      fontSize: 12,
      fill: 0x374151,
      fontWeight: 'bold'
    })

    // Calculate background size with padding
    const padding = 4
    const bgWidth = text.width + (padding * 2)
    const bgHeight = text.height + (padding * 2)

    // Draw background with border
    background.lineStyle(1, borderColorNumber)
    background.beginFill(0xffffff, 0.9) // White background with slight transparency
    background.drawRoundedRect(-bgWidth / 2, -bgHeight / 2, bgWidth, bgHeight, 4)
    background.endFill()

    // Center text
    text.anchor.set(0.5, 0.5)

    // Add to container
    container.addChild(background)
    container.addChild(text)

    // Make draggable if in pick mode
    if (this.controller.interactionMode === 'pick') {
      container.interactive = true
      container.buttonMode = true
      container.cursor = 'move'

      // Add hover effects
      container.on('pointerover', () => {
        container.scale.set(1.1)
      })
      container.on('pointerout', () => {
        container.scale.set(1.0)
      })

      // Add drag functionality
      container.on('pointerdown', (event) => {
        this.controller.draggingLabel = container
        container.alpha = 0.7
      })
    }

    // Store border color for reference
    container.borderColor = borderColor

    return container
  }

  // Convert hex color to PIXI color number
  convertHexToPixiColor(hexColor) {
    if (!hexColor || hexColor === 'undefined') return 0xcccccc
    return parseInt(hexColor.replace('#', ''), 16)
  }

  // Normalize X coordinate to screen space
  normalizeX(x, bounds) {
    return ((x - bounds.minX) / (bounds.maxX - bounds.minX)) * this.pixiApp.screen.width
  }

  // Normalize Y coordinate to screen space
  normalizeY(y, bounds) {
    return ((y - bounds.minY) / (bounds.maxY - bounds.minY)) * this.pixiApp.screen.height
  }

  // Update all point sizes
  updateAllPointSizes(newSize) {
    if (!this.scatterContainer || !this.scatterContainer.children) {
      return
    }

    this.scatterContainer.children.forEach((point) => {
      if (point.isPoint) {
        this.updatePointSize(point, newSize)
      }
    })
  }

  // Update a single point's size
  updatePointSize(point, newSize) {
    if (!point || !point.isPoint) return

    // Store the current position and properties
    const currentX = point.x
    const currentY = point.y
    const currentAlpha = point.alpha || 1.0

    // Get the current color from the current coloring scheme
    let currentColor = 0x3b82f6 // Default blue fallback

    if (point.cellId !== undefined) {
      // Use the current coloring scheme to get the correct color
      const { color } = this.controller.getColorAndAlpha(point.cellId)
      currentColor = color
    }

    // Clear and redraw the circle with new size
    point.clear()
    point.beginFill(currentColor)
    point.alpha = currentAlpha
    point.drawCircle(0, 0, newSize)
    point.endFill()

    // Restore position
    point.x = currentX
    point.y = currentY
  }

  // Update point positions for pan/zoom
  updatePointPositions() {
    if (!this.controller.currentCoordinates || !this.controller.currentBounds || !this.scatterContainer) {
      return
    }

    this.scatterContainer.children.forEach((point) => {
      if (point.isPoint && point.cellId !== undefined) {
        const [x, y] = this.controller.currentCoordinates[point.cellId]
        point.x = this.normalizeX(x, this.controller.currentBounds)
        point.y = this.normalizeY(y, this.controller.currentBounds)
      }
    })
  }

  // Update visualization bounds
  updateVisualizationBounds(newBounds) {
    this.controller.currentBounds = newBounds
    
    // Update axes, grid, and category labels with new bounds
    this.renderAxes()
    this.renderGrid()
    this.renderCategoryLabels()
  }

  // Cleanup method
  destroy() {
    if (this.pixiApp) {
      this.pixiApp.destroy(true)
      this.pixiApp = null
    }
    this.scatterContainer = null
    this.axesContainer = null
    this.gridContainer = null
    this.categoryLabelsContainer = null
    this.animatedContainer = null
  }
}
