/**
 * ReGL-based WebGL renderer for high-performance scatter plot visualization
 * Optimized for rendering 500k+ points with fast buffer updates
 */

import createREGL from 'regl'

export class ReglRenderer {
  constructor(canvas) {
    // Generate unique ID for this renderer instance to track scope issues
    this.instanceId = Math.random().toString(36).substring(7)
    // console.log(`🚀 [ReGL] Creating new ReglRenderer instance - ID: ${this.instanceId}`)
    // console.log(`🚀 [ReGL] Canvas element:`, canvas)
    // console.log(`🚀 [ReGL] Canvas dimensions: ${canvas.width}x${canvas.height}`)
    // console.log(`🚀 [ReGL] Canvas parent:`, canvas.parentElement)
    //console.trace(`🚀 [ReGL] ReglRenderer constructor call stack for instance ${this.instanceId}:`)
    
    // Store creation timestamp for debugging
    this.createdAt = Date.now()
    this.createdAtTime = new Date().toISOString()
    
    this.canvas = canvas
    this.regl = null
    this.drawPoints = null
    
    // State
    this.positions = null  // Float32Array of [x, y] pairs
    this.colors = null     // Float32Array of [r, g, b, a] per point
    this.numPoints = 0
    this.pointSize = 4
    
    // Camera state
    this.camera = {
      scale: 1.0,
      offsetX: 0,
      offsetY: 0
    }
    
    // Background tissue image (spatial/Visium view)
    this.backgroundTexture = null
    this.backgroundCornersProvider = null
    this.backgroundImageOpacity = 1.0
    this.imagePositionBuffer = null
    this.imageTexcoordBuffer = null
    this.drawImage = null

    // Buffers
    this.positionBuffer = null
    this.colorBuffer = null
    this.byteToFloat = new Float32Array(256)
    for (let i = 0; i < 256; i++) {
      this.byteToFloat[i] = i / 255
    }
    
    this.initialize()
  }
  
  initialize() {
    // Create ReGL context
    this.regl = createREGL({
      canvas: this.canvas,
      attributes: {
        antialias: true,
        alpha: true,
        preserveDrawingBuffer: false
      }
    })
    
    // Create the draw command
    this.drawPoints = this.regl({
      // Vertex shader
      vert: `
        precision highp float;
        
        attribute vec2 position;
        attribute vec4 color;
        
        uniform float pointSize;
        uniform vec2 canvasSize;
        
        varying vec4 vColor;
        
        void main() {
          // Position is in SCREEN COORDINATES (pixel space from 0 to canvasSize)
          // Convert to normalized device coordinates (0 to 1)
          vec2 normalizedPos = position / canvasSize;
          
          // Convert to clip space (-1 to 1)
          vec2 clipSpace = normalizedPos * 2.0 - 1.0;
          clipSpace.y *= -1.0; // Flip Y axis (screen Y increases downward, OpenGL increases upward)
          
          gl_Position = vec4(clipSpace, 0.0, 1.0);
          gl_PointSize = pointSize;
          
          vColor = color;
        }
      `,
      
      // Fragment shader
      frag: `
        precision highp float;
        
        varying vec4 vColor;
        
        void main() {
          // Make points circular
          vec2 center = gl_PointCoord - vec2(0.5, 0.5);
          float dist = length(center);
          if (dist > 0.5) {
            discard;
          }
          
          // Anti-aliasing
          float alpha = smoothstep(0.5, 0.4, dist);
          gl_FragColor = vec4(vColor.rgb, vColor.a * alpha);
        }
      `,
      
      attributes: {
        position: this.regl.prop('positions'),
        color: this.regl.prop('colors')
      },
      
      uniforms: {
        pointSize: this.regl.prop('pointSize'),
        canvasSize: ({ viewportWidth, viewportHeight }) => [viewportWidth, viewportHeight]
      },
      
      count: this.regl.prop('count'),
      primitive: 'points',
      
      blend: {
        enable: true,
        func: {
          srcRGB: 'src alpha',
          srcAlpha: 'one',
          dstRGB: 'one minus src alpha',
          dstAlpha: 'one minus src alpha'
        }
      },
      
      depth: {
        enable: false
      }
    })

    // Draw command for the tissue background image (textured quad).
    // Corner positions are supplied in screen/pixel space, matching the point
    // positions, so the image stays aligned with the spots under pan/zoom.
    this.drawImage = this.regl({
      vert: `
        precision highp float;

        attribute vec2 position;
        attribute vec2 texcoord;

        uniform vec2 canvasSize;

        varying vec2 vTexcoord;

        void main() {
          vec2 normalizedPos = position / canvasSize;
          vec2 clipSpace = normalizedPos * 2.0 - 1.0;
          clipSpace.y *= -1.0;
          gl_Position = vec4(clipSpace, 0.0, 1.0);
          vTexcoord = texcoord;
        }
      `,

      frag: `
        precision highp float;

        varying vec2 vTexcoord;

        uniform sampler2D tissue;
        uniform float opacity;

        void main() {
          vec4 texColor = texture2D(tissue, vTexcoord);
          gl_FragColor = vec4(texColor.rgb, texColor.a * opacity);
        }
      `,

      attributes: {
        position: this.regl.prop('positions'),
        texcoord: this.regl.prop('texcoords')
      },

      uniforms: {
        canvasSize: ({ viewportWidth, viewportHeight }) => [viewportWidth, viewportHeight],
        tissue: this.regl.prop('texture'),
        opacity: this.regl.prop('opacity')
      },

      count: 6,
      primitive: 'triangles',

      blend: {
        enable: true,
        func: {
          srcRGB: 'src alpha',
          srcAlpha: 'one',
          dstRGB: 'one minus src alpha',
          dstAlpha: 'one minus src alpha'
        }
      },

      depth: {
        enable: false
      }
    })
  }

