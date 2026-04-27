// Second-metadata-column toggle for DE forms: std_method attrs_json may use either name.
const DE_SECOND_METADATA_TOGGLE_ATTR_NAMES = [
  "second_group_from_other_metadata",
  "group_comp_from_other_metadata"
]

export function queryDeSecondMetadataCheckbox(root) {
  if (!root || typeof root.querySelector !== "function") return null
  for (const name of DE_SECOND_METADATA_TOGGLE_ATTR_NAMES) {
    const el = root.querySelector(`#checkbox-${name}`)
    if (el) return el
  }
  return null
}

export function queryDeSecondMetadataHidden(root) {
  if (!root || typeof root.querySelector !== "function") return null
  for (const name of DE_SECOND_METADATA_TOGGLE_ATTR_NAMES) {
    const el = root.querySelector(`#attrs_${name}`)
    if (el) return el
  }
  return null
}

export function queryDeSecondMetadataFormBlock(root) {
  if (!root || typeof root.querySelector !== "function") return null
  for (const name of DE_SECOND_METADATA_TOGGLE_ATTR_NAMES) {
    const el = root.querySelector(`#form-container_${name}`)
    if (el) return el
  }
  return null
}
