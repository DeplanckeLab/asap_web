/**
 * Split violin plot: two mirrored halves sharing a vertical axis
 * (category cells vs rest of dataset), same y scale (expression).
 */

const DEFAULT_LEFT_FILL = 'rgba(22, 163, 74, 0.42)'
const DEFAULT_LEFT_STROKE = '#15803d'

function parseHexColorRgb (hex) {
  if (hex == null || typeof hex !== 'string') return null
  const s = hex.trim()
  let m = /^#([0-9a-fA-F]{6})$/.exec(s)
  if (m) {
    const n = parseInt(m[1], 16)
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 }
  }
  m = /^#([0-9a-fA-F]{3})$/.exec(s)
  if (m) {
    const x = m[1]
    return {
      r: parseInt(x[0] + x[0], 16),
      g: parseInt(x[1] + x[1], 16),
      b: parseInt(x[2] + x[2], 16)
    }
  }
  return null
}

function leftViolinColorsFromCategoryHex (hex) {
  const rgb = parseHexColorRgb(hex)
  if (!rgb) return { fill: DEFAULT_LEFT_FILL, stroke: DEFAULT_LEFT_STROKE }
  const { r, g, b } = rgb
  const fill = `rgba(${r},${g},${b},0.42)`
  const stroke = `rgb(${Math.max(0, Math.min(255, Math.round(r * 0.72)))},${Math.max(0, Math.min(255, Math.round(g * 0.72)))},${Math.max(0, Math.min(255, Math.round(b * 0.72)))})`
  return { fill, stroke }
}

function drawAnnotSplitViolinLegend (ctx, {
  padL,
  innerW,
  legY,
  leftLabel,
  rightLabel,
  fillLeft,
  strokeLeft,
  fillRight,
  strokeRight,
  trunc
}) {
  const sw = 7
  const gap = 5
  const leftTxt = trunc(leftLabel, 16) + ' (left)'
  const rightTxt = trunc(rightLabel, 14) + ' (right)'
  const sepStr = ' | '
  ctx.font = '9px sans-serif'
  ctx.textBaseline = 'middle'
  ctx.textAlign = 'left'
  const mLeft = ctx.measureText(leftTxt).width
  const mSep = ctx.measureText(sepStr).width
  const mRight = ctx.measureText(rightTxt).width
  const totalW = sw + gap + mLeft + mSep + sw + gap + mRight
  const midX = padL + innerW / 2
  const yy = legY + 5
  let x = midX - totalW / 2
  ctx.fillStyle = fillLeft
  ctx.fillRect(x, yy - sw / 2, sw, sw)
  ctx.strokeStyle = strokeLeft
  ctx.lineWidth = 1
  ctx.strokeRect(x, yy - sw / 2, sw, sw)
  x += sw + gap
  ctx.fillStyle = '#6b7280'
  ctx.fillText(leftTxt, x, yy)
  x += mLeft
  ctx.fillText(sepStr, x, yy)
  x += mSep
  ctx.fillStyle = fillRight
  ctx.fillRect(x, yy - sw / 2, sw, sw)
  ctx.strokeStyle = strokeRight
  ctx.strokeRect(x, yy - sw / 2, sw, sw)
  x += sw + gap
  ctx.fillStyle = '#6b7280'
  ctx.fillText(rightTxt, x, yy)
}

function finiteNumbers (arr) {
  if (!arr || !arr.length) return []
  const out = []
  for (let i = 0; i < arr.length; i++) {
    const n = Number(arr[i])
    if (Number.isFinite(n)) out.push(n)
  }
  return out
}

/** Minimum CSS width per gene column in combined multi-gene violins (horizontal scroll if wider than container). */
export const ANNOT_COMBINED_VIOLIN_MIN_COL_PX = 120

