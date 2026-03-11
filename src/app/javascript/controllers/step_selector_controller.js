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
  static targets = ["resultsContainer", "emptyState", "loadingState", "content", "stepsPanel"]
  static values = { projectId: Number, projectKey: String, statusIcons: Array, loadRunPanel: Boolean, loadSubView: Boolean, subViewStepId: Number, loomFile: String }

  get projectIdentifier() {
    return this.projectKeyValue || this.projectIdValue
  }

  // LocalStorage key helpers for state persistence
  getStorageKey(suffix) {
    return `project_${this.projectIdValue}_analysis_${suffix}`
  }

  saveState(stepId, contentType = 'step', runId = null) {
    try {
      const state = {
        stepId: stepId ? stepId.toString() : null,
        contentType: contentType, // 'step', 'run', 'form'
        runId: runId ? runId.toString() : null,
        timestamp: Date.now()
      }
      localStorage.setItem(this.getStorageKey('state'), JSON.stringify(state))
      console.log('[StepSelectorController] State saved:', state)
    } catch (e) {
      console.warn('[StepSelectorController] Failed to save state to localStorage:', e)
    }
  }

  loadState() {
    try {
      const stateJson = localStorage.getItem(this.getStorageKey('state'))
      if (stateJson) {
        const state = JSON.parse(stateJson)
        // Check if state is not too old (24 hours)
        const maxAge = 24 * 60 * 60 * 1000
        if (state.timestamp && (Date.now() - state.timestamp) < maxAge) {
          console.log('[StepSelectorController] State loaded:', state)
          return state
        } else {
          console.log('[StepSelectorController] State expired, clearing')
          localStorage.removeItem(this.getStorageKey('state'))
        }
      }
    } catch (e) {
      console.warn('[StepSelectorController] Failed to load state from localStorage:', e)
    }
    return null
  }

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
      if (!this.hasStepsPanelTarget) {
        console.warn('[StepSelectorController] stepsPanel target not found')
      } else {
        console.log('[StepSelectorController] stepsPanel target found:', this.stepsPanelTarget)
      }
    // Track currently displayed step
    this.currentStepId = null
    console.log('[StepSelectorController] Initial currentStepId set to:', this.currentStepId)
    this._refreshingStepsPanel = false
    this._refreshingStepsPanelPromise = null
    this.statusUpdateDebounceMs = 350
    this.statusUpdateTimer = null
    this.pendingStatusUpdate = null
    this._initialPanelRevealDone = false
    this._pendingLoadStepId = null
    this._isBootstrapping = true
    this._hasLoadedInitialStep = false
    this._realtimeReloadCooldownUntil = Date.now() + 4000
    
    // Remove any blue background from server-rendered steps (all should be white)
    // This ensures consistency with the new design
    // DO NOT reset borders - server already sets them correctly based on @selected_step_id
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
      // Border is already set correctly by server based on @selected_step_id, don't modify it
    })
    
    // Check URL parameters
    const urlParams = new URLSearchParams(window.location.search)
    const runIdFromUrl = urlParams.get('run_id')
    const stepIdFromUrl = urlParams.get('step_id')
    const showFormFromUrl = urlParams.get('show_form')
    const panelModeFromUrl = urlParams.get('panel_mode')
    const loomFileFromUrl = urlParams.get('loom_file')
    const hasTransientUrlParams = !!(
      runIdFromUrl ||
      stepIdFromUrl ||
      showFormFromUrl ||
      panelModeFromUrl ||
      loomFileFromUrl ||
      urlParams.get('sub_view') ||
      urlParams.get('de_fdr') ||
      urlParams.get('de_fc') ||
      urlParams.get('markers_fdr') ||
      urlParams.get('markers_fc') ||
      urlParams.get('markers_max_genes') ||
      urlParams.get('markers_highlight') ||
      urlParams.get('markers_analysis') ||
      urlParams.get('ge_fdr') ||
      urlParams.get('gene_list_run_id') ||
      urlParams.get('gene_list_type') ||
      urlParams.get('geneset_list_run_id') ||
      urlParams.get('geneset_list_type')
    )
    
    // Check if server says to load run panel (false when step has a custom partial like _parsing.html.erb)
    const shouldLoadRunPanel = this.hasLoadRunPanelValue ? this.loadRunPanelValue : false
    const shouldLoadSubView = this.hasLoadSubViewValue ? this.loadSubViewValue : false
    const subViewStepId = this.hasSubViewStepIdValue ? this.subViewStepIdValue : null
    console.log('[StepSelectorController] loadRunPanelValue:', shouldLoadRunPanel, 'loadSubViewValue:', shouldLoadSubView, 'subViewStepId:', subViewStepId)
    
    // If server already rendered the sub_view content into the page, just set up state and return
    if (shouldLoadSubView && subViewStepId) {
      console.log('[StepSelectorController] Sub-view content server-rendered, setting up state for step:', subViewStepId)
      this.currentStepId = subViewStepId.toString()
      this.element.setAttribute('data-current-step-id', subViewStepId.toString())
      this.saveState(subViewStepId, 'step', null)
      this._executeInlineScripts()
      this.subscribeToProject()
      this._cleanUrlParams()
      this._initialPanelRevealDone = true
      return
    }

    // If server already rendered the run panel content into the page, just set up state and return
    if (shouldLoadRunPanel && stepIdFromUrl) {
      console.log('[StepSelectorController] Run panel content server-rendered, setting up state for step:', stepIdFromUrl)
      this.currentStepId = stepIdFromUrl.toString()
      this.element.setAttribute('data-current-step-id', stepIdFromUrl.toString())
      this.saveState(stepIdFromUrl, 'run', runIdFromUrl)
      this._executeInlineScripts()
      this.subscribeToProject()
      this._cleanUrlParams()
      this._initialPanelRevealDone = true
      return
    }

    // Normal flow: load step results
    // If panel_mode=graph is requested, do not auto-load a step here.
    // The analysis view script will load the graph into the right panel.
    if (panelModeFromUrl === 'graph') {
      console.log('[StepSelectorController] panel_mode=graph detected, skipping initial auto step load')
      if (hasTransientUrlParams) {
        this._cleanUrlParams()
      }
      this.subscribeToProject()
      return
    }

    // Wait for steps panel to be loaded before trying to select a step
    // The steps panel might be loaded asynchronously via refreshStepsPanel
    const controller = this
    
    // Check if we should restore state from localStorage (no URL params)
    const savedState = this.loadState()
    const shouldRestoreState = !stepIdFromUrl && !runIdFromUrl && savedState && savedState.stepId
    console.log('[StepSelectorController] Should restore state:', shouldRestoreState, savedState)
    
    const trySelectStep = function() {
      // Priority 1: URL params
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
          if (runIdFromUrl && typeof loadRunInRightPanel === 'function') {
            controller.saveState(stepId, 'run', runIdFromUrl)
            setTimeout(() => {
              loadRunInRightPanel(`/runs/${runIdFromUrl}`, stepId)
            }, 0)
            return true
          }
          const extraQuery = showFormFromUrl === '1' ? '&show_form=1' : ''
          controller.loadStepResults(stepId, stepElement, true, extraQuery, 'connect:url_step')
          return true
        } else {
          console.warn('[StepSelectorController] Step element not found for step_id:', stepIdFromUrl)
          console.log('[StepSelectorController] Available step elements:', Array.from(controller.element.querySelectorAll('[data-step-id]')).map(el => el.getAttribute('data-step-id')))
          return false
        }
      }
      
      // Priority 2: Restore from localStorage
      if (shouldRestoreState) {
        console.log('[StepSelectorController] Restoring state from localStorage:', savedState)
        const stepElement = controller.element.querySelector(`[data-step-id="${savedState.stepId}"]`)
        if (stepElement) {
          const stepId = savedState.stepId
          console.log('[StepSelectorController] Restoring step_id from localStorage:', stepId)
          controller.currentStepId = stepId.toString()
          controller.element.setAttribute('data-current-step-id', stepId.toString())
          
          // If saved state was showing a run, load the run directly
          if (savedState.contentType === 'run' && savedState.runId) {
            console.log('[StepSelectorController] Restoring run panel for run_id:', savedState.runId)
            // Hide empty state and loading state, show loading
            if (controller.hasEmptyStateTarget) {
              controller.emptyStateTarget.style.display = 'none'
            }
            if (controller.hasLoadingStateTarget) {
              controller.loadingStateTarget.style.display = 'block'
            }
            
            // Load run panel - use global function from _analysis.html.erb
            setTimeout(() => {
              if (typeof loadRunInRightPanel === 'function') {
                loadRunInRightPanel(`/runs/${savedState.runId}`, stepId)
              } else {
                // Fallback to loading step results
                controller.loadStepResults(stepId, stepElement, true, '', 'connect:restore_state_run_fallback')
              }
            }, 100)
            return true
          }
          
          // Regular step load
          controller.loadStepResults(stepId, stepElement, true, '', 'connect:restore_state_step')
          return true
        } else {
          console.warn('[StepSelectorController] Saved step element not found for step_id:', savedState.stepId)
          // Clear invalid saved state
          localStorage.removeItem(controller.getStorageKey('state'))
        }
      }
      
      // Priority 3: First available step
      console.log('[StepSelectorController] No step_id in URL or localStorage, selecting first available step')
      return controller.selectFirstAvailableStep()
    }
    
    // Try immediately, then retry after a short delay if steps panel isn't ready
    if (!trySelectStep()) {
      console.log('[StepSelectorController] Steps panel not ready, retrying after refresh...')
      this.refreshStepsPanel('connect:retry_steps_panel')
      setTimeout(function() {
        if (!trySelectStep()) {
          console.warn('[StepSelectorController] Still couldn\'t find step, falling back to first available')
          controller.selectFirstAvailableStep()
        }
      }, 500)
    }

    // Ensure deep-link/transient params are always cleaned, including non-server-rendered flows.
    if (hasTransientUrlParams) {
      setTimeout(() => {
        this._cleanUrlParams()
      }, 300)
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
    if (this.statusUpdateTimer) {
      clearTimeout(this.statusUpdateTimer)
      this.statusUpdateTimer = null
    }
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
          if (this._hasLoadedInitialStep && !this._isBootstrapping) {
            this.reconcileCurrentStepOnConnect()
          } else {
            console.log('[StepSelectorController] Skip reconcile on initial websocket connect during bootstrap')
          }
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
          if (data && data.event === 'queue_position_changed') {
            return
          }
          console.log(`[StepSelectorController] ===== WEBSOCKET MESSAGE RECEIVED =====`)
          console.log(`[StepSelectorController] Timestamp:`, new Date().toISOString())
          console.log(`[StepSelectorController] Full data object:`, JSON.stringify(data, null, 2))
          console.log(`[StepSelectorController] step_id:`, data.step_id, `(type: ${typeof data.step_id})`)
          console.log(`[StepSelectorController] parsing_status:`, data.parsing_status)
          console.log(`[StepSelectorController] h_nber_analyses:`, data.h_nber_analyses)
          console.log(`[StepSelectorController] Current step ID:`, this.currentStepId, `(type: ${typeof this.currentStepId})`)
          console.log(`[StepSelectorController] Will call handleStatusUpdate now...`)
          this.scheduleStatusUpdate(data)
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

  scheduleStatusUpdate(data) {
    console.log('[StepSelectorController] scheduleStatusUpdate payload:', {
      step_id: data?.step_id,
      step_name: data?.step_name,
      parsing_status: data?.parsing_status,
      has_h_nber_analyses: !!data?.h_nber_analyses,
      has_project_run_totals: !!data?.project_run_totals
    })

    // Do not debounce terminal updates (completed/failed): they must be applied
    // immediately so left/right panels switch as soon as a step ends.
    const isTerminal = this.isTerminalStepUpdate(data)
    console.log('[StepSelectorController] scheduleStatusUpdate decision:', {
      isTerminalStepUpdate: isTerminal,
      debounceMs: this.statusUpdateDebounceMs
    })
    if (isTerminal) {
      if (this.statusUpdateTimer) {
        clearTimeout(this.statusUpdateTimer)
        this.statusUpdateTimer = null
      }
      this.pendingStatusUpdate = null
      console.log('[StepSelectorController] Applying terminal update immediately')
      this.handleStatusUpdate(data)
      return
    }

    this.pendingStatusUpdate = data
    if (this.statusUpdateTimer) {
      clearTimeout(this.statusUpdateTimer)
    }
    this.statusUpdateTimer = setTimeout(() => {
      const update = this.pendingStatusUpdate
      this.pendingStatusUpdate = null
      this.statusUpdateTimer = null
      if (update) {
        this.handleStatusUpdate(update)
      }
    }, this.statusUpdateDebounceMs)
  }

  reconcileCurrentStepOnConnect() {
    // Reconciliation pass for cases where terminal updates were missed during
    // websocket reconnects: pull current aggregate state and refresh parsing UI.
    const currentStepId = this.currentStepId || this.element.getAttribute('data-current-step-id')
    if (!currentStepId) return

    const currentStepEl = this.element.querySelector(`[data-step-id="${currentStepId}"]`)
    if (!currentStepEl) return

    const currentStepName = (currentStepEl.getAttribute('data-step-name') || '').toString().toLowerCase()
    if (currentStepName !== 'parsing') return

    const url = `/projects/${this.projectIdentifier}/run_counts`
    console.log('[StepSelectorController] reconcileCurrentStepOnConnect request:', {
      url,
      currentStepId,
      currentStepName
    })

    fetch(url, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`)
        }
        return response.json()
      })
      .then((counts) => {
        console.log('[StepSelectorController] reconcileCurrentStepOnConnect response:', counts)
        const running = parseInt(counts.running ?? 0, 10) || 0
        const success = parseInt(counts.success ?? 0, 10) || 0
        const failed = parseInt(counts.failed ?? 0, 10) || 0
        const isTerminal = running === 0 && (success > 0 || failed > 0)
        if (!isTerminal) return

        const sameStepLoadInFlight =
          this._pendingLoadStepId &&
          this._pendingLoadStepId.toString() === currentStepId.toString()

        if (sameStepLoadInFlight) {
          console.log('[StepSelectorController] reconcileCurrentStepOnConnect skip: same step load in flight', {
            currentStepId,
            pendingLoadStepId: this._pendingLoadStepId
          })
          return
        }

        const sameStepJustLoaded =
          this._lastLoadedStepId &&
          this._lastLoadedStepId.toString() === currentStepId.toString() &&
          this._lastStepResultsLoadedAt &&
          (Date.now() - this._lastStepResultsLoadedAt) < 3000

        if (sameStepJustLoaded) {
          console.log('[StepSelectorController] reconcileCurrentStepOnConnect skip: same step loaded recently', {
            currentStepId,
            msSinceLastLoad: Date.now() - this._lastStepResultsLoadedAt
          })
          return
        }

        console.log('[StepSelectorController] reconcileCurrentStepOnConnect forcing refresh for terminal parsing state', {
          currentStepId,
          running,
          success,
          failed
        })
        this.loadStepResults(currentStepId, currentStepEl, false)
      })
      .catch((error) => {
        console.warn('[StepSelectorController] reconcileCurrentStepOnConnect failed:', error)
      })
  }

  isTerminalStepUpdate(data) {
    if (!data) return false

    const parsingStatus = (data.parsing_status || '').toString().toLowerCase()
    if (parsingStatus === 'success' || parsingStatus === 'failed') {
      console.log('[StepSelectorController] Terminal by parsing_status:', parsingStatus)
      return true
    }

    const counts = data.h_nber_analyses
    if (!counts) return false

    const pending = parseInt(counts[1] ?? counts['1'] ?? 0, 10) || 0
    const running = parseInt(counts[2] ?? counts['2'] ?? 0, 10) || 0
    const success = parseInt(counts[3] ?? counts['3'] ?? 0, 10) || 0
    const failed = parseInt(counts[4] ?? counts['4'] ?? 0, 10) || 0

    const isTerminal = pending === 0 && running === 0 && (success > 0 || failed > 0)
    console.log('[StepSelectorController] Terminal by h_nber_analyses check:', {
      pending,
      running,
      success,
      failed,
      isTerminal
    })
    return isTerminal
  }

  handleStatusUpdate(data) {
    if (this._isBootstrapping) {
      console.log('[StepSelectorController] Ignoring websocket status update during bootstrap')
      return
    }

    console.log('[StepSelectorController] ===== HANDLE STATUS UPDATE =====')
    console.log('[StepSelectorController] handleStatusUpdate called with data:', data)
    console.log('[StepSelectorController] data.step_id:', data.step_id)
    console.log('[StepSelectorController] data.parsing_status:', data.parsing_status)
    console.log('[StepSelectorController] data.h_nber_analyses:', data.h_nber_analyses)
    console.log('[StepSelectorController] Current step ID before update:', this.currentStepId)

    // Keep the top header status summary synchronized from the same websocket payload.
    // This avoids stale header icons when another controller misses an update.
    this.updateHeaderStatusSummary(data)
    this.forceRefreshParsingPanelOnTerminalStatus(data)
    
    // Check if right panel is displaying a form (new run form)
    const hasFormInRightPanel = this.hasContentTarget && this.contentTarget.querySelector('.std-form') !== null
    console.log('[StepSelectorController] Right panel has form?', hasFormInRightPanel)
    
    if (hasFormInRightPanel) {
      console.log('[StepSelectorController] Right panel is displaying form - skipping refresh to avoid interrupting user')
      // Still update the badge in the left panel
      const updateStepId = data.step_id ? parseInt(data.step_id) : null
      if (updateStepId && (data.h_nber_analyses || data.parsing_status)) {
        this.refreshStepsPanel().then(() => {
          this.updateStepStatusBadge(updateStepId.toString(), data)
        }).catch((error) => {
          console.error('[StepSelectorController] Error refreshing steps panel:', error)
          this.updateStepStatusBadge(updateStepId.toString(), data)
        })
      }
      return // Exit early - don't refresh right panel
    }
    
    // Check if any form is currently open
    const isFormOpen = this.isAnyFormOpen()
    console.log('[StepSelectorController] Is form open?', isFormOpen)
    
    // Preserve currentStepId before refresh (it might get lost during DOM replacement)
    const preservedStepId = this.currentStepId || this.element.getAttribute('data-current-step-id')
    console.log('[StepSelectorController] Preserving step ID before refresh:', preservedStepId)
    
    // Convert step_id to number for comparison
    const updateStepId = data.step_id ? parseInt(data.step_id) : null
    
    // Store websocket data to update badge after panel refresh (since DOM gets replaced)
    const websocketData = data
    
    // Always refresh the steps panel from the server to ensure consistency
    // After refresh completes, update the badge with websocket data
    this.refreshStepsPanel().then(() => {
      // Update step status badge with websocket data after panel refresh
      // This ensures the badge reflects the latest run counts from the websocket
      if (updateStepId && (websocketData.h_nber_analyses || websocketData.parsing_status)) {
        console.log(`[StepSelectorController] Updating status badge for step ${updateStepId} with websocket data after panel refresh`)
        this.updateStepStatusBadge(updateStepId.toString(), websocketData)
      }
    }).catch((error) => {
      console.error('[StepSelectorController] Error refreshing steps panel:', error)
      // Still try to update badge even if refresh failed
      if (updateStepId && (websocketData.h_nber_analyses || websocketData.parsing_status)) {
        console.log(`[StepSelectorController] Updating status badge for step ${updateStepId} with websocket data (refresh failed)`)
        this.updateStepStatusBadge(updateStepId.toString(), websocketData)
      }
    })
    
    // Restore currentStepId after refresh (DOM replacement might have cleared it)
    if (preservedStepId && !this.currentStepId) {
      console.log('[StepSelectorController] Restoring currentStepId after refresh:', preservedStepId)
      this.currentStepId = preservedStepId
      this.element.setAttribute('data-current-step-id', preservedStepId)
    }
    
    const currentStepIdNum = this.currentStepId ? parseInt(this.currentStepId) : null
    
    console.log('[StepSelectorController] Update step ID:', updateStepId, 'Current step ID:', currentStepIdNum)
    console.log('[StepSelectorController] Comparison:', updateStepId, '===', currentStepIdNum, '?', updateStepId === currentStepIdNum)
    
    // Update specific runs in the right panel if the update is for the currently displayed step
    // Instead of reloading the whole panel, only update status/time for runs that finished
    if (updateStepId && currentStepIdNum && updateStepId === currentStepIdNum) {
      console.log(`[StepSelectorController] Status update for current step ${this.currentStepId}, updating specific runs...`)
      
      // For the parsing step (identified by parsing_status in the broadcast data),
      // don't reload the content panel on every broadcast. The parsing view has no
      // run rows and would trigger an unnecessary full reload each time.
      // The parsing_status check further below handles the success/failed transitions.
      if (data.parsing_status && data.parsing_status !== 'success' && data.parsing_status !== 'failed') {
        // Keep in-progress parsing lightweight, but force a reload when the current
        // panel still shows a failed state so failed -> waiting/running is visible.
        const parsingStatusPanel = this.contentTarget.querySelector('[data-parsing-status-panel="true"]')
        const shownStatusId = parsingStatusPanel ? parseInt(parsingStatusPanel.dataset.currentStatusId || '', 10) : null
        const isShowingFailedPanel = shownStatusId === 4

        if (isShowingFailedPanel && (data.parsing_status === 'pending' || data.parsing_status === 'running')) {
          console.log(`[StepSelectorController] Parsing recovered (${data.parsing_status}) from failed panel, reloading content`)
          clearTimeout(this.reloadTimeout)
          this.reloadTimeout = setTimeout(() => {
            this.loadStepResults(this.currentStepId, currentStepElement, false)
          }, 300)
        } else {
          console.log(`[StepSelectorController] Parsing step in progress (${data.parsing_status}), skipping content reload`)
        }
      } else if (this.hasContentTarget) {
        // Search for run rows - they might be in a table or nested in the content
        const runRows = this.contentTarget.querySelectorAll('tr[data-run-id]')
        console.log(`[StepSelectorController] Found ${runRows.length} run rows in content target`)
        
        const runsToUpdate = []
        
        runRows.forEach(row => {
          const runId = parseInt(row.getAttribute('data-run-id'))
          runsToUpdate.push(runId)
        })
        
        if (runsToUpdate.length > 0) {
          console.log(`[StepSelectorController] Found ${runsToUpdate.length} runs to update:`, runsToUpdate)
          runsToUpdate.forEach(runId => {
            this.updateRunStatus(runId)
          })
        } else if (runRows.length === 0 && this.contentTarget.innerHTML.trim().length > 0) {
          console.log(`[StepSelectorController] No run rows found but content exists, skipping reload to preserve current sub-view`)
        }
      } else {
        console.warn(`[StepSelectorController] No content target available`)
      }
    } else if (updateStepId && !currentStepIdNum) {
      if (Date.now() < this._realtimeReloadCooldownUntil) {
        console.log('[StepSelectorController] Skipping websocket-driven step load during startup cooldown')
        return
      }
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
    
    // Parsing terminal refresh is handled by forceRefreshParsingPanelOnTerminalStatus.
  }

  forceRefreshParsingPanelOnTerminalStatus(data) {
    if (!data) return
    const status = data.parsing_status
    const stepName = (data.step_name || '').toString().toLowerCase()
    console.log('[StepSelectorController] forceRefreshParsingPanelOnTerminalStatus input:', {
      step_id: data.step_id,
      step_name: stepName,
      parsing_status: status,
      currentStepId: this.currentStepId
    })
    if (stepName !== 'parsing') return
    if (status !== 'success' && status !== 'failed') return
    if (Date.now() < this._realtimeReloadCooldownUntil) {
      console.log('[StepSelectorController] Skipping parsing terminal reload during startup cooldown')
      return
    }

    const stepId = data.step_id ? parseInt(data.step_id, 10) : null
    if (!stepId) return

    const stepElement = this.element.querySelector(`[data-step-id="${stepId}"]`)
    console.log('[StepSelectorController] forceRefreshParsingPanelOnTerminalStatus target lookup:', {
      stepId,
      stepElementFound: !!stepElement
    })
    if (!stepElement) return

    this.currentStepId = stepId.toString()
    this.element.setAttribute('data-current-step-id', this.currentStepId)

    clearTimeout(this.reloadTimeout)
    console.log('[StepSelectorController] Triggering loadStepResults from terminal parsing update:', {
      stepId,
      status
    })
    this.reloadTimeout = setTimeout(() => {
      this.loadStepResults(stepId, stepElement, false)
    }, 250)
  }

  updateHeaderStatusSummary(data) {
    const totals = data && data.project_run_totals
    if (!totals) return

    const headerRoot = document.querySelector('[data-controller~="header-run-status"]')
    if (!headerRoot) return

    const statusKeys = ['pending', 'running', 'success', 'failed']
    statusKeys.forEach((statusKey) => {
      const count = parseInt(totals[statusKey]) || 0

      const countEl = headerRoot.querySelector(`[data-header-run-status-target="statusCount"][data-status-key="${statusKey}"]`)
      if (countEl) {
        countEl.textContent = `${count}`
      }

      const iconEl = headerRoot.querySelector(`[data-header-run-status-target="statusIcon"][data-status-key="${statusKey}"]`)
      if (iconEl) {
        const iconBase = iconEl.dataset.iconBase || ''
        const iconSpin = iconEl.dataset.iconSpin || ''
        const activeColor = iconEl.dataset.activeColor || ''
        const inactiveColor = iconEl.dataset.inactiveColor || ''
        const isActive = count > 0
        const colorClass = isActive ? activeColor : inactiveColor
        const spinClass = isActive && iconSpin ? ` ${iconSpin}` : ''
        iconEl.className = `${iconBase}${spinClass} text-base ${colorClass}`
      }

      const btnEl = headerRoot.querySelector(`[data-header-run-status-target="statusButton"][data-status-key="${statusKey}"]`)
      if (btnEl) {
        const isActive = count > 0
        const label = iconEl?.dataset.label || statusKey
        btnEl.title = `${label} (${count})`
        btnEl.disabled = !isActive
        if (isActive) {
          btnEl.classList.remove('cursor-default')
        } else {
          btnEl.classList.add('cursor-default')
        }
      }
    })
  }

  isAnyFormOpen() {
    // No longer using slide-in forms, so always return false
    return false
  }

  _cleanUrlParams() {
    const url = new URL(window.location.href)
    const keysToRemove = ['step_id', 'run_id', 'sub_view',
      'panel_mode', 'show_form', 'loom_file',
      'de_fdr', 'de_fc',
      'markers_fdr', 'markers_fc', 'markers_max_genes', 'markers_highlight', 'markers_analysis',
      'ge_fdr',
      'gene_list_run_id', 'gene_list_type', 'geneset_list_run_id', 'geneset_list_type']
    keysToRemove.forEach(k => url.searchParams.delete(k))
    window.history.replaceState({}, '', url.toString())
  }

  _executeInlineScripts() {
    if (!this.hasContentTarget) return
    const scripts = this.contentTarget.querySelectorAll('script')
    scripts.forEach(original => {
      try {
        const replacement = document.createElement('script')
        if (original.src) {
          replacement.src = original.src
        } else {
          replacement.textContent = original.textContent
        }
        original.parentNode.replaceChild(replacement, original)
      } catch (error) {
        console.warn('[StepSelectorController] Inline script execution failed:', error)
      }
    })
  }

  refreshStepsPanel(source = 'unknown') {
    console.log('[StepSelectorController] ===== REFRESHING STEPS PANEL FROM SERVER =====')
    console.log('[StepSelectorController][trace] refreshStepsPanel called:', {
      source,
      currentStepId: this.currentStepId,
      dataCurrentStepId: this.element.getAttribute('data-current-step-id'),
      inFlight: this._refreshingStepsPanel,
      origin: this.debugCallOrigin()
    })
    if (this._refreshingStepsPanel) {
      return this._refreshingStepsPanelPromise || Promise.resolve()
    }
    this._refreshingStepsPanel = true
    // Send selected_step_id so the server can render the blue border correctly
    const selectedStepId = this.currentStepId || this.element.getAttribute('data-current-step-id')
    let url = `/projects/${this.projectIdentifier}/refresh_steps_panel.html`
    if (selectedStepId) {
      url += `?selected_step_id=${selectedStepId}`
    }
    console.log('[StepSelectorController] Fetching steps panel from:', url)
    console.log('[StepSelectorController] Selected step ID:', selectedStepId)
    
    const controller = this
    let preservedScrollTop = 0
    
    const refreshPromise = fetch(url, {
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
      
      // Find the steps panel container using the target or fallback to class selectors
      const stepsPanelContainer = controller.hasStepsPanelTarget 
        ? controller.stepsPanelTarget 
        : (controller.element.querySelector('.w-75') || controller.element.querySelector('.w-64') || controller.element.querySelector('.w-1\\/4'))
      console.log('[StepSelectorController] Steps panel container found:', !!stepsPanelContainer)
      if (stepsPanelContainer) {
        // The steps panel is rendered inside a div with specific classes
        const panelWrapper = stepsPanelContainer.querySelector('.bg-white.rounded-lg.shadow-sm.border')
        console.log('[StepSelectorController] Panel wrapper found:', !!panelWrapper)
        if (panelWrapper) {
          const previousScrollContainer = panelWrapper.querySelector('.flex-1.overflow-y-auto')
          preservedScrollTop = previousScrollContainer ? previousScrollContainer.scrollTop : 0

          // Replace the steps panel content with fresh HTML from server
          panelWrapper.innerHTML = html
          console.log('[StepSelectorController] Steps panel content updated from server')

          const refreshedScrollContainer = panelWrapper.querySelector('.flex-1.overflow-y-auto')
          if (refreshedScrollContainer) {
            refreshedScrollContainer.scrollTop = preservedScrollTop
          }
          
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
            if (!stepEl.classList.contains('disabled') && stepEl.getAttribute('data-step-locked') !== 'true') {
              // Remove existing listeners and add new one
              stepEl.removeEventListener('click', controller.selectStep)
              stepEl.addEventListener('click', (e) => {
                controller.selectStep(e)
              })
            }
          })
          console.log('[StepSelectorController] Re-attached event listeners to', stepElements.length, 'step elements')
          console.log('[StepSelectorController] Border is already rendered by server - no client-side modification needed')
          
        } else {
          console.warn('[StepSelectorController] Steps panel wrapper not found')
        }
      } else {
        console.warn('[StepSelectorController] Steps panel container (.w-1/4) not found')
      }
    })
    .catch((error) => {
      console.error('[StepSelectorController] ===== ERROR REFRESHING STEPS PANEL =====')
      console.error('[StepSelectorController] Error:', error)
      throw error // Re-throw so handleStatusUpdate can catch it
    })
    .finally(() => {
      controller._refreshingStepsPanel = false
      controller._refreshingStepsPanelPromise = null
    })

    this._refreshingStepsPanelPromise = refreshPromise
    return refreshPromise
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
    const rawCurrentStatus = currentBadge ? currentBadge.textContent.toLowerCase().trim() : null
    const currentStatus = this.normalizeStatusName(rawCurrentStatus)
    console.log('[StepSelectorController] Current badge status:', currentStatus)

    // Determine status from data
    let status = 'not_started'
    
    // Check if this is the parsing step and we have parsing_status
    if (data.parsing_status && dataStepIdNum === stepIdNum) {
      status = this.normalizeStatusName(data.parsing_status)
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
        status = 'success'
      } else if (data.h_nber_analyses[1] > 0) {
        status = 'pending'
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
    
    // Check if status changed to success or failed, and if this is the currently displayed step
    const statusChanged = currentStatus !== status
    const isCurrentStep = this.currentStepId && (this.currentStepId.toString() === stepId.toString())
    const sameStepLoadInFlight =
      this._pendingLoadStepId &&
      this._pendingLoadStepId.toString() === stepId.toString()
    const isParsingStatusPayload = !!data.parsing_status
    const shouldReload =
      statusChanged &&
      isCurrentStep &&
      !this._isBootstrapping &&
      !sameStepLoadInFlight &&
      !isParsingStatusPayload &&
      (status === 'success' || status === 'failed')
    
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
      const statusConfig = this.getStatusIconConfig(status)
      if (statusConfig) {
        const spinClass = status === 'running' && statusConfig.icon_spin ? ' ' + statusConfig.icon_spin : ''
        iconElement.className = statusConfig.icon_base + spinClass + ' text-lg ' + statusConfig.active_color
      } else {
        iconElement.className = 'far fa-circle text-lg opacity-30'
      }
    }

    // Update the status badge
    let badgeElement = stepElement.querySelector('.inline-flex.items-center')
    if (!badgeElement) {
      // Create badge if it doesn't exist
      let badgeContainer = stepElement.querySelector('.flex-grow .mt-2')
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
    const statusConfig = this.getStatusIconConfig(status)
    return statusConfig?.color || 'gray'
  }

  humanizeStatus(status) {
    if (!status) return ''
    const statusConfig = this.getStatusIconConfig(status)
    if (statusConfig?.label) return statusConfig.label
    return status.charAt(0).toUpperCase() + status.slice(1)
  }

  normalizeStatusName(status) {
    const normalized = (status || '').toString().toLowerCase().trim()
    if (!normalized) return normalized

    // Canonicalize status names so equivalent labels do not trigger fake transitions.
    if (normalized === 'complete' || normalized === 'completed') return 'success'
    if (normalized === 'waiting' || normalized === 'queued' || normalized === 'queue') return 'pending'
    if (normalized === 'error') return 'failed'

    return normalized
  }

  debugCallOrigin() {
    try {
      return (new Error().stack || '')
        .split('\n')
        .slice(2, 6)
        .map((line) => line.trim())
        .join(' | ')
    } catch (_e) {
      return 'stack_unavailable'
    }
  }

  selectFirstAvailableStep() {
    // Find the first available step (not disabled)
    const firstStep = this.element.querySelector('[data-step-id]:not(.disabled)')
    if (firstStep) {
      const stepId = firstStep.getAttribute('data-step-id')
      // Set currentStepId before loading
      this.currentStepId = stepId.toString()
      this.element.setAttribute('data-current-step-id', stepId.toString())
      // Save state to localStorage for when user returns from visualization view
      this.saveState(stepId, 'step', null)
      // Load step results
      this.loadStepResults(stepId, firstStep, true, '', 'selectFirstAvailableStep')
      return true
    }
    return false
  }

  selectStep(event) {
    const stepElement = event.currentTarget
    const stepId = stepElement.getAttribute('data-step-id')
    
    // Don't proceed if step is disabled or locked
    if (stepElement.classList.contains('disabled') || stepElement.getAttribute('data-step-locked') === 'true') {
      event.preventDefault()
      event.stopPropagation()
      return false
    }
    
    // Update currentStepId
    this.currentStepId = stepId.toString()
    this.element.setAttribute('data-current-step-id', stepId.toString())
    
    // Save state to localStorage for when user returns from visualization view
    this.saveState(stepId, 'step', null)
    
    // Update dropdown element's data-selected-step-id attribute
    const dropdownElement = document.querySelector('[data-controller~="dropdown"]')
    if (dropdownElement) {
      dropdownElement.setAttribute('data-selected-step-id', stepId.toString())
    }
    
    // Update dropdown button if it exists
    this.updateDropdownButton(stepElement)
    
    // Update selected step in dropdown list
    this.updateDropdownListSelection(stepId)

    // If graph mode is active, keep graph view and only update node highlighting
    if (this.isGraphModeActive()) {
      this.refreshStepsPanel('selectStep:graph_mode')
      if (typeof window.updatePipelineGraphStepHighlight === 'function') {
        window.updatePipelineGraphStepHighlight(stepId)
      }
      if (typeof window.updateAnalysisLoomFilterWarning === 'function') {
        window.updateAnalysisLoomFilterWarning()
      }
      return
    }

    this.loadStepResults(stepId, stepElement, true, '', 'selectStep')
  }

  selectStepFromDropdown(event) {
    const selectElement = event.currentTarget
    const stepId = selectElement.value
    
    if (!stepId) {
      return
    }
    
    // Update currentStepId
    this.currentStepId = stepId.toString()
    this.element.setAttribute('data-current-step-id', stepId.toString())
    
    // Save state to localStorage for when user returns from visualization view
    this.saveState(stepId, 'step', null)
    
    // Update dropdown element's data-selected-step-id attribute
    const dropdownElement = document.querySelector('[data-controller~="dropdown"]')
    if (dropdownElement) {
      dropdownElement.setAttribute('data-selected-step-id', stepId.toString())
    }
    
    // Find or create a step element for compatibility with loadStepResults
    let stepElement = document.querySelector(`[data-step-id="${stepId}"]`)
    if (!stepElement) {
      // Create a temporary element if not found (for dropdown usage)
      stepElement = { getAttribute: () => stepId }
    }

    // Update dropdown button if it exists
    if (stepElement && stepElement.nodeType === 1) {
      this.updateDropdownButton(stepElement)
    }

    // If graph mode is active, keep graph view and only update node highlighting
    if (this.isGraphModeActive()) {
      this.refreshStepsPanel('selectStepFromDropdown:graph_mode')
      if (typeof window.updatePipelineGraphStepHighlight === 'function') {
        window.updatePipelineGraphStepHighlight(stepId)
      }
      if (typeof window.updateAnalysisLoomFilterWarning === 'function') {
        window.updateAnalysisLoomFilterWarning()
      }
      return
    }

    this.loadStepResults(stepId, stepElement, true, '', 'selectStepFromDropdown')
  }

  isGraphModeActive() {
    const graphToggleButton = document.getElementById('analysis-pipeline-toggle-button')
    return !!(graphToggleButton && graphToggleButton.dataset && graphToggleButton.dataset.mode === 'details')
  }

  updateDropdownButton(stepElement) {
    // Find the dropdown button (only visible on narrow screens)
    const dropdownContainer = document.querySelector('[data-controller~="dropdown"]')
    if (!dropdownContainer) return
    
    const button = dropdownContainer.querySelector('[data-dropdown-target="button"]')
    if (!button) return
    
    // Get step info from the step element
    const stepName = stepElement.querySelector('strong')?.textContent?.trim() || 'Unknown Step'
    
    // Get icon and status from the step element
    const iconElement = stepElement.querySelector('i')
    const iconClass = iconElement ? iconElement.className : 'far fa-circle text-base text-gray-400'
    
    // Get text color class
    const textColorClass = stepElement.classList.contains('text-gray-500') ? 'text-gray-500' :
                          stepElement.classList.contains('text-green-600') ? 'text-green-600' :
                          'text-gray-900'
    
    // Add blue left border to button (since this step is selected)
    button.style.borderLeft = '4px solid #007bff'
    button.style.setProperty('border-left', '4px solid #007bff', 'important')
    
    // Update button content
    const buttonContent = button.querySelector('.flex.items-center')
    if (buttonContent) {
      buttonContent.innerHTML = `
        <div class="flex-shrink-0 mr-3 w-5 flex items-center justify-center">
          <i class="${iconClass}"></i>
        </div>
        <span class="${textColorClass} font-semibold truncate">
          ${stepName}
        </span>
      `
    }
  }

  updateDropdownListSelection(stepId) {
    // Find all step items in the dropdown list
    const dropdownContainer = document.querySelector('[data-controller~="dropdown"]')
    if (!dropdownContainer) return
    
    const menu = dropdownContainer.querySelector('[data-dropdown-target="menu"]')
    if (!menu) return
    
    // Remove blue border from all items
    const allStepItems = menu.querySelectorAll('[data-step-id]')
    allStepItems.forEach(item => {
      item.style.borderLeft = '4px solid transparent'
    })
    
    // Add blue border to the selected step
    const selectedItem = menu.querySelector(`[data-step-id="${stepId}"]`)
    if (selectedItem) {
      selectedItem.style.borderLeft = '4px solid #007bff'
    }
  }

  loadStepResults(stepId, stepElement, showLoading = true, extraQuery = '', source = 'unknown') {
    console.log('[StepSelectorController] ===== LOADING STEP RESULTS =====')
    const callId = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    console.log('[StepSelectorController][trace] loadStepResults called:', {
      callId,
      source,
      stepId,
      showLoading,
      extraQuery,
      currentStepIdBefore: this.currentStepId,
      dataCurrentStepIdBefore: this.element.getAttribute('data-current-step-id'),
      origin: this.debugCallOrigin()
    })
    console.log('[StepSelectorController] Step ID:', stepId, 'type:', typeof stepId)
    console.log('[StepSelectorController] Step Element:', stepElement)
    console.log('[StepSelectorController] Show Loading:', showLoading)
    console.log('[StepSelectorController][debug] extraQuery:', extraQuery)
    console.log('[StepSelectorController] Previous currentStepId:', this.currentStepId)
    
    // Track current step (ensure it's stored as string for consistency)
    // Store the stepId in a closure to preserve it
    const stepIdString = stepId ? stepId.toString() : null
    this.currentStepId = stepIdString
    this.element.setAttribute('data-current-step-id', stepIdString)
    this._pendingLoadStepId = stepIdString
    console.log('[StepSelectorController] New currentStepId:', this.currentStepId, 'type:', typeof this.currentStepId)
    console.log('[StepSelectorController] Stored stepIdString:', stepIdString)
    
    // Save state to localStorage for when user returns from visualization view
    this.saveState(stepId, 'step', null)
    
    // Avoid forcing a steps-panel refresh here: it causes a second visible redraw.
    // Steps panel refresh is triggered by explicit flows (selection/graph/websocket sync).
    
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
    let query = `step_id=${encodeURIComponent(stepId)}&_t=${cacheBuster}`
    if (extraQuery) {
      if (extraQuery.startsWith('&')) {
        query += extraQuery
      } else {
        query += `&${extraQuery}`
      }
    }
    if (this.hasLoomFileValue && this.loomFileValue && !query.includes('loom_file=')) {
      query += `&loom_file=${encodeURIComponent(this.loomFileValue)}`
    }
    const url = `/projects/${this.projectIdentifier}/step_results.html?${query}`
    console.log('[StepSelectorController] Fetching URL:', url)
    
    // Store controller reference and stepId to preserve in promise chain
    const controller = this
    this._stepResultsRequestSeq = (this._stepResultsRequestSeq || 0) + 1
    const requestSeq = this._stepResultsRequestSeq
    window.__analysisRightPanelRequestSeq = (window.__analysisRightPanelRequestSeq || 0) + 1
    const panelRequestSeq = window.__analysisRightPanelRequestSeq
    
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
      // Ignore stale responses from older requests to prevent UI flashing/reverts.
      if (requestSeq !== controller._stepResultsRequestSeq || panelRequestSeq !== window.__analysisRightPanelRequestSeq) {
        console.log('[StepSelectorController] Ignoring stale step results response for step:', stepId)
        return
      }
      console.log('[StepSelectorController] Response text received, length:', html ? html.length : 0, 'callId:', callId)
      console.log('[StepSelectorController] ===== STEP RESULTS LOADED =====', 'callId:', callId)
      console.log('[StepSelectorController] HTML length:', html.length)
      console.log('[StepSelectorController] HTML preview (first 500 chars):', html.substring(0, 500))
      controller._lastLoadedStepId = stepIdString
      controller._lastStepResultsLoadedAt = Date.now()
      controller._hasLoadedInitialStep = true
      controller._isBootstrapping = false
      if (controller._pendingLoadStepId && controller._pendingLoadStepId.toString() === stepIdString.toString()) {
        controller._pendingLoadStepId = null
      }
      
      // Check if queue-position controller is in the HTML
      if (html.includes('queue-position')) {
        console.log('[StepSelectorController] ✓ Found "queue-position" in HTML')
        // Try to find the exact element
        const tempDiv = document.createElement('div')
        tempDiv.innerHTML = html
        const queuePositionElements = tempDiv.querySelectorAll('[data-controller*="queue-position"]')
        console.log('[StepSelectorController] Found', queuePositionElements.length, 'elements with queue-position controller in HTML')
        queuePositionElements.forEach((el, idx) => {
          console.log(`[StepSelectorController] Queue position element ${idx + 1}:`, {
            dataController: el.getAttribute('data-controller'),
            runId: el.getAttribute('data-queue-position-run-id-value'),
            slurmJobId: el.getAttribute('data-queue-position-slurm-job-id-value'),
            projectId: el.getAttribute('data-queue-position-project-id-value'),
            hasPositionTarget: el.querySelector('[data-queue-position-target="position"]') ? 'yes' : 'no',
            hasQueueInfoTarget: el.querySelector('[data-queue-position-target="queueInfo"]') ? 'yes' : 'no',
            hasEmptyQueueTarget: el.querySelector('[data-queue-position-target="emptyQueue"]') ? 'yes' : 'no'
          })
        })
      } else {
        console.log('[StepSelectorController] ✗ "queue-position" NOT found in HTML')
      }
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
      
      // Simple approach: Just insert the HTML directly
      console.log('[StepSelectorController] Inserting HTML into content target')
      // Ensure content target is properly constrained before inserting content
      controller.contentTarget.style.width = '100%'
      controller.contentTarget.style.maxWidth = '100%'
      controller.contentTarget.style.minWidth = '0'
      controller.contentTarget.style.overflowX = 'hidden'
      controller.contentTarget.style.boxSizing = 'border-box'
      controller.contentTarget.innerHTML = html
      
      // Execute inline scripts that were inserted via innerHTML
      controller._executeInlineScripts()
      
      // Trigger Stimulus to scan for new controllers
      if (window.Stimulus && window.Stimulus.router) {
        console.log('[StepSelectorController] Triggering Stimulus scan for new controllers...')
        try {
          setTimeout(() => {
            if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
              console.log('[StepSelectorController] Calling Stimulus router.scan()')
              window.Stimulus.router.scan()
            }
          }, 0)
          
          setTimeout(() => {
            if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
              console.log('[StepSelectorController] Calling second Stimulus router.scan()')
              window.Stimulus.router.scan()
            }
          }, 100)
        } catch (e) {
          console.warn('[StepSelectorController] Error triggering Stimulus scan:', e)
        }
      }
      
      // UI updates
      console.log('[StepSelectorController] Applying UI updates (showing content, hiding loading/empty states)')
      if (controller.hasLoadingStateTarget) {
        controller.loadingStateTarget.style.display = 'none'
      }
      if (controller.hasEmptyStateTarget) {
        controller.emptyStateTarget.style.display = 'none'
      }
      controller.contentTarget.style.display = 'block'
      if (typeof window.setPipelineHeaderButtonMode === 'function') {
        window.setPipelineHeaderButtonMode('graph')
      }
      
      // Log information about controllers in the loaded content for debugging
      // Stimulus's MutationObserver should automatically detect and connect them
      if (typeof window !== 'undefined' && window.Stimulus) {
        // Function to check and log controller status
        const checkControllerStatus = (delay = 0) => {
          setTimeout(() => {
            const elementsWithControllers = controller.contentTarget.querySelectorAll('[data-controller]')
            console.log(`[StepSelectorController] Checking controller status (delay: ${delay}ms), found ${elementsWithControllers.length} elements with data-controller`)
            
            if (elementsWithControllers.length === 0) {
              console.log('[StepSelectorController] No elements with data-controller found in loaded content')
              return
            }
            
            elementsWithControllers.forEach((element, index) => {
              const controllerNames = element.getAttribute('data-controller').split(' ').filter(name => name.trim())
              console.log(`[StepSelectorController] Element ${index + 1}: data-controller="${element.getAttribute('data-controller')}"`)
              
              // Log all data attributes for debugging
              const dataAttributes = Array.from(element.attributes)
                .filter(attr => attr.name.startsWith('data-'))
                .map(attr => `${attr.name}="${attr.value}"`)
              console.log(`[StepSelectorController] Element ${index + 1} data attributes:`, dataAttributes)
              
              controllerNames.forEach((controllerName) => {
                try {
                  // Check if controller is connected
                  const connectedController = window.Stimulus.getControllerForElementAndIdentifier(element, controllerName.trim())
                  if (!connectedController) {
                    console.log(`[StepSelectorController] Controller "${controllerName.trim()}" NOT connected yet (delay: ${delay}ms)`)
                  } else {
                    console.log(`[StepSelectorController] Controller "${controllerName.trim()}" IS connected (delay: ${delay}ms)`)
                    
                    // For queue-position, log detailed information
                    if (controllerName.trim() === 'queue-position') {
                      console.log('[StepSelectorController] Queue position controller details:', {
                        runId: connectedController.runIdValue,
                        slurmJobId: connectedController.slurmJobIdValue,
                        projectId: connectedController.projectIdValue,
                        hasPositionTarget: connectedController.hasPositionTarget,
                        hasQueueInfoTarget: connectedController.hasQueueInfoTarget,
                        hasEmptyQueueTarget: connectedController.hasEmptyQueueTarget,
                        pollInterval: connectedController.pollInterval ? 'active' : 'not set'
                      })
                      
                      // Check if targets exist in DOM
                      if (connectedController.hasPositionTarget) {
                        console.log('[StepSelectorController] Position target element:', connectedController.positionTarget)
                        console.log('[StepSelectorController] Position target content:', connectedController.positionTarget.innerHTML)
                      }
                      if (connectedController.hasQueueInfoTarget) {
                        console.log('[StepSelectorController] QueueInfo target element:', connectedController.queueInfoTarget)
                        console.log('[StepSelectorController] QueueInfo target classes:', connectedController.queueInfoTarget.className)
                      }
                      if (connectedController.hasEmptyQueueTarget) {
                        console.log('[StepSelectorController] EmptyQueue target element:', connectedController.emptyQueueTarget)
                        console.log('[StepSelectorController] EmptyQueue target classes:', connectedController.emptyQueueTarget.className)
                      }
                    }
                  }
                } catch (e) {
                  console.warn(`[StepSelectorController] Error checking controller "${controllerName.trim()}":`, e)
                }
              })
            })
          }, delay)
        }
        
        // Check multiple times with increasing delays to see when controllers connect
        checkControllerStatus(0)   // Immediate
        checkControllerStatus(50)  // After 50ms
        checkControllerStatus(100) // After 100ms
        checkControllerStatus(200) // After 200ms
        checkControllerStatus(500) // After 500ms
        checkControllerStatus(1000) // After 1 second (final check)
      }
      
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
      controller._hasLoadedInitialStep = true
      controller._isBootstrapping = false
      if (controller._pendingLoadStepId && stepIdString && controller._pendingLoadStepId.toString() === stepIdString.toString()) {
        controller._pendingLoadStepId = null
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

  // Update a specific run's status and time without reloading the whole panel
  updateRunStatus(runId) {
    console.log(`[StepSelectorController] Updating run status for run ${runId}`)
    
    if (!this.hasContentTarget) {
      console.warn('[StepSelectorController] No content target available for updating run status')
      return
    }
    
    const runRow = this.contentTarget.querySelector(`tr[data-run-id="${runId}"]`)
    if (!runRow) {
      console.warn(`[StepSelectorController] Run row not found for run ${runId}`)
      return
    }
    
    // Fetch updated run status from server
    fetch(`/projects/${this.projectIdentifier}/run_status?run_id=${runId}`, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.json()
    })
    .then(data => {
      console.log(`[StepSelectorController] Received run status for run ${runId}:`, data)
      this.updateRunStatusInDOM(runRow, data)
    })
    .catch(error => {
      console.error(`[StepSelectorController] Error fetching run status for run ${runId}:`, error)
    })
  }

  // Update the DOM for a specific run row with new status/time data
  updateRunStatusInDOM(runRow, data) {
    console.log(`[StepSelectorController] Updating DOM for run ${data.run_id} with status ${data.status_id}`)
    
    // Find status cell - it's the 4th td in the row
    const cells = runRow.querySelectorAll('td')
    const statusCell = cells[3] // 0-indexed, so 3 is the 4th column
    if (!statusCell) {
      console.warn('[StepSelectorController] Status cell not found in run row')
      return
    }
    
    // Update status badge
    const statusBadge = statusCell.querySelector('.inline-flex.items-center')
    if (statusBadge) {
      const statusConfig = this.getStatusConfig(data.status_id)
      statusBadge.className = `inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${statusConfig.bg} ${statusConfig.text}`
      statusBadge.textContent = data.status_name
      console.log(`[StepSelectorController] Updated status badge to: ${data.status_name}`)
    } else {
      console.warn('[StepSelectorController] Status badge not found')
    }
    
    // Update duration/timer section
    const durationContainer = statusCell.querySelector('.flex.flex-col.gap-1')
    if (durationContainer) {
      // First, disconnect any existing run-timer controllers before removing elements
      // Search for timer controllers in the entire status cell to catch nested ones
      const allTimerElements = statusCell.querySelectorAll('[data-controller*="run-timer"]')
      allTimerElements.forEach(el => {
        // Get the controller instance and disconnect it properly
        if (window.Stimulus) {
          try {
            const controller = window.Stimulus.getControllerForElementAndIdentifier(el, 'run-timer')
            if (controller && typeof controller.disconnect === 'function') {
              controller.disconnect()
              console.log(`[StepSelectorController] Disconnected run-timer controller for run ${data.run_id}`)
            }
          } catch (e) {
            // Controller might not be connected yet, that's okay
            console.log(`[StepSelectorController] Timer controller not found or already disconnected`)
          }
        }
      })
      
      // Remove all existing duration/timer elements (there might be multiple)
      // Remove elements that contain timers or are timer containers
      const existingDurations = durationContainer.querySelectorAll('.text-xs.text-gray-500.mt-0.5, .text-xs.text-gray-500.space-y-0.5, [data-controller*="run-timer"]')
      existingDurations.forEach(el => {
        el.remove()
      })
      
      // Also remove any queue-position controllers that might be in waiting status
      const queuePositionElements = durationContainer.querySelectorAll('[data-controller*="queue-position"]')
      queuePositionElements.forEach(el => {
        if (window.Stimulus) {
          try {
            const controller = window.Stimulus.getControllerForElementAndIdentifier(el, 'queue-position')
            if (controller && typeof controller.disconnect === 'function') {
              controller.disconnect()
            }
          } catch (e) {
            // Controller might not be connected, that's okay
          }
        }
        el.remove()
      })
      
      // Add new duration/timer based on status
      if (data.status_id === 3 && data.duration) {
        // Completed: show duration
        const durationDiv = document.createElement('div')
        durationDiv.className = 'text-xs text-gray-500 mt-0.5'
        durationDiv.innerHTML = `<i class="fas fa-clock text-gray-400 mr-1"></i><span>${this.formatDuration(data.duration)}</span>`
        durationContainer.appendChild(durationDiv)
        console.log(`[StepSelectorController] Added completed duration: ${this.formatDuration(data.duration)}`)
      } else if (data.status_id === 2 && data.start_time) {
        // Running: show live timer (will be updated by run-timer controller)
        const timerDiv = document.createElement('div')
        timerDiv.className = 'text-xs text-gray-500 mt-0.5'
        timerDiv.setAttribute('data-controller', 'run-timer')
        timerDiv.setAttribute('data-run-timer-start-time-value', data.start_time)
        timerDiv.innerHTML = `<i class="fas fa-clock text-gray-400 mr-1"></i><span data-run-timer-target="elapsedTime">--:--</span>`
        durationContainer.appendChild(timerDiv)
        console.log(`[StepSelectorController] Added running timer with start_time: ${data.start_time}`)
        
        // Trigger Stimulus to connect the new controller
        if (window.Stimulus && window.Stimulus.router) {
          setTimeout(() => {
            if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
              window.Stimulus.router.scan()
            }
          }, 0)
        }
      } else if (data.status_id === 1) {
        // Waiting: show waiting timer
        const waitingDiv = document.createElement('div')
        waitingDiv.className = 'text-xs text-gray-500 mt-0.5 space-y-0.5'
        
        if (data.submitted_at) {
          const timerDiv = document.createElement('div')
          timerDiv.setAttribute('data-controller', 'run-timer')
          timerDiv.setAttribute('data-run-timer-submitted-at-value', data.submitted_at)
          timerDiv.innerHTML = `<i class="fas fa-clock text-gray-400 mr-1"></i><span data-run-timer-target="elapsedTime">--:--</span>`
          waitingDiv.appendChild(timerDiv)
          console.log(`[StepSelectorController] Added waiting timer with submitted_at: ${data.submitted_at}`)
        }
        
        durationContainer.appendChild(waitingDiv)
        
        // Trigger Stimulus to connect the new controller
        if (window.Stimulus && window.Stimulus.router) {
          setTimeout(() => {
            if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
              window.Stimulus.router.scan()
            }
          }, 0)
        }
      }
    } else {
      console.warn('[StepSelectorController] Duration container not found')
    }
  }

  // Get status configuration for a status_id
  getStatusConfig(statusId) {
    switch(statusId) {
      case 1:
        return { name: 'Waiting', bg: 'bg-yellow-100', text: 'text-yellow-800' }
      case 2:
        return { name: 'Running', bg: 'bg-blue-100', text: 'text-blue-800' }
      case 3:
        return { name: 'Completed', bg: 'bg-green-100', text: 'text-green-800' }
      case 4:
        return { name: 'Failed', bg: 'bg-red-100', text: 'text-red-800' }
      default:
        return { name: 'Unknown', bg: 'bg-gray-100', text: 'text-gray-800' }
    }
  }

  // Format duration in seconds to HH:MM:SS or MM:SS
  formatDuration(seconds) {
    if (!seconds && seconds !== 0) return '0s'
    
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60
    
    if (hours > 0) {
      return `${hours}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`
    } else {
      return `${minutes}:${String(secs).padStart(2, '0')}`
    }
  }

  // Get status icon configuration by status name
  getStatusIconConfig(statusName) {
    if (!this.hasStatusIconsValue || !this.statusIconsValue) {
      console.error('[StepSelectorController] Status icons config not available - run the migration')
      return null
    }
    return this.statusIconsValue.find(s => s.key === statusName)
  }

  // Note: updateActiveStep is no longer needed - the server renders the border
  // This method is kept for backwards compatibility but does nothing
  // The border is now handled entirely by the server in _steps_panel.html.erb
  updateActiveStep(activeElement) {
    // Server handles border rendering, so this is a no-op
    // Kept for backwards compatibility in case any code still calls it
  }
}