  /**
   * Set (or replace) the tissue background image for the spatial view.
   * @param {HTMLImageElement|ImageBitmap|HTMLCanvasElement} image - decoded image
   * @param {Function} cornersProvider - returns { tl, tr, br, bl } screen-space
   *   corner coordinates ([x, y]) for the current pan/zoom, or null
   * @param {number} opacity - image opacity (0..1)
   */
  setBackgroundImage(image, cornersProvider, opacity = 1.0) {
    if (this.backgroundTexture) {
      this.backgroundTexture.destroy()
      this.backgroundTexture = null
    }

    if (!image) {
      this.backgroundCornersProvider = null
      return this
    }

    this.backgroundTexture = this.regl.texture({
      data: image,
      flipY: false,
      min: 'linear',
      mag: 'linear',
      wrapS: 'clamp',
      wrapT: 'clamp'
    })
    this.backgroundCornersProvider = typeof cornersProvider === 'function' ? cornersProvider : null
    this.backgroundImageOpacity = opacity

    if (!this.imagePositionBuffer) {
      this.imagePositionBuffer = this.regl.buffer(new Float32Array(12))
    }
    if (!this.imageTexcoordBuffer) {
      // Two triangles: TL, TR, BR / TL, BR, BL
      this.imageTexcoordBuffer = this.regl.buffer(new Float32Array([
        0, 0, 1, 0, 1, 1,
        0, 0, 1, 1, 0, 1
      ]))
    }

    return this
  }

  /**
   * Remove the tissue background image (e.g. switching to a non-spatial embedding).
   */
  clearBackgroundImage() {
    if (this.backgroundTexture) {
      this.backgroundTexture.destroy()
      this.backgroundTexture = null
    }
    this.backgroundCornersProvider = null
    return this
  }

  setBackgroundImageOpacity(opacity) {
    this.backgroundImageOpacity = opacity
    return this
  }

  hasBackgroundImage() {
    return !!(this.backgroundTexture && this.backgroundCornersProvider)
  }

