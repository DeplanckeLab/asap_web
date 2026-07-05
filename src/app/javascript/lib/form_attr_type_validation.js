export function attrTypeValidationError(value, attrType) {
  if (!attrType) {
    return null
  }

  const type = String(attrType).trim().toLowerCase()
  if (!type || type === "text") {
    return null
  }

  if (value == null) {
    return null
  }

  const str = String(value).trim()
  if (str === "") {
    return null
  }

  switch (type) {
    case "int":
      if (!/^-?\d+$/.test(str)) {
        return "Value must be an integer"
      }
      return null
    case "float": {
      const num = Number(str)
      if (!Number.isFinite(num)) {
        return "Value must be a number"
      }
      return null
    }
    case "bool":
      if (str !== "true" && str !== "false") {
        return "Value must be true or false"
      }
      return null
    default:
      return null
  }
}
