/**
 * Color Manager Module
 * Handles color management and customization
 */

export class ColorManager {
  constructor(controller) {
    this.controller = controller
  }

  // Color calculation and caching
  getColorAndAlpha(pointIndex, coloringMetadataVector = null) {
    const hasSelection = this.controller.selectedCells && this.controller.selectedCells.size > 0
    const isSelected = this.controller.selectedCells && this.controller.selectedCells.has(pointIndex)
    
    // Check for selection coloring first (highest priority)
    if (isSelected) {
      return { color: 0xff0000, alpha: 1.0 } // Red for selected points
    }

    // Check for metadata coloring
    let baseColor = 0x3b82f6 // Default blue color
    
    // Find the metadata vector that is actually being used for coloring
    // This should be the one that has a visible legend/color scheme active
    // This fixes the issue where new dots appear with wrong colors when filtering constraints are relaxed
    // Allow passing in the coloring vector to avoid repeated DOM queries
    if (!coloringMetadataVector) {
      coloringMetadataVector = this.getColoringMetadataVector()
    }
    
    if (coloringMetadataVector && coloringMetadataVector.values && coloringMetadataVector.values[pointIndex] !== undefined) {
      const { data_type, values, compression_info } = coloringMetadataVector
      const value = values[pointIndex]
      
      if (data_type === 'DISCRETE') {
        // Cache the color map to avoid recalculating for every point
        if (!this.controller._cachedColorMap || this.controller._cachedColorMapMetadataId !== coloringMetadataVector.id) {
          // CRITICAL: Use ALL categories from compression_info if available (includes categories with 0 cells)
          // Otherwise fall back to unique categories from values
          // This ensures colors remain stable even when categories have 0 visible cells
          let allCategories
          if (compression_info && compression_info.categories) {
            allCategories = [...compression_info.categories]
          } else {
            allCategories = [...new Set(values.filter(v => v !== null && v !== undefined))]
          }
          
          const stableSortedCategories = this.controller.getStableSortedCategories(values, allCategories)
          
          // Create color map using stable sorted order
          const categoryColors = this.getCategoryColors()
          this.controller._cachedColorMap = {}
          stableSortedCategories.forEach((cat, idx) => {
            const colorValue = categoryColors[idx % categoryColors.length]
            const color = typeof colorValue === 'string' 
              ? parseInt(colorValue.replace('#', ''), 16)
              : colorValue
            this.controller._cachedColorMap[cat] = color
          })
          
          this.controller._cachedColorMapMetadataId = coloringMetadataVector.id
        }
        
        // _cachedColorMap is a plain object, not a Map
        baseColor = this.controller._cachedColorMap[value] || 0x3b82f6
      } else if (data_type === 'NUMERIC') {
        // For numeric data, use the continuous color mapping
        // Get effective color range (respects user-set range slider)
        const effectiveRange = this.controller.getEffectiveColorRange()
        let minVal, maxVal
        
        if (effectiveRange) {
          minVal = effectiveRange.min
          maxVal = effectiveRange.max
        } else if (compression_info) {
          minVal = compression_info.min_val
          maxVal = compression_info.max_val
        } else {
          // Fallback: use value as-is (shouldn't happen normally)
          minVal = value
          maxVal = value
        }
        
        const range = maxVal - minVal
        let normalizedValue
        if (range > 0) {
          normalizedValue = (value - minVal) / range
          // Clamp to valid range
          normalizedValue = Math.max(0, Math.min(1, normalizedValue))
        } else {
          normalizedValue = 0.5
        }
        
        // Use gradient manager to get color
        baseColor = this.controller.gradientManager.getColorFromGradient(normalizedValue)
      }
    }
    
    // Apply visibility filtering (alpha channel)
    let alpha = 1.0
    if (this.controller.currentVisibleCells && this.controller.currentVisibleCells.length > 0) {
      alpha = this.controller.currentVisibleCells.includes(pointIndex) ? 1.0 : 0.1
    }
    
    return { color: baseColor, alpha: alpha }
  }

