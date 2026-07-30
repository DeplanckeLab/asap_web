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
    "mapFixPanel", "mapFixOriginal", "mapFixInput", "mapFixResults", "mapFixSelected", "mapFixConfirm", "mapFixHint",
    "multiEnumGroup", "multiEnumOption",
    "submitButton", "fixedBadge"
  ]
  static values = {
    metadataUrl: String,
    autocompleteUrl: String,
    resolveUrl: String,
    projectId: Number,
    resultUrl: String,
    crossFieldConfig: Object,
    currentTriggerValues: Object
  }

  connect() {
    this.previewCache = {}
    this.debounceTimers = {}
    this.selectedHighlight = -1
    // Per-group state for map-from paired resolution
    // { groupId: { selectedRole, pairedRole, sourcePath, prefixes, values, resolved } }
    this.mapResolveState = {}
    this.mapFixHighlight = -1
    // Accumulated terms for the currently open map-fix panel: { groupId: [{ identifier, name }, ...] }
    this.mapFixAccumulated = {}
    this.subscription = null
    this.overlay = null
    // Track the current assay-based suspension constraint so it can be
    // re-applied when tissue_type unlocks suspension_type.
    this.activeAssaySuspension = null

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

    // Hover-highlight for paired badges (both "Current field content" and "Map from existing"):
    // when hovering a badge, highlight its counterpart on the other side.
    this.pairHoverIn = (e) => {
      const badge = e.target.closest('.cfv-pair-badge, .map-pair-badge')
      if (!badge) return
      const group = badge.dataset.pairGroup
      const idx = badge.dataset.pairIdx
      if (!group || idx == null) return
      const cls = badge.classList.contains('cfv-pair-badge') ? 'cfv-pair-badge' : 'map-pair-badge'
      this.element.querySelectorAll(`.${cls}[data-pair-group="${group}"][data-pair-idx="${idx}"]`).forEach(el => {
        el.classList.add('ring-2', 'ring-blue-400')
      })
    }
    this.pairHoverOut = (e) => {
      const badge = e.target.closest('.cfv-pair-badge, .map-pair-badge')
      if (!badge) return
      const group = badge.dataset.pairGroup
      const idx = badge.dataset.pairIdx
      if (!group || idx == null) return
      const cls = badge.classList.contains('cfv-pair-badge') ? 'cfv-pair-badge' : 'map-pair-badge'
      this.element.querySelectorAll(`.${cls}[data-pair-group="${group}"][data-pair-idx="${idx}"]`).forEach(el => {
        el.classList.remove('ring-2', 'ring-blue-400')
      })
    }
    this.element.addEventListener('mouseover', this.pairHoverIn)
    this.element.addEventListener('mouseout', this.pairHoverOut)

    // Auto-trigger map source selects that are pre-selected (from prefill data)
    requestAnimationFrame(() => this.triggerPreselectedMapSources())

    // Listen for changes on set_value fields that trigger cross-field constraints.
    // - assay_ontology_term_id -> determines suspension_type
    // - tissue_type -> if "cell line", ethnicity must be "na"
    this.element.addEventListener('change', (e) => {
      const input = e.target
      const name = input.name || ''
      if (name.includes('assay_ontology_term_id') && name.includes('[value]')) {
        this.onAssayChanged(input.value)
      }
      if (name.includes('tissue_type') && name.includes('[value]')) {
        this.onTissueTypeChanged(input.value)
      }
      // Re-evaluate "Fixed" badge when any value input changes
      if (name.includes('[value]') || name.includes('[source]')) {
        const row = input.closest('[data-compliance-fix-target="fieldRow"]')
        if (row) this.updateFixedBadge(row.dataset.groupId)
      }
    })

    // Evaluate cross-field constraints for values already present in the LOOM
    // (compliant fields whose values were set in a previous fix). Without this,
    // constraints like assay -> suspension_type would not trigger for fields
    // that are already compliant and therefore not actively changed.
    requestAnimationFrame(() => this.evaluateInitialTriggers())

    // Initial evaluation of "Fixed" badges (after a short delay to allow
    // pre-selected map sources to trigger their resolution).
    setTimeout(() => this.updateFixedBadges(), 500)
  }

  triggerPreselectedMapSources() {
    // Group pre-selected dropdowns by groupId. When both the term and label
    // dropdowns in a paired field have the same source selected, only fire
    // the label side (which uses by_name resolve mode). If only one is
    // selected, fire that one.
    const byGroup = {}
    this.mapSelectTargets.forEach(select => {
      if (select.value) {
        const gid = select.dataset.groupId
        if (!byGroup[gid]) byGroup[gid] = []
        byGroup[gid].push(select)
      }
    })
    for (const selects of Object.values(byGroup)) {
      if (selects.length > 1) {
        const labelSelect = selects.find(s => s.dataset.role === 'label')
        const termSelect = selects.find(s => s.dataset.role === 'term')
        if (labelSelect && termSelect && labelSelect.value === termSelect.value) {
          termSelect.value = ''
          labelSelect.dispatchEvent(new Event('change', { bubbles: true }))
        } else {
          selects.forEach(s => s.dispatchEvent(new Event('change', { bubbles: true })))
        }
      } else {
        selects[0].dispatchEvent(new Event('change', { bubbles: true }))
      }
    }
  }

  disconnect() {
    document.removeEventListener('click', this.outsideClickHandler)
    this.element.removeEventListener('mouseover', this.pairHoverIn)
    this.element.removeEventListener('mouseout', this.pairHoverOut)
    Object.values(this.debounceTimers).forEach(t => clearTimeout(t))
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
    this.removeOverlay()
  }

  // ── Cross-field schema constraints ──

  get multiValueConfig() {
    return this.crossFieldConfigValue?.multi_value || {}
  }

  get multiValueDelimiter() {
    return this.multiValueConfig.delimiter
  }

  isMultiValueGroup(groupId) {
    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (row?.dataset.multiValue === 'true') return true
    return Boolean(this.multiValueConfig.by_group_id?.[groupId])
  }

  isSortedMultiValueGroup(groupId) {
    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (row?.dataset.multiValueSorted === 'true') return true
    const cfg = this.multiValueConfig.by_group_id?.[groupId]
    return cfg?.sorted !== false
  }

  sortMultiValuePairs(terms, labels) {
    const pairs = terms.map((term, index) => ({ term, label: labels[index] || '' }))
    pairs.sort((a, b) => a.term.localeCompare(b.term))
    return {
      terms: pairs.map(pair => pair.term),
      labels: pairs.map(pair => pair.label)
    }
  }

  appendMultiValueTerms(termInput, labelInput, identifier, name, sorted) {
    let terms = termInput?.value ? this.splitMultiValue(termInput.value) : []
    let labels = labelInput?.value ? this.splitMultiValue(labelInput.value) : []
    terms.push(identifier)
    labels.push(name)
    if (sorted) {
      const ordered = this.sortMultiValuePairs(terms, labels)
      terms = ordered.terms
      labels = ordered.labels
    }
    if (termInput) termInput.value = this.joinMultiValue(terms)
    if (labelInput) labelInput.value = this.joinMultiValue(labels)
  }

  splitMultiValue(raw) {
    return raw.toString().split(this.multiValueDelimiter).map((part) => part.trim()).filter(Boolean)
  }

  joinMultiValue(values) {
    return values.map((v) => v.toString()).filter(Boolean).join(this.multiValueDelimiter)
  }

  onMultiEnumChange(event) {
    const checkbox = event.currentTarget
    const groupId = checkbox.dataset.groupId
    if (!groupId) return

    const groupEl = this.multiEnumGroupTargets.find((el) => el.dataset.groupId === groupId)
    const exclusiveValue = groupEl?.dataset.exclusiveValue || null
    const options = this.multiEnumOptionTargets.filter((el) => el.dataset.groupId === groupId)

    if (exclusiveValue && checkbox.value === exclusiveValue && checkbox.checked) {
      options.forEach((el) => {
        if (el !== checkbox) el.checked = false
      })
    } else if (exclusiveValue && checkbox.checked) {
      options.forEach((el) => {
        if (el.value === exclusiveValue) el.checked = false
      })
    }

    let selected = options.filter((el) => el.checked).map((el) => el.value)
    if (exclusiveValue && selected.includes(exclusiveValue)) {
      selected = [exclusiveValue]
    } else if (this.isSortedMultiValueGroup(groupId)) {
      selected = [...selected].sort((a, b) => a.localeCompare(b))
    }

    const termInput = this.termValueTargets.find((el) => el.dataset.groupId === groupId)
    if (termInput) {
      termInput.value = selected.length <= 1 ? (selected[0] || '') : this.joinMultiValue(selected)
      termInput.dispatchEvent(new Event('change', { bubbles: true }))
    }

    this.updateFixedBadge(groupId)
  }

  // Get the current unique LOOM values for a field path.
  // Returns an array of unique values, or null if unknown.
  getCurrentFieldValues(fieldPath) {
    const triggers = this.currentTriggerValuesValue || {}
    const fv = triggers.field_values || {}
    return fv[fieldPath] || null
  }

  // Check whether a field currently has a single uniform value matching the required one.
  fieldAlreadyHasValue(fieldPath, requiredValue) {
    const vals = this.getCurrentFieldValues(fieldPath)
    if (!vals || vals.length === 0) return false
    return vals.length === 1 && vals[0] === requiredValue
  }

  // Lock a field: disable all radio buttons and inputs, select skip or set_value.
  // If the field already has the correct value, select "skip". Otherwise "set_value".
  // reason: string to show in the constraint message.
  // fields: { termPath, termValue, labelPath?, labelValue? }
  lockField(groupId, reason, fields) {
    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (!row) return

    // Skip if this field has a static backend constraint already
    const staticConstraint = row.querySelector(`[data-constraint-group="${groupId}"]`)
    if (staticConstraint) return

    const alreadyCorrect = this.fieldAlreadyHasValue(fields.termPath, fields.termValue)
    const action = alreadyCorrect ? 'skip' : 'set_value'

    // Set hidden action inputs
    this.hiddenActionTargets.forEach(input => {
      if (input.dataset.groupId === groupId) input.value = action
    })

    // Select and disable all radio buttons
    const radios = row.querySelectorAll(`input[type="radio"][name="group_action_${groupId}"]`)
    radios.forEach(r => {
      r.checked = (r.value === action)
      r.disabled = true
    })

    const valuePanel = document.getElementById(`set_value_${groupId}`)
    const mapPanel = document.getElementById(`map_from_${groupId}`)

    if (action === 'skip') {
      if (valuePanel) valuePanel.classList.add('hidden')
      if (mapPanel) mapPanel.classList.add('hidden')
    } else {
      if (valuePanel) valuePanel.classList.remove('hidden')
      if (mapPanel) mapPanel.classList.add('hidden')

      // Set the value inputs
      const selectInput = row.querySelector(`select[name="fixes[${fields.termPath}][value]"]`)
      const textInput = row.querySelector(`input[name="fixes[${fields.termPath}][value]"]`)
      if (selectInput) { selectInput.value = fields.termValue; selectInput.disabled = true }
      if (textInput) { textInput.value = fields.termValue; textInput.disabled = true }

      if (fields.labelPath) {
        const labelSelect = row.querySelector(`select[name="fixes[${fields.labelPath}][value]"]`)
        const labelText = row.querySelector(`input[name="fixes[${fields.labelPath}][value]"]`)
        if (labelSelect) { labelSelect.value = fields.labelValue; labelSelect.disabled = true }
        if (labelText) { labelText.value = fields.labelValue; labelText.disabled = true }
      }
    }

    // Disable map-from dropdowns too
    row.querySelectorAll('select[data-compliance-fix-target="mapSelect"]').forEach(s => { s.disabled = true })

    // Show constraint message
    const dynMsg = row.querySelector(`[data-constraint-dynamic="${groupId}"]`)
    const msgEl = row.querySelector(`[data-constraint-message="${groupId}"]`)
    const detailEl = row.querySelector(`[data-constraint-detail="${groupId}"]`)
    if (dynMsg && msgEl && detailEl) {
      msgEl.textContent = `Schema constraint: ${reason}`
      if (alreadyCorrect) {
        detailEl.textContent = `Value is already "${fields.termValue}" -- no change needed.`
      } else {
        detailEl.textContent = `Value will be set to "${fields.termValue}".`
      }
      dynMsg.classList.remove('hidden')
    }

    this.updateFixedBadge(groupId)
  }

  // Unlock a field: re-enable radio buttons and inputs, hide constraint message.
  unlockField(groupId) {
    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (!row) return

    // Re-enable radio buttons
    const radios = row.querySelectorAll(`input[type="radio"][name="group_action_${groupId}"]`)
    radios.forEach(r => { r.disabled = false })

    // Re-enable inputs in set_value panel
    const valuePanel = document.getElementById(`set_value_${groupId}`)
    if (valuePanel) {
      valuePanel.querySelectorAll('select, input[type="text"]').forEach(el => { el.disabled = false })
    }

    // Re-enable map-from dropdowns
    row.querySelectorAll('select[data-compliance-fix-target="mapSelect"]').forEach(s => { s.disabled = false })

    // Hide constraint message
    const dynMsg = row.querySelector(`[data-constraint-dynamic="${groupId}"]`)
    if (dynMsg) dynMsg.classList.add('hidden')

    this.updateFixedBadge(groupId)
  }

  evaluateInitialTriggers() {
    const triggers = this.currentTriggerValuesValue || {}
    // The backend pre-computes the union of allowed suspension types across
    // all assay terms in the project.
    if (triggers.assay_allowed_suspension) {
      const assayIds = triggers.assay_ontology_term_ids || []
      const label = assayIds.length === 1 ? assayIds[0] : `${assayIds.length} assays`
      this.applySuspensionConstraint(label, triggers.assay_allowed_suspension)
    } else if (triggers.assay_ontology_term_ids && triggers.assay_ontology_term_ids.length > 0) {
      // Fallback: compute union on the frontend from the exact-match map
      this.computeAndApplySuspensionFromAssays(triggers.assay_ontology_term_ids)
    }
    if (triggers.tissue_type) {
      this.onTissueTypeChanged(triggers.tissue_type)
    } else {
      this.applyTissuePrefixConstraint(null)
    }
  }

  // Compute the union of allowed suspension types for a set of assay term IDs
  // using the frontend exact-match map. Used when backend didn't resolve.
  computeAndApplySuspensionFromAssays(assayIds) {
    const suspCfg = this.crossFieldConfigValue?.assay_suspension || {}
    const map = suspCfg.map || {}
    const unionSet = new Set()
    assayIds.forEach(id => {
      const perAssay = map[id]
      if (perAssay) perAssay.forEach(v => unionSet.add(v))
    })
    if (unionSet.size === 0) return
    const allowed = Array.from(unionSet)
    const label = assayIds.length === 1 ? assayIds[0] : `${assayIds.length} assays`
    this.applySuspensionConstraint(label, allowed)
  }

  onAssayChanged(assayTermId) {
    const suspCfg = this.crossFieldConfigValue?.assay_suspension || {}
    const groupId = suspCfg.group_id || 'suspension_type'

    if (!assayTermId) {
      this.activeAssaySuspension = null
      this.unlockField(groupId)
      return
    }

    this.unlockField(groupId)

    // Get all assay term IDs from the current LOOM values and combine with
    // the newly selected one, then compute the union.
    const triggers = this.currentTriggerValuesValue || {}
    const existingAssays = triggers.assay_ontology_term_ids || []
    const allAssays = [...new Set([...existingAssays, assayTermId])]
    this.computeAndApplySuspensionFromAssays(allAssays)
  }

  applySuspensionConstraint(assayLabel, allowed) {
    const suspCfg = this.crossFieldConfigValue?.assay_suspension || {}
    const groupId = suspCfg.group_id || 'suspension_type'
    const termPath = suspCfg.term_path || '/col_attrs/suspension_type'
    this.activeAssaySuspension = { assayLabel, allowed, groupId, termPath }
    const suspRow = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (!suspRow) return

    if (allowed.length === 1) {
      this.lockField(groupId, this.formatTemplate(suspCfg.lock_reason_template, { assay: assayLabel }), {
        termPath,
        termValue: allowed[0]
      })
    } else {
      // Multiple allowed values: do NOT lock the field -- the user must choose.
      // Just restrict dropdown options and show an informational message.
      const selectEl = suspRow.querySelector(`select[name="fixes[${termPath}][value]"]`)
      if (selectEl) {
        Array.from(selectEl.options).forEach(opt => {
          if (opt.value === '') return
          opt.disabled = !allowed.includes(opt.value)
        })
        if (selectEl.value && !allowed.includes(selectEl.value)) {
          selectEl.value = allowed[0]
        }
      }

      const dynMsg = suspRow.querySelector(`[data-constraint-dynamic="${groupId}"]`)
      const msgEl = suspRow.querySelector(`[data-constraint-message="${groupId}"]`)
      const detailEl = suspRow.querySelector(`[data-constraint-detail="${groupId}"]`)
      if (dynMsg && msgEl && detailEl) {
        msgEl.textContent = this.formatTemplate(suspCfg.restrict_message_template, { assay: assayLabel })
        detailEl.textContent = this.formatTemplate(suspCfg.restrict_detail_template, { allowed: allowed.join(', ') })
        dynMsg.classList.remove('hidden')
      }
    }
  }

  onTissueTypeChanged(value) {
    this.applyTissuePrefixConstraint(value)
    if (!value) return
    const cfg = this.crossFieldConfigValue?.cell_line
    if (!cfg) return

    const isCellLine = value === cfg.trigger_value
    const forcedFields = cfg.forced_fields || []
    const affectedGroups = cfg.affected_group_ids || []

    if (isCellLine) {
      forcedFields.forEach(field => {
        const lockFields = {
          termPath: field.term_path,
          termValue: field.term_value
        }
        if (field.label_path) {
          lockFields.labelPath = field.label_path
          lockFields.labelValue = field.label_value
        }
        this.lockField(field.group_id, cfg.reason, lockFields)
      })

      const note = cfg.tissue_note
      if (note) {
        const tissueRow = this.fieldRowTargets.find(el => el.dataset.groupId === note.group_id)
        if (tissueRow) {
          const dynMsg = tissueRow.querySelector(`[data-constraint-dynamic="${note.group_id}"]`)
          const msgEl = tissueRow.querySelector(`[data-constraint-message="${note.group_id}"]`)
          const detailEl = tissueRow.querySelector(`[data-constraint-detail="${note.group_id}"]`)
          if (dynMsg && msgEl && detailEl) {
            msgEl.textContent = note.message
            detailEl.textContent = note.detail
            dynMsg.classList.remove('hidden')
          }
        }
      }
    } else {
      affectedGroups.forEach(gid => {
        this.unlockField(gid)
      })
      if (this.activeAssaySuspension) {
        const { assayLabel, allowed } = this.activeAssaySuspension
        this.applySuspensionConstraint(assayLabel, allowed)
      }
    }
  }

  applyTissuePrefixConstraint(tissueType) {
    const cfg = this.crossFieldConfigValue?.tissue_type_tissue
    if (!cfg) return

    const groupId = cfg.group_id
    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (!row) return

    let prefixes
    if (tissueType === cfg.cell_line_value) {
      prefixes = cfg.cell_line_prefixes
    } else if (tissueType === cfg.primary_cell_culture_value) {
      prefixes = cfg.cell_type_prefixes
    } else {
      prefixes = cfg.tissue_prefixes
    }

    const prefixStr = (prefixes || []).join(',')
    row.querySelectorAll('[data-prefixes]').forEach(el => {
      el.dataset.prefixes = prefixStr
    })
  }

  formatTemplate(template, vars) {
    if (!template) return ''
    return template.replace(/%\{(\w+)\}/g, (_, key) => (vars[key] != null ? vars[key] : ''))
  }

  // Force a field group to a specific value: switch to set_value, fill the value input.
  // Used for non-locking constraints or intermediate operations.
  forceFieldValue(groupId, fieldPath, value) {
    this.hiddenActionTargets.forEach(input => {
      if (input.dataset.groupId === groupId) input.value = 'set_value'
    })

    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (row) {
      const radios = row.querySelectorAll(`input[type="radio"][name="group_action_${groupId}"]`)
      radios.forEach(r => { r.checked = (r.value === 'set_value') })
    }

    const valuePanel = document.getElementById(`set_value_${groupId}`)
    const mapPanel = document.getElementById(`map_from_${groupId}`)
    if (valuePanel) valuePanel.classList.remove('hidden')
    if (mapPanel) mapPanel.classList.add('hidden')

    if (row) {
      const selectInput = row.querySelector(`select[name="fixes[${fieldPath}][value]"]`)
      const textInput = row.querySelector(`input[name="fixes[${fieldPath}][value]"]`)
      if (selectInput) selectInput.value = value
      if (textInput) textInput.value = value
    }
  }

  // Force the label side of a paired field group to a specific value
  forceFieldLabelValue(groupId, labelPath, value) {
    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (!row) return
    const selectInput = row.querySelector(`select[name="fixes[${labelPath}][value]"]`)
    const textInput = row.querySelector(`input[name="fixes[${labelPath}][value]"]`)
    if (selectInput) selectInput.value = value
    if (textInput) textInput.value = value
  }

  // ── Restricted-terms dropdown (e.g. sex field) ──

  onRestrictedTermSelect(event) {
    const select = event.target
    const groupId = select.dataset.groupId
    const selectedOption = select.options[select.selectedIndex]
    const identifier = select.value
    const name = selectedOption ? (selectedOption.dataset.name || '') : ''

    const termInput = this.termValueTargets.find(el => el.dataset.groupId === groupId)
    const labelInput = this.labelValueTargets.find(el => el.dataset.groupId === groupId)

    if (termInput) termInput.value = identifier
    if (labelInput) labelInput.value = name

    if (termInput) termInput.dispatchEvent(new Event('change', { bubbles: true }))
    this.updateFixedBadge(groupId)
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
      case 'progress':
      case 'started':
        this.updateOverlay(data.message || 'Running compliance validation...', data.progress)
        break
      case 'completed': {
        const resultUrl = this.hasResultUrlValue ? this.resultUrlValue : null
        if (data.valid) {
          this.updateOverlay('Validation passed. Redirecting...', 100)
        } else {
          const count = data.errors_count || 0
          this.updateOverlay(`Validation complete (${count} error(s)). Redirecting...`, 100)
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
    this.overlayProgress = 0

    const overlay = document.createElement('div')
    overlay.id = 'compliance-fix-overlay'
    overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background-color:rgba(0,0,0,0.5);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;'
    overlay.innerHTML = `
      <div style="background:white;border-radius:12px;padding:32px 40px;text-align:left;max-width:480px;width:90%;">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:12px;">
          <p id="compliance-fix-overlay-msg" style="font-size:16px;font-weight:500;color:#1f2937;margin:0;">${this.escapeHtml(message)}</p>
          <span id="compliance-fix-overlay-pct" style="font-size:13px;color:#6b7280;font-variant-numeric:tabular-nums;">0%</span>
        </div>
        <div style="height:8px;background:#e5e7eb;border-radius:9999px;overflow:hidden;">
          <div id="compliance-fix-overlay-bar" style="height:8px;width:0%;background:#2563eb;border-radius:9999px;transition:width 0.3s ease;"></div>
        </div>
        <p style="font-size:13px;color:#6b7280;margin-top:12px;margin-bottom:0;">Please wait, this may take a few minutes for large datasets.</p>
      </div>
    `
    document.body.appendChild(overlay)
    this.overlay = overlay
  }

  updateOverlay(message, progress = null) {
    const msgEl = document.getElementById('compliance-fix-overlay-msg')
    if (!msgEl) {
      this.showOverlay(message)
    } else if (message) {
      msgEl.textContent = message
    }

    if (progress == null) return

    const next = Math.max(this.overlayProgress || 0, Math.max(0, Math.min(100, Math.round(Number(progress) || 0))))
    this.overlayProgress = next
    const bar = document.getElementById('compliance-fix-overlay-bar')
    const pct = document.getElementById('compliance-fix-overlay-pct')
    if (bar) bar.style.width = `${next}%`
    if (pct) pct.textContent = `${next}%`
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

    this.updateFixedBadge(groupId)
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

      // Auto-detect whether source values are identifiers or names by checking
      // the first few non-array values for an ontology ID pattern (e.g. "CL:0000123").
      const idPattern = /^[A-Za-z][A-Za-z0-9]*:[0-9]+$/
      const sampleVals = values.filter(v => !v.startsWith('[')).slice(0, 5)
      const looksLikeIds = sampleVals.length > 0 && sampleVals.every(v => idPattern.test(v.trim()))

      // If auto-detection disagrees with the dropdown role, swap the effective roles
      // so identifiers always go to the term side and names to the label side.
      let effectiveSelectedRole = selectedRole
      let effectivePairedRole = pairedRole
      if (looksLikeIds && selectedRole === 'label') {
        effectiveSelectedRole = 'term'
        effectivePairedRole = 'label'
      } else if (!looksLikeIds && selectedRole === 'term') {
        effectiveSelectedRole = 'label'
        effectivePairedRole = 'term'
      }

      // If roles were swapped, also swap the dropdown UI so the source appears
      // under the correct field and the other dropdown is cleared.
      if (effectiveSelectedRole !== selectedRole) {
        const correctSelect = this.mapSelectTargets.find(
          el => el.dataset.groupId === groupId && el.dataset.role === effectiveSelectedRole
        )
        if (correctSelect) correctSelect.value = sourcePath
        select.value = ''
      }

      const resolveMode = effectiveSelectedRole === 'term' ? 'by_identifier' : 'by_name'
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
          mode: resolveMode,
          project_id: this.projectIdValue
        })
      })

      if (!resolveResponse.ok) {
        if (statusEl) statusEl.textContent = 'Failed to resolve paired values'
        return
      }

      const resolveData = await resolveResponse.json()
      const resolved = resolveData.resolved || {}
      const multiTermMap = resolveData.multi_term_map || {}
      const canonicalNames = resolveData.canonical_names || {}

      // Auto-populate sourceRenames for values whose source text doesn't match
      // the canonical ontology name (e.g. "fat_body" -> "fat body",
      // "malpighian_tubule" -> "Malpighian tubule") and for array-formatted
      // values that need rewriting ("['a','b']" -> "a || b").
      const sourceRenames = {}
      for (const [original, joinedSource] of Object.entries(multiTermMap)) {
        sourceRenames[original] = joinedSource
      }
      for (const [original, canonical] of Object.entries(canonicalNames)) {
        if (!sourceRenames[original]) {
          sourceRenames[original] = canonical
        }
      }

      // Store state for this group so the fix autocomplete can update it
      // sourceRenames tracks corrections to the source field itself (e.g., "T-cell" -> "T cell",
      // or "['FBbt:001','FBbt:002']" -> "FBbt:001 || FBbt:002")
      // Use the effective roles (auto-detected from value content) not the dropdown roles.
      this.mapResolveState[groupId] = {
        selectedRole: effectiveSelectedRole,
        pairedRole: effectivePairedRole,
        sourcePath, prefixes, values, resolved,
        sourceRenames
      }

      // Update hidden action inputs to match effective roles
      this.hiddenActionTargets.forEach(input => {
        if (input.dataset.groupId !== groupId) return
        if (input.dataset.role === `${effectiveSelectedRole}_action`) {
          input.value = 'map_from'
        } else if (input.dataset.role === `${effectivePairedRole}_action`) {
          input.value = 'resolve_paired'
        }
      })

      // Render badges on both sides
      this.renderMapBadges(groupId)

      // Store the resolve map in a hidden input for form submission
      this.setResolveMapInput(groupId, effectivePairedRole, sourcePath, resolved)

      // If any source values need renaming (canonical name mismatch or array
      // rewrite), the source field also needs a resolve_paired action
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
    const statusEl = this.mapStatusTargets.find(el => el.dataset.groupId === groupId)

    const resolvedCount = values.filter(v => resolved[v]).length
    const unresolvedValues = values.filter(v => !resolved[v])

    // Sort values: unresolved first, then resolved
    const sortedValues = [...unresolvedValues, ...values.filter(v => resolved[v])]

    // Determine which badge container holds identifiers vs names.
    // Term side always shows identifiers (blue/mono), label side shows names (grey/green).
    const termBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === 'term'
    )
    const labelBadgeEl = this.mapBadgesTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === 'label'
    )
    if (termBadgeEl) termBadgeEl.innerHTML = ''
    if (labelBadgeEl) labelBadgeEl.innerHTML = ''

    // The source values go on the selectedRole side; resolved values on the pairedRole side.
    // Figure out which content (source vs resolved) goes to term vs label.
    const termIsSource = selectedRole === 'term'

    // Color convention: source side (directly from metadata) = blue,
    // derived side (resolved via ontology) = grey, font-mono on term side always.
    const sourceStyle = 'bg-blue-100 text-blue-700 border border-blue-200 hover:bg-blue-200'
    const derivedStyle = 'bg-gray-100 text-gray-600 border border-gray-200 hover:bg-gray-200'

    const pairGroup = `map_${groupId}`

    // Render term side (identifiers): font-mono always
    if (termBadgeEl) {
      const termStyle = termIsSource ? sourceStyle : derivedStyle
      sortedValues.forEach((val, idx) => {
        const badge = document.createElement('span')
        const isResolved = !!resolved[val]
        const isArrayFormat = val.startsWith('[') && val.endsWith(']')
        const displayValue = termIsSource ? val : resolved[val]
        const hasRename = termIsSource && !!sourceRenames[val]

        badge.dataset.action = 'click->compliance-fix#openMapFix'
        badge.dataset.groupId = groupId
        badge.dataset.originalValue = val
        badge.dataset.mapBadgeValue = val
        badge.dataset.mapBadgeRole = 'term'
        badge.dataset.pairGroup = pairGroup
        badge.dataset.pairIdx = idx

        if (!isResolved) {
          badge.className = 'map-pair-badge inline-flex items-center px-2 py-0.5 text-xs rounded-full font-mono bg-red-100 text-red-700 border border-red-300 cursor-pointer hover:bg-red-200'
          badge.textContent = termIsSource ? val : `? (${val})`
          badge.title = 'Click to fix this unresolved term'
        } else if (isArrayFormat) {
          badge.className = 'map-pair-badge inline-flex items-center px-2 py-0.5 text-xs rounded-full font-mono bg-purple-100 text-purple-700 border border-purple-200 cursor-pointer hover:bg-purple-200'
          badge.textContent = termIsSource ? (sourceRenames[val] || val) : resolved[val]
          badge.title = 'Click to change'
        } else if (hasRename) {
          badge.className = 'map-pair-badge inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full font-mono bg-green-100 text-green-700 border border-green-200 cursor-pointer hover:bg-green-200'
          badge.innerHTML = `<s class="text-red-400 text-[10px]">${this.escapeHtml(val)}</s> ${this.escapeHtml(sourceRenames[val])}`
          badge.title = 'Click to change'
        } else {
          badge.className = `map-pair-badge inline-flex items-center px-2 py-0.5 text-xs rounded-full font-mono ${termStyle} cursor-pointer`
          badge.textContent = displayValue || val
          badge.title = 'Click to change'
        }
        termBadgeEl.appendChild(badge)
      })
    }

    // Render label side (names): no font-mono
    if (labelBadgeEl) {
      const labelStyle = termIsSource ? derivedStyle : sourceStyle
      sortedValues.forEach((val, idx) => {
        const badge = document.createElement('span')
        const isResolved = !!resolved[val]
        const isArrayFormat = val.startsWith('[') && val.endsWith(']')
        const displayValue = termIsSource ? resolved[val] : val
        const hasRename = !termIsSource && !!sourceRenames[val]

        badge.dataset.action = 'click->compliance-fix#openMapFix'
        badge.dataset.groupId = groupId
        badge.dataset.originalValue = val
        badge.dataset.mapBadgeValue = val
        badge.dataset.mapBadgeRole = 'label'
        badge.dataset.pairGroup = pairGroup
        badge.dataset.pairIdx = idx

        if (!isResolved) {
          badge.className = 'map-pair-badge inline-flex items-center px-2 py-0.5 text-xs rounded-full bg-red-100 text-red-700 border border-red-300 cursor-pointer hover:bg-red-200'
          badge.textContent = termIsSource ? `? (${val})` : val
          badge.title = 'Click to fix this unresolved term'
        } else if (isArrayFormat) {
          badge.className = 'map-pair-badge inline-flex items-center px-2 py-0.5 text-xs rounded-full bg-purple-100 text-purple-700 border border-purple-200 cursor-pointer hover:bg-purple-200'
          badge.textContent = termIsSource ? resolved[val] : (sourceRenames[val] || val)
          badge.title = 'Click to change'
        } else if (hasRename) {
          badge.className = 'map-pair-badge inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-green-100 text-green-700 border border-green-200 cursor-pointer hover:bg-green-200'
          badge.innerHTML = `<s class="text-red-400 text-[10px]">${this.escapeHtml(val)}</s> ${this.escapeHtml(sourceRenames[val])}`
          badge.title = 'Click to change'
        } else {
          badge.className = `map-pair-badge inline-flex items-center px-2 py-0.5 text-xs rounded-full ${labelStyle} cursor-pointer`
          badge.textContent = displayValue || val
          badge.title = 'Click to change'
        }
        labelBadgeEl.appendChild(badge)
      })
    }

    // Show resolution status
    if (statusEl) {
      if (unresolvedValues.length > 0) {
        statusEl.innerHTML = ''
        const msg = document.createElement('span')
        msg.textContent = `Resolved ${resolvedCount}/${values.length} values. ${unresolvedValues.length} unresolved (shown first in red). Click on red badges to fix them. `
        statusEl.appendChild(msg)

        const btn = document.createElement('button')
        btn.type = 'button'
        btn.textContent = `Set ${unresolvedValues.length} unresolved to "unknown"`
        btn.className = 'ml-2 px-2 py-0.5 text-[10px] rounded bg-amber-200 text-amber-800 hover:bg-amber-300 border border-amber-300'
        btn.dataset.action = 'click->compliance-fix#setUnresolvedToUnknown'
        btn.dataset.groupId = groupId
        statusEl.appendChild(btn)

        statusEl.className = 'text-xs text-amber-600 font-medium'
      } else {
        statusEl.innerHTML = ''
        statusEl.textContent = `All ${resolvedCount} values resolved successfully.`
        statusEl.className = 'text-xs text-green-600 italic'
      }
      statusEl.classList.remove('hidden')
    }

    this.updateFixedBadge(groupId)
  }

  setUnresolvedToUnknown(event) {
    const groupId = event.currentTarget.dataset.groupId
    const state = this.mapResolveState[groupId]
    if (!state) return

    const { values, resolved, selectedRole, pairedRole, sourcePath, sourceRenames } = state

    // Map every unresolved value to "unknown"
    values.forEach(val => {
      if (!resolved[val]) {
        resolved[val] = 'unknown'
      }
    })

    // Also rename the source side for unresolved values so the source field
    // itself gets "unknown" written (the original value is replaced).
    values.forEach(val => {
      if (!sourceRenames[val] && resolved[val] === 'unknown') {
        sourceRenames[val] = 'unknown'
      }
    })

    // Re-render badges and update the hidden form inputs
    this.renderMapBadges(groupId)
    this.setResolveMapInput(groupId, pairedRole, sourcePath, resolved)
    this.updateSourceFieldAction(groupId)
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

    // Pre-populate accumulated terms if this value was already resolved
    // (allows editing an existing multi-term assignment)
    const state = this.mapResolveState[groupId]
    this.mapFixAccumulated[groupId] = []
    if (state && state.resolved[originalValue]) {
      const existingResolved = state.resolved[originalValue]
      const existingSource = state.sourceRenames[originalValue] || ''
      const resolvedParts = this.splitMultiValue(existingResolved)
      const sourceParts = this.splitMultiValue(existingSource)
      resolvedParts.forEach((part, idx) => {
        const srcPart = sourceParts[idx] || ''
        if (state.selectedRole === 'term') {
          // paired = names, source = identifiers
          this.mapFixAccumulated[groupId].push({ identifier: srcPart, name: part })
        } else {
          // paired = identifiers, source = names
          this.mapFixAccumulated[groupId].push({ identifier: part, name: srcPart })
        }
      })
    }
    this.renderMapFixSelected(groupId)

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
      this.fetchMapFixAutocomplete(
        groupId,
        query,
        input.dataset.prefixes,
        input.dataset.allowedTerms,
        input.dataset.excludedTerms
      )
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

  async fetchMapFixAutocomplete(groupId, query, prefixes, allowedTerms, excludedTerms) {
    let url = `${this.autocompleteUrlValue}?term=${encodeURIComponent(query)}&prefixes=${encodeURIComponent(prefixes)}&project_id=${this.projectIdValue}`
    if (allowedTerms) url += `&allowed_terms=${encodeURIComponent(allowedTerms)}`
    if (excludedTerms) url += `&excluded_terms=${encodeURIComponent(excludedTerms)}`
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

    // Accumulate this term (avoid duplicates)
    if (!this.mapFixAccumulated[groupId]) this.mapFixAccumulated[groupId] = []
    const already = this.mapFixAccumulated[groupId].some(t => t.identifier === identifier)
    if (!already) {
      this.mapFixAccumulated[groupId].push({ identifier, name })
    }

    // Re-render the selected terms area, show Confirm button
    this.renderMapFixSelected(groupId)

    // Clear search input so user can add another term
    const fixInput = this.mapFixInputTargets.find(el => el.dataset.groupId === groupId)
    if (fixInput) { fixInput.value = ''; fixInput.focus() }
    this.hideMapFixResults(groupId)
  }

  removeMapFixTerm(event) {
    const groupId = event.currentTarget.dataset.groupId
    const identifier = event.currentTarget.dataset.identifier
    if (!this.mapFixAccumulated[groupId]) return
    this.mapFixAccumulated[groupId] = this.mapFixAccumulated[groupId].filter(t => t.identifier !== identifier)
    this.renderMapFixSelected(groupId)
  }

  renderMapFixSelected(groupId) {
    const selectedEl = this.mapFixSelectedTargets.find(el => el.dataset.groupId === groupId)
    const confirmBtn = this.mapFixConfirmTargets.find(el => el.dataset.groupId === groupId)
    const hintEl = this.mapFixHintTargets.find(el => el.dataset.groupId === groupId)
    const terms = this.mapFixAccumulated[groupId] || []

    if (selectedEl) {
      if (terms.length === 0) {
        selectedEl.innerHTML = ''
        selectedEl.classList.add('hidden')
      } else {
        selectedEl.classList.remove('hidden')
        selectedEl.innerHTML = terms.map(t =>
          `<span class="inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-green-100 text-green-700 border border-green-200">` +
            `<span class="font-mono">${this.escapeHtml(t.identifier)}</span>` +
            `<span class="text-gray-400">-</span> ${this.escapeHtml(t.name)}` +
            `<button type="button" data-action="click->compliance-fix#removeMapFixTerm" ` +
              `data-group-id="${groupId}" data-identifier="${this.escapeHtml(t.identifier)}" ` +
              `class="ml-1 text-red-400 hover:text-red-600 leading-none" title="Remove">x</button>` +
          `</span>`
        ).join('')
      }
    }
    if (confirmBtn) {
      if (terms.length > 0) {
        confirmBtn.classList.remove('hidden')
        confirmBtn.textContent = terms.length === 1 ? 'Confirm' : `Confirm (${terms.length} terms, joined with ${this.multiValueDelimiter.trim()})`
      } else {
        confirmBtn.classList.add('hidden')
      }
    }
    if (hintEl) {
      hintEl.classList.toggle('hidden', terms.length > 0)
    }
  }

  confirmMapFix(event) {
    const groupId = event.currentTarget.dataset.groupId
    const state = this.mapResolveState[groupId]
    if (!state) return

    const terms = this.mapFixAccumulated[groupId] || []
    if (terms.length === 0) return

    const fixPanel = this.mapFixPanelTargets.find(el => el.dataset.groupId === groupId)
    if (!fixPanel) return
    const originalValue = fixPanel.dataset.fixingValue

    let idTerms = terms.map(t => t.identifier)
    let nameTerms = terms.map(t => t.name)
    if (this.isSortedMultiValueGroup(groupId)) {
      const ordered = this.sortMultiValuePairs(idTerms, nameTerms)
      idTerms = ordered.terms
      nameTerms = ordered.labels
    }
    const joinedIdentifiers = this.joinMultiValue(idTerms)
    const joinedNames = this.joinMultiValue(nameTerms)

    // Update both maps: the paired resolve map AND the source-side rename map
    if (state.selectedRole === 'term') {
      // Source has identifiers -> paired gets names
      state.resolved[originalValue] = joinedNames
      state.sourceRenames[originalValue] = joinedIdentifiers
    } else {
      // Source has names -> paired gets identifiers
      state.resolved[originalValue] = joinedIdentifiers
      state.sourceRenames[originalValue] = joinedNames
    }

    // Re-render badges
    this.renderMapBadges(groupId)

    // Update hidden inputs
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
      this.fetchAutocomplete(
        groupId,
        query,
        input.dataset.prefixes,
        input.dataset.allowedTerms,
        input.dataset.excludedTerms
      )
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

  async fetchAutocomplete(groupId, query, prefixes, allowedTerms, excludedTerms) {
    let url = `${this.autocompleteUrlValue}?term=${encodeURIComponent(query)}&prefixes=${encodeURIComponent(prefixes)}&project_id=${this.projectIdValue}`
    if (allowedTerms) url += `&allowed_terms=${encodeURIComponent(allowedTerms)}`
    if (excludedTerms) url += `&excluded_terms=${encodeURIComponent(excludedTerms)}`
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
    const isMulti = this.isMultiValueGroup(groupId)

    // Get current values
    const termInput = this.termValueTargets.find(el => el.dataset.groupId === groupId)
    const labelInput = this.labelValueTargets.find(el => el.dataset.groupId === groupId)

    if (isMulti) {
      this.appendMultiValueTerms(
        termInput,
        labelInput,
        identifier,
        name,
        this.isSortedMultiValueGroup(groupId)
      )
    } else {
      // Single-value: replace
      if (termInput) termInput.value = identifier
      if (labelInput) labelInput.value = name
    }

    // Add visual badge for selected term
    this.addSelectedBadge(groupId, identifier, name, isMulti)

    // Trigger cross-field constraint checks (e.g. assay -> suspension_type)
    if (termInput) termInput.dispatchEvent(new Event('change', { bubbles: true }))

    // Clear autocomplete input and hide results
    if (input) input.value = ''
    this.hideResults(groupId)

    this.updateFixedBadge(groupId)
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
    const termInput = this.termValueTargets.find(el => el.dataset.groupId === groupId)
    const labelInput = this.labelValueTargets.find(el => el.dataset.groupId === groupId)

    if (termInput) {
      let terms = this.splitMultiValue(termInput.value).filter(t => t !== identifier)
      let labels = labelInput ? this.splitMultiValue(labelInput.value).filter(l => l !== name) : []
      if (this.isSortedMultiValueGroup(groupId)) {
        const ordered = this.sortMultiValuePairs(terms, labels)
        terms = ordered.terms
        labels = ordered.labels
      }
      termInput.value = this.joinMultiValue(terms)
      if (labelInput) labelInput.value = this.joinMultiValue(labels)
    } else if (labelInput) {
      const labels = this.splitMultiValue(labelInput.value).filter(l => l !== name)
      labelInput.value = this.joinMultiValue(labels)
    }

    // Remove badge element
    btn.closest('span').remove()

    this.updateFixedBadge(groupId)
  }

  // ── Helpers ──

  getResultsEl(groupId) {
    return this.autocompleteResultsTargets.find(el => el.dataset.groupId === groupId)
  }

  // Evaluate all field groups and update their "Fixed" badges
  updateFixedBadges() {
    this.fieldRowTargets.forEach(row => {
      const groupId = row.dataset.groupId
      if (groupId) this.updateFixedBadge(groupId)
    })
  }

  // Evaluate whether a single field group is fully fixed and toggle its badge
  updateFixedBadge(groupId) {
    const badge = this.fixedBadgeTargets.find(el => el.dataset.groupId === groupId)
    if (!badge) return

    const row = this.fieldRowTargets.find(el => el.dataset.groupId === groupId)
    if (!row) return

    const termHasError = row.dataset.termHasError === 'true'
    const labelHasError = row.dataset.labelHasError === 'true'
    const isAuto = row.dataset.isAuto === 'true'

    // Auto-filled or constrained groups are always fixed
    if (isAuto) {
      badge.classList.remove('hidden')
      return
    }

    // If neither path has a validation error, the group is already compliant
    if (!termHasError && !labelHasError) {
      badge.classList.remove('hidden')
      return
    }

    // Determine the currently selected action
    const actionInput = this.hiddenActionTargets.find(
      el => el.dataset.groupId === groupId && el.dataset.role === 'term_action'
    )
    const action = actionInput ? actionInput.value : 'skip'

    if (action === 'skip') {
      badge.classList.add('hidden')
      return
    }

    if (action === 'set_value') {
      // Fixed if the term value input is filled (and label too if paired & has error)
      const termInput = this.termValueTargets.find(el => el.dataset.groupId === groupId)
      const labelInput = this.labelValueTargets.find(el => el.dataset.groupId === groupId)

      // Also check for select or plain text inputs in the set_value panel
      const valuePanel = document.getElementById(`set_value_${groupId}`)
      let termFilled = termInput && termInput.value.trim() !== ''
      let labelFilled = labelInput && labelInput.value.trim() !== ''

      if (!termFilled && valuePanel) {
        const sel = valuePanel.querySelector('select[name*="[value]"]')
        const txt = valuePanel.querySelector('input[name*="[value]"]:not([readonly])')
        if (sel && sel.value) termFilled = true
        if (txt && txt.value.trim()) termFilled = true
      }

      const termOk = !termHasError || termFilled
      const labelOk = !labelHasError || labelFilled
      badge.classList.toggle('hidden', !(termOk && labelOk))
      return
    }

    if (action === 'map_from' || action === 'resolve_paired') {
      // Fixed if all values in the map are resolved
      const state = this.mapResolveState[groupId]
      if (!state || !state.values || state.values.length === 0) {
        badge.classList.add('hidden')
        return
      }
      const allResolved = state.values.every(v => !!state.resolved[v])
      badge.classList.toggle('hidden', !allResolved)
      return
    }

    badge.classList.add('hidden')
  }

  escapeHtml(str) {
    const div = document.createElement('div')
    div.textContent = str
    return div.innerHTML
  }
}
