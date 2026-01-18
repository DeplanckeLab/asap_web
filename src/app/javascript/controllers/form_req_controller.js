import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "submitButton",
    "methodSelect",
    "methodDesc",
    "methodPred",
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
    stepResultsUrl: String,
    unavailableMethods: { type: Object, default: {} },
    methods: { type: Object, default: {} }
  }

  connect() {
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
      })
    } else {
      console.warn("[FormReqController] Method select target not found")
    }
    
    // Verify submit button exists
    if (this.hasSubmitButtonTarget) {
      console.log("[FormReqController] Submit button found:", this.submitButtonTarget)
      console.log("[FormReqController] Submit button ID:", this.submitButtonTarget.id)
    } else {
      console.error("[FormReqController] Submit button target NOT found!")
    }
  }

  disconnect() {
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
        this.submitButtonTarget.disabled = isUnavailable || false
      }

      // Update method description
      if (this.hasMethodDescTarget) {
        this.methodDescTarget.textContent = (description || '') + ' ' + (link || '')
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
      }
    } else {
      if (this.hasAttrsContainerTarget) {
        this.attrsContainerTarget.innerHTML = ''
      }
    }
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
      } else {
        this.attrsContainerTarget.innerHTML = '<p class="text-gray-500 text-sm">No attributes available for this method.</p>'
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
    
    // Handle attribute field changes for validation or other updates
    const attrInputs = this.attrsContainerTarget.querySelectorAll('input, select, textarea')
    attrInputs.forEach(input => {
      input.addEventListener('change', () => {
        console.log('[FormReqController] Attribute changed:', input.name || input.id)
      })
    })
  }

  submit(event) {
    event.preventDefault()
    event.stopPropagation()

    console.log("[FormReqController] Submit button clicked")

    if (!this.hasSubmitButtonTarget) {
      console.error("[FormReqController] Submit button target not found")
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

      // Handle errors if any
      let otherParams = ''
      if (data.errors) {
        otherParams += '&errors=' + encodeURIComponent(data.errors)
        console.warn("[FormReqController] Errors in response:", data.errors)
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
          stepSelectorController.loadStepResults(this.stepIdValue, stepElement, false)
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

