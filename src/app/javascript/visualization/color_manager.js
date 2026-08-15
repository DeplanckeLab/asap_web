/**
 * Color Manager Module
 * Handles color management and customization
 */

import { getDiscretePaletteHexList } from 'visualization/discrete_palettes'

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
      return { color: this.controller.getSelectionHighlightColorInt(), alpha: 1.0 }
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
          const labels = this.controller.dataManager.getCategoryLabels(coloringMetadataVector)
          if (!labels) {
            throw new Error(`Discrete metadata ${coloringMetadataVector.id} is missing compression_info.categories`)
          }
          const allCategories = [...labels]
          
          const stableSortedCategories = this.controller.getStableSortedCategories(values, allCategories)
          
          // Create color map using stable sorted order with per-category overrides (keyed by label)
          const discreteColorMap = this.createDiscreteColorMap(stableSortedCategories, coloringMetadataVector.id)
          this.controller._cachedColorMap = {}
          const colorByCode = new Array(labels.length)
          for (let code = 0; code < labels.length; code++) {
            const label = labels[code]
            const color = discreteColorMap[label]
            this.controller._cachedColorMap[label] = color
            colorByCode[code] = color
          }
          this.controller._cachedColorByCode = colorByCode
          
          this.controller._cachedColorMapMetadataId = coloringMetadataVector.id
        }
        
        baseColor = this.controller._cachedColorByCode[value] || 0x3b82f6
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
        
        if (typeof value !== 'number' || Number.isNaN(value)) {
          baseColor = this.controller.getMissingNumericColor()
        } else if (this.controller.getEffectiveGradientScale(minVal, maxVal) === 'log' && value <= 0) {
          baseColor = this.controller.getMissingNumericColor()
        } else {
          const normalizedValue = this.controller.valueToGradientPosition(value, minVal, maxVal)
          
          // Use gradient manager to get color
          baseColor = this.controller.gradientManager.getColorFromGradient(normalizedValue)
          if (!baseColor || baseColor === 0) {
            baseColor = this.controller.getMissingNumericColor()
          }
        }
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
    // Source of truth: current metadata vector actively selected for coloring.
    // DOM legends can be stale after checkpoint restore, so do not prioritize them.
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.values) {
      return this.controller.currentMetadataVector
    }

    if (this.controller.currentMetadataId && this.controller.loadedMetadataVectors?.[this.controller.currentMetadataId]) {
      return this.controller.loadedMetadataVectors[this.controller.currentMetadataId]
    }
    
    const activeLegend = document.querySelector('.metadata-legend:not([style*="display: none"])')
    if (activeLegend) {
      const metadataId = activeLegend.dataset.metadataId
      if (metadataId && this.controller.loadedMetadataVectors[metadataId]) {
        return this.controller.loadedMetadataVectors[metadataId]
      }
    }
    
    const activeColorLegend = document.querySelector('.color-legend:not([style*="display: none"])')
    if (activeColorLegend) {
      const metadataId = activeColorLegend.dataset.metadataId
      if (metadataId && this.controller.loadedMetadataVectors[metadataId]) {
        return this.controller.loadedMetadataVectors[metadataId]
      }
    }
    
    const activeGradientLegend = document.querySelector('.gradient-legend:not([style*="display: none"])')
    if (activeGradientLegend) {
      const metadataId = activeGradientLegend.dataset.metadataId
      if (metadataId && this.controller.loadedMetadataVectors[metadataId]) {
        return this.controller.loadedMetadataVectors[metadataId]
      }
    }
    
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.values) {
      return this.controller.currentMetadataVector
    }
    
    return null
  }

  shouldRecalculateColors(coloringMetadataVector) {
    // If no coloring metadata, no recalculation needed
    if (!coloringMetadataVector) {
      return false
    }
    
    // If we don't have cached colors, we need to calculate them
    if (!(this.controller.cachedColorsByCellIndex instanceof Uint32Array) || this.controller.cachedColorsByCellIndex.length === 0) {
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
      if (this.controller.lastGradientScale !== this.controller.getEffectiveGradientScale()) {
        return true
      }
    }
    
    return false
  }

  getPointColor(pointIndex) {
    return this.getColorAndAlpha(pointIndex).color
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
        this.controller.ensurePointColorArrays(numPoints)
        for (let i = 0; i < numPoints; i++) {
          const isSelected = this.controller.selectedCells && this.controller.selectedCells.has(i)
          this.controller.cachedColorsByCellIndex[i] = isSelected ? this.controller.getSelectionHighlightColorInt() : 0x3b82f6
        }
      } else {
        this.controller.cachedColorsByCellIndex = null
      }
      
      this.controller.lastColoringMetadataId = null
      this.controller.lastColorRange = null
      this.controller.lastGradientScale = null
      return
    }
    
    // console.log(`🎨 [CACHE] Calculating colors for ${coloringMetadataVector.values.length} points`)
    const startTime = performance.now()
    
    this.controller.ensurePointColorArrays(coloringMetadataVector.values.length)
    const { data_type, values, compression_info } = coloringMetadataVector
    
    if (data_type === 'DISCRETE' || data_type === 'STRING') {
      // Discrete metadata coloring — values are codes; labels in compression_info.categories
      const labels = this.controller.dataManager.getCategoryLabels(coloringMetadataVector)
      if (!labels) {
        throw new Error(`Discrete metadata ${coloringMetadataVector.id} is missing compression_info.categories`)
      }
      const allCategories = [...labels]
      
      // Use stable sorted categories (always largest-first) for consistent color assignment
      // This ensures colors match between legend and points regardless of display order
      const stableSortedCategories = this.controller.getStableSortedCategories(values, allCategories)
      
      // Build category-to-index map using stable sorted order (keys are labels)
      let categoryToIndex = {}
      stableSortedCategories.forEach((cat, idx) => {
        categoryToIndex[cat] = idx
      })
      
      const discreteColorMap = this.createDiscreteColorMap(stableSortedCategories, coloringMetadataVector.id)
      const palette = this.getCategoryColors()
      const colorByCode = new Array(labels.length)
      for (let code = 0; code < labels.length; code++) {
        const label = labels[code]
        const categoryIndex = categoryToIndex[label] || 0
        const fallbackColorValue = palette[categoryIndex % palette.length]
        const fallbackColor = typeof fallbackColorValue === 'string'
          ? parseInt(fallbackColorValue.replace('#', ''), 16)
          : fallbackColorValue
        colorByCode[code] = discreteColorMap[label] !== undefined ? discreteColorMap[label] : fallbackColor
      }

      // Cache colors for all points
      for (let i = 0; i < values.length; i++) {
        const color = colorByCode[values[i]] !== undefined ? colorByCode[values[i]] : 0x3b82f6
        const isSelected = this.controller.selectedCells && this.controller.selectedCells.has(i)
        this.controller.cachedColorsByCellIndex[i] = isSelected ? this.controller.getSelectionHighlightColorInt() : color
        this.controller.originalPointColors[i] = color
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
        // Never use Math.min/max(...values): large embeddings blow the call stack.
        minVal = this.controller.dataManager.safeMin(values)
        maxVal = this.controller.dataManager.safeMax(values)
      }
      
      const missingColor = this.controller.getMissingNumericColor()
      const useLog = this.controller.getEffectiveGradientScale(minVal, maxVal) === 'log'
      
      // Cache colors for all points
      for (let i = 0; i < values.length; i++) {
        const value = values[i]
        let color
        if (typeof value !== 'number' || Number.isNaN(value)) {
          color = missingColor
        } else if (useLog && value <= 0) {
          color = missingColor
        } else {
          const normalizedValue = this.controller.valueToGradientPosition(value, minVal, maxVal)
          color = this.controller.gradientManager.getColorFromGradient(normalizedValue)
          if (!color || color === 0) {
            color = missingColor
          }
        }
        const isSelected = this.controller.selectedCells && this.controller.selectedCells.has(i)
        this.controller.cachedColorsByCellIndex[i] = isSelected ? this.controller.getSelectionHighlightColorInt() : color
        this.controller.originalPointColors[i] = color
      }
      
      // Cache the color range for future comparisons
      this.controller.lastColorRange = effectiveRange ? { min: effectiveRange.min, max: effectiveRange.max } : null
      this.controller.lastGradientScale = this.controller.getEffectiveGradientScale(minVal, maxVal)
    }
    
    // Cache the metadata ID for future comparisons
    this.controller.lastColoringMetadataId = coloringMetadataVector.id
    
    const elapsed = performance.now() - startTime
    // console.log(`🎨 [CACHE] Cached colors for ${this.controller.cachedColorsByCellIndex.length} points in ${elapsed.toFixed(2)}ms`)
  }

  // Clear color cache when coloring metadata changes
  clearColorMapCache() {
    this.controller._cachedColorMap = null
    this.controller._cachedColorByCode = null
    this.controller._cachedColorMapMetadataId = null
    this.controller._cachedCentroids = null
    this.controller._cachedCentroidsKey = null
    this.controller.cachedColorsByCellIndex = null
    this.controller.lastColoringMetadataId = null
    this.controller.lastColorRange = null
    this.controller.lastGradientScale = null
    this.invalidateCategoryColorOverrides()
  }

  // Create discrete color map for categories
  createDiscreteColorMap(categories, metadataId) {
    // Use the centralized color palette from the server
    const colors = this.getCategoryColors()
    const overrides = this.getCategoryColorOverrides(metadataId)
    
    const colorMap = {}
    categories.forEach((category, index) => {
      const storedColor = overrides.get(String(category))
      
      if (storedColor) {
        // Convert hex string to packed RGB number
        colorMap[category] = parseInt(String(storedColor).replace('#', ''), 16)
      } else {
        // Use default color
        colorMap[category] = colors[index % colors.length]
      }
    })
    
    return colorMap
  }

  // Read all category_color_${metadataId}_* overrides once (avoids per-category localStorage in hot path)
  getCategoryColorOverrides(metadataId) {
    const key = String(metadataId)
    if (this._categoryColorOverrideCache && this._categoryColorOverrideCacheMetadataId === key) {
      return this._categoryColorOverrideCache
    }

    const prefix = `category_color_${metadataId}_`
    const overrides = new Map()
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const storageKey = localStorage.key(i)
        if (!storageKey || !storageKey.startsWith(prefix)) continue
        const category = storageKey.slice(prefix.length)
        const storedColor = localStorage.getItem(storageKey)
        if (storedColor) overrides.set(String(category), storedColor)
      }
    } catch (error) {
      console.warn('Failed to batch-load category color overrides:', error)
    }

    this._categoryColorOverrideCache = overrides
    this._categoryColorOverrideCacheMetadataId = key
    return overrides
  }

  invalidateCategoryColorOverrides(metadataId = null) {
    if (metadataId == null || String(metadataId) === this._categoryColorOverrideCacheMetadataId) {
      this._categoryColorOverrideCache = null
      this._categoryColorOverrideCacheMetadataId = null
    }
  }

  // Initialize default gradient based on value distribution
  initializeDefaultGradient() {
    // console.log('🎨 initializeDefaultGradient called')
    // console.log('🎨 currentMetadataVector:', this.controller.currentMetadataVector)
    // console.log('🎨 data_type:', this.controller.currentMetadataVector?.data_type)
    
    if (!this.controller.currentMetadataVector || this.controller.currentMetadataVector.data_type !== 'NUMERIC') {
      console.warn('🎨 ⚠️ Cannot initialize gradient - missing metadata vector or not NUMERIC type')
      return
    }

    const values = this.controller.currentMetadataVector.values
    // console.log('🎨 Values length:', values ? values.length : 0)
    
    if (!values || values.length === 0) {
      console.warn('🎨 ⚠️ Cannot initialize gradient - no values in metadata vector')
      return
    }
    
    const controlPoints = this.determineGradientForValues(values)
    // console.log('🎨 Determined control points:', controlPoints)
    
    this.controller.gradientControlPoints = controlPoints
    // console.log('🎨 Set gradientControlPoints:', this.controller.gradientControlPoints)
  }
  
  // Determine appropriate gradient based on value distribution
  determineGradientForValues(values) {
    const minVal = this.controller.dataManager.safeMin(values)
    const maxVal = this.controller.dataManager.safeMax(values)

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
    
    // console.log('🎨 Determining gradient for values:', { minVal, maxVal, spansZero, allNegative, allPositive })
    
    if (spansZero) {
      // Values span from negative to positive: use diverging gradient (dark blue -> light grey at 0 -> dark red)
      const zeroPosition = valueToPosition(0)
      // console.log('🎨 Diverging gradient: zero positioned at', zeroPosition)
      return [
        { position: 0, color: 0x1e3a8a },           // Dark blue (most negative)
        { position: zeroPosition, color: 0xe5e7eb }, // Light grey (at zero)
        { position: 1, color: 0x991b1b }            // Dark red (most positive)
      ]
    } else if (allNegative) {
      // All negative values: dark blue to light grey
      // console.log('🎨 All negative gradient: dark blue -> light grey')
      return [
        { position: 0, color: 0x1e3a8a },   // Dark blue (most negative)
        { position: 1, color: 0xe5e7eb }    // Light grey (at zero/least negative)
      ]
    } else if (allPositive) {
      // All positive values: light grey to dark red
      // console.log('🎨 All positive gradient: light grey -> dark red')
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
  getCategoryColors () {
    const paletteId = this.controller.discretePaletteId
    if (
      this.controller._cachedCategoryColors &&
      this.controller._cachedDiscretePaletteId === paletteId
    ) {
      return this.controller._cachedCategoryColors
    }

    const hexList = getDiscretePaletteHexList(paletteId)
    if (hexList.length > 0) {
      const jsColors = hexList.map(cssColor => {
        const s = String(cssColor).replace('#', '').trim()
        const n = parseInt(s, 16)
        return Number.isFinite(n) ? n : 0x3b82f6
      })
      this.controller._cachedCategoryColors = jsColors
      this.controller._cachedDiscretePaletteId = paletteId
      return jsColors
    }

    console.warn('Using temporary fallback colors to prevent infinite loop')
    const fallbackColors = [
      0x1f77b4, 0xff7f0e, 0x2ca02c, 0x9467bd, 0x8c564b,
      0xe377c2, 0x7f7f7f, 0xbcbd22, 0x17becf, 0x4ecdc4
    ]
    this.controller._cachedCategoryColors = fallbackColors
    this.controller._cachedDiscretePaletteId = paletteId
    return fallbackColors
  }

  getCategoryColorsCssHex () {
    return this.getCategoryColors().map(n => {
      const hex = ((n >>> 0) & 0xFFFFFF).toString(16).padStart(6, '0')
      return '#' + hex
    })
  }

  // Clear the cached colors (call this when colors are reloaded)
  clearCategoryColorsCache () {
    this.controller._cachedCategoryColors = null
    this.controller._cachedDiscretePaletteId = null
  }
}
