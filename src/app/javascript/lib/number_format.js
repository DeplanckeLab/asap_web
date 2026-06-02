export function formatNumberWithDelimiter(value) {
  if (value === null || value === undefined || value === '') {
    return '0'
  }

  const number = Number(value)
  if (!Number.isFinite(number)) {
    return '0'
  }

  const integerPart = Math.trunc(number).toString()
  return integerPart.replace(/\B(?=(\d{3})+(?!\d))/g, "'")
}
