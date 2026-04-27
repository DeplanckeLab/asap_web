import { Controller } from "@hotwired/stimulus"
import { queryDeSecondMetadataHidden } from "visualization/de_second_metadata_attrs"

export default class extends Controller {
  static targets = [
    "dropdownButton",
    "dropdownMenu",
    "dropdownText",
    "selectedDiv",
    "hiddenField",
    "option"
  ]

  static values = {
    attrName: String,
    isArray: Boolean,
    minItems: { type: Number, default: 0 },
    maxItems: { type: Number, default: null },
    isMultiple: Boolean,
    dropdownPlaceholder: { type: String, default: "" }
  }

  emptyDropdownLabel() {
    const custom = (this.dropdownPlaceholderValue || "").trim()
    if (custom.length > 0) {
      return custom
    }
    const title = this.attrNameValue.replace(/_/g, " ").replace(/\b\w/g, (l) => l.toUpperCase())
    return `-- Select ${title} --`
  }

  applyEmptyDropdownLabel() {
    if (!this.hasDropdownTextTarget) {
      return
    }
    this.dropdownTextTarget.textContent = this.emptyDropdownLabel()
    this.dropdownTextTarget.classList.remove('text-gray-900', 'font-medium')
    this.dropdownTextTarget.classList.add('text-gray-500')
  }

  connect() {
    console.log("[InputDataSelectorController] Connected for", this.attrNameValue)
    console.log("[InputDataSelectorController] Has targets:", {
      dropdownButton: this.hasDropdownButtonTarget,
      dropdownMenu: this.hasDropdownMenuTarget,
      hiddenField: this.hasHiddenFieldTarget,
      options: this.optionTargets.length
    })
    
    // Add click outside listener
    this.boundCloseDropdown = this.closeDropdown.bind(this)
    document.addEventListener('click', this.boundCloseDropdown, true)

    this.formElement = this.element.closest('form')
    this.boundMatrixContextChanged = this.handleMatrixContextChanged.bind(this)
    if (this.formElement) {
      this.formElement.addEventListener('input-data:matrix-context-changed', this.boundMatrixContextChanged)
    }
    
    this.restoreSelectionFromHiddenField()
    this.applyCurrentMatrixContextFromForm()
    this.updateSelectedItems()
    this.validateSelection()
  }

  disconnect() {
    if (this.boundCloseDropdown) {
      document.removeEventListener('click', this.boundCloseDropdown, true)
    }
    if (this._boundGroupRefChangeHandler) {
      const refSelect = this._deGroupRefSelect || document.getElementById("attrs_group_ref")
      if (refSelect) {
        refSelect.removeEventListener("change", this._boundGroupRefChangeHandler)
      }
      this._boundGroupRefChangeHandler = null
      this._deGroupRefSelect = null
    }
    if (this.formElement && this.boundMatrixContextChanged) {
      this.formElement.removeEventListener('input-data:matrix-context-changed', this.boundMatrixContextChanged)
    }
  }

  toggleDropdown(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const isHidden = this.dropdownMenuTarget.classList.contains('hidden')
    console.log("[InputDataSelectorController] Toggle dropdown for", this.attrNameValue, "isHidden:", isHidden, "options:", this.optionTargets.length)
    
    // Close all other dropdowns
    document.querySelectorAll('[data-input-data-selector-target="dropdownMenu"]').forEach((menu) => {
      if (menu !== this.dropdownMenuTarget) {
        menu.classList.add('hidden')
      }
    })
    
    if (isHidden) {
      this.dropdownMenuTarget.classList.remove('hidden')
      // Position relative to button with no gap
      this.dropdownMenuTarget.style.width = this.dropdownButtonTarget.offsetWidth + 'px'
      this.dropdownMenuTarget.style.display = 'block'
      this.dropdownMenuTarget.style.position = 'absolute'
      this.dropdownMenuTarget.style.zIndex = '9999'
      this.dropdownMenuTarget.style.top = '100%'
      this.dropdownMenuTarget.style.left = '0'
      this.dropdownMenuTarget.style.marginTop = '0'
      // Hide selected tags when dropdown is open
      if (this.hasSelectedDivTarget && !this.selectedDivTarget.classList.contains('hidden')) {
        this.selectedDivTarget.classList.add('hidden')
      }
      console.log("[InputDataSelectorController] Dropdown opened, visible:", this.dropdownMenuTarget.offsetHeight > 0)
    } else {
      this.dropdownMenuTarget.classList.add('hidden')
      this.dropdownMenuTarget.style.display = 'none'
      // Show selected tags when dropdown is closed (if there are any selected)
      if (this.hasSelectedDivTarget && this.selectedDivTarget.children.length > 0) {
        this.selectedDivTarget.classList.remove('hidden')
      }
    }
  }

