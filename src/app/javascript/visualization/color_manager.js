// Color Management Module for Visualization
// Handles all color-related operations including customization and caching

export class ColorManager {
  constructor(controller) {
    this.controller = controller
    this._cachedCategoryColors = null
    this._cachedColorMap = null
    this._cachedCentroids = null
    this._cachedCentroidsKey = null
  }

  // Get category colors with caching
  getCategoryColors() {
    if (this._cachedCategoryColors) {
      return this._cachedCategoryColors
    }

    if (window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0) {
      this._cachedCategoryColors = window.CATEGORY_COLORS.map(color => {
        // Convert hex to PIXI color number
        return parseInt(color.replace('#', ''), 16)
      })
      return this._cachedCategoryColors
    }

    // Fallback colors if global colors are not available
    const fallbackColors = [
      0x1f77b4, 0xff7f0e, 0x2ca02c, 0x9467bd, 0x8c564b,
      0xe377c2, 0x7f7f7f, 0xbcbd22, 0x17becf, 0x4ecdc4,
      0x45b7d1, 0x96ceb4, 0xfeca57, 0xff9ff3, 0xff6b6b
    ]
    
    this._cachedCategoryColors = fallbackColors
    return this._cachedCategoryColors
  }

  // Get color and alpha for a point with caching
  getColorAndAlpha(pointIndex) {
    if (this._cachedColorMap && this._cachedColorMap.has(pointIndex)) {
      return this._cachedColorMap.get(pointIndex)
    }

    // If no metadata coloring is active, return default blue
    if (!this.controller.currentMetadataVector || !this.controller.currentMetadataVector.values) {
      return { color: 0x3b82f6, alpha: 1.0 }
    }

    const { data_type, values, compression_info } = this.controller.currentMetadataVector
    let color, alpha

    if (data_type === 'DISCRETE') {
      const category = values[pointIndex]
      const categories = this.controller.currentMetadataVector.categories
      const categoryIndex = categories.indexOf(category)
      
      color = this.getCategoryColor(category, categoryIndex, this.controller.currentMetadataVector.name)
      alpha = 1.0
    } else if (data_type === 'CONTINUOUS') {
      const normalizedValue = this.normalizeContinuousValue(values[pointIndex], compression_info)
      color = this.valueToColor(normalizedValue)
      alpha = 1.0
    } else {
      color = 0x3b82f6
      alpha = 1.0
    }

    // Cache the result
    if (!this._cachedColorMap) {
      this._cachedColorMap = new Map()
    }
    this._cachedColorMap.set(pointIndex, { color, alpha })

    return { color, alpha }
  }

  // Get point color (simplified version)
  getPointColor(pointIndex) {
    const { color } = this.getColorAndAlpha(pointIndex)
    return color
  }

  // Clear category colors cache
  clearCategoryColorsCache() {
    this._cachedCategoryColors = null
  }

  // Clear color map cache
  clearColorMapCache() {
    this._cachedColorMap = null
    this._cachedCentroids = null
    this._cachedCentroidsKey = null
  }

  // Normalize continuous value to 0-1 range
  normalizeContinuousValue(value, compressionInfo) {
    if (!compressionInfo || compressionInfo.min === undefined || compressionInfo.max === undefined) {
      return 0.5 // Default to middle if no compression info
    }
    
    const { min, max } = compressionInfo
    if (max === min) return 0.5 // Avoid division by zero
    
    return Math.max(0, Math.min(1, (value - min) / (max - min)))
  }

  // Convert normalized value to color
  valueToColor(normalizedValue) {
    // Use a color scale from blue (low) to red (high)
    const colors = this.getCategoryColors()
    
    // Map normalized value to color index
    const colorIndex = Math.floor(normalizedValue * (colors.length - 1))
    return colors[colorIndex]
  }

  // Get category color with customization support
  getCategoryColor(categoryName, index, metadataId) {
    // Check for custom color in localStorage
    const customColorKey = `custom_color_${metadataId}_${categoryName}`
    const customColor = localStorage.getItem(customColorKey)
    
    if (customColor && customColor !== 'undefined') {
      return parseInt(customColor.replace('#', ''), 16)
    }
    
    // Use default color from palette
    const colors = this.getCategoryColors()
    return colors[index % colors.length]
  }

  // Get default category color (ignoring localStorage)
  getDefaultCategoryColor(categoryName, index) {
    // Use the same color palette as the plot
    if (window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0) {
      const color = window.CATEGORY_COLORS[index % window.CATEGORY_COLORS.length]
      return parseInt(color.replace('#', ''), 16)
    }
    
    // Fallback to default colors if global colors are not available
    const defaultColors = [
      0x1f77b4, 0xff7f0e, 0x2ca02c, 0x9467bd, 0x8c564b,
      0xe377c2, 0x7f7f7f, 0xbcbd22, 0x17becf, 0x4ecdc4,
      0x45b7d1, 0x96ceb4, 0xfeca57, 0xff9ff3, 0xff6b6b
    ]
    
    return defaultColors[index % defaultColors.length]
  }

  // Check if metadata has customized colors
  hasCustomizedColors(metadataId) {
    const keys = Object.keys(localStorage)
    return keys.some(key => key.startsWith(`custom_color_${metadataId}_`))
  }

  // Clear stored colors for a metadata
  clearStoredColors(metadataId) {
    const keys = Object.keys(localStorage)
    keys.forEach(key => {
      if (key.startsWith(`custom_color_${metadataId}_`)) {
        localStorage.removeItem(key)
      }
    })
  }