// Sort key from category-side expression only; empty sorts last when ordering descending.
export function categoryCellSortValue (leftValues, sortBy) {
  const v = finiteNumbers(leftValues)
  if (v.length === 0) return Number.NEGATIVE_INFINITY
  const mode = sortBy === 'mean' || sortBy === 'max' ? sortBy : 'median'
  if (mode === 'max') {
    let m = v[0]
    for (let i = 1; i < v.length; i++) {
      if (v[i] > m) m = v[i]
    }
    return m
  }
  if (mode === 'mean') {
    let s = 0
    for (let i = 0; i < v.length; i++) s += v[i]
    return s / v.length
  }
  const sorted = v.slice().sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

function sampleStdDev (values) {
  const n = values.length
  if (n < 2) return 0
  let mean = 0
  for (let i = 0; i < n; i++) mean += values[i]
  mean /= n
  let s = 0
  for (let i = 0; i < n; i++) {
    const d = values[i] - mean
    s += d * d
  }
  return Math.sqrt(s / (n - 1))
}

function computeViolinValueStats (arr) {
  const v = finiteNumbers(arr)
  if (v.length === 0) return null
  let minV = v[0]
  let maxV = v[0]
  let sum = 0
  for (let i = 0; i < v.length; i++) {
    minV = Math.min(minV, v[i])
    maxV = Math.max(maxV, v[i])
    sum += v[i]
  }
  const mean = sum / v.length
  const sorted = v.slice().sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  const median = sorted.length % 2 === 1
    ? sorted[mid]
    : (sorted[mid - 1] + sorted[mid]) / 2
  const stdDev = sampleStdDev(v)
  return { n: v.length, min: minV, max: maxV, mean, median, stdDev }
}

function formatViolinStatNumber (x) {
  if (!Number.isFinite(x)) return '—'
  if (x === 0) return '0'
  const ax = Math.abs(x)
  if (ax >= 1e4 || (ax < 1e-3 && ax > 0)) return x.toExponential(4)
  const s = x.toFixed(4)
  return s.replace(/\.?0+$/, '')
}

let annotViolinTooltipEl = null

function getAnnotViolinTooltipEl () {
  if (!annotViolinTooltipEl && typeof document !== 'undefined') {
    annotViolinTooltipEl = document.createElement('div')
    annotViolinTooltipEl.setAttribute('id', 'annot-split-violin-tooltip')
    annotViolinTooltipEl.style.cssText =
      'position:fixed;z-index:10060;pointer-events:none;display:none;' +
      'background:#1f2937;color:#f9fafb;padding:8px 10px;border-radius:6px;' +
      'font-size:11px;line-height:1.45;max-width:300px;box-shadow:0 4px 14px rgba(0,0,0,0.2);'
    document.body.appendChild(annotViolinTooltipEl)
  }
  return annotViolinTooltipEl
}

function hideAnnotViolinTooltip () {
  const el = annotViolinTooltipEl || (typeof document !== 'undefined' ? document.getElementById('annot-split-violin-tooltip') : null)
  if (el) el.style.display = 'none'
}

function clearAnnotViolinCanvasHandlers (canvas) {
  if (!canvas) return
  canvas.onmousemove = null
  canvas.onmouseleave = null
  delete canvas._annotViolinHitTest
}

function escapeViolinTooltipText (s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function formatViolinTooltipHtml (title, stats) {
  const t = escapeViolinTooltipText(title)
  if (!stats || stats.n === 0) {
    return '<div style="font-weight:600;margin-bottom:4px">' + t + '</div>' +
      '<div>No numeric values</div>'
  }
  const rows = [
    'n: ' + stats.n,
    'min: ' + formatViolinStatNumber(stats.min),
    'max: ' + formatViolinStatNumber(stats.max),
    'mean: ' + formatViolinStatNumber(stats.mean),
    'median: ' + formatViolinStatNumber(stats.median),
    'std dev: ' + formatViolinStatNumber(stats.stdDev)
  ]
  let html = '<div style="font-weight:600;margin-bottom:6px">' + t + '</div>'
  for (let i = 0; i < rows.length; i++) {
    html += '<div>' + escapeViolinTooltipText(rows[i]) + '</div>'
  }
  return html
}

function positionAnnotViolinTooltip (el, clientX, clientY) {
  const pad = 12
  const margin = 8
  el.style.display = 'block'
  const w = el.offsetWidth
  const h = el.offsetHeight
  let x = clientX + pad
  let y = clientY + pad
  if (typeof window !== 'undefined') {
    if (x + w + margin > window.innerWidth) x = clientX - w - pad
    if (y + h + margin > window.innerHeight) y = clientY - h - pad
    x = Math.max(margin, Math.min(x, window.innerWidth - w - margin))
    y = Math.max(margin, Math.min(y, window.innerHeight - h - margin))
  }
  el.style.left = x + 'px'
  el.style.top = y + 'px'
}

function buildHalfViolinPath (cx, gridY, yToPx, maxHalfW, maxD, dSide, side) {
  const p = new Path2D()
  p.moveTo(cx, yToPx(gridY[0]))
  if (side === 'left') {
    for (let i = 0; i < gridY.length; i++) {
      const w = maxHalfW * (dSide[i] / maxD)
      p.lineTo(cx - w, yToPx(gridY[i]))
    }
    for (let i = gridY.length - 1; i >= 0; i--) {
      p.lineTo(cx, yToPx(gridY[i]))
    }
  } else {
    for (let i = 0; i < gridY.length; i++) {
      const w = maxHalfW * (dSide[i] / maxD)
      p.lineTo(cx + w, yToPx(gridY[i]))
    }
    for (let i = gridY.length - 1; i >= 0; i--) {
      p.lineTo(cx, yToPx(gridY[i]))
    }
  }
  p.closePath()
  return p
}

function annotViolinCanvasCssPoint (canvas, clientX, clientY) {
  const rect = canvas.getBoundingClientRect()
  const cw = canvas.clientWidth || rect.width || 1
  const ch = canvas.clientHeight || rect.height || 1
  const sx = cw / (rect.width || 1)
  const sy = ch / (rect.height || 1)
  return {
    mx: (clientX - rect.left) * sx,
    my: (clientY - rect.top) * sy
  }
}

function bindAnnotViolinTooltip (canvas, ctx, dpr, hitState) {
  if (typeof document === 'undefined') return
  canvas._annotViolinHitTest = hitState
  canvas.onmousemove = function (e) {
    const h = canvas._annotViolinHitTest
    const tip = getAnnotViolinTooltipEl()
    if (!h || !tip || !ctx) {
      hideAnnotViolinTooltip()
      return
    }
    const { mx, my } = annotViolinCanvasCssPoint(canvas, e.clientX, e.clientY)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    let title = ''
    let stats = null
    let matched = false
    if (h.mode === 'single') {
      const inPlot = mx >= h.plotPadL && mx <= h.plotPadL + h.plotInnerW &&
        my >= h.plotPadT && my <= h.plotPadT + h.plotInnerH
      if (h.pathLeft && ctx.isPointInPath(h.pathLeft, mx, my)) {
        title = h.leftTitle
        stats = h.statsL
        matched = true
      } else if (h.pathRight && ctx.isPointInPath(h.pathRight, mx, my)) {
        title = h.rightTitle
        stats = h.statsR
        matched = true
      } else if (inPlot) {
        if (mx < h.cx) {
          title = h.leftTitle
          stats = h.statsL
        } else {
          title = h.rightTitle
          stats = h.statsR
        }
        matched = true
      }
    } else if (h.mode === 'multi' && h.columns) {
      for (let j = 0; j < h.columns.length; j++) {
        const col = h.columns[j]
        if (mx < col.colLeft || mx >= col.colLeft + col.colW) continue
        const inBand = my >= h.padT && my <= h.padT + h.innerH
        if (col.pathLeft && ctx.isPointInPath(col.pathLeft, mx, my)) {
          title = col.leftTitle
          stats = col.statsL
          matched = true
          break
        }
        if (col.pathRight && ctx.isPointInPath(col.pathRight, mx, my)) {
          title = col.rightTitle
          stats = col.statsR
          matched = true
          break
        }
        if (inBand) {
          if (mx < col.cx) {
            title = col.leftTitle
            stats = col.statsL
          } else {
            title = col.rightTitle
            stats = col.statsR
          }
          matched = true
          break
        }
      }
    }
    if (!matched) {
      hideAnnotViolinTooltip()
      return
    }
    tip.innerHTML = formatViolinTooltipHtml(title, stats)
    positionAnnotViolinTooltip(tip, e.clientX, e.clientY)
  }
  canvas.onmouseleave = function () {
    hideAnnotViolinTooltip()
  }
}

function kdeAtGrid (values, gridY, bandwidth) {
  const n = values.length
  if (!n) return gridY.map(() => 0)
  const h = bandwidth != null && bandwidth > 0
    ? bandwidth
    : Math.max(1e-9, 1.06 * sampleStdDev(values) * Math.pow(n, -0.2))
  const inv = 1 / (h * Math.sqrt(2 * Math.PI))
  const out = new Array(gridY.length)
  for (let gi = 0; gi < gridY.length; gi++) {
    const y = gridY[gi]
    let sum = 0
    for (let i = 0; i < n; i++) {
      const t = (y - values[i]) / h
      sum += Math.exp(-0.5 * t * t) * inv
    }
    out[gi] = sum / n
  }
  return out
}

/**
 * @param {HTMLCanvasElement} canvas
 * @param {number[]} leftValues expression in category
 * @param {number[]} rightValues expression in rest
 * @param {object} opts
 * @param {string} [opts.leftLabel]
 * @param {string} [opts.rightLabel]
 * @param {string} [opts.yLabel]
 * @param {string} [opts.categoryColor] hex (e.g. #1f77b4) for left half; default category green
 */
export function renderAnnotSplitViolinPlot (canvas, leftValues, rightValues, opts = {}) {
  if (!canvas) return

  const leftLabel = opts.leftLabel || 'Category'
  const rightLabel = opts.rightLabel || 'Rest'
  const yLabel = opts.yLabel || 'Expression'

  const L = finiteNumbers(leftValues)
  const R = finiteNumbers(rightValues)

  const dpr = window.devicePixelRatio || 1
  const cssW = canvas.clientWidth || 300
  const cssH = canvas.clientHeight || 200
  canvas.width = Math.max(2, Math.floor(cssW * dpr))
  canvas.height = Math.max(2, Math.floor(cssH * dpr))
  const ctx = canvas.getContext('2d')
  if (!ctx) return
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, canvas.width, canvas.height)
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

  if (L.length === 0 && R.length === 0) {
    clearAnnotViolinCanvasHandlers(canvas)
    hideAnnotViolinTooltip()
    ctx.fillStyle = '#6b7280'
    ctx.font = '12px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText('No numeric expression values', cssW / 2, cssH / 2)
    return
  }

  let yMin = Infinity
  let yMax = -Infinity
  for (let i = 0; i < L.length; i++) {
    yMin = Math.min(yMin, L[i])
    yMax = Math.max(yMax, L[i])
  }
  for (let i = 0; i < R.length; i++) {
    yMin = Math.min(yMin, R[i])
    yMax = Math.max(yMax, R[i])
  }
  if (!Number.isFinite(yMin) || !Number.isFinite(yMax)) {
    clearAnnotViolinCanvasHandlers(canvas)
    hideAnnotViolinTooltip()
    return
  }
  if (yMin === yMax) {
    yMin -= 1
    yMax += 1
  }
  const yPad = (yMax - yMin) * 0.08
  yMin -= yPad
  yMax += yPad

  const padLYAxisTitle = 22
  const padLTickLabels = 54
  const padL = padLYAxisTitle + padLTickLabels
  const padR = 10
  const padT = 14
  const padB = 40
  const innerW = Math.max(1, cssW - padL - padR)
  const innerH = Math.max(1, cssH - padT - padB)
  const cx = padL + innerW / 2
  const tickLabelX = padL - 8

  const yToPx = y => padT + innerH * (1 - (y - yMin) / (yMax - yMin))

  const steps = 72
  const gridY = []
  for (let s = 0; s <= steps; s++) {
    gridY.push(yMin + (s / steps) * (yMax - yMin))
  }

  const dL = L.length ? kdeAtGrid(L, gridY) : gridY.map(() => 0)
  const dR = R.length ? kdeAtGrid(R, gridY) : gridY.map(() => 0)
  let maxD = 0
  for (let i = 0; i < dL.length; i++) maxD = Math.max(maxD, dL[i], dR[i])
  if (maxD <= 0) maxD = 1e-12
  const maxHalfW = innerW * 0.42

  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, cssW, cssH)

  ctx.strokeStyle = '#e5e7eb'
  ctx.lineWidth = 1
  const ticks = 5
  ctx.fillStyle = '#6b7280'
  ctx.font = '10px sans-serif'
  ctx.textAlign = 'right'
  ctx.textBaseline = 'middle'
  for (let t = 0; t <= ticks; t++) {
    const frac = t / ticks
    const val = yMin + (yMax - yMin) * (1 - frac)
    const py = padT + innerH * frac
    ctx.beginPath()
    ctx.moveTo(padL, py)
    ctx.lineTo(padL + innerW, py)
    ctx.stroke()
    ctx.fillText(val.toExponential(2), tickLabelX, py)
  }

  ctx.strokeStyle = '#94a3b8'
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.moveTo(cx, padT)
  ctx.lineTo(cx, padT + innerH)
  ctx.stroke()

  const { fill: fillLeft, stroke: strokeLeft } = leftViolinColorsFromCategoryHex(opts.categoryColor)
  const fillRight = 'rgba(100, 116, 139, 0.42)'
  const strokeRight = '#475569'

  const trunc = (s, n) => {
    const t = String(s || '')
    return t.length > n ? t.slice(0, n - 3) + '...' : t
  }

  const pathLeft = buildHalfViolinPath(cx, gridY, yToPx, maxHalfW, maxD, dL, 'left')
  const pathRight = buildHalfViolinPath(cx, gridY, yToPx, maxHalfW, maxD, dR, 'right')

  ctx.fillStyle = fillLeft
  ctx.fill(pathLeft)
  ctx.strokeStyle = strokeLeft
  ctx.lineWidth = 1
  ctx.stroke(pathLeft)

  ctx.fillStyle = fillRight
  ctx.fill(pathRight)
  ctx.strokeStyle = strokeRight
  ctx.stroke(pathRight)

  ctx.fillStyle = '#374151'
  ctx.font = '10px sans-serif'
  ctx.textAlign = 'center'
  ctx.textBaseline = 'top'
  const lx = cx - maxHalfW * 0.55
  const rx = cx + maxHalfW * 0.55
  ctx.fillText(trunc(leftLabel, 18), lx, padT + innerH + 6)
  ctx.fillText(trunc(rightLabel, 14), rx, padT + innerH + 6)

  ctx.save()
  ctx.translate(padLYAxisTitle / 2, padT + innerH / 2)
  ctx.rotate(-Math.PI / 2)
  ctx.textAlign = 'center'
  ctx.fillStyle = '#6b7280'
  ctx.fillText(yLabel, 0, 0)
  ctx.restore()

  bindAnnotViolinTooltip(canvas, ctx, dpr, {
    mode: 'single',
    pathLeft,
    pathRight,
    statsL: computeViolinValueStats(L),
    statsR: computeViolinValueStats(R),
    leftTitle: trunc(leftLabel, 28) + ' (left half)',
    rightTitle: trunc(rightLabel, 24) + ' (right half)',
    plotPadL: padL,
    plotPadT: padT,
    plotInnerW: innerW,
    plotInnerH: innerH,
    cx
  })
}

