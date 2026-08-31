// Searchable combobox for DE / compose group operands with metadata-grouped dropdown.

function escapeHtml(text) {
  const div = document.createElement('div')
  div.textContent = String(text ?? '')
  return div.innerHTML
}

export function buildComposeOperandOptionGroups(virtualOptions, savedOptions, categoryOptions, fanoutOptions = []) {
  const groups = []

  if ((fanoutOptions || []).length > 0) {
    groups.push({ label: 'Batch fan-out', options: fanoutOptions })
  }
  if ((virtualOptions || []).length > 0) {
    groups.push({ label: 'Virtual results', options: virtualOptions })
  }
  if ((savedOptions || []).length > 0) {
    groups.push({
      label: 'Saved selections',
      options: savedOptions.map((opt) => ({
        ...opt,
        searchText: String(opt.label || '').toLowerCase()
      }))
    })
  }

  const byMetadata = new Map()
  for (const opt of categoryOptions || []) {
    const metaName = String(opt.metadataName || 'Metadata').trim() || 'Metadata'
    if (!byMetadata.has(metaName)) byMetadata.set(metaName, [])
    byMetadata.get(metaName).push(opt)
  }

  Array.from(byMetadata.keys())
    .sort((a, b) => a.localeCompare(b))
    .forEach((metaName) => {
      const opts = byMetadata.get(metaName) || []
      opts.sort((a, b) => String(a.categoryName || a.label).localeCompare(String(b.categoryName || b.label)))
      groups.push({
        label: metaName,
        options: opts.map((opt) => {
          const categoryName = String(opt.categoryName || '').trim() || String(opt.label || '').trim()
          return {
            value: opt.value,
            label: categoryName,
            displayLabel: `${metaName}: ${categoryName}`,
            searchText: `${metaName} ${categoryName}`.toLowerCase()
          }
        })
      })
    })

  return groups
}

export class DeOperandCombobox {
  constructor(rootEl, { onChange, escapeHtmlFn } = {}) {
    if (!rootEl) throw new Error('DeOperandCombobox requires a root element')
    this.root = rootEl
    this.hiddenInput = rootEl.querySelector('[data-de-operand-value]')
    this.textInput = rootEl.querySelector('[data-de-operand-input]')
    this.dropdown = rootEl.querySelector('[data-de-operand-dropdown]')
    if (!this.hiddenInput || !this.textInput || !this.dropdown) {
      throw new Error('DeOperandCombobox root is missing required child elements')
    }
    this.onChange = typeof onChange === 'function' ? onChange : null
    this.escapeHtml = typeof escapeHtmlFn === 'function' ? escapeHtmlFn : escapeHtml
    this.groups = []
    this.optionByValue = new Map()
    this.highlightIndex = -1
    this.isOpen = false
    this.disabled = false

    this.boundDocMouseDown = this.handleDocumentMouseDown.bind(this)
    this.boundInputFocus = this.handleInputFocus.bind(this)
    this.boundInputInput = this.handleInputInput.bind(this)
    this.boundInputKeyDown = this.handleInputKeyDown.bind(this)
    this.boundDropdownMouseDown = this.handleDropdownMouseDown.bind(this)

    this.textInput.addEventListener('focus', this.boundInputFocus)
    this.textInput.addEventListener('input', this.boundInputInput)
    this.textInput.addEventListener('keydown', this.boundInputKeyDown)
    this.dropdown.addEventListener('mousedown', this.boundDropdownMouseDown)
  }

  destroy() {
    document.removeEventListener('mousedown', this.boundDocMouseDown)
    this.textInput.removeEventListener('focus', this.boundInputFocus)
    this.textInput.removeEventListener('input', this.boundInputInput)
    this.textInput.removeEventListener('keydown', this.boundInputKeyDown)
    this.dropdown.removeEventListener('mousedown', this.boundDropdownMouseDown)
  }

  setDisabled(disabled) {
    this.disabled = !!disabled
    this.textInput.disabled = this.disabled
    if (this.disabled) this.closeDropdown()
  }

  setGroups(groups) {
    this.groups = Array.isArray(groups) ? groups : []
    this.optionByValue.clear()
    for (const group of this.groups) {
      for (const opt of group.options || []) {
        this.optionByValue.set(String(opt.value), opt)
      }
    }
    this.renderDropdown(this.textInput.value)
  }

  getValue() {
    return String(this.hiddenInput?.value || '')
  }

