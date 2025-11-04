/**
 * ReGL-based WebGL renderer for high-performance scatter plot visualization
 * Optimized for rendering 500k+ points with fast buffer updates
 */

import createREGL from 'regl'

export class ReglRenderer {
  constructor(canvas) {
    // Generate unique ID for this renderer instance to track scope issues
    this.instanceId = Math.random().toString(36).substring(7)
    console.log(`🚀 [ReGL] Creating new ReglRenderer instance - ID: ${this.instanceId}`)
    console.log(`🚀 [ReGL] Canvas element:`, canvas)
    console.log(`🚀 [ReGL] Canvas dimensions: ${canvas.width}x${canvas.height}`)
    console.log(`🚀 [ReGL] Canvas parent:`, canvas.parentElement)
    console.trace(`🚀 [ReGL] ReglRenderer constructor call stack for instance ${this.instanceId}:`)
    
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
    
    // Buffers
    this.positionBuffer = null
    this.colorBuffer = null
    
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
  }
  
  /**
   * Set point positions from coordinate array
   * @param {Float32Array} coordinates - Flat array of x,y pairs [x1,y1,x2,y2,...]
   */
  setPositions(coordinates) {
    const startTime = performance.now()
    console.log('🚀 [ReGL] setPositions called with:', typeof coordinates, coordinates.length)
    
    // coordinates is a flat Float32Array: [x1, y1, x2, y2, x3, y3, ...]
    // So number of points = length / 2
    if (coordinates instanceof Float32Array) {
      this.numPoints = coordinates.length / 2
      this.positions = coordinates
      console.log('🚀 [ReGL] Using Float32Array, numPoints:', this.numPoints)
    } else {
      // Fallback: convert array of pairs to Float32Array
      this.numPoints = coordinates.length
      this.positions = new Float32Array(this.numPoints * 2)
      for (let i = 0; i < this.numPoints; i++) {
        this.positions[i * 2] = coordinates[i][0]
        this.positions[i * 2 + 1] = coordinates[i][1]
      }
      console.log('🚀 [ReGL] Converted to Float32Array, numPoints:', this.numPoints)
    }
    
    console.log('🚀 [ReGL] Creating position buffer...')
    // Create or update buffer
    if (this.positionBuffer) {
      this.positionBuffer.destroy()
    }
    this.positionBuffer = this.regl.buffer(this.positions)
    console.log('🚀 [ReGL] Position buffer created')
    
    // Initialize colors if needed
    if (!this.colors || this.colors.length !== this.numPoints * 4) {
      console.log('🚀 [ReGL] Initializing default colors...')
      this.initializeDefaultColors()
    }
    
    const elapsed = performance.now() - startTime
    console.log(`🚀 [ReGL] Set ${this.numPoints.toLocaleString()} positions in ${elapsed.toFixed(2)}ms`)
    
    return this
  }
  
  /**
   * Fast update of positions using buffer.subdata()
   * This is the key performance advantage of ReGL over PixiJS sprites
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
    console.log(`⚡ [ReGL] Updated ${this.numPoints.toLocaleString()} positions in ${elapsed.toFixed(2)}ms (${pointsPerSec} points/sec)`)
    
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
   * Update colors for specific point indices
   * @param {Map<number, number>} colorMap - Map of point index -> hex color
   */
  updateColors(colorMap) {
    const startTime = performance.now()
    
    console.log(`🎨 [ReGL] updateColors called with ${colorMap.size} color updates`)
    console.log(`🎨 [ReGL] Renderer state: numPoints=${this.numPoints}, colorsLength=${this.colors?.length || 0}, hasColorBuffer=${!!this.colorBuffer}`)
    
    if (!this.colors || !this.colorBuffer) {
      console.error('🎨 [ReGL] ERROR: Cannot update colors - colors array or colorBuffer missing')
      return this
    }
    
    let transparentCount = 0
    let visibleCount = 0
    const sampleUpdates = []
    
    colorMap.forEach((hexColor, index) => {
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
        
        if (sampleUpdates.length < 5 && index < 100) {
          sampleUpdates.push(`idx${index}: transparent (0x00000000)`)
        }
      }
      // Check if this is an RGBA color (> 0xFFFFFF means 32-bit RGBA)
      else if (hexColor > 0xFFFFFF) {
        // RGBA format: 0xRRGGBBAA
        const r = ((hexColor >>> 24) & 0xFF) / 255
        const g = ((hexColor >>> 16) & 0xFF) / 255
        const b = ((hexColor >>> 8) & 0xFF) / 255
        const a = (hexColor & 0xFF) / 255
        
        this.colors[offset] = r
        this.colors[offset + 1] = g
        this.colors[offset + 2] = b
        this.colors[offset + 3] = a
        visibleCount++
        
        if (sampleUpdates.length < 5 && index < 100) {
          sampleUpdates.push(`idx${index}: rgba(${r.toFixed(2)},${g.toFixed(2)},${b.toFixed(2)},${a.toFixed(2)})`)
        }
      } else {
        // RGB format: 0xRRGGBB - set alpha to 1.0 (fully opaque)
        const r = ((hexColor >> 16) & 0xFF) / 255
        const g = ((hexColor >> 8) & 0xFF) / 255
        const b = (hexColor & 0xFF) / 255
        
        this.colors[offset] = r
        this.colors[offset + 1] = g
        this.colors[offset + 2] = b
        this.colors[offset + 3] = 1.0 // Always set to fully opaque for normal colors
        visibleCount++
        
        if (sampleUpdates.length < 5 && index < 100) {
          sampleUpdates.push(`idx${index}: rgb(${r.toFixed(2)},${g.toFixed(2)},${b.toFixed(2)}) alpha=1.0`)
        }
      }
    })
    
