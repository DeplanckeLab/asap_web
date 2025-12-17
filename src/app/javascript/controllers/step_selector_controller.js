import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

console.log('[StepSelectorController] File loaded')

// Check if element exists on page load
if (typeof document !== 'undefined') {
  document.addEventListener('DOMContentLoaded', function() {
    const element = document.querySelector('[data-controller*="step-selector"]')
    console.log('[StepSelectorController] DOMContentLoaded - element found:', element)
    if (element) {
      console.log('[StepSelectorController] Element HTML:', element.outerHTML.substring(0, 300))
    } else {
      console.warn('[StepSelectorController] Element not found on DOMContentLoaded!')
      // Try again after a delay
      setTimeout(function() {
        const element2 = document.querySelector('[data-controller*="step-selector"]')
        console.log('[StepSelectorController] Delayed check - element found:', element2)
      }, 1000)
    }
  })
  
  // Also check immediately if DOM is already loaded
  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    const element = document.querySelector('[data-controller*="step-selector"]')
    console.log('[StepSelectorController] Immediate check - element found:', element)
  }
}

export default class extends Controller {
  static targets = ["resultsContainer", "emptyState", "loadingState", "content"]
  static values = { projectId: Number }

  connect() {
    console.log('[StepSelectorController] CONNECT METHOD CALLED!')
    try {
      console.log('[StepSelectorController] ===== CONNECTED =====')
      console.log('[StepSelectorController] Project ID:', this.projectIdValue)
      console.log('[StepSelectorController] Element:', this.element)
      console.log('[StepSelectorController] Element HTML:', this.element.outerHTML.substring(0, 200))
      
      // Check if required targets exist
      if (!this.hasEmptyStateTarget) {
        console.warn('[StepSelectorController] emptyState target not found')
      }
      if (!this.hasLoadingStateTarget) {
        console.warn('[StepSelectorController] loadingState target not found')
      }
      if (!this.hasContentTarget) {
        console.warn('[StepSelectorController] content target not found')
      }
      if (!this.hasResultsContainerTarget) {
        console.warn('[StepSelectorController] resultsContainer target not found')
      }
    // Track currently displayed step
    this.currentStepId = null
    console.log('[StepSelectorController] Initial currentStepId set to:', this.currentStepId)
    
    // Remove any blue background from server-rendered steps (all should be white)
    // This ensures consistency with the new design
    const allSteps = this.element.querySelectorAll('[data-step-id]')
    allSteps.forEach((stepEl) => {
      stepEl.classList.remove('bg-blue-600')
      stepEl.style.backgroundColor = ''
      if (!stepEl.classList.contains('bg-white')) {
        stepEl.classList.add('bg-white')
      }
      // Remove white text
      const textElements = stepEl.querySelectorAll('strong, small, span:not(.badge)')
      textElements.forEach((el) => {
        el.classList.remove('text-white')
      })
      // Reset border
      stepEl.style.borderLeft = '4px solid transparent'
    })
    
    // Check if step_id is in URL parameters
    const urlParams = new URLSearchParams(window.location.search)
    const stepIdFromUrl = urlParams.get('step_id')
    
    // Wait for steps panel to be loaded before trying to select a step
    // The steps panel might be loaded asynchronously via refreshStepsPanel
    const controller = this
    const trySelectStep = function() {
      if (stepIdFromUrl) {
        // Select the step from URL parameter
        console.log('[StepSelectorController] Found step_id in URL:', stepIdFromUrl)
        const stepElement = controller.element.querySelector(`[data-step-id="${stepIdFromUrl}"]`)
        console.log('[StepSelectorController] Step element found:', stepElement)
        if (stepElement) {
          const stepId = stepElement.getAttribute('data-step-id')
          console.log('[StepSelectorController] Loading step results for step_id:', stepId)
          controller.currentStepId = stepId.toString()
          controller.element.setAttribute('data-current-step-id', stepId.toString())
          controller.loadStepResults(stepId, stepElement, true)
          return true
        } else {
          console.warn('[StepSelectorController] Step element not found for step_id:', stepIdFromUrl)
          console.log('[StepSelectorController] Available step elements:', Array.from(controller.element.querySelectorAll('[data-step-id]')).map(el => el.getAttribute('data-step-id')))
          return false
        }
      } else {
        console.log('[StepSelectorController] No step_id in URL, selecting first available step')
        return controller.selectFirstAvailableStep()
      }
    }
    
    // Try immediately, then retry after a short delay if steps panel isn't ready
    if (!trySelectStep()) {
      console.log('[StepSelectorController] Steps panel not ready, retrying after refresh...')
      this.refreshStepsPanel()
      setTimeout(function() {
        if (!trySelectStep()) {
          console.warn('[StepSelectorController] Still couldn\'t find step, falling back to first available')
          controller.selectFirstAvailableStep()
        }
      }, 500)
    }
    
      // Subscribe to websocket updates for this project
      this.subscribeToProject()
      console.log('[StepSelectorController] Initial setup complete, currentStepId:', this.currentStepId)
    } catch (error) {
      console.error('[StepSelectorController] Error in connect():', error)
      console.error('[StepSelectorController] Error stack:', error.stack)
    }
  }

