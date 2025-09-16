// UI Manager Module for Visualization
// Handles UI elements, tooltips, settings windows, and other interface components

export class UIManager {
  constructor(controller) {
    this.controller = controller
    this.tooltip = null
    this.settingsWindow = null
    this.isDraggingSettings = false
    this.dragOffset = { x: 0, y: 0 }
  }

  // Initialize tooltip
  initializeTooltip() {
    // Create tooltip element
    this.tooltip = document.createElement('div')
    this.tooltip.id = 'visualization-tooltip'
    this.tooltip.style.cssText = `
      position: absolute;
      background: rgba(0, 0, 0, 0.8);
      color: white;
      padding: 8px 12px;
      border-radius: 4px;
      font-size: 12px;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      pointer-events: none;
      z-index: 1000;
      display: none;
      max-width: 300px;
      word-wrap: break-word;
    `
    document.body.appendChild(this.tooltip)
  }

  // Create tooltip dynamically
  createTooltipDynamically() {
    if (this.tooltip) {
      this.tooltip.remove()
    }
    this.initializeTooltip()
  }

  // Show tooltip
  showTooltip(cellId, point) {
    if (!this.tooltip) {
      this.createTooltipDynamically()
    }

    // Get cell information
    const cellName = `Cell ${cellId + 1}`
    let categoryInfo = ''

    // Add metadata information if available
    if (this.controller.currentMetadataVector) {
      const { data_type, values, categories } = this.controller.currentMetadataVector
      
      if (data_type === 'DISCRETE' && values && values[cellId] !== undefined) {
        const category = values[cellId]
        categoryInfo = `Category: ${category}`
      } else if (data_type === 'CONTINUOUS' && values && values[cellId] !== undefined) {
        const value = values[cellId]
        categoryInfo = `Value: ${value.toFixed(3)}`
      }
    }

    // Show tooltip
    this.showSimpleTooltip(cellName, categoryInfo, point)
  }

  // Show simple tooltip
  showSimpleTooltip(cellName, categoryInfo, point) {
    if (!this.tooltip) return

    // Build tooltip content
    let content = `<strong>${cellName}</strong>`
    if (categoryInfo) {
      content += `<br>${categoryInfo}`
    }

    // Add selection status
    if (this.controller.selectedCells && this.controller.selectedCells.has(point.cellId)) {
      content += '<br><em>Selected</em>'
    }

    this.tooltip.innerHTML = content

    // Position tooltip
    const canvas = this.controller.canvas || (this.controller.pixiApp && this.controller.pixiApp.canvas)
    if (!canvas) return

    const rect = canvas.getBoundingClientRect()
    const tooltipX = rect.left + point.x
    const tooltipY = rect.top + point.y - 10

    this.tooltip.style.left = tooltipX + 'px'
    this.tooltip.style.top = tooltipY + 'px'
    this.tooltip.style.display = 'block'
  }

  // Hide tooltip
  hideTooltip() {
    if (this.tooltip) {
      this.tooltip.style.display = 'none'
    }
  }

  // Toggle settings window
  toggleSettingsWindow() {
    const settingsWindow = document.getElementById('settings-window')
    if (!settingsWindow) return

    if (settingsWindow.style.display === 'none' || !settingsWindow.style.display) {
      settingsWindow.style.display = 'block'
      this.initializeSettingsWindow()
    } else {
      settingsWindow.style.display = 'none'
    }
  }

  // Initialize settings window
  initializeSettingsWindow() {
    const settingsWindow = document.getElementById('settings-window')
    if (!settingsWindow) return

    // Initialize slider
    const slider = document.getElementById('point-size-slider')
    const valueDisplay = document.getElementById('point-size-value')
    if (slider && valueDisplay) {
      slider.value = this.controller.currentPointSize
      valueDisplay.textContent = this.controller.currentPointSize.toFixed(1)
    }

    // Initialize checkboxes
    const axesCheckbox = document.getElementById('show-axes-checkbox')
    const gridCheckbox = document.getElementById('show-grid-checkbox')
    const categoriesCheckbox = document.getElementById('show-categories-checkbox')

    if (axesCheckbox) {
      axesCheckbox.checked = this.controller.axesContainer ? this.controller.axesContainer.visible : true
    }
    if (gridCheckbox) {
      gridCheckbox.checked = this.controller.gridContainer ? this.controller.gridContainer.visible : true
    }
    if (categoriesCheckbox) {
      categoriesCheckbox.checked = this.controller.categoryLabelsContainer ? this.controller.categoryLabelsContainer.visible : true
    }

    // Make window draggable
    this.makeSettingsWindowDraggable()
  }

