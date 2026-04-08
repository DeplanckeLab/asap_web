/**
 * Category box plots (gene expression by discrete metadata) using regl WebGL.
 * Replaces legacy Plotly box traces for the visualization gene panel.
 */

import createREGL from 'regl'

function quantileSorted (sorted, p) {
  if (!sorted.length) return NaN
  const idx = (sorted.length - 1) * p
  const lo = Math.floor(idx)
  const hi = Math.ceil(idx)
  if (lo === hi) return sorted[lo]
  const t = idx - lo
  return sorted[lo] * (1 - t) + sorted[hi] * t
}

export function computeBoxStats (values) {
  const v = values.filter(x => Number.isFinite(x)).slice().sort((a, b) => a - b)
  if (v.length === 0) return null
  const q1 = quantileSorted(v, 0.25)
  const median = quantileSorted(v, 0.5)
  const q3 = quantileSorted(v, 0.75)
  const iqr = q3 - q1
  const lowFence = q1 - 1.5 * iqr
  const highFence = q3 + 1.5 * iqr
  const lowWhisker = v.find(x => x >= lowFence) ?? v[0]
  const highWhisker = [...v].reverse().find(x => x <= highFence) ?? v[v.length - 1]
  const mean = v.reduce((a, b) => a + b, 0) / v.length
  return { lowWhisker, q1, median, q3, highWhisker, mean, n: v.length }
}

function hslToRgb (h, s, l) {
  const hh = ((h % 360) + 360) % 360 / 60
  const c = (1 - Math.abs(2 * l - 1)) * s
  const x = c * (1 - Math.abs((hh % 2) - 1))
  const m = l - c / 2
  let rp = 0; let gp = 0; let bp = 0
  if (hh < 1) { rp = c; gp = x } else if (hh < 2) { rp = x; gp = c } else if (hh < 3) { gp = c; bp = x } else if (hh < 4) { gp = x; bp = c } else if (hh < 5) { rp = x; bp = c } else { rp = c; bp = x }
  return [rp + m, gp + m, bp + m]
}

function clipX (px, w) {
  return (px / w) * 2 - 1
}

function clipY (py, h) {
  return 1 - (py / h) * 2
}

function destroyReglIfAny (canvas) {
  const prev = canvas.__geneBoxplotRegl
  if (prev && typeof prev.destroy === 'function') {
    try { prev.destroy() } catch (_) { /* ignore */ }
  }
  canvas.__geneBoxplotRegl = null
}

/**
 * @param {HTMLCanvasElement} webglCanvas
 * @param {HTMLCanvasElement|null} labelCanvas optional 2D overlay for axes and category labels
 * @param {Array<{ name: string, values: number[] }>} groups ordered left-to-right
 * @param {object} opts
 * @param {string} [opts.yAxisLabel]
 */