  closeDropdown(event) {
    // Close if clicking outside
    if (!this.dropdownMenuTarget.contains(event.target) && !this.dropdownButtonTarget.contains(event.target)) {
      this.dropdownMenuTarget.classList.add('hidden')
      this.dropdownMenuTarget.style.display = 'none'
      // Show selected tags when dropdown is closed (if there are any selected)
      if (this.hasSelectedDivTarget && this.selectedDivTarget.children.length > 0) {
        this.selectedDivTarget.classList.remove('hidden')
      }
    }
  }

  optionChanged(event) {
    const input = event.target
    console.log("[InputDataSelectorController] Option changed:", input.value, "checked:", input.checked)
    
    if (!this.isMultipleValue && input.checked) {
      // For radio buttons, uncheck others
      this.optionTargets.forEach((opt) => {
        if (opt !== input) opt.checked = false
      })
    }
    
    this.updateSelectedItems()

    // UX: for single-select widgets (radio), close dropdown immediately after selection
    if (!this.isMultipleValue && input.checked) {
      this.dropdownMenuTarget.classList.add('hidden')
      this.dropdownMenuTarget.style.display = 'none'
      if (this.hasSelectedDivTarget && this.selectedDivTarget.children.length > 0) {
        this.selectedDivTarget.classList.remove('hidden')
      }
    }
  }

  removeSelected(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const label = event.target.closest('span').textContent.replace('×', '').trim()
    console.log("[InputDataSelectorController] Remove selected:", label)
    
    this.optionTargets.forEach((opt) => {
      if (opt.checked) {
        const optionLabel = opt.closest('label')
        if (optionLabel) {
          const stepRunInfo = optionLabel.querySelector('.font-medium')
          if (stepRunInfo && stepRunInfo.textContent.trim() === label) {
            opt.checked = false
          }
        }
      }
    })
    
    this.updateSelectedItems()
  }

  updateSelectedItems() {
    const selectedValues = []
    const selectedLabels = []
    
    this.optionTargets.forEach((input) => {
      if (input.checked) {
        try {
          const dataValue = JSON.parse(input.value)
          selectedValues.push(dataValue)
          const label = input.closest('label')
          if (label) {
            const stepRunInfo = label.querySelector('.font-medium')
            if (stepRunInfo) {
              selectedLabels.push(stepRunInfo.textContent)
            }
          }
        } catch (e) {
          console.error("[InputDataSelectorController] Error parsing option value:", e)
        }
      }
    })
    
    // Update hidden field
    if (this.isArrayValue) {
      this.hiddenFieldTarget.value = JSON.stringify(selectedValues)
    } else {
      this.hiddenFieldTarget.value = selectedValues.length > 0 ? JSON.stringify(selectedValues[0]) : ''
    }

    this.updateDependentCategorySelect(selectedValues)
    this.updateDeGroupSelectsFromPrimaryMetadata(selectedValues)
    this.updateDeGroupCompFromSecondaryMetadata(selectedValues)
    this.broadcastMatrixContextIfNeeded(selectedValues)
    
    // Update display
    if (selectedValues.length > 0) {
      this.dropdownTextTarget.textContent = selectedValues.length + ' item' + (selectedValues.length > 1 ? 's' : '') + ' selected'
      this.dropdownTextTarget.classList.remove('text-gray-500')
      this.dropdownTextTarget.classList.add('text-gray-900', 'font-medium')
      
      // Build selected items tags
      this.selectedDivTarget.innerHTML = ''
      selectedLabels.forEach((label) => {
        const badge = document.createElement('span')
        badge.className = 'inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800 mr-2 mb-1'
        badge.textContent = label
        const removeBtn = document.createElement('button')
        removeBtn.type = 'button'
        removeBtn.className = 'ml-1.5 inline-flex items-center justify-center w-4 h-4 text-blue-600 hover:text-blue-800 rounded-full hover:bg-blue-200'
        removeBtn.innerHTML = '×'
        removeBtn.addEventListener('click', (e) => this.removeSelected(e))
        badge.appendChild(removeBtn)
        this.selectedDivTarget.appendChild(badge)
      })
      // Only show selected tags when dropdown is closed
      const isDropdownOpen = !this.dropdownMenuTarget.classList.contains('hidden')
      if (!isDropdownOpen) {
        this.selectedDivTarget.classList.remove('hidden')
      } else {
        this.selectedDivTarget.classList.add('hidden')
      }
    } else {
      this.applyEmptyDropdownLabel()
      this.selectedDivTarget.classList.add('hidden')
      this.selectedDivTarget.innerHTML = ''
    }
    
    // Validate and trigger form validation
    this.validateSelection()
  }