  /**
   * Draw the tissue background image using the current pan/zoom transform.
   */
  drawBackgroundImage() {
    if (!this.hasBackgroundImage()) return

    const corners = this.backgroundCornersProvider()
    if (!corners || !corners.tl || !corners.tr || !corners.br || !corners.bl) return

    const { tl, tr, br, bl } = corners
    const positions = new Float32Array([
      tl[0], tl[1], tr[0], tr[1], br[0], br[1],
      tl[0], tl[1], br[0], br[1], bl[0], bl[1]
    ])
    this.imagePositionBuffer.subdata(positions)

    this.drawImage({
      positions: this.imagePositionBuffer,
      texcoords: this.imageTexcoordBuffer,
      texture: this.backgroundTexture,
      opacity: this.backgroundImageOpacity
    })
  }
  
  /**
   * Set point positions from coordinate array
   * @param {Float32Array} coordinates - Flat array of x,y pairs [x1,y1,x2,y2,...]
   */
  setPositions(coordinates) {
    const startTime = performance.now()
    // console.log('🚀 [ReGL] setPositions called with:', typeof coordinates, coordinates.length)
    
    // coordinates is a flat Float32Array: [x1, y1, x2, y2, x3, y3, ...]
    // So number of points = length / 2
    if (coordinates instanceof Float32Array) {
      this.numPoints = coordinates.length / 2
      this.positions = coordinates
      // console.log('🚀 [ReGL] Using Float32Array, numPoints:', this.numPoints)
    } else {
      // Fallback: convert array of pairs to Float32Array
      this.numPoints = coordinates.length
      this.positions = new Float32Array(this.numPoints * 2)
      for (let i = 0; i < this.numPoints; i++) {
        this.positions[i * 2] = coordinates[i][0]
        this.positions[i * 2 + 1] = coordinates[i][1]
      }
      // console.log('🚀 [ReGL] Converted to Float32Array, numPoints:', this.numPoints)
    }
    
    // console.log('🚀 [ReGL] Creating position buffer...')
    // Create or update buffer
    if (this.positionBuffer) {
      this.positionBuffer.destroy()
    }
    this.positionBuffer = this.regl.buffer(this.positions)
    // console.log('🚀 [ReGL] Position buffer created')
    
    // Initialize colors if needed
    if (!this.colors || this.colors.length !== this.numPoints * 4) {
      // console.log('🚀 [ReGL] Initializing default colors...')
      this.initializeDefaultColors()
    }
    
    const elapsed = performance.now() - startTime
    // console.log(`🚀 [ReGL] Set ${this.numPoints.toLocaleString()} positions in ${elapsed.toFixed(2)}ms`)
    
    return this
  }
  
  /**
   * Fast update of positions using buffer.subdata()
   * This is the key performance advantage of ReGL over many sprite-based renderers
   */
  updatePositions(coordinates) {
    const startTime = performance.now()
    
    // Check if it's a Float32Array (flat) or array of pairs
    const newNumPoints = coordinates instanceof Float32Array ? coordinates.length / 2 : coordinates.length
    
    if (newNumPoints !== this.numPoints) {
      console.warn(`[ReGL] Point count mismatch (${newNumPoints} vs ${this.numPoints}), using full setPositions()`)
      return this.setPositions(coordinates)
    }
    
    // Convert to Float32Array if needed
    if (coordinates instanceof Float32Array) {
      this.positions = coordinates
    } else {
      // Convert array of pairs to flat Float32Array
      for (let i = 0; i < this.numPoints; i++) {
        this.positions[i * 2] = coordinates[i][0]
        this.positions[i * 2 + 1] = coordinates[i][1]
      }
    }
    
    // Fast GPU buffer update - THIS IS THE MAGIC! 🎯
    this.positionBuffer.subdata(this.positions)
    
    const elapsed = performance.now() - startTime
    const pointsPerSec = (this.numPoints / elapsed * 1000).toLocaleString(Math.floor)
    // console.log(`⚡ [ReGL] Updated ${this.numPoints.toLocaleString()} positions in ${elapsed.toFixed(2)}ms (${pointsPerSec} points/sec)`)
    
    return this
  }
  