  // Make settings window draggable
  makeSettingsWindowDraggable() {
    const settingsWindow = document.getElementById('settings-window')
    const header = document.getElementById('settings-header')
    if (!settingsWindow || !header) return

    header.addEventListener('mousedown', (e) => {
      this.isDraggingSettings = true
      const rect = settingsWindow.getBoundingClientRect()
      this.dragOffset.x = e.clientX - rect.left
      this.dragOffset.y = e.clientY - rect.top
      header.style.cursor = 'grabbing'
    })

    document.addEventListener('mousemove', (e) => {
      if (this.isDraggingSettings) {
        const x = e.clientX - this.dragOffset.x
        const y = e.clientY - this.dragOffset.y
        settingsWindow.style.left = x + 'px'
        settingsWindow.style.top = y + 'px'
        settingsWindow.style.right = 'auto'
      }
    })

    document.addEventListener('mouseup', () => {
      if (this.isDraggingSettings) {
        this.isDraggingSettings = false
        header.style.cursor = 'move'
      }
    })

    // Close button
    const closeBtn = document.getElementById('close-settings-btn')
    if (closeBtn) {
      closeBtn.addEventListener('click', () => {
        settingsWindow.style.display = 'none'
      })
    }
  }

  // Update point size
  updatePointSize() {
    const slider = document.getElementById('point-size-slider')
    const valueDisplay = document.getElementById('point-size-value')
    
    if (!slider || !valueDisplay) return

    const newSize = parseFloat(slider.value)
    this.controller.currentPointSize = newSize
    valueDisplay.textContent = newSize.toFixed(1)

    // Update all point sizes
    this.controller.updateAllPointSizes(newSize)
  }

  // Toggle axes
  toggleAxes() {
    const checkbox = document.getElementById('show-axes-checkbox')
    if (!checkbox || !this.controller.axesContainer) return

    const previousVisibility = this.controller.axesContainer.visible
    this.controller.axesContainer.visible = checkbox.checked

    if (checkbox.checked !== previousVisibility) {
      // Recalculate bounds when toggling axes
      const originalBounds = this.controller.calculateBounds(this.controller.currentCoordinates)
      const newBounds = this.controller.getAdjustedBounds(originalBounds)
      this.controller.currentBounds = newBounds

      // Restore the previous visibility state
      this.controller.axesContainer.visible = previousVisibility

      // Re-render points with new bounds
      this.controller.scatterContainer.removeChildren()
      this.controller.renderPointsWithCurrentColoring()

      // Now set the final axes visibility
      this.controller.axesContainer.visible = checkbox.checked

      // Re-render axes
      this.controller.renderAxes()
    }
  }

  // Toggle grid
  toggleGrid() {
    const checkbox = document.getElementById('show-grid-checkbox')
    if (!checkbox || !this.controller.gridContainer) return

    this.controller.gridContainer.visible = checkbox.checked
    this.controller.renderGrid()
  }

  // Toggle categories
  toggleCategories() {
    const checkbox = document.getElementById('show-categories-checkbox')
    if (!checkbox || !this.controller.categoryLabelsContainer) return

    this.controller.categoryLabelsContainer.visible = checkbox.checked
    this.controller.renderCategoryLabels()
  }

  // Update categories checkbox state
  updateCategoriesCheckboxState() {
    const checkbox = document.getElementById('show-categories-checkbox')
    if (!checkbox) return

    // Check if current metadata is discrete
    const isDiscreteMetadata = this.controller.currentMetadataVector && this.controller.currentMetadataVector.data_type === 'DISCRETE'

    if (isDiscreteMetadata) {
      checkbox.disabled = false
      checkbox.checked = this.controller.categoryLabelsContainer ? this.controller.categoryLabelsContainer.visible : true
    } else {
      checkbox.disabled = true
      checkbox.checked = false
    }
  }

