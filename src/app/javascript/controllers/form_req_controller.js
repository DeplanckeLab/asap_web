import { Controller } from "@hotwired/stimulus"
import {
  queryDeSecondMetadataCheckbox,
  queryDeSecondMetadataFormBlock,
  queryDeSecondMetadataHidden
} from "visualization/de_second_metadata_attrs"
import { resetInputDataWidgetToEmptyPlaceholder } from "lib/reset_input_data_widget_placeholder"

export default class extends Controller {
  static targets = [
    "submitButton",
    "methodSelect",
    "methodDesc",
    "methodPred",
    "predictionPrevent",
    "attrsContainer",
    "errorMessages"
  ]

  static values = {
    projectId: Number,
    projectKey: String,
    stepId: Number,
    stepName: String,
    actionButtonLabel: String,
    submitUrl: String,
    updPredUrl: String,
    stepResultsUrl: String,
    unavailableMethods: { type: Object, default: {} },
    methods: { type: Object, default: {} }
  }

  connect() {
    this._predictionPreventSubmit = false
    this._resourcePredictionTimer = null
    console.log("=== [FormReqController] CONNECTED ===")
    console.log("[FormReqController] Element:", this.element)
    console.log("[FormReqController] Step name:", this.stepNameValue)
    console.log("[FormReqController] Project ID:", this.projectIdValue, "Key:", this.projectKeyValue)
    console.log("[FormReqController] Submit URL:", this.submitUrlValue)
    console.log("[FormReqController] Has submit button target:", this.hasSubmitButtonTarget)
    console.log("[FormReqController] Has method select target:", this.hasMethodSelectTarget)
    
    // Initialize method selection
    if (this.hasMethodSelectTarget) {
      console.log("[FormReqController] Initializing method selection...")
      this.updateMethodSelectOptions()
      this.handleMethodChange()
      
      // Listen for method changes
      this.methodSelectTarget.addEventListener('change', () => {
        console.log("[FormReqController] Method selection changed")
        this.handleMethodChange()
        // Validate form after method change
        setTimeout(() => this.validateForm(), 100)
      })
    } else {
      console.warn("[FormReqController] Method select target not found")
    }
    
    // Verify submit button exists
    if (this.hasSubmitButtonTarget) {
      console.log("[FormReqController] Submit button found:", this.submitButtonTarget)
      console.log("[FormReqController] Submit button ID:", this.submitButtonTarget.id)
      // Initial validation
      setTimeout(() => this.validateForm(), 100)
    } else {
      console.error("[FormReqController] Submit button target NOT found!")
    }
  }

  isCellFilteringManagedSubmit() {
    return this.stepNameValue === 'cell_filtering' &&
      this.hasSubmitButtonTarget &&
      this.submitButtonTarget.hasAttribute('data-cell-filtering-target')
  }

  disconnect() {
    if (this._resourcePredictionTimer) {
      clearTimeout(this._resourcePredictionTimer)
      this._resourcePredictionTimer = null
    }
    console.log("[FormReqController] Disconnected")
  }

  updateMethodSelectOptions() {
    if (!this.hasMethodSelectTarget || !this.unavailableMethodsValue) {
      return
    }

    // Parse if it's a JSON string
    let unavailableMethods = this.unavailableMethodsValue
    if (typeof unavailableMethods === 'string') {
      try {
        unavailableMethods = JSON.parse(unavailableMethods)
      } catch (e) {
        console.error("[FormReqController] Error parsing unavailableMethods:", e)
        return
      }
    }

    const options = this.methodSelectTarget.querySelectorAll('option')
    options.forEach(option => {
      if (unavailableMethods && unavailableMethods[option.value]) {
        option.classList.add('unavailable_method')
      }
    })
  }

