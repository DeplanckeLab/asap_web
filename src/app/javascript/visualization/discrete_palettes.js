/**
 * Discrete (categorical) color palettes for the main plot.
 *
 * Two palettes are exposed:
 *   - colorblind_friendly: 200 colors, starting with the server-provided
 *     colorblind-friendly base (visualization_colors.yml via window.CATEGORY_COLORS)
 *     plus additional distinct hues padded up to 200.
 *   - high_contrast: 200 colors, not colorblind friendly, ordered so the first
 *     entries are maximally distinct in CIELAB space (farthest-point-first)
 *     and later entries are progressively closer to already-used colors.
 */

export const DISCRETE_PALETTE_STORAGE_KEY = 'asap2_discrete_palette_id'

export const DISCRETE_PALETTE_COLORBLIND = 'colorblind_friendly'

export const DISCRETE_PALETTE_HIGH_CONTRAST = 'high_contrast'

const PALETTE_TARGET_SIZE = 200

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

function hexToRgbTriple (hex) {
  const h = String(hex).replace('#', '')
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16)
  ]
}

function srgbToLinear (c) {
  const v = c / 255
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function rgbToLab (r, g, b) {
  const rl = srgbToLinear(r)
  const gl = srgbToLinear(g)
  const bl = srgbToLinear(b)
  // D65 reference white, sRGB matrix
  const x = (rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375) / 0.95047
  const y = (rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750)
  const z = (rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041) / 1.08883
  const f = (t) => t > 0.008856 ? Math.cbrt(t) : (7.787 * t) + 16 / 116
  const fx = f(x); const fy = f(y); const fz = f(z)
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
}

function labDistSq (a, b) {
  const dL = a[0] - b[0]
  const da = a[1] - b[1]
  const db = a[2] - b[2]
  return dL * dL + da * da + db * db
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
  return DISCRETE_PALETTE_COLORBLIND
}

export const VALID_DISCRETE_PALETTE_IDS = new Set([
  DISCRETE_PALETTE_COLORBLIND,
  DISCRETE_PALETTE_HIGH_CONTRAST
])

// Map legacy ids (previous palette scheme) to the current ones. Any stored
// preference pointing to a removed palette is migrated transparently.
const LEGACY_PALETTE_ID_MAP = {
  extended: DISCRETE_PALETTE_COLORBLIND,
  extended_200: DISCRETE_PALETTE_COLORBLIND
}

function normalizeStoredPaletteId (raw) {
  if (!raw) return null
  if (VALID_DISCRETE_PALETTE_IDS.has(raw)) return raw
  if (Object.prototype.hasOwnProperty.call(LEGACY_PALETTE_ID_MAP, raw)) {
    return LEGACY_PALETTE_ID_MAP[raw]
  }
  return null
}

export function readStoredDiscretePaletteId () {
  try {
    const raw = localStorage.getItem(DISCRETE_PALETTE_STORAGE_KEY)
    const normalized = normalizeStoredPaletteId(raw)
    if (normalized) {
      if (normalized !== raw) {
        try { localStorage.setItem(DISCRETE_PALETTE_STORAGE_KEY, normalized) } catch (e) { /* ignore */ }
      }
      return normalized
    }
  } catch (e) {
    // ignore
  }
  return getDefaultDiscretePaletteId()
}

export function writeStoredDiscretePaletteId (id) {
  try {
    localStorage.setItem(DISCRETE_PALETTE_STORAGE_KEY, id)
  } catch (e) {
    // ignore
  }
}

function getColorblindBaseHexList () {
  const base = (typeof window !== 'undefined' && window.CATEGORY_COLORS && window.CATEGORY_COLORS.length > 0)
    ? [...window.CATEGORY_COLORS]
    : [...TAB10_FALLBACK]
  const combined = [...base]
  const seen = new Set(combined.map((c) => String(c).toLowerCase()))
  for (let i = 0; i < EXTENSION_ONLY_HEX.length; i++) {
    const hex = EXTENSION_ONLY_HEX[i]
    const k = hex.toLowerCase()
    if (!seen.has(k)) {
      combined.push(hex)
      seen.add(k)
    }
  }
  return combined
}

let colorblindFriendlyCache = null

export function getColorblindFriendlyHexList () {
  if (colorblindFriendlyCache) return colorblindFriendlyCache
  const out = getColorblindBaseHexList()
  const seen = new Set(out.map((c) => String(c).toLowerCase()))
  let genI = 0
  const maxAttempts = 8000
  while (out.length < PALETTE_TARGET_SIZE && genI < maxAttempts) {
    const hex = generatedDistinctHex(genI)
    genI++
    const k = hex.toLowerCase()
    if (!seen.has(k)) {
      seen.add(k)
      out.push(hex)
    }
  }
  colorblindFriendlyCache = out
  return out
}

let highContrastCache = null

function buildHighContrastCandidatePool () {
  const candidates = []
  const seen = new Set()
  // HSL grid: fine hue resolution, multiple saturations and lightnesses
  // so the farthest-first selection has a rich pool to draw from.
  for (let h = 0; h < 360; h += 10) {
    for (const s of [55, 75, 95]) {
      for (const l of [35, 50, 65, 80]) {
        const [r, g, b] = hslToRgb(h, s, l)
        const hex = rgbToHex(r, g, b)
        const k = hex.toLowerCase()
        if (seen.has(k)) continue
        seen.add(k)
        candidates.push({ hex, lab: rgbToLab(r, g, b) })
      }
    }
  }
  return candidates
}

export function getHighContrastHexList () {
  if (highContrastCache) return highContrastCache

  const candidates = buildHighContrastCandidatePool()

  // Seed with a vivid red so the first color is deterministic and visually
  // familiar. Subsequent colors are chosen greedily by maximizing the
  // minimum CIELAB distance to the already-selected set.
  const seedHex = '#e41a1c'
  const [sr, sg, sb] = hexToRgbTriple(seedHex)
  const seedLab = rgbToLab(sr, sg, sb)

  const out = [seedHex]
  const selected = new Set([seedHex.toLowerCase()])
  const minDistSq = new Array(candidates.length)
  for (let i = 0; i < candidates.length; i++) {
    minDistSq[i] = labDistSq(candidates[i].lab, seedLab)
  }

  while (out.length < PALETTE_TARGET_SIZE) {
    let bestIdx = -1
    let bestDist = -1
    for (let i = 0; i < candidates.length; i++) {
      if (selected.has(candidates[i].hex.toLowerCase())) continue
      const d = minDistSq[i]
      if (d > bestDist) {
        bestDist = d
        bestIdx = i
      }
    }
    if (bestIdx < 0) break

    const picked = candidates[bestIdx]
    out.push(picked.hex)
    selected.add(picked.hex.toLowerCase())

    for (let i = 0; i < candidates.length; i++) {
      if (selected.has(candidates[i].hex.toLowerCase())) continue
      const d = labDistSq(candidates[i].lab, picked.lab)
      if (d < minDistSq[i]) minDistSq[i] = d
    }
  }

  highContrastCache = out
  return out
}

export function getDiscretePaletteHexList (paletteId) {
  if (paletteId === DISCRETE_PALETTE_HIGH_CONTRAST) return getHighContrastHexList()
  return getColorblindFriendlyHexList()
}

export function getDiscretePaletteSelectLabels () {
  const cb = getColorblindFriendlyHexList()
  const hc = getHighContrastHexList()
  return {
    [DISCRETE_PALETTE_COLORBLIND]: `Colorblind friendly (${cb.length} colors)`,
    [DISCRETE_PALETTE_HIGH_CONTRAST]: `High contrast (${hc.length} colors)`
  }
}