  /**
   * Initialize all points to default blue color
   */
  initializeDefaultColors() {
    this.colors = new Float32Array(this.numPoints * 4)
    const defaultColor = { r: 0.231, g: 0.510, b: 0.965, a: 0.8 } // #3b82f6 with 80% opacity
    
    for (let i = 0; i < this.numPoints; i++) {
      const offset = i * 4
      this.colors[offset] = defaultColor.r
      this.colors[offset + 1] = defaultColor.g
      this.colors[offset + 2] = defaultColor.b
      this.colors[offset + 3] = defaultColor.a
    }
    
    if (this.colorBuffer) {
      this.colorBuffer.destroy()
    }
    this.colorBuffer = this.regl.buffer(this.colors)
    
    return this
  }
  
  /**
   * Update colors for all points in draw order.
   * Supports Map<number, number> and typed arrays (Uint32Array/Array<number>).
   */
  /**
   * Fast path: upload a pre-expanded Float32Array of RGBA (length = numPoints * 4).
   */
  updateColorsFloat32(floatColors) {
    const startTime = performance.now()
    if (!this.colors || !this.colorBuffer) {
      console.error('🎨 [ReGL] ERROR: Cannot update colors - colors array or colorBuffer missing')
      return this
    }
    if (!(floatColors instanceof Float32Array) || floatColors.length !== this.numPoints * 4) {
      throw new Error(`updateColorsFloat32 expected Float32Array of length ${this.numPoints * 4}, got ${floatColors?.length}`)
    }
    this.colors.set(floatColors)
    this.colorBuffer.subdata(this.colors)
    const elapsed = performance.now() - startTime
    try {
      if (localStorage.getItem('vizPerfLogging') === '1') {
        console.log(`[PERF] regl_updateColorsFloat32: ${elapsed.toFixed(2)}ms`, {
          points: this.numPoints
        })
      }
    } catch (error) {
      // Ignore localStorage access errors
    }
    return this
  }

  updateColors(colorData) {
    const startTime = performance.now()
    
    const colorCount = (colorData && typeof colorData.length === 'number')
      ? colorData.length
      : (colorData?.size || 0)
    // console.log(`🎨 [ReGL] updateColors called with ${colorCount} color updates`)
    // console.log(`🎨 [ReGL] Renderer state: numPoints=${this.numPoints}, colorsLength=${this.colors?.length || 0}, hasColorBuffer=${!!this.colorBuffer}`)
    
    if (!this.colors || !this.colorBuffer) {
      console.error('🎨 [ReGL] ERROR: Cannot update colors - colors array or colorBuffer missing')
      return this
    }
    
    let transparentCount = 0
    let visibleCount = 0
    const byteToFloat = this.byteToFloat

    const applyColorAtIndex = (index, hexColor) => {
      if (index >= this.numPoints) {
        console.warn(`🎨 [ReGL] WARNING: Index ${index} >= numPoints ${this.numPoints}, skipping`)
        return
      }
      
      const offset = index * 4
      
      // Special case: 0x00000000 means fully transparent (all channels = 0)
      if (hexColor === 0x00000000 || hexColor === 0) {
        this.colors[offset] = 0
        this.colors[offset + 1] = 0
        this.colors[offset + 2] = 0
        this.colors[offset + 3] = 0 // Fully transparent
        transparentCount++
      }
      // Check if this is an RGBA color (> 0xFFFFFF means 32-bit RGBA)
      else if (hexColor > 0xFFFFFF) {
        // RGBA format: 0xRRGGBBAA
        const r = byteToFloat[(hexColor >>> 24) & 0xFF]
        const g = byteToFloat[(hexColor >>> 16) & 0xFF]
        const b = byteToFloat[(hexColor >>> 8) & 0xFF]
        const a = byteToFloat[hexColor & 0xFF]
        
        this.colors[offset] = r
        this.colors[offset + 1] = g
        this.colors[offset + 2] = b
        this.colors[offset + 3] = a
        visibleCount++
      } else {
        // RGB format: 0xRRGGBB - set alpha to 1.0 (fully opaque)
        const r = byteToFloat[(hexColor >> 16) & 0xFF]
        const g = byteToFloat[(hexColor >> 8) & 0xFF]
        const b = byteToFloat[hexColor & 0xFF]
        
        this.colors[offset] = r
        this.colors[offset + 1] = g
        this.colors[offset + 2] = b
        this.colors[offset + 3] = 1.0 // Always set to fully opaque for normal colors
        visibleCount++
      }
    }

    if (colorData && typeof colorData.length === 'number') {
      for (let index = 0; index < colorData.length; index++) {
        applyColorAtIndex(index, colorData[index])
      }
    } else if (colorData && typeof colorData.forEach === 'function') {
      colorData.forEach((hexColor, index) => {
        applyColorAtIndex(index, hexColor)
      })
    }
    
    // console.log(`🎨 [ReGL] Color updates: ${visibleCount} visible, ${transparentCount} hidden`)
    
    // console.log(`🎨 [ReGL] Updating color buffer with subdata...`)
    this.colorBuffer.subdata(this.colors)
    // console.log(`🎨 [ReGL] Color buffer updated`)
    
    // Verify a few color values after update
    const verifyIndices = [0, 100, 1000]
    // console.log(`🎨 [ReGL] Verifying colors after update:`)
    verifyIndices.forEach(idx => {
      if (idx < this.numPoints) {
        const offset = idx * 4
        const r = this.colors[offset]
        const g = this.colors[offset + 1]
        const b = this.colors[offset + 2]
        const a = this.colors[offset + 3]
        // console.log(`🎨 [ReGL]   idx ${idx}: rgba(${r.toFixed(3)},${g.toFixed(3)},${b.toFixed(3)},${a.toFixed(3)})`)
      }
    })
    
    const elapsed = performance.now() - startTime
    try {
      if (localStorage.getItem('vizPerfLogging') === '1') {
        console.log(`[PERF] regl_updateColors: ${elapsed.toFixed(2)}ms`, {
          points: this.numPoints,
          updates: colorCount,
          visible: visibleCount,
          transparent: transparentCount
        })
      }
    } catch (error) {
      // Ignore localStorage access errors
    }
    // console.log(`🎨 [ReGL] Updated ${colorCount.toLocaleString()} colors in ${elapsed.toFixed(2)}ms`)
    
    return this
  }
  
