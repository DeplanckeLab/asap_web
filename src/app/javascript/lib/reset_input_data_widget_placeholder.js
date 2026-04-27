/**
 * Reset an input-data-selector widget (e.g. groups2) to its empty label from attrs
 * (dropdown_placeholder / emptyDropdownLabel). Falls back only if Stimulus is not ready.
 */
export function resetInputDataWidgetToEmptyPlaceholder(root, application) {
  if (!root || !application) {
    return
  }
  const widget =
    root.querySelector(
      '[data-controller*="input-data-selector"][data-input-data-selector-attr-name-value="groups2"]'
    ) || root.querySelector('[data-controller*="input-data-selector"]')
  if (!widget) {
    return
  }
  const c = application.getControllerForElementAndIdentifier(widget, 'input-data-selector')
  if (c && typeof c.applyEmptyDropdownLabel === 'function') {
    c.applyEmptyDropdownLabel()
    return
  }
  const text = root.querySelector('[data-input-data-selector-target="dropdownText"]')
  if (text) {
    text.textContent = '-- Select second metadata --'
    text.classList.add('text-gray-500')
    text.classList.remove('text-gray-900', 'font-medium')
  }
}