  broadcastMatrixContextIfNeeded(selectedValues) {
    if (this.attrNameValue !== 'input_matrix' || !this.formElement) {
      return
    }

    const selected = selectedValues.length > 0 ? selectedValues[0] : null
    const loomFile = selected && selected.output_filename ? String(selected.output_filename) : ''
    const event = new CustomEvent('input-data:matrix-context-changed', {
      bubbles: true,
      detail: { loomFile: loomFile }
    })
    this.formElement.dispatchEvent(event)
  }

  handleMatrixContextChanged(event) {
    if (this.attrNameValue !== 'groups' && this.attrNameValue !== 'groups2') {
      return
    }
    const loomFile = event && event.detail && event.detail.loomFile ? String(event.detail.loomFile) : ''
    this.filterOptionsByLoomFile(loomFile)
    this.updateSelectedItems()
  }

  applyCurrentMatrixContextFromForm() {
    if (this.attrNameValue !== 'groups' && this.attrNameValue !== 'groups2') {
      return
    }
    const loomFile = this.getSelectedMatrixLoomFromForm()
    this.filterOptionsByLoomFile(loomFile)
  }

  getSelectedMatrixLoomFromForm() {
    if (!this.formElement) {
      return ''
    }
    const hidden = this.formElement.querySelector('#attrs_input_matrix, [name="attrs[input_matrix]"]')
    if (!hidden || !hidden.value) {
      return ''
    }

    try {
      const parsed = JSON.parse(hidden.value)
      if (Array.isArray(parsed)) {
        const first = parsed[0]
        return first && first.output_filename ? String(first.output_filename) : ''
      }
      if (parsed && typeof parsed === 'object') {
        return parsed.output_filename ? String(parsed.output_filename) : ''
      }
    } catch (_error) {
      return ''
    }
    return ''
  }

  inlineValidationElement() {
    const container = this.element.parentElement
    if (!container) {
      return null
    }
    const name = this.attrNameValue
    const candidates = container.querySelectorAll("[data-input-data-validation-inline]")
    for (let i = 0; i < candidates.length; i++) {
      const el = candidates[i]
      if (el.getAttribute("data-input-data-validation-inline") === name) {
        return el
      }
    }
    return null
  }

  normalizeMaxItems() {
    const raw = this.maxItemsValue
    if (raw == null || raw === "") {
      return null
    }
    const n = Number(raw)
    return Number.isFinite(n) && n > 0 ? n : null
  }

  minSelectionErrorMessage() {
    const min = this.minItemsValue
    const maxNum = this.normalizeMaxItems()
    const onlyOneSelectable = !this.isMultipleValue || maxNum === 1

    if (min > 0 && maxNum != null && min === maxNum) {
      return `Please select exactly ${min} item${min > 1 ? "s" : ""}`
    }
    if (min === 1 && onlyOneSelectable) {
      return "Please select exactly 1 item"
    }
    return `Please select at least ${min} item${min > 1 ? "s" : ""}`
  }

  selectedCountSuccessMessage(count) {
    if (count === 1) {
      return "1 item selected"
    }
    return `${count} items selected`
  }