  disconnect() {
    this.unsubscribeFromProject()
  }

  subscribeToProject() {
    if (!this.projectIdValue) {
      console.error('[StepSelectorController] No project ID provided')
      return
    }

    console.log(`[StepSelectorController] ===== SUBSCRIBING TO PROJECT =====`)
    console.log(`[StepSelectorController] Project ID: ${this.projectIdValue}`)
    console.log(`[StepSelectorController] Consumer:`, consumer)

    this.subscription = consumer.subscriptions.create(
      {
        channel: "ProjectChannel",
        project_id: this.projectIdValue
      },
      {
        connected: () => {
          console.log(`[StepSelectorController] ===== WEBSOCKET CONNECTED =====`)
          console.log(`[StepSelectorController] Connected to ProjectChannel for project ${this.projectIdValue}`)
        },
        disconnected: () => {
          console.warn(`[StepSelectorController] ===== WEBSOCKET DISCONNECTED =====`)
          console.warn(`[StepSelectorController] Disconnected from ProjectChannel for project ${this.projectIdValue}`)
        },
        rejected: () => {
          console.error(`[StepSelectorController] ===== WEBSOCKET REJECTED =====`)
          console.error(`[StepSelectorController] Subscription rejected for project ${this.projectIdValue}`)
        },
        received: (data) => {
          console.log(`[StepSelectorController] ===== WEBSOCKET MESSAGE RECEIVED =====`)
          console.log(`[StepSelectorController] Timestamp:`, new Date().toISOString())
          console.log(`[StepSelectorController] Full data object:`, JSON.stringify(data, null, 2))
          console.log(`[StepSelectorController] step_id:`, data.step_id, `(type: ${typeof data.step_id})`)
          console.log(`[StepSelectorController] parsing_status:`, data.parsing_status)
          console.log(`[StepSelectorController] h_nber_analyses:`, data.h_nber_analyses)
          console.log(`[StepSelectorController] Current step ID:`, this.currentStepId, `(type: ${typeof this.currentStepId})`)
          console.log(`[StepSelectorController] Will call handleStatusUpdate now...`)
          this.handleStatusUpdate(data)
          console.log(`[StepSelectorController] handleStatusUpdate completed`)
        }
      }
    )
    
    console.log(`[StepSelectorController] Subscription created:`, this.subscription)
  }

