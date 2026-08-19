/**
 * ReGL-based WebGL heatmap renderer.
 *
 * Renders a genes x columns matrix as a single textured quad. The matrix is
 * kept in CPU memory as an RGBA data texture source (R = normalized value,
 * G = validity mask); the fragment shader maps the normalized value through a
 * 1D colormap texture. Zoom/pan are expressed as a visible [colStart,colEnd] x
 * [rowStart,rowEnd] range so the 2D overlay (dendrograms/tracks/labels) can
 * stay aligned.
 *
 * When the full matrix exceeds the GPU MAX_TEXTURE_SIZE, only the current view
 * window is uploaded (downsampled if the window itself is still too large).
 */

import createREGL from 'regl'
import { DEFAULT_NAN_COLOR_INT, nanColorToRgb, parseNanColor } from 'lib/nan_color'

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
    this.sourceRgba = null
    this.maxTextureSize = 4096
    this.texOrigin = [0, 0]
    this.texSize = [1, 1]
    this.textureViewKey = null
    this.fullTextureFits = false
    this.nanColorRgb = nanColorToRgb(DEFAULT_NAN_COLOR_INT)
    this.initialize()
  }

  initialize() {
    this.regl = createREGL({
      canvas: this.canvas,
      // preserveDrawingBuffer so SVG/PNG export can read the canvas reliably
      attributes: { antialias: false, alpha: false, preserveDrawingBuffer: true }
    })

    const gl = this.regl._gl
    const reportedMax = gl && typeof gl.getParameter === 'function'
      ? gl.getParameter(gl.MAX_TEXTURE_SIZE)
      : 0
    this.maxTextureSize = Math.max(64, Number(reportedMax) || 4096)

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
        uniform vec2 uTexOrigin;
        uniform vec2 uTexSize;
        uniform vec3 uNanColor;

        void main() {
          float col = mix(uColRange.x, uColRange.y, vPos.x);
          float row = mix(uRowRange.x, uRowRange.y, vPos.y);
          // Texture covers [uTexOrigin, uTexOrigin + uTexSize) in matrix space.
          // Row 0 is at v=0 in the uploaded buffer; flip so row 0 is on top.
          vec2 uv = vec2(
            (col - uTexOrigin.x) / uTexSize.x,
            1.0 - ((row - uTexOrigin.y) / uTexSize.y)
          );
          if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            gl_FragColor = vec4(0.88, 0.88, 0.88, 1.0);
            return;
          }
          vec4 texel = texture2D(uMatrix, uv);
          if (texel.g < 0.5) {
            gl_FragColor = vec4(uNanColor, 1.0);
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
        uTexOrigin: () => this.texOrigin,
        uTexSize: () => this.texSize,
        uNanColor: () => this.nanColorRgb
      },
      count: 6
    })

    this.setColormap(true)
  }

  setNanColor(colorInt) {
    this.nanColorRgb = nanColorToRgb(parseNanColor(colorInt))
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
    this.nRows = Math.max(0, Number(nRows) || 0)
    this.nCols = Math.max(0, Number(nCols) || 0)
    this.vmin = vmin
    this.vmax = vmax
    this.textureViewKey = null
    this.fullTextureFits = false

    if (this.nRows < 1 || this.nCols < 1) {
      this.sourceRgba = null
      if (this.texture) {
        this.texture.destroy()
        this.texture = null
      }
      return
    }

    const span = (vmax - vmin) || 1
    const rgba = new Uint8Array(this.nRows * this.nCols * 4)
    for (let i = 0; i < this.nRows * this.nCols; i++) {
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
    this.sourceRgba = rgba

    if (this.nCols <= this.maxTextureSize && this.nRows <= this.maxTextureSize) {
      this.uploadTextureRegion(rgba, this.nCols, this.nRows, 0, 0, this.nCols, this.nRows)
      this.fullTextureFits = true
      this.textureViewKey = 'full'
      return
    }

    // Too large for a single GPU texture: keep CPU buffer and upload per view.
    if (this.texture) {
      this.texture.destroy()
      this.texture = null
    }
  }

  uploadTextureRegion(rgba, width, height, originCol, originRow, sizeCols, sizeRows) {
    const safeW = Math.max(1, Math.min(this.maxTextureSize, Math.round(width)))
    const safeH = Math.max(1, Math.min(this.maxTextureSize, Math.round(height)))
    if (this.texture) {
      this.texture.destroy()
    }
    this.texture = this.regl.texture({
      width: safeW,
      height: safeH,
      data: rgba,
      format: 'rgba',
      type: 'uint8',
      mag: 'nearest',
      min: 'nearest',
      flipY: false
    })
    this.texOrigin = [originCol, originRow]
    this.texSize = [Math.max(1e-6, sizeCols), Math.max(1e-6, sizeRows)]
  }

  syncTextureForView(view) {
    if (!this.sourceRgba || this.nRows < 1 || this.nCols < 1) return
    if (this.fullTextureFits && this.texture) return

    const colStart = Number(view?.colStart) || 0
    const colEnd = Number(view?.colEnd) || this.nCols
    const rowStart = Number(view?.rowStart) || 0
    const rowEnd = Number(view?.rowEnd) || this.nRows
    const c0 = Math.max(0, Math.min(this.nCols, Math.min(colStart, colEnd)))
    const c1 = Math.max(0, Math.min(this.nCols, Math.max(colStart, colEnd)))
    const r0 = Math.max(0, Math.min(this.nRows, Math.min(rowStart, rowEnd)))
    const r1 = Math.max(0, Math.min(this.nRows, Math.max(rowStart, rowEnd)))
    const visCols = Math.max(1e-6, c1 - c0)
    const visRows = Math.max(1e-6, r1 - r0)

    const texW = Math.max(1, Math.min(this.maxTextureSize, Math.max(1, Math.ceil(visCols))))
    const texH = Math.max(1, Math.min(this.maxTextureSize, Math.max(1, Math.ceil(visRows))))
    const key = `${c0.toFixed(3)}:${c1.toFixed(3)}:${r0.toFixed(3)}:${r1.toFixed(3)}:${texW}x${texH}`
    if (this.texture && this.textureViewKey === key) return

    const rgba = new Uint8Array(texW * texH * 4)
    for (let y = 0; y < texH; y++) {
      const srcRow = Math.min(this.nRows - 1, Math.max(0, Math.floor(r0 + ((y + 0.5) / texH) * visRows)))
      for (let x = 0; x < texW; x++) {
        const srcCol = Math.min(this.nCols - 1, Math.max(0, Math.floor(c0 + ((x + 0.5) / texW) * visCols)))
        const src = (srcRow * this.nCols + srcCol) * 4
        const dst = (y * texW + x) * 4
        rgba[dst] = this.sourceRgba[src]
        rgba[dst + 1] = this.sourceRgba[src + 1]
        rgba[dst + 2] = this.sourceRgba[src + 2]
        rgba[dst + 3] = this.sourceRgba[src + 3]
      }
    }

    this.uploadTextureRegion(rgba, texW, texH, c0, r0, visCols, visRows)
    this.textureViewKey = key
  }

  render(view) {
    if (!this.sourceRgba || !this.colormapTexture) return
    this.syncTextureForView(view)
    if (!this.texture) return
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
    this.sourceRgba = null
    if (this.regl) {
      this.regl.destroy()
      this.regl = null
    }
  }
}