  handleMethodChange() {
    if (!this.hasMethodSelectTarget || !this.methodsValue) {
      return
    }

    // Parse if it's a JSON string
    let methods = this.methodsValue
    if (typeof methods === 'string') {
      try {
        methods = JSON.parse(methods)
      } catch (e) {
        console.error("[FormReqController] Error parsing methods:", e)
        return
      }
    }

    let unavailableMethods = this.unavailableMethodsValue
    if (typeof unavailableMethods === 'string') {
      try {
        unavailableMethods = JSON.parse(unavailableMethods)
      } catch (e) {
        unavailableMethods = {}
      }
    }

    const selectedMethodId = this.methodSelectTarget.value
    const method = methods[selectedMethodId]

    if (method) {
      const [speedId, description, link] = method
      const isUnavailable = unavailableMethods && unavailableMethods[selectedMethodId]

      // Update button state
      if (this.hasSubmitButtonTarget) {
        if (!this.isCellFilteringManagedSubmit()) {
          this.submitButtonTarget.disabled = isUnavailable || false
        }
      }

      // Update method description
      if (this.hasMethodDescTarget) {
        this.methodDescTarget.innerHTML = (description || '') + ' ' + (link || '')
      }

      // Show/hide speed image
      if (speedId) {
        const speedImage = document.getElementById(`speed_${speedId}`)
        if (speedImage) {
          speedImage.classList.remove('hidden')
        }
      }

      // Hide other speed images
      document.querySelectorAll('.speed_image').forEach(img => {
        if (img.id !== `speed_${speedId}`) {
          img.classList.add('hidden')
        }
      })

      // Load attributes when method is selected
      if (this.hasAttrsContainerTarget && selectedMethodId) {
        this.loadAttributes(selectedMethodId)
      } else if (this.hasAttrsContainerTarget) {
        this.attrsContainerTarget.innerHTML = '<p class="text-gray-500 text-sm">Select a method to configure parameters...</p>'
        this.validateForm()
      }
    } else {
      if (this.hasAttrsContainerTarget) {
        this.attrsContainerTarget.innerHTML = ''
      }
    }
  }

  getStdMethodId() {
    if (this.hasMethodSelectTarget && this.methodSelectTarget.value) {
      return this.methodSelectTarget.value
    }
    const hidden = this.element.querySelector('input[name="req[std_method_id]"], #req_std_method_id')
    return hidden ? hidden.value : ''
  }

  collectAnnotIdsForPrediction() {
    const ids = new Set()
    if (!this.hasAttrsContainerTarget) {
      return []
    }
    const hiddenFields = this.attrsContainerTarget.querySelectorAll('[data-input-data-selector-target="hiddenField"]')
    hiddenFields.forEach((field) => {
      const raw = (field.value || '').trim()
      if (!raw) {
        return
      }
      try {
        const parsed = JSON.parse(raw)
        const list = Array.isArray(parsed) ? parsed : [parsed]
        list.forEach((item) => {
          if (item && item.annot_id != null && item.annot_id !== '') {
            ids.add(String(item.annot_id))
          }
        })
      } catch (_e) {
        // ignore invalid JSON
      }
    })
    return Array.from(ids)
  }

  scheduleResourcePrediction() {
    if (!this.hasMethodPredTarget) {
      return
    }
    if (this._resourcePredictionTimer) {
      clearTimeout(this._resourcePredictionTimer)
    }
    this._resourcePredictionTimer = setTimeout(() => {
      this._resourcePredictionTimer = null
      this.refreshResourcePrediction()
    }, 400)
  }

  clearResourcePrediction() {
    this._predictionPreventSubmit = false
    if (this.hasMethodPredTarget) {
      this.methodPredTarget.innerHTML = ''
    }
    if (this.hasPredictionPreventTarget) {
      this.predictionPreventTarget.textContent = ''
      this.predictionPreventTarget.classList.add('hidden')
    }
    const dur = document.getElementById('pred_process_duration')
    const ram = document.getElementById('pred_max_ram')
    if (dur) {
      dur.value = ''
    }
    if (ram) {
      ram.value = ''
    }
  }

  escapeHtml(text) {
    if (text == null) {
      return ''
    }
    const div = document.createElement('div')
    div.textContent = String(text)
    return div.innerHTML
  }

  badgeClassForSeverity(severity) {
    if (severity === 'danger') {
      return 'bg-red-50 text-red-900 border-red-200'
    }
    if (severity === 'warning') {
      return 'bg-amber-50 text-amber-900 border-amber-200'
    }
    return 'bg-gray-100 text-gray-800 border-gray-200'
  }

