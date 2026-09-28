/**
 * Category box plots (gene expression by discrete metadata) using Canvas 2D.
 *
 * Previously used one regl/WebGL context per gene card and left those contexts
 * alive after draw. Coloring by metadata refreshes every gene boxplot, which
 * quickly exceeded the browser WebGL context limit and lost the main scatter
 * plot context (cells became invisible). Boxplots do not need WebGL.
 */

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

function hslToRgb255 (h, s, l) {
  const hh = ((h % 360) + 360) % 360 / 60
  const c = (1 - Math.abs(2 * l - 1)) * s
  const x = c * (1 - Math.abs((hh % 2) - 1))
  const m = l - c / 2
  let rp = 0; let gp = 0; let bp = 0
  if (hh < 1) { rp = c; gp = x } else if (hh < 2) { rp = x; gp = c } else if (hh < 3) { gp = c; bp = x } else if (hh < 4) { gp = x; bp = c } else if (hh < 5) { rp = x; bp = c } else { rp = c; bp = x }
  return [
    Math.round((rp + m) * 255),
    Math.round((gp + m) * 255),
    Math.round((bp + m) * 255)
  ]
}

/** Release any leftover regl context from older builds (canvas stays WebGL-typed). */
function destroyLegacyReglIfAny (canvas) {
  if (!canvas) return
  const prev = canvas.__geneBoxplotRegl
  if (prev && typeof prev.destroy === 'function') {
    try { prev.destroy() } catch (_) { /* ignore */ }
  }
  canvas.__geneBoxplotRegl = null
}

/**
 * Prefer a 2D context on `preferred`. If that canvas was previously bound to
 * WebGL, replace it in the DOM so 2D works again.
 */
function acquire2dContext (preferred, fallback) {
  const tryCanvas = (canvas) => {
    if (!canvas) return null
    destroyLegacyReglIfAny(canvas)
    let ctx = null
    try {
      ctx = canvas.getContext('2d')
    } catch (_) {
      ctx = null
    }
    if (ctx) return { canvas, ctx }

    const parent = canvas.parentNode
    if (!parent) return null
    const replacement = document.createElement('canvas')
    replacement.className = canvas.className
    const style = canvas.getAttribute('style')
    if (style) replacement.setAttribute('style', style)
    parent.replaceChild(replacement, canvas)
    destroyLegacyReglIfAny(replacement)
    try {
      ctx = replacement.getContext('2d')
    } catch (_) {
      ctx = null
    }
    return ctx ? { canvas: replacement, ctx } : null
  }

  return tryCanvas(preferred) || tryCanvas(fallback)
}

function clearCanvas (entry, w, h) {
  if (!entry) return
  entry.canvas.width = w
  entry.canvas.height = h
  entry.ctx.setTransform(1, 0, 0, 1, 0, 0)
  entry.ctx.clearRect(0, 0, w, h)
}

/**
 * @param {HTMLCanvasElement} plotCanvas former WebGL canvas (now unused for GL)
 * @param {HTMLCanvasElement|null} labelCanvas 2D overlay; plot is drawn here
 * @param {Array<{ name: string, values: number[] }>} groups ordered left-to-right
 * @param {object} opts
 * @param {string} [opts.yAxisLabel]
 */