  unsubscribeFromProject() {
    if (this.subscription) {
      console.log(`[StepSelectorController] Unsubscribing from project ${this.projectIdValue}`)
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  handleStatusUpdate(data) {
    console.log('[StepSelectorController] ===== HANDLE STATUS UPDATE =====')
    console.log('[StepSelectorController] handleStatusUpdate called with data:', data)
    console.log('[StepSelectorController] data.step_id:', data.step_id)
    console.log('[StepSelectorController] data.parsing_status:', data.parsing_status)
    console.log('[StepSelectorController] Current step ID before update:', this.currentStepId)
    
    // Preserve currentStepId before refresh (it might get lost during DOM replacement)
    const preservedStepId = this.currentStepId || this.element.getAttribute('data-current-step-id')
    console.log('[StepSelectorController] Preserving step ID before refresh:', preservedStepId)
    
    // Always refresh the steps panel from the server to ensure consistency
    this.refreshStepsPanel()
    
    // Restore currentStepId after refresh (DOM replacement might have cleared it)
    if (preservedStepId && !this.currentStepId) {
      console.log('[StepSelectorController] Restoring currentStepId after refresh:', preservedStepId)
      this.currentStepId = preservedStepId
      this.element.setAttribute('data-current-step-id', preservedStepId)
    }
    
    // Convert step_id to number for comparison
    const updateStepId = data.step_id ? parseInt(data.step_id) : null
    const currentStepIdNum = this.currentStepId ? parseInt(this.currentStepId) : null
    
    console.log('[StepSelectorController] Update step ID:', updateStepId, 'Current step ID:', currentStepIdNum)
    console.log('[StepSelectorController] Comparison:', updateStepId, '===', currentStepIdNum, '?', updateStepId === currentStepIdNum)
    
    // If the update is for the currently displayed step, reload it from server
    if (updateStepId && currentStepIdNum && updateStepId === currentStepIdNum) {
      console.log(`[StepSelectorController] Status update for current step ${this.currentStepId}, reloading from server...`)
      const stepElement = this.element.querySelector(`[data-step-id="${this.currentStepId}"]`)
      if (stepElement) {
        // Use a small delay to avoid too frequent reloads, but reload to show latest status
        clearTimeout(this.reloadTimeout)
        this.reloadTimeout = setTimeout(() => {
          console.log(`[StepSelectorController] Executing server-side reload for step ${this.currentStepId}`)
          this.loadStepResults(this.currentStepId, stepElement, false) // false = don't show loading state
        }, 500)
      } else {
        console.warn(`[StepSelectorController] Step element not found for step_id: ${this.currentStepId}`)
      }
    } else if (updateStepId && !currentStepIdNum) {
      // No step is currently selected, but we got an update for a step - select and load it
      console.log(`[StepSelectorController] No step selected, but got update for step ${updateStepId}, selecting it...`)
      const stepElement = this.element.querySelector(`[data-step-id="${updateStepId}"]`)
      if (stepElement) {
        this.currentStepId = updateStepId.toString()
        this.element.setAttribute('data-current-step-id', updateStepId.toString())
        clearTimeout(this.reloadTimeout)
        this.reloadTimeout = setTimeout(() => {
          console.log(`[StepSelectorController] Loading step ${updateStepId} from websocket update`)
          this.loadStepResults(updateStepId, stepElement, true)
        }, 300)
      } else {
        console.warn(`[StepSelectorController] Step element not found for step_id: ${updateStepId}, refreshing steps panel first...`)
        this.refreshStepsPanel()
        setTimeout(() => {
          const stepElement2 = this.element.querySelector(`[data-step-id="${updateStepId}"]`)
          if (stepElement2) {
            this.currentStepId = updateStepId.toString()
            this.element.setAttribute('data-current-step-id', updateStepId.toString())
            this.loadStepResults(updateStepId, stepElement2, true)
          }
        }, 500)
      }
    } else {
      console.log(`[StepSelectorController] Not reloading step results - updateStepId (${updateStepId}) !== currentStepIdNum (${currentStepIdNum})`)
    }
    
    // Also reload if parsing_status changed and we're viewing the parsing step
    // This handles the case where parsing_status is sent but step_id might not match exactly
    if (data.parsing_status && this.currentStepId) {
      const currentStepElement = this.element.querySelector(`[data-step-id="${this.currentStepId}"]`)
      if (currentStepElement) {
        // If parsing status changed to complete or failed, reload the current step
        if (data.parsing_status === 'complete' || data.parsing_status === 'failed') {
          console.log(`[StepSelectorController] Parsing status changed to ${data.parsing_status}, reloading current step as fallback`)
          clearTimeout(this.reloadTimeout)
          this.reloadTimeout = setTimeout(() => {
            this.loadStepResults(this.currentStepId, currentStepElement, false)
          }, 500)
        }
      }
    }
  }

  refreshStepsPanel() {
    console.log('[StepSelectorController] ===== REFRESHING STEPS PANEL FROM SERVER =====')
    // Send selected_step_id so the server can render the blue border correctly
    const selectedStepId = this.currentStepId || this.element.getAttribute('data-current-step-id')
    let url = `/projects/${this.projectIdValue}/refresh_steps_panel`
    if (selectedStepId) {
      url += `?selected_step_id=${selectedStepId}`
    }
    console.log('[StepSelectorController] Fetching steps panel from:', url)
    console.log('[StepSelectorController] Selected step ID:', selectedStepId)
    
    const controller = this
    
    fetch(url, {
      method: 'GET',
      headers: {
        'Accept': 'text/html',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
    .then((response) => {
      console.log('[StepSelectorController] Steps panel response status:', response.status)
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.text()
    })
    .then((html) => {
      console.log('[StepSelectorController] ===== STEPS PANEL REFRESHED =====')
      console.log('[StepSelectorController] HTML length:', html.length)
      
      // Check if the HTML contains bg-blue-600 (server's is_current styling)
      const hasBlueBackground = html.includes('bg-blue-600')
      console.log('[StepSelectorController] HTML contains bg-blue-600:', hasBlueBackground)
      if (hasBlueBackground) {
        const match = html.match(/data-step-id="(\d+)"[^>]*bg-blue-600/)
        if (match) {
          console.log('[StepSelectorController] Server marked step', match[1], 'as current in HTML')
        }
      }
      
      // Find the steps panel container - it's the left panel div
      const stepsPanelContainer = controller.element.querySelector('.w-1\\/4') // Left panel
      if (stepsPanelContainer) {
        // The steps panel is rendered inside a div with specific classes
        const panelWrapper = stepsPanelContainer.querySelector('.bg-white.rounded-lg.shadow-sm.border')
        if (panelWrapper) {
          // Replace the steps panel content with fresh HTML from server
          panelWrapper.innerHTML = html
          console.log('[StepSelectorController] Steps panel content updated from server')
          
          // Re-attach event listeners to the new step elements
          const stepElements = panelWrapper.querySelectorAll('[data-step-id]')
          console.log('[StepSelectorController] Found', stepElements.length, 'step elements after refresh')
          
          // Server has already rendered the border correctly based on selected_step_id
          // Just clean up any blue backgrounds and re-attach event listeners
          stepElements.forEach((stepEl) => {
            // Remove blue background if present (shouldn't be, but safety check)
            stepEl.classList.remove('bg-blue-600')
            stepEl.style.backgroundColor = ''
            // Ensure white background
            if (!stepEl.classList.contains('bg-white')) {
              stepEl.classList.add('bg-white')
            }
            // Remove white text (we don't use that anymore)
            const textElements = stepEl.querySelectorAll('strong, small, span:not(.badge)')
            textElements.forEach((el) => {
              el.classList.remove('text-white')
            })
            // Border is already set by server, don't modify it
          })
          
          // Re-attach event listeners to the new step elements
          stepElements.forEach((stepEl) => {
            if (!stepEl.classList.contains('disabled')) {
              // Remove existing listeners and add new one
              stepEl.removeEventListener('click', controller.selectStep)
              stepEl.addEventListener('click', (e) => {
                controller.selectStep(e)
              })
            }
          })
          console.log('[StepSelectorController] Re-attached event listeners to', stepElements.length, 'step elements')
          console.log('[StepSelectorController] Border is already rendered by server - no client-side modification needed')
          
          // Clear the refreshing flag
          controller._refreshingStepsPanel = false
        } else {
          console.warn('[StepSelectorController] Steps panel wrapper not found')
          controller._refreshingStepsPanel = false
        }
      } else {
        console.warn('[StepSelectorController] Steps panel container (.w-1/4) not found')
        controller._refreshingStepsPanel = false
      }
    })
    .catch((error) => {
      console.error('[StepSelectorController] ===== ERROR REFRESHING STEPS PANEL =====')
      console.error('[StepSelectorController] Error:', error)
      controller._refreshingStepsPanel = false
    })
  }

  updateStepStatusBadge(stepId, data) {
    console.log('[StepSelectorController] ===== UPDATING STEP STATUS BADGE =====')
    console.log('[StepSelectorController] Step ID:', stepId, 'type:', typeof stepId)
    console.log('[StepSelectorController] Data:', data)
    
    const stepElement = this.element.querySelector(`[data-step-id="${stepId}"]`)
    if (!stepElement) {
      console.warn('[StepSelectorController] Step element not found for stepId:', stepId)
      return
    }
    console.log('[StepSelectorController] Step element found:', stepElement)

    // Convert step_id to number for comparison
    const stepIdNum = parseInt(stepId)
    const dataStepIdNum = data.step_id ? parseInt(data.step_id) : null
    console.log('[StepSelectorController] stepIdNum:', stepIdNum, 'dataStepIdNum:', dataStepIdNum)

    // Get current status from the badge (if it exists) to detect changes
    const currentBadge = stepElement.querySelector('.inline-flex.items-center')
    const currentStatus = currentBadge ? currentBadge.textContent.toLowerCase().trim() : null
    console.log('[StepSelectorController] Current badge status:', currentStatus)

    // Determine status from data
    let status = 'not_started'
    
    // Check if this is the parsing step and we have parsing_status
    if (data.parsing_status && dataStepIdNum === stepIdNum) {
      status = data.parsing_status
      console.log('[StepSelectorController] Using parsing_status:', status)
    } 
    // Check if we have run counts for this step
    else if (data.h_nber_analyses && dataStepIdNum === stepIdNum) {
      console.log('[StepSelectorController] Using h_nber_analyses:', data.h_nber_analyses)
      // Check if there are any runs with different statuses
      const hasRunning = data.h_nber_analyses[2] > 0
      const hasComplete = data.h_nber_analyses[3] > 0
      const hasFailed = data.h_nber_analyses[4] > 0
      
      console.log('[StepSelectorController] Run counts - Running:', hasRunning, 'Complete:', hasComplete, 'Failed:', hasFailed)
      
      if (hasRunning) {
        status = 'running'
      } else if (hasFailed) {
        status = 'failed'
      } else if (hasComplete) {
        status = 'complete'
      } else if (data.h_nber_analyses[1] > 0) {
        status = 'waiting'
      }
    } else {
      console.log('[StepSelectorController] No matching status data found')
    }
    
    console.log('[StepSelectorController] Determined status:', status)
    
    // If status is still not_started, don't update
    if (status === 'not_started') {
      console.log('[StepSelectorController] Status is not_started, skipping update')
      return
    }
    
    // Check if status changed to complete or failed, and if this is the currently displayed step
    const statusChanged = currentStatus !== status
    const isCurrentStep = this.currentStepId && (this.currentStepId.toString() === stepId.toString())
    const shouldReload = statusChanged && isCurrentStep && (status === 'complete' || status === 'failed' || status === 'running')
    
    console.log('[StepSelectorController] Status change check:')
    console.log('  - statusChanged:', statusChanged, `("${currentStatus}" -> "${status}")`)
    console.log('  - isCurrentStep:', isCurrentStep, `(currentStepId: ${this.currentStepId}, stepId: ${stepId})`)
    console.log('  - shouldReload:', shouldReload)
    
    if (shouldReload) {
      console.log(`[StepSelectorController] ===== TRIGGERING RELOAD =====`)
      console.log(`[StepSelectorController] Status changed from "${currentStatus}" to "${status}" for current step`)
    }

    // Update the icon
    const iconElement = stepElement.querySelector('.flex-shrink-0 i')
    if (iconElement) {
      iconElement.className = 'fas ' + (status === 'complete' ? 'fa-check-circle text-lg text-green-500' :
                                        status === 'running' ? 'fa-spinner fa-spin text-lg text-blue-500' :
                                        status === 'waiting' ? 'fa-clock text-lg text-yellow-500' :
                                        status === 'failed' ? 'fa-exclamation-circle text-lg text-red-500' :
                                        'far fa-circle text-lg opacity-30')
    }

    // Update the status badge
    let badgeElement = stepElement.querySelector('.inline-flex.items-center')
    if (!badgeElement) {
      // Create badge if it doesn't exist
      const badgeContainer = stepElement.querySelector('.flex-grow .mt-2')
      if (!badgeContainer) {
        // Create the container if it doesn't exist
        const flexGrow = stepElement.querySelector('.flex-grow')
        if (flexGrow) {
          const newContainer = document.createElement('div')
          newContainer.className = 'mt-2'
          flexGrow.appendChild(newContainer)
          badgeContainer = newContainer
        }
      }
      if (badgeContainer && status !== 'not_started') {
        // Create badge for all statuses except 'not_started' (including 'complete')
        badgeContainer.innerHTML = `<span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-${this.getStatusColor(status)}-100 text-${this.getStatusColor(status)}-800">${this.humanizeStatus(status)}</span>`
        console.log('[StepSelectorController] Created new badge for status:', status)
      }
    } else if (status !== 'not_started') {
      // Update existing badge
      badgeElement.className = `inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-${this.getStatusColor(status)}-100 text-${this.getStatusColor(status)}-800`
      badgeElement.textContent = this.humanizeStatus(status)
      console.log('[StepSelectorController] Updated existing badge to status:', status)
    } else if (status === 'not_started' && badgeElement) {
      // Remove badge if status is 'not_started'
      badgeElement.remove()
      console.log('[StepSelectorController] Removed badge for not_started status')
    }
    
    // Reload the step results if this is the current step and status changed significantly
    if (shouldReload) {
      clearTimeout(this.reloadTimeout)
      this.reloadTimeout = setTimeout(() => {
        console.log(`[StepSelectorController] Reloading step ${stepId} due to status change to ${status}`)
        this.loadStepResults(stepId, stepElement, false)
      }, 300)
    }
  }

  getStatusColor(status) {
    switch(status) {
      case 'complete': return 'green'
      case 'running': return 'blue'
      case 'waiting': return 'yellow'
      case 'failed': return 'red'
      default: return 'gray'
    }
  }

  humanizeStatus(status) {
    // Convert status string to human-readable format (capitalize first letter)
    if (!status) return ''
    return status.charAt(0).toUpperCase() + status.slice(1)
  }

  selectFirstAvailableStep() {
    // Find the first available step (not disabled)
    const firstStep = this.element.querySelector('[data-step-id]:not(.disabled)')
    if (firstStep) {
      const stepId = firstStep.getAttribute('data-step-id')
      // Set currentStepId before loading
      this.currentStepId = stepId.toString()
      this.element.setAttribute('data-current-step-id', stepId.toString())
      // Refresh steps panel to show the border (server will render it)
      this.refreshStepsPanel()
      // Load step results
      this.loadStepResults(stepId, firstStep, true)
      return true
    }
    return false
  }

  selectStep(event) {
    const stepElement = event.currentTarget
    const stepId = stepElement.getAttribute('data-step-id')
    
    // Update currentStepId
    this.currentStepId = stepId.toString()
    this.element.setAttribute('data-current-step-id', stepId.toString())
    
    // Refresh steps panel to show the border (server will render it)
    this.refreshStepsPanel()
    
    // Don't proceed if step is disabled
    if (stepElement.classList.contains('disabled')) {
      return
    }

    this.loadStepResults(stepId, stepElement)
  }

  loadStepResults(stepId, stepElement, showLoading = true) {
    console.log('[StepSelectorController] ===== LOADING STEP RESULTS =====')
    console.log('[StepSelectorController] Step ID:', stepId, 'type:', typeof stepId)
    console.log('[StepSelectorController] Step Element:', stepElement)
    console.log('[StepSelectorController] Show Loading:', showLoading)
    console.log('[StepSelectorController] Previous currentStepId:', this.currentStepId)
    
    // Track current step (ensure it's stored as string for consistency)
    // Store the stepId in a closure to preserve it
    const stepIdString = stepId ? stepId.toString() : null
    this.currentStepId = stepIdString
    this.element.setAttribute('data-current-step-id', stepIdString)
    console.log('[StepSelectorController] New currentStepId:', this.currentStepId, 'type:', typeof this.currentStepId)
    console.log('[StepSelectorController] Stored stepIdString:', stepIdString)
    
    // Refresh steps panel to show the border (server will render it)
    // Only refresh if we're not already in the middle of a refresh (to avoid infinite loops)
    if (!this._refreshingStepsPanel) {
      this.refreshStepsPanel()
    }
    
    // Update UI states
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.style.display = 'none'
    }
    if (showLoading && this.hasLoadingStateTarget) {
      console.log('[StepSelectorController] Showing loading state')
      this.loadingStateTarget.style.display = 'block'
    }
    if (this.hasContentTarget) {
      this.contentTarget.style.display = 'none'
    }
    
    // Border is handled by server via refreshStepsPanel (called from selectStep/selectFirstAvailableStep)

    // Load step results via AJAX
    // Add cache-busting parameter to ensure fresh data on page reload
    const cacheBuster = new Date().getTime()
    const url = `/projects/${this.projectIdValue}/step_results?step_id=${stepId}&_t=${cacheBuster}`
    console.log('[StepSelectorController] Fetching URL:', url)
    
    // Store controller reference and stepId to preserve in promise chain
    const controller = this
    
    fetch(url, {
      method: 'GET',
      headers: {
        'Accept': 'text/html',
        'X-Requested-With': 'XMLHttpRequest',
        'Cache-Control': 'no-cache'
      },
      credentials: 'same-origin',
      cache: 'no-store'
    })
    .then((response) => {
      console.log('[StepSelectorController] Fetch response status:', response.status, response.statusText)
      console.log('[StepSelectorController] Response headers:', response.headers)
      if (!response.ok) {
        console.error('[StepSelectorController] Response not OK, status:', response.status)
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      console.log('[StepSelectorController] Converting response to text...')
      return response.text()
    })
    .then((html) => {
      console.log('[StepSelectorController] Response text received, length:', html ? html.length : 0)
      console.log('[StepSelectorController] ===== STEP RESULTS LOADED =====')
      console.log('[StepSelectorController] HTML length:', html.length)
      console.log('[StepSelectorController] HTML preview (first 500 chars):', html.substring(0, 500))
      console.log('[StepSelectorController] Updating content target')
      console.log('[StepSelectorController] currentStepId BEFORE update:', controller.currentStepId)
      console.log('[StepSelectorController] stepId parameter:', stepId, 'stepIdString:', stepIdString)
      console.log('[StepSelectorController] controller reference:', controller)
      
      // Check if HTML is empty or just whitespace
      if (!html || html.trim().length === 0) {
        console.error('[StepSelectorController] Received empty HTML response!')
        if (controller.hasLoadingStateTarget) {
          controller.loadingStateTarget.style.display = 'none'
        }
        if (controller.hasEmptyStateTarget) {
          controller.emptyStateTarget.style.display = 'block'
        }
        if (controller.hasContentTarget) {
          controller.contentTarget.style.display = 'none'
        }
        return
      }
      
      // Re-set currentStepId to ensure it's preserved
      if (stepIdString) {
        controller.currentStepId = stepIdString
        // Also store in data attribute as backup
        controller.element.setAttribute('data-current-step-id', stepIdString)
        console.log('[StepSelectorController] Re-set currentStepId to:', controller.currentStepId)
        console.log('[StepSelectorController] Also stored in data attribute')
      }
      
      // Verify contentTarget exists before updating
      if (!controller.hasContentTarget) {
        console.error('[StepSelectorController] contentTarget is missing! Cannot update content.')
        if (controller.hasLoadingStateTarget) {
          controller.loadingStateTarget.style.display = 'none'
        }
        if (controller.hasEmptyStateTarget) {
          controller.emptyStateTarget.style.display = 'block'
        }
        return
      }
      
      controller.contentTarget.innerHTML = html
      if (controller.hasLoadingStateTarget) {
        controller.loadingStateTarget.style.display = 'none'
      }
      if (controller.hasEmptyStateTarget) {
        controller.emptyStateTarget.style.display = 'none'
      }
      controller.contentTarget.style.display = 'block'
      
      console.log('[StepSelectorController] Content updated')
      if (controller.hasContentTarget) {
        console.log('[StepSelectorController] Content target element:', controller.contentTarget)
        console.log('[StepSelectorController] Content target display after update:', window.getComputedStyle(controller.contentTarget).display)
        console.log('[StepSelectorController] Content target innerHTML length:', controller.contentTarget.innerHTML.length)
        console.log('[StepSelectorController] Content target innerHTML preview:', controller.contentTarget.innerHTML.substring(0, 200))
        
        // Double-check that content is visible
        if (window.getComputedStyle(controller.contentTarget).display === 'none') {
          console.warn('[StepSelectorController] Content is still hidden! Forcing display block...')
          controller.contentTarget.style.display = 'block'
        }
      }
      console.log('[StepSelectorController] currentStepId AFTER update:', controller.currentStepId)
      console.log('[StepSelectorController] Data attribute value:', controller.element.getAttribute('data-current-step-id'))
      console.log('[StepSelectorController] Verifying currentStepId is still set correctly...')
      // Ensure currentStepId is still set (it might have been reset somehow)
      if (!controller.currentStepId && stepId) {
        console.warn('[StepSelectorController] WARNING: currentStepId was null, resetting to:', stepId)
        controller.currentStepId = stepId.toString()
        controller.element.setAttribute('data-current-step-id', stepId.toString())
      }
      console.log('[StepSelectorController] Final currentStepId:', controller.currentStepId)
    })
    .catch(error => {
      console.error('[StepSelectorController] ===== ERROR LOADING STEP RESULTS =====')
      console.error('[StepSelectorController] Error:', error)
      console.error('[StepSelectorController] Error message:', error.message)
      console.error('[StepSelectorController] Error stack:', error.stack)
      if (controller.hasLoadingStateTarget) {
        controller.loadingStateTarget.style.display = 'none'
      }
      if (controller.hasContentTarget) {
        controller.contentTarget.innerHTML = `
          <div class="alert alert-danger">
            <i class="fas fa-exclamation-triangle me-2"></i>
            Error loading step results: ${error.message}. Please try again.
          </div>
        `
        controller.contentTarget.style.display = 'block'
      }
      if (controller.hasEmptyStateTarget) {
        controller.emptyStateTarget.style.display = 'none'
      }
    })
  }

  // Note: updateActiveStep is no longer needed - the server renders the border
  // This method is kept for backwards compatibility but does nothing
  // The border is now handled entirely by the server in _steps_panel.html.erb
  updateActiveStep(activeElement) {
    // Server handles border rendering, so this is a no-op
    // Kept for backwards compatibility in case any code still calls it
  }
}

