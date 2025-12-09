import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = ["statusContainer", "spinner", "statusText"]
  static values = { 
    projectId: Number,
    initialStatus: String
  }

  connect() {
    console.log(`[ParsingStatusController] Connected for project ${this.projectIdValue}, initial status: ${this.initialStatusValue}`)
    
    // Only subscribe if parsing is in progress
    if (this.initialStatusValue === 'running' || this.initialStatusValue === 'waiting') {
      this.subscribeToProject()
    }
  }

  disconnect() {
    this.unsubscribeFromProject()
  }

  subscribeToProject() {
    if (!this.projectIdValue) {
      console.error('[ParsingStatusController] No project ID provided')
      return
    }

    console.log(`[ParsingStatusController] Subscribing to project ${this.projectIdValue}`)

    this.subscription = consumer.subscriptions.create(
      {
        channel: "ProjectChannel",
        project_id: this.projectIdValue
      },
      {
        connected: () => {
          console.log(`[ParsingStatusController] Connected to ProjectChannel for project ${this.projectIdValue}`)
        },
        disconnected: () => {
          console.warn(`[ParsingStatusController] Disconnected from ProjectChannel for project ${this.projectIdValue}`)
        },
        received: (data) => {
          console.log(`[ParsingStatusController] Received websocket message:`, data)
          this.handleStatusUpdate(data)
        }
      }
    )
  }

  unsubscribeFromProject() {
    if (this.subscription) {
      console.log(`[ParsingStatusController] Unsubscribing from project ${this.projectIdValue}`)
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  handleStatusUpdate(data) {
    // Only process parsing-related updates
    if (data.parsing_status) {
      const status = data.parsing_status
      console.log(`[ParsingStatusController] Parsing status update: ${status}`)

      if (status === 'complete') {
        this.showComplete()
      } else if (status === 'failed') {
        this.showFailed()
      } else if (status === 'running') {
        this.showRunning()
      } else if (status === 'waiting') {
        this.showWaiting()
      }
    }
  }

  showRunning() {
    if (!this.hasStatusContainerTarget) return
    
    this.statusContainerTarget.className = 'alert alert-info'
    this.statusContainerTarget.style.display = 'block'
    this.statusContainerTarget.innerHTML = `
      <i class='fas fa-spinner fa-spin me-2'></i>
      <strong>Your project file is being parsed...</strong>
      <div class='small mt-1'>Parsing in progress</div>
    `
  }

  showWaiting() {
    if (!this.hasStatusContainerTarget) return
    
    this.statusContainerTarget.className = 'alert alert-info'
    this.statusContainerTarget.style.display = 'block'
    this.statusContainerTarget.innerHTML = `
      <i class='fas fa-spinner fa-spin me-2'></i>
      <strong>Your project file is being parsed...</strong>
      <div class='small mt-1'>Waiting to start parsing</div>
    `
  }

  showComplete() {
    if (!this.hasStatusContainerTarget) return
    
    this.statusContainerTarget.className = 'alert alert-success'
    this.statusContainerTarget.style.display = 'block'
    this.statusContainerTarget.innerHTML = `
      <strong>Parsing completed successfully!</strong>
      <div class='small mt-1'>Your project is ready to use.</div>
    `
    
    // Unsubscribe since parsing is complete
    this.unsubscribeFromProject()
    
    // Reload the page after a short delay to show updated content
    setTimeout(() => {
      window.location.reload()
    }, 2000)
  }

  showFailed() {
    if (!this.hasStatusContainerTarget) return
    
    this.statusContainerTarget.className = 'alert alert-danger'
    this.statusContainerTarget.style.display = 'block'
    this.statusContainerTarget.innerHTML = `
      <strong>Parsing failed</strong>
      <div class='small mt-1'>There was an error parsing your project file. Please try again or contact support.</div>
    `
    
    // Unsubscribe since parsing failed
    this.unsubscribeFromProject()
  }
}

