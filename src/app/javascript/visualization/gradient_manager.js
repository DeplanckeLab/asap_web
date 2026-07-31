// GradientManager - Handles all gradient-related functionality including modal, control points, and color calculations
export class GradientManager {
  constructor(controller) {
    this.controller = controller
    this.isDraggingControlPoint = false // Flag to prevent marker re-rendering during drag
  }

  // Open gradient editor modal
  openGradientEditorModal() {
    const modal = document.getElementById('gradient-editor-modal')
    if (!modal) {
      console.error('❌ Gradient editor modal not found')
      return
    }

    // console.log('🎨 Opening gradient editor modal')
    // console.log('🎨 Current metadata ID:', this.controller.currentMetadataId)
    // console.log('🎨 Current metadata vector:', this.controller.currentMetadataVector)

    // Close any open control point editor to start fresh
    this.controller.closeControlPointEditor()
    this.controller.selectedControlPointIndex = undefined

    // Load gradient for current metadata (or initialize default if none exists)
    this.loadGradientForMetadata(this.controller.currentMetadataId)
    
    // Calculate and store min/max values for the current metadata
    if (this.controller.currentMetadataVector && this.controller.currentMetadataVector.values) {
      const values = this.controller.currentMetadataVector.values
      this.controller.gradientMinValue = this.controller.dataManager.safeMin(values)
      this.controller.gradientMaxValue = this.controller.dataManager.safeMax(values)
      // Prefer the effective coloring range when available (respects adapted/custom range)
      const effectiveRange = this.controller.getEffectiveColorRange?.()
      if (effectiveRange && Number.isFinite(effectiveRange.min) && Number.isFinite(effectiveRange.max)) {
        this.controller.gradientMinValue = effectiveRange.min
        this.controller.gradientMaxValue = effectiveRange.max
      }
    } else {
      console.warn('🎨 ⚠️ No metadata vector or values found:', {
        hasMetadataVector: !!this.controller.currentMetadataVector,
        hasValues: !!(this.controller.currentMetadataVector && this.controller.currentMetadataVector.values),
        dataType: this.controller.currentMetadataVector?.data_type
      })
    }

    if (this.controller.gradientScale === 'log' &&
        !this.controller.canUseLogGradientScale(this.controller.gradientMinValue, this.controller.gradientMaxValue)) {
      this.controller.gradientScale = 'normal'
      this.saveGradientForMetadata(this.controller.currentMetadataId)
    }

    // Get the control points that will be used
    const controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    // console.log('🎨 Control points to render:', controlPoints)
    // console.log('🎨 Number of control points:', controlPoints ? controlPoints.length : 0)

    // Show modal
    modal.style.display = 'flex'
    
    // Wait for layout to settle before rendering markers
    // This ensures the canvas has its final width
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        // Initialize gradient editor with current gradient
        this.syncGradientScaleSelect()
        this.controller.rendererManager.renderModalGradientPreview()
        this.controller.rendererManager.renderModalControlPointMarkers()
        this.controller.rendererManager.renderControlPointsList()
        this.renderGradientDistributionHistogram()
        
        // Attach event listeners to buttons since the modal is outside the controller scope
        this.attachModalButtonListeners()
        
        // Attach click/hover listeners to gradient and histogram canvases
        this.attachGradientCanvasListener()
        this.attachGradientEditorHoverListeners()
        
        // console.log('Modal opened and rendered')
      })
    })
  }
  
  // Attach click listener to gradient canvas
  attachGradientCanvasListener() {
    const canvas = document.getElementById('gradient-editor-preview-canvas')
    if (canvas) {
      // Remove any existing listener to avoid duplicates
      const newCanvas = canvas.cloneNode(true)
      canvas.parentNode.replaceChild(newCanvas, canvas)
      
      // Re-render the gradient on the new canvas
      this.controller.rendererManager.renderModalGradientPreview()
      
      // Attach click listener
      newCanvas.addEventListener('click', (event) => {
        this.gradientBarClicked(event)
      })
    }
  }

  attachGradientEditorHoverListeners() {
    const wrap = document.getElementById('gradient-editor-preview-wrap')
    if (!wrap) return
    if (wrap.dataset.hoverBound === '1') return
    wrap.dataset.hoverBound = '1'
    wrap.addEventListener('mousemove', (event) => {
      this.handleGradientEditorHover(event)
    })
    wrap.addEventListener('mouseleave', () => {
      this.clearGradientEditorHover()
    })
  }
  
  // Attach event listeners to modal buttons
  attachModalButtonListeners() {
    // Close button (X in header)
    const closeBtn = document.getElementById('close-gradient-editor')
    if (closeBtn) {
      // Remove any existing listener to avoid duplicates
      const newCloseBtn = closeBtn.cloneNode(true)
      closeBtn.parentNode.replaceChild(newCloseBtn, closeBtn)
      newCloseBtn.addEventListener('click', () => {
        // console.log('🎨 Close button clicked')
        this.closeGradientEditorModal()
      })
    }
    
    // Apply & Close button
    const applyBtn = document.getElementById('gradient-apply-btn')
    if (applyBtn) {
      // Remove any existing listener to avoid duplicates
      const newApplyBtn = applyBtn.cloneNode(true)
      applyBtn.parentNode.replaceChild(newApplyBtn, applyBtn)
      newApplyBtn.addEventListener('click', () => {
        // console.log('🎨 Apply & Close button clicked')
        this.closeGradientEditorModal()
      })
    }
    
    // Reset button
    const resetBtn = document.getElementById('gradient-reset-btn')
    if (resetBtn) {
      // Remove any existing listener to avoid duplicates
      const newResetBtn = resetBtn.cloneNode(true)
      resetBtn.parentNode.replaceChild(newResetBtn, resetBtn)
      newResetBtn.addEventListener('click', () => {
        // console.log('🎨 Reset button clicked')
        this.controller.resetGradient()
      })
    }
    
    // Done button in control point editor
    const doneBtn = document.getElementById('gradient-close-control-point-editor-btn')
    if (doneBtn) {
      // Remove any existing listener to avoid duplicates
      const newDoneBtn = doneBtn.cloneNode(true)
      doneBtn.parentNode.replaceChild(newDoneBtn, doneBtn)
      newDoneBtn.addEventListener('click', () => {
        // console.log('🎨 Done button (control point editor) clicked')
        // Apply any pending changes before closing the editor
        this.applyPendingControlPointChanges()
        this.controller.closeControlPointEditor()
      })
    }
    
    // Remove Point button
    const removeBtn = document.getElementById('gradient-remove-control-point-btn')
    if (removeBtn) {
      // Remove any existing listener to avoid duplicates
      const newRemoveBtn = removeBtn.cloneNode(true)
      removeBtn.parentNode.replaceChild(newRemoveBtn, removeBtn)
      newRemoveBtn.addEventListener('click', () => {
        // console.log('🎨 Remove Point button clicked')
        this.removeControlPoint()
      })
    }

    const scaleSelect = document.getElementById('gradient-scale-select')
    if (scaleSelect && !scaleSelect.dataset.gradientScaleBound) {
      scaleSelect.dataset.gradientScaleBound = '1'
      scaleSelect.addEventListener('change', (e) => {
        this.handleGradientScaleChange(e.target.value)
      })
    }
    this.syncGradientScaleSelect()
  }

  syncGradientScaleSelect() {
    const scaleSelect = document.getElementById('gradient-scale-select')
    const hint = document.getElementById('gradient-scale-hint')
    if (!scaleSelect) return

    const minVal = this.controller.gradientMinValue
    const maxVal = this.controller.gradientMaxValue
    const canUseLog = this.controller.canUseLogGradientScale(minVal, maxVal)
    const logOption = scaleSelect.querySelector('option[value="log"]')
    if (logOption) {
      logOption.disabled = !canUseLog
    }

    const effective = this.controller.getEffectiveGradientScale(minVal, maxVal)
    scaleSelect.value = effective === 'log' ? 'log' : 'normal'
    scaleSelect.disabled = false

    if (hint) {
      if (!canUseLog) {
        hint.textContent = 'Log10 requires a strictly positive value range.'
      } else if (effective === 'log') {
        hint.textContent = 'Data values are mapped to the gradient in log10 space.'
      } else {
        hint.textContent = 'Maps data values to the gradient.'
      }
    }
  }

  handleGradientScaleChange(scale) {
    const applied = this.controller.setGradientScale(scale)
    if (!applied) {
      this.syncGradientScaleSelect()
      return
    }
    this.saveGradientForMetadata(this.controller.currentMetadataId)
    this.syncGradientScaleSelect()

    // Refresh control-point value labels (positions stay the same; displayed values change with scale)
    if (this.controller.selectedControlPointIndex !== undefined) {
      this.selectControlPoint(this.controller.selectedControlPointIndex)
    }
    this.controller.rendererManager.renderModalControlPointMarkers()
    this.controller.rendererManager.renderControlPointsList()
    this.renderGradientDistributionHistogram()
    this.controller.reapplyColorsWithNewGradient()
  }
  
  // Apply any pending changes from the control point editor inputs
  applyPendingControlPointChanges() {
    const colorInput = document.getElementById('gradient-control-point-color')
    const positionInput = document.getElementById('gradient-control-point-position')
    const selectedIndex = this.controller.selectedControlPointIndex
    
    if (selectedIndex === undefined) {
      return
    }
    
    // Ensure we have a custom gradient
    if (!this.controller.customGradientControlPoints) {
      if (this.controller.gradientControlPoints) {
        this.controller.customGradientControlPoints = this.controller.gradientControlPoints.map(p => ({
          position: p.position,
          color: p.color
        }))
      } else {
        return
      }
    }
    
    // Apply color change if any
    if (colorInput && colorInput.value) {
      const hexColor = colorInput.value
      const color = parseInt(hexColor.substring(1), 16)
      if (this.controller.customGradientControlPoints[selectedIndex]) {
        this.controller.customGradientControlPoints[selectedIndex].color = color
        // console.log('🎨 applyPendingControlPointChanges: Updated color to', hexColor)
      }
    }
    
    // Apply position change if any
    if (positionInput && positionInput.value) {
      const actualValue = parseFloat(positionInput.value)
      if (!isNaN(actualValue)) {
        const position = this.controller.actualValueToPosition(actualValue)
        if (this.controller.customGradientControlPoints[selectedIndex]) {
          this.controller.customGradientControlPoints[selectedIndex].position = position
          // console.log('🎨 applyPendingControlPointChanges: Updated position to', position)
          
          // Sort control points
          this.controller.customGradientControlPoints.sort((a, b) => a.position - b.position)
          
          // Find new index after sorting
          const currentColor = this.controller.customGradientControlPoints.find(p => 
            Math.abs(p.position - position) < 0.001
          )?.color
          if (currentColor !== undefined) {
            const newIndex = this.controller.customGradientControlPoints.findIndex(p => 
              Math.abs(p.position - position) < 0.001 && p.color === currentColor
            )
            if (newIndex >= 0) {
              this.controller.selectedControlPointIndex = newIndex
            }
          }
        }
      }
    }
    
    // Update display
    this.updateGradientDisplay()
  }

  // Close gradient editor modal
  closeGradientEditorModal() {
    // console.log('closeGradientEditorModal called')
    
    // Before closing, ensure any pending color/position changes are applied
    const editor = document.getElementById('gradient-control-point-editor')
    if (editor && editor.style.display !== 'none') {
      // console.log('closeGradientEditorModal: Applying pending changes before closing')
      this.applyPendingControlPointChanges()
    }
    
    // Save gradient for current metadata before closing
    this.saveGradientForMetadata(this.controller.currentMetadataId)
    this.clearGradientEditorHover()
    
    const modal = document.getElementById('gradient-editor-modal')
    if (modal) {
      modal.style.display = 'none'
    }
    
    // Close control point editor if open
    this.controller.closeControlPointEditor()
    
    // Ensure scatter plot and bar plots are updated with the final gradient
    // This handles the case where the modal is closed, ensuring all visualizations
    // reflect the current gradient state
    if (this.controller.currentMetadataVector?.data_type === 'NUMERIC') {
      // console.log('🎨 closeGradientEditorModal: Updating all visualizations with new gradient')
      // This will update: legend, scatter plot points, and bar plots
      this.controller.reapplyColorsWithNewGradient()
    }
    
    // console.log('🎨 closeGradientEditorModal: Modal closed and changes applied')
  }

  // Handle clicking on gradient bar to add new control point
  gradientBarClicked(event) {
    // Stop event propagation to avoid conflicts with marker clicks
    event.stopPropagation()
    
    const canvas = event.target
    const rect = canvas.getBoundingClientRect()
    const x = event.clientX - rect.left
    const normalizedPosition = Math.max(0, Math.min(1, x / rect.width))
    
    // Get control points (will create custom if needed)
    let controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    
    // Check if click is near an existing control point (within threshold)
    if (controlPoints && controlPoints.length > 0) {
      const threshold = 0.02 // 2% threshold
      
      for (let i = 0; i < controlPoints.length; i++) {
        const point = controlPoints[i]
        if (Math.abs(point.position - normalizedPosition) < threshold) {
          // Clicked near existing point - select it instead
          // Make sure we're using custom gradient
          if (!this.controller.customGradientControlPoints) {
            this.controller.customGradientControlPoints = this.controller.gradientControlPoints 
              ? [...this.controller.gradientControlPoints] 
              : []
            controlPoints = this.controller.customGradientControlPoints
            // Re-find the index after copying
            i = controlPoints.findIndex(p => 
              Math.abs(p.position - point.position) < 0.0001 && p.color === point.color
            )
            if (i < 0) break
          }
          this.selectControlPoint(i)
          return
        }
      }
    }
    
    // Not near an existing point - add a new one
    const color = this.getColorFromGradient(normalizedPosition)
    this.addControlPoint(normalizedPosition, color)
  }

  // Select a control point for editing
  selectControlPoint(index) {
    // Create custom gradient if modifying auto gradient
    if (!this.controller.customGradientControlPoints) {
      this.controller.customGradientControlPoints = this.controller.gradientControlPoints 
        ? [...this.controller.gradientControlPoints] 
        : []
    }
    
    const controlPoints = this.controller.customGradientControlPoints
    if (!controlPoints || index < 0 || index >= controlPoints.length) {
      return
    }
    
    this.controller.selectedControlPointIndex = index
    const point = controlPoints[index]
    
    // Show editor panel
    const editor = document.getElementById('gradient-control-point-editor')
    if (editor) {
      editor.style.display = 'block'
      // Store the index in data attribute for recovery
      editor.dataset.selectedControlPointIndex = index
    }
    
    // Populate editor fields
    const positionInput = document.getElementById('gradient-control-point-position')
    const colorInput = document.getElementById('gradient-control-point-color')
    
    if (positionInput) {
      // Convert position (0-1) to actual value
      const actualValue = this.controller.positionToActualValue(point.position)
      positionInput.value = actualValue.toFixed(3)
      // Store the index in data attribute
      positionInput.dataset.controlPointIndex = index
      
      // Update input min/max attributes to match data range
      if (this.controller.gradientMinValue !== undefined && this.controller.gradientMaxValue !== undefined) {
        positionInput.min = this.controller.gradientMinValue
        positionInput.max = this.controller.gradientMaxValue
        const range = this.controller.gradientMaxValue - this.controller.gradientMinValue
        positionInput.step = range > 0 ? range / 1000 : 0.001
      }
    }
    
    if (colorInput) {
      colorInput.value = `#${point.color.toString(16).padStart(6, '0')}`
      // Store the index in data attribute
      colorInput.dataset.controlPointIndex = index
    }
    
    // Update markers to show selected state
    this.renderModalControlPointMarkers()
  }

  // Add a new control point at the specified position with the specified color
  addControlPoint(position, color) {
    // Create custom gradient if modifying auto gradient
    if (!this.controller.customGradientControlPoints) {
      this.controller.customGradientControlPoints = this.controller.gradientControlPoints 
        ? [...this.controller.gradientControlPoints] 
        : []
    }
    
    // Clamp position to valid range
    const clampedPosition = Math.max(0, Math.min(1, position))
    
    // Add new control point
    const newPoint = {
      position: clampedPosition,
      color: color
    }
    
    this.controller.customGradientControlPoints.push(newPoint)
    
    // Sort by position
    this.controller.customGradientControlPoints.sort((a, b) => a.position - b.position)
    
    // Find the index of the newly added point after sorting
    const newIndex = this.controller.customGradientControlPoints.findIndex(p => 
      p.position === clampedPosition && p.color === color
    )
    
    // Select the newly added point
    if (newIndex >= 0) {
      this.selectControlPoint(newIndex)
    }
    
    // Update preview
    this.updateGradientDisplay()
  }

  // Remove a control point
  removeControlPoint(index) {
    // Use provided index or selected index
    const targetIndex = index !== undefined ? index : this.controller.selectedControlPointIndex
    if (targetIndex === undefined || targetIndex < 0) {
      return false
    }
    
    // Create custom gradient if modifying auto gradient
    if (!this.controller.customGradientControlPoints) {
      this.controller.customGradientControlPoints = this.controller.gradientControlPoints 
        ? [...this.controller.gradientControlPoints] 
        : []
    }
    
    const controlPoints = this.controller.customGradientControlPoints
    
    // Validate index
    if (targetIndex >= controlPoints.length) {
      return false
    }
    
    // Don't allow removing if only 2 points left (minimum required)
    if (controlPoints.length <= 2) {
      alert('A gradient must have at least 2 control points.')
      return false
    }
    
    // Remove control point
    controlPoints.splice(targetIndex, 1)
    
    // Adjust selected index
    if (this.controller.selectedControlPointIndex === targetIndex) {
      // Removed the selected point - clear selection
      this.controller.selectedControlPointIndex = undefined
      this.controller.closeControlPointEditor()
    } else if (this.controller.selectedControlPointIndex > targetIndex) {
      // Adjust selected index if a point before it was removed
      this.controller.selectedControlPointIndex--
    }
    
    // Save gradient for current metadata
    this.saveGradientForMetadata(this.controller.currentMetadataId)
    
    // Update preview
    this.updateGradientDisplay()
    
    return true
  }
  
  // Update gradient display and reapply colors
  updateGradientDisplay() {
    // console.log('🎨 updateGradientDisplay called')
    // console.log('🎨 updateGradientDisplay: customGradientControlPoints', this.controller.customGradientControlPoints)
    // console.log('🎨 updateGradientDisplay: gradientControlPoints', this.controller.gradientControlPoints)
    
    // CRITICAL: If both are undefined, reinitialize from current metadata
    if (!this.controller.customGradientControlPoints && !this.controller.gradientControlPoints) {
      console.warn('🎨 ⚠️ Both gradient arrays are undefined! Reinitializing...')
      if (this.controller.currentMetadataVector?.data_type === 'NUMERIC') {
        this.controller.colorManager.initializeDefaultGradient()
        // console.log('🎨 updateGradientDisplay: After reinit, gradientControlPoints', this.controller.gradientControlPoints)
      }
    }
    
    // Preserve control points before rendering - prefer custom, fallback to default
    let preservedCustomPoints = this.controller.customGradientControlPoints ? 
      JSON.parse(JSON.stringify(this.controller.customGradientControlPoints)) : null
    let preservedDefaultPoints = this.controller.gradientControlPoints ? 
      JSON.parse(JSON.stringify(this.controller.gradientControlPoints)) : null
    
    // If we have default points but no custom, preserve default as custom
    if (!preservedCustomPoints && preservedDefaultPoints) {
      // console.log('🎨 updateGradientDisplay: No custom points, preserving default as custom')
      preservedCustomPoints = preservedDefaultPoints
    }
    
    this.controller.rendererManager.renderModalGradientPreview()
    this.controller.rendererManager.renderModalControlPointMarkers()
    this.renderGradientDistributionHistogram()
    
    // Restore control points if they got lost - prefer custom, fallback to default
    if (!this.controller.customGradientControlPoints) {
      if (preservedCustomPoints) {
        console.warn('Control points were lost during rendering! Restoring custom...')
        this.controller.customGradientControlPoints = preservedCustomPoints
      } else if (preservedDefaultPoints) {
        console.warn('Control points were lost during rendering! Restoring default...')
        this.controller.gradientControlPoints = preservedDefaultPoints
      }
    }
    
    // console.log('🎨 updateGradientDisplay: after rendering, customGradientControlPoints', this.controller.customGradientControlPoints)
    
    this.controller.reapplyColorsWithNewGradient()
    
    // Restore again after reapplyColors in case it reset them
    if (!this.controller.customGradientControlPoints) {
      if (preservedCustomPoints) {
        console.warn('🎨 ⚠️ Control points were lost during reapplyColors! Restoring custom...')
        this.controller.customGradientControlPoints = preservedCustomPoints
      } else if (preservedDefaultPoints) {
        console.warn('🎨 ⚠️ Control points were lost during reapplyColors! Restoring default...')
        this.controller.gradientControlPoints = preservedDefaultPoints
      }
    }
    
    // console.log('🎨 updateGradientDisplay: after reapplyColors, customGradientControlPoints', this.controller.customGradientControlPoints)
  }

  // Load gradient for a specific metadata ID
  loadGradientForMetadata(metadataId) {
    if (!metadataId) {
      console.warn('🎨 ⚠️ Cannot load gradient - no metadata ID')
      return
    }
    
    // console.log('🎨 Loading gradient for metadata:', metadataId)
    
    // CRITICAL: Clear existing gradient values first to avoid using previous metadata's gradient
    this.controller.gradientControlPoints = null
    this.controller.customGradientControlPoints = null
    this.controller.gradientScale = 'normal'
    
    // Check if we have a stored gradient for this metadata
    const storedGradient = this.controller.metadataGradients.get(metadataId)
    
    if (storedGradient) {
      // console.log('🎨 Found stored gradient for metadata:', storedGradient)
      // Restore stored gradient
      this.controller.gradientControlPoints = storedGradient.gradientControlPoints ? 
        JSON.parse(JSON.stringify(storedGradient.gradientControlPoints)) : null
      this.controller.customGradientControlPoints = storedGradient.customGradientControlPoints ? 
        JSON.parse(JSON.stringify(storedGradient.customGradientControlPoints)) : null
      this.controller.gradientScale = storedGradient.gradientScale === 'log' ? 'log' : 'normal'
    } else {
      // No stored gradient - initialize default
      // console.log('🎨 No stored gradient found - initializing default gradient')
      this.controller.colorManager.initializeDefaultGradient()
      this.controller.gradientScale = 'normal'
      
      // Save the default gradient for this metadata
      this.saveGradientForMetadata(metadataId)
    }

    const range = this.controller.getEffectiveColorRange?.()
    if (range) {
      this.controller.ensureGradientScaleMatchesRange?.(range.min, range.max)
    } else if (this.controller.currentMetadataVector?.values) {
      const values = this.controller.currentMetadataVector.values
      const minVal = this.controller.dataManager.safeMin(values)
      const maxVal = this.controller.dataManager.safeMax(values)
      this.controller.ensureGradientScaleMatchesRange?.(minVal, maxVal)
    }
  }
  
  // Save current gradient for a specific metadata ID
  saveGradientForMetadata(metadataId) {
    if (!metadataId) {
      console.warn('🎨 ⚠️ Cannot save gradient - no metadata ID')
      return
    }
    
    // console.log('🎨 Saving gradient for metadata:', metadataId)
    
    // Store current gradient state
    const gradientState = {
      gradientControlPoints: this.controller.gradientControlPoints ? 
        JSON.parse(JSON.stringify(this.controller.gradientControlPoints)) : null,
      customGradientControlPoints: this.controller.customGradientControlPoints ? 
        JSON.parse(JSON.stringify(this.controller.customGradientControlPoints)) : null,
      gradientScale: this.controller.gradientScale === 'log' ? 'log' : 'normal'
    }
    
    this.controller.metadataGradients.set(metadataId, gradientState)
    // console.log('🎨 Saved gradient state:', gradientState)
  }

  // Get color from gradient at normalized position (0-1)
  getColorFromGradient(normalizedValue) {
    // Handle invalid values — never return 0 (regl treats 0 as transparent; falsy
    // fallbacks turn it into default blue).
    if (normalizedValue < 0 || normalizedValue > 1 || isNaN(normalizedValue)) {
      return this.controller.getMissingNumericColor()
    }
    
    // Get active gradient (custom or auto)
    const controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    if (!controlPoints || controlPoints.length === 0) {
      return this.controller.getMissingNumericColor()
    }
    
    // Sort control points by position
    const sorted = [...controlPoints].sort((a, b) => a.position - b.position)
    
    // Find the two control points to interpolate between
    let leftPoint = null
    let rightPoint = null
    
    // Check if normalizedValue exactly matches a control point
    for (let i = 0; i < sorted.length; i++) {
      const point = sorted[i]
      if (Math.abs(point.position - normalizedValue) < 0.0001) {
        // Exact match (or very close) - return this point's color directly
        return point.color
      }
      
      if (point.position <= normalizedValue) {
        leftPoint = point
      }
      if (point.position >= normalizedValue && !rightPoint) {
        rightPoint = point
        break
      }
    }
    
    // Handle edge cases
    if (!leftPoint && rightPoint) {
      return rightPoint.color
    }
    if (leftPoint && !rightPoint) {
      return leftPoint.color
    }
    if (!leftPoint && !rightPoint) {
      console.warn('getColorFromGradient: No control points found for normalizedValue', normalizedValue)
      return this.controller.getMissingNumericColor()
    }
    
    // If leftPoint and rightPoint are the same (same position), return that color directly
    if (Math.abs(leftPoint.position - rightPoint.position) < 0.0001) {
      return leftPoint.color
    }
    
    // Interpolate between the two points
    const t = (normalizedValue - leftPoint.position) / (rightPoint.position - leftPoint.position)
    
    // Clamp t to valid range to avoid NaN
    const clampedT = Math.max(0, Math.min(1, t))
    
    if (isNaN(clampedT)) {
      console.warn('🎨 ⚠️ getColorFromGradient: NaN in interpolation, normalizedValue:', normalizedValue, 'leftPoint:', leftPoint, 'rightPoint:', rightPoint)
      return leftPoint.color // Fallback to left point color
    }
    
    return this.interpolateColor(leftPoint.color, rightPoint.color, clampedT)
  }

  // Interpolate between two colors
  interpolateColor(color1, color2, t) {
    const r1 = (color1 >> 16) & 0xFF
    const g1 = (color1 >> 8) & 0xFF
    const b1 = color1 & 0xFF
    
    const r2 = (color2 >> 16) & 0xFF
    const g2 = (color2 >> 8) & 0xFF
    const b2 = color2 & 0xFF
    
    const r = Math.round(r1 + (r2 - r1) * t)
    const g = Math.round(g1 + (g2 - g1) * t)
    const b = Math.round(b1 + (b2 - b1) * t)
    
    return (r << 16) | (g << 8) | b
  }

  // Remove gradient legend listeners (when switching to categorical metadata)
  removeGradientLegendListeners() {
    if (!this.controller.overlayCanvas) {
      return
    }

    // Get the parent container where listeners were attached
    const canvasContainer = this.controller.overlayCanvas.parentElement
    if (!canvasContainer) {
      return
    }

    // Remove event listeners if they exist
    if (this.controller.gradientLegendClickListener) {
      canvasContainer.removeEventListener('click', this.controller.gradientLegendClickListener)
      this.controller.gradientLegendClickListener = null
    }
    if (this.controller.gradientLegendMouseMoveListener) {
      canvasContainer.removeEventListener('mousemove', this.controller.gradientLegendMouseMoveListener)
      this.controller.gradientLegendMouseMoveListener = null
    }
    if (this.controller.gradientLegendMouseLeaveListener) {
      canvasContainer.removeEventListener('mouseleave', this.controller.gradientLegendMouseLeaveListener)
      this.controller.gradientLegendMouseLeaveListener = null
    }

    // Clear gradient legend bounds to prevent click detection
    this.controller.gradientLegendBounds = null

    // Reset hover state
    this.controller.isHoveringGradientLegend = false
    if (this.controller.overlayCanvas) {
      this.controller.overlayCanvas.style.cursor = 'default'
    }
  }

  // Initialize gradient legend listeners
  initializeGradientLegendListeners() {
    if (!this.controller.overlayCanvas) {
      // console.log('⚠️ Cannot initialize gradient legend listeners: overlayCanvas is null')
      return
    }

    // Get the parent container to listen for events (overlay canvas has pointerEvents: 'none')
    const canvasContainer = this.controller.overlayCanvas.parentElement
    if (!canvasContainer) {
      // console.log('⚠️ Cannot find canvas container')
      return
    }

    // Remove existing listeners if any
    if (this.controller.gradientLegendClickListener) {
      canvasContainer.removeEventListener('click', this.controller.gradientLegendClickListener)
    }
    if (this.controller.gradientLegendMouseMoveListener) {
      canvasContainer.removeEventListener('mousemove', this.controller.gradientLegendMouseMoveListener)
    }
    if (this.controller.gradientLegendMouseLeaveListener) {
      canvasContainer.removeEventListener('mouseleave', this.controller.gradientLegendMouseLeaveListener)
    }

    // Add click listener to gradient legend
    this.controller.gradientLegendClickListener = (event) => {
      if (this.controller.gradientLegendBounds && this.isPointInGradientLegend(event.clientX, event.clientY)) {
        this.openGradientEditorModal()
        event.stopPropagation()
      }
    }

    // Add hover listeners for gradient legend
    this.controller.gradientLegendMouseMoveListener = (event) => {
      if (this.controller.gradientLegendBounds) {
        const isHovering = this.isPointInGradientLegend(event.clientX, event.clientY)
        if (isHovering !== this.controller.isHoveringGradientLegend) {
          this.controller.isHoveringGradientLegend = isHovering
          this.controller.overlayCanvas.style.cursor = isHovering ? 'pointer' : 'default'
          this.controller.rendererManager.renderContinuousColorLegendCanvas2D()
        }
      }
    }

    this.controller.gradientLegendMouseLeaveListener = () => {
      if (this.controller.isHoveringGradientLegend) {
        this.controller.isHoveringGradientLegend = false
        this.controller.overlayCanvas.style.cursor = 'default'
        this.controller.rendererManager.renderContinuousColorLegendCanvas2D()
      }
    }

    // Add listeners to the container, not the overlay canvas
    canvasContainer.addEventListener('click', this.controller.gradientLegendClickListener)
    canvasContainer.addEventListener('mousemove', this.controller.gradientLegendMouseMoveListener)
    canvasContainer.addEventListener('mouseleave', this.controller.gradientLegendMouseLeaveListener)

    // console.log('✅ Gradient legend listeners initialized successfully')
  }

  // Check if point is within gradient legend bounds
  isPointInGradientLegend(x, y) {
    if (!this.controller.gradientLegendBounds) return false
    
    const rect = this.controller.overlayCanvas.getBoundingClientRect()
    const relativeX = x - rect.left
    const relativeY = y - rect.top
    
    return relativeX >= this.controller.gradientLegendBounds.x &&
           relativeX <= this.controller.gradientLegendBounds.x + this.controller.gradientLegendBounds.width &&
           relativeY >= this.controller.gradientLegendBounds.y &&
           relativeY <= this.controller.gradientLegendBounds.y + this.controller.gradientLegendBounds.height
  }

  // Render gradient preview in modal
  renderModalGradientPreview() {
    const canvas = document.getElementById('gradient-editor-preview-canvas')
    if (!canvas) {
      console.warn('🎨 ⚠️ Preview canvas not found')
      return
    }
    
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    
    // Clear canvas
    ctx.clearRect(0, 0, width, height)
    
    // Get active gradient (custom or auto) - defensive check
    let controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    // console.log('🎨 renderModalGradientPreview - customGradientControlPoints:', this.controller.customGradientControlPoints)
    // console.log('🎨 renderModalGradientPreview - gradientControlPoints:', this.controller.gradientControlPoints)
    // console.log('🎨 renderModalGradientPreview - controlPoints:', controlPoints)
    // console.log('🎨 renderModalGradientPreview - controlPoints length:', controlPoints ? controlPoints.length : 0)
    
    // Safety check: if controlPoints is undefined but we had custom points, try to recover
    if (!controlPoints && this.controller.customGradientControlPoints) {
      console.warn('🎨 ⚠️ renderModalGradientPreview: controlPoints is undefined but customGradientControlPoints exists!')
      controlPoints = this.controller.customGradientControlPoints
    }
    
    if (!controlPoints || controlPoints.length === 0) {
      console.warn('🎨 ⚠️ No control points - using fallback gradient')
      // Draw a default gradient if no control points
      const gradient = ctx.createLinearGradient(0, 0, width, 0)
      gradient.addColorStop(0, '#3b82f6')
      gradient.addColorStop(1, '#ef4444')
      ctx.fillStyle = gradient
      ctx.fillRect(0, 0, width, height)
      return
    }
    
    // Sort control points by position
    const sorted = [...controlPoints].sort((a, b) => a.position - b.position)
    
    // Create linear gradient
    const gradient = ctx.createLinearGradient(0, 0, width, 0)
    
    for (const point of sorted) {
      const color = `#${point.color.toString(16).padStart(6, '0')}`
      gradient.addColorStop(point.position, color)
    }
    
    ctx.fillStyle = gradient
    ctx.fillRect(0, 0, width, height)
  }

  formatGradientEditorValue(value) {
    if (!Number.isFinite(value)) return 'n/a'
    const abs = Math.abs(value)
    if (abs !== 0 && (abs < 0.001 || abs >= 10000)) {
      return value.toExponential(2)
    }
    if (Number.isInteger(value)) return String(value)
    return value.toFixed(Math.abs(value) >= 100 ? 1 : 3)
  }

  colorIntToCss(colorInt) {
    const n = (colorInt >>> 0) & 0xffffff
    return `#${n.toString(16).padStart(6, '0')}`
  }

  getGradientEditorHistogramValues() {
    const vector = this.controller.currentMetadataVector
    if (!vector?.values || vector.data_type !== 'NUMERIC') return []

    const filteredIndices = this.controller.dataManager?.getIncrementalFilteredIndices?.()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const values = []
    for (let i = 0; i < vector.values.length; i++) {
      if (filteredSet && !filteredSet.has(i)) continue
      const v = vector.values[i]
      if (typeof v === 'number' && Number.isFinite(v)) {
        values.push(v)
      }
    }
    return values
  }

  getGradientEditorRange() {
    const effectiveRange = this.controller.getEffectiveColorRange?.()
    if (effectiveRange && Number.isFinite(effectiveRange.min) && Number.isFinite(effectiveRange.max)) {
      return { min: effectiveRange.min, max: effectiveRange.max }
    }
    const min = this.controller.gradientMinValue
    const max = this.controller.gradientMaxValue
    if (Number.isFinite(min) && Number.isFinite(max)) {
      return { min, max }
    }
    return null
  }

  // Colored histogram under the gradient preview (same value axis / scale as coloring).
  renderGradientDistributionHistogram() {
    const canvas = document.getElementById('gradient-editor-histogram-canvas')
    if (!canvas) return

    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    ctx.clearRect(0, 0, width, height)
    ctx.fillStyle = '#f9fafb'
    ctx.fillRect(0, 0, width, height)

    const range = this.getGradientEditorRange()
    const minLabel = document.getElementById('gradient-editor-hist-min')
    const maxLabel = document.getElementById('gradient-editor-hist-max')
    if (!range || !(range.max > range.min)) {
      this._gradientHistogramBins = []
      if (minLabel) minLabel.textContent = ''
      if (maxLabel) maxLabel.textContent = ''
      ctx.fillStyle = '#9ca3af'
      ctx.font = '12px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('No numeric range available', width / 2, height / 2)
      return
    }

    if (minLabel) minLabel.textContent = this.formatGradientEditorValue(range.min)
    if (maxLabel) maxLabel.textContent = this.formatGradientEditorValue(range.max)

    const values = this.getGradientEditorHistogramValues()
    const numBins = 40
    const scale = this.controller.getEffectiveGradientScale(range.min, range.max)
    const { bins, maxCount, binRanges } = this.controller.buildHistogramBins(
      values,
      range.min,
      range.max,
      numBins,
      { scale, ignoreZeros: scale === 'log' }
    )

    const binMeta = []
    const denom = maxCount > 0 ? maxCount : 1
    const barGap = 1
    const barWidth = width / numBins

    for (let i = 0; i < numBins; i++) {
      const count = bins[i] || 0
      const start = binRanges[i]?.min
      const end = binRanges[i]?.max
      const useLog = scale === 'log'
      const center = useLog && start > 0 && end > 0
        ? Math.sqrt(start * end)
        : (start + end) / 2
      const position = this.controller.valueToGradientPosition(center, range.min, range.max)
      const colorInt = this.getColorFromGradient(position)
      const colorCss = this.colorIntToCss(colorInt)
      const barHeight = (count / denom) * (height - 4)
      const x = i * barWidth
      const y = height - barHeight

      ctx.fillStyle = colorCss
      ctx.fillRect(x, y, Math.max(1, barWidth - barGap), barHeight)

      binMeta.push({
        index: i,
        start,
        end,
        center,
        count,
        position,
        color: colorCss,
        x0: x / width,
        x1: (x + barWidth) / width
      })
    }

    this._gradientHistogramBins = binMeta
  }

  findGradientHistogramBinAtFraction(fraction) {
    const bins = this._gradientHistogramBins || []
    if (bins.length === 0) return null
    const t = Math.min(1, Math.max(0, fraction))
    const index = Math.min(bins.length - 1, Math.floor(t * bins.length))
    return bins[index] || null
  }

  ensureGradientEditorHoverTooltip() {
    let tooltip = document.getElementById('gradient-editor-hover-tooltip')
    if (!tooltip) {
      tooltip = document.createElement('div')
      tooltip.id = 'gradient-editor-hover-tooltip'
      tooltip.style.cssText = `
        display: none; position: fixed; z-index: 12050; pointer-events: none;
        background: rgba(17, 24, 39, 0.95); color: white; padding: 8px 10px;
        border-radius: 6px; font-size: 12px; line-height: 1.4;
        box-shadow: 0 4px 12px rgba(0,0,0,0.25); white-space: nowrap;
      `
      document.body.appendChild(tooltip)
    }
    return tooltip
  }

  setGradientEditorHoverLine(fraction) {
    const line = document.getElementById('gradient-editor-hover-line')
    if (!line) return
    const t = Math.min(1, Math.max(0, fraction))
    line.style.display = 'block'
    line.style.left = `${t * 100}%`
  }

  clearGradientEditorHover() {
    const line = document.getElementById('gradient-editor-hover-line')
    if (line) line.style.display = 'none'
    const tooltip = document.getElementById('gradient-editor-hover-tooltip')
    if (tooltip) tooltip.style.display = 'none'
    const hadHover = this._gradientHistogramHoverIndex !== null && this._gradientHistogramHoverIndex !== undefined
    this._gradientHistogramHoverIndex = null
    if (hadHover) {
      this.renderGradientDistributionHistogram()
    }
  }

  handleGradientEditorHover(event) {
    const wrap = document.getElementById('gradient-editor-preview-wrap')
    if (!wrap) return
    const rect = wrap.getBoundingClientRect()
    if (rect.width <= 0) return

    const fraction = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width))
    const range = this.getGradientEditorRange()
    if (!range) {
      this.clearGradientEditorHover()
      return
    }

    // Keep controller min/max aligned so position <-> value conversion matches the histogram axis
    this.controller.gradientMinValue = range.min
    this.controller.gradientMaxValue = range.max

    const value = this.controller.positionToActualValue(fraction)
    const colorInt = this.getColorFromGradient(fraction)
    const colorCss = this.colorIntToCss(colorInt)
    const bin = this.findGradientHistogramBinAtFraction(fraction)

    this.setGradientEditorHoverLine(fraction)

    if (bin && bin.index !== this._gradientHistogramHoverIndex) {
      this._gradientHistogramHoverIndex = bin.index
      this.renderGradientDistributionHistogram()
      this.drawGradientHistogramHoverOverlay(bin.index)
    }

    const tooltip = this.ensureGradientEditorHoverTooltip()
    const scaleLabel = this.controller.getEffectiveGradientScale(range.min, range.max) === 'log' ? 'log10' : 'linear'
    let html = `<div style="display:flex;align-items:center;gap:8px;">`
    html += `<span style="display:inline-block;width:12px;height:12px;border-radius:2px;background:${colorCss};border:1px solid rgba(255,255,255,0.35);"></span>`
    html += `<span>Value: <strong>${this.formatGradientEditorValue(value)}</strong> (${scaleLabel})</span>`
    html += `</div>`
    if (bin) {
      html += `<div style="margin-top:4px;color:#d1d5db;">`
      html += `Bin: ${this.formatGradientEditorValue(bin.start)} – ${this.formatGradientEditorValue(bin.end)}`
      html += ` · ${bin.count.toLocaleString()} values`
      html += `</div>`
    }
    tooltip.innerHTML = html
    tooltip.style.display = 'block'

    const tipWidth = tooltip.offsetWidth || 180
    const tipHeight = tooltip.offsetHeight || 40
    let left = event.clientX + 12
    let top = event.clientY + 12
    if (left + tipWidth > window.innerWidth - 8) left = event.clientX - tipWidth - 12
    if (top + tipHeight > window.innerHeight - 8) top = event.clientY - tipHeight - 12
    tooltip.style.left = `${Math.max(8, left)}px`
    tooltip.style.top = `${Math.max(8, top)}px`
  }

  drawGradientHistogramHoverOverlay(binIndex) {
    const canvas = document.getElementById('gradient-editor-histogram-canvas')
    const bins = this._gradientHistogramBins || []
    const bin = bins[binIndex]
    if (!canvas || !bin) return
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    const barWidth = width / bins.length
    ctx.fillStyle = 'rgba(255, 255, 255, 0.28)'
    ctx.fillRect(binIndex * barWidth, 0, barWidth, height)
    ctx.strokeStyle = 'rgba(17, 24, 39, 0.7)'
    ctx.lineWidth = 1
    ctx.strokeRect(binIndex * barWidth + 0.5, 0.5, Math.max(1, barWidth - 1), height - 1)
  }
  
  // Render control point markers on the gradient bar in modal
  renderModalControlPointMarkers() {
    // Don't re-render markers if we're currently dragging one
    // This prevents the marker from jumping during drag
    if (this.isDraggingControlPoint) {
      return
    }
    
    const container = document.getElementById('gradient-editor-control-points')
    if (!container) {
      console.warn('🎨 ⚠️ Control points container not found')
      return
    }
    
    // Clear existing markers
    container.innerHTML = ''
    
    // Get active gradient (custom or auto) - defensive check
    let controlPoints = this.controller.customGradientControlPoints || this.controller.gradientControlPoints
    // console.log('🎨 renderModalControlPointMarkers - customGradientControlPoints:', this.controller.customGradientControlPoints)
    // console.log('🎨 renderModalControlPointMarkers - gradientControlPoints:', this.controller.gradientControlPoints)
    // console.log('🎨 renderModalControlPointMarkers - controlPoints:', controlPoints)
    // console.log('🎨 renderModalControlPointMarkers - controlPoints length:', controlPoints ? controlPoints.length : 0)
    
    // Safety check: if controlPoints is undefined but we had custom points, try to recover
    if (!controlPoints && this.controller.customGradientControlPoints) {
      console.warn('🎨 ⚠️ renderModalControlPointMarkers: controlPoints is undefined but customGradientControlPoints exists!')
      controlPoints = this.controller.customGradientControlPoints
    }
    
    if (!controlPoints || controlPoints.length === 0) {
      console.warn('🎨 ⚠️ No control points to render')
      return
    }
    
    const canvas = document.getElementById('gradient-editor-preview-canvas')
    if (!canvas) return
    
    // Use getBoundingClientRect for more accurate width, especially when layout is still settling
    // Try multiple methods to get canvas width - getBoundingClientRect can return 0 if not fully laid out
    const canvasRect = canvas.getBoundingClientRect()
    const canvasWidth = canvasRect.width || canvas.offsetWidth || canvas.clientWidth || canvas.width
    const selectedIndex = this.controller.selectedControlPointIndex
    
    // Create a marker for each control point
    controlPoints.forEach((point, index) => {
      const marker = document.createElement('div')
      const isSelected = selectedIndex === index
      const markerSize = isSelected ? 20 : 16
      const borderWidth = isSelected ? 3 : 2
      const borderColor = isSelected ? '#3b82f6' : 'white'
      const x = point.position * canvasWidth - (markerSize / 2)
      
      marker.style.cssText = `
        position: absolute;
        left: ${x}px;
        top: 50%;
        transform: translateY(-50%);
        width: ${markerSize}px;
        height: ${markerSize}px;
        border: ${borderWidth}px solid ${borderColor};
        border-radius: 50%;
        background-color: #${point.color.toString(16).padStart(6, '0')};
        box-shadow: 0 2px 6px rgba(0,0,0,${isSelected ? '0.5' : '0.3'});
        cursor: grab;
        pointer-events: all;
        transition: transform 0.2s, box-shadow 0.2s;
        z-index: ${isSelected ? 10 : 1};
      `
      
      marker.addEventListener('mouseenter', () => {
        if (!isSelected) {
          marker.style.transform = 'translateY(-50%) scale(1.3)'
        }
      })
      
      marker.addEventListener('mouseleave', () => {
        if (!isSelected) {
          marker.style.transform = 'translateY(-50%) scale(1)'
        }
      })
      
      // Add drag functionality
      let isDragging = false
      let dragStartMouseX = 0
      let dragStartMarkerCenterX = 0
      let dragStartPosition = 0
      let dragStartColor = point.color
      let hasMoved = false
      const DRAG_THRESHOLD = 3 // pixels of movement before considering it a drag
      
      const startDrag = (e) => {
        // Don't start drag if clicking on delete button
        if (e.target !== marker && e.target.closest('div[style*="background-color: #dc2626"]')) {
          return
        }
        
        isDragging = true
        hasMoved = false
        this.isDraggingControlPoint = true // Set flag to prevent marker re-rendering
        
        // Store the control point's position and color first
        dragStartPosition = point.position
        dragStartColor = point.color
        
        // Get the actual mouse position relative to the canvas
        const rect = canvas.getBoundingClientRect()
        // Try multiple methods to get canvas width - getBoundingClientRect can return 0 if not fully laid out
        const canvasWidth = rect.width || canvas.offsetWidth || canvas.clientWidth || canvas.width
        dragStartMouseX = (e.clientX || e.touches[0].clientX) - rect.left
        
        // If canvas width is 0, we can't calculate positions correctly
        // In this case, use the mouse position directly and calculate from control point
        if (canvasWidth === 0) {
          console.warn('🎨 WARNING: Canvas width is 0 at drag start!', {
            rectWidth: rect.width,
            offsetWidth: canvas.offsetWidth,
            clientWidth: canvas.clientWidth,
            width: canvas.width,
            rect: rect
          })
          // Use mouse position as marker center (approximation)
          dragStartMarkerCenterX = dragStartMouseX
        } else {
          // Get the marker's ACTUAL current visual position (not calculated from data)
          // This prevents jumps if there's any mismatch
          const markerRect = marker.getBoundingClientRect()
          const containerElement = document.getElementById('gradient-editor-control-points')
          if (containerElement) {
            const containerRect = containerElement.getBoundingClientRect()
            const actualMarkerCenterX = markerRect.left + (markerRect.width / 2) - containerRect.left
            // Use the actual visual position as the starting point
            dragStartMarkerCenterX = actualMarkerCenterX
          } else {
            // Fallback: calculate from control point position
            dragStartMarkerCenterX = dragStartPosition * canvasWidth
          }
        }
        
        // console.log('🎨 DRAG START:', {
          // controlPointIndex: index,
          // dragStartPosition: dragStartPosition,
          // dragStartColor: dragStartColor,
          // canvasWidth: canvasWidth,
          // dragStartMouseX: dragStartMouseX,
          // dragStartMarkerCenterX: dragStartMarkerCenterX,
          // markerLeft: marker.style.left,
          // calculatedFromPosition: dragStartPosition * canvasWidth
        // })
        
        // Don't prevent default yet - wait until we know it's a drag
        // This allows click events to work if user just clicks without dragging
        e.stopPropagation()
        
        // Change cursor to indicate draggability
        marker.style.cursor = 'grabbing'
        document.body.style.cursor = 'grabbing'
      }
      
      marker.addEventListener('click', (e) => {
        // Only select if we didn't drag (or moved less than threshold)
        if (!hasMoved) {
          e.stopPropagation()
          e.preventDefault()
          this.selectControlPoint(index)
        }
      })
      
      const doDrag = (e) => {
        if (!isDragging) return
        
        const rect = canvas.getBoundingClientRect()
        const currentMouseX = (e.clientX || e.touches[0].clientX) - rect.left
        const mouseDeltaX = Math.abs(currentMouseX - dragStartMouseX)
        
        // Only consider it a drag if moved more than threshold
        if (mouseDeltaX > DRAG_THRESHOLD) {
          if (!hasMoved) {
            // First time crossing threshold - now prevent default and disable transitions
            hasMoved = true
            e.preventDefault()
            marker.style.transition = 'none'
            document.body.style.userSelect = 'none'
          }
        } else {
          // Still too small to be a drag, don't update position yet
          return
        }
        
        // Calculate the new marker center position
        // The marker center moves by the same amount as the mouse
        const mouseMovement = currentMouseX - dragStartMouseX
        const newMarkerCenterX = dragStartMarkerCenterX + mouseMovement
        
        // Use getBoundingClientRect for more accurate width
        // Try multiple methods to get canvas width - getBoundingClientRect can return 0 if not fully laid out
        const canvasRect = canvas.getBoundingClientRect()
        const canvasWidth = canvasRect.width || canvas.offsetWidth || canvas.clientWidth || canvas.width
        
        // Prevent division by zero - if canvas width is still 0, abort this drag update
        if (canvasWidth === 0) {
          console.warn('🎨 DRAG MOVE: Canvas width is 0, skipping update')
          return
        }
        
        // Convert marker center position to normalized position (0-1)
        const rawPosition = newMarkerCenterX / canvasWidth
        const newPosition = Math.max(0, Math.min(1, rawPosition))
        
        // console.log('🎨 DRAG MOVE:', {
          // currentMouseX: currentMouseX,
          // dragStartMouseX: dragStartMouseX,
          // mouseMovement: mouseMovement,
          // dragStartMarkerCenterX: dragStartMarkerCenterX,
          // newMarkerCenterX: newMarkerCenterX,
          // canvasWidth: canvasWidth,
          // rawPosition: rawPosition,
          // newPosition: newPosition,
          // clamped: rawPosition !== newPosition
        // })
        
        // Ensure we have custom gradient
        if (!this.controller.customGradientControlPoints) {
          this.controller.customGradientControlPoints = this.controller.gradientControlPoints 
            ? [...this.controller.gradientControlPoints] 
            : []
        }
        
        // Find the control point by color (should be unique)
        const controlPoints = this.controller.customGradientControlPoints
        const targetPoint = controlPoints.find(p => p.color === dragStartColor)
        
        if (targetPoint) {
          const oldPosition = targetPoint.position
          targetPoint.position = newPosition
          
          // console.log('🎨 DRAG UPDATE:', {
            // foundPoint: !!targetPoint,
            // oldPosition: oldPosition,
            // newPosition: newPosition,
            // positionChange: newPosition - oldPosition
          // })
          
          // Update marker position visually
          const markerSize = isSelected ? 20 : 16
          const newX = newPosition * canvasWidth - (markerSize / 2)
          marker.style.left = `${newX}px`
          
          // console.log('🎨 DRAG VISUAL:', {
            // markerSize: markerSize,
            // calculatedNewX: newX,
            // newLeftStyle: marker.style.left
          // })
          
          // Update position input if this point is selected
          if (isSelected) {
            const positionInput = document.getElementById('gradient-control-point-position')
            if (positionInput) {
              const actualValue = this.controller.positionToActualValue(newPosition)
              positionInput.value = actualValue.toFixed(3)
            }
          }
          
          // Update gradient preview in real-time
          this.controller.rendererManager.renderModalGradientPreview()
        } else {
          console.warn('🎨 DRAG ERROR: Target point not found!', {
            dragStartColor: dragStartColor,
            controlPoints: controlPoints.map(p => ({ color: p.color, position: p.position }))
          })
        }
      }
      
      const endDrag = (e) => {
        if (!isDragging) return
        
        const wasDragging = hasMoved
        isDragging = false
        this.isDraggingControlPoint = false // Clear flag to allow marker re-rendering
        marker.style.cursor = 'grab'
        marker.style.transition = 'transform 0.2s, box-shadow 0.2s'
        document.body.style.cursor = ''
        document.body.style.userSelect = ''
        
        // If we didn't actually drag, don't do any updates
        // The click handler will take care of opening the editor
        if (!wasDragging) {
          hasMoved = false
          return
        }
        
        // Ensure we have custom gradient
        if (!this.controller.customGradientControlPoints) {
          this.controller.customGradientControlPoints = this.controller.gradientControlPoints 
            ? [...this.controller.gradientControlPoints] 
            : []
        }
        
        const controlPoints = this.controller.customGradientControlPoints
        
        // Find the dragged point by color (more reliable than index)
        const draggedPoint = controlPoints.find(p => p.color === dragStartColor)
        
        if (draggedPoint) {
          // Sort control points by position
          controlPoints.sort((a, b) => a.position - b.position)
          
          // Find new index after sorting
          const newIndex = controlPoints.findIndex(p => 
            p.color === dragStartColor
          )
          
          if (newIndex >= 0) {
            // Update selected index if this was the selected point
            if (this.controller.selectedControlPointIndex !== undefined) {
              const wasSelected = this.controller.selectedControlPointIndex === index
              if (wasSelected || controlPoints[this.controller.selectedControlPointIndex]?.color === dragStartColor) {
                this.controller.selectedControlPointIndex = newIndex
              }
            }
          }
          
          // Re-render markers to update positions
          this.renderModalControlPointMarkers()
          
          // Update gradient display
          this.updateGradientDisplay()
        }
      }
      
      // Mouse events
      marker.addEventListener('mousedown', startDrag)
      document.addEventListener('mousemove', doDrag)
      document.addEventListener('mouseup', endDrag)
      
      // Touch events
      marker.addEventListener('touchstart', startDrag, { passive: false })
      document.addEventListener('touchmove', doDrag, { passive: false })
      document.addEventListener('touchend', endDrag)
      
      // Add delete button for selected marker
      if (isSelected && controlPoints.length > 2) {
        const deleteBtn = document.createElement('div')
        deleteBtn.innerHTML = '×'
        deleteBtn.style.cssText = `
          position: absolute;
          top: -8px;
          right: -8px;
          width: 18px;
          height: 18px;
          background-color: #dc2626;
          color: white;
          border-radius: 50%;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 14px;
          font-weight: bold;
          cursor: pointer;
          box-shadow: 0 2px 4px rgba(0,0,0,0.3);
          pointer-events: all;
          z-index: 20;
        `
        deleteBtn.addEventListener('click', (e) => {
          e.stopPropagation()
          e.preventDefault()
          this.removeControlPoint(index)
        })
        deleteBtn.addEventListener('mouseenter', () => {
          deleteBtn.style.backgroundColor = '#b91c1c'
          deleteBtn.style.transform = 'scale(1.1)'
        })
        deleteBtn.addEventListener('mouseleave', () => {
          deleteBtn.style.backgroundColor = '#dc2626'
          deleteBtn.style.transform = 'scale(1)'
        })
        marker.appendChild(deleteBtn)
      }
      
      container.appendChild(marker)
    })
  }
  
  // Render list of control points (now just updates markers, list UI removed for simplicity)
  renderControlPointsList() {
    // UI simplified - control points list removed
    // Control points are now only visible on the gradient bar and in the editor
    // This method is kept for backward compatibility but does nothing
  }
}