  getColoringMetadataVector() {
    return this.controller.getColoringMetadataVector()
  }

  clearColorMapCache() {
    return this.controller.clearColorMapCache()
  }

  shouldRecalculateColors(coloringMetadataVector) {
    return this.controller.shouldRecalculateColors(coloringMetadataVector)
  }

  calculateAndCacheColors(coloringMetadataVector) {
    return this.controller.calculateAndCacheColors(coloringMetadataVector)
  }

  getPointColor(pointIndex) {
    return this.controller.getPointColor(pointIndex)
  }

  // Color updates and rendering
  updateVisualizationWithMetadataVector() {
    return this.controller.updateVisualizationWithMetadataVector()
  }

  renderPointsWithCurrentColoring() {
    return this.controller.renderPointsWithCurrentColoring()
  }

  // Color storage management
  clearStoredColors(metadataId) {
    return this.controller.clearStoredColors(metadataId)
  }

  resetColorsForMetadata(metadataId) {
    return this.controller.resetColorsForMetadata(metadataId)
  }

  // Calculate and cache colors for all points based on coloring metadata
  calculateAndCacheColors(coloringMetadataVector) {
    if (!coloringMetadataVector || !coloringMetadataVector.values) {
      // No coloring metadata, use default colors
      this.controller.cachedColorsByCellIndex = new Map()
      
      // Determine number of points from displayOrder, currentCoordinates, or renderer
      let numPoints = 0
      if (this.controller.displayOrder && this.controller.displayOrder.length > 0) {
        numPoints = this.controller.displayOrder.length
      } else if (this.controller.currentCoordinates && this.controller.currentCoordinates.length > 0) {
        numPoints = this.controller.currentCoordinates.length
      } else if (this.controller.reglRenderer && this.controller.reglRenderer.numPoints > 0) {
        numPoints = this.controller.reglRenderer.numPoints
      }
      
      if (numPoints > 0) {
        for (let i = 0; i < numPoints; i++) {
          this.controller.cachedColorsByCellIndex.set(i, 0x3b82f6) // Default blue
        }
      }
      
      this.controller.lastColoringMetadataId = null
      this.controller.lastColorRange = null
      return
    }
    
    console.log(`🎨 [CACHE] Calculating colors for ${coloringMetadataVector.values.length} points`)
    const startTime = performance.now()
    
    this.controller.cachedColorsByCellIndex = new Map()
    const { data_type, values, compression_info } = coloringMetadataVector
    
    if (data_type === 'DISCRETE') {
      // Discrete metadata coloring
      const categoryColors = this.getCategoryColors()
      
      // CRITICAL: Use ALL categories from compression_info if available (includes categories with 0 cells)
      // Otherwise fall back to unique categories from values
      // This ensures colors remain stable even when categories have 0 visible cells
      let allCategories
      if (compression_info && compression_info.categories) {
        allCategories = [...compression_info.categories]
      } else {
        allCategories = [...new Set(values)]
      }
      
      // Use stable sorted categories (always largest-first) for consistent color assignment
      // This ensures colors match between legend and points regardless of display order
      const stableSortedCategories = this.controller.getStableSortedCategories(values, allCategories)
      
      // Build category-to-index map using stable sorted order
      let categoryToIndex = {}
      stableSortedCategories.forEach((cat, idx) => {
        categoryToIndex[cat] = idx
      })
      
      // Cache colors for all points
      for (let i = 0; i < values.length; i++) {
        const category = values[i]
        const categoryIndex = categoryToIndex[category] || 0
        const colorValue = categoryColors[categoryIndex % categoryColors.length]
        const color = typeof colorValue === 'string' 
          ? parseInt(colorValue.replace('#', ''), 16)
          : colorValue
        this.controller.cachedColorsByCellIndex.set(i, color)
      }
      
    } else if (data_type === 'NUMERIC') {
      // Continuous metadata coloring
      const effectiveRange = this.controller.getEffectiveColorRange()
      let minVal, maxVal
      
      if (effectiveRange) {
        minVal = effectiveRange.min
        maxVal = effectiveRange.max
      } else if (compression_info) {
        minVal = compression_info.min_val
        maxVal = compression_info.max_val
      } else {
        minVal = Math.min(...values)
        maxVal = Math.max(...values)
      }
      
      const range = maxVal - minVal
      
      // Cache colors for all points
      for (let i = 0; i < values.length; i++) {
        const value = values[i]
        const normalizedValue = range > 0 ? (value - minVal) / range : 0.5
        const color = this.controller.getColorFromGradient(normalizedValue)
        this.controller.cachedColorsByCellIndex.set(i, color)
      }
      
      // Cache the color range for future comparisons
      this.controller.lastColorRange = effectiveRange ? { min: effectiveRange.min, max: effectiveRange.max } : null
    }
    
    // Cache the metadata ID for future comparisons
    this.controller.lastColoringMetadataId = coloringMetadataVector.id
    
    const elapsed = performance.now() - startTime
    console.log(`🎨 [CACHE] Cached colors for ${this.controller.cachedColorsByCellIndex.size} points in ${elapsed.toFixed(2)}ms`)
  }