    console.log(`🎨 [ReGL] Color updates: ${visibleCount} visible, ${transparentCount} hidden`)
    console.log(`🎨 [ReGL] Sample color updates:`, sampleUpdates.slice(0, 5))
    
    console.log(`🎨 [ReGL] Updating color buffer with subdata...`)
    this.colorBuffer.subdata(this.colors)
    console.log(`🎨 [ReGL] Color buffer updated`)
    
    // Verify a few color values after update
    const verifyIndices = [0, 100, 1000]
    console.log(`🎨 [ReGL] Verifying colors after update:`)
    verifyIndices.forEach(idx => {
      if (idx < this.numPoints) {
        const offset = idx * 4
        const r = this.colors[offset]
        const g = this.colors[offset + 1]
        const b = this.colors[offset + 2]
        const a = this.colors[offset + 3]
        console.log(`🎨 [ReGL]   idx ${idx}: rgba(${r.toFixed(3)},${g.toFixed(3)},${b.toFixed(3)},${a.toFixed(3)})`)
      }
    })
    
    const elapsed = performance.now() - startTime
    console.log(`🎨 [ReGL] Updated ${colorMap.size.toLocaleString()} colors in ${elapsed.toFixed(2)}ms`)
    
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
   * Render the current frame
   */
  render() {
    console.log('🚀 [ReGL] render() called')
    
    if (!this.positionBuffer || !this.colorBuffer) {
      console.log('🚀 [ReGL] Missing buffers, skipping render')
      console.log('🚀 [ReGL] Buffer state:', {
        hasPositionBuffer: !!this.positionBuffer,
        hasColorBuffer: !!this.colorBuffer,
        numPoints: this.numPoints
      })
      return
    }
    
    // Calculate count from positions if numPoints is not set or is 0
    let count = this.numPoints
    if (!count || count === 0) {
      if (this.positions && this.positions.length > 0) {
        // positions is Float32Array: [x1, y1, x2, y2, ...], so count = length / 2
        count = this.positions.length / 2
        console.log('🚀 [ReGL] Calculated count from positions array:', count)
        // Update numPoints for future use
        this.numPoints = count
      } else {
        console.log('🚀 [ReGL] Cannot determine count - numPoints is 0 and positions not available')
        return
      }
    }
    
    console.log(`🚀 [ReGL] Rendering ${count} points with pointSize=${this.pointSize}`)
    console.log(`🚀 [ReGL] Canvas size: ${this.canvas.width}x${this.canvas.height}`)
    
    // Clear canvas
    this.regl.clear({
      color: [1, 1, 1, 1], // White background
      depth: 1
    })
    
    console.log('🚀 [ReGL] Calling drawPoints...')
    // Draw points (positions are already in screen/pixel coordinates)
    this.drawPoints({
      positions: this.positionBuffer,
      colors: this.colorBuffer,
      count: count,
      pointSize: this.pointSize
    })
    console.log('🚀 [ReGL] drawPoints completed')
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
      console.log('🔄 [ReGL] Viewport updated to:', width, 'x', height)
    }
    
    return this
  }
  
  /**
   * Handle canvas resize (wrapper for resize method)
   */
  handleResize() {
    // Get the actual rendered size of the canvas
    const rect = this.canvas.getBoundingClientRect()
    console.log('🔄 [ReGL] handleResize called:', {
      rectWidth: rect.width,
      rectHeight: rect.height,
      canvasWidth: this.canvas.width,
      canvasHeight: this.canvas.height
    })
    
    if (rect.width > 0 && rect.height > 0) {
      this.resize(rect.width, rect.height)
      console.log('🔄 [ReGL] After resize:', {
        canvasWidth: this.canvas.width,
        canvasHeight: this.canvas.height
      })
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
    if (this.regl) this.regl.destroy()
  }
}

