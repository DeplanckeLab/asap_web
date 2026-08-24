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
    this.lastPlotExportData = null
    this.is2DPlotMinimized = false
    this.previous2DPlotWindowState = null
    this.hasInitialized2DPlotWindowSize = false
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

  isPlotVisible() {
    const modal = document.getElementById('2d-plot-modal')
    if (!modal) {
      return false
    }

    const style = window.getComputedStyle(modal)
    if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) {
      return false
    }

    const canvas = document.getElementById('2d-plot-canvas')
    return !!canvas
  }

  getActivePlotCanvas() {
    if (!this.isPlotVisible()) {
      return null
    }
    const canvas = document.getElementById('2d-plot-canvas')
    if (!canvas || canvas.width === 0 || canvas.height === 0) {
      return null
    }
    return canvas
  }

  savePlotAsPNG() {
    const canvas = this.getActivePlotCanvas()
    if (!canvas) {
      alert('No custom plot available to save')
      return false
    }

    try {
      const dataUrl = canvas.toDataURL('image/png')
      this.controller.downloadDataUrl(dataUrl, 'custom-plot.png')
      return true
    } catch (error) {
      console.error('Error saving custom plot PNG:', error)
      alert('Error saving custom plot PNG')
      return false
    }
  }

  savePlotAsSVG() {
    const canvas = this.getActivePlotCanvas()
    if (!canvas) {
      alert('No custom plot available to save')
      return false
    }

    const exportData = this.lastPlotExportData

    if (!exportData) {
      console.warn('No vector export data available for custom plot, using raster fallback.')
      return this.savePlotAsSVGRasterFallback(canvas)
    }

    try {
      let svgContent
      if (exportData.type === 'scatter') {
        svgContent = this.generateScatterPlotSVG(exportData)
      } else if (exportData.type === 'violin') {
        svgContent = this.generateViolinPlotSVG(exportData)
      } else {
        console.warn(`Unknown custom plot export type "${exportData.type}", using raster fallback.`)
        return this.savePlotAsSVGRasterFallback(canvas)
      }

      this.controller.downloadSVG(svgContent, 'custom-plot.svg')
      return true
    } catch (error) {
      console.error('Error saving custom plot SVG:', error)
      alert('Error saving custom plot SVG')
      return this.savePlotAsSVGRasterFallback(canvas)
    }
  }

  savePlotAsSVGRasterFallback(canvas) {
    try {
      const rect = canvas.getBoundingClientRect()
      const width = canvas.width || rect.width || 800
      const height = canvas.height || rect.height || 600
      const pngDataUrl = canvas.toDataURL('image/png')
      const svgContent = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><image href="${pngDataUrl}" width="${width}" height="${height}" preserveAspectRatio="xMidYMid meet"/></svg>`
      this.controller.downloadSVG(svgContent, 'custom-plot.svg')
      return true
    } catch (error) {
      console.error('Error generating raster SVG fallback for custom plot:', error)
      return false
    }
  }

  generateScatterPlotSVG(data) {
    const width = data.width || 800
    const height = data.height || 600
    const background = data.background || '#ffffff'
    const parts = []
    const format = (value) => (Number.isFinite(value) ? Number(value).toFixed(2) : '0')

    parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`)
    parts.push(`<rect width="${width}" height="${height}" fill="${background}"/>`)

    const vertical = data.grid?.vertical
    if (vertical?.positions?.length) {
      const top = Number.isFinite(vertical.top) ? vertical.top : 0
      const bottom = Number.isFinite(vertical.bottom) ? vertical.bottom : height
      const color = vertical.color || 'rgba(204, 204, 204, 0.3)'
      vertical.positions.forEach((x) => {
        parts.push(`<line x1="${format(x)}" y1="${format(top)}" x2="${format(x)}" y2="${format(bottom)}" stroke="${color}" stroke-width="1" stroke-dasharray="2,2"/>`)
      })
    }

    const horizontal = data.grid?.horizontal
    if (horizontal?.positions?.length) {
      const left = Number.isFinite(horizontal.left) ? horizontal.left : 0
      const right = Number.isFinite(horizontal.right) ? horizontal.right : width
      const color = horizontal.color || 'rgba(204, 204, 204, 0.3)'
      horizontal.positions.forEach((y) => {
        parts.push(`<line x1="${format(left)}" y1="${format(y)}" x2="${format(right)}" y2="${format(y)}" stroke="${color}" stroke-width="1" stroke-dasharray="2,2"/>`)
      })
    }

    const axes = data.axes || {}
    const axisColor = axes.color || '#d1d5db'
    const axisX = axes.x
    if (axisX?.line) {
      const y = Number.isFinite(axisX.line.y) ? axisX.line.y : height
      const x1 = Number.isFinite(axisX.line.x1) ? axisX.line.x1 : 0
      const x2 = Number.isFinite(axisX.line.x2) ? axisX.line.x2 : width
      parts.push(`<line x1="${format(x1)}" y1="${format(y)}" x2="${format(x2)}" y2="${format(y)}" stroke="${axisColor}" stroke-width="1"/>`)
    }

    const axisY = axes.y
    if (axisY?.line) {
      const x = Number.isFinite(axisY.line.x1) ? axisY.line.x1 : axisY.axisX || 0
      const y1 = Number.isFinite(axisY.line.y1) ? axisY.line.y1 : 0
      const y2 = Number.isFinite(axisY.line.y2) ? axisY.line.y2 : height
      parts.push(`<line x1="${format(x)}" y1="${format(y1)}" x2="${format(x)}" y2="${format(y2)}" stroke="${axisColor}" stroke-width="1"/>`)
    }

    if (axisX?.ticks?.length) {
      const axisYPos = Number.isFinite(axisX.axisY) ? axisX.axisY : height
      const tickLength = axisX.tickLength || 5
      const labelOffset = axisX.tickLabelOffset || 8
      const fontSize = axisX.tickFontSize || 11
      axisX.ticks.forEach((tick) => {
        const x = Number.isFinite(tick.x) ? tick.x : null
        if (x === null) return
        parts.push(`<line x1="${format(x)}" y1="${format(axisYPos)}" x2="${format(x)}" y2="${format(axisYPos + tickLength)}" stroke="${axisColor}" stroke-width="1"/>`)
        const label = this.escapeXML(tick.label ?? tick.value)
        parts.push(`<text x="${format(x)}" y="${format(axisYPos + labelOffset)}" font-family="Arial, sans-serif" font-size="${fontSize}" fill="#374151" text-anchor="middle" dominant-baseline="hanging" alignment-baseline="hanging">${label}</text>`)
      })
    }

    if (axisY?.ticks?.length) {
      const axisXPos = Number.isFinite(axisY.axisX) ? axisY.axisX : 0
      const tickLength = axisY.tickLength || 5
      const labelOffset = axisY.tickLabelOffset || 8
      const fontSize = axisY.tickFontSize || 11
      axisY.ticks.forEach((tick) => {
        const y = Number.isFinite(tick.y) ? tick.y : null
        if (y === null) return
        parts.push(`<line x1="${format(axisXPos)}" y1="${format(y)}" x2="${format(axisXPos - tickLength)}" y2="${format(y)}" stroke="${axisColor}" stroke-width="1"/>`)
        const label = this.escapeXML(tick.label ?? tick.value)
        parts.push(`<text x="${format(axisXPos - labelOffset)}" y="${format(y)}" font-family="Arial, sans-serif" font-size="${fontSize}" fill="#374151" text-anchor="end" dominant-baseline="central" alignment-baseline="central">${label}</text>`)
      })
    }

    if (axisX?.label?.lines?.length) {
      const baseY = Number.isFinite(axisX.label.baseY) ? axisX.label.baseY : height + 20
      const lineSpacing = axisX.label.lineSpacing || 16
      const fontSize = axisX.label.fontSize || 13
      const xCenter = Number.isFinite(axisX.label.x) ? axisX.label.x : width / 2
      axisX.label.lines.forEach((line, index) => {
        const label = this.escapeXML(line)
        const y = baseY + index * lineSpacing
        parts.push(`<text x="${format(xCenter)}" y="${format(y)}" font-family="Arial, sans-serif" font-size="${fontSize}" fill="#374151" text-anchor="middle" dominant-baseline="hanging" alignment-baseline="hanging">${label}</text>`)
      })
    }

    if (axisY?.label?.lines?.length) {
      const translateX = Number.isFinite(axisY.label.translateX) ? axisY.label.translateX : 15
      const translateY = Number.isFinite(axisY.label.translateY) ? axisY.label.translateY : height / 2
      const lineSpacing = axisY.label.lineSpacing || 16
      const fontSize = axisY.label.fontSize || 13
      parts.push(`<g transform="translate(${format(translateX)}, ${format(translateY)}) rotate(-90)">`)
      axisY.label.lines.forEach((line, index) => {
        const label = this.escapeXML(line)
        const y = index * lineSpacing
        parts.push(`<text x="0" y="${format(y)}" font-family="Arial, sans-serif" font-size="${fontSize}" fill="#374151" text-anchor="middle">${label}</text>`)
      })
      parts.push(`</g>`)
    }

    if (Array.isArray(data.points)) {
      data.points.forEach((point) => {
        const x = Number.isFinite(point.x) ? point.x : null
        const y = Number.isFinite(point.y) ? point.y : null
        if (x === null || y === null) return
        const radius = Number.isFinite(point.radius) ? point.radius : 2
        const color = point.color || '#3b82f6'
        parts.push(`<circle cx="${format(x)}" cy="${format(y)}" r="${format(radius)}" fill="${color}"/>`)
      })
    }

    parts.push(`</svg>`)
    return parts.join('')
  }

  generateViolinPlotSVG(data) {
    const width = data.width || 800
    const height = data.height || 600
    const background = data.background || '#ffffff'
    const parts = []
    const format = (value) => (Number.isFinite(value) ? Number(value).toFixed(2) : '0')

    const yScale = data.yScale || {}
    const yMin = Number.isFinite(yScale.min) ? yScale.min : 0
    const yMax = Number.isFinite(yScale.max) ? yScale.max : 1
    const topPadding = Number.isFinite(yScale.topPadding) ? yScale.topPadding : 60
    const bottomPadding = Number.isFinite(yScale.bottomPadding) ? yScale.bottomPadding : 60
    const range = yMax - yMin || (yScale.range || 1)
    const scaleY = (value) => {
      const safeRange = range === 0 ? 1 : range
      return height - bottomPadding - ((value - yMin) / safeRange) * (height - topPadding - bottomPadding)
    }

    parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`)
    parts.push(`<rect width="${width}" height="${height}" fill="${background}"/>`)

    const horizontal = data.grid?.horizontal
    if (horizontal?.positions?.length) {
      const left = Number.isFinite(horizontal.left) ? horizontal.left : 0
      const right = Number.isFinite(horizontal.right) ? horizontal.right : width
      const color = horizontal.color || 'rgba(204, 204, 204, 0.3)'
      horizontal.positions.forEach((y) => {
        parts.push(`<line x1="${format(left)}" y1="${format(y)}" x2="${format(right)}" y2="${format(y)}" stroke="${color}" stroke-width="1" stroke-dasharray="2,2"/>`)
      })
    }

    const axes = data.axes || {}
    const axisColor = axes.color || '#d1d5db'
    const axisX = axes.x
    if (axisX?.line) {
      const y = Number.isFinite(axisX.line.y) ? axisX.line.y : height - bottomPadding
      const x1 = Number.isFinite(axisX.line.x1) ? axisX.line.x1 : 0
      const x2 = Number.isFinite(axisX.line.x2) ? axisX.line.x2 : width
      parts.push(`<line x1="${format(x1)}" y1="${format(y)}" x2="${format(x2)}" y2="${format(y)}" stroke="${axisColor}" stroke-width="1"/>`)
    }

    const axisY = axes.y
    const axisXPos = Number.isFinite(axisY?.axisX) ? axisY.axisX : 0
    if (axisY?.line) {
      const y1 = Number.isFinite(axisY.line.y1) ? axisY.line.y1 : topPadding
      const y2 = Number.isFinite(axisY.line.y2) ? axisY.line.y2 : height - bottomPadding
      parts.push(`<line x1="${format(axisXPos)}" y1="${format(y1)}" x2="${format(axisXPos)}" y2="${format(y2)}" stroke="${axisColor}" stroke-width="1"/>`)
    }

    if (axisY?.ticks?.length) {
      const tickLength = axisY.tickLength || 5
      const labelOffset = axisY.tickLabelOffset || 8
      const fontSize = axisY.tickFontSize || 11
      axisY.ticks.forEach((tick) => {
        const y = Number.isFinite(tick.y) ? tick.y : null
        if (y === null) return
        parts.push(`<line x1="${format(axisXPos)}" y1="${format(y)}" x2="${format(axisXPos - tickLength)}" y2="${format(y)}" stroke="${axisColor}" stroke-width="1"/>`)
        const label = this.escapeXML(tick.label ?? tick.value)
        parts.push(`<text x="${format(axisXPos - labelOffset)}" y="${format(y)}" font-family="Arial, sans-serif" font-size="${fontSize}" fill="#374151" text-anchor="end" dominant-baseline="central" alignment-baseline="central">${label}</text>`)
      })
    }

    if (axisX?.label?.lines?.length) {
      const baseY = Number.isFinite(axisX.label.baseY) ? axisX.label.baseY : height - bottomPadding + 20
      const lineSpacing = axisX.label.lineSpacing || 16
      const fontSize = axisX.label.fontSize || 13
      const xCenter = Number.isFinite(axisX.label.x) ? axisX.label.x : width / 2
      axisX.label.lines.forEach((line, index) => {
        const label = this.escapeXML(line)
        const y = baseY + index * lineSpacing
        parts.push(`<text x="${format(xCenter)}" y="${format(y)}" font-family="Arial, sans-serif" font-size="${fontSize}" fill="#374151" text-anchor="middle" dominant-baseline="hanging" alignment-baseline="hanging">${label}</text>`)
      })
    }

    if (axisY?.label?.lines?.length) {
      const translateX = Number.isFinite(axisY.label.translateX) ? axisY.label.translateX : 15
      const translateY = Number.isFinite(axisY.label.translateY) ? axisY.label.translateY : height / 2
      const lineSpacing = axisY.label.lineSpacing || 16
      const fontSize = axisY.label.fontSize || 13
      parts.push(`<g transform="translate(${format(translateX)}, ${format(translateY)}) rotate(-90)">`)
      axisY.label.lines.forEach((line, index) => {
        const label = this.escapeXML(line)
        const y = index * lineSpacing
        parts.push(`<text x="0" y="${format(y)}" font-family="Arial, sans-serif" font-size="${fontSize}" fill="#374151" text-anchor="middle">${label}</text>`)
      })
      parts.push(`</g>`)
    }

    const categories = Array.isArray(data.categories) ? data.categories : []
    categories.forEach((category) => {
      const centerX = Number.isFinite(category.centerX) ? category.centerX : null
      const violinWidth = Number.isFinite(category.violinWidth) ? category.violinWidth : data.layout?.violinWidth || 0
      const maxDensity = Number.isFinite(category.maxDensity) && category.maxDensity > 0 ? category.maxDensity : 1
      const density = Array.isArray(category.density) ? category.density : []
      if (centerX !== null && violinWidth && density.length > 0) {
        const pathParts = []
        density.forEach((point, index) => {
          const offset = (Number(point.density) / maxDensity) * (violinWidth / 2)
          const x = centerX + offset
          const y = scaleY(point.value)
          pathParts.push(`${index === 0 ? 'M' : 'L'}${format(x)} ${format(y)}`)
        })
        for (let i = density.length - 1; i >= 0; i--) {
          const point = density[i]
          const offset = (Number(point.density) / maxDensity) * (violinWidth / 2)
          const x = centerX - offset
          const y = scaleY(point.value)
          pathParts.push(`L${format(x)} ${format(y)}`)
        }
        pathParts.push('Z')
        const outlineColor = category.outlineColor || '#3b82f6'
        parts.push(`<path d="${pathParts.join(' ')}" fill="none" stroke="${outlineColor}" stroke-width="2"/>`)
      }

      if (Array.isArray(category.points)) {
        category.points.forEach((point) => {
          const x = Number.isFinite(point.x) ? point.x : null
          const y = Number.isFinite(point.y) ? point.y : null
          if (x === null || y === null) {
            return
          }
          const radius = Number.isFinite(point.radius) ? point.radius : data.layout?.pointRadius || 1
          const color = point.color || '#3b82f6'
          parts.push(`<circle cx="${format(x)}" cy="${format(y)}" r="${format(radius)}" fill="${color}"/>`)
        })
      }

      if (category.label && Number.isFinite(category.label.endX) && Number.isFinite(category.label.endY)) {
        const angle = Number.isFinite(category.label.angleDegrees) ? category.label.angleDegrees : -45
        const labelText = this.escapeXML(category.name || '')
        parts.push(`<text transform="translate(${format(category.label.endX)}, ${format(category.label.endY)}) rotate(${format(angle)})" font-family="Arial, sans-serif" font-size="11" fill="#374151" text-anchor="end">${labelText}</text>`)
      }
    })

    parts.push(`</svg>`)
    return parts.join('')
  }

  escapeXML(value) {
    if (value === undefined || value === null) {
      return ''
    }
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')
  }
  
  // Close 2D plot modal
  close2DPlotModal(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const modal = document.getElementById('2d-plot-modal')
    if (modal) {
      if (this.is2DPlotMinimized) {
        this.restore2DPlotModal()
      }
      this.undock2DPlotModalFromMobileFooter(modal, { mountForExpanded: false })
      this.return2DPlotModalHome(modal)
      modal.style.display = 'none'
    }
    this.is2DPlotMinimized = false
    this.update2DPlotWindowControls()
    this.detachCanvasInteractions()
    if (this.controller && typeof this.controller.updateCustomPlotSettingsContext === 'function') {
      this.controller.updateCustomPlotSettingsContext({ visible: false })
    }
  }

  close2DPlotModalAndClearAxes(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (this.controller) {
      this.controller.resetAllXButtons()
      this.controller.resetAllYButtons()
      this.controller.selectedXButton = null
      this.controller.selectedYButton = null
    }
    this.close2DPlotModal()
  }

  update2DPlotWindowControls() {
    const minimizeBtn = document.getElementById('minimize-2d-plot-modal')
    const minimizeGlyph = document.getElementById('2d-plot-minimize-glyph')
    if (!minimizeBtn || !minimizeGlyph) return

    if (this.is2DPlotMinimized) {
      minimizeBtn.title = 'Restore'
      minimizeGlyph.classList.remove('fa-minus', 'fa-square')
      minimizeGlyph.classList.add('fa-window-restore')
      minimizeGlyph.style.fontSize = '12px'
    } else {
      minimizeBtn.title = 'Minimize'
      minimizeGlyph.classList.remove('fa-window-restore', 'fa-square')
      minimizeGlyph.classList.add('fa-minus')
      minimizeGlyph.style.fontSize = '13px'
    }
  }

  isMobileVizLayout() {
    return this.controller?.isMobileVizLayout?.() === true
  }

  is2DPlotModalDockOrPlotFooterParent(parent) {
    if (!parent || parent === document.body || parent === document.documentElement) return true
    if (parent.id === 'viz-mobile-custom-plot-dock' || parent.id === 'viz-plot-footer' || parent.id === 'viz-plot-area-wrap') {
      return true
    }
    return typeof parent.closest === 'function' && !!parent.closest('#viz-plot-area-wrap, #viz-mobile-custom-plot-dock')
  }

  remember2DPlotModalHome(modal = document.getElementById('2d-plot-modal')) {
    if (!modal) return
    if (this._2dPlotModalHome && document.contains(this._2dPlotModalHome)) return

    const parent = modal.parentElement
    // Never treat the mobile footer dock (z-index:1 plot wrap) as the permanent home.
    if (this.is2DPlotModalDockOrPlotFooterParent(parent)) return
    this._2dPlotModalHome = parent
  }

  return2DPlotModalHome(modal = document.getElementById('2d-plot-modal')) {
    if (!modal) return
    const home = this._2dPlotModalHome
    if (home && document.contains(home) && modal.parentElement !== home) {
      home.appendChild(modal)
    }
  }

  dockMinimized2DPlotToMobileFooter(modal = document.getElementById('2d-plot-modal')) {
    if (!modal || !this.isMobileVizLayout()) return false

    const dock = document.getElementById('viz-mobile-custom-plot-dock')
    if (!dock) return false

    this.remember2DPlotModalHome(modal)
    if (modal.parentElement !== dock) {
      dock.appendChild(modal)
    }

    modal.classList.add('is-mobile-docked')
    modal.style.display = 'flex'
    modal.style.transform = 'none'
    modal.style.left = ''
    modal.style.top = ''
    modal.style.right = ''
    modal.style.bottom = ''
    modal.style.width = ''
    modal.style.height = '32px'
    modal.style.minWidth = '0'
    modal.style.minHeight = '32px'
    modal.style.maxWidth = ''
    modal.style.maxHeight = '32px'
    modal.style.position = 'relative'
    modal.style.zIndex = '5'

    return true
  }

  undock2DPlotModalFromMobileFooter(modal = document.getElementById('2d-plot-modal'), { mountForExpanded = true } = {}) {
    if (!modal) return

    modal.classList.remove('is-mobile-docked')
    this.remember2DPlotModalHome(modal)

    // Expanded mobile plot must leave #viz-plot-area-wrap (z-index:1 / overflow:hidden)
    // or it paints under the panel selector (z-index:40) and side panels (z-index:60).
    if (mountForExpanded && this.isMobileVizLayout()) {
      if (modal.parentElement !== document.body) {
        document.body.appendChild(modal)
      }
    } else {
      this.return2DPlotModalHome(modal)
    }
    modal.style.zIndex = '10050'
  }

  applyDesktopMinimized2DPlotGeometry(modal = document.getElementById('2d-plot-modal')) {
    if (!modal) return

    const plotPanel = document.querySelector('.plot-container')
    const minimizedHeight = 48
    const viewportBottomMargin = 4
    const dockBottomOffset = 4
    let targetLeft = 12
    let targetTop = Math.max(8, window.innerHeight - minimizedHeight - viewportBottomMargin)
    if (plotPanel) {
      const panelRect = plotPanel.getBoundingClientRect()
      targetLeft = Math.max(8, Math.round(panelRect.left) + 8)
      targetTop = Math.max(8, Math.round(panelRect.bottom) - minimizedHeight - dockBottomOffset)
      targetTop = Math.min(targetTop, window.innerHeight - minimizedHeight - viewportBottomMargin)
    }

    modal.style.transform = 'none'
    modal.style.left = `${targetLeft}px`
    modal.style.top = `${targetTop}px`
    modal.style.width = '240px'
    modal.style.height = '48px'
    modal.style.minWidth = '240px'
    modal.style.minHeight = '48px'
    modal.style.maxWidth = '240px'
    modal.style.maxHeight = '48px'
    modal.style.position = 'fixed'
    modal.style.zIndex = '10000'
  }

  syncMinimized2DPlotDock() {
    if (!this.is2DPlotMinimized) return
    const modal = document.getElementById('2d-plot-modal')
    if (!modal || window.getComputedStyle(modal).display === 'none') return

    if (this.isMobileVizLayout()) {
      this.dockMinimized2DPlotToMobileFooter(modal)
      return
    }

    this.undock2DPlotModalFromMobileFooter(modal)
    this.applyDesktopMinimized2DPlotGeometry(modal)
  }

  applyMinimized2DPlotChrome(modal = document.getElementById('2d-plot-modal')) {
    if (!modal) return

    const content = document.getElementById('2d-plot-content')
    if (content) {
      content.style.display = 'none'
    }
    const header = document.getElementById('2d-plot-header')
    const titleRow = document.getElementById('2d-plot-title-row')
    const controls = document.getElementById('2d-plot-window-controls')
    const title = document.getElementById('2d-plot-title')
    if (header) {
      header.style.height = '100%'
      header.style.padding = this.isMobileVizLayout() ? '0 6px' : '0 10px'
      header.style.borderBottom = 'none'
      header.style.borderRadius = '12px'
      header.style.justifyContent = 'center'
      header.style.gap = this.isMobileVizLayout() ? '6px' : '12px'
    }
    if (titleRow) {
      titleRow.style.margin = '0'
      titleRow.style.minWidth = '0'
      titleRow.style.flex = '1 1 auto'
      titleRow.style.cursor = 'pointer'
    }
    if (title) {
      title.style.cursor = 'pointer'
      if (this.isMobileVizLayout()) {
        title.style.setProperty('font-size', '9px', 'important')
        title.style.setProperty('font-weight', '600', 'important')
        title.style.setProperty('line-height', '1.15', 'important')
        title.style.setProperty('max-width', '72px', 'important')
        title.style.setProperty('overflow', 'hidden', 'important')
        title.style.setProperty('text-overflow', 'ellipsis', 'important')
        title.style.setProperty('white-space', 'nowrap', 'important')
      }
    }
    if (header) {
      header.style.cursor = 'pointer'
    }
    if (controls) {
      controls.style.marginLeft = '0'
      controls.style.flexShrink = '0'
    }
    const resizeRight = document.getElementById('2d-plot-resize-right')
    const resizeBottom = document.getElementById('2d-plot-resize-bottom')
    const resizeCorner = document.getElementById('2d-plot-resize-corner')
    if (resizeRight) resizeRight.style.display = 'none'
    if (resizeBottom) resizeBottom.style.display = 'none'
    if (resizeCorner) resizeCorner.style.display = 'none'
  }

  minimize2DPlotModal(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    const modal = document.getElementById('2d-plot-modal')
    if (!modal || this.is2DPlotMinimized) return

    const rect = modal.getBoundingClientRect()
    this.previous2DPlotWindowState = {
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      transform: modal.style.transform || 'none'
    }

    this.applyMinimized2DPlotChrome(modal)

    if (this.isMobileVizLayout() && this.dockMinimized2DPlotToMobileFooter(modal)) {
      this.is2DPlotMinimized = true
      this.update2DPlotWindowControls()
      return
    }

    this.applyDesktopMinimized2DPlotGeometry(modal)

    this.is2DPlotMinimized = true
    this.update2DPlotWindowControls()
  }

  ensureMobileExpanded2DPlotModalWindowSize(modal = document.getElementById('2d-plot-modal')) {
    if (!modal) return

    const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0
    const margin = 8
    const selector = document.getElementById('viz-mobile-panel-selector')
    const selectorBottom = selector?.getBoundingClientRect?.().bottom
    const topFloor = Number.isFinite(selectorBottom) && selectorBottom > 0
      ? Math.ceil(selectorBottom) + margin
      : margin
    const width = Math.max(280, Math.round(viewportWidth - margin * 2))
    const availableHeight = Math.max(240, viewportHeight - topFloor - margin)
    const height = Math.min(Math.round(viewportHeight * 0.72), availableHeight)
    const left = Math.max(margin, Math.round((viewportWidth - width) / 2))
    const top = Math.max(topFloor, Math.round((viewportHeight - height) / 2))

    modal.style.transform = 'none'
    modal.style.left = `${left}px`
    modal.style.top = `${top}px`
    modal.style.width = `${width}px`
    modal.style.height = `${height}px`
    modal.style.minWidth = '280px'
    modal.style.minHeight = '240px'
    modal.style.maxWidth = '96vw'
    modal.style.maxHeight = '90vh'
    modal.style.position = 'fixed'
    modal.style.zIndex = '10050'
  }

  restore2DPlotModal(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    const modal = document.getElementById('2d-plot-modal')
    if (!modal || !this.is2DPlotMinimized) return

    this.undock2DPlotModalFromMobileFooter(modal)

    if (this.isMobileVizLayout()) {
      this.ensureMobileExpanded2DPlotModalWindowSize(modal)
    } else {
      const previous = this.previous2DPlotWindowState
      if (previous) {
        modal.style.transform = 'none'
        modal.style.left = `${Math.max(0, Math.round(previous.left))}px`
        modal.style.top = `${Math.max(0, Math.round(previous.top))}px`
        modal.style.width = `${Math.round(previous.width)}px`
        modal.style.height = `${Math.round(previous.height)}px`
      }
      modal.style.minWidth = '400px'
      modal.style.minHeight = '300px'
      modal.style.maxWidth = '90vw'
      modal.style.maxHeight = '90vh'
      modal.style.position = 'fixed'
      modal.style.zIndex = '10000'
    }

    const content = document.getElementById('2d-plot-content')
    if (content) {
      content.style.display = 'block'
    }
    const header = document.getElementById('2d-plot-header')
    const titleRow = document.getElementById('2d-plot-title-row')
    const controls = document.getElementById('2d-plot-window-controls')
    const title = document.getElementById('2d-plot-title')
    if (header) {
      header.style.height = ''
      header.style.padding = '12px 16px'
      header.style.borderBottom = '1px solid #e5e7eb'
      header.style.borderRadius = '12px 12px 0 0'
      header.style.justifyContent = 'space-between'
      header.style.gap = ''
      header.style.cursor = 'move'
    }
    if (titleRow) {
      titleRow.style.margin = ''
      titleRow.style.minWidth = ''
      titleRow.style.flex = ''
      titleRow.style.cursor = ''
    }
    if (title) {
      title.style.cursor = ''
      title.style.removeProperty('font-size')
      title.style.removeProperty('font-weight')
      title.style.removeProperty('line-height')
      title.style.removeProperty('max-width')
      title.style.removeProperty('overflow')
      title.style.removeProperty('text-overflow')
      title.style.removeProperty('white-space')
    }
    if (controls) {
      controls.style.marginLeft = ''
      controls.style.flexShrink = ''
    }
    const resizeRight = document.getElementById('2d-plot-resize-right')
    const resizeBottom = document.getElementById('2d-plot-resize-bottom')
    const resizeCorner = document.getElementById('2d-plot-resize-corner')
    if (resizeRight) resizeRight.style.display = 'block'
    if (resizeBottom) resizeBottom.style.display = 'block'
    if (resizeCorner) resizeCorner.style.display = 'block'

    this.is2DPlotMinimized = false
    this.update2DPlotWindowControls()
    this.update2DPlotCanvasSize()
  }

  toggle2DPlotModalMinimize(event) {
    if (this.is2DPlotMinimized) {
      this.restore2DPlotModal(event)
    } else {
      this.minimize2DPlotModal(event)
    }
  }

  get2DPlotCheckpointState() {
    const modal = document.getElementById('2d-plot-modal')
    if (!modal) return null

    const computedStyle = window.getComputedStyle(modal)
    const isVisible = computedStyle.display !== 'none'
    if (!isVisible) return null

    const rect = modal.getBoundingClientRect()
    const expandedWindow = this.previous2DPlotWindowState
      ? {
          left: Number(this.previous2DPlotWindowState.left),
          top: Number(this.previous2DPlotWindowState.top),
          width: Number(this.previous2DPlotWindowState.width),
          height: Number(this.previous2DPlotWindowState.height)
        }
      : null

    return {
      isMinimized: this.is2DPlotMinimized === true,
      left: Number(rect.left),
      top: Number(rect.top),
      width: Number(rect.width),
      height: Number(rect.height),
      expandedWindow: expandedWindow
    }
  }

  async apply2DPlotCheckpointState(windowState) {
    if (!windowState || !this.controller?.selectedXButton || !this.controller?.selectedYButton) {
      return
    }

    let modal = document.getElementById('2d-plot-modal')
    const modalHidden = !modal || window.getComputedStyle(modal).display === 'none'
    if (modalHidden) {
      await this.open2DPlotModal()
      modal = document.getElementById('2d-plot-modal')
    }

    for (let i = 0; i < 40; i++) {
      if (modal && window.getComputedStyle(modal).display !== 'none') {
        break
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
      modal = document.getElementById('2d-plot-modal')
    }
    if (!modal || window.getComputedStyle(modal).display === 'none') {
      return
    }

    const normalizedExpanded = windowState.expandedWindow && Number.isFinite(Number(windowState.expandedWindow.left))
      ? {
          left: Number(windowState.expandedWindow.left),
          top: Number(windowState.expandedWindow.top),
          width: Number(windowState.expandedWindow.width),
          height: Number(windowState.expandedWindow.height),
          transform: 'none'
        }
      : null

    if (normalizedExpanded) {
      this.previous2DPlotWindowState = normalizedExpanded
    }

    const targetLeft = Number(windowState.left)
    const targetTop = Number(windowState.top)
    const targetWidth = Number(windowState.width)
    const targetHeight = Number(windowState.height)
    const shouldMinimize = windowState.isMinimized === true

    if (!shouldMinimize) {
      if (this.is2DPlotMinimized) {
        this.restore2DPlotModal()
      }
      if (this.isMobileVizLayout()) {
        this.ensureMobileExpanded2DPlotModalWindowSize(modal)
      } else if (Number.isFinite(targetLeft) && Number.isFinite(targetTop) && Number.isFinite(targetWidth) && Number.isFinite(targetHeight)) {
        modal.style.transform = 'none'
        modal.style.left = `${Math.max(0, Math.round(targetLeft))}px`
        modal.style.top = `${Math.max(0, Math.round(targetTop))}px`
        modal.style.width = `${Math.round(targetWidth)}px`
        modal.style.height = `${Math.round(targetHeight)}px`
      }
      this.update2DPlotCanvasSize()
      return
    }

    if (!this.is2DPlotMinimized) {
      if (normalizedExpanded && !this.isMobileVizLayout()) {
        modal.style.transform = 'none'
        modal.style.left = `${Math.max(0, Math.round(normalizedExpanded.left))}px`
        modal.style.top = `${Math.max(0, Math.round(normalizedExpanded.top))}px`
        modal.style.width = `${Math.round(normalizedExpanded.width)}px`
        modal.style.height = `${Math.round(normalizedExpanded.height)}px`
      }
      this.minimize2DPlotModal()
    } else if (this.isMobileVizLayout()) {
      this.dockMinimized2DPlotToMobileFooter(modal)
    }

    // Desktop checkpoints may store absolute minimized coords; on mobile keep the footer dock.
    if (!this.isMobileVizLayout() && Number.isFinite(targetLeft) && Number.isFinite(targetTop) && Number.isFinite(targetWidth) && Number.isFinite(targetHeight)) {
      modal.style.transform = 'none'
      modal.style.left = `${Math.max(0, Math.round(targetLeft))}px`
      modal.style.top = `${Math.max(0, Math.round(targetTop))}px`
      modal.style.width = `${Math.round(targetWidth)}px`
      modal.style.height = `${Math.round(targetHeight)}px`
    }
  }
  
  // Make 2D plot modal draggable
  make2DPlotModalDraggable() {
    const modal = document.getElementById('2d-plot-modal')
    const header = document.getElementById('2d-plot-header')
    const closeBtn = document.getElementById('close-2d-plot-modal')
    const minimizeBtn = document.getElementById('minimize-2d-plot-modal')
    
    if (!modal || !header) return
    
    // Add direct event listener for close button (like settings window)
    if (closeBtn) {
      closeBtn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.close2DPlotModalAndClearAxes(e)
      })
    }

    if (minimizeBtn) {
      minimizeBtn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.toggle2DPlotModalMinimize(e)
      })
    }
    this.update2DPlotWindowControls()
    
    let isDragging = false
    let dragMoved = false
    let currentX = 0
    let currentY = 0
    let initialX = 0
    let initialY = 0
    const dragThresholdPx = 5

    const isWindowControlTarget = (target) => {
      if (!target || typeof target.closest !== 'function') return false
      return !!(target.closest('#close-2d-plot-modal') || target.closest('#minimize-2d-plot-modal'))
    }
    
    const startDrag = (e) => {
      // Don't start drag if clicking on window controls.
      if (isWindowControlTarget(e.target)) {
        return
      }

      // Reduced window: title/header click expands (same as restore). Dragging while
      // minimized breaks docked/fixed chrome and can make the window disappear.
      if (this.is2DPlotMinimized) {
        return
      }
      
      if (e.button !== 0 && e.type !== 'touchstart') return // Only left mouse button
      
      isDragging = true
      dragMoved = false
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
      if (Math.abs(dx) > dragThresholdPx || Math.abs(dy) > dragThresholdPx) {
        dragMoved = true
      }
      
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
      dragMoved = false
    }

    const restoreFromMinimizedHeader = (e) => {
      if (!this.is2DPlotMinimized) return
      if (isWindowControlTarget(e.target)) return
      e.preventDefault()
      e.stopPropagation()
      this.restore2DPlotModal(e)
    }
    
    header.addEventListener('mousedown', startDrag)
    header.addEventListener('touchstart', startDrag)
    header.addEventListener('click', restoreFromMinimizedHeader)
    
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
    let resizeFrameId = null
    let pendingWidth = null
    let pendingHeight = null
    let pendingLeft = null
    let pendingTop = null
    
    const applyPendingModalSize = () => {
      resizeFrameId = null
      if (pendingWidth == null || pendingHeight == null) return

      modal.style.width = pendingWidth + 'px'
      modal.style.height = pendingHeight + 'px'
      modal.style.transform = 'none'
      if (pendingLeft != null) modal.style.left = pendingLeft + 'px'
      if (pendingTop != null) modal.style.top = pendingTop + 'px'
    }

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
      modal.style.left = startLeft + 'px'
      modal.style.top = startTop + 'px'
      modal.style.transform = 'none'
      
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

      if (newLeft + newWidth > window.innerWidth) {
        newLeft = Math.max(0, window.innerWidth - newWidth)
      }
      if (newTop + newHeight > window.innerHeight) {
        newTop = Math.max(0, window.innerHeight - newHeight)
      }
      if (newLeft < 0) newLeft = 0
      if (newTop < 0) newTop = 0

      pendingWidth = newWidth
      pendingHeight = newHeight
      pendingLeft = newLeft
      pendingTop = newTop

      // Only update modal chrome during drag. Full plot redraw runs once on mouseup.
      if (resizeFrameId == null) {
        resizeFrameId = window.requestAnimationFrame(applyPendingModalSize)
      }
    }
    
    const stopResize = () => {
      if (!isResizing) return

      isResizing = false
      resizeType = null
      if (resizeFrameId != null) {
        window.cancelAnimationFrame(resizeFrameId)
        applyPendingModalSize()
      }
      pendingWidth = null
      pendingHeight = null
      pendingLeft = null
      pendingTop = null
      // Single redraw after resize completes (not on every mousemove)
      this.update2DPlotCanvasSize()
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
    document.addEventListener('touchmove', doResize, { passive: false })
    document.addEventListener('mouseup', stopResize)
    document.addEventListener('touchend', stopResize)
  }
  
  // Update 2D plot canvas size based on modal size
  update2DPlotCanvasSize() {
    const canvas = document.getElementById('2d-plot-canvas')
    const modal = document.getElementById('2d-plot-modal')
    
    if (!canvas || !modal || modal.style.display === 'none') return
    
    const contentArea = canvas.parentElement?.parentElement
    if (!contentArea) return

    const contentRect = contentArea.getBoundingClientRect()
    const availableWidth = contentRect.width - 32 // padding
    const availableHeight = contentRect.height - 32 // padding
    
    // Set canvas size (use available space, but allow horizontal scroll if wider)
    const canvasWidth = Math.max(Math.floor(availableWidth), 600) // Minimum 600px width
    const canvasHeight = Math.max(Math.floor(availableHeight), 400) // Minimum 400px height

    if (canvas.width === canvasWidth && canvas.height === canvasHeight) {
      return
    }
    
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
    if (this.controller.isClientPointOverVisualizationOntopUi(event.clientX, event.clientY)) {
      return
    }
    if (!this.currentCanvas) {
      return
    }
    const mode = this.controller.interactionMode
    if (mode === 'lasso') {
      this.currentCanvas.style.cursor = 'crosshair'
      if (!this.isDrawingLasso) {
        return
      }
      const pointer = this.controller.clientPointToCanvasBuffer(event.clientX, event.clientY, this.currentCanvas)
      if (!pointer) return
      const mouseX = pointer.x
      const mouseY = pointer.y
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
    const pointer = this.controller.clientPointToCanvasBuffer(event.clientX, event.clientY, this.currentCanvas)
    if (!pointer) return
    const mouseX = pointer.x
    const mouseY = pointer.y
    const closest = this.findClosestPoint(mouseX, mouseY)
    if (!closest) {
      if (!this.controller.isTooltipFixed && typeof this.controller.hideSimpleTooltip === 'function') {
        this.controller.hideSimpleTooltip()
      }
      this.lastHoverCellId = null
      return
    }
    // Check if the cell is visible (not hidden by filters)
    const cellId = closest.point.cellIndex
    if (!this.controller.dataManager.isCellVisible(cellId)) {
      // Cell is hidden - hide tooltip only if not fixed
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
      const cellName = cellId.toString()
      if (typeof this.controller.showSimpleTooltip === 'function') {
        this.controller.showSimpleTooltip(cellName, null, { x: tooltipLeft, y: tooltipTop }, cellId, false)
      }
      this.lastHoverCellId = cellId
    }
  }
  
  handleCanvasClick(event) {
    if (this.controller.isClientPointOverVisualizationOntopUi(event.clientX, event.clientY)) {
      return
    }
    if (!this.currentCanvas || !this.currentPlotPoints || this.currentPlotPoints.length === 0) {
      return
    }
    if (this.controller.interactionMode === 'lasso') {
      return
    }
    if (this.controller.interactionMode !== 'pick') {
      return
    }
    const pointer = this.controller.clientPointToCanvasBuffer(event.clientX, event.clientY, this.currentCanvas)
    if (!pointer) return
    const mouseX = pointer.x
    const mouseY = pointer.y
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
    // Check if the cell is visible (not hidden by filters)
    const cellId = closest.point.cellIndex
    if (!this.controller.dataManager.isCellVisible(cellId)) {
      // Cell is hidden - don't fix tooltip, hide it instead
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
    // Use saved position if available (from dragging), otherwise use click position
    // Don't override lastTooltipPosition - it should only be set when dragging the tooltip
    const tooltipLeft = event.clientX + 12
    const tooltipTop = event.clientY + 12
    if (typeof this.controller.fixTooltipToCell === 'function') {
      // Pass screen coordinates for consistent positioning
      this.controller.fixTooltipToCell(cellId, event.clientX, event.clientY)
    } else if (typeof this.controller.showSimpleTooltip === 'function') {
      const cellName = cellId.toString()
      this.controller.isTooltipFixed = true
      this.controller.fixedTooltipCellId = cellId
      // showSimpleTooltip will use lastTooltipPosition if available (from dragging),
      // otherwise it will use the click position passed here
      this.controller.showSimpleTooltip(cellName, null, { x: event.clientX, y: event.clientY }, cellId, true)
    }
    this.lastHoverCellId = cellId
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
    if (this.controller.isClientPointOverVisualizationOntopUi(event.clientX, event.clientY)) {
      return
    }
    if (!this.currentCanvas) return
    if (this.controller.interactionMode !== 'lasso') return
    if (event.button !== 0) return
    event.preventDefault()
    const pointer = this.controller.clientPointToCanvasBuffer(event.clientX, event.clientY, this.currentCanvas)
    if (!pointer) return
    const mouseX = pointer.x
    const mouseY = pointer.y
    this.isDrawingLasso = true
    this.customLassoPoints = [{ x: mouseX, y: mouseY }]
    this.ensureLassoOverlay(this.currentCanvas)
    this.drawLassoPath()
  }

  handleCanvasMouseUp(event) {
    const overOntop = this.controller.isClientPointOverVisualizationOntopUi(event.clientX, event.clientY)
    if (overOntop && !this.isDrawingLasso) {
      return
    }
    if (!this.isDrawingLasso) return
    if (this.controller.interactionMode !== 'lasso') {
      this.finishCustomLassoSelection(false)
      return
    }
    event.preventDefault()
    const pointer = this.controller.clientPointToCanvasBuffer(event.clientX, event.clientY, this.currentCanvas)
    if (!pointer) return
    const mouseX = pointer.x
    const mouseY = pointer.y
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

    // Create Set from currentVisibleCells for fast lookup (null means all cells are visible)
    const visibleCellsSet = this.controller && this.controller.currentVisibleCells 
      ? new Set(this.controller.currentVisibleCells) 
      : null

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
      // Check if cell is visible (skip if not in visible set)
      if (visibleCellsSet && !visibleCellsSet.has(point.cellIndex)) {
        continue
      }
      
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
    const displayRect = baseCanvas.getBoundingClientRect()
    overlayCanvas.style.width = `${displayRect.width}px`
    overlayCanvas.style.height = `${displayRect.height}px`
    overlayCanvas.style.display = 'block'

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
    ctx.fillStyle = (typeof this.controller?.getSelectionHighlightColorHex === 'function')
      ? this.controller.getSelectionHighlightColorHex()
      : '#ff0000'
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
    this.remember2DPlotModalHome(modal)
    modal.style.display = 'flex'
    this.ensureInitial2DPlotModalWindowSize(modal)
    if (typeof this.controller?.bringVisualizationOntopUiToFront === 'function') {
      this.controller.bringVisualizationOntopUiToFront(modal)
    }
    this.update2DPlotWindowControls()
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
      
      if (this.controller && typeof this.controller.updateCustomPlotSettingsContext === 'function') {
        this.controller.updateCustomPlotSettingsContext({
          visible: true,
          xAxisType: xVector.data_type
        })
      }
      
      if (isXCategorical) {
        // Render violin plot
        await this.renderViolinPlot2D(canvas, xVector, yVector, filteredIndices)
      } else {
        // Render scatter plot (both numerical)
        await this.renderScatterPlot2D(canvas, xVector, yVector, filteredIndices)
      }

      // On mobile keep the reduced window in the plot footer next to zoom controls.
      if (this.isMobileVizLayout() && !this.is2DPlotMinimized) {
        this.minimize2DPlotModal()
      }
      
    } catch (error) {
      console.error('Error opening 2D plot modal:', error)
      if (loadingDiv) loadingDiv.style.display = 'none'
      alert('Error loading 2D plot: ' + error.message)
    }
  }

  ensureInitial2DPlotModalWindowSize(modal) {
    if (!modal || this.hasInitialized2DPlotWindowSize) return

    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight
    const margin = 32

    const minWidth = 400
    const minHeight = 300
    const maxWidth = Math.max(minWidth, viewportWidth - (margin * 2))
    const maxHeight = Math.max(minHeight, viewportHeight - (margin * 2))

    const targetWidth = Math.min(maxWidth, Math.max(minWidth, Math.round(viewportWidth * 0.72)))
    const targetHeight = Math.min(maxHeight, Math.max(minHeight, Math.round(viewportHeight * 0.72)))

    const targetLeft = Math.max(margin, Math.round((viewportWidth - targetWidth) / 2))
    const targetTop = Math.max(margin, Math.round((viewportHeight - targetHeight) / 2))

    modal.style.transform = 'none'
    modal.style.left = `${targetLeft}px`
    modal.style.top = `${targetTop}px`
    modal.style.width = `${targetWidth}px`
    modal.style.height = `${targetHeight}px`

    this.hasInitialized2DPlotWindowSize = true
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
      
      if (this.controller && typeof this.controller.updateCustomPlotSettingsContext === 'function') {
        this.controller.updateCustomPlotSettingsContext({
          visible: true,
          xAxisType: xVector.data_type
        })
      }
      
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
    this.lastPlotExportData = null
    
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
    
    // Axis scale definitions
    const xScaleType = this.controller.customPlotXAxisScale || 'normal'
    const yScaleType = this.controller.customPlotYAxisScale || 'normal'
    const xScaleDef = this.getScaleDefinition(xScaleType)
    const yScaleDef = this.getScaleDefinition(yScaleType)
    
    // Apply filtering
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const dataPoints = []
    let xDomainMin = Infinity
    let xDomainMax = -Infinity
    let yDomainMin = Infinity
    let yDomainMax = -Infinity
    let xDisplayMin = Infinity
    let xDisplayMax = -Infinity
    let yDisplayMin = Infinity
    let yDisplayMax = -Infinity
    let skippedDueToScale = 0
    
    for (let i = 0; i < xValues.length; i++) {
      if (filteredSet && !filteredSet.has(i)) {
        continue
      }
      
      const x = xValues[i]
      const y = yValues[i]
      const displayX = this.transformValueForScale(x, xScaleDef)
      const displayY = this.transformValueForScale(y, yScaleDef)
      
      if (!Number.isFinite(displayX) || !Number.isFinite(displayY)) {
        skippedDueToScale++
        continue
      }
      
      dataPoints.push({
        x,
        y,
        displayX,
        displayY,
        cellIndex: i
      })
      
      if (x < xDomainMin) xDomainMin = x
      if (x > xDomainMax) xDomainMax = x
      if (y < yDomainMin) yDomainMin = y
      if (y > yDomainMax) yDomainMax = y
      if (displayX < xDisplayMin) xDisplayMin = displayX
      if (displayX > xDisplayMax) xDisplayMax = displayX
      if (displayY < yDisplayMin) yDisplayMin = displayY
      if (displayY > yDisplayMax) yDisplayMax = displayY
    }
    
    if (dataPoints.length === 0) {
      ctx.fillStyle = '#6b7280'
      ctx.font = '16px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('No data points to display for the selected axis scales', width / 2, height / 2)
      return
    }
    
    if (skippedDueToScale > 0) {
      console.warn(`Skipped ${skippedDueToScale.toLocaleString()} points that are incompatible with the selected axis scales.`)
    }
    
    if (!Number.isFinite(xDomainMin) || !Number.isFinite(xDomainMax) || !Number.isFinite(yDomainMin) || !Number.isFinite(yDomainMax)) {
      console.error('Unable to determine domain bounds for scatter plot', { xDomainMin, xDomainMax, yDomainMin, yDomainMax })
      return
    }
    
    if (!Number.isFinite(xDisplayMin) || !Number.isFinite(xDisplayMax) || !Number.isFinite(yDisplayMin) || !Number.isFinite(yDisplayMax)) {
      console.error('Unable to determine display bounds for scatter plot', { xDisplayMin, xDisplayMax, yDisplayMin, yDisplayMax })
      return
    }
    
    if (Math.abs(xDisplayMax - xDisplayMin) < 1e-9) {
      const adjust = Math.abs(xDisplayMin) > 0 ? Math.abs(xDisplayMin) * 0.1 : 1
      xDisplayMin -= adjust
      xDisplayMax += adjust
    }
    
    if (Math.abs(yDisplayMax - yDisplayMin) < 1e-9) {
      const adjust = Math.abs(yDisplayMin) > 0 ? Math.abs(yDisplayMin) * 0.1 : 1
      yDisplayMin -= adjust
      yDisplayMax += adjust
    }
    
    const xDisplayRange = xDisplayMax - xDisplayMin || 1
    const yDisplayRange = yDisplayMax - yDisplayMin || 1
    
    // Padding for axes (left, right, top, bottom)
    const leftPadding = 70
    const rightPadding = 20
    const topPadding = 20
    const bottomPadding = 70
    
    const plotWidth = width - leftPadding - rightPadding
    const plotHeight = height - topPadding - bottomPadding
    
    // Scale functions (operate on transformed display values)
    const scaleDisplayX = (displayValue) => leftPadding + ((displayValue - xDisplayMin) / xDisplayRange) * plotWidth
    const scaleDisplayY = (displayValue) => height - bottomPadding - ((displayValue - yDisplayMin) / yDisplayRange) * plotHeight
    
    // Tick generation
    const xTickValues = this.generateAxisTicks(xScaleDef, xDomainMin, xDomainMax)
    const yTickValues = this.generateAxisTicks(yScaleDef, yDomainMin, yDomainMax)
    
    const verticalGridLines = []
    const horizontalGridLines = []
    const xTicks = []
    const yTicks = []
    const gridStroke = 'rgba(204, 204, 204, 0.3)'
    const axisStroke = '#d1d5db'
    
    // Draw grid lines first (behind everything)
    ctx.strokeStyle = gridStroke
    ctx.lineWidth = 1
    ctx.setLineDash([2, 2])
    
    for (const tickValue of xTickValues) {
      const displayValue = this.transformValueForScale(tickValue, xScaleDef)
      if (!Number.isFinite(displayValue)) continue
      const x = scaleDisplayX(displayValue)
      if (x < leftPadding || x > width - rightPadding) continue
      ctx.beginPath()
      ctx.moveTo(x, topPadding)
      ctx.lineTo(x, height - bottomPadding)
      ctx.stroke()
      verticalGridLines.push(x)
    }
    
    for (const tickValue of yTickValues) {
      const displayValue = this.transformValueForScale(tickValue, yScaleDef)
      if (!Number.isFinite(displayValue)) continue
      const y = scaleDisplayY(displayValue)
      if (y < topPadding || y > height - bottomPadding) continue
      ctx.beginPath()
      ctx.moveTo(leftPadding, y)
      ctx.lineTo(width - rightPadding, y)
      ctx.stroke()
      horizontalGridLines.push(y)
    }
    
    ctx.setLineDash([])
    
    // Draw axes
    ctx.strokeStyle = axisStroke
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
    
    for (const tickValue of xTickValues) {
      const displayValue = this.transformValueForScale(tickValue, xScaleDef)
      if (!Number.isFinite(displayValue)) continue
      const x = scaleDisplayX(displayValue)
      if (x < leftPadding || x > width - rightPadding) continue
      ctx.beginPath()
      ctx.moveTo(x, height - bottomPadding)
      ctx.lineTo(x, height - bottomPadding + 5)
      ctx.stroke()
      const label = this.formatTickValue(tickValue)
      ctx.fillText(label, x, height - bottomPadding + 8)
      xTicks.push({
        value: tickValue,
        label,
        x
      })
    }
    
    ctx.textAlign = 'right'
    ctx.textBaseline = 'middle'
    for (const tickValue of yTickValues) {
      const displayValue = this.transformValueForScale(tickValue, yScaleDef)
      if (!Number.isFinite(displayValue)) continue
      const y = scaleDisplayY(displayValue)
      if (y < topPadding || y > height - bottomPadding) continue
      ctx.beginPath()
      ctx.moveTo(leftPadding, y)
      ctx.lineTo(leftPadding - 5, y)
      ctx.stroke()
      const label = this.formatTickValue(tickValue)
      ctx.fillText(label, leftPadding - 8, y)
      yTicks.push({
        value: tickValue,
        label,
        y
      })
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
      const canvasX = scaleDisplayX(point.displayX)
      const canvasY = scaleDisplayY(point.displayY)
      
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
      plotPoints.push({ cellIndex: point.cellIndex, canvasX, canvasY, radius: pointSize, color })
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
    
    const axisY = height - bottomPadding
    const axisX = leftPadding
    this.lastPlotExportData = {
      type: 'scatter',
      width,
      height,
      background: '#ffffff',
      axisScales: {
        x: xScaleType,
        y: yScaleType
      },
      skippedDueToScale,
      grid: {
        vertical: {
          positions: verticalGridLines,
          top: topPadding,
          bottom: height - bottomPadding,
          color: gridStroke
        },
        horizontal: {
          positions: horizontalGridLines,
          left: leftPadding,
          right: width - rightPadding,
          color: gridStroke
        }
      },
      axes: {
        color: axisStroke,
        x: {
          scale: xScaleType,
          domainMin: xDomainMin,
          domainMax: xDomainMax,
          displayMin: xDisplayMin,
          displayMax: xDisplayMax,
          axisY,
          line: { x1: leftPadding, x2: width - rightPadding },
          ticks: xTicks,
          tickLength: 5,
          tickLabelOffset: 8,
          tickFontSize: 11,
          label: {
            lines: xLines,
            baseY: axisY + 28,
            lineSpacing: 16,
            fontSize: 13,
            x: width / 2
          }
        },
        y: {
          scale: yScaleType,
          domainMin: yDomainMin,
          domainMax: yDomainMax,
          displayMin: yDisplayMin,
          displayMax: yDisplayMax,
          axisX,
          line: { y1: topPadding, y2: height - bottomPadding },
          ticks: yTicks,
          tickLength: 5,
          tickLabelOffset: 8,
          tickFontSize: 11,
          label: {
            lines: yLines,
            translateX: 15,
            translateY: height / 2,
            lineSpacing: 16,
            fontSize: 13
          }
        }
      },
      points: plotPoints.map(({ canvasX, canvasY, radius, color }) => ({
        x: canvasX,
        y: canvasY,
        radius,
        color
      }))
    }
    
    // console.log('Scatter plot rendered with', dataPoints.length, 'points')
  }
  
  // Render violin plot for 2D modal (x is categorical)
  async renderViolinPlot2D(canvas, xVector, yVector, filteredIndices) {
    // console.log('Rendering violin plot 2D')
    
    const ctx = canvas.getContext('2d')
    const width = canvas.width
    const height = canvas.height
    this.currentCanvasContext = ctx
    this.lastPlotExportData = null
    
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
    
    const yScaleType = this.controller.customPlotYAxisScale || 'normal'
    const yScaleDef = this.getScaleDefinition(yScaleType)
    
    // Apply filtering
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const dataByCategory = {}
    const xLabels = this.controller.dataManager.getCategoryLabels(xVector)
    if (!xLabels) {
      throw new Error(`Discrete metadata ${xVector?.id} is missing compression_info.categories`)
    }
    let yDomainMin = Infinity
    let yDomainMax = -Infinity
    let yDisplayMin = Infinity
    let yDisplayMax = -Infinity
    let skippedDueToScale = 0
    for (let i = 0; i < xValues.length; i++) {
      if (filteredSet && !filteredSet.has(i)) {
        continue
      }
      const category = String(xLabels[xValues[i]])
      const y = yValues[i]
      const displayY = this.transformValueForScale(y, yScaleDef)
      if (!Number.isFinite(displayY)) {
        skippedDueToScale++
        continue
      }
      if (!dataByCategory[category]) {
        dataByCategory[category] = []
      }
      dataByCategory[category].push({
        y,
        displayY,
        cellIndex: i
      })
      if (y < yDomainMin) yDomainMin = y
      if (y > yDomainMax) yDomainMax = y
      if (displayY < yDisplayMin) yDisplayMin = displayY
      if (displayY > yDisplayMax) yDisplayMax = displayY
    }
    
    const categories = Object.keys(dataByCategory).sort()
    
    if (skippedDueToScale > 0) {
      console.warn(`Skipped ${skippedDueToScale.toLocaleString()} points that are incompatible with the selected Y-axis scale.`)
    }
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
    
    if (!Number.isFinite(yDomainMin) || !Number.isFinite(yDomainMax)) {
      ctx.fillStyle = '#6b7280'
      ctx.font = '16px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('No data points to display', width / 2, height / 2)
      return
    }
    
    if (!Number.isFinite(yDisplayMin) || !Number.isFinite(yDisplayMax)) {
      console.error('Unable to determine Y-axis display bounds for violin plot', { yDisplayMin, yDisplayMax })
      return
    }
    
    if (Math.abs(yDisplayMax - yDisplayMin) < 1e-9) {
      const adjust = Math.abs(yDisplayMin) > 0 ? Math.abs(yDisplayMin) * 0.1 : 1
      yDisplayMin -= adjust
      yDisplayMax += adjust
    }
    
    const yDisplayRange = yDisplayMax - yDisplayMin || 1
    const scaleDisplayY = (displayValue) => height - bottomPadding - ((displayValue - yDisplayMin) / yDisplayRange) * plotHeight
    const yMin = yDomainMin
    const yMax = yDomainMax
    const yRange = yMax - yMin || 1
    
    const yTickValues = this.generateAxisTicks(yScaleDef, yMin, yMax)
    const horizontalGridLines = []
    const yTicks = []
    const categoriesExport = []
    const categoryExportMap = new Map()
    const gridStroke = 'rgba(204, 204, 204, 0.3)'
    const axisStroke = '#d1d5db'
    
    // Draw grid lines first (behind everything)
    ctx.strokeStyle = gridStroke
    ctx.lineWidth = 1
    ctx.setLineDash([2, 2])
    
    // Horizontal grid lines (aligned with Y-axis ticks)
    for (const tickValue of yTickValues) {
      const displayValue = this.transformValueForScale(tickValue, yScaleDef)
      if (!Number.isFinite(displayValue)) continue
      const y = scaleDisplayY(displayValue)
      if (y >= topPadding && y <= height - bottomPadding) {
        ctx.beginPath()
        ctx.moveTo(sidePadding, y)
        ctx.lineTo(width - sidePadding, y)
        ctx.stroke()
        horizontalGridLines.push(y)
      }
    }
    
    ctx.setLineDash([])
    
    // Draw axes
    ctx.strokeStyle = axisStroke
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
    for (const tickValue of yTickValues) {
      const displayValue = this.transformValueForScale(tickValue, yScaleDef)
      if (!Number.isFinite(displayValue)) continue
      const y = scaleDisplayY(displayValue)
      if (y >= topPadding && y <= height - bottomPadding) {
        // Tick mark
        ctx.beginPath()
        ctx.moveTo(sidePadding, y)
        ctx.lineTo(sidePadding - 5, y)
        ctx.stroke()
        
        // Label
        const label = this.formatTickValue(tickValue)
        ctx.fillText(label, sidePadding - 8, y)
        yTicks.push({
          value: tickValue,
          label,
          y
        })
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
    
    // Get coloring metadata vector for point colors
    const coloringVector = this.controller.colorManager?.getColoringMetadataVector()

    // Build category outline colors using the X-axis metadata category mapping.
    const categoryColors = window.CATEGORY_COLORS || []
    const categoryColorMap = {}
    const xMetadataId = xVector?.id || this.controller?.selectedXButton?.metadataId
    const canResolveStableCategoryIndex = typeof this.controller.getStableSortedCategories === 'function'
    const canResolveCategoryColor = typeof this.controller.getCategoryColor === 'function' && !!xMetadataId
    let categoryToStableIndex = null

    if (canResolveStableCategoryIndex) {
      const labels = this.controller.dataManager.getCategoryLabels(xVector)
      if (!labels) {
        throw new Error(`Discrete metadata ${xVector?.id} is missing compression_info.categories`)
      }
      const allCategories = [...labels]

      const stableSortedCategories = this.controller.getStableSortedCategories(xValues, allCategories)
      categoryToStableIndex = new Map()
      stableSortedCategories.forEach((cat, idx) => {
        categoryToStableIndex.set(cat, idx)
      })
    }

    categories.forEach((cat, idx) => {
      const categoryIndex = categoryToStableIndex?.has(cat) ? categoryToStableIndex.get(cat) : idx
      const fallbackColor = categoryColors[categoryIndex % categoryColors.length] || '#3b82f6'

      if (canResolveCategoryColor) {
        categoryColorMap[cat] = this.controller.getCategoryColor(cat, categoryIndex, xMetadataId)
      } else {
        categoryColorMap[cat] = fallbackColor
      }
    })
    
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
      const categoryExport = {
        name: category,
        centerX,
        violinWidth,
        outlineColor: categoryColorMap[category] || '#3b82f6',
        points: []
      }
      categoryExportMap.set(category, categoryExport)
      
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
        const y = scaleDisplayY(point.displayY)
        
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
        const pointInfo = { cellIndex: point.cellIndex, canvasX: pointX, canvasY: y, radius: pointSize, color }
        plotPoints.push(pointInfo)
        categoryExport.points.push({ x: pointX, y, radius: pointSize, color })
      }
      categoriesExport.push(categoryExport)
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
      const categoryExport = categoryExportMap.get(category)
      if (!categoryExport) {
        return
      }
      
      // Calculate kernel density estimate for violin shape
      const densityValues = categoryData.map(p => p.displayY)
      const density = this.calculateDensity(densityValues, yDisplayMin, yDisplayMax, 50)
      const maxDensity = Math.max(...density.map(d => d.density))
      categoryExport.density = density.map(d => ({
        value: this.inverseTransformValueForScale(d.value, yScaleDef),
        displayValue: d.value,
        density: d.density
      }))
      categoryExport.maxDensity = maxDensity || 1
      
      // Draw violin outline
      const outlineColor = categoryExport.outlineColor
      ctx.strokeStyle = outlineColor
      ctx.lineWidth = 2
      ctx.beginPath()
      
      // Right side of violin
      for (let i = 0; i < density.length; i++) {
        const x = centerX + (density[i].density / maxDensity) * (violinWidth / 2)
        const y = scaleDisplayY(density[i].value)
        if (i === 0) {
          ctx.moveTo(x, y)
        } else {
          ctx.lineTo(x, y)
        }
      }
      
      // Left side of violin
      for (let i = density.length - 1; i >= 0; i--) {
        const x = centerX - (density[i].density / maxDensity) * (violinWidth / 2)
        const y = scaleDisplayY(density[i].value)
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
      categoryExport.label = {
        angleDegrees: angle * (180 / Math.PI),
        endX: textEndX,
        endY: textEndY
      }
    })
    
    this.lastPlotExportData = {
      type: 'violin',
      width,
      height,
      background: '#ffffff',
      axisScales: {
        x: 'categorical',
        y: yScaleType
      },
      skippedDueToScale,
      yScale: {
        min: yMin,
        max: yMax,
        range: yRange,
        scale: yScaleType,
        displayMin: yDisplayMin,
        displayMax: yDisplayMax,
        topPadding,
        bottomPadding,
        height
      },
      grid: {
        horizontal: {
          positions: horizontalGridLines,
          left: sidePadding,
          right: width - sidePadding,
          color: gridStroke
        }
      },
      axes: {
        color: axisStroke,
        x: {
          line: { x1: sidePadding, x2: width - sidePadding, y: height - bottomPadding },
          label: {
            lines: xLines,
            baseY: height - bottomPadding + maxTextHeight + 15,
            lineSpacing: 16,
            fontSize: 13,
            x: width / 2
          }
        },
        y: {
          axisX: sidePadding,
          line: { y1: topPadding, y2: height - bottomPadding },
          ticks: yTicks,
          tickLength: 5,
          tickLabelOffset: 8,
          tickFontSize: 11,
          scale: yScaleType,
          domainMin: yMin,
          domainMax: yMax,
          displayMin: yDisplayMin,
          displayMax: yDisplayMax,
          label: {
            lines: yLines,
            translateX: 15,
            translateY: height / 2,
            lineSpacing: 16,
            fontSize: 13
          }
        }
      },
      categories: categoriesExport,
      layout: {
        pointRadius: pointSize,
        sidePadding,
        topPadding,
        bottomPadding,
        violinWidth,
        pointAreaWidth
      }
    }
    
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

  getScaleDefinition(scale) {
    if (scale === 'log2') {
      return { type: 'log', base: 2 }
    }
    if (scale === 'log10') {
      return { type: 'log', base: 10 }
    }
    return { type: 'linear', base: Math.E }
  }

  transformValueForScale(value, scaleDef) {
    if (!Number.isFinite(value)) {
      return null
    }
    if (!scaleDef || scaleDef.type === 'linear') {
      return value
    }
    if (scaleDef.type === 'log') {
      if (value <= 0) {
        return null
      }
      return Math.log(value) / Math.log(scaleDef.base)
    }
    return value
  }

  inverseTransformValueForScale(value, scaleDef) {
    if (!Number.isFinite(value)) {
      return null
    }
    if (!scaleDef || scaleDef.type === 'linear') {
      return value
    }
    if (scaleDef.type === 'log') {
      return Math.pow(scaleDef.base, value)
    }
    return value
  }

  generateAxisTicks(scaleDef, domainMin, domainMax) {
    if (!Number.isFinite(domainMin) || !Number.isFinite(domainMax)) {
      return []
    }
    if (scaleDef && scaleDef.type === 'log') {
      const safeMin = Math.max(domainMin, Number.MIN_VALUE)
      return this.generateLogTicks(safeMin, domainMax, scaleDef.base)
    }
    return this.generateLinearTicks(domainMin, domainMax)
  }

  generateLinearTicks(min, max) {
    if (!Number.isFinite(min) || !Number.isFinite(max)) {
      return []
    }
    if (min === max) {
      return [min]
    }
    const range = max - min || 1
    const spacing = this.calculateTickSpacing(range)
    if (!Number.isFinite(spacing) || spacing <= 0) {
      return this.uniqueSortedTicks([min, max])
    }
    const ticks = []
    const start = Math.ceil(min / spacing) * spacing
    const maxIterations = 60
    let value = start
    let iterations = 0
    while (value <= max + spacing * 0.5 && iterations < maxIterations) {
      ticks.push(Number(value.toFixed(12)))
      value += spacing
      iterations++
    }
    ticks.push(min)
    ticks.push(max)
    const unique = this.uniqueSortedTicks(ticks)
    return this.limitTicksCount(unique)
  }

  generateLogTicks(min, max, base) {
    if (!Number.isFinite(min) || !Number.isFinite(max) || min <= 0 || max <= 0) {
      return []
    }
    if (min === max) {
      return [min]
    }
    const logMin = Math.log(min) / Math.log(base)
    const logMax = Math.log(max) / Math.log(base)
    const startPower = Math.floor(logMin)
    const endPower = Math.ceil(logMax)
    const ticks = []

    for (let power = startPower; power <= endPower; power++) {
      const tick = Math.pow(base, power)
      if (tick >= min && tick <= max) {
        ticks.push(tick)
      }
    }

    ticks.push(min)
    ticks.push(max)
    const unique = this.uniqueSortedTicks(ticks)
    return this.limitTicksCount(unique)
  }

  uniqueSortedTicks(values) {
    if (!Array.isArray(values)) {
      return []
    }
    const sorted = values
      .filter(Number.isFinite)
      .sort((a, b) => a - b)

    const unique = []
    const epsilon = 1e-9
    for (const value of sorted) {
      if (unique.length === 0 || Math.abs(value - unique[unique.length - 1]) > epsilon) {
        unique.push(value)
      }
    }
    return unique
  }

  limitTicksCount(ticks, maxCount = 12) {
    if (!Array.isArray(ticks) || ticks.length === 0) {
      return []
    }
    if (ticks.length <= maxCount) {
      return ticks
    }
    if (maxCount <= 2) {
      return [ticks[0], ticks[ticks.length - 1]]
    }

    const result = []
    const step = (ticks.length - 1) / (maxCount - 1)

    for (let i = 0; i < maxCount; i++) {
      const index = Math.round(i * step)
      result.push(ticks[Math.min(index, ticks.length - 1)])
    }

    return this.uniqueSortedTicks(result)
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