  // Centralized function to get the color for a point at a given index
  getPointColor(pointIndex) {
    return this.getColorAndAlpha(pointIndex).color
  }

  // Get the metadata vector that is currently being used for coloring
  getColoringMetadataVector() {
    // Temporarily reduce logging to prevent infinite loop spam
    // console.log('🎨 [GET COLORING] getColoringMetadataVector() called')
    
    // First, check if there's a metadata vector that has a visible legend
    // Look for active legend elements in the DOM
    const activeLegend = document.querySelector('.metadata-legend:not([style*="display: none"])')
    // console.log('🎨 [GET COLORING] Checking for active legend:', {
    //   foundActiveLegend: !!activeLegend,
    //   legendMetadataId: activeLegend?.dataset.metadataId || 'none'
    // })
    if (activeLegend) {
      const metadataId = activeLegend.dataset.metadataId
      if (metadataId && this.controller.loadedMetadataVectors[metadataId]) {
        // console.log('🎨 [GET COLORING] Found coloring metadata vector from active legend:', metadataId)
        return this.controller.loadedMetadataVectors[metadataId]
      }
    }
    
    // Fallback: check for active color legend (for continuous metadata)
    const activeColorLegend = document.querySelector('.color-legend:not([style*="display: none"])')
    // console.log('🎨 [GET COLORING] Checking for active color legend:', {
    //   foundActiveColorLegend: !!activeColorLegend,
    //   colorLegendMetadataId: activeColorLegend?.dataset.metadataId || 'none'
    // })
    if (activeColorLegend) {
      const metadataId = activeColorLegend.dataset.metadataId
      if (metadataId && this.controller.loadedMetadataVectors[metadataId]) {
        // console.log('🎨 [GET COLORING] Found coloring metadata vector from active color legend:', metadataId)
        return this.controller.loadedMetadataVectors[metadataId]
      }
    }
    
    // Fallback: check for active gradient legend (for continuous metadata)
    const activeGradientLegend = document.querySelector('.gradient-legend:not([style*="display: none"])')
    // console.log('🎨 [GET COLORING] Checking for active gradient legend:', {
    //   foundActiveGradientLegend: !!activeGradientLegend,
    //   gradientLegendMetadataId: activeGradientLegend?.dataset.metadataId || 'none'
    // })
    if (activeGradientLegend) {
      const metadataId = activeGradientLegend.dataset.metadataId
      if (metadataId && this.controller.loadedMetadataVectors[metadataId]) {
        // console.log('🎨 [GET COLORING] Found coloring metadata vector from active gradient legend:', metadataId)
        return this.controller.loadedMetadataVectors[metadataId]
      }
    }
    
    // Final fallback: use currentMetadataVector if it exists and has values
    // console.log('🎨 [GET COLORING] Checking currentMetadataVector:', {
    //   hasCurrentMetadataVector: !!this.controller.currentMetadataVector,
    //   currentMetadataVectorId: this.controller.currentMetadataVector?.id || 'none',
    //   hasValues: !!this.controller.currentMetadataVector?.values,
    //   valuesLength: this.controller.currentMetadataVector?.values?.length || 0
    // })
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.values) {
      // console.log('🎨 [GET COLORING] Returning currentMetadataVector:', this.controller.currentMetadataVector.id)
      return this.controller.currentMetadataVector
    }
    
