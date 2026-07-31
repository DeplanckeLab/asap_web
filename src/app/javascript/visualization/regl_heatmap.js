/**
 * ReGL-based WebGL heatmap renderer.
 *
 * Renders a genes x columns matrix as a single textured quad. The matrix is
 * uploaded once as an RGBA data texture (R = normalized value, G = validity
 * mask); the fragment shader maps the normalized value through a 1D colormap
 * texture. Zoom/pan are expressed as a visible [colStart,colEnd] x
 * [rowStart,rowEnd] range so the 2D overlay (dendrograms/tracks/labels) can
 * stay aligned.
 */

import createREGL from 'regl'

const COLORMAP_SIZE = 256

export class ReglHeatmap {
  constructor(canvas) {
    this.canvas = canvas
    this.regl = null
    this.draw = null
    this.texture = null
    this.colormapTexture = null
    this.nRows = 0
    this.nCols = 0
    this.vmin = 0
    this.vmax = 1
    this.diverging = true
    this.initialize()
  }

  initialize() {
    this.regl = createREGL({
      canvas: this.canvas,
      // preserveDrawingBuffer so SVG/PNG export can read the canvas reliably
      attributes: { antialias: false, alpha: false, preserveDrawingBuffer: true }
    })

    this.draw = this.regl({
      vert: `
        precision highp float;
        attribute vec2 position;
        varying vec2 vPos;
        void main() {
          // vPos: 0..1 across the canvas, y = 0 at the top.
          vPos = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
          gl_Position = vec4(position, 0.0, 1.0);
        }
      `,
      frag: `
        precision highp float;
        varying vec2 vPos;
        uniform sampler2D uMatrix;
        uniform sampler2D uColormap;
        uniform vec2 uColRange;
        uniform vec2 uRowRange;
        uniform vec2 uDims;

        void main() {
          float col = mix(uColRange.x, uColRange.y, vPos.x);
          float row = mix(uRowRange.x, uRowRange.y, vPos.y);
          // texture stores row 0 at v=0 (first uploaded row); flip to put row 0 on top
          vec2 uv = vec2(col / uDims.x, 1.0 - (row / uDims.y));
          vec4 texel = texture2D(uMatrix, uv);
          if (texel.g < 0.5) {
            gl_FragColor = vec4(0.88, 0.88, 0.88, 1.0);
            return;
          }
          float t = clamp(texel.r, 0.0, 1.0);
          vec3 c = texture2D(uColormap, vec2(t, 0.5)).rgb;
          gl_FragColor = vec4(c, 1.0);
        }
      `,
      attributes: {
        position: [[-1, -1], [1, -1], [-1, 1], [-1, 1], [1, -1], [1, 1]]
      },
      uniforms: {
        uMatrix: () => this.texture,
        uColormap: () => this.colormapTexture,
        uColRange: this.regl.prop('colRange'),
        uRowRange: this.regl.prop('rowRange'),
        uDims: () => [this.nCols, this.nRows]
      },
      count: 6
    })

    this.setColormap(true)
  }

  setColormap(diverging) {
    this.diverging = !!diverging
    const lut = new Uint8Array(COLORMAP_SIZE * 4)
    for (let i = 0; i < COLORMAP_SIZE; i++) {
      const t = i / (COLORMAP_SIZE - 1)
      const rgb = this.diverging ? this.divergingColor(t) : this.sequentialColor(t)
      const o = i * 4
      lut[o] = rgb[0]
      lut[o + 1] = rgb[1]
      lut[o + 2] = rgb[2]
      lut[o + 3] = 255
    }
    this.uploadColormap(lut)
  }

  // controlPoints: [{ position: 0..1, color: 0xRRGGBB }, ...]
  // colorAt: optional (normalized) => 0xRRGGBB for interpolation consistent with editor
  setColormapFromControlPoints(controlPoints, colorAt = null) {
    const points = Array.isArray(controlPoints) ? [...controlPoints] : []
    points.sort((a, b) => a.position - b.position)
    if (!points.length) {
      this.setColormap(this.diverging)
      return
    }

    const lut = new Uint8Array(COLORMAP_SIZE * 4)
    for (let i = 0; i < COLORMAP_SIZE; i++) {
      const t = i / (COLORMAP_SIZE - 1)
      const colorInt = typeof colorAt === 'function'
        ? colorAt(t)
        : this.interpolateControlPoints(points, t)
      const o = i * 4
      lut[o] = (colorInt >> 16) & 0xFF
      lut[o + 1] = (colorInt >> 8) & 0xFF
      lut[o + 2] = colorInt & 0xFF
      lut[o + 3] = 255
    }
    this.uploadColormap(lut)
  }