  setInlineFeedback(inline, kind, text) {
    if (!inline) {
      return
    }
    const base = "ml-2 inline-flex items-center rounded-md border px-2 py-0.5 text-xs font-medium"
    if (kind === "hide") {
      inline.textContent = ""
      inline.className = "ml-2 hidden"
      return
    }
    if (kind === "error") {
      inline.className = `${base} border-red-200 bg-red-50 text-red-800`
      inline.textContent = text
      return
    }
    if (kind === "ok") {
      inline.className = `${base} border-green-200 bg-green-50 text-green-800`
      inline.textContent = text
    }
  }

  filterOptionsByLoomFile(loomFile) {
    this.optionTargets.forEach((input) => {
      let optionValue = null
      try {
        optionValue = JSON.parse(input.value)
      } catch (_error) {
        optionValue = null
      }

      const optionLabel = input.closest('label')
      if (!optionLabel || !optionValue) {
        return
      }

      const optionLoom = optionValue.output_filename ? String(optionValue.output_filename) : ''
      const shouldShow = !loomFile || optionLoom === loomFile

      optionLabel.style.display = shouldShow ? '' : 'none'
      if (!shouldShow && input.checked) {
        input.checked = false
      }
    })
  }

  validateSelection() {
    const selectedCount = this.optionTargets.filter((input) => input.checked).length
    let isValid = true
    const inline = this.inlineValidationElement()
    const maxNum = this.normalizeMaxItems()

    if (this.minItemsValue > 0 && selectedCount < this.minItemsValue) {
      this.setInlineFeedback(inline, "error", this.minSelectionErrorMessage())
      isValid = false
    } else if (maxNum != null && selectedCount > maxNum) {
      this.setInlineFeedback(
        inline,
        "error",
        "Please select at most " + maxNum + " item" + (maxNum > 1 ? "s" : "")
      )
      isValid = false
    } else if (selectedCount === 0 && this.minItemsValue === 0) {
      this.setInlineFeedback(inline, "hide")
    } else {
      this.setInlineFeedback(inline, "ok", this.selectedCountSuccessMessage(selectedCount))
    }
    
    // Dispatch custom event for form validation
    const event = new CustomEvent('validation-changed', {
      bubbles: true,
      detail: { isValid: isValid, selectedCount: selectedCount }
    })
    this.element.dispatchEvent(event)
    
    return isValid
  }

  restoreSelectionFromHiddenField() {
    if (!this.hasHiddenFieldTarget || !this.hiddenFieldTarget.value) {
      return
    }

    let parsedValue = null
    try {
      parsedValue = JSON.parse(this.hiddenFieldTarget.value)
    } catch (error) {
      return
    }

    const selectedItems = Array.isArray(parsedValue) ? parsedValue : [parsedValue]
    if (selectedItems.length === 0) {
      return
    }

    this.optionTargets.forEach((optionInput) => {
      let optionValue = null
      try {
        optionValue = JSON.parse(optionInput.value)
      } catch (error) {
        optionValue = null
      }

      if (!optionValue) {
        optionInput.checked = false
        return
      }

      optionInput.checked = selectedItems.some((selectedItem) => this.valuesMatch(selectedItem, optionValue))
    })

    if (!this.isMultipleValue) {
      let foundChecked = false
      this.optionTargets.forEach((optionInput) => {
        if (optionInput.checked && !foundChecked) {
          foundChecked = true
        } else if (optionInput.checked) {
          optionInput.checked = false
        }
      })
    }
  }

  valuesMatch(a, b) {
    if (!a || !b) {
      return false
    }

    if (a.annot_id && b.annot_id) {
      return String(a.annot_id) === String(b.annot_id)
    }

    if (a.run_id && b.run_id && a.output_dataset && b.output_dataset) {
      return String(a.run_id) === String(b.run_id) && String(a.output_dataset) === String(b.output_dataset)
    }

    return false
  }

