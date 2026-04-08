import { Controller } from "@hotwired/stimulus"
import consumer, { dispatchProjectStepRunsChangedFromCable } from "channels/consumer"

export default class extends Controller {
  static targets = ["statusCount", "statusIcon", "statusButton", "cellCount"]
  static values = { projectId: Number, publicationSnapshot: Boolean }

  connect() {
    console.log('[HeaderRunStatus] Connected, project ID:', this.projectIdValue)
    console.log('[HeaderRunStatus] Has cellCount target:', this.hasCellCountTarget)
    console.log('[HeaderRunStatus] statusCount targets:', this.statusCountTargets.length)
    this.subscribeToProject()
    this.syncCountsFromServer()
  }

  disconnect() {
    console.log('[HeaderRunStatus] Disconnected')
    this.unsubscribeFromProject()
  }

  subscribeToProject() {
    if (!this.projectIdValue) {
      console.warn('[HeaderRunStatus] No project ID, cannot subscribe')
      return
    }

    console.log(`[HeaderRunStatus] Subscribing to project_${this.projectIdValue}`)
    
    this.subscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectIdValue },
      {
        connected: () => {
          console.log(`[HeaderRunStatus] Connected to ProjectChannel for project ${this.projectIdValue}`)
          this.syncCountsFromServer()
        },
        disconnected: () => {
          console.log(`[HeaderRunStatus] Disconnected from ProjectChannel`)
        },
        rejected: () => {
          console.error('[HeaderRunStatus] Subscription REJECTED for project', this.projectIdValue)
        },
        received: (data) => {
          console.log('[HeaderRunStatus] Received broadcast:', JSON.stringify(data))
          dispatchProjectStepRunsChangedFromCable(data)
          this.handleStatusUpdate(data)
        }
      }
    )
  }

  unsubscribeFromProject() {
    if (this.subscription) {
      console.log('[HeaderRunStatus] Unsubscribing from ProjectChannel')
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  handleStatusUpdate(data) {
    if (data && data.event === 'queue_position_changed') {
      return
    }
    console.log('[HeaderRunStatus] handleStatusUpdate payload:', {
      step_id: data?.step_id,
      step_name: data?.step_name,
      parsing_status: data?.parsing_status,
      has_project_run_totals: !!data?.project_run_totals
    })
    if (data && data.project_unarchived === true) {
      console.log('[HeaderRunStatus] Project unarchive completed, reloading page')
      window.location.reload()
      return
    }
    this.updateFromBroadcast(data)
  }

  updateFromBroadcast(data) {
    // Update cell count from broadcast data
    if (this.hasCellCountTarget && data.cell_count !== undefined) {
      const cellCount = parseInt(data.cell_count) || 0
      const formatted = cellCount.toLocaleString()
      const colLabel = data.col_label || 'cells'
      console.log(`[HeaderRunStatus] Updating cell count: ${formatted} ${colLabel}`)
      this.cellCountTarget.innerHTML = `<i class="fas fa-circle text-gray-400 mr-1 flex-shrink-0"></i>${formatted} ${colLabel}`
    }

    // Update run status counts from broadcast project_run_totals
    // project_run_totals is { pending: N, running: N, success: N, failed: N }
    const totals = data.project_run_totals
    if (!totals) {
      console.log('[HeaderRunStatus] No project_run_totals in broadcast, syncing from server')
      this.syncCountsFromServer()
      return
    }
    // Broadcast aggregates are full totals; publication snapshot readers only see runs before public_at.
    if (this.publicationSnapshotValue) {
      console.log('[HeaderRunStatus] Publication snapshot reader: refreshing counts from server instead of broadcast totals')
      this.syncCountsFromServer()
      return
    }
    console.log('[HeaderRunStatus] Applying project_run_totals:', totals)

    this.statusCountTargets.forEach(countEl => {
      const statusKey = countEl.dataset.statusKey
      const newCount = parseInt(totals[statusKey]) || 0
      const oldCount = parseInt(countEl.textContent) || 0

      if (newCount !== oldCount) {
        console.log(`[HeaderRunStatus] Updating ${statusKey}: ${oldCount} -> ${newCount}`)
        countEl.textContent = newCount
        this.updateIconState(statusKey, newCount)
      }
    })
  }

  syncCountsFromServer() {
    if (!this.projectIdValue) return

    const url = `/projects/${this.projectIdValue}/run_counts`
    console.log('[HeaderRunStatus] syncCountsFromServer request:', url)
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
        console.log('[HeaderRunStatus] syncCountsFromServer response:', counts)
        this.updateFromBroadcast({ project_run_totals: counts, cell_count: counts.cell_count, col_label: counts.col_label })
      })
      .catch((error) => {
        console.warn('[HeaderRunStatus] Failed to sync run counts from server:', error)
      })
  }

  updateIconState(statusKey, count) {
    const isActive = count > 0

    // Update icon classes (color + spin)
    const iconEl = this.statusIconTargets.find(el => el.dataset.statusKey === statusKey)
    if (iconEl) {
      const iconBase = iconEl.dataset.iconBase || ''
      const iconSpin = iconEl.dataset.iconSpin || ''
      const activeColor = iconEl.dataset.activeColor || ''
      const inactiveColor = iconEl.dataset.inactiveColor || ''
      const colorClass = isActive ? activeColor : inactiveColor
      const spinClass = isActive && iconSpin ? ` ${iconSpin}` : ''
      iconEl.className = `${iconBase}${spinClass} text-base ${colorClass}`
    }

    // Update button disabled state and title
    const btnEl = this.statusButtonTargets.find(el => el.dataset.statusKey === statusKey)
    if (btnEl) {
      const label = iconEl?.dataset.uiLabel || statusKey
      btnEl.title = `${label} (${count})`
      btnEl.disabled = !isActive
      if (isActive) {
        btnEl.classList.remove('cursor-default')
      } else {
        btnEl.classList.add('cursor-default')
      }
    }
  }
}

