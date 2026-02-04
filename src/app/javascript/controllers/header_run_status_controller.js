import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = ["statusButton", "statusIcon", "statusCount"]
  static values = { projectId: Number, statusIcons: Array }

  connect() {
    console.log('[HeaderRunStatus] Connected, project ID:', this.projectIdValue)
    this.subscribeToProject()
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
        },
        disconnected: () => {
          console.log(`[HeaderRunStatus] Disconnected from ProjectChannel`)
        },
        received: (data) => {
          console.log('[HeaderRunStatus] Received data:', data)
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
    // Fetch updated run counts from server
    console.log('[HeaderRunStatus] Fetching updated run counts...')
    
    fetch(`/projects/${this.projectIdValue}/run_counts`, {
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
    .then(counts => {
      console.log('[HeaderRunStatus] Received run counts:', counts)
      this.updateCounts(counts)
    })
    .catch(error => {
      console.error('[HeaderRunStatus] Error fetching run counts:', error)
    })
  }

  updateCounts(counts) {
    // counts is expected to be { waiting: N, running: N, completed: N, failed: N }
    const statusIconsConfig = this.statusIconsValue || []
    
    // Build a map of status key to config
    const configByKey = {}
    statusIconsConfig.forEach(config => {
      configByKey[config.key] = config
    })

    // Update each status count
    this.statusCountTargets.forEach(countEl => {
      const statusKey = countEl.dataset.statusKey
      const newCount = counts[statusKey] || 0
      const oldCount = parseInt(countEl.textContent) || 0
      
      if (newCount !== oldCount) {
        console.log(`[HeaderRunStatus] Updating ${statusKey}: ${oldCount} -> ${newCount}`)
        countEl.textContent = newCount
        
        // Update the corresponding button and icon
        const button = this.statusButtonTargets.find(b => b.dataset.statusKey === statusKey)
        const icon = this.statusIconTargets.find(i => i.dataset.statusKey === statusKey)
        const config = configByKey[statusKey]
        
        if (button && config) {
          const isActive = newCount > 0
          button.title = `${config.label} (${newCount})`
          button.disabled = !isActive
          
          if (isActive) {
            button.classList.remove('cursor-default')
          } else {
            button.classList.add('cursor-default')
          }
        }
        
        if (icon && config) {
          const isActive = newCount > 0
          // Update icon color
          icon.classList.remove(config.active_color, config.inactive_color)
          icon.classList.add(isActive ? config.active_color : config.inactive_color)
          
          // Update spin class for running status
          if (config.icon_spin) {
            if (isActive) {
              icon.classList.add(config.icon_spin)
            } else {
              icon.classList.remove(config.icon_spin)
            }
          }
        }
      }
    })
  }
}