export function renderGeneCategoryBoxplot (plotCanvas, labelCanvas, groups, opts = {}) {
  if (!plotCanvas && !labelCanvas) return

  destroyLegacyReglIfAny(plotCanvas)

  const sizeSource = plotCanvas || labelCanvas
  const dpr = window.devicePixelRatio || 1
  const cssW = sizeSource.clientWidth || 300
  const cssH = sizeSource.clientHeight || 200
  const w = Math.max(2, Math.floor(cssW * dpr))
  const h = Math.max(2, Math.floor(cssH * dpr))

  // Draw the full plot on the label (top) canvas so we never open a WebGL context.
  // Keep the underlying plot canvas blank after releasing any legacy regl handle.
  const drawTarget = acquire2dContext(labelCanvas, plotCanvas)
  if (!drawTarget) return

  if (plotCanvas && plotCanvas !== drawTarget.canvas) {
    destroyLegacyReglIfAny(plotCanvas)
    // Blank the unused underlay when it still accepts 2D (never had WebGL).
    try {
      const under = plotCanvas.getContext('2d')
      if (under) {
        plotCanvas.width = w
        plotCanvas.height = h
        under.setTransform(1, 0, 0, 1, 0, 0)
        under.clearRect(0, 0, w, h)
      }
    } catch (_) { /* canvas may still be WebGL-typed; ignore */ }
  }

  clearCanvas(drawTarget, w, h)
  const ctx = drawTarget.ctx

  if (!groups || groups.length === 0) {
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
    ctx.fillStyle = '#6b7280'
    ctx.font = `${12 * dpr}px sans-serif`
    ctx.textAlign = 'left'
    ctx.textBaseline = 'alphabetic'
    ctx.fillText('No numeric expression in visible cells', padL, padT + 20 * dpr)
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
  const capHalf = Math.max(2 * dpr, slotW * 0.12)
  const nCat = groups.length
  const lineW = Math.max(1, dpr)

  // White plot background (matches previous regl clear)
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, w, h)

  // Soft horizontal grid + y tick labels
  ctx.font = `${11 * dpr}px sans-serif`
  ctx.textAlign = 'right'
  ctx.textBaseline = 'middle'
  const ticks = 5
  for (let t = 0; t <= ticks; t++) {
    const frac = t / ticks
    const val = yMin + (yMax - yMin) * (1 - frac)
    const py = padT + innerH * frac
    ctx.fillStyle = '#374151'
    ctx.fillText(val.toExponential(2), padL - 6 * dpr, py)
    ctx.strokeStyle = '#f3f4f6'
    ctx.lineWidth = lineW
    ctx.beginPath()
    ctx.moveTo(padL, py)
    ctx.lineTo(padL + innerW, py)
    ctx.stroke()
  }

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
    const [r, g, b] = hslToRgb255((i * 360) / Math.max(nCat, 1), 0.52, 0.5)

    // IQR box
    ctx.fillStyle = `rgba(${r},${g},${b},0.88)`
    ctx.fillRect(x0, Math.min(yQ3, yQ1), x1 - x0, Math.abs(yQ1 - yQ3))

    // Whiskers, caps, median
    ctx.strokeStyle = 'rgb(56,56,61)'
    ctx.lineWidth = lineW
    ctx.beginPath()
    ctx.moveTo(cx, yL)
    ctx.lineTo(cx, yQ1)
    ctx.moveTo(cx, yQ3)
    ctx.lineTo(cx, yH)
    ctx.moveTo(cx - capHalf, yL)
    ctx.lineTo(cx + capHalf, yL)
    ctx.moveTo(cx - capHalf, yH)
    ctx.lineTo(cx + capHalf, yH)
    ctx.moveTo(x0, yMed)
    ctx.lineTo(x1, yMed)
    ctx.stroke()

    // Mean marker
    const yMeanPx = yToPx(s.mean)
    const mw = bw * 0.35
    ctx.strokeStyle = 'rgb(237,148,15)'
    ctx.beginPath()
    ctx.moveTo(cx - mw, yMeanPx)
    ctx.lineTo(cx + mw, yMeanPx)
    ctx.stroke()
  })

  // Category labels
  ctx.textAlign = 'center'
  ctx.textBaseline = 'top'
  ctx.fillStyle = '#4b5563'
  ctx.font = `${11 * dpr}px sans-serif`
  groups.forEach((g, i) => {
    const cx = padL + (i + 0.5) * slotW
    let name = String(g.name ?? i)
    if (name.length > 14) name = name.slice(0, 12) + '\u2026'
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
  ctx.textBaseline = 'middle'
  ctx.font = `${10 * dpr}px sans-serif`
  ctx.fillStyle = '#6b7280'
  ctx.fillText(yLabel, 0, 0)
  ctx.restore()
}