  updateDependentCategorySelect(selectedValues) {
    const dependentSelect = document.getElementById(`attrs_${this.attrNameValue}_sel`)
    if (!dependentSelect) {
      return
    }
    const currentValue = dependentSelect.value

    const selected = selectedValues.length > 0 ? selectedValues[0] : null
    const categories = selected && selected.categories && typeof selected.categories === 'object'
      ? selected.categories
      : null

    dependentSelect.innerHTML = ''

    if (!categories) {
      const option = document.createElement('option')
      option.value = ''
      option.textContent = 'Select a category'
      dependentSelect.appendChild(option)
      dependentSelect.value = ''
      dependentSelect.dispatchEvent(new Event('change', { bubbles: true }))
      return
    }

    const categoryNames = Object.keys(categories).filter((name) => name !== '').sort()
    if (categoryNames.length === 0) {
      const option = document.createElement('option')
      option.value = ''
      option.textContent = 'No category available'
      dependentSelect.appendChild(option)
      dependentSelect.value = ''
      dependentSelect.dispatchEvent(new Event('change', { bubbles: true }))
      return
    }

    categoryNames.forEach((categoryName, index) => {
      const count = categories[categoryName]
      const option = document.createElement('option')
      option.value = categoryName
      option.textContent = Number.isFinite(Number(count))
        ? `${categoryName} (${count})`
        : categoryName
      if ((currentValue && categoryName === currentValue) || (!currentValue && index === 0)) {
        option.selected = true
      }
      dependentSelect.appendChild(option)
    })

    dependentSelect.dispatchEvent(new Event('change', { bubbles: true }))
  }

  isSecondGroupFromOtherMetadata() {
    const root = this.formElement || this.element.closest("form")
    if (!root) {
      return false
    }
    const h = queryDeSecondMetadataHidden(root)
    return !!(h && String(h.value) === "true")
  }

  teardownDeGroupRefSyncedCompListener() {
    if (this._boundGroupRefChangeHandler && this._deGroupRefSelect) {
      this._deGroupRefSelect.removeEventListener("change", this._boundGroupRefChangeHandler)
    }
    this._boundGroupRefChangeHandler = null
    this._deGroupRefSelect = null
  }

  deFillCategorySelect(select, categoryNames, categories, keepValue, placeholderText) {
    select.innerHTML = ""
    if (!categoryNames || categoryNames.length === 0) {
      const emptyOption = document.createElement("option")
      emptyOption.value = ""
      emptyOption.textContent = placeholderText
      select.appendChild(emptyOption)
      select.value = ""
      return
    }

    categoryNames.forEach((name) => {
      const count = categories ? categories[name] : null
      const option = document.createElement("option")
      option.value = name
      option.textContent = Number.isFinite(Number(count))
        ? `${name} (${count})`
        : name
      select.appendChild(option)
    })

    if (keepValue && categoryNames.includes(keepValue)) {
      select.value = keepValue
    } else {
      select.value = categoryNames[0]
    }
  }

  async resolveCategoriesForDeSelection(selected) {
    let categories = this.normalizeCategories(selected ? selected.categories : null)
    if ((!categories || Object.keys(categories).length === 0) && selected && selected.annot_id) {
      categories = await this.fetchCategoriesForAnnot(selected.annot_id)
    }
    const categoryNames = categories
      ? Object.keys(categories).filter((name) => name !== "").sort()
      : []
    return { categories, categoryNames }
  }

