export const DEFAULT_NAN_COLOR_HEX = '#d1d5db'
export const DEFAULT_NAN_COLOR_INT = 0xd1d5db

export function parseNanColor(value) {
  if (value == null || value === '') return DEFAULT_NAN_COLOR_INT
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      throw new Error('NaN color must be a finite RGB integer')
    }
    const packed = value >>> 0
    if ((packed & 0xffffff) === 0) {
      throw new Error('NaN color cannot be 0')
    }
    return packed & 0xffffff
  }

  const str = String(value).trim()
  const hex = str.startsWith('#') ? str.slice(1) : str
  if (!/^[0-9a-fA-F]{6}$/.test(hex)) {
    throw new Error(`Invalid NaN color: ${value}`)
  }
  const packed = parseInt(hex, 16)
  if (packed === 0) {
    throw new Error('NaN color cannot be 0')
  }
  return packed
}

export function nanColorToHex(value) {
  const packed = parseNanColor(value)
  return `#${packed.toString(16).padStart(6, '0')}`
}

export function nanColorToRgb(value) {
  const packed = parseNanColor(value)
  return [
    ((packed >> 16) & 255) / 255,
    ((packed >> 8) & 255) / 255,
    (packed & 255) / 255
  ]
}