    // console.log('🎨 [GET COLORING] No coloring metadata vector found - returning null')
    return null
  }

  // Clear color cache when coloring metadata changes
  clearColorMapCache() {
    this.controller._cachedColorMap = null
    this.controller._cachedColorMapMetadataId = null
    // Also clear the new color cache for visibility updates
    this.controller.cachedColorsByCellIndex = new Map()
    this.controller.lastColoringMetadataId = null
    this.controller.lastColorRange = null
  }

  // Check if colors need to be recalculated
  shouldRecalculateColors(coloringMetadataVector) {
    // If no coloring metadata, no recalculation needed
    if (!coloringMetadataVector) {
      return false
    }
    
    // If we don't have cached colors, we need to calculate them
    if (!this.controller.cachedColorsByCellIndex || this.controller.cachedColorsByCellIndex.size === 0) {
      return true
    }
    
    // If the coloring metadata ID has changed, we need to recalculate
    if (this.controller.lastColoringMetadataId !== coloringMetadataVector.id) {
      return true
    }
    
    // If the color range has changed (for continuous metadata), we need to recalculate
    if (coloringMetadataVector.data_type === 'NUMERIC') {
      const currentRange = this.controller.getEffectiveColorRange()
      if (this.controller.lastColorRange && currentRange) {
        if (this.controller.lastColorRange.min !== currentRange.min || this.controller.lastColorRange.max !== currentRange.max) {
          return true
        }
      } else if (this.controller.lastColorRange !== currentRange) {
        return true
      }
    }
    
    return false
  }

  // Create discrete color map for categories
  createDiscreteColorMap(categories, metadataId) {
    // Use the centralized color palette from the server
    const colors = this.getCategoryColors()
    
    const colorMap = {}
    categories.forEach((category, index) => {
      // Check if we have a stored color for this category in this metadata
      const storageKey = `category_color_${metadataId}_${category}`
      const storedColor = localStorage.getItem(storageKey)
      
      if (storedColor) {
        // Convert hex string to number for PIXI.js
        colorMap[category] = parseInt(storedColor.replace('#', ''), 16)
      } else {
        // Use default color
        colorMap[category] = colors[index % colors.length]
      }
    })
    
    return colorMap
  }

  // Initialize default gradient based on value distribution
  initializeDefaultGradient() {
    console.log('🎨 initializeDefaultGradient called')
    console.log('🎨 currentMetadataVector:', this.controller.currentMetadataVector)
    console.log('🎨 data_type:', this.controller.currentMetadataVector?.data_type)
    
    if (!this.controller.currentMetadataVector || this.controller.currentMetadataVector.data_type !== 'NUMERIC') {
      console.warn('🎨 ⚠️ Cannot initialize gradient - missing metadata vector or not NUMERIC type')
      return
    }

    const values = this.controller.currentMetadataVector.values
    console.log('🎨 Values length:', values ? values.length : 0)
    
    if (!values || values.length === 0) {
      console.warn('🎨 ⚠️ Cannot initialize gradient - no values in metadata vector')
      return
    }
    
    const controlPoints = this.determineGradientForValues(values)
    console.log('🎨 Determined control points:', controlPoints)
    
    this.controller.gradientControlPoints = controlPoints
    console.log('🎨 Set gradientControlPoints:', this.controller.gradientControlPoints)
  }
  
  // Determine appropriate gradient based on value distribution
  determineGradientForValues(values) {
    // Calculate min and max values
    let minVal = Infinity
    let maxVal = -Infinity
    
    for (let i = 0; i < values.length; i++) {
      const val = values[i]
      if (val < minVal) minVal = val
      if (val > maxVal) maxVal = val
    }
    
    // Store min/max for value conversion
    this.controller.gradientMinValue = minVal
    this.controller.gradientMaxValue = maxVal
    
    // Helper to convert actual value to position
    const valueToPosition = (value) => {
      const range = maxVal - minVal
      if (range === 0) return 0
      return (value - minVal) / range
    }
    
    // Determine gradient type based on value range
    const spansZero = minVal < 0 && maxVal > 0
    const allNegative = maxVal <= 0
    const allPositive = minVal >= 0
    
    console.log('🎨 Determining gradient for values:', { minVal, maxVal, spansZero, allNegative, allPositive })
    
    if (spansZero) {
      // Values span from negative to positive: use diverging gradient (dark blue -> light grey at 0 -> dark red)
      const zeroPosition = valueToPosition(0)
      console.log('🎨 Diverging gradient: zero positioned at', zeroPosition)
      return [
        { position: 0, color: 0x1e3a8a },           // Dark blue (most negative)
        { position: zeroPosition, color: 0xe5e7eb }, // Light grey (at zero)
        { position: 1, color: 0x991b1b }            // Dark red (most positive)
      ]
    } else if (allNegative) {
      // All negative values: dark blue to light grey
      console.log('🎨 All negative gradient: dark blue -> light grey')
      return [
        { position: 0, color: 0x1e3a8a },   // Dark blue (most negative)
        { position: 1, color: 0xe5e7eb }    // Light grey (at zero/least negative)
      ]
    } else if (allPositive) {
      // All positive values: light grey to dark red
      console.log('🎨 All positive gradient: light grey -> dark red')
      // If minimum is exactly 0, position light grey at 0, otherwise at minimum
      const startPosition = minVal === 0 ? 0 : valueToPosition(Math.max(0, minVal))
      return [
        { position: 0, color: 0xe5e7eb },   // Light grey (at zero or minimum)
        { position: 1, color: 0x991b1b }    // Dark red (most positive)
      ]
    } else {
      // Fallback: simple gradient
      return [
        { position: 0, color: 0xdbeafe },   // Light blue
        { position: 1, color: 0x1e40af }    // Dark blue
      ]
    }
  }

  // Get category colors from global palette
  getCategoryColors() {
    // Cache the colors to prevent repeated conversion
    if (this.controller._cachedCategoryColors) {
      return this.controller._cachedCategoryColors
    }
    
    //console.log('🎨 getCategoryColors called - converting colors for first time')
    //console.log('🎨 window.CATEGORY_COLORS:', window.CATEGORY_COLORS)
    
    // Use colors from the global color palette loaded in layout
    if (window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0) {
      //console.log('Converting colors to JavaScript hex numbers')
      // Convert CSS hex colors (#1f77b4) to JavaScript hex numbers (0x1f77b4)
      const jsColors = window.CATEGORY_COLORS.map(cssColor => {
        // Remove # and convert to hex number
        return parseInt(cssColor.replace('#', ''), 16)
      })
      //console.log('Converted colors:', jsColors)
      
      // Cache the converted colors
      this.controller._cachedCategoryColors = jsColors
      return jsColors
    }
    
    // Temporary fallback to prevent infinite loop - will be removed once colors are properly loaded
    console.warn('Using temporary fallback colors to prevent infinite loop')
    const fallbackColors = [
      0x1f77b4, 0xff7f0e, 0x2ca02c, 0x9467bd, 0x8c564b, 
      0xe377c2, 0x7f7f7f, 0xbcbd22, 0x17becf, 0x4ecdc4
    ]
    
    // Cache the fallback colors too
    this.controller._cachedCategoryColors = fallbackColors
    return fallbackColors
  }

  // Clear the cached colors (call this when colors are reloaded)
  clearCategoryColorsCache() {
    this.controller._cachedCategoryColors = null
  }
}
