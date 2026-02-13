import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Handles the compliance fix form:
// - Toggling field group actions (skip / map_from / set_value)
// - Updating hidden action inputs so the backend knows which action to apply
// - Previewing metadata values when selecting a source annotation
// - Ontology term autocomplete with paired field auto-fill
// - AJAX form submission with loading overlay and websocket updates
export default class extends Controller {
  static targets = [
    "fieldRow", "preview", "hiddenAction",
    "autocompleteInput", "autocompleteResults", "autocompleteWrapper",
    "selectedTerms", "termValue", "labelValue",
    "mapSelect", "mapBadges", "mapStatus",
    "mapFixPanel", "mapFixOriginal", "mapFixInput", "mapFixResults",
    "submitButton"
  ]
  static values = {
    metadataUrl: String,
    autocompleteUrl: String,
    resolveUrl: String,
    projectId: Number,
    resultUrl: String
  }

  connect() {
    this.previewCache = {}
    this.debounceTimers = {}
    this.selectedHighlight = -1
    // Per-group state for map-from paired resolution
    // { groupId: { selectedRole, pairedRole, sourcePath, prefixes, values, resolved } }
    this.mapResolveState = {}
    this.mapFixHighlight = -1
    this.subscription = null
    this.overlay = null

    // Close autocomplete and map fix dropdowns when clicking outside
    this.outsideClickHandler = (e) => {
      if (!e.target.closest('[data-compliance-fix-target="autocompleteWrapper"]')) {
        this.closeAllAutocomplete()
      }
      if (!e.target.closest('[data-compliance-fix-target="mapFixPanel"]')) {
        this.mapFixResultsTargets.forEach(el => el.classList.add('hidden'))
      }
    }
    document.addEventListener('click', this.outsideClickHandler)

    // Auto-trigger map source selects that are pre-selected (from prefill data)
    requestAnimationFrame(() => this.triggerPreselectedMapSources())
  }

  triggerPreselectedMapSources() {
    this.mapSelectTargets.forEach(select => {
      if (select.value) {
        select.dispatchEvent(new Event('change', { bubbles: true }))
      }
    })
  }

  disconnect() {
    document.removeEventListener('click', this.outsideClickHandler)
    Object.values(this.debounceTimers).forEach(t => clearTimeout(t))
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
    this.removeOverlay()
  }

  // ── Form submission with loading overlay ──

  async submitForm(event) {
    event.preventDefault()

    const form = event.target
    if (!form) return

    // Disable submit button
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
      this.submitButtonTarget.textContent = 'Applying...'
    }

    // Show loading overlay
    this.showOverlay('Applying fixes to LOOM files...')

    // Subscribe to websocket for real-time updates
    if (this.hasProjectIdValue && this.projectIdValue) {
      this.subscribeToCompliance(this.projectIdValue)
    }