  // Save selection
  saveSelection() {
    if (!this.controller.selectedCells || this.controller.selectedCells.size === 0) {
      alert('No cells selected')
      return
    }

    const selectedArray = Array.from(this.controller.selectedCells)
    const selectionData = {
      selected_cells: selectedArray,
      total_cells: this.controller.currentCoordinates ? this.controller.currentCoordinates.length : 0
    }

    // Here you would typically send the selection to the server
    console.log('Saving selection:', selectionData)
    alert(`Selection saved: ${selectedArray.length} cells selected`)
  }

  // Save as SVG
  saveAsSVG() {
    if (!this.controller.pixiApp) {
      alert('No plot to save')
      return
    }

    const canvas = this.controller.canvas || this.controller.pixiApp.canvas
    if (!canvas) {
      alert('No canvas found')
      return
    }

    const svgContent = this.generateSVGFromPlot(canvas)
    this.downloadSVG(svgContent, 'visualization.svg')
  }

  // Generate SVG from plot
  generateSVGFromPlot(canvas) {
    const width = this.controller.pixiApp.screen.width
    const height = this.controller.pixiApp.screen.height

    let svg = `<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">`

    // Add grid if visible
    if (this.controller.gridContainer && this.controller.gridContainer.visible) {
      svg += this.generateSVGGrid(width, height)
    }

    // Add axes if visible
    if (this.controller.axesContainer && this.controller.axesContainer.visible) {
      svg += this.generateSVGAxes(width, height)
    }

    // Add points
    svg += this.generateSVGPoints(width, height)

    // Add category labels if visible
    if (this.controller.categoryLabelsContainer && this.controller.categoryLabelsContainer.visible) {
      svg += this.generateSVGCategoryLabels()
    }

    svg += '</svg>'
    return svg
  }

  // Generate SVG for points
  generateSVGPoints(width, height) {
    let svg = ''
    
    if (this.controller.scatterContainer && this.controller.scatterContainer.children) {
      this.controller.scatterContainer.children.forEach(point => {
        if (point.isPoint && point.visible) {
          const { color, size } = this.controller.getPointColorAndSize(point)
          svg += `<circle cx="${point.x}" cy="${point.y}" r="${size}" fill="${color}" opacity="0.8"/>`
        }
      })
    }
    
    return svg
  }

  // Generate SVG for grid
  generateSVGGrid(width, height) {
    if (!this.controller.currentBounds) return ''

    let svg = ''
    const { minX, maxX, minY, maxY } = this.controller.currentBounds

    // Use the same coordinate system as the actual plot
    const plotWidth = this.controller.pixiApp.screen.width
    const plotHeight = this.controller.pixiApp.screen.height

    // Use the same margins as axes
    const leftMargin = 80
    const bottomMargin = 40

    // Calculate tick spacing for each axis
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)