  applyResourcePredictionPayload(data) {
    if (!this.hasMethodPredTarget) {
      return
    }

    const dur = document.getElementById('pred_process_duration')
    const ram = document.getElementById('pred_max_ram')
    if (dur) {
      dur.value = data.predicted_time != null ? String(data.predicted_time) : ''
    }
    if (ram) {
      ram.value = data.predicted_ram != null ? String(data.predicted_ram) : ''
    }

    if (data.error) {
      this.methodPredTarget.innerHTML = `<span class="text-red-600">${this.escapeHtml(data.error)}</span>`
      this._predictionPreventSubmit = false
      if (this.hasPredictionPreventTarget) {
        this.predictionPreventTarget.classList.add('hidden')
      }
      this.validateForm()
      return
    }

    const timeDisp = data.time_display || ''
    const ramDisp = data.ram_display || ''
    if (!timeDisp && !ramDisp) {
      this.methodPredTarget.innerHTML = ''
      this._predictionPreventSubmit = false
      if (this.hasPredictionPreventTarget) {
        this.predictionPreventTarget.classList.add('hidden')
      }
      this.validateForm()
      return
    }

    const tCls = this.badgeClassForSeverity(data.time_severity || 'none')
    const rCls = this.badgeClassForSeverity(data.ram_severity || 'none')
    const tTitle = this.escapeHtml(data.time_title || '')
    const rTitle = this.escapeHtml(data.ram_title || '')

    const timeBadge = timeDisp
      ? `<span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border mr-1 mb-1 ${tCls}" title="${tTitle}">Time: ${this.escapeHtml(timeDisp)}</span>`
      : ''
    const ramBadge = ramDisp
      ? `<span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border mb-1 ${rCls}" title="${rTitle}">RAM: ${this.escapeHtml(ramDisp)}</span>`
      : ''

    this.methodPredTarget.innerHTML =
      `<span class="font-medium text-gray-700">Resource prediction:</span> ${timeBadge}${ramBadge}`

    this._predictionPreventSubmit = !!data.prevent_submit
    if (this.hasPredictionPreventTarget) {
      if (data.prevent_submit && Array.isArray(data.prevent_messages) && data.prevent_messages.length > 0) {
        const lines = data.prevent_messages.map((m) => this.escapeHtml(m)).join('<br/>')
        this.predictionPreventTarget.innerHTML =
          `${lines}<br/><span class="font-semibold">Try a smaller input or a more scalable method.</span>`
        this.predictionPreventTarget.classList.remove('hidden')
      } else {
        this.predictionPreventTarget.textContent = ''
        this.predictionPreventTarget.classList.add('hidden')
      }
    }

    this.validateForm()
  }

