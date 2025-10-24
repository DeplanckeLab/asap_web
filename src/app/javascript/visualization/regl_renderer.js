/**
 * ReGL-based WebGL renderer for high-performance scatter plot visualization
 * Optimized for rendering 500k+ points with fast buffer updates
 */

import createREGL from 'regl'

export class ReglRenderer {
  constructor(canvas) {
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
        uniform vec2 scale;
        uniform vec2 offset;
        uniform vec2 canvasSize;
        
        varying vec4 vColor;
        
        void main() {
          // Apply camera transform
          vec2 transformed = (position + offset) * scale;
          
          // Convert to clip space (-1 to 1)
          vec2 clipSpace = (transformed / canvasSize) * 2.0 - 1.0;
          clipSpace.y *= -1.0; // Flip Y axis
          
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
        scale: this.regl.prop('scale'),
        offset: this.regl.prop('offset'),
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
    
    colorMap.forEach((hexColor, index) => {
      if (index >= this.numPoints) return
      
      const offset = index * 4
      
      // Special case: 0x00000000 means fully transparent (all channels = 0)
      if (hexColor === 0x00000000 || hexColor === 0) {
        this.colors[offset] = 0
        this.colors[offset + 1] = 0
        this.colors[offset + 2] = 0
        this.colors[offset + 3] = 0 // Fully transparent
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
      } else {
        // RGB format: 0xRRGGBB - set alpha to 1.0 (fully opaque)
        const r = ((hexColor >> 16) & 0xFF) / 255
        const g = ((hexColor >> 8) & 0xFF) / 255
        const b = (hexColor & 0xFF) / 255
        
        this.colors[offset] = r
        this.colors[offset + 1] = g
        this.colors[offset + 2] = b
        this.colors[offset + 3] = 1.0 // Always set to fully opaque for normal colors
      }
    })
    
    this.colorBuffer.subdata(this.colors)
    
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
   * Render the current frame
   */
  render() {
    console.log('🚀 [ReGL] render() called')
    console.log('🚀 [ReGL] positionBuffer:', !!this.positionBuffer)
    console.log('🚀 [ReGL] colorBuffer:', !!this.colorBuffer)
    console.log('🚀 [ReGL] numPoints:', this.numPoints)
    
    if (!this.positionBuffer || !this.colorBuffer) {
      console.log('🚀 [ReGL] Missing buffers, skipping render')
      return
    }
    
    console.log('🚀 [ReGL] Clearing canvas...')
    // Clear canvas to white background
    this.regl.clear({
      color: [1, 1, 1, 1], // White background
      depth: 1
    })
    
    console.log('🚀 [ReGL] Drawing points...')
    console.log('🚀 [ReGL] Camera settings:', { scale: this.camera.scale, offsetX: this.camera.offsetX, offsetY: this.camera.offsetY })
    console.log('🚀 [ReGL] Point size:', this.pointSize)
    console.log('🚀 [ReGL] Canvas size:', { width: this.canvas.width, height: this.canvas.height })
    
    // Draw points
    this.drawPoints({
      positions: this.positionBuffer,
      colors: this.colorBuffer,
      count: this.numPoints,
      pointSize: this.pointSize,
      scale: [this.camera.scale, this.camera.scale],
      offset: [this.camera.offsetX, this.camera.offsetY]
    })
    
    console.log('🚀 [ReGL] Render completed')
  }
  
  /**
   * Resize canvas
   */
  resize(width, height) {
    this.canvas.width = width
    this.canvas.height = height
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

