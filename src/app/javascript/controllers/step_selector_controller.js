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
  static targets = ["resultsContainer", "emptyState", "loadingState", "content", "stepsPanel", "stepHelpModal", "stepHelpTitle", "stepHelpBody"]
  static values = {
    projectId: Number,
    projectKey: String,
    statusIcons: Array,
    runStatusBadges: Object,
    loadRunPanel: Boolean,
    loadSubView: Boolean,
    subViewStepId: Number,
    loomFile: String
  }

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
    this._stepResultsRequestSeq = 0
    console.log('[StepSelectorController] Initial currentStepId set to:', this.currentStepId)
    this._refreshingStepsPanel = false
    this._refreshingStepsPanelPromise = null
    this.statusUpdateDebounceMs = 350
    this.pendingStatusByStepId = new Map()
    this.statusUpdateFlushTimer = null
    this._runStatusFetchSeqByRunId = new Map()
    this._initialPanelRevealDone = false
    this._pendingLoadStepId = null
    this._isBootstrapping = true
    this._hasLoadedInitialStep = false
    this._realtimeReloadCooldownUntil = Date.now() + 4000

    this.boundStepHelpCapture = this.onStepHelpCaptureClick.bind(this)
    this.element.addEventListener('click', this.boundStepHelpCapture, true)
    
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
    
      // Handle reset-parsing buttons in the right panel at capture phase,
      // so navigation is not swallowed by other click handlers.
      this.boundResetParsingClick = (event) => {
        const target = event.target instanceof Element ? event.target : null
        if (!target) return
        const button = target.closest('[data-reset-parsing-url]')
        if (!button) return

        const url = button.getAttribute('data-reset-parsing-url')
        if (!url) return

        event.preventDefault()
        event.stopPropagation()
        if (typeof event.stopImmediatePropagation === 'function') {
          event.stopImmediatePropagation()
        }
        window.location.assign(url)
      }
      document.addEventListener('click', this.boundResetParsingClick, true)

      // Subscribe to websocket updates for this project
      this.subscribeToProject()
      console.log('[StepSelectorController] Initial setup complete, currentStepId:', this.currentStepId)
    } catch (error) {
      console.error('[StepSelectorController] Error in connect():', error)
      console.error('[StepSelectorController] Error stack:', error.stack)
    }
  }

  disconnect() {
    this.clearStepPanelFlash()
    if (this.boundStepHelpCapture) {
      this.element.removeEventListener('click', this.boundStepHelpCapture, true)
      this.boundStepHelpCapture = null
    }
    this.closeStepHelp()
    if (this.statusUpdateFlushTimer) {
      clearTimeout(this.statusUpdateFlushTimer)
      this.statusUpdateFlushTimer = null
    }
    if (this.pendingStatusByStepId) {
      this.pendingStatusByStepId.clear()
    }
    if (this.boundResetParsingClick) {
      document.removeEventListener('click', this.boundResetParsingClick, true)
      this.boundResetParsingClick = null
    }
    this.unsubscribeFromProject()
  }

  onStepHelpCaptureClick(event) {
    const el = event.target
    if (!el || typeof el.closest !== 'function') return
    const trigger = el.closest('[data-step-help-trigger]')
    if (!trigger || !this.element.contains(trigger)) return
    event.stopPropagation()
    this.openStepHelp(trigger)
  }

  openStepHelp(trigger) {
    if (!this.hasStepHelpModalTarget || !this.hasStepHelpTitleTarget || !this.hasStepHelpBodyTarget) return

    const title = (trigger.dataset.stepHelpTitle || 'Step').trim()
    const available = trigger.dataset.stepHelpAvailable === 'true'
    const detail = (trigger.dataset.stepHelpDetail || '').trim()

    this.stepHelpTitleTarget.textContent = title
    this.fillStepHelpBody(available, detail)

    this.stepHelpModalTarget.classList.remove('hidden')
    document.body.classList.add('overflow-hidden')
  }

  fillStepHelpBody(available, detail) {
    const body = this.stepHelpBodyTarget
    while (body.firstChild) body.removeChild(body.firstChild)

    if (available) {
      const p = document.createElement('p')
      p.className = 'text-gray-700 m-0 leading-relaxed'
      p.textContent = 'All required inputs for this step are available. You can open it from the pipeline list.'
      body.appendChild(p)
      return
    }

    const intro = document.createElement('p')
    intro.className = 'text-gray-800 font-medium m-0 mb-3 leading-relaxed'
    intro.textContent = 'This step is not available yet because some inputs are still missing.'
    body.appendChild(intro)

    if (!detail) {
      const p = document.createElement('p')
      p.className = 'text-gray-600 m-0 leading-relaxed'
      p.textContent = 'No further detail is available. If this persists, try refreshing the page.'
      body.appendChild(p)
      return
    }

    const prefix = /^Missing inputs:\s*/i
    let remainder = detail
    if (prefix.test(detail)) {
      remainder = detail.replace(prefix, '').trim()
    }

    const parts = remainder.split(/\s*;\s*/).map((s) => s.trim()).filter(Boolean)
    if (parts.length <= 1) {
      const p = document.createElement('p')
      p.className = 'text-gray-700 m-0 leading-relaxed'
      p.textContent = remainder
      body.appendChild(p)
      return
    }

    const ul = document.createElement('ul')
    ul.className = 'list-disc pl-5 m-0 mt-2 space-y-2 text-gray-700 leading-relaxed'
    parts.forEach((part) => {
      const li = document.createElement('li')
      li.textContent = part
      ul.appendChild(li)
    })
    body.appendChild(ul)
  }

  closeStepHelp() {
    if (!this.hasStepHelpModalTarget) return
    this.stepHelpModalTarget.classList.add('hidden')
    document.body.classList.remove('overflow-hidden')
  }

  closeStepHelpOnEscape(event) {
    if (event.key !== 'Escape') return
    if (!this.hasStepHelpModalTarget || this.stepHelpModalTarget.classList.contains('hidden')) return
    event.preventDefault()
    this.closeStepHelp()
  }

  stopStepHelpPanelClick(event) {
    event.stopPropagation()
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
          console.log('[RSC.received] event=', data && data.event, 'has_run_status=', !!(data && data.run_status), 'step_id=', data && data.step_id)
          if (data && data.event === 'run_status_changed' && data.run_status) {
            this.applyRunStatusChange(data)
            return
          }
          this.scheduleStatusUpdate(data)
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
    if (!data) {
      return
    }

    const sid = data.step_id != null && data.step_id !== '' ? String(data.step_id) : null

    // Do not debounce terminal updates (completed/failed): they must be applied
    // immediately so left/right panels switch as soon as a step ends.
    const isTerminal = this.isTerminalStepUpdate(data)
    if (isTerminal) {
      if (this.statusUpdateFlushTimer) {
        clearTimeout(this.statusUpdateFlushTimer)
        this.statusUpdateFlushTimer = null
      }
      const pendingEntries = Array.from(this.pendingStatusByStepId.entries())
      this.pendingStatusByStepId.clear()
      pendingEntries.forEach(([key, payload]) => {
        if (sid && key === sid) {
          return
        }
        this.handleStatusUpdate(payload)
      })
      this.handleStatusUpdate(data)
      return
    }

    if (!sid) {
      this.handleStatusUpdate(data)
      return
    }

    const newTs = data.project_updated_at != null ? Number(data.project_updated_at) : null
    const prev = this.pendingStatusByStepId.get(sid)
    const prevTs = prev && prev.project_updated_at != null ? Number(prev.project_updated_at) : null
    if (prev && Number.isFinite(prevTs) && Number.isFinite(newTs) && newTs < prevTs) {
      return
    }

    this.pendingStatusByStepId.set(sid, data)

    if (this.statusUpdateFlushTimer) {
      clearTimeout(this.statusUpdateFlushTimer)
    }
    this.statusUpdateFlushTimer = setTimeout(() => {
      this.statusUpdateFlushTimer = null
      const batch = Array.from(this.pendingStatusByStepId.values())
      this.pendingStatusByStepId.clear()
      batch.forEach((payload) => {
        this.handleStatusUpdate(payload)
      })
    }, this.statusUpdateDebounceMs)
  }

  sumWebsocketStepRunCounts(data) {
    const counts = data && data.h_nber_analyses
    if (!counts || typeof counts !== 'object') return 0
    return Object.values(counts).reduce((sum, v) => sum + (parseInt(v, 10) || 0), 0)
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
        const running = parseInt(counts.running ?? 0, 10) || 0
        const success = parseInt(counts.success ?? 0, 10) || 0
        const failed = parseInt(counts.failed ?? 0, 10) || 0
        const isTerminal = running === 0 && (success > 0 || failed > 0)
        if (!isTerminal) return

        const sameStepLoadInFlight =
          this._pendingLoadStepId &&
          this._pendingLoadStepId.toString() === currentStepId.toString()
        if (sameStepLoadInFlight) return

        const sameStepJustLoaded =
          this._lastLoadedStepId &&
          this._lastLoadedStepId.toString() === currentStepId.toString() &&
          this._lastStepResultsLoadedAt &&
          (Date.now() - this._lastStepResultsLoadedAt) < 3000
        if (sameStepJustLoaded) return

        this.loadStepResults(currentStepId, currentStepEl, false)
      })
      .catch((error) => {
        console.warn('[StepSelectorController] reconcileCurrentStepOnConnect failed:', error)
      })
  }

  isTerminalStepUpdate(data) {
    if (!data) return false

    const parsingStatus = this.normalizeStatusName(data.parsing_status)
    if (this.isTerminalParsingStatus(parsingStatus)) {
      return true
    }

    if (parsingStatus && this.isParsingInProgressStatus(parsingStatus)) {
      return true
    }

    const counts = data.h_nber_analyses
    if (!counts) return false

    const pending = parseInt(counts[1] ?? counts['1'] ?? 0, 10) || 0
    const running = parseInt(counts[2] ?? counts['2'] ?? 0, 10) || 0
    const success = parseInt(counts[3] ?? counts['3'] ?? 0, 10) || 0
    const failed = parseInt(counts[4] ?? counts['4'] ?? 0, 10) || 0

    if (pending > 0 || running > 0) {
      return true
    }

    return pending === 0 && running === 0 && (success > 0 || failed > 0)
  }

  // Direct, push-based run status update path.
  //
  // Triggered by the server via the "run_status_changed" websocket event.
  // The payload carries both step-level counts (same shape as
  // ProjectBroadcastJob output, so the left panel icon and the page header
  // can be updated exactly like before) AND a run_status block with the
  // fields updateRunStatusInDOM needs, so we can update the specific run
  // row directly without a follow-up HTTP fetch. This replaces the
  // broadcast -> fetch /run_status?run_id=... roundtrip that was causing
  // the right panel to lag behind or miss updates.
  applyRunStatusChange(data) {
    console.log('[RSC.applyRunStatusChange] received', {
      bootstrapping: this._isBootstrapping,
      step_id: data && data.step_id,
      run_status: data && data.run_status,
      hasContentTarget: this.hasContentTarget
    })
    if (this._isBootstrapping) {
      console.log('[RSC.applyRunStatusChange] skip: bootstrapping')
      return
    }

    this.updateHeaderStatusSummary(data)

    const stepIdStr = data.step_id != null ? String(data.step_id) : null
    if (stepIdStr) {
      // Pass skipRightPanelReload=true because applyRunStatusChange below
      // already handles the right panel refresh authoritatively based on the
      // run_status payload (summary panel patch + loadRunInRightPanel, runs
      // table row in-place patch, or single-run intermediate-status reload).
      // updateStepStatusBadge's built-in success/failed -> loadStepResults
      // reload would otherwise trigger a second right-panel swap ~300ms
      // after our own reload, which is the "double refresh on success" the
      // user was seeing.
      this.refreshStepsPanel().then(() => {
        this.updateStepStatusBadge(stepIdStr, data, { skipRightPanelReload: true })
      }).catch(() => {
        this.updateStepStatusBadge(stepIdStr, data, { skipRightPanelReload: true })
      })
    }

    const runStatus = data.run_status
    if (!runStatus || runStatus.run_id == null || !this.hasContentTarget) {
      return
    }

    const runRow = this.contentTarget.querySelector(
      `tr[data-run-id="${runStatus.run_id}"]`
    )
    if (runRow) {
      this.updateRunStatusInDOM(runRow, runStatus)
    }

    // Decide how to refresh the right panel based on what it is currently
    // showing. Three mutually-exclusive cases:
    //
    // 1. #run_result_summary_panel for this run (single-run summary, the
    //    terminal-state "details" view rendered by runs/_panel.html.erb).
    //    -> patch the header status pill synchronously, then reload the full
    //       summary via loadRunInRightPanel so the body (metadata, figures,
    //       results) reflects the new state.
    //
    // 2. A runs table row for this run (multiple_runs step).
    //    -> updateRunStatusInDOM has already patched the row above; no panel
    //       reload is needed.
    //
    // 3. The single-run intermediate-status view (see
    //    projects/views/_single_run_intermediate_status.html.erb). That
    //    partial renders completely different markup for status_id 1/6
    //    ("waiting") vs 2 ("running"), and on terminal transitions the step
    //    switches to std_step entirely. There is no stable element to patch,
    //    so we reload the full step_results panel.
    const runSummaryPanel = this.contentTarget.querySelector('#run_result_summary_panel')
    const panelRunId = runSummaryPanel && runSummaryPanel.getAttribute('data-run-id')
    const panelMatchesRun = !!(runSummaryPanel && panelRunId && String(panelRunId) === String(runStatus.run_id))
    console.log('[RSC.applyRunStatusChange] panel lookup', {
      foundPanel: !!runSummaryPanel,
      panelRunId: panelRunId,
      foundRunRow: !!runRow,
      targetRunId: runStatus.run_id,
      match: panelMatchesRun
    })

    const currentStepIdNum = this.currentStepId ? parseInt(this.currentStepId) : null
    const runStepIdNum = runStatus.step_id != null ? parseInt(runStatus.step_id) : null
    const stepForPanel = currentStepIdNum || runStepIdNum

    if (panelMatchesRun) {
      this.updateRunSummaryPanelBadge(runSummaryPanel, runStatus)

      if (typeof loadRunInRightPanel === 'function') {
        // Fire the reload on the next tick (no long delay). The previous 150ms
        // window was large enough for other websocket events arriving in the
        // same burst (e.g. markers_run_status_changed) to clear this.reloadTimeout
        // via handleStatusUpdate before the reload actually executed, which is
        // why the right panel appeared to miss the waiting -> running
        // transition while terminal transitions still refreshed.
        clearTimeout(this.reloadTimeout)
        this.reloadTimeout = setTimeout(() => {
          console.log('[RSC.applyRunStatusChange] firing loadRunInRightPanel', {
            runId: runStatus.run_id,
            stepId: stepForPanel
          })
          loadRunInRightPanel(`/runs/${runStatus.run_id}`, String(stepForPanel))
        }, 0)
      } else {
        console.warn('[RSC.applyRunStatusChange] loadRunInRightPanel is NOT defined')
      }
      return
    }

    if (runRow) {
      // Row has been patched in-place; nothing else to do for this run.
      return
    }

    // Case 3: neither the summary panel nor a runs table row for this run is
    // on screen. That means the right panel is currently rendering
    // _single_run_intermediate_status (see
    // projects/views/_single_run_intermediate_status.html.erb), whose markup
    // differs between statuses 1/6 ("waiting") and 2 ("running"), and which
    // switches to the full run summary panel on terminal states (3/4).
    //
    // Transitions within intermediate states (e.g. 1/6 -> 2) require the
    // step_results view to be re-rendered because the partial itself changes.
    // For terminal transitions (2 -> 3 or 2 -> 4), the step now renders
    // _std_step whose only job is to auto-open the run summary panel via
    // loadRunInRightPanel; going through loadStepResults first would cost an
    // extra HTTP round-trip and an extra visible DOM swap for no benefit, so
    // we skip straight to loadRunInRightPanel.
    if (runStepIdNum && currentStepIdNum && runStepIdNum === currentStepIdNum) {
      const statusIdNum = runStatus.status_id != null ? parseInt(runStatus.status_id, 10) : null
      const isTerminalStatus = statusIdNum === 3 || statusIdNum === 4
      const stepEl = this.element.querySelector(`[data-step-id="${currentStepIdNum}"]`)

      clearTimeout(this.reloadTimeout)
      this.reloadTimeout = setTimeout(() => {
        if (isTerminalStatus && typeof loadRunInRightPanel === 'function') {
          console.log('[RSC.applyRunStatusChange] firing loadRunInRightPanel for terminal transition from intermediate status', {
            stepId: currentStepIdNum,
            runId: runStatus.run_id,
            statusId: statusIdNum
          })
          loadRunInRightPanel(`/runs/${runStatus.run_id}`, String(currentStepIdNum))
          return
        }
        console.log('[RSC.applyRunStatusChange] firing loadStepResults for intermediate status transition', {
          stepId: currentStepIdNum,
          runId: runStatus.run_id,
          statusId: statusIdNum
        })
        this.loadStepResults(currentStepIdNum, stepEl, false, '', 'run_status_changed')
      }, 0)
    }
  }

  // Update the status pill in the right-panel summary header directly from the
  // websocket payload. The pill lives inside the sticky header of
  // #run_result_summary_panel (see app/views/runs/_panel.html.erb) and is the
  // first span.inline-flex.rounded-full in that header. We keep this in sync
  // with the Tailwind classes used in the ERB so the transition is visible
  // without waiting for the full panel reload.
  updateRunSummaryPanelBadge(panel, runStatus) {
    if (!panel || !runStatus) return
    const header = panel.querySelector('.border-b')
    if (!header) return
    const badge = header.querySelector('span.rounded-full')
    if (!badge) return

    const cfg = this.getStatusConfig(runStatus.status_id)
    const baseClasses = 'inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium'
    badge.className = `${baseClasses} ${cfg.bg} ${cfg.text}`
    badge.textContent = runStatus.status_name || cfg.name
  }

  handleStatusUpdate(data) {
    if (this._isBootstrapping) {
      return
    }

    // Keep the top header status summary synchronized from the same websocket payload.
    // This avoids stale header icons when another controller misses an update.
    this.updateHeaderStatusSummary(data)
    this.forceRefreshParsingPanelOnTerminalStatus(data)

    // Check if right panel is displaying a form (new run form)
    const hasFormInRightPanel = this.hasContentTarget && this.contentTarget.querySelector('.std-form') !== null

    if (hasFormInRightPanel) {
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

    // Preserve currentStepId before refresh (it might get lost during DOM replacement)
    const preservedStepId = this.currentStepId || this.element.getAttribute('data-current-step-id')

    // Convert step_id to number for comparison
    const updateStepId = data.step_id ? parseInt(data.step_id) : null

    // Store websocket data to update badge after panel refresh (since DOM gets replaced)
    const websocketData = data

    // Always refresh the steps panel from the server to ensure consistency
    // After refresh completes, update the badge with websocket data
    this.refreshStepsPanel().then(() => {
      if (updateStepId && (websocketData.h_nber_analyses || websocketData.parsing_status)) {
        this.updateStepStatusBadge(updateStepId.toString(), websocketData)
      }
    }).catch((error) => {
      console.error('[StepSelectorController] Error refreshing steps panel:', error)
      if (updateStepId && (websocketData.h_nber_analyses || websocketData.parsing_status)) {
        this.updateStepStatusBadge(updateStepId.toString(), websocketData)
      }
    })

    // Restore currentStepId after refresh (DOM replacement might have cleared it)
    if (preservedStepId && !this.currentStepId) {
      this.currentStepId = preservedStepId
      this.element.setAttribute('data-current-step-id', preservedStepId)
    }

    const currentStepIdNum = this.currentStepId ? parseInt(this.currentStepId) : null

    // Update specific runs in the right panel if the update is for the currently displayed step
    // Instead of reloading the whole panel, only update status/time for runs that finished
    if (updateStepId && currentStepIdNum && updateStepId === currentStepIdNum) {
      // parsing_status is included on every project broadcast (see ProjectBroadcastJob#get_parsing_status).
      // Only treat non-terminal parsing_status as "parsing UI throttling" when the user is actually on
      // parsing content; otherwise we would skip run-panel refreshes for normalization and other steps.
      const parsingStatus = this.normalizeStatusName(data.parsing_status)
      const parsingInProgress = !!(parsingStatus && !this.isTerminalParsingStatus(parsingStatus))
      const stepNameLower = (data.step_name && String(data.step_name).toLowerCase()) || ''
      const parsingUiRelevant = this.hasContentTarget && (
        !!this.contentTarget.querySelector('[data-parsing-status-panel="true"]') ||
        stepNameLower === 'parsing'
      )

      if (parsingInProgress && parsingUiRelevant) {
        // Keep in-progress parsing lightweight, but force a reload when the current
        // panel still shows a failed state so failed -> waiting/running is visible.
        const parsingStatusPanel = this.contentTarget.querySelector('[data-parsing-status-panel="true"]')
        const shownStatusId = parsingStatusPanel ? parseInt(parsingStatusPanel.dataset.currentStatusId || '', 10) : null
        const isShowingFailedPanel = shownStatusId === 4

        if (isShowingFailedPanel && this.isParsingInProgressStatus(parsingStatus)) {
          const stepElForReload = this.element.querySelector(`[data-step-id="${this.currentStepId}"]`)
          clearTimeout(this.reloadTimeout)
          this.reloadTimeout = setTimeout(() => {
            if (stepElForReload) {
              this.loadStepResults(this.currentStepId, stepElForReload, false)
            }
          }, 300)
        }
      } else if (this.hasContentTarget) {
        const runRows = this.contentTarget.querySelectorAll('tr[data-run-id]')
        const runsToUpdate = []

        runRows.forEach(row => {
          const runId = parseInt(row.getAttribute('data-run-id'))
          runsToUpdate.push(runId)
        })

        if (runsToUpdate.length > 0) {
          runsToUpdate.forEach(runId => {
            this.updateRunStatus(runId)
          })
        } else if (runRows.length === 0 && this.contentTarget.innerHTML.trim().length > 0) {
          const runPanel = this.contentTarget.querySelector('#run_result_summary_panel')
          const panelRunId = runPanel && runPanel.getAttribute('data-run-id')
          const panelStepId = runPanel && runPanel.getAttribute('data-step-id')
          const panelStepNum = panelStepId ? parseInt(panelStepId, 10) : null
          const canonicalDetails = this._analysisCanonicalRunDetailsFromUrl()
          const canonicalRunPanel =
            typeof loadRunInRightPanel === 'function' &&
            canonicalDetails &&
            parseInt(canonicalDetails.stepId, 10) === currentStepIdNum &&
            this._analysisUriAllowsAutoOpenRunPanel()
          const panelRunIdToReload =
            (runPanel && panelRunId && panelStepNum === currentStepIdNum)
              ? panelRunId
              : (canonicalRunPanel ? canonicalDetails.runId : null)
          if (panelRunIdToReload) {
            clearTimeout(this.reloadTimeout)
            this.reloadTimeout = setTimeout(() => {
              if (typeof loadRunInRightPanel === 'function') {
                loadRunInRightPanel(`/runs/${panelRunIdToReload}`, String(currentStepIdNum))
              }
              this._syncHeaderRunCountsFromServer()
            }, 300)
          } else {
            const runsTotal = this.sumWebsocketStepRunCounts(data)
            const showingRunsEmptyState = !!this.contentTarget.querySelector('[data-step-runs-empty-state="true"]')
            if (runsTotal > 0 && showingRunsEmptyState) {
              const stepElForReload = this.element.querySelector(`[data-step-id="${this.currentStepId}"]`)
              if (stepElForReload) {
                clearTimeout(this.reloadTimeout)
                this.reloadTimeout = setTimeout(() => {
                  this.loadStepResults(this.currentStepId, stepElForReload, false)
                }, 300)
              }
            }
          }
        }
      }
    } else if (updateStepId && !currentStepIdNum) {
      if (Date.now() < this._realtimeReloadCooldownUntil) {
        return
      }
      // No step is currently selected, but we got an update for a step - select and load it
      const stepElement = this.element.querySelector(`[data-step-id="${updateStepId}"]`)
      if (stepElement) {
        this.currentStepId = updateStepId.toString()
        this.element.setAttribute('data-current-step-id', updateStepId.toString())
        clearTimeout(this.reloadTimeout)
        this.reloadTimeout = setTimeout(() => {
          this.loadStepResults(updateStepId, stepElement, true)
        }, 300)
      } else {
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
    }

    // Parsing terminal refresh is handled by forceRefreshParsingPanelOnTerminalStatus.
  }

  forceRefreshParsingPanelOnTerminalStatus(data) {
    if (!data) return
    const status = data.parsing_status
    const normalizedStatus = this.normalizeStatusName(status)
    const stepName = (data.step_name || '').toString().toLowerCase()
    if (stepName !== 'parsing') return
    if (!this.isTerminalParsingStatus(normalizedStatus)) return
    if (Date.now() < this._realtimeReloadCooldownUntil) return

    const stepId = data.step_id ? parseInt(data.step_id, 10) : null
    if (!stepId) return

    const stepElement = this.element.querySelector(`[data-step-id="${stepId}"]`)
    if (!stepElement) return

    const viewingStepIdStr = this.currentStepId || this.element.getAttribute('data-current-step-id')
    const viewingStepId = viewingStepIdStr ? parseInt(viewingStepIdStr, 10) : null
    if (!viewingStepId || viewingStepId !== stepId) return

    this.currentStepId = stepId.toString()
    this.element.setAttribute('data-current-step-id', this.currentStepId)

    clearTimeout(this.reloadTimeout)
    this.reloadTimeout = setTimeout(() => {
      this.loadStepResults(stepId, stepElement, false)
    }, 250)
  }

  _syncHeaderRunCountsFromServer() {
    const headerRoot = document.querySelector('[data-controller~="header-run-status"]')
    if (!headerRoot || !window.Stimulus) {
      return
    }
    const hc = window.Stimulus.getControllerForElementAndIdentifier(headerRoot, 'header-run-status')
    if (hc && typeof hc.syncCountsFromServer === 'function') {
      hc.syncCountsFromServer()
    }
  }

  updateHeaderStatusSummary(data) {
    const headerRoot = document.querySelector('[data-controller~="header-run-status"]')
    if (!headerRoot) return

    // project_run_totals in ActionCable payloads are full aggregates. Publication snapshot readers
    // (guests / non-owners on published projects) must use filtered counts from GET /run_counts;
    // applying broadcast totals here would flip the header between correct snapshot counts and full totals.
    if (headerRoot.getAttribute('data-header-run-status-publication-snapshot-value') === 'true') {
      return
    }

    const totals = data && data.project_run_totals
    if (!totals) {
      this._syncHeaderRunCountsFromServer()
      return
    }

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
        const label = iconEl?.dataset.uiLabel || statusKey
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

  _analysisUriAllowsAutoOpenRunPanel() {
    try {
      return new URLSearchParams(window.location.search).get('panel_mode') !== 'graph'
    } catch (_e) {
      return true
    }
  }

  // Canonical analysis URL: ?view=analysis&step_id=&run_id=&panel_mode=run_details (server redirect).
  _analysisCanonicalRunDetailsFromUrl() {
    try {
      const p = new URLSearchParams(window.location.search)
      if (p.get('panel_mode') !== 'run_details') {
        return null
      }
      const runId = p.get('run_id')
      const stepIdUrl = p.get('step_id')
      if (!runId || !stepIdUrl) {
        return null
      }
      if (!/^\d+$/.test(String(runId)) || !/^\d+$/.test(String(stepIdUrl))) {
        return null
      }
      return { runId: String(runId), stepId: String(stepIdUrl) }
    } catch (_e) {
      return null
    }
  }

  _analysisRestoreRunPanelFromCanonicalUrl(stepIdString, query) {
    if (typeof loadRunInRightPanel !== 'function') {
      return
    }
    if (!this._analysisUriAllowsAutoOpenRunPanel()) {
      return
    }
    if (!this._analysisStepQueryAllowsAutoOpenRunPanel(query)) {
      return
    }
    if (!this.hasContentTarget) {
      return
    }
    const canonical = this._analysisCanonicalRunDetailsFromUrl()
    if (!canonical || canonical.stepId !== String(stepIdString)) {
      return
    }
    if (this.contentTarget.querySelector('[data-analysis-auto-open-run-id]')) {
      return
    }

    this.contentTarget.innerHTML = ''
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.style.display = 'none'
    }
    if (this.hasLoadingStateTarget) {
      this.loadingStateTarget.style.display = 'block'
    }
    this.contentTarget.style.display = 'none'
    if (typeof window.setPipelineHeaderButtonMode === 'function') {
      window.setPipelineHeaderButtonMode('graph')
    }
    loadRunInRightPanel(`/runs/${canonical.runId}`, String(stepIdString))
  }

  _analysisStepQueryAllowsAutoOpenRunPanel(loadQuery) {
    return !(loadQuery && String(loadQuery).includes('prefer_runs_list'))
  }

  _extractAnalysisAutoOpenRunIdFromHtml(html) {
    if (!html || typeof html !== 'string') {
      return null
    }
    const m = html.match(/data-analysis-auto-open-run-id="(\d+)"/)
    return m ? m[1] : null
  }

  _analysisAutoOpenSingleRunAfterStepResults(stepIdString, loadQuery) {
    if (!this._analysisStepQueryAllowsAutoOpenRunPanel(loadQuery)) {
      return
    }
    if (typeof loadRunInRightPanel !== 'function' || !this.hasContentTarget) {
      return
    }
    const marker = this.contentTarget.querySelector('[data-analysis-auto-open-run-id]')
    if (!marker) {
      return
    }
    const autoRunId = marker.getAttribute('data-analysis-auto-open-run-id')
    if (!autoRunId) {
      return
    }

    if (!this._analysisUriAllowsAutoOpenRunPanel()) {
      return
    }

    const existingPanel = document.getElementById('run_result_summary_panel')
    const existingRunId = existingPanel && existingPanel.getAttribute('data-run-id')
    if (existingRunId && existingRunId === autoRunId) {
      return
    }

    loadRunInRightPanel(`/runs/${autoRunId}`, stepIdString)
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
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.text()
    })
    .then((html) => {
      // Find the steps panel container using the target or fallback to class selectors
      const stepsPanelContainer = controller.hasStepsPanelTarget
        ? controller.stepsPanelTarget
        : (controller.element.querySelector('.w-75') || controller.element.querySelector('.w-64') || controller.element.querySelector('.w-1\\/4'))
      if (stepsPanelContainer) {
        const panelWrapper = stepsPanelContainer.querySelector('.bg-white.rounded-lg.shadow-sm.border')
        if (panelWrapper) {
          const previousScrollContainer = panelWrapper.querySelector('.flex-1.overflow-y-auto')
          preservedScrollTop = previousScrollContainer ? previousScrollContainer.scrollTop : 0

          panelWrapper.innerHTML = html

          const refreshedScrollContainer = panelWrapper.querySelector('.flex-1.overflow-y-auto')
          if (refreshedScrollContainer) {
            refreshedScrollContainer.scrollTop = preservedScrollTop
          }

          const stepElements = panelWrapper.querySelectorAll('[data-step-id]')

          // Server has already rendered the border correctly based on selected_step_id;
          // strip legacy selected-state classes and re-attach listeners.
          stepElements.forEach((stepEl) => {
            stepEl.classList.remove('bg-blue-600')
            stepEl.style.backgroundColor = ''
            if (!stepEl.classList.contains('bg-white')) {
              stepEl.classList.add('bg-white')
            }
            const textElements = stepEl.querySelectorAll('strong, small, span:not(.badge)')
            textElements.forEach((el) => {
              el.classList.remove('text-white')
            })
          })

          stepElements.forEach((stepEl) => {
            if (!stepEl.classList.contains('disabled') && stepEl.getAttribute('data-step-locked') !== 'true') {
              stepEl.removeEventListener('click', controller.selectStep)
              stepEl.addEventListener('click', (e) => {
                controller.selectStep(e)
              })
            }
          })
        }
      }
    })
    .catch((error) => {
      console.error('[StepSelectorController] Error refreshing steps panel:', error)
      throw error
    })
    .finally(() => {
      controller._refreshingStepsPanel = false
      controller._refreshingStepsPanelPromise = null
    })

    this._refreshingStepsPanelPromise = refreshPromise
    return refreshPromise
  }

  updateStepStatusBadge(stepId, data, options = {}) {
    const rowSelector = `[data-step-id="${stepId}"]`
    const contentRoots = this.element.querySelectorAll('[data-step-selector-target="content"]')
    const isInsideContentTarget = (el) => {
      for (let i = 0; i < contentRoots.length; i++) {
        if (contentRoots[i].contains(el)) {
          return true
        }
      }
      return false
    }
    const stepElements = Array.from(this.element.querySelectorAll(rowSelector)).filter((el) => !isInsideContentTarget(el))
    if (stepElements.length === 0) {
      return
    }

    const primaryEl =
      (this.hasStepsPanelTarget && this.stepsPanelTarget.querySelector(rowSelector)) || stepElements[0]

    const stepNameLower = (primaryEl.getAttribute('data-step-name') || '').toString().toLowerCase()

    const stepIdNum = parseInt(stepId)
    const dataStepIdNum = data.step_id ? parseInt(data.step_id) : null

    const currentStatus = this.normalizeStatusName(primaryEl.getAttribute('data-step-status'))

    const nberCount = (h, statusId) => {
      if (!h || typeof h !== 'object') return 0
      const v = h[statusId] ?? h[String(statusId)]
      return parseInt(v, 10) || 0
    }

    let status = 'not_started'

    // parsing_status is merged into every project broadcast; only use it for the parsing row.
    if (data.parsing_status && stepNameLower === 'parsing' && dataStepIdNum === stepIdNum) {
      status = this.normalizeStatusName(data.parsing_status)
    } else if (data.h_nber_analyses && dataStepIdNum === stepIdNum) {
      const h = data.h_nber_analyses
      const hasRunning = nberCount(h, 2) > 0
      const hasComplete = nberCount(h, 3) > 0
      const hasFailed = nberCount(h, 4) > 0

      if (hasRunning) {
        status = 'running'
      } else if (hasFailed) {
        status = 'failed'
      } else if (hasComplete) {
        status = 'success'
      } else if (nberCount(h, 1) > 0) {
        status = 'pending'
      }
    }

    if (status === 'not_started') {
      return
    }

    const statusChanged = currentStatus !== status
    const isCurrentStep = this.currentStepId && (this.currentStepId.toString() === stepId.toString())
    const sameStepLoadInFlight =
      this._pendingLoadStepId &&
      this._pendingLoadStepId.toString() === stepId.toString()
    const isParsingStepBroadcast = stepNameLower === 'parsing' && dataStepIdNum === stepIdNum
    const shouldReload =
      !options.skipRightPanelReload &&
      statusChanged &&
      isCurrentStep &&
      !this._isBootstrapping &&
      !sameStepLoadInFlight &&
      !isParsingStepBroadcast &&
      (status === 'success' || status === 'failed')

    const stepElForReload =
      (this.hasStepsPanelTarget && this.stepsPanelTarget.querySelector(rowSelector)) || primaryEl

    stepElements.forEach((stepElement) => {
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

      const badgeElement = stepElement.querySelector('.inline-flex.items-center')
      if (badgeElement) {
        badgeElement.remove()
      }

      stepElement.setAttribute('data-step-status', status)
    })

    if (shouldReload) {
      clearTimeout(this.reloadTimeout)
      this.reloadTimeout = setTimeout(() => {
        this.loadStepResults(stepId, stepElForReload, false)
      }, 300)
    }
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

  isTerminalParsingStatus(status) {
    return status === 'success' || status === 'failed'
  }

  isParsingInProgressStatus(status) {
    return status === 'pending' || status === 'running'
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
    const lockDetail = (stepElement.dataset.stepLockDetail || '').trim()
    const lockAvail = stepElement.dataset.stepLockAvailable === 'true'
    
    const statusCol = stepElement.querySelector('.flex-shrink-0.mr-3')
    const iconElement = statusCol ? statusCol.querySelector('i') : stepElement.querySelector('i')
    const iconClass = iconElement ? iconElement.className : 'far fa-circle text-base text-gray-400'
    
    // Get text color class
    const textColorClass = stepElement.classList.contains('text-gray-500') ? 'text-gray-500' :
                          stepElement.classList.contains('text-green-600') ? 'text-green-600' :
                          'text-gray-900'
    
    const headerRow = dropdownContainer.firstElementChild
    if (headerRow && headerRow.classList.contains('flex')) {
      headerRow.style.setProperty('border-left', '4px solid #007bff', 'important')
    }
    button.style.removeProperty('border-left')

    let helpBtn = dropdownContainer.querySelector('[data-step-help-trigger]')
    if (lockAvail) {
      if (helpBtn) {
        helpBtn.remove()
        helpBtn = null
      }
    } else if (headerRow && button) {
      if (!helpBtn) {
        helpBtn = document.createElement('button')
        helpBtn.type = 'button'
        helpBtn.className = 'step-availability-help flex-shrink-0 w-10 flex items-center justify-center border-0 border-l border-gray-200 bg-white text-gray-600 hover:bg-gray-50 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-blue-500 cursor-pointer'
        helpBtn.setAttribute('data-step-help-trigger', '')
        helpBtn.setAttribute('title', 'Availability details')
        helpBtn.setAttribute('aria-label', 'Availability details for this step')
        helpBtn.innerHTML = '<span class="sr-only">Availability details</span><i class="far fa-question-circle text-base" aria-hidden="true"></i>'
        if (button.nextSibling) {
          headerRow.insertBefore(helpBtn, button.nextSibling)
        } else {
          headerRow.appendChild(helpBtn)
        }
      }
      helpBtn.setAttribute('data-step-help-available', 'false')
      helpBtn.setAttribute('data-step-help-title', stepName)
      helpBtn.setAttribute('data-step-help-detail', lockDetail)
    }

    const buttonContent = button.querySelector('.flex.items-center')
    if (buttonContent) {
      buttonContent.innerHTML = `
        <div class="flex-shrink-0 mr-3 w-5 flex items-center justify-center">
          <i class="${iconClass}"></i>
        </div>
        <span class="${textColorClass} font-semibold truncate">
          ${this.escapeForHtmlText(stepName)}
        </span>
      `
    }
  }

  escapeForHtmlAttribute(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/"/g, '&quot;')
      .replace(/</g, '&lt;')
      .replace(/\r?\n/g, ' ')
  }

  escapeForHtmlText(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
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

  clearStepPanelFlash() {
    const mount = this._stepResultsPanelFlashMount()
    if (mount) {
      mount.style.display = 'none'
      mount.setAttribute('hidden', '')
      mount.innerHTML = ''
    }
  }

  _stepResultsPanelFlashMount() {
    if (!this.hasContentTarget) return null
    return this.contentTarget.querySelector('[data-step-results-panel-flash-mount]')
  }

  showStepPanelFlashFromQuery(queryString) {
    if (!queryString) return
    const params = new URLSearchParams(queryString)
    const notice = params.get('notice') || params.get('errors')
    if (!notice || !String(notice).trim()) return

    const mount = this._stepResultsPanelFlashMount()
    if (!mount) return

    const text = this._escapeHtmlForPanelFlash(notice)
    mount.innerHTML =
      '<div class="flex items-start gap-3 px-3 py-2.5">' +
      '<span class="fas fa-exclamation-triangle text-amber-600 mt-0.5 flex-shrink-0" aria-hidden="true"></span>' +
      '<span class="leading-snug">' +
      text +
      '</span>' +
      '</div>'
    mount.removeAttribute('hidden')
    mount.style.display = 'block'
  }

  _escapeHtmlForPanelFlash(value) {
    const div = document.createElement('div')
    div.textContent = value == null ? '' : String(value)
    return div.innerHTML
  }

  loadStepResults(stepId, stepElement, showLoading = true, extraQuery = '', source = 'unknown') {
    this.clearStepPanelFlash()
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
    const canonicalForSave = this._analysisCanonicalRunDetailsFromUrl()
    const preserveRunInStorage =
      canonicalForSave &&
      canonicalForSave.stepId === String(stepIdString) &&
      this._analysisUriAllowsAutoOpenRunPanel() &&
      this._analysisStepQueryAllowsAutoOpenRunPanel(extraQuery) &&
      !String(extraQuery || '').includes('show_form') &&
      !String(extraQuery || '').includes('prefer_runs_list')
    if (preserveRunInStorage) {
      this.saveState(stepId, 'run', canonicalForSave.runId)
    } else {
      this.saveState(stepId, 'step', null)
    }
    
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
    const overlaySeqWhenStepFetchStarted = window.__analysisRightPanelOverlaySeq || 0

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
      // Do not share a single counter with loadRunInRightPanel: bumping on step_results start caused
      // every in-flight run panel fetch to be treated as stale. Only run/form bump overlaySeq; step
      // fetch records it and drops this HTML if a run/graph load started meanwhile.
      if (requestSeq !== controller._stepResultsRequestSeq) {
        return
      }
      if ((window.__analysisRightPanelOverlaySeq || 0) !== overlaySeqWhenStepFetchStarted) {
        return
      }
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
      
      controller.contentTarget.style.width = '100%'
      controller.contentTarget.style.maxWidth = '100%'
      controller.contentTarget.style.minWidth = '0'
      controller.contentTarget.style.overflowX = 'hidden'
      controller.contentTarget.style.boxSizing = 'border-box'

      const autoRunId = controller._extractAnalysisAutoOpenRunIdFromHtml(html)
      const allowAutoRunPanel =
        controller._analysisStepQueryAllowsAutoOpenRunPanel(query) &&
        controller._analysisUriAllowsAutoOpenRunPanel()
      const existingPanel = document.getElementById('run_result_summary_panel')
      const existingRunId = existingPanel && existingPanel.getAttribute('data-run-id')
      const canLoadRunPanel = typeof loadRunInRightPanel === 'function'

      if (autoRunId && allowAutoRunPanel && canLoadRunPanel) {
        if (existingRunId && existingRunId === autoRunId) {
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
          if (stepIdString && typeof controller.refreshStepsPanel === 'function') {
            controller.refreshStepsPanel()
          }
          controller.showStepPanelFlashFromQuery(query)
        } else {
          controller.contentTarget.innerHTML = ''
          if (controller.hasEmptyStateTarget) {
            controller.emptyStateTarget.style.display = 'none'
          }
          if (controller.hasLoadingStateTarget) {
            controller.loadingStateTarget.style.display = 'block'
          }
          controller.contentTarget.style.display = 'none'
          if (typeof window.setPipelineHeaderButtonMode === 'function') {
            window.setPipelineHeaderButtonMode('graph')
          }
          loadRunInRightPanel(`/runs/${autoRunId}`, stepIdString)
          controller.showStepPanelFlashFromQuery(query)
        }
      } else {
        console.log('[StepSelectorController] Inserting HTML into content target')
        controller.contentTarget.innerHTML = html

        controller._executeInlineScripts()

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

        controller._analysisAutoOpenSingleRunAfterStepResults(stepIdString, query)

        controller._analysisRestoreRunPanelFromCanonicalUrl(stepIdString, query)

        controller.showStepPanelFlashFromQuery(query)
      }

      const skippedStepHtmlForAutoRunPanel = Boolean(
        autoRunId && allowAutoRunPanel && canLoadRunPanel
      )
      if (skippedStepHtmlForAutoRunPanel) {
        console.log('[StepSelectorController] Content updated (run panel direct or kept)')
        console.log('[StepSelectorController] Final currentStepId:', controller.currentStepId)
      } else {
        if (typeof window !== 'undefined' && window.Stimulus) {
        // Log information about controllers in the loaded content for debugging
        // Stimulus's MutationObserver should automatically detect and connect them
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

          if (window.getComputedStyle(controller.contentTarget).display === 'none') {
            console.warn('[StepSelectorController] Content is still hidden! Forcing display block...')
            controller.contentTarget.style.display = 'block'
          }
        }
        console.log('[StepSelectorController] currentStepId AFTER update:', controller.currentStepId)
        console.log('[StepSelectorController] Data attribute value:', controller.element.getAttribute('data-current-step-id'))
        console.log('[StepSelectorController] Verifying currentStepId is still set correctly...')
        if (!controller.currentStepId && stepId) {
          console.warn('[StepSelectorController] WARNING: currentStepId was null, resetting to:', stepId)
          controller.currentStepId = stepId.toString()
          controller.element.setAttribute('data-current-step-id', stepId.toString())
        }
        console.log('[StepSelectorController] Final currentStepId:', controller.currentStepId)
      }
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

    const rid = String(runId)
    const nextSeq = (this._runStatusFetchSeqByRunId.get(rid) || 0) + 1
    this._runStatusFetchSeqByRunId.set(rid, nextSeq)
    const requestSeq = nextSeq

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
      if (this._runStatusFetchSeqByRunId.get(rid) !== requestSeq) {
        return
      }
      const row = this.contentTarget.querySelector(`tr[data-run-id="${runId}"]`)
      if (!row) {
        return
      }
      console.log(`[StepSelectorController] Received run status for run ${runId}:`, data)
      this.updateRunStatusInDOM(row, data)
    })
    .catch(error => {
      console.error(`[StepSelectorController] Error fetching run status for run ${runId}:`, error)
    })
  }

  // Update the DOM for a specific run row with new status/time data
  updateRunStatusInDOM(runRow, data) {
    console.log(`[StepSelectorController] Updating DOM for run ${data.run_id} with status ${data.status_id}`)
    
    // Status column index varies (e.g. clustering adds a column before status); use a stable marker from the template.
    const statusCell = runRow.querySelector('td[data-run-table-status-cell]')
    if (!statusCell) {
      console.warn('[StepSelectorController] Status cell not found in run row (missing data-run-table-status-cell)')
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

  // Run row badge label + classes from server (Status#ui_label + Tailwind).
  getStatusConfig(statusId) {
    const id = String(statusId)
    const map = this.runStatusBadgesValue
    const row = map && (map[id] || map[statusId])
    if (row && row.ui_label) {
      return { name: row.ui_label, bg: row.bg, text: row.text }
    }
    return { name: "Unknown", bg: "bg-gray-100", text: "text-gray-800" }
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