/**
 * Multiple genes on one canvas: shared y-axis; one split violin per column.
 * @param {HTMLCanvasElement} canvas
 * @param {Array<{ leftValues: number[], rightValues: number[], title?: string }>} panels
 * @param {object} opts
 */
export function renderAnnotSplitViolinPlotMulti (canvas, panels, opts = {}) {
  if (!canvas || !panels || panels.length === 0) {
    if (canvas) clearAnnotViolinCanvasHandlers(canvas)
    hideAnnotViolinTooltip()
    return
  }

  if (panels.length === 1) {
    const p = panels[0]
    renderAnnotSplitViolinPlot(canvas, p.leftValues, p.rightValues, {
      leftLabel: opts.leftLabel,
      rightLabel: opts.rightLabel,
      yLabel: opts.yLabel,
      categoryColor: opts.categoryColor
    })
    return
  }

  const leftLabel = opts.leftLabel || 'Category'
  const rightLabel = opts.rightLabel || 'Rest'
  const yLabel = opts.yLabel || 'Expression'

  let yMin = Infinity
  let yMax = -Infinity
  for (let pi = 0; pi < panels.length; pi++) {
    const L = finiteNumbers(panels[pi].leftValues)
    const R = finiteNumbers(panels[pi].rightValues)
    for (let i = 0; i < L.length; i++) {
      yMin = Math.min(yMin, L[i])
      yMax = Math.max(yMax, L[i])
    }
    for (let i = 0; i < R.length; i++) {
      yMin = Math.min(yMin, R[i])
      yMax = Math.max(yMax, R[i])
    }
  }

  const dpr = window.devicePixelRatio || 1
  const cssW = canvas.clientWidth || 300
  const cssH = canvas.clientHeight || 200
  canvas.width = Math.max(2, Math.floor(cssW * dpr))
  canvas.height = Math.max(2, Math.floor(cssH * dpr))
  const ctx = canvas.getContext('2d')
  if (!ctx) return
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, canvas.width, canvas.height)
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

  if (!Number.isFinite(yMin) || !Number.isFinite(yMax)) {
    clearAnnotViolinCanvasHandlers(canvas)
    hideAnnotViolinTooltip()
    ctx.fillStyle = '#6b7280'
    ctx.font = '12px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText('No numeric expression values', cssW / 2, cssH / 2)
    return
  }
  if (yMin === yMax) {
    yMin -= 1
    yMax += 1
  }
  const yPad = (yMax - yMin) * 0.08
  yMin -= yPad
  yMax += yPad

  const padLYAxisTitle = 22
  const padLTickLabels = 54
  const padL = padLYAxisTitle + padLTickLabels
  const padR = 10
  const padT = 14
  const padB = 52
  const innerW = Math.max(1, cssW - padL - padR)
  const innerH = Math.max(1, cssH - padT - padB)
  const N = panels.length
  const colW = innerW / N
  const tickLabelX = padL - 8

  const yToPx = y => padT + innerH * (1 - (y - yMin) / (yMax - yMin))

  const steps = 72
  const gridY = []
  for (let s = 0; s <= steps; s++) {
    gridY.push(yMin + (s / steps) * (yMax - yMin))
  }

  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, cssW, cssH)

  ctx.strokeStyle = '#e5e7eb'
  ctx.lineWidth = 1
  const ticks = 5
  ctx.fillStyle = '#6b7280'
  ctx.font = '10px sans-serif'
  ctx.textAlign = 'right'
  ctx.textBaseline = 'middle'
  for (let t = 0; t <= ticks; t++) {
    const frac = t / ticks
    const val = yMin + (yMax - yMin) * (1 - frac)
    const py = padT + innerH * frac
    ctx.beginPath()
    ctx.moveTo(padL, py)
    ctx.lineTo(padL + innerW, py)
    ctx.stroke()
    ctx.fillText(val.toExponential(2), tickLabelX, py)
  }

  const { fill: fillLeft, stroke: strokeLeft } = leftViolinColorsFromCategoryHex(opts.categoryColor)
  const fillRight = 'rgba(100, 116, 139, 0.42)'
  const strokeRight = '#475569'

  const trunc = (s, n) => {
    const t = String(s || '')
    return t.length > n ? t.slice(0, n - 3) + '...' : t
  }

  const hitColumns = []
  for (let j = 0; j < N; j++) {
    const colLeft = padL + j * colW
    const cx = colLeft + colW / 2
    const maxHalfW = colW * 0.38

    const L = finiteNumbers(panels[j].leftValues)
    const R = finiteNumbers(panels[j].rightValues)

    const dL = L.length ? kdeAtGrid(L, gridY) : gridY.map(() => 0)
    const dR = R.length ? kdeAtGrid(R, gridY) : gridY.map(() => 0)
    let maxD = 0
    for (let i = 0; i < dL.length; i++) maxD = Math.max(maxD, dL[i], dR[i])
    if (maxD <= 0) maxD = 1e-12

    const pathLeft = buildHalfViolinPath(cx, gridY, yToPx, maxHalfW, maxD, dL, 'left')
    const pathRight = buildHalfViolinPath(cx, gridY, yToPx, maxHalfW, maxD, dR, 'right')

    ctx.strokeStyle = '#94a3b8'
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(cx, padT)
    ctx.lineTo(cx, padT + innerH)
    ctx.stroke()

    ctx.fillStyle = fillLeft
    ctx.fill(pathLeft)
    ctx.strokeStyle = strokeLeft
    ctx.lineWidth = 1
    ctx.stroke(pathLeft)

    ctx.fillStyle = fillRight
    ctx.fill(pathRight)
    ctx.strokeStyle = strokeRight
    ctx.stroke(pathRight)

    const title = panels[j].title || ('Gene ' + (j + 1))
    const geneTitle = trunc(title, 18)
    hitColumns.push({
      colLeft,
      colW,
      cx,
      pathLeft,
      pathRight,
      statsL: computeViolinValueStats(L),
      statsR: computeViolinValueStats(R),
      leftTitle: geneTitle + ' — ' + trunc(leftLabel, 14) + ' (left)',
      rightTitle: geneTitle + ' — ' + trunc(rightLabel, 12) + ' (right)'
    })

    ctx.fillStyle = '#374151'
    ctx.font = '10px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'
    ctx.fillText(trunc(title, 14), cx, padT + innerH + 6)
  }

  const legY = padT + innerH + 20
  drawAnnotSplitViolinLegend(ctx, {
    padL,
    innerW,
    legY,
    leftLabel,
    rightLabel,
    fillLeft,
    strokeLeft,
    fillRight,
    strokeRight,
    trunc
  })

  ctx.save()
  ctx.translate(padLYAxisTitle / 2, padT + innerH / 2)
  ctx.rotate(-Math.PI / 2)
  ctx.textAlign = 'center'
  ctx.fillStyle = '#6b7280'
  ctx.fillText(yLabel, 0, 0)
  ctx.restore()

  bindAnnotViolinTooltip(canvas, ctx, dpr, {
    mode: 'multi',
    padT,
    innerH,
    columns: hitColumns
  })
}
