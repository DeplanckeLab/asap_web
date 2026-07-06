/**
 * ReGL-based WebGL heatmap renderer.
 *
 * Renders a genes x columns matrix as a single textured quad. The matrix is
 * uploaded once as an RGBA data texture (R = normalized value, G = validity
 * mask); the fragment shader maps the normalized value through a colormap.
 * Zoom/pan are expressed as a visible [colStart,colEnd] x [rowStart,rowEnd]
 * range so the 2D overlay (dendrograms/tracks/labels) can stay aligned.
 */

import createREGL from 'regl'

export class ReglHeatmap {
  constructor(canvas) {
    this.canvas = canvas
    this.regl = null
    this.draw = null
    this.texture = null
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
      attributes: { antialias: false, alpha: false, preserveDrawingBuffer: false }
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
        uniform vec2 uColRange;
        uniform vec2 uRowRange;
        uniform vec2 uDims;
        uniform float uDiverging;

        vec3 divergingColor(float t) {
          // blue - white - red
          vec3 low = vec3(0.23, 0.30, 0.75);
          vec3 mid = vec3(0.97, 0.97, 0.97);
          vec3 high = vec3(0.71, 0.09, 0.16);
          if (t < 0.5) return mix(low, mid, t * 2.0);
          return mix(mid, high, (t - 0.5) * 2.0);
        }

        vec3 sequentialColor(float t) {
          // dark blue -> teal -> yellow (viridis-like 3-stop)
          vec3 c0 = vec3(0.27, 0.00, 0.33);
          vec3 c1 = vec3(0.13, 0.57, 0.55);
          vec3 c2 = vec3(0.99, 0.91, 0.14);
          if (t < 0.5) return mix(c0, c1, t * 2.0);
          return mix(c1, c2, (t - 0.5) * 2.0);
        }

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
          vec3 c = uDiverging > 0.5 ? divergingColor(t) : sequentialColor(t);
          gl_FragColor = vec4(c, 1.0);
        }
      `,
      attributes: {
        position: [[-1, -1], [1, -1], [-1, 1], [-1, 1], [1, -1], [1, 1]]
      },
      uniforms: {
        uMatrix: () => this.texture,
        uColRange: this.regl.prop('colRange'),
        uRowRange: this.regl.prop('rowRange'),
        uDims: () => [this.nCols, this.nRows],
        uDiverging: () => (this.diverging ? 1.0 : 0.0)
      },
      count: 6
    })
  }

  setColormap(diverging) {
    this.diverging = !!diverging
  }

  /**
   * Upload a matrix. values is a Float32Array of length nRows*nCols (row-major).
   * NaN entries render as a grey "missing" cell.
   */
  setMatrix(values, nRows, nCols, vmin, vmax) {
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
        let norm = (v - vmin) / span
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
    if (this.regl) {
      this.regl.destroy()
      this.regl = null
    }
  }
}