  refreshResourcePrediction() {
    if (!this.hasMethodPredTarget) {
      return
    }

    const methodId = this.getStdMethodId()
    if (!methodId) {
      this.clearResourcePrediction()
      this.validateForm()
      return
    }

    const annotIds = this.collectAnnotIdsForPrediction()
    if (annotIds.length === 0) {
      this.clearResourcePrediction()
      this.validateForm()
      return
    }

    const url =
      this.updPredUrlValue && String(this.updPredUrlValue).length > 0
        ? this.updPredUrlValue
        : `/projects/${this.projectKeyValue}/upd_pred`

    this.methodPredTarget.innerHTML =
      '<span class="text-gray-500">Predicting required resources</span>'

    const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''

    fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        'X-CSRF-Token': token
      },
      credentials: 'same-origin',
      body: JSON.stringify({
        annot_ids: annotIds.join(','),
        std_method_id: methodId
      })
    })
      .then((response) => {
        if (!response.ok) {
          return response.text().then((text) => {
            let msg = text || `HTTP ${response.status}`
            try {
              const body = JSON.parse(text)
              if (body.error) {
                msg = body.error
              }
            } catch (_e) {
              // keep msg as text
            }
            throw new Error(msg)
          })
        }
        return response.json()
      })
      .then((data) => this.applyResourcePredictionPayload(data))
      .catch((err) => {
        console.warn('[FormReqController] Resource prediction failed:', err)
        this.applyResourcePredictionPayload({ error: err.message || 'Prediction failed' })
      })
  }

  loadAttributes(stdMethodId) {
    if (!this.hasAttrsContainerTarget || !this.projectKeyValue || !this.stepIdValue) {
      return
    }
    
    const stepId = this.stepIdValue
    const projectKey = this.projectKeyValue
    
    // Show loading state
    this.attrsContainerTarget.innerHTML = '<div class="flex items-center justify-center p-4"><i class="fa fa-spinner fa-pulse mr-2"></i>Loading attributes...</div>'
    
    // Build URL
    const url = `/projects/${projectKey}/get_attributes?step_id=${stepId}&obj_id=${stdMethodId}&format=html`
    
    // Fetch attributes
    fetch(url, {
      method: 'GET',
      headers: {
        'Accept': 'text/html',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.text()
    })
    .then(html => {
      if (html && html.trim().length > 0) {
        this.attrsContainerTarget.innerHTML = html
        // Re-initialize any event listeners that might be needed
        this.initializeAttributeListeners()
        // Validate form after attributes are loaded
        setTimeout(() => this.validateForm(), 100)
      } else {
        this.attrsContainerTarget.innerHTML = '<p class="text-gray-500 text-sm">No attributes available for this method.</p>'
        this.validateForm()
      }
    })
    .catch(error => {
      console.error('[FormReqController] Error loading attributes:', error)
      this.attrsContainerTarget.innerHTML = `<p class="text-red-600 text-sm">Error loading attributes: ${error.message}</p>`
    })
  }
  
  initializeAttributeListeners() {
    // Handle checkbox changes for attributes loaded dynamically
    const checkboxes = this.attrsContainerTarget.querySelectorAll('.std_form_checkbox')
    checkboxes.forEach(checkbox => {
      checkbox.addEventListener('change', function() {
        const attrName = this.id.replace('checkbox-', '')
        const hiddenField = document.getElementById('attrs_' + attrName)
        if (hiddenField) {
          hiddenField.value = this.checked ? 'true' : 'false'
        }
      })
    })
    
    // Handle attribute field changes for validation
    const attrInputs = this.attrsContainerTarget.querySelectorAll('input, select, textarea')
    attrInputs.forEach(input => {
      input.addEventListener('change', () => {
        console.log('[FormReqController] Attribute changed:', input.name || input.id)
        this.validateForm()
      })
      input.addEventListener('input', () => {
        this.validateForm()
      })
    })
    
    // Listen to input-data-selector validation events
    const inputDataSelectors = this.attrsContainerTarget.querySelectorAll('[data-controller*="input-data-selector"]')
    inputDataSelectors.forEach(selector => {
      // Listen for custom validation events from input-data-selector
      selector.addEventListener('validation-changed', () => {
        this.validateForm()
        this.scheduleResourcePrediction()
      })
    })
    
    // Initial validation
    this.syncDeGroupVisibility()
    this.syncSecondGroupMetadataVisibility()
    this.validateForm()
    this.scheduleResourcePrediction()
  }

  syncSecondGroupMetadataVisibility() {
    const toggle = queryDeSecondMetadataCheckbox(this.attrsContainerTarget)
    const g2Container = this.attrsContainerTarget.querySelector("#form-container_groups2")
    if (!toggle || !g2Container) {
      return
    }
    if (toggle.dataset.secondGroupBound === "1") {
      return
    }
    toggle.dataset.secondGroupBound = "1"

    const clearGroupDataset2 = () => {
      const hidden = g2Container.querySelector('[data-input-data-selector-target="hiddenField"]')
      if (hidden) {
        hidden.value = ""
      }
      g2Container.querySelectorAll('input[type="radio"], input[type="checkbox"]').forEach((inp) => {
        inp.checked = false
      })
      resetInputDataWidgetToEmptyPlaceholder(g2Container, this.application)
      const selectedDiv = g2Container.querySelector('[data-input-data-selector-target="selectedDiv"]')
      if (selectedDiv) {
        selectedDiv.innerHTML = ""
        selectedDiv.classList.add("hidden")
      }
    }

    const triggerPrimaryDeRefresh = () => {
      const sel = '[data-input-data-selector-attr-name-value="groups"]'
      const el = this.attrsContainerTarget.querySelector(sel)
      if (!el || !this.application) {
        return
      }
      const c = this.application.getControllerForElementAndIdentifier(el, "input-data-selector")
      if (c && typeof c.refreshDeGroupDropdownsAfterSecondMetadataToggle === "function") {
        c.refreshDeGroupDropdownsAfterSecondMetadataToggle()
      }
    }

    const apply = () => {
      const allAgainst = this.attrsContainerTarget.querySelector("#checkbox-all_against_compl")
      if (allAgainst && allAgainst.checked) {
        g2Container.style.display = "none"
        this.validateForm()
        return
      }
      const on = !!toggle.checked
      g2Container.style.display = on ? "" : "none"
      if (!on) {
        clearGroupDataset2()
      }
      triggerPrimaryDeRefresh()
      this.validateForm()
    }

    toggle.addEventListener("change", () => {
      const hiddenAttr = queryDeSecondMetadataHidden(this.attrsContainerTarget)
      if (hiddenAttr) {
        hiddenAttr.value = toggle.checked ? "true" : "false"
      }
      apply()
    })
    apply()
  }

  syncDeGroupVisibility() {
    const toggle = this.attrsContainerTarget.querySelector('#checkbox-all_against_compl')
    const refContainer = this.attrsContainerTarget.querySelector('#form-container_group_ref')
    const compContainer = this.attrsContainerTarget.querySelector('#form-container_group_comp')

    if (!toggle || !refContainer || !compContainer) {
      return
    }
    if (toggle.dataset.deAllAgainstBound === '1') {
      return
    }
    toggle.dataset.deAllAgainstBound = '1'

    const g2Container = this.attrsContainerTarget.querySelector('#form-container_groups2')
    const secondMetaBlock = queryDeSecondMetadataFormBlock(this.attrsContainerTarget)

    const clearSecondMetadataUi = () => {
      const st = queryDeSecondMetadataCheckbox(this.attrsContainerTarget)
      const stHidden = queryDeSecondMetadataHidden(this.attrsContainerTarget)
      if (st) {
        st.checked = false
      }
      if (stHidden) {
        stHidden.value = 'false'
      }
      if (!g2Container) {
        return
      }
      const hidden = g2Container.querySelector('[data-input-data-selector-target="hiddenField"]')
      if (hidden) {
        hidden.value = ''
      }
      g2Container.querySelectorAll('input[type="radio"], input[type="checkbox"]').forEach((inp) => {
        inp.checked = false
      })
      resetInputDataWidgetToEmptyPlaceholder(g2Container, this.application)
      const selectedDiv = g2Container.querySelector('[data-input-data-selector-target="selectedDiv"]')
      if (selectedDiv) {
        selectedDiv.innerHTML = ''
        selectedDiv.classList.add('hidden')
      }
    }

    const applyVisibility = () => {
      // Checked = complementary mode: one run, no explicit ref/comp (server strips attrs); hide second-metadata UI too.
      const allAgainst = !!toggle.checked
      refContainer.style.display = allAgainst ? 'none' : ''
      compContainer.style.display = allAgainst ? 'none' : ''
      if (secondMetaBlock) {
        secondMetaBlock.style.display = allAgainst ? 'none' : ''
      }
      if (g2Container) {
        if (allAgainst) {
          g2Container.style.display = 'none'
        } else {
          const stHidden = queryDeSecondMetadataHidden(this.attrsContainerTarget)
          const secondOn = stHidden && String(stHidden.value) === 'true'
          g2Container.style.display = secondOn ? '' : 'none'
        }
      }
      if (allAgainst) {
        const gref = this.attrsContainerTarget.querySelector('#attrs_group_ref')
        const gcomp = this.attrsContainerTarget.querySelector('#attrs_group_comp')
        if (gref) {
          gref.value = ''
        }
        if (gcomp) {
          gcomp.value = ''
        }
        const gp = this.attrsContainerTarget.querySelector('#attrs_group_pairs')
        if (gp) {
          gp.value = ''
        }
        clearSecondMetadataUi()
      }
      this.validateForm()
    }

    toggle.addEventListener('change', applyVisibility)
    applyVisibility()
  }
  
  validateForm() {
    if (!this.hasSubmitButtonTarget) {
      return true
    }

    // Cell filtering submit button state is managed exclusively by cell_filtering_controller
    // to avoid transient enable/disable flicker during recomputation.
    if (this.isCellFilteringManagedSubmit()) {
      return true
    }
    
    let isValid = true
    const errors = []
    
    // Check if method is selected (if method select exists)
    if (this.hasMethodSelectTarget) {
      const methodValue = this.methodSelectTarget.value
      if (!methodValue || methodValue === '') {
        isValid = false
        errors.push('Please select a method')
      }
    }
    
    // If no attributes container, just check method selection
    if (!this.hasAttrsContainerTarget) {
      const blockedByPrediction = this._predictionPreventSubmit === true
      const submitEnabled = isValid && !blockedByPrediction
      this.submitButtonTarget.disabled = !submitEnabled
      if (submitEnabled) {
        this.submitButtonTarget.classList.remove('opacity-50', 'cursor-not-allowed')
        this.submitButtonTarget.classList.add('cursor-pointer')
      } else {
        this.submitButtonTarget.classList.add('opacity-50', 'cursor-not-allowed')
        this.submitButtonTarget.classList.remove('cursor-pointer')
      }
      return isValid && !blockedByPrediction
    }
    
    // Get all attribute containers
    const attrContainers = this.attrsContainerTarget.querySelectorAll('[data-attr-name]')
    
    attrContainers.forEach(container => {
      if (container.offsetParent === null) {
        return
      }
      const attrName = container.getAttribute('data-attr-name')
      const widget = container.getAttribute('data-attr-widget')
      const notNull = container.getAttribute('data-attr-not-null') === 'true'
      const minItems = parseInt(container.getAttribute('data-attr-min-items') || '0')
      const maxItems = container.getAttribute('data-attr-max-items')
      const minVal = container.getAttribute('data-attr-min-val')
      const maxVal = container.getAttribute('data-attr-max-val')
      
      // Skip hidden widgets
      if (widget === 'hidden') {
        return
      }
      
      let value = null
      let isEmpty = true
      
      if (widget === 'input_data') {
        // For input_data widgets, check the hidden field value
        const hiddenField = container.querySelector('[data-input-data-selector-target="hiddenField"]')
        if (hiddenField && hiddenField.value) {
          try {
            const parsed = JSON.parse(hiddenField.value)
            if (Array.isArray(parsed)) {
              value = parsed
              isEmpty = parsed.length === 0
            } else if (typeof parsed === 'object' && parsed !== null) {
              value = [parsed]
              isEmpty = false
            }
          } catch (e) {
            // Invalid JSON, treat as empty
            isEmpty = true
          }
        }
        
        // Check min/max items constraints
        if (isEmpty && minItems > 0) {
          isValid = false
          errors.push(`${attrName}: Please select at least ${minItems} item${minItems > 1 ? 's' : ''}`)
        } else if (!isEmpty && value) {
          const count = Array.isArray(value) ? value.length : 1
          if (minItems > 0 && count < minItems) {
            isValid = false
            errors.push(`${attrName}: Please select at least ${minItems} item${minItems > 1 ? 's' : ''}`)
          }
          if (maxItems && count > parseInt(maxItems)) {
            isValid = false
            errors.push(`${attrName}: Please select at most ${maxItems} item${maxItems > 1 ? 's' : ''}`)
          }
        }
      } else if (widget === 'checkbox') {
        // For checkboxes, check the hidden field
        const hiddenField = container.querySelector(`#attrs_${attrName}`)
        if (hiddenField) {
          value = hiddenField.value
          isEmpty = !value || value === 'false'
        }
      } else {
        // For other widgets (text, select), check the input/select element
        const input = container.querySelector(`#attrs_${attrName}, input[name="attrs[${attrName}]"], select[name="attrs[${attrName}]"]`)
        if (input) {
          if (input.type === 'checkbox') {
            value = input.checked ? input.value : null
            isEmpty = !input.checked
          } else {
            value = input.value
            isEmpty = !value || value.trim() === ''
          }
        }
      }
      
      // Check not_null constraint
      if (notNull && isEmpty) {
        isValid = false
        const label = container.querySelector('label')?.textContent?.trim() || attrName
        errors.push(`${label}: This field is required`)
      }
      
      // Check min_val/max_val constraints for numeric values
      if (!isEmpty && value && (minVal || maxVal)) {
        const numValue = parseFloat(value)
        if (!isNaN(numValue)) {
          if (minVal && numValue < parseFloat(minVal)) {
            isValid = false
            errors.push(`${attrName}: Value must be at least ${minVal}`)
          }
          if (maxVal && numValue > parseFloat(maxVal)) {
            isValid = false
            errors.push(`${attrName}: Value must be at most ${maxVal}`)
          }
        }
      }
    })

    const secondHidden = queryDeSecondMetadataHidden(this.attrsContainerTarget)
    const secondOn = secondHidden && String(secondHidden.value) === "true"
    const g2c = this.attrsContainerTarget.querySelector("#form-container_groups2")
    if (secondOn && g2c && g2c.offsetParent !== null) {
      const hidden2 = g2c.querySelector('[data-input-data-selector-target="hiddenField"]')
      if (!hidden2 || !String(hidden2.value || "").trim()) {
        isValid = false
        errors.push("Second metadata: select a metadata column for the compared group")
      }
    }
    
    // Update submit button state (resource prediction can block submit like legacy ASAP)
    const blockedByPrediction = this._predictionPreventSubmit === true
    const submitEnabled = isValid && !blockedByPrediction
    this.submitButtonTarget.disabled = !submitEnabled

    if (submitEnabled) {
      this.submitButtonTarget.classList.remove('opacity-50', 'cursor-not-allowed')
      this.submitButtonTarget.classList.add('cursor-pointer')
    } else {
      this.submitButtonTarget.classList.add('opacity-50', 'cursor-not-allowed')
      this.submitButtonTarget.classList.remove('cursor-pointer')
    }
    
    // Log validation result
    if (!isValid || blockedByPrediction) {
      console.log('[FormReqController] Validation failed:', errors)
    } else {
      console.log('[FormReqController] Form is valid')
    }

    return isValid && !blockedByPrediction
  }

  submit(event) {
    event.preventDefault()
    event.stopPropagation()

    console.log("[FormReqController] Submit button clicked")

    if (!this.hasSubmitButtonTarget) {
      console.error("[FormReqController] Submit button target not found")
      return
    }
    
    // Validate form before submission
    if (!this.validateForm()) {
      console.warn("[FormReqController] Form validation failed, preventing submission")
      return
    }

    // The form element is this.element since the controller is attached to the form
    const formElement = this.element

    // Disable button and show spinner
    this.submitButtonTarget.disabled = true
    const originalText = this.submitButtonTarget.innerHTML
    this.submitButtonTarget.innerHTML = `<i class='fa fa-pulse fa-spinner'></i> ${this.actionButtonLabelValue || 'Submit'}`

    // Serialize form data
    // Rails form_for generates nested names like req[std_method_id]
    const formData = new FormData(formElement)
    const reqData = {}
    const attrs = {}
    
    // Parse FormData - Rails uses nested names like req[std_method_id]
    for (const [key, value] of formData.entries()) {
      console.log("[FormReqController] Form field:", key, "=", value)
      
      // Parse req[field_name] format
      const reqMatch = key.match(/^req\[(.*?)\]$/)
      if (reqMatch) {
        const fieldName = reqMatch[1]
        reqData[fieldName] = value
      }
      // Parse attrs[attr_name] format for attributes
      else if (key.startsWith('attrs[')) {
        const attrMatch = key.match(/^attrs\[(.*?)\]$/)
        if (attrMatch) {
          const attrName = attrMatch[1]
          attrs[attrName] = value
        }
      }
    }

    // Also check directly from form elements (in case FormData doesn't capture all)
    // Try multiple selector patterns to find the fields
    const methodSelect = formElement.querySelector('[name="req[std_method_id]"], select[name*="std_method_id"], #req_std_method_id')
    if (methodSelect) {
      reqData.std_method_id = methodSelect.value
      console.log("[FormReqController] Found std_method_id from element:", methodSelect.name, "=", reqData.std_method_id)
    } else {
      console.warn("[FormReqController] std_method_id field not found!")
      // Log all form inputs for debugging
      const allInputs = formElement.querySelectorAll('input, select, textarea')
      console.log("[FormReqController] All form fields:", Array.from(allInputs).map(el => ({ name: el.name, id: el.id, value: el.value })))
    }

    const stepIdInput = formElement.querySelector('[name="req[step_id]"], input[name*="step_id"], #req_step_id')
    if (stepIdInput) {
      reqData.step_id = stepIdInput.value
      console.log("[FormReqController] Found step_id from element:", stepIdInput.name, "=", reqData.step_id)
    } else {
      console.warn("[FormReqController] step_id field not found!")
    }
    
    // Ensure we have required values
    if (!reqData.std_method_id && this.hasMethodSelectTarget) {
      reqData.std_method_id = this.methodSelectTarget.value
      console.log("[FormReqController] Using std_method_id from target:", reqData.std_method_id)
    }
    
    if (!reqData.step_id) {
      reqData.step_id = this.stepIdValue
      console.log("[FormReqController] Using step_id from controller value:", reqData.step_id)
    }

    // Collect attributes from attrs_container if any
    if (this.hasAttrsContainerTarget) {
      const attrInputs = this.attrsContainerTarget.querySelectorAll('input, select, textarea')
      attrInputs.forEach(input => {
        const name = input.name || input.id
        if (name && name.startsWith('attrs[')) {
          const attrMatch = name.match(/attrs\[(.*?)\]/)
          if (attrMatch) {
            const attrName = attrMatch[1]
            if (input.type === 'checkbox') {
              attrs[attrName] = input.checked ? input.value : null
            } else if (input.type === 'radio') {
              if (input.checked) {
                attrs[attrName] = input.value
              }
            } else {
              attrs[attrName] = input.value || ''
            }
          }
        }
      })
    }

    // Add project info
    const projectId = this.projectIdValue
    const projectKey = this.projectKeyValue

    console.log("[FormReqController] Req data:", reqData)
    console.log("[FormReqController] Attributes collected:", attrs)
    console.log("[FormReqController] Project ID:", projectId, "Key:", projectKey)
    console.log("[FormReqController] Submit URL:", this.submitUrlValue)

    // Find content container (used by step_selector_controller)
    const stepContainer = document.querySelector('[data-step-selector-target="content"]')
    
    // Show loading in container if available
    if (stepContainer) {
      const originalContent = stepContainer.innerHTML
      stepContainer.innerHTML = '<div class="loading"><i class="fa fa-spinner fa-pulse fa-fw fa-lg fa-2x"></i></div>'
    }

    // Submit via fetch
    // Rails expects params[:req] and params[:attrs]
    const requestBody = {
      req: {
        step_id: reqData.step_id,
        std_method_id: reqData.std_method_id
      },
      project_id: projectId,
      project_key: projectKey
    }
    
    // Only add attrs if there are any attributes
    if (Object.keys(attrs).length > 0) {
      requestBody.attrs = attrs
    }

    console.log("[FormReqController] Final request body:", JSON.stringify(requestBody, null, 2))

    // Add project_key as query parameter (required by set_project before_action)
    const submitUrl = new URL(this.submitUrlValue, window.location.origin)
    if (projectKey) {
      submitUrl.searchParams.set('project_key', projectKey)
    }

    fetch(submitUrl.toString(), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '',
        'Accept': 'application/json'
      },
      body: JSON.stringify(requestBody)
    })
    .then(response => {
      console.log("[FormReqController] Response status:", response.status)
      if (!response.ok) {
        return response.text().then(text => {
          throw new Error(`HTTP ${response.status}: ${text}`)
        })
      }
      return response.json()
    })
    .then(data => {
      console.log("[FormReqController] Success response:", data)
      
      // Re-enable button
      this.submitButtonTarget.disabled = false
      this.submitButtonTarget.innerHTML = originalText

      // Close slide-in form panel if it exists
      const slideInFormElement = this.element.closest('[data-controller*="slide-in-form"]')
      if (slideInFormElement && window.Stimulus) {
        const slideInFormController = window.Stimulus.getControllerForElementAndIdentifier(slideInFormElement, 'slide-in-form')
        if (slideInFormController && typeof slideInFormController.close === 'function') {
          console.log("[FormReqController] Closing slide-in form panel")
          slideInFormController.close()
        }
      }

      // Surface server notices (duplicate runs, etc.) in the step panel via step_results params
      let otherParams = ''
      const panelMessage = data.notice || data.errors
      if (panelMessage) {
        otherParams += '&notice=' + encodeURIComponent(panelMessage)
        if (data.errors && data.errors !== data.notice) {
          console.warn("[FormReqController] Response errors:", data.errors)
        }
      }

      // Refresh step results
      this.refreshStepResults(otherParams)
    })
    .catch(error => {
      console.error("[FormReqController] Error submitting form:", error)
      
      // Re-enable button
      this.submitButtonTarget.disabled = false
      this.submitButtonTarget.innerHTML = originalText

      // Show error message
      let errorMsg = "Error submitting form: "
      try {
        const errorData = JSON.parse(error.message)
        if (errorData.error) {
          errorMsg += errorData.error
        } else if (errorData.errors) {
          errorMsg += errorData.errors
        } else {
          errorMsg += error.message
        }
      } catch {
        errorMsg += error.message || "Unknown error"
      }

      alert(errorMsg)
    })
  }

  refreshStepResults(otherParams = '') {
    const stepResultsUrl = `${this.stepResultsUrlValue}?step_id=${this.stepIdValue}${otherParams}`
    console.log("[FormReqController] Refreshing step results:", stepResultsUrl)

    // Try to use step_selector_controller's loadStepResults if available
    const stepSelectorElement = document.querySelector('[data-controller*="step-selector"]')
    if (stepSelectorElement && window.Stimulus) {
      const stepSelectorController = window.Stimulus.getControllerForElementAndIdentifier(stepSelectorElement, 'step-selector')
      if (stepSelectorController && typeof stepSelectorController.loadStepResults === 'function') {
        console.log("[FormReqController] Using step-selector controller to refresh")
        const stepElement = stepSelectorElement.querySelector(`[data-step-id="${this.stepIdValue}"]`)
        if (stepElement) {
          stepSelectorController.loadStepResults(this.stepIdValue, stepElement, false, otherParams)
          return
        }
      }
    }

    // Fallback: use window.location
    console.log("[FormReqController] Using window.location fallback")
    window.location.href = stepResultsUrl
  }

  cancel(event) {
    event.preventDefault()
    console.log("[FormReqController] Cancel button clicked")
    this.refreshStepResults()
  }
}