  /**
   * Set all points to a single color
   */
  setAllColors(hexColor, alpha = 0.8) {
    const r = ((hexColor >> 16) & 0xFF) / 255
    const g = ((hexColor >> 8) & 0xFF) / 255
    const b = (hexColor & 0xFF) / 255
    
    for (let i = 0; i < this.numPoints; i++) {
      const offset = i * 4
      this.colors[offset] = r
      this.colors[offset + 1] = g
      this.colors[offset + 2] = b
      this.colors[offset + 3] = alpha
    }
    
    this.colorBuffer.subdata(this.colors)
    
    return this
  }
  
  /**
   * Update camera position and zoom
   */
  setCamera(offsetX, offsetY, scale) {
    this.camera.offsetX = offsetX
    this.camera.offsetY = offsetY
    this.camera.scale = scale
    return this
  }
  
  /**
   * Set point size
   */
  setPointSize(size) {
    this.pointSize = size
    return this
  }
  
  /**
   * Update point size and re-render
   */
  updatePointSize(size) {
    this.setPointSize(size)
    if (this.positionBuffer && this.colorBuffer && this.numPoints > 0) {
      this.render()
    }
    return this
  }

  /**
   * Capture the current frame as a data URL
   */
  captureToDataURL(type = 'image/png') {
    if (!this.regl || !this.regl._gl) {
      console.warn('⚠️ [ReGL] Cannot capture image - WebGL context unavailable')
      return null
    }

    // Ensure the latest frame is rendered before capture
    this.render()

    const gl = this.regl._gl
    const width = this.canvas.width
    const height = this.canvas.height

    if (!width || !height) {
      console.warn('⚠️ [ReGL] Cannot capture image - canvas has zero dimensions')
      return null
    }

    if (typeof gl.finish === 'function') {
      gl.finish()
    }

    const pixels = new Uint8Array(width * height * 4)
    gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels)

    // Create a 2D canvas to convert pixel data into an image
    const outputCanvas = document.createElement('canvas')
    outputCanvas.width = width
    outputCanvas.height = height
    const ctx = outputCanvas.getContext('2d')