  setValue(value, { silent = false } = {}) {
    const normalized = String(value || '')
    if (this.hiddenInput) this.hiddenInput.value = normalized
    const opt = this.optionByValue.get(normalized)
    if (this.textInput) {
      this.textInput.value = opt ? String(opt.label || '') : ''
    }
    if (!silent && this.onChange) this.onChange(normalized)
  }

  getDisplayLabelForValue(value) {
    const opt = this.optionByValue.get(String(value || ''))
    if (!opt) return ''
    return String(opt.displayLabel || opt.label || '')
  }

  openDropdown() {
    if (this.disabled) return
    this.isOpen = true
    this.dropdown.style.display = 'block'
    document.addEventListener('mousedown', this.boundDocMouseDown)
  }

  closeDropdown() {
    this.isOpen = false
    this.highlightIndex = -1
    this.dropdown.style.display = 'none'
    document.removeEventListener('mousedown', this.boundDocMouseDown)
    const currentValue = this.getValue()
    const label = this.getDisplayLabelForValue(currentValue)
    if (this.textInput) this.textInput.value = label
  }

  handleDocumentMouseDown(event) {
    if (!this.root.contains(event.target)) {
      this.closeDropdown()
    }
  }

  handleInputFocus() {
    this.renderDropdown(this.textInput.value)
    this.openDropdown()
  }

  handleInputInput() {
    this.renderDropdown(this.textInput.value)
    if (!this.isOpen) this.openDropdown()
  }

  handleInputKeyDown(event) {
    const flatItems = this.getVisibleFlatItems(this.textInput.value)
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      if (!this.isOpen) this.openDropdown()
      this.highlightIndex = Math.min(flatItems.length - 1, this.highlightIndex + 1)
      this.renderDropdown(this.textInput.value)
      return
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault()
      this.highlightIndex = Math.max(0, this.highlightIndex - 1)
      this.renderDropdown(this.textInput.value)
      return
    }
    if (event.key === 'Enter') {
      event.preventDefault()
      if (this.highlightIndex >= 0 && flatItems[this.highlightIndex]) {
        this.selectOption(flatItems[this.highlightIndex].value)
      }
      return
    }
    if (event.key === 'Escape') {
      event.preventDefault()
      this.closeDropdown()
    }
  }

  handleDropdownMouseDown(event) {
    event.preventDefault()
    const itemEl = event.target.closest('[data-de-operand-option-value]')
    if (!itemEl) return
    this.selectOption(itemEl.dataset.deOperandOptionValue)
  }

  selectOption(value) {
    this.setValue(value)
    this.closeDropdown()
  }

  normalizeQuery(query) {
    return String(query || '').trim().toLowerCase()
  }

  filterGroups(query) {
    const q = this.normalizeQuery(query)
    if (!q) return this.groups

    return this.groups
      .map((group) => ({
        label: group.label,
        options: (group.options || []).filter((opt) => String(opt.searchText || opt.label || '').includes(q))
      }))
      .filter((group) => (group.options || []).length > 0)
  }

  getVisibleFlatItems(query) {
    const items = []
    for (const group of this.filterGroups(query)) {
      for (const opt of group.options || []) items.push(opt)
    }
    return items
  }

  renderDropdown(query) {
    const filtered = this.filterGroups(query)
    const flatItems = []
    for (const group of filtered) {
      for (const opt of group.options || []) flatItems.push(opt)
    }
    if (this.highlightIndex >= flatItems.length) {
      this.highlightIndex = flatItems.length > 0 ? flatItems.length - 1 : -1
    }

    if (filtered.length === 0) {
      this.dropdown.innerHTML =
        '<div style="padding: 10px 12px; font-size: 12px; color: #6b7280;">No matching groups</div>'
      return
    }

    const parts = []
    let itemIndex = 0
    for (const group of filtered) {
      parts.push(
        `<div style="padding: 6px 12px 4px; font-size: 11px; font-weight: 600; color: #6b7280; background: #f9fafb; border-bottom: 1px solid #f3f4f6;">${this.escapeHtml(group.label)}</div>`
      )
      for (const opt of group.options || []) {
        const isHighlighted = itemIndex === this.highlightIndex
        const bg = isHighlighted ? '#eff6ff' : '#fff'
        parts.push(
          `<div data-de-operand-option-value="${this.escapeHtml(opt.value)}" ` +
          `style="padding: 8px 12px 8px 20px; font-size: 12px; color: #111827; cursor: pointer; background: ${bg}; border-bottom: 1px solid #f3f4f6;">` +
          `${this.escapeHtml(opt.label)}</div>`
        )
        itemIndex += 1
      }
    }
    this.dropdown.innerHTML = parts.join('')
  }
}