    try {
      const formData = new FormData(form)
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || ''

      const response = await fetch(form.action, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Accept': 'application/json'
        },
        body: formData
      })

      const data = await response.json()

      if (data.status === 'error') {
        this.removeOverlay()
        if (this.hasSubmitButtonTarget) {
          this.submitButtonTarget.disabled = false
          this.submitButtonTarget.textContent = 'Apply to the LOOM file'
        }
        alert(data.message || 'An error occurred while applying fixes.')
        return
      }

      // Fixes applied, now waiting for validation via websocket
      this.updateOverlay(data.message || 'Fixes applied. Running validation...')

      // If the backend didn't trigger async validation and returned a redirect,
      // go there directly
      if (data.redirect_url && !data.validating) {
        window.location.href = data.redirect_url
      }

    } catch (error) {
      console.error('[ComplianceFix] Form submission error:', error)
      this.removeOverlay()
      if (this.hasSubmitButtonTarget) {
        this.submitButtonTarget.disabled = false
        this.submitButtonTarget.textContent = 'Apply to the LOOM file'
      }
      alert('An error occurred while applying fixes. Please try again.')
    }
  }

  subscribeToCompliance(projectId) {
    if (this.subscription) {
      this.subscription.unsubscribe()
    }

    if (!consumer || !consumer.subscriptions) {
      console.error('[ComplianceFix] ActionCable consumer not available')
      return
    }

    try {
      this.subscription = consumer.subscriptions.create(
        { channel: "ComplianceChannel", project_id: projectId },
        {
          connected: () => {
            console.log(`[ComplianceFix] Connected to ComplianceChannel for project ${projectId}`)
          },
          disconnected: () => {
            console.warn('[ComplianceFix] Disconnected from ComplianceChannel')
          },
          received: (data) => {
            console.log('[ComplianceFix] Received:', data)
            this.handleComplianceUpdate(data)
          }
        }
      )
    } catch (error) {
      console.error('[ComplianceFix] Error subscribing:', error)
    }
  }

  handleComplianceUpdate(data) {
    if (!data) return

    switch (data.status) {
      case 'applying':
        this.updateOverlay(data.message || 'Applying fixes...')
        break
      case 'validating':
        this.updateOverlay(data.message || 'Running compliance validation...')
        break
      case 'completed': {
        const resultUrl = this.hasResultUrlValue ? this.resultUrlValue : null
        if (data.valid) {
          this.updateOverlay('Validation passed. Redirecting...')
        } else {
          const count = data.errors_count || 0
          this.updateOverlay(`Validation complete (${count} error(s)). Redirecting...`)
        }
        // Redirect to the compliance result page
        setTimeout(() => {
          if (data.redirect_url) {
            window.location.href = data.redirect_url
          } else if (resultUrl) {
            window.location.href = resultUrl
          } else {
            window.location.reload()
          }
        }, 800)
        break
      }
      case 'failed':
        this.updateOverlay(`Validation failed: ${data.message || 'Unknown error'}. Redirecting...`)
        setTimeout(() => {
          const resultUrl = this.hasResultUrlValue ? this.resultUrlValue : null
          if (resultUrl) {
            window.location.href = resultUrl
          } else {
            window.location.reload()
          }
        }, 2000)
        break
    }
  }

  showOverlay(message) {
    this.removeOverlay()

    const overlay = document.createElement('div')
    overlay.id = 'compliance-fix-overlay'
    overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background-color:rgba(0,0,0,0.5);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;'
    overlay.innerHTML = `
      <div style="background:white;border-radius:12px;padding:32px 48px;text-align:center;max-width:480px;">
        <svg style="width:48px;height:48px;margin:0 auto 16px;color:#3b82f6;" viewBox="0 0 24 24" fill="none">
          <circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="2" opacity="0.2"/>
          <path d="M12 2a10 10 0 0 1 10 10" stroke="currentColor" stroke-width="2" stroke-linecap="round">
            <animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="1s" repeatCount="indefinite"/>
          </path>
        </svg>
        <p id="compliance-fix-overlay-msg" style="font-size:16px;font-weight:500;color:#1f2937;margin:0;">${this.escapeHtml(message)}</p>
        <p style="font-size:13px;color:#6b7280;margin-top:8px;">Please wait, this may take a few minutes for large datasets.</p>
      </div>
    `
    document.body.appendChild(overlay)
    this.overlay = overlay
  }

  updateOverlay(message) {
    const msgEl = document.getElementById('compliance-fix-overlay-msg')
    if (msgEl) {
      msgEl.textContent = message
    } else {
      // Overlay might not exist yet (e.g., websocket arrived before overlay was created)
      this.showOverlay(message)
    }
  }

  removeOverlay() {
    if (this.overlay) {
      this.overlay.remove()
      this.overlay = null
    }
    const existing = document.getElementById('compliance-fix-overlay')
    if (existing) existing.remove()
  }

  // ── Group action toggling ──

  toggleGroupAction(event) {
    const radio = event.target
    const groupId = radio.dataset.groupId
    const action = radio.value

    const mapPanel = document.getElementById(`map_from_${groupId}`)
    const valuePanel = document.getElementById(`set_value_${groupId}`)

    if (mapPanel) mapPanel.classList.toggle('hidden', action !== 'map_from')
    if (valuePanel) valuePanel.classList.toggle('hidden', action !== 'set_value')

    // Clean up resolve inputs and state when switching away from map_from
    if (action !== 'map_from' && mapPanel) {
      mapPanel.querySelectorAll(`[data-resolve-group="${groupId}"]`).forEach(el => el.remove())
      this.mapBadgesTargets.forEach(el => {
        if (el.dataset.groupId === groupId) el.innerHTML = ''
      })
      this.mapStatusTargets.forEach(el => {
        if (el.dataset.groupId === groupId) el.classList.add('hidden')
      })
      this.mapFixPanelTargets.forEach(el => {
        if (el.dataset.groupId === groupId) el.classList.add('hidden')
      })
      delete this.mapResolveState[groupId]
    }

    this.hiddenActionTargets.forEach(input => {
      if (input.dataset.groupId !== groupId) return

      if (action === 'skip') {
        input.value = 'skip'
      } else if (action === 'map_from') {
        input.value = 'map_from'
      } else if (action === 'set_value') {
        input.value = 'set_value'
      }
    })
  }

  // ── Metadata preview ──

  async previewSource(event) {
    const select = event.target
    const groupId = select.dataset.groupId
    const role = select.dataset.role
    const sourcePath = select.value
    const previewKey = `${groupId}_${role}`
    const previewEl = this.previewTargets.find(el => el.dataset.previewFor === previewKey)

    if (!sourcePath || !previewEl) {
      if (previewEl) previewEl.textContent = ''
      return
    }

    if (this.previewCache[sourcePath]) {
      previewEl.textContent = this.previewCache[sourcePath]
      return
    }

    previewEl.textContent = 'Loading...'

    try {
      const url = `${this.metadataUrlValue}?field_path=${encodeURIComponent(sourcePath)}`
      const response = await fetch(url, { headers: { 'Accept': 'application/json' } })

      if (response.ok) {
        const data = await response.json()
        const values = data.values || []
        const preview = values.length > 0
          ? `Values: ${values.slice(0, 5).join(', ')}${values.length > 5 ? '...' : ''} (${values.length} unique)`
          : 'No values found'
        this.previewCache[sourcePath] = preview
        previewEl.textContent = preview
      } else {
        previewEl.textContent = 'Could not load preview'
      }
    } catch (error) {
      previewEl.textContent = 'Could not load preview'
    }
  }

  // ── Map from existing metadata with paired resolution ──

  async onMapSourceSelect(event) {
    const select = event.target
    const groupId = select.dataset.groupId
    const selectedRole = select.dataset.role // "term" or "label"
    const pairedRole = selectedRole === 'term' ? 'label' : 'term'
    const prefixes = select.dataset.prefixes || ''
    const sourcePath = select.value

    // Get badge containers for both sides
    const thisBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === selectedRole
    )
    const pairedBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === pairedRole
    )
    const statusEl = this.mapStatusTargets.find(el => el.dataset.groupId === groupId)

    // Clear current badges
    if (thisBadgeEl) thisBadgeEl.innerHTML = ''
    if (pairedBadgeEl) pairedBadgeEl.innerHTML = ''
    if (statusEl) statusEl.classList.add('hidden')

    // Clear the paired select (since we're auto-resolving it)
    const pairedSelect = this.mapSelectTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === pairedRole
    )
    if (pairedSelect) pairedSelect.value = ''

    if (!sourcePath) return

    // Update hidden action inputs
    this.hiddenActionTargets.forEach(input => {
      if (input.dataset.groupId !== groupId) return
      if (input.dataset.role === `${selectedRole}_action`) {
        input.value = 'map_from'
      } else if (input.dataset.role === `${pairedRole}_action`) {
        input.value = 'resolve_paired'
      }
    })

    // Fetch unique values from the selected source metadata
    if (statusEl) {
      statusEl.textContent = 'Loading values...'
      statusEl.classList.remove('hidden')
    }

    try {
      const url = `${this.metadataUrlValue}?field_path=${encodeURIComponent(sourcePath)}`
      const response = await fetch(url, { headers: { 'Accept': 'application/json' } })
      if (!response.ok) {
        if (statusEl) statusEl.textContent = 'Failed to load metadata values'
        return
      }

      const data = await response.json()
      const values = data.values || []

      if (values.length === 0) {
        if (statusEl) statusEl.textContent = 'No values found in this metadata field'
        return
      }

      // Resolve paired values via ontology lookup
      if (statusEl) statusEl.textContent = 'Resolving paired values...'

      const resolveMode = selectedRole === 'term' ? 'by_identifier' : 'by_name'
      const resolveResponse = await fetch(this.resolveUrlValue, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''
        },
        body: new URLSearchParams({
          values: JSON.stringify(values),
          prefixes: prefixes,
          mode: resolveMode
        })
      })

      if (!resolveResponse.ok) {
        if (statusEl) statusEl.textContent = 'Failed to resolve paired values'
        return
      }

      const resolveData = await resolveResponse.json()
      const resolved = resolveData.resolved || {}
      const multiTermMap = resolveData.multi_term_map || {}

      // For array-formatted values that were resolved, auto-populate sourceRenames
      // so the source field will be rewritten from "['a','b']" to "a || b"
      const sourceRenames = {}
      for (const [original, joinedSource] of Object.entries(multiTermMap)) {
        sourceRenames[original] = joinedSource
      }

      // Store state for this group so the fix autocomplete can update it
      // sourceRenames tracks corrections to the source field itself (e.g., "T-cell" -> "T cell",
      // or "['FBbt:001','FBbt:002']" -> "FBbt:001 || FBbt:002")
      this.mapResolveState[groupId] = {
        selectedRole, pairedRole, sourcePath, prefixes, values, resolved,
        sourceRenames
      }

      // Render badges on both sides
      this.renderMapBadges(groupId)

      // Store the resolve map in a hidden input for form submission
      this.setResolveMapInput(groupId, pairedRole, sourcePath, resolved)

      // If array-formatted values were auto-converted, the source field also needs
      // a resolve_paired action to rewrite "['a','b']" -> "a || b"
      if (Object.keys(sourceRenames).length > 0) {
        this.updateSourceFieldAction(groupId)
      }

    } catch (error) {
      if (statusEl) {
        statusEl.textContent = 'Error loading or resolving values'
        statusEl.classList.remove('hidden')
      }
    }
  }

  setResolveMapInput(groupId, pairedRole, sourcePath, resolveMap) {
    // Get the paired field path from the badge container or the select
    const pairedBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === pairedRole
    )
    if (!pairedBadgeEl) return

    const fieldPath = pairedBadgeEl.dataset.fieldPath
    if (!fieldPath) return

    const mapPanel = document.getElementById(`map_from_${groupId}`)
    if (!mapPanel) return

    // Remove old resolve inputs for this group+role
    mapPanel.querySelectorAll(`[data-resolve-group="${groupId}"][data-resolve-role="${pairedRole}"]`).forEach(el => el.remove())

    // Create hidden input for source
    const sourceInput = document.createElement('input')
    sourceInput.type = 'hidden'
    sourceInput.name = `fixes[${fieldPath}][source]`
    sourceInput.value = sourcePath
    sourceInput.dataset.resolveGroup = groupId
    sourceInput.dataset.resolveRole = pairedRole
    mapPanel.appendChild(sourceInput)

    // Create hidden input for resolve_map
    const mapInput = document.createElement('input')
    mapInput.type = 'hidden'
    mapInput.name = `fixes[${fieldPath}][resolve_map]`
    mapInput.value = JSON.stringify(resolveMap)
    mapInput.dataset.resolveGroup = groupId
    mapInput.dataset.resolveRole = pairedRole
    mapPanel.appendChild(mapInput)
  }

  // When manual fixes rename source values, the source field can no longer use
  // plain "map_from" (which copies raw data). It must use "resolve_paired" with
  // a rename map so that e.g. "T-cell" becomes "T cell" in the LOOM file.
  updateSourceFieldAction(groupId) {
    const state = this.mapResolveState[groupId]
    if (!state) return

    const { selectedRole, sourceRenames, sourcePath } = state
    const hasRenames = Object.keys(sourceRenames).length > 0

    const sourceBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === selectedRole
    )
    if (!sourceBadgeEl) return

    const sourceFieldPath = sourceBadgeEl.dataset.fieldPath
    if (!sourceFieldPath) return

    // Update the hidden action input for the source field
    const actionRole = `${selectedRole}_action`
    this.hiddenActionTargets.forEach(input => {
      if (input.dataset.groupId !== groupId) return
      if (input.dataset.role === actionRole) {
        input.value = hasRenames ? 'resolve_paired' : 'map_from'
      }
    })

    const mapPanel = document.getElementById(`map_from_${groupId}`)
    if (!mapPanel) return

    // Remove old source resolve inputs
    mapPanel.querySelectorAll(`[data-resolve-group="${groupId}"][data-resolve-role="${selectedRole}"]`).forEach(el => el.remove())

    if (hasRenames) {
      // Create hidden inputs for resolve_paired on the source field
      const srcInput = document.createElement('input')
      srcInput.type = 'hidden'
      srcInput.name = `fixes[${sourceFieldPath}][source]`
      srcInput.value = sourcePath
      srcInput.dataset.resolveGroup = groupId
      srcInput.dataset.resolveRole = selectedRole
      mapPanel.appendChild(srcInput)

      const mapInput = document.createElement('input')
      mapInput.type = 'hidden'
      mapInput.name = `fixes[${sourceFieldPath}][resolve_map]`
      mapInput.value = JSON.stringify(sourceRenames)
      mapInput.dataset.resolveGroup = groupId
      mapInput.dataset.resolveRole = selectedRole
      mapPanel.appendChild(mapInput)
    }
  }

  // ── Badge rendering for map-from paired resolution ──

  renderMapBadges(groupId) {
    const state = this.mapResolveState[groupId]
    if (!state) return

    const { selectedRole, pairedRole, values, resolved, sourceRenames } = state

    const thisBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === selectedRole
    )
    const pairedBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === pairedRole
    )
    const statusEl = this.mapStatusTargets.find(el => el.dataset.groupId === groupId)

    // Clear current badges
    if (thisBadgeEl) thisBadgeEl.innerHTML = ''
    if (pairedBadgeEl) pairedBadgeEl.innerHTML = ''

    const resolvedCount = values.filter(v => resolved[v]).length
    const unresolvedValues = values.filter(v => !resolved[v])

    // Sort values: unresolved first, then resolved
    const sortedValues = [...unresolvedValues, ...values.filter(v => resolved[v])]

    // Display source values as badges
    // All badges are clickable (to allow replacing any term, even resolved ones)
    // - Gray: auto-resolved with no rename needed (source value matches ontology)
    // - Green/purple: resolved from array format (shows || separated values)
    // - Green: manually fixed (source value was renamed to the correct ontology term)
    // - Red: unresolved
    if (thisBadgeEl) {
      sortedValues.forEach(val => {
        const badge = document.createElement('span')
        const isResolved = !!resolved[val]
        const hasRename = !!sourceRenames[val]
        const isArrayFormat = val.startsWith('[') && val.endsWith(']')

        // All badges are clickable to allow corrections
        badge.dataset.action = 'click->compliance-fix#openMapFix'
        badge.dataset.groupId = groupId
        badge.dataset.originalValue = val

        if (isResolved && isArrayFormat) {
          // Multi-term value resolved from array format: show the || joined version in purple
          badge.className = 'inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-purple-100 text-purple-700 border border-purple-200 cursor-pointer hover:bg-purple-200'
          badge.innerHTML = `<s class="text-gray-400 text-[10px]">[...]</s> ${this.escapeHtml(sourceRenames[val])}`
          badge.title = `Original: ${val} -- click to change`
        } else if (isResolved && hasRename) {
          // Manually fixed: show the corrected value in green
          badge.className = 'inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-green-100 text-green-700 border border-green-200 cursor-pointer hover:bg-green-200'
          badge.innerHTML = `<s class="text-red-400 text-[10px]">${this.escapeHtml(val)}</s> ${this.escapeHtml(sourceRenames[val])}`
          badge.title = 'Click to change'
        } else if (isResolved) {
          // Auto-resolved: original value is valid, still clickable for corrections
          badge.className = 'inline-flex items-center px-2 py-0.5 text-xs rounded-full bg-gray-100 text-gray-700 border border-gray-200 cursor-pointer hover:bg-gray-200'
          badge.textContent = val
          badge.title = 'Click to change'
        } else {
          // Unresolved: red + clickable
          badge.className = 'inline-flex items-center px-2 py-0.5 text-xs rounded-full bg-red-100 text-red-700 border border-red-300 cursor-pointer hover:bg-red-200'
          badge.title = 'Click to fix this unresolved term'
          badge.textContent = val
        }
        badge.dataset.mapBadgeValue = val
        badge.dataset.mapBadgeRole = selectedRole
        thisBadgeEl.appendChild(badge)
      })
    }

    // Display paired values as badges (blue/purple if resolved, red if unresolved)
    // All badges are clickable to allow corrections
    if (pairedBadgeEl) {
      sortedValues.forEach(val => {
        const badge = document.createElement('span')
        const isArrayFormat = val.startsWith('[') && val.endsWith(']')

        // All paired badges are clickable
        badge.dataset.action = 'click->compliance-fix#openMapFix'
        badge.dataset.groupId = groupId
        badge.dataset.originalValue = val

        if (resolved[val]) {
          if (isArrayFormat) {
            // Multi-term resolved: purple badge with || separated names
            badge.className = 'inline-flex items-center px-2 py-0.5 text-xs rounded-full bg-purple-100 text-purple-700 border border-purple-200 cursor-pointer hover:bg-purple-200'
          } else {
            badge.className = 'inline-flex items-center px-2 py-0.5 text-xs rounded-full bg-blue-100 text-blue-700 border border-blue-200 cursor-pointer hover:bg-blue-200'
          }
          badge.textContent = resolved[val]
          badge.title = 'Click to change'
        } else {
          badge.className = 'inline-flex items-center px-2 py-0.5 text-xs rounded-full bg-red-100 text-red-700 border border-red-300 cursor-pointer hover:bg-red-200'
          badge.title = 'Click to fix this unresolved term'
          badge.textContent = `? (${val})`
        }
        badge.dataset.mapBadgeValue = val
        badge.dataset.mapBadgeRole = pairedRole
        pairedBadgeEl.appendChild(badge)
      })
    }

    // Show resolution status
    if (statusEl) {
      if (unresolvedValues.length > 0) {
        statusEl.textContent = `Resolved ${resolvedCount}/${values.length} values. ${unresolvedValues.length} unresolved (shown first in red). Click on red badges to fix them.`
        statusEl.className = 'text-xs text-amber-600 font-medium'
      } else {
        statusEl.textContent = `All ${resolvedCount} values resolved successfully.`
        statusEl.className = 'text-xs text-green-600 italic'
      }
      statusEl.classList.remove('hidden')
    }
  }

  // ── Inline fix autocomplete for unresolved map-from badges ──

  openMapFix(event) {
    const badge = event.currentTarget
    const groupId = badge.dataset.groupId
    const originalValue = badge.dataset.originalValue

    const fixPanel = this.mapFixPanelTargets.find(el => el.dataset.groupId === groupId)
    const fixOriginal = this.mapFixOriginalTargets.find(el => el.dataset.groupId === groupId)
    const fixInput = this.mapFixInputTargets.find(el => el.dataset.groupId === groupId)

    if (!fixPanel || !fixInput) return

    // Store which value we're fixing
    fixPanel.dataset.fixingValue = originalValue

    // Show the panel with the original value
    if (fixOriginal) fixOriginal.textContent = originalValue
    fixPanel.classList.remove('hidden')
    fixInput.value = ''
    fixInput.focus()
  }

  closeMapFix(event) {
    const groupId = event.currentTarget.dataset.groupId
    const fixPanel = this.mapFixPanelTargets.find(el => el.dataset.groupId === groupId)
    if (fixPanel) fixPanel.classList.add('hidden')
    this.hideMapFixResults(groupId)
  }

  onMapFixAutocomplete(event) {
    const input = event.target
    const groupId = input.dataset.groupId
    const query = input.value.trim()
    const timerKey = `mapfix_${groupId}`

    if (this.debounceTimers[timerKey]) clearTimeout(this.debounceTimers[timerKey])

    if (query.length < 2) {
      this.hideMapFixResults(groupId)
      return
    }

    this.debounceTimers[timerKey] = setTimeout(() => {
      this.fetchMapFixAutocomplete(groupId, query, input.dataset.prefixes)
    }, 250)
  }

  onMapFixKeydown(event) {
    const groupId = event.target.dataset.groupId
    const resultsEl = this.mapFixResultsTargets.find(el => el.dataset.groupId === groupId)
    if (!resultsEl || resultsEl.classList.contains('hidden')) return

    const items = resultsEl.querySelectorAll('[data-mapfix-item]')
    if (!items.length) return

    if (event.key === 'ArrowDown') {
      event.preventDefault()
      this.mapFixHighlight = Math.min(this.mapFixHighlight + 1, items.length - 1)
      this.highlightMapFixItem(items)
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      this.mapFixHighlight = Math.max(this.mapFixHighlight - 1, 0)
      this.highlightMapFixItem(items)
    } else if (event.key === 'Enter') {
      event.preventDefault()
      if (this.mapFixHighlight >= 0 && this.mapFixHighlight < items.length) {
        items[this.mapFixHighlight].click()
      }
    } else if (event.key === 'Escape') {
      this.hideMapFixResults(groupId)
    }
  }

  highlightMapFixItem(items) {
    items.forEach((item, i) => {
      item.classList.toggle('bg-blue-50', i === this.mapFixHighlight)
    })
    if (this.mapFixHighlight >= 0 && items[this.mapFixHighlight]) {
      items[this.mapFixHighlight].scrollIntoView({ block: 'nearest' })
    }
  }

  async fetchMapFixAutocomplete(groupId, query, prefixes) {
    const url = `${this.autocompleteUrlValue}?term=${encodeURIComponent(query)}&prefixes=${encodeURIComponent(prefixes)}`
    try {
      const response = await fetch(url, { headers: { 'Accept': 'application/json' } })
      if (!response.ok) return
      const data = await response.json()
      this.showMapFixResults(groupId, data.results || [], data.total_count || 0)
    } catch (error) {
      // silently fail
    }
  }

  showMapFixResults(groupId, results, totalCount) {
    const resultsEl = this.mapFixResultsTargets.find(el => el.dataset.groupId === groupId)
    if (!resultsEl) return

    this.mapFixHighlight = -1

    if (results.length === 0) {
      resultsEl.innerHTML = '<div class="px-3 py-2 text-sm text-gray-500">No results found</div>'
      resultsEl.classList.remove('hidden')
      return
    }

    const countInfo = totalCount > results.length
      ? `<div class="px-3 py-1.5 text-xs text-gray-400 bg-gray-50 border-b border-gray-100">Showing ${results.length} of ${totalCount} matches</div>`
      : `<div class="px-3 py-1.5 text-xs text-gray-400 bg-gray-50 border-b border-gray-100">${totalCount} match${totalCount !== 1 ? 'es' : ''}</div>`

    resultsEl.innerHTML = countInfo + results.map(r =>
      `<div data-mapfix-item
            data-identifier="${this.escapeHtml(r.identifier)}"
            data-name="${this.escapeHtml(r.name)}"
            data-group-id="${groupId}"
            data-action="click->compliance-fix#selectMapFixItem"
            class="px-3 py-2 text-sm cursor-pointer hover:bg-blue-50 border-b border-gray-100 last:border-0">
        <span class="font-mono text-blue-700">${this.escapeHtml(r.identifier)}</span>
        <span class="text-gray-500 ml-1">-</span>
        <span class="text-gray-800 ml-1">${this.escapeHtml(r.name)}</span>
      </div>`
    ).join('')

    resultsEl.classList.remove('hidden')
  }

  hideMapFixResults(groupId) {
    const resultsEl = this.mapFixResultsTargets.find(el => el.dataset.groupId === groupId)
    if (resultsEl) resultsEl.classList.add('hidden')
    this.mapFixHighlight = -1
  }

  selectMapFixItem(event) {
    const item = event.currentTarget
    const groupId = item.dataset.groupId
    const identifier = item.dataset.identifier
    const name = item.dataset.name

    const state = this.mapResolveState[groupId]
    if (!state) return

    // Find which original value we are fixing
    const fixPanel = this.mapFixPanelTargets.find(el => el.dataset.groupId === groupId)
    if (!fixPanel) return
    const originalValue = fixPanel.dataset.fixingValue

    // Update both maps: the paired resolve map AND the source-side rename map
    // Both sides must be coherent with the selected ontology term
    if (state.selectedRole === 'term') {
      // Source has identifiers -> paired gets names
      state.resolved[originalValue] = name
      // Source identifier also needs correcting to the selected identifier
      state.sourceRenames[originalValue] = identifier
    } else {
      // Source has names -> paired gets identifiers
      state.resolved[originalValue] = identifier
      // Source name also needs correcting to the selected ontology name
      state.sourceRenames[originalValue] = name
    }

    // Re-render badges (will show corrected values on both sides)
    this.renderMapBadges(groupId)

    // Update hidden inputs for both the paired field and the source field
    this.setResolveMapInput(groupId, state.pairedRole, state.sourcePath, state.resolved)
    this.updateSourceFieldAction(groupId)

    // Close the fix panel
    fixPanel.classList.add('hidden')
    this.hideMapFixResults(groupId)
  }

  // ── Ontology autocomplete ──

  onAutocompleteInput(event) {
    const input = event.target
    const groupId = input.dataset.groupId
    const query = input.value.trim()

    // Debounce: wait 250ms after last keystroke
    if (this.debounceTimers[groupId]) clearTimeout(this.debounceTimers[groupId])

    if (query.length < 2) {
      this.hideResults(groupId)
      return
    }

    this.debounceTimers[groupId] = setTimeout(() => {
      this.fetchAutocomplete(groupId, query, input.dataset.prefixes)
    }, 250)
  }

  onAutocompleteKeydown(event) {
    const groupId = event.target.dataset.groupId
    const resultsEl = this.getResultsEl(groupId)
    if (!resultsEl || resultsEl.classList.contains('hidden')) return

    const items = resultsEl.querySelectorAll('[data-autocomplete-item]')
    if (!items.length) return

    if (event.key === 'ArrowDown') {
      event.preventDefault()
      this.selectedHighlight = Math.min(this.selectedHighlight + 1, items.length - 1)
      this.highlightItem(items)
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      this.selectedHighlight = Math.max(this.selectedHighlight - 1, 0)
      this.highlightItem(items)
    } else if (event.key === 'Enter') {
      event.preventDefault()
      if (this.selectedHighlight >= 0 && this.selectedHighlight < items.length) {
        items[this.selectedHighlight].click()
      }
    } else if (event.key === 'Escape') {
      this.hideResults(groupId)
    }
  }

  highlightItem(items) {
    items.forEach((item, i) => {
      item.classList.toggle('bg-blue-50', i === this.selectedHighlight)
    })
    if (this.selectedHighlight >= 0 && items[this.selectedHighlight]) {
      items[this.selectedHighlight].scrollIntoView({ block: 'nearest' })
    }
  }

  async fetchAutocomplete(groupId, query, prefixes) {
    const url = `${this.autocompleteUrlValue}?term=${encodeURIComponent(query)}&prefixes=${encodeURIComponent(prefixes)}`
    try {
      const response = await fetch(url, { headers: { 'Accept': 'application/json' } })
      if (!response.ok) return

      const data = await response.json()
      this.showResults(groupId, data.results || [], data.total_count || 0)
    } catch (error) {
      // silently fail
    }
  }

  showResults(groupId, results, totalCount) {
    const resultsEl = this.getResultsEl(groupId)
    if (!resultsEl) return

    this.selectedHighlight = -1

    if (results.length === 0) {
      resultsEl.innerHTML = '<div class="px-3 py-2 text-sm text-gray-500">No results found</div>'
      resultsEl.classList.remove('hidden')
      return
    }

    const countInfo = totalCount > results.length
      ? `<div class="px-3 py-1.5 text-xs text-gray-400 bg-gray-50 border-b border-gray-100">Showing ${results.length} of ${totalCount} matches</div>`
      : `<div class="px-3 py-1.5 text-xs text-gray-400 bg-gray-50 border-b border-gray-100">${totalCount} match${totalCount !== 1 ? 'es' : ''}</div>`

    resultsEl.innerHTML = countInfo + results.map(r =>
      `<div data-autocomplete-item
            data-identifier="${this.escapeHtml(r.identifier)}"
            data-name="${this.escapeHtml(r.name)}"
            data-group-id="${groupId}"
            data-action="click->compliance-fix#selectAutocompleteItem"
            class="px-3 py-2 text-sm cursor-pointer hover:bg-blue-50 border-b border-gray-100 last:border-0">
        <span class="font-mono text-blue-700">${this.escapeHtml(r.identifier)}</span>
        <span class="text-gray-500 ml-1">-</span>
        <span class="text-gray-800 ml-1">${this.escapeHtml(r.name)}</span>
      </div>`
    ).join('')

    resultsEl.classList.remove('hidden')
  }

  hideResults(groupId) {
    const resultsEl = this.getResultsEl(groupId)
    if (resultsEl) resultsEl.classList.add('hidden')
    this.selectedHighlight = -1
  }

  closeAllAutocomplete() {
    this.autocompleteResultsTargets.forEach(el => el.classList.add('hidden'))
    this.selectedHighlight = -1
  }

  selectAutocompleteItem(event) {
    const item = event.currentTarget
    const groupId = item.dataset.groupId
    const identifier = item.dataset.identifier
    const name = item.dataset.name

    // Check if this group supports multi-value
    const input = this.autocompleteInputTargets.find(el => el.dataset.groupId === groupId)
    const fieldRow = item.closest('[data-compliance-fix-target="fieldRow"]')
    const isMulti = fieldRow && fieldRow.querySelector('[class*="bg-purple-100"]')

    // Get current values
    const termInput = this.termValueTargets.find(el => el.dataset.groupId === groupId)
    const labelInput = this.labelValueTargets.find(el => el.dataset.groupId === groupId)

    if (isMulti) {
      // Multi-value: append with || separator
      const currentTerm = termInput?.value || ''
      const currentLabel = labelInput?.value || ''
      const sep = ' || '

      if (termInput) {
        termInput.value = currentTerm ? `${currentTerm}${sep}${identifier}` : identifier
      }
      if (labelInput) {
        labelInput.value = currentLabel ? `${currentLabel}${sep}${name}` : name
      }
    } else {
      // Single-value: replace
      if (termInput) termInput.value = identifier
      if (labelInput) labelInput.value = name
    }

    // Add visual badge for selected term
    this.addSelectedBadge(groupId, identifier, name, isMulti)

    // Clear autocomplete input and hide results
    if (input) input.value = ''
    this.hideResults(groupId)
  }

  addSelectedBadge(groupId, identifier, name, isMulti) {
    const container = this.selectedTermsTargets.find(el => el.dataset.groupId === groupId)
    if (!container) return

    if (!isMulti) {
      // Single-value: clear existing badges
      container.innerHTML = ''
    }

    const badge = document.createElement('span')
    badge.className = 'inline-flex items-center gap-1 px-2 py-1 text-xs rounded-full bg-blue-100 text-blue-800'
    badge.innerHTML = `<span class="font-mono">${this.escapeHtml(identifier)}</span> <span class="text-blue-600">${this.escapeHtml(name)}</span>` +
      (isMulti ? `<button type="button" data-action="click->compliance-fix#removeBadge" data-group-id="${groupId}" data-identifier="${this.escapeHtml(identifier)}" data-name="${this.escapeHtml(name)}" class="ml-1 text-blue-500 hover:text-blue-800">&times;</button>` : '')
    container.appendChild(badge)
  }

  removeBadge(event) {
    event.preventDefault()
    const btn = event.currentTarget
    const groupId = btn.dataset.groupId
    const identifier = btn.dataset.identifier
    const name = btn.dataset.name
    const sep = ' || '

    // Remove from hidden inputs
    const termInput = this.termValueTargets.find(el => el.dataset.groupId === groupId)
    const labelInput = this.labelValueTargets.find(el => el.dataset.groupId === groupId)

    if (termInput) {
      const terms = termInput.value.split(sep).filter(t => t.trim() !== identifier)
      termInput.value = terms.join(sep)
    }
    if (labelInput) {
      const labels = labelInput.value.split(sep).filter(l => l.trim() !== name)
      labelInput.value = labels.join(sep)
    }

    // Remove badge element
    btn.closest('span').remove()
  }

  // ── Helpers ──

  getResultsEl(groupId) {
    return this.autocompleteResultsTargets.find(el => el.dataset.groupId === groupId)
  }

  escapeHtml(str) {
    const div = document.createElement('div')
    div.textContent = str
    return div.innerHTML
  }
}