  interpolateControlPoints(sorted, t) {
    if (t <= sorted[0].position) return sorted[0].color
    if (t >= sorted[sorted.length - 1].position) return sorted[sorted.length - 1].color
    let left = sorted[0]
    let right = sorted[sorted.length - 1]
    for (let i = 0; i < sorted.length - 1; i++) {
      if (t >= sorted[i].position && t <= sorted[i + 1].position) {
        left = sorted[i]
        right = sorted[i + 1]
        break
      }
    }
    const span = right.position - left.position
    const u = span > 0 ? (t - left.position) / span : 0
    const r1 = (left.color >> 16) & 0xFF
    const g1 = (left.color >> 8) & 0xFF
    const b1 = left.color & 0xFF
    const r2 = (right.color >> 16) & 0xFF
    const g2 = (right.color >> 8) & 0xFF
    const b2 = right.color & 0xFF
    const r = Math.round(r1 + (r2 - r1) * u)
    const g = Math.round(g1 + (g2 - g1) * u)
    const b = Math.round(b1 + (b2 - b1) * u)
    return (r << 16) | (g << 8) | b
  }

  uploadColormap(lut) {
    if (this.colormapTexture) {
      this.colormapTexture.destroy()
    }
    this.colormapTexture = this.regl.texture({
      width: COLORMAP_SIZE,
      height: 1,
      data: lut,
      format: 'rgba',
      type: 'uint8',
      mag: 'linear',
      min: 'linear',
      flipY: false
    })
  }

  divergingColor(t) {
    // blue - white - red (matches previous shader)
    const low = [59, 77, 191]
    const mid = [247, 247, 247]
    const high = [181, 23, 26]
    if (t < 0.5) return this.mixRgb(low, mid, t * 2)
    return this.mixRgb(mid, high, (t - 0.5) * 2)
  }

  sequentialColor(t) {
    // dark blue -> teal -> yellow
    const c0 = [69, 10, 84]
    const c1 = [33, 145, 140]
    const c2 = [252, 231, 40]
    if (t < 0.5) return this.mixRgb(c0, c1, t * 2)
    return this.mixRgb(c1, c2, (t - 0.5) * 2)
  }

  mixRgb(a, b, t) {
    return [
      Math.round(a[0] + (b[0] - a[0]) * t),
      Math.round(a[1] + (b[1] - a[1]) * t),
      Math.round(a[2] + (b[2] - a[2]) * t)
    ]
  }

  /**
   * Upload a matrix. values is a Float32Array of length nRows*nCols (row-major).
   * NaN entries render as a grey "missing" cell.
   * normalizeValue(v, vmin, vmax) optional custom mapper returning 0..1.
   */
  setMatrix(values, nRows, nCols, vmin, vmax, normalizeValue = null) {
    this.nRows = nRows
    this.nCols = nCols
    this.vmin = vmin
    this.vmax = vmax

    const span = (vmax - vmin) || 1
    const rgba = new Uint8Array(nRows * nCols * 4)
    for (let i = 0; i < nRows * nCols; i++) {
      const v = values[i]
      const o = i * 4
      if (v === null || v === undefined || Number.isNaN(v)) {
        rgba[o] = 0
        rgba[o + 1] = 0 // invalid
        rgba[o + 2] = 0
        rgba[o + 3] = 255
      } else {
        let norm = typeof normalizeValue === 'function'
          ? normalizeValue(v, vmin, vmax)
          : (v - vmin) / span
        norm = norm < 0 ? 0 : (norm > 1 ? 1 : norm)
        rgba[o] = Math.round(norm * 255)
        rgba[o + 1] = 255 // valid
        rgba[o + 2] = 0
        rgba[o + 3] = 255
      }
    }

    if (this.texture) {
      this.texture.destroy()
    }
    this.texture = this.regl.texture({
      width: nCols,
      height: nRows,
      data: rgba,
      format: 'rgba',
      type: 'uint8',
      mag: 'nearest',
      min: 'nearest',
      flipY: false
    })
  }

  render(view) {
    if (!this.texture || !this.colormapTexture) return
    this.regl.poll()
    this.regl.clear({ color: [1, 1, 1, 1], depth: 1 })
    this.draw({
      colRange: [view.colStart, view.colEnd],
      rowRange: [view.rowStart, view.rowEnd]
    })
  }

  destroy() {
    if (this.texture) {
      this.texture.destroy()
      this.texture = null
    }
    if (this.colormapTexture) {
      this.colormapTexture.destroy()
      this.colormapTexture = null
    }
    if (this.regl) {
      this.regl.destroy()
      this.regl = null
    }
  }
}
