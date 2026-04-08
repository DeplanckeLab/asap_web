/**
 * Discrete (categorical) color palettes for the main plot.
 * Colorblind-friendly set = first 10 entries aligned with tab10 / server base.
 * Extended = full server palette (visualization_colors.yml via window.CATEGORY_COLORS) plus extra distinct hues.
 * Extended 200 = same as Extended, then generated distinct colors up to 200 total.
 */

export const DISCRETE_PALETTE_STORAGE_KEY = 'asap2_discrete_palette_id'

export const DISCRETE_PALETTE_COLORBLIND = 'colorblind_friendly'

export const DISCRETE_PALETTE_EXTENDED = 'extended'

export const DISCRETE_PALETTE_EXTENDED_200 = 'extended_200'

const EXTENDED_200_TARGET = 200

const GOLDEN_RATIO_CONJ = 0.618033988749895

function clampByte (x) {
  return Math.max(0, Math.min(255, Math.round(x)))
}

function hslToRgb (h, s, l) {
  const sat = s / 100
  const light = l / 100
  const c = (1 - Math.abs(2 * light - 1)) * sat
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  const m = light - c / 2
  let rp = 0; let gp = 0; let bp = 0
  if (h < 60) { rp = c; gp = x; bp = 0 } else if (h < 120) { rp = x; gp = c; bp = 0 } else if (h < 180) { rp = 0; gp = c; bp = x } else if (h < 240) { rp = 0; gp = x; bp = c } else if (h < 300) { rp = x; gp = 0; bp = c } else { rp = c; gp = 0; bp = x }
  return [
    clampByte((rp + m) * 255),
    clampByte((gp + m) * 255),
    clampByte((bp + m) * 255)
  ]
}

function rgbToHex (r, g, b) {
  return '#' + [r, g, b].map((v) => clampByte(v).toString(16).padStart(2, '0')).join('')
}

function generatedDistinctHex (index) {
  const h = (index * GOLDEN_RATIO_CONJ * 360) % 360
  const s = 52 + (index % 6) * 7
  const l = 38 + (index % 9) * 4.5
  const [r, g, b] = hslToRgb(h, s, l)
  return rgbToHex(r, g, b)
}

const TAB10_FALLBACK = [
  '#1f77b4',
  '#ff7f0e',
  '#2ca02c',
  '#9467bd',
  '#8c564b',
  '#e377c2',
  '#7f7f7f',
  '#bcbd22',
  '#17becf',
  '#4ecdc4'
]

const EXTENSION_ONLY_HEX = [
  '#f39c12',
  '#d35400',
  '#c0392b',
  '#8e44ad',
  '#2980b9',
  '#16a085',
  '#27ae60',
  '#2c3e50',
  '#e84393',
  '#00cec9',
  '#6c5ce7',
  '#fd79a8',
  '#a29bfe',
  '#00b894',
  '#fab1a0',
  '#e17055',
  '#0984e3',
  '#6ab04c'
]

export function getDefaultDiscretePaletteId () {
  return DISCRETE_PALETTE_EXTENDED
}

export const VALID_DISCRETE_PALETTE_IDS = new Set([
  DISCRETE_PALETTE_COLORBLIND,
  DISCRETE_PALETTE_EXTENDED,
  DISCRETE_PALETTE_EXTENDED_200
])

export function readStoredDiscretePaletteId () {
  try {
    const v = localStorage.getItem(DISCRETE_PALETTE_STORAGE_KEY)
    if (v && VALID_DISCRETE_PALETTE_IDS.has(v)) return v
  } catch (e) {
    // ignore
  }
  return DISCRETE_PALETTE_EXTENDED
}

export function writeStoredDiscretePaletteId (id) {
  try {
    localStorage.setItem(DISCRETE_PALETTE_STORAGE_KEY, id)
  } catch (e) {
    // ignore
  }
}

export function getColorblindFriendlyHexList () {
  if (typeof window !== 'undefined' && window.CATEGORY_COLORS && window.CATEGORY_COLORS.length >= 10) {
    return window.CATEGORY_COLORS.slice(0, 10)
  }
  return [...TAB10_FALLBACK]
}

export function getExtendedHexList () {
  const base = (typeof window !== 'undefined' && window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0)
    ? [...window.CATEGORY_COLORS]
    : [...TAB10_FALLBACK]
  const combined = [...base]
  const seen = new Set(combined.map(c => String(c).toLowerCase()))
  for (let i = 0; i < EXTENSION_ONLY_HEX.length; i++) {
    const h = EXTENSION_ONLY_HEX[i]
    const k = h.toLowerCase()
    if (!seen.has(k)) {
      combined.push(h)
      seen.add(k)
    }
  }
  return combined
}

export function getExtended200HexList () {
  const base = getExtendedHexList()
  const out = [...base]
  const seen = new Set(out.map((c) => String(c).toLowerCase()))
  let genI = 0
  const maxAttempts = 8000
  while (out.length < EXTENDED_200_TARGET && genI < maxAttempts) {
    const hex = generatedDistinctHex(genI)
    genI++
    const k = hex.toLowerCase()
    if (!seen.has(k)) {
      seen.add(k)
      out.push(hex)
    }
  }
  return out
}

export function getDiscretePaletteHexList (paletteId) {
  if (paletteId === DISCRETE_PALETTE_COLORBLIND) return getColorblindFriendlyHexList()
  if (paletteId === DISCRETE_PALETTE_EXTENDED_200) return getExtended200HexList()
  return getExtendedHexList()
}

export function getDiscretePaletteSelectLabels () {
  const cb = getColorblindFriendlyHexList()
  const ex = getExtendedHexList()
  const x200 = getExtended200HexList()
  return {
    [DISCRETE_PALETTE_COLORBLIND]: `Colorblind friendly (${cb.length})`,
    [DISCRETE_PALETTE_EXTENDED]: `Extended (${ex.length})`,
    [DISCRETE_PALETTE_EXTENDED_200]: `Extended 200 (${x200.length})`
  }
}