    const imageData = ctx.createImageData(width, height)
    const rowSize = width * 4

    // Flip rows vertically (WebGL origin is bottom-left)
    for (let row = 0; row < height; row++) {
      const sourceStart = row * rowSize
      const destStart = (height - row - 1) * rowSize
      imageData.data.set(pixels.subarray(sourceStart, sourceStart + rowSize), destStart)
    }

    ctx.putImageData(imageData, 0, 0)
    return outputCanvas.toDataURL(type)
  }
  
  /**
   * Render the current frame
   */
  render() {
    // console.log('🚀 [ReGL] render() called')
    
    if (!this.positionBuffer || !this.colorBuffer) {
      // console.log('🚀 [ReGL] Missing buffers, skipping render')
      // console.log('🚀 [ReGL] Buffer state:', {
        // hasPositionBuffer: !!this.positionBuffer,
        // hasColorBuffer: !!this.colorBuffer,
        // numPoints: this.numPoints
      // })
      return
    }
    
    // Calculate count from positions if numPoints is not set or is 0
    let count = this.numPoints
    if (!count || count === 0) {
      if (this.positions && this.positions.length > 0) {
        // positions is Float32Array: [x1, y1, x2, y2, ...], so count = length / 2
        count = this.positions.length / 2
        // console.log('🚀 [ReGL] Calculated count from positions array:', count)
        // Update numPoints for future use
        this.numPoints = count
      } else {
        // console.log('🚀 [ReGL] Cannot determine count - numPoints is 0 and positions not available')
        return
      }
    }
    
    // console.log(`🚀 [ReGL] Rendering ${count} points with pointSize=${this.pointSize}`)
    // console.log(`🚀 [ReGL] Canvas size: ${this.canvas.width}x${this.canvas.height}`)
    
    // Clear canvas
    this.regl.clear({
      color: [1, 1, 1, 1], // White background
      depth: 1
    })

    // Draw the tissue background image (spatial view) before the points so the
    // spots are overlaid on top of the tissue.
    this.drawBackgroundImage()

    // console.log('🚀 [ReGL] Calling drawPoints...')
    // Draw points (positions are already in screen/pixel coordinates)
    this.drawPoints({
      positions: this.positionBuffer,
      colors: this.colorBuffer,
      count: count,
      pointSize: this.pointSize
    })
    // console.log('🚀 [ReGL] drawPoints completed')
  }
  
  /**
   * Resize canvas
   */
  resize(width, height) {
    this.canvas.width = width
    this.canvas.height = height
    
    // Update ReGL viewport to match new canvas size
    if (this.regl && this.regl._gl) {
      this.regl._gl.viewport(0, 0, width, height)
      // console.log('🔄 [ReGL] Viewport updated to:', width, 'x', height)
    }
    
    return this
  }
  
  /**
   * Handle canvas resize (wrapper for resize method)
   */
  handleResize() {
    // Get the actual rendered size of the canvas
    const rect = this.canvas.getBoundingClientRect()
    // console.log('🔄 [ReGL] handleResize called:', {
      // rectWidth: rect.width,
      // rectHeight: rect.height,
      // canvasWidth: this.canvas.width,
      // canvasHeight: this.canvas.height
    // })
    
    if (rect.width > 0 && rect.height > 0) {
      this.resize(rect.width, rect.height)
      // console.log('🔄 [ReGL] After resize:', {
        // canvasWidth: this.canvas.width,
        // canvasHeight: this.canvas.height
      // })
      // Re-render with new canvas size
      if (this.positionBuffer && this.colorBuffer && this.numPoints > 0) {
        this.render()
      }
    }
    return this
  }
  
  /**
   * Clean up resources
   */
  destroy() {
    if (this.positionBuffer) this.positionBuffer.destroy()
    if (this.colorBuffer) this.colorBuffer.destroy()
    if (this.backgroundTexture) this.backgroundTexture.destroy()
    if (this.imagePositionBuffer) this.imagePositionBuffer.destroy()
    if (this.imageTexcoordBuffer) this.imageTexcoordBuffer.destroy()
    if (this.regl) this.regl.destroy()
  }
}