export function renderGeneCategoryBoxplot (webglCanvas, labelCanvas, groups, opts = {}) {
  if (!webglCanvas) return

  const dpr = window.devicePixelRatio || 1
  const cssW = webglCanvas.clientWidth || 300
  const cssH = webglCanvas.clientHeight || 200
  const w = Math.max(2, Math.floor(cssW * dpr))
  const h = Math.max(2, Math.floor(cssH * dpr))
  webglCanvas.width = w
  webglCanvas.height = h
  if (labelCanvas) {
    labelCanvas.width = w
    labelCanvas.height = h
  }

  destroyReglIfAny(webglCanvas)

  if (!groups || groups.length === 0) {
    const ctx2d = labelCanvas && labelCanvas.getContext('2d')
    if (ctx2d) {
      ctx2d.setTransform(1, 0, 0, 1, 0, 0)
      ctx2d.clearRect(0, 0, w, h)
    }
    return
  }

  const padL = Math.floor(48 * dpr)
  const padR = Math.floor(12 * dpr)
  const padT = Math.floor(16 * dpr)
  const padB = Math.floor(56 * dpr)
  const innerW = Math.max(1, w - padL - padR)
  const innerH = Math.max(1, h - padT - padB)

  const statsList = groups.map(g => computeBoxStats(g.values)).filter(Boolean)
  if (statsList.length === 0) {
    const ctx2d = labelCanvas && labelCanvas.getContext('2d')
    if (ctx2d) {
      ctx2d.setTransform(1, 0, 0, 1, 0, 0)
      ctx2d.clearRect(0, 0, w, h)
      ctx2d.fillStyle = '#6b7280'
      ctx2d.font = `${12 * dpr}px sans-serif`
      ctx2d.fillText('No numeric expression in visible cells', padL, padT + 20 * dpr)
    }
    return
  }

  let yMin = Infinity
  let yMax = -Infinity
  statsList.forEach(s => {
    yMin = Math.min(yMin, s.lowWhisker)
    yMax = Math.max(yMax, s.highWhisker)
  })
  if (!Number.isFinite(yMin) || !Number.isFinite(yMax)) return
  if (yMin === yMax) {
    yMin -= 1
    yMax += 1
  }
  const yPad = (yMax - yMin) * 0.08
  yMin -= yPad
  yMax += yPad

  const yToPx = y => padT + innerH * (1 - (y - yMin) / (yMax - yMin))
  const n = groups.length
  const slotW = innerW / n

  const triPositions = []
  const triColors = []
  const linePositions = []
  const meanLinePositions = []
  const capHalf = Math.max(2 * dpr, slotW * 0.12)
  const nCat = groups.length

  groups.forEach((grp, i) => {
    const s = computeBoxStats(grp.values)
    if (!s) return
    const cx = padL + (i + 0.5) * slotW
    const bw = Math.min(slotW * 0.45, 28 * dpr)
    const x0 = cx - bw / 2
    const x1 = cx + bw / 2
    const yL = yToPx(s.lowWhisker)
    const yQ1 = yToPx(s.q1)
    const yMed = yToPx(s.median)
    const yQ3 = yToPx(s.q3)
    const yH = yToPx(s.highWhisker)
    const [r, gc, b] = hslToRgb((i * 360) / Math.max(nCat, 1), 0.52, 0.5)

    const pushTri = (xa, ya, xb, yb, xc, yc) => {
      triPositions.push(clipX(xa, w), clipY(ya, h), clipX(xb, w), clipY(yb, h), clipX(xc, w), clipY(yc, h))
      for (let k = 0; k < 3; k++) triColors.push(r, gc, b, 0.88)
    }

    pushTri(x0, yQ3, x1, yQ3, x0, yQ1)
    pushTri(x1, yQ3, x1, yQ1, x0, yQ1)

    const line = (arr, xA, yA, xB, yB) => {
      arr.push(clipX(xA, w), clipY(yA, h), clipX(xB, w), clipY(yB, h))
    }

    line(linePositions, cx, yL, cx, yQ1)
    line(linePositions, cx, yQ3, cx, yH)
    line(linePositions, cx - capHalf, yL, cx + capHalf, yL)
    line(linePositions, cx - capHalf, yH, cx + capHalf, yH)
    line(linePositions, x0, yMed, x1, yMed)

    const yMeanPx = yToPx(s.mean)
    const mw = bw * 0.35
    line(meanLinePositions, cx - mw, yMeanPx, cx + mw, yMeanPx)
  })

  const regl = createREGL({
    canvas: webglCanvas,
    attributes: { antialias: true, alpha: false, preserveDrawingBuffer: false }
  })
  webglCanvas.__geneBoxplotRegl = regl

  const triBuf = triPositions.length ? regl.buffer(new Float32Array(triPositions)) : null
  const triColBuf = triColors.length ? regl.buffer(new Float32Array(triColors)) : null
  const lineBuf = linePositions.length ? regl.buffer(new Float32Array(linePositions)) : null
  const meanBuf = meanLinePositions.length ? regl.buffer(new Float32Array(meanLinePositions)) : null

  const drawTris = triBuf && triPositions.length
    ? regl({
        vert: `
          precision highp float;
          attribute vec2 position;
          attribute vec4 color;
          varying vec4 vColor;
          void main() {
            vColor = color;
            gl_Position = vec4(position, 0.0, 1.0);
          }
        `,
        frag: `
          precision highp float;
          varying vec4 vColor;
          void main() {
            gl_FragColor = vColor;
          }
        `,
        attributes: { position: triBuf, color: triColBuf },
        count: triPositions.length / 2,
        primitive: 'triangles',
        depth: { enable: false }
      })
    : null

  const drawLines = lineBuf && linePositions.length
    ? regl({
        vert: `
          precision highp float;
          attribute vec2 position;
          void main() {
            gl_Position = vec4(position, 0.0, 1.0);
          }
        `,
        frag: `
          precision highp float;
          void main() {
            gl_FragColor = vec4(0.22, 0.22, 0.24, 1.0);
          }
        `,
        attributes: { position: lineBuf },
        count: linePositions.length / 2,
        primitive: 'lines',
        lineWidth: 1,
        depth: { enable: false }
      })
    : null

  const drawMeanLines = meanBuf && meanLinePositions.length
    ? regl({
        vert: `
          precision highp float;
          attribute vec2 position;
          void main() {
            gl_Position = vec4(position, 0.0, 1.0);
          }
        `,
        frag: `
          precision highp float;
          void main() {
            gl_FragColor = vec4(0.93, 0.58, 0.06, 1.0);
          }
        `,
        attributes: { position: meanBuf },
        count: meanLinePositions.length / 2,
        primitive: 'lines',
        lineWidth: 1,
        depth: { enable: false }
      })
    : null

  regl.clear({ color: [1, 1, 1, 1] })
  if (drawTris) drawTris()
  if (drawLines) drawLines()
  if (drawMeanLines) drawMeanLines()

  if (triBuf) triBuf.destroy()
  if (triColBuf) triColBuf.destroy()
  if (lineBuf) lineBuf.destroy()
  if (meanBuf) meanBuf.destroy()

  if (labelCanvas) {
    const ctx = labelCanvas.getContext('2d')
    if (ctx) {
      ctx.setTransform(1, 0, 0, 1, 0, 0)
      ctx.clearRect(0, 0, w, h)
      ctx.fillStyle = '#374151'
      ctx.font = `${11 * dpr}px sans-serif`
      ctx.textAlign = 'right'
      ctx.textBaseline = 'middle'
      const ticks = 5
      for (let t = 0; t <= ticks; t++) {
        const frac = t / ticks
        const val = yMin + (yMax - yMin) * (1 - frac)
        const py = padT + innerH * frac
        ctx.fillText(val.toExponential(2), padL - 6 * dpr, py)
        ctx.strokeStyle = '#f3f4f6'
        ctx.lineWidth = 1 * dpr
        ctx.beginPath()
        ctx.moveTo(padL, py)
        ctx.lineTo(padL + innerW, py)
        ctx.stroke()
      }
      ctx.textAlign = 'center'
      ctx.textBaseline = 'top'
      ctx.fillStyle = '#4b5563'
      groups.forEach((g, i) => {
        const cx = padL + (i + 0.5) * slotW
        let name = String(g.name ?? i)
        if (name.length > 14) name = name.slice(0, 12) + '…'
        ctx.save()
        ctx.translate(cx, h - padB + 4 * dpr)
        ctx.rotate(-Math.PI / 5)
        ctx.fillText(name, 0, 0)
        ctx.restore()
      })
      const yLabel = opts.yAxisLabel || 'Expression'
      ctx.save()
      ctx.translate(12 * dpr, padT + innerH / 2)
      ctx.rotate(-Math.PI / 2)
      ctx.textAlign = 'center'
      ctx.font = `${10 * dpr}px sans-serif`
      ctx.fillStyle = '#6b7280'
      ctx.fillText(yLabel, 0, 0)
      ctx.restore()
    }
  }

}
