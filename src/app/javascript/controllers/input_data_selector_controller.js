import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "dropdownButton",
    "dropdownMenu",
    "dropdownText",
    "selectedDiv",
    "hiddenField",
    "validationDiv",
    "option"
  ]

  static values = {
    attrName: String,
    isArray: Boolean,
    minItems: { type: Number, default: 0 },
    maxItems: { type: Number, default: null },
    isMultiple: Boolean
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
    
    this.validateSelection()
  }

  disconnect() {
    if (this.boundCloseDropdown) {
      document.removeEventListener('click', this.boundCloseDropdown, true)
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
      // Position relative to button
      this.dropdownMenuTarget.style.width = this.dropdownButtonTarget.offsetWidth + 'px'
      this.dropdownMenuTarget.style.display = 'block'
      this.dropdownMenuTarget.style.position = 'absolute'
      this.dropdownMenuTarget.style.zIndex = '9999'
      this.dropdownMenuTarget.style.top = '100%'
      this.dropdownMenuTarget.style.left = '0'
      this.dropdownMenuTarget.style.marginTop = '4px'
      console.log("[InputDataSelectorController] Dropdown opened, visible:", this.dropdownMenuTarget.offsetHeight > 0)
    } else {
      this.dropdownMenuTarget.classList.add('hidden')
      this.dropdownMenuTarget.style.display = 'none'
    }
  }

  closeDropdown(event) {
    // Close if clicking outside
    if (!this.dropdownMenuTarget.contains(event.target) && !this.dropdownButtonTarget.contains(event.target)) {
      this.dropdownMenuTarget.classList.add('hidden')
      this.dropdownMenuTarget.style.display = 'none'
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
    
    // Update display
    if (selectedValues.length > 0) {
      this.dropdownTextTarget.textContent = selectedValues.length + ' item' + (selectedValues.length > 1 ? 's' : '') + ' selected'
      this.dropdownTextTarget.classList.remove('text-gray-500')
      this.dropdownTextTarget.classList.add('text-gray-900', 'font-medium')
      
      // Show selected items
      this.selectedDivTarget.innerHTML = ''
      this.selectedDivTarget.classList.remove('hidden')
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
    } else {
      this.dropdownTextTarget.textContent = '-- Select ' + (this.attrNameValue.replace(/_/g, ' ').replace(/\b\w/g, (l) => l.toUpperCase())) + ' --'
      this.dropdownTextTarget.classList.remove('text-gray-900', 'font-medium')
      this.dropdownTextTarget.classList.add('text-gray-500')
      this.selectedDivTarget.classList.add('hidden')
      this.selectedDivTarget.innerHTML = ''
    }
    
    // Validate
    this.validateSelection()
  }

  validateSelection() {
    const selectedCount = this.optionTargets.filter((input) => input.checked).length
    let errorMsg = ''
    
    if (this.minItemsValue > 0 && selectedCount < this.minItemsValue) {
      errorMsg = 'Please select at least ' + this.minItemsValue + ' item' + (this.minItemsValue > 1 ? 's' : '')
      this.validationDivTarget.className = 'mt-1 text-xs text-red-600'
    } else if (this.maxItemsValue && selectedCount > this.maxItemsValue) {
      errorMsg = 'Please select at most ' + this.maxItemsValue + ' item' + (this.maxItemsValue > 1 ? 's' : '')
      this.validationDivTarget.className = 'mt-1 text-xs text-red-600'
    } else {
      this.validationDivTarget.className = 'mt-1 text-xs text-green-600'
      errorMsg = selectedCount + ' item' + (selectedCount !== 1 ? 's' : '') + ' selected'
    }
    
    this.validationDivTarget.textContent = errorMsg
  }
}