    // Vertical grid lines
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let x = xStart; x <= xEnd; x += xTickSpacing) {
      const screenX = leftMargin + ((x - minX) / (maxX - minX)) * (plotWidth - leftMargin)
      svg += `<line x1="${screenX}" y1="0" x2="${screenX}" y2="${plotHeight - bottomMargin}" stroke="#e5e7eb" stroke-width="1" stroke-dasharray="2,2" opacity="0.6"/>`
    }

    // Horizontal grid lines
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let y = yStart; y <= yEnd; y += yTickSpacing) {
      const screenY = ((y - minY) / (maxY - minY)) * (plotHeight - bottomMargin)
      svg += `<line x1="${leftMargin}" y1="${screenY}" x2="${plotWidth}" y2="${screenY}" stroke="#e5e7eb" stroke-width="1" stroke-dasharray="2,2" opacity="0.6"/>`
    }

    return svg
  }

  // Generate SVG for axes
  generateSVGAxes(width, height) {
    if (!this.controller.currentBounds) return ''

    let svg = ''
    const { minX, maxX, minY, maxY } = this.controller.currentBounds

    // Use the same coordinate system as the actual plot
    const plotWidth = this.controller.pixiApp.screen.width
    const plotHeight = this.controller.pixiApp.screen.height

    // Add more left margin for Y-axis labels
    const leftMargin = 80
    const bottomMargin = 40

    // X-axis (bottom)
    const xAxisY = plotHeight - bottomMargin
    svg += `<line x1="${leftMargin}" y1="${xAxisY}" x2="${plotWidth}" y2="${xAxisY}" stroke="#374151" stroke-width="2"/>`

    // Y-axis (left)
    const yAxisX = leftMargin
    svg += `<line x1="${yAxisX}" y1="0" x2="${yAxisX}" y2="${plotHeight - bottomMargin}" stroke="#374151" stroke-width="2"/>`

    // Axis labels
    svg += `<text x="${(plotWidth/2) + leftMargin}" y="${plotHeight - 5}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#374151">Dimension 1</text>`
    svg += `<text x="${leftMargin - 15}" y="${plotHeight/2}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#374151" transform="rotate(-90, ${leftMargin - 15}, ${plotHeight/2})">Dimension 2</text>`

    // Tick marks and values
    const xRange = maxX - minX
    const yRange = maxY - minY
    const xTickSpacing = this.calculateTickSpacing(xRange)
    const yTickSpacing = this.calculateTickSpacing(yRange)

    // X-axis ticks
    const xStart = Math.ceil(minX / xTickSpacing) * xTickSpacing
    const xEnd = Math.floor(maxX / xTickSpacing) * xTickSpacing
    for (let x = xStart; x <= xEnd; x += xTickSpacing) {
      const screenX = leftMargin + ((x - minX) / (maxX - minX)) * (plotWidth - leftMargin)
      svg += `<line x1="${screenX}" y1="${xAxisY - 5}" x2="${screenX}" y2="${xAxisY + 5}" stroke="#374151" stroke-width="1"/>`
      svg += `<text x="${screenX}" y="${xAxisY + 15}" text-anchor="middle" font-family="Arial, sans-serif" font-size="10" fill="#6b7280">${this.formatTickValue(x)}</text>`
    }

    // Y-axis ticks
    const yStart = Math.ceil(minY / yTickSpacing) * yTickSpacing
    const yEnd = Math.floor(maxY / yTickSpacing) * yTickSpacing
    for (let y = yStart; y <= yEnd; y += yTickSpacing) {
      const screenY = ((y - minY) / (maxY - minY)) * (plotHeight - bottomMargin)
      svg += `<line x1="${yAxisX - 5}" y1="${screenY}" x2="${yAxisX + 5}" y2="${screenY}" stroke="#374151" stroke-width="1"/>`
      svg += `<text x="${yAxisX - 10}" y="${screenY + 3}" text-anchor="end" font-family="Arial, sans-serif" font-size="10" fill="#6b7280">${this.formatTickValue(y)}</text>`
    }

    return svg
  }

  // Generate SVG for category labels
  generateSVGCategoryLabels() {
    let svg = ''
    
    if (this.controller.categoryLabelsContainer && this.controller.categoryLabelsContainer.children) {
      this.controller.categoryLabelsContainer.children.forEach(label => {
        if (label.visible) {
          const text = label.children[1] // Text is the second child
          if (text && text.text) {
            const bgWidth = text.width + 8
            const bgHeight = text.height + 8
            const borderColor = label.borderColor || '#cccccc'
            
            svg += `<rect x="${label.x - bgWidth/2}" y="${label.y - bgHeight/2}" width="${bgWidth}" height="${bgHeight}" fill="white" fill-opacity="0.9" stroke="${borderColor}" stroke-width="1" rx="4"/>`
            svg += `<text x="${label.x}" y="${label.y + 4}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" font-weight="bold" fill="#374151">${text.text}</text>`
          }
        }
      })
    }
    
    return svg
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

  // Download SVG
  downloadSVG(svgContent, filename) {
    const blob = new Blob([svgContent], { type: 'image/svg+xml' })
    const url = URL.createObjectURL(blob)
    
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    
    URL.revokeObjectURL(url)
  }

  // Cleanup method
  destroy() {
    if (this.tooltip) {
      this.tooltip.remove()
      this.tooltip = null
    }
    
    if (this.settingsWindow) {
      this.settingsWindow.remove()
      this.settingsWindow = null
    }
  }
}
