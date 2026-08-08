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
    dropdownPlaceholder: { type: String, default: "" },
    selectedLoomFile: { type: String, default: "" }
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
    this.selectRecommendedOptionOnInitialLoad()
    this.updateRecommendationBadges()
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
    const selectedRecommendedFlags = []
    
    this.optionTargets.forEach((input) => {
      if (input.checked) {
        try {
          const dataValue = JSON.parse(input.value)
          selectedValues.push(dataValue)
          const label = input.closest('label')
          if (label) {
            const stepRunInfo = label.querySelector('.font-medium')
            if (stepRunInfo) {
              selectedLabels.push(this.extractOptionDisplayLabel(stepRunInfo))
              selectedRecommendedFlags.push(this.optionHasRecommendationBadge(stepRunInfo))
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

    void this.updateDependentCategorySelect(selectedValues)
    void this.updateDeGroupSelectsFromPrimaryMetadata(selectedValues)
    void this.updateDeGroupCompFromSecondaryMetadata(selectedValues)
    this.syncInputMatrixToSelectedGroupsLoom(selectedValues)
    this.syncInputMatrixCountFlags(selectedValues)
    this.broadcastMatrixContextIfNeeded(selectedValues)
    
    // Update display
    if (selectedValues.length > 0) {
      const showSelectedValueInField = this.singleSelectionRequired() && selectedValues.length === 1
      if (showSelectedValueInField) {
        this.renderSelectedValueInDropdown(selectedLabels[0] || '1 item selected', selectedRecommendedFlags[0] === true)
      } else {
        this.dropdownTextTarget.textContent = selectedValues.length + ' item' + (selectedValues.length > 1 ? 's' : '') + ' selected'
        this.dropdownTextTarget.classList.remove('text-gray-500')
        this.dropdownTextTarget.classList.add('text-gray-900', 'font-medium')
      }
      
      // Build selected items tags
      this.selectedDivTarget.innerHTML = ''
      if (showSelectedValueInField) {
        this.selectedDivTarget.classList.add('hidden')
      } else {
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
      }
    } else {
      this.applyEmptyDropdownLabel()
      this.selectedDivTarget.classList.add('hidden')
      this.selectedDivTarget.innerHTML = ''
    }
    
    // Validate and trigger form validation
    this.validateSelection()
  }

  renderSelectedValueInDropdown(labelText, isRecommended) {
    if (!this.hasDropdownTextTarget) {
      return
    }
    this.dropdownTextTarget.innerHTML = ""
    this.dropdownTextTarget.classList.remove('text-gray-500')
    this.dropdownTextTarget.classList.add('text-gray-900', 'font-medium')

    if (isRecommended) {
      const badge = document.createElement("span")
      badge.className = "inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-medium text-emerald-800 mr-2 align-middle"
      badge.textContent = "Recommended"
      this.dropdownTextTarget.appendChild(badge)
    }

    const labelSpan = document.createElement("span")
    labelSpan.textContent = labelText
    this.dropdownTextTarget.appendChild(labelSpan)
  }

  optionHasRecommendationBadge(stepRunInfo) {
    if (!stepRunInfo) {
      return false
    }
    return !!stepRunInfo.querySelector('[data-recommendation-badge="1"]')
  }

  extractOptionDisplayLabel(stepRunInfo) {
    if (!stepRunInfo) {
      return ''
    }
    const cloned = stepRunInfo.cloneNode(true)
    const badge = cloned.querySelector('[data-recommendation-badge="1"]')
    if (badge) {
      badge.remove()
    }
    return cloned.textContent ? cloned.textContent.trim() : ''
  }

  syncInputMatrixToSelectedGroupsLoom(selectedValues) {
    if (this.attrNameValue !== "groups" && this.attrNameValue !== "groups2") {
      return
    }
    if (!selectedValues || selectedValues.length === 0) {
      return
    }

    const selectedGroup = selectedValues[0]
    const groupLoom = selectedGroup && selectedGroup.output_filename ? String(selectedGroup.output_filename) : ""
    if (!groupLoom) {
      return
    }

    const matrixController = this.getInputMatrixController()
    if (!matrixController) {
      return
    }

    const currentMatrix = matrixController.getFirstCheckedOptionValue()
    const currentMatrixLoom = currentMatrix && currentMatrix.output_filename ? String(currentMatrix.output_filename) : ""
    if (currentMatrixLoom === groupLoom) {
      return
    }

    const targetInput = matrixController.findRecommendedMatrixInputForLoom(groupLoom)
    if (!targetInput) {
      return
    }

    matrixController.selectSingleOption(targetInput)
    matrixController.updateSelectedItems()
  }

  syncInputMatrixCountFlags(selectedValues) {
    if (this.attrNameValue !== "input_matrix") {
      return
    }

    const selected = selectedValues && selectedValues.length > 0 ? selectedValues[0] : null
    const isCount = this.isCountDataset(selected)
    this.setHiddenBooleanValue("attrs_input_matrix_is_count_table", isCount)
    this.setHiddenBooleanValue("attrs_input_matrix_is_count", isCount)
    this.setHiddenBooleanValue("attrs_is_count_table", isCount)
    this.setHiddenBooleanValue("attrs_is_count", isCount)
  }

  setHiddenBooleanValue(fieldId, boolValue) {
    const root = this.formElement || this.element.closest("form")
    if (!root) {
      return
    }
    const field = root.querySelector(`#${fieldId}, [name="attrs[${fieldId.replace(/^attrs_/, "")}]"]`)
    if (!field) {
      return
    }
    field.value = boolValue ? "true" : "false"
  }

  getInputMatrixController() {
    const root = this.formElement || this.element.closest("form")
    if (!root || !this.application) {
      return null
    }

    const matrixElement = root.querySelector('[data-input-data-selector-attr-name-value="input_matrix"]')
    if (!matrixElement) {
      return null
    }

    return this.application.getControllerForElementAndIdentifier(matrixElement, "input-data-selector")
  }

  getFirstCheckedOptionValue() {
    for (let i = 0; i < this.optionTargets.length; i++) {
      const input = this.optionTargets[i]
      if (!input.checked) {
        continue
      }
      const parsed = this.parseOptionValue(input)
      if (parsed) {
        return parsed
      }
    }
    return null
  }

  parseOptionValue(input) {
    if (!input || !input.value) {
      return null
    }
    try {
      return JSON.parse(input.value)
    } catch (_error) {
      return null
    }
  }

  optionDatasetName(optionValue) {
    return optionValue && optionValue.output_dataset ? String(optionValue.output_dataset) : ""
  }

  optionLoomFile(optionValue) {
    return optionValue && optionValue.output_filename ? String(optionValue.output_filename) : ""
  }

  optionArea(optionValue) {
    const rows = Number(optionValue && optionValue.nber_rows)
    const cols = Number(optionValue && optionValue.nber_cols)
    if (!Number.isFinite(rows) || !Number.isFinite(cols)) {
      return 0
    }
    return rows * cols
  }

  isCountDataset(optionValue) {
    if (!optionValue || typeof optionValue !== "object") {
      return false
    }
    if (typeof optionValue.is_count === "boolean") {
      return optionValue.is_count
    }
    return false
  }

  isMatrixDataset(optionValue) {
    return this.optionDatasetName(optionValue) === "/matrix"
  }

  isLayerDataset(optionValue) {
    return this.optionDatasetName(optionValue).startsWith("/layers/")
  }

  isAsapNormalizedDataset(optionValue) {
    if (!optionValue || typeof optionValue !== "object") {
      return false
    }
    if (this.isCountDataset(optionValue)) {
      return false
    }
    if (!this.isLayerDataset(optionValue)) {
      return false
    }
    return optionValue.from_asap_pipeline === true
  }

  matrixOptionScore(optionValue) {
    if (!optionValue || typeof optionValue !== "object") {
      return 0
    }

    const attrName = optionValue.output_attr_name ? String(optionValue.output_attr_name) : ""
    if (attrName === "/matrix") {
      return 3
    }
    if (attrName === "matrix" || attrName === "output_matrix") {
      return 2
    }
    return 1
  }

  selectTopByArea(inputs) {
    if (!inputs || inputs.length === 0) {
      return null
    }
    let best = inputs[0]
    let bestArea = this.optionArea(this.parseOptionValue(best))
    for (let i = 1; i < inputs.length; i++) {
      const candidate = inputs[i]
      const area = this.optionArea(this.parseOptionValue(candidate))
      if (area > bestArea) {
        best = candidate
        bestArea = area
      }
    }
    return best
  }

  optionStepRank(optionValue) {
    const rank = Number(optionValue && optionValue.step_rank)
    return Number.isFinite(rank) ? rank : -1
  }

  // Prefer the matrix from the latest pipeline step (highest Step#rank), not DOM/name order.
  selectBestByReverseStepRank(inputs) {
    if (!inputs || inputs.length === 0) {
      return null
    }
    if (inputs.length === 1) {
      return inputs[0]
    }
    let best = inputs[0]
    let bestRank = this.optionStepRank(this.parseOptionValue(best))
    for (let i = 1; i < inputs.length; i++) {
      const candidate = inputs[i]
      const rank = this.optionStepRank(this.parseOptionValue(candidate))
      if (rank > bestRank) {
        best = candidate
        bestRank = rank
      } else if (rank === bestRank) {
        const bestArea = this.optionArea(this.parseOptionValue(best))
        const candidateArea = this.optionArea(this.parseOptionValue(candidate))
        if (candidateArea > bestArea) {
          best = candidate
        }
      }
    }
    return best
  }

  isLoomFilterActive() {
    return String(this.selectedLoomFileValue || "").trim().length > 0
  }

  isParsingLoomFile(loomFile) {
    const source = String(loomFile || "").trim().toLowerCase()
    if (!source) {
      return false
    }
    return /(^|\/)parsing(\/|$)/.test(source)
  }

  // When analysis has no loom filter, prefer the main parsing/output.loom over other files.
  loomFilesForRecommendation(loomKeys) {
    const keys = Array.isArray(loomKeys) ? loomKeys.slice() : []
    if (this.isLoomFilterActive() || keys.length <= 1) {
      return keys
    }
    const parsing = []
    const other = []
    keys.forEach((loomFile) => {
      if (this.isParsingLoomFile(loomFile)) {
        parsing.push(loomFile)
      } else {
        other.push(loomFile)
      }
    })
    return parsing.concat(other)
  }

  findRecommendedMatrixInputForLoom(loomFile) {
    const candidates = this.optionTargets.filter((input) => {
      const optionValue = this.parseOptionValue(input)
      return this.optionLoomFile(optionValue) === loomFile
    })
    if (candidates.length === 0) {
      return null
    }

    const p1 = candidates.filter((input) => this.isAsapNormalizedDataset(this.parseOptionValue(input)))
    if (p1.length > 0) {
      return this.selectBestByReverseStepRank(p1)
    }

    const p2 = candidates.filter((input) => {
      const value = this.parseOptionValue(input)
      return this.isMatrixDataset(value) && this.isCountDataset(value)
    })
    if (p2.length > 0) {
      return this.selectBestByReverseStepRank(p2)
    }

    const p3 = candidates.filter((input) => {
      const value = this.parseOptionValue(input)
      return this.isLayerDataset(value) && this.isCountDataset(value)
    })
    if (p3.length > 0) {
      return this.selectBestByReverseStepRank(p3)
    }

    const p4 = candidates.filter((input) => {
      const value = this.parseOptionValue(input)
      return this.isMatrixDataset(value) && !this.isCountDataset(value)
    })
    if (p4.length > 0) {
      return this.selectBestByReverseStepRank(p4)
    }

    const p5 = candidates.filter((input) => this.isLayerDataset(this.parseOptionValue(input)))
    if (p5.length > 0) {
      return this.selectBestByReverseStepRank(p5)
    }

    return this.selectBestByReverseStepRank(candidates)
  }

  clearRecommendationBadge(input) {
    const label = input ? input.closest("label") : null
    if (!label) {
      return
    }
    const title = label.querySelector(".font-medium")
    if (!title) {
      return
    }
    const badge = title.querySelector('[data-recommendation-badge="1"]')
    if (badge) {
      badge.remove()
    }
  }

  addRecommendationBadge(input) {
    const label = input ? input.closest("label") : null
    if (!label) {
      return
    }
    const title = label.querySelector(".font-medium")
    if (!title) {
      return
    }
    if (title.querySelector('[data-recommendation-badge="1"]')) {
      return
    }

    const badge = document.createElement("span")
    badge.setAttribute("data-recommendation-badge", "1")
    badge.className = "inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-medium text-emerald-800 mr-2"
    badge.textContent = "Recommended"
    title.prepend(badge)
  }

  updateRecommendationBadges() {
    if (this.attrNameValue !== "input_matrix") {
      return
    }

    this.optionTargets.forEach((input) => this.clearRecommendationBadge(input))

    const loomGroups = {}
    this.optionTargets.forEach((input) => {
      const value = this.parseOptionValue(input)
      const loomFile = this.optionLoomFile(value)
      if (!loomFile) {
        return
      }
      if (!loomGroups[loomFile]) {
        loomGroups[loomFile] = []
      }
      loomGroups[loomFile].push(input)
    })

    let loomFiles = this.loomFilesForRecommendation(Object.keys(loomGroups))
    if (!this.isLoomFilterActive() && loomFiles.length > 1) {
      const parsingOnly = loomFiles.filter((loomFile) => this.isParsingLoomFile(loomFile))
      if (parsingOnly.length > 0) {
        loomFiles = parsingOnly
      }
    }
    loomFiles.forEach((loomFile) => {
      const recommended = this.findRecommendedMatrixInputForLoom(loomFile)
      if (recommended) {
        this.addRecommendationBadge(recommended)
      }
    })
  }

  selectRecommendedOptionOnInitialLoad() {
    if (this.attrNameValue !== "input_matrix") {
      return
    }
    if (!this.hasHiddenFieldTarget) {
      return
    }
    if (String(this.hiddenFieldTarget.value || "").trim().length > 0) {
      return
    }
    if (this.optionTargets.some((input) => input.checked)) {
      return
    }

    const preferredLoom = this.detectPreferredLoomForInitialMatrixSelection()
    let recommendedInput = null
    if (preferredLoom) {
      recommendedInput = this.findRecommendedMatrixInputForLoom(preferredLoom)
    }
    if (!recommendedInput) {
      recommendedInput = this.findRecommendedMatrixInputAcrossAllLooms()
    }
    if (!recommendedInput) {
      return
    }

    this.selectSingleOption(recommendedInput)
  }

  detectPreferredLoomForInitialMatrixSelection() {
    const root = this.formElement || this.element.closest("form")
    if (!root) {
      return ""
    }

    const groupHidden = root.querySelector("#attrs_groups, [name='attrs[groups]']")
    if (!groupHidden || !String(groupHidden.value || "").trim()) {
      return ""
    }

    try {
      const parsed = JSON.parse(groupHidden.value)
      const first = Array.isArray(parsed) ? parsed[0] : parsed
      return first && first.output_filename ? String(first.output_filename) : ""
    } catch (_error) {
      return ""
    }
  }

  findRecommendedMatrixInputAcrossAllLooms() {
    const loomGroups = {}
    this.optionTargets.forEach((input) => {
      const value = this.parseOptionValue(input)
      const loomFile = this.optionLoomFile(value)
      if (!loomFile) {
        return
      }
      if (!loomGroups[loomFile]) {
        loomGroups[loomFile] = []
      }
      loomGroups[loomFile].push(input)
    })

    const loomKeys = this.loomFilesForRecommendation(Object.keys(loomGroups))
    if (loomKeys.length === 0) {
      return null
    }

    for (let i = 0; i < loomKeys.length; i++) {
      const candidate = this.findRecommendedMatrixInputForLoom(loomKeys[i])
      if (candidate) {
        return candidate
      }
    }
    return null
  }

  selectSingleOption(targetInput) {
    if (!targetInput) {
      return
    }
    this.optionTargets.forEach((input) => {
      input.checked = (input === targetInput)
    })
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

  singleSelectionRequired() {
    const maxNum = this.normalizeMaxItems()
    const onlyOneSelectable = !this.isMultipleValue || maxNum === 1
    return onlyOneSelectable && this.minItemsValue > 0
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

  async updateDependentCategorySelect(selectedValues) {
    const dependentSelect = document.getElementById(`attrs_${this.attrNameValue}_sel`)
    if (!dependentSelect) {
      return
    }

    if (dependentSelect.dataset.multiCategoryFilter === "true") {
      await this.updateMultiCategoryFilter(dependentSelect, selectedValues)
      return
    }

    const currentValue = dependentSelect.value
    const blankOption = Array.from(dependentSelect.options).find((option) => option.value === "")
    const blankLabel = blankOption ? blankOption.textContent : null

    const selected = selectedValues.length > 0 ? selectedValues[0] : null
    const { categories, categoryNames } = await this.resolveCategoriesForDeSelection(selected)

    dependentSelect.innerHTML = ""

    if (blankLabel != null) {
      const allOption = document.createElement("option")
      allOption.value = ""
      allOption.textContent = blankLabel
      dependentSelect.appendChild(allOption)
    }

    if (categoryNames.length === 0) {
      if (blankLabel == null) {
        const option = document.createElement("option")
        option.value = ""
        option.textContent = selected ? "No category available" : "Select a category"
        dependentSelect.appendChild(option)
      }
      dependentSelect.value = ""
      dependentSelect.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    categoryNames.forEach((categoryName) => {
      const count = categories ? categories[categoryName] : null
      const option = document.createElement("option")
      option.value = categoryName
      option.textContent = Number.isFinite(Number(count))
        ? `${categoryName} (${count})`
        : categoryName
      dependentSelect.appendChild(option)
    })

    if (currentValue && categoryNames.includes(currentValue)) {
      dependentSelect.value = currentValue
    } else if (blankLabel != null) {
      dependentSelect.value = ""
    } else {
      dependentSelect.value = categoryNames[0]
    }

    dependentSelect.dispatchEvent(new Event("change", { bubbles: true }))
  }

  parseMultiCategorySelectedValues(container) {
    const raw = container.dataset.selectedValues || "[]"
    try {
      const parsed = JSON.parse(raw)
      if (Array.isArray(parsed)) {
        return parsed.map((v) => String(v)).filter((v) => v !== "")
      }
    } catch (_e) {
      /* ignore */
    }
    return []
  }

  async updateMultiCategoryFilter(container, selectedValues) {
    const optionsHost = container.querySelector('[data-role="category-options"]')
    if (!optionsHost) {
      return
    }

    const previouslySelected = new Set([
      ...this.parseMultiCategorySelectedValues(container),
      ...Array.from(optionsHost.querySelectorAll('input[type="checkbox"]:checked')).map((input) => input.value)
    ])

    const selected = selectedValues.length > 0 ? selectedValues[0] : null
    const { categories, categoryNames } = await this.resolveCategoriesForDeSelection(selected)

    optionsHost.innerHTML = ""

    if (!selected) {
      const empty = document.createElement("div")
      empty.className = "px-2 py-1 text-sm text-gray-500"
      empty.textContent = "Select metadata first"
      optionsHost.appendChild(empty)
      container.dataset.selectedValues = "[]"
      container.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    if (categoryNames.length === 0) {
      const empty = document.createElement("div")
      empty.className = "px-2 py-1 text-sm text-gray-500"
      empty.textContent = "No category available"
      optionsHost.appendChild(empty)
      container.dataset.selectedValues = "[]"
      container.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    const attrName = `${this.attrNameValue}_sel`
    const syncSelected = () => {
      const values = Array.from(optionsHost.querySelectorAll('input[type="checkbox"]:checked'))
        .map((input) => input.value)
        .filter((v) => v !== "")
      container.dataset.selectedValues = JSON.stringify(values)
      container.dispatchEvent(new Event("change", { bubbles: true }))
    }

    categoryNames.forEach((categoryName) => {
      const count = categories ? categories[categoryName] : null
      const label = document.createElement("label")
      label.className = "flex items-center gap-2 px-2 py-1 rounded hover:bg-gray-50 cursor-pointer text-sm text-gray-800"

      const checkbox = document.createElement("input")
      checkbox.type = "checkbox"
      checkbox.name = `attrs[${attrName}][]`
      checkbox.value = categoryName
      checkbox.className = "h-4 w-4 text-blue-600 border-gray-300 rounded"
      checkbox.checked = previouslySelected.has(categoryName)
      checkbox.addEventListener("change", syncSelected)

      const text = document.createElement("span")
      text.textContent = Number.isFinite(Number(count))
        ? `${categoryName} (${count})`
        : categoryName

      label.appendChild(checkbox)
      label.appendChild(text)
      optionsHost.appendChild(label)
    })

    syncSelected()
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