  async populateComparedFromSecondDataset(compSelect, previousComp) {
    const root = this.formElement || this.element.closest("form")
    const hidden2 = root ? root.querySelector("#attrs_groups2") : null
    if (!hidden2 || !String(hidden2.value || "").trim()) {
      compSelect.innerHTML = ""
      const emptyComp = document.createElement("option")
      emptyComp.value = ""
      emptyComp.textContent = "Select a second metadata column"
      compSelect.appendChild(emptyComp)
      compSelect.value = ""
      compSelect.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    let parsed = null
    try {
      parsed = JSON.parse(hidden2.value)
    } catch (_e) {
      parsed = null
    }
    if (!parsed || typeof parsed !== "object") {
      compSelect.innerHTML = ""
      const emptyComp = document.createElement("option")
      emptyComp.value = ""
      emptyComp.textContent = "Select a second metadata column"
      compSelect.appendChild(emptyComp)
      compSelect.value = ""
      compSelect.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    if (Array.isArray(parsed) && parsed[0] && typeof parsed[0] === "object") {
      parsed = parsed[0]
    }

    const { categories, categoryNames } = await this.resolveCategoriesForDeSelection(parsed)
    this.deFillCategorySelect(
      compSelect,
      categoryNames,
      categories,
      previousComp,
      "Select a compared group"
    )
    compSelect.dispatchEvent(new Event("change", { bubbles: true }))
  }

  async updateDeGroupSelectsFromPrimaryMetadata(selectedValues) {
    if (this.attrNameValue !== "groups") {
      return
    }

    const refSelect = document.getElementById("attrs_group_ref")
    const compSelect = document.getElementById("attrs_group_comp")
    if (!refSelect || !compSelect) {
      return
    }

    const selected = selectedValues.length > 0 ? selectedValues[0] : null
    const { categories, categoryNames } = await this.resolveCategoriesForDeSelection(selected)

    const previousRef = refSelect.value
    const previousComp = compSelect.value

    if (categoryNames.length === 0) {
      refSelect.innerHTML = ""
      compSelect.innerHTML = ""
      const emptyRef = document.createElement("option")
      emptyRef.value = ""
      emptyRef.textContent = "Select a reference group"
      refSelect.appendChild(emptyRef)
      const emptyComp = document.createElement("option")
      emptyComp.value = ""
      emptyComp.textContent = "Select a compared group"
      compSelect.appendChild(emptyComp)
      refSelect.value = ""
      compSelect.value = ""
      refSelect.dispatchEvent(new Event("change", { bubbles: true }))
      compSelect.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    this.deFillCategorySelect(
      refSelect,
      categoryNames,
      categories,
      previousRef,
      "Select a reference group"
    )

    const dualSecondMetadata = this.isSecondGroupFromOtherMetadata()

    if (dualSecondMetadata) {
      this.teardownDeGroupRefSyncedCompListener()
      await this.populateComparedFromSecondDataset(compSelect, previousComp)
      refSelect.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    const refreshComparedSelect = () => {
      const selectedRef = refSelect.value
      const comparedNames = categoryNames.filter((name) => name !== selectedRef)
      this.deFillCategorySelect(
        compSelect,
        comparedNames,
        categories,
        previousComp,
        "Select a compared group"
      )
      compSelect.dispatchEvent(new Event("change", { bubbles: true }))
    }

    this.teardownDeGroupRefSyncedCompListener()
    this._boundGroupRefChangeHandler = () => {
      refreshComparedSelect()
    }
    this._deGroupRefSelect = refSelect
    refSelect.addEventListener("change", this._boundGroupRefChangeHandler)

    refreshComparedSelect()
    refSelect.dispatchEvent(new Event("change", { bubbles: true }))
  }

  async updateDeGroupCompFromSecondaryMetadata(selectedValues) {
    if (this.attrNameValue !== "groups2") {
      return
    }
    if (!this.isSecondGroupFromOtherMetadata()) {
      return
    }

    const compSelect = document.getElementById("attrs_group_comp")
    if (!compSelect) {
      return
    }

    const previousComp = compSelect.value
    await this.populateComparedFromSecondDataset(compSelect, previousComp)
  }

  refreshDeGroupDropdownsAfterSecondMetadataToggle() {
    if (this.attrNameValue !== "groups") {
      return
    }
    const selectedValues = []
    this.optionTargets.forEach((input) => {
      if (!input.checked) {
        return
      }
      try {
        selectedValues.push(JSON.parse(input.value))
      } catch (_e) {
        /* ignore */
      }
    })
    void this.updateDeGroupSelectsFromPrimaryMetadata(selectedValues)
  }

  normalizeCategories(rawCategories) {
    if (!rawCategories) {
      return null
    }
    if (Array.isArray(rawCategories)) {
      // Supports payloads like [{name, count, indices}, ...]
      const map = {}
      rawCategories.forEach((entry) => {
        if (!entry || typeof entry !== "object") return
        const name = entry.name == null ? "" : String(entry.name)
        if (name === "") return
        const count = Number(entry.count)
        map[name] = Number.isFinite(count) ? count : 0
      })
      return map
    }
    if (typeof rawCategories === "object") {
      return rawCategories
    }
    return null
  }

  async fetchCategoriesForAnnot(annotId) {
    try {
      const response = await fetch(`/annots/${annotId}/categories.json`, {
        method: "GET",
        headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" },
        credentials: "same-origin"
      })
      if (!response.ok) {
        return null
      }
      const payload = await response.json()
      return this.normalizeCategories(payload.categories)
    } catch (_error) {
      return null
    }
  }
}