  // Show color picker for category customization
  showColorPicker(colorDisk, categoryName, metadataId) {
    // Check if there's already a picker open for this category/metadata
    const existingPicker = document.querySelector('.color-picker')
    if (existingPicker) {
      const existingCategory = existingPicker.dataset.category
      const existingMetadata = existingPicker.dataset.metadata
      
      if (existingCategory === categoryName && existingMetadata === metadataId) {
        // Same picker, remove it (toggle behavior)
        existingPicker.remove()
        return
      } else {
        // Different picker, remove the old one
        existingPicker.remove()
      }
    }

    // Get current color
    const currentColor = colorDisk.style.backgroundColor || '#1f77b4'
    
    // Create color picker
    const picker = document.createElement('div')
    picker.className = 'color-picker'
    picker.style.cssText = `
      position: absolute;
      background: white;
      border: 1px solid #ccc;
      border-radius: 4px;
      padding: 10px;
      box-shadow: 0 2px 10px rgba(0,0,0,0.1);
      z-index: 1000;
    `
    picker.dataset.category = categoryName
    picker.dataset.metadata = metadataId

    // Create color input
    const colorInput = document.createElement('input')
    colorInput.type = 'color'
    colorInput.value = currentColor
    colorInput.style.cssText = 'width: 40px; height: 30px; border: none; cursor: pointer;'

    // Create save button
    const saveButton = document.createElement('button')
    saveButton.textContent = 'Save'
    saveButton.style.cssText = `
      margin-left: 10px;
      padding: 5px 10px;
      background: #007bff;
      color: white;
      border: none;
      border-radius: 3px;
      cursor: pointer;
    `

    // Create cancel button
    const cancelButton = document.createElement('button')
    cancelButton.textContent = 'Cancel'
    cancelButton.style.cssText = `
      margin-left: 5px;
      padding: 5px 10px;
      background: #6c757d;
      color: white;
      border: none;
      border-radius: 3px;
      cursor: pointer;
    `

    // Position picker
    const rect = colorDisk.getBoundingClientRect()
    picker.style.left = rect.left + 'px'
    picker.style.top = (rect.bottom + 5) + 'px'

    // Add elements to picker
    picker.appendChild(colorInput)
    picker.appendChild(saveButton)
    picker.appendChild(cancelButton)

    // Add to document
    document.body.appendChild(picker)

    // Event handlers
    cancelButton.addEventListener('click', () => {
      picker.remove()
    })

    saveButton.addEventListener('click', () => {
      const newColor = colorInput.value
      
      // Store custom color
      const customColorKey = `custom_color_${metadataId}_${categoryName}`
      localStorage.setItem(customColorKey, newColor)
      
      // Clear color cache to force re-rendering
      this.clearColorMapCache()
      
      // Re-render plot if this is the active metadata
      if (this.controller.currentMetadataId === metadataId) {
        this.controller.renderPointsWithCurrentColoring()
        this.controller.updateLegendColors(metadataId)
        
        // Re-render category labels if they are visible
        if (this.controller.categoryLabelsContainer && this.controller.categoryLabelsContainer.visible) {
          this.controller.renderCategoryLabels()
        }
      }
      
      // Add reset button if it doesn't exist (first customization)
      const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
      if (metadataContainer) {
        this.controller.addResetColorsButton(metadataContainer, metadataId)
      }
      
      // Close the picker
      picker.remove()
    })

    // Close on outside click
    setTimeout(() => {
      document.addEventListener('click', function closePicker(e) {
        if (!picker.contains(e.target)) {
          picker.remove()
          document.removeEventListener('click', closePicker)
        }
      })
    }, 100)
  }

  // Reset colors for a metadata
  resetColorsForMetadata(metadataId) {
    // Clear stored colors
    this.clearStoredColors(metadataId)
    
    // Clear color cache
    this.clearColorMapCache()
    
    // Re-render plot if this is the active metadata
    if (this.controller.currentMetadataId === metadataId) {
      this.controller.renderPointsWithCurrentColoring()
      this.controller.updateLegendColors(metadataId)
      
      // Re-render category labels if they are visible
      if (this.controller.categoryLabelsContainer && this.controller.categoryLabelsContainer.visible) {
        this.controller.renderCategoryLabels()
      }
    }
    
    // Remove reset button
    this.controller.removeResetColorsButton(metadataId)
  }

  // Update legend colors
  updateLegendColors(metadataId) {
    const metadataContainer = document.querySelector(`[data-metadata-item="${metadataId}"]`)
    if (!metadataContainer) return

    const colorDisks = metadataContainer.querySelectorAll('.category-color-disk')
    colorDisks.forEach((disk, index) => {
      const categoryName = disk.dataset.category
      const defaultColor = this.getDefaultCategoryColor(categoryName, index)
      const hexColor = '#' + defaultColor.toString(16).padStart(6, '0')
      disk.style.backgroundColor = hexColor
    })
  }

  // Convert hex to RGB
  hexToRgb(hex) {
    if (!hex || hex === 'undefined') return { r: 204, g: 204, b: 204 }
    
    const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex)
    return result ? {
      r: parseInt(result[1], 16),
      g: parseInt(result[2], 16),
      b: parseInt(result[3], 16)
    } : { r: 204, g: 204, b: 204 }
  }

  // Get point color and size for SVG export
  getPointColorAndSize(point) {
    let color = '#3b82f6' // Default blue
    let size = this.controller.currentPointSize || 1

    if (point.cellId !== undefined) {
      const { color: pointColor } = this.getColorAndAlpha(point.cellId)
      color = '#' + pointColor.toString(16).padStart(6, '0')
    }

    return { color, size }
  }

  // Store original point color for reset functionality
  storeOriginalPointColor(cellId, color) {
    if (!this.controller.originalPointColors) {
      this.controller.originalPointColors = new Map()
    }
    this.controller.originalPointColors.set(cellId, color)
  }
}
