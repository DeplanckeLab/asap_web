import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="project-creation"
export default class extends Controller {
  static targets = [
    "step1",
    "step1Icon",
    "step1Status",
    "step2",
    "step2Icon",
    "step2Status",
    "step2Spinner",
    "step3",
    "step3Icon",
    "step3Status",
    "step3Spinner",
    "projectKey"
  ]

  static values = {
    projectId: Number
  }

  connect() {
    this.subscription = null
    this.subscribeToProject()
  }

  disconnect() {
    this.unsubscribeFromProject()
  }

  subscribeToProject() {
    if (!this.projectIdValue) {
      console.error('[ProjectCreation] No project ID provided')
      return
    }

    console.log(`[ProjectCreation] Subscribing to project ${this.projectIdValue}`)

    this.subscription = consumer.subscriptions.create(
      {
        channel: "ProjectChannel",
        project_id: this.projectIdValue
      },
      {
        connected: () => {
          console.log(`[ProjectCreation] Connected to ProjectChannel for project ${this.projectIdValue}`)
        },
        disconnected: () => {
          console.warn(`[ProjectCreation] Disconnected from ProjectChannel for project ${this.projectIdValue}`)
        },
        received: (data) => {
          console.log(`[ProjectCreation] Received websocket message:`, data)
          this.handleStatusUpdate(data)
        }
      }
    )
  }

  unsubscribeFromProject() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
      console.log(`[ProjectCreation] Unsubscribed from ProjectChannel for project ${this.projectIdValue}`)
    }
  }

  handleStatusUpdate(data) {
    // Only process creation stage updates
    if (data.stage !== 'creation') {
      return
    }

    // Update step 1 (always complete)
    if (data.project_key) {
      this.updateStep1(data.project_key)
    }

    // Update step 2 (parsing)
    if (data.parsing_status !== undefined) {
      this.updateStep2(data.parsing_status, data.parsing_complete)
    }

    // Update step 3 (metadata)
    if (data.metadata_status !== undefined) {
      this.updateStep3(data.metadata_status, data.metadata_complete)
    }

    // If all complete, redirect
    if (data.all_complete && data.redirect_url) {
      this.unsubscribeFromProject()
      // Small delay before redirect to show final state
      setTimeout(() => {
        window.location.href = data.redirect_url
      }, 1000)
    }
  }

  updateStep1(projectKey) {
    if (projectKey && this.hasProjectKeyTarget) {
      this.projectKeyTarget.textContent = projectKey
    }
    // Step 1 is always complete
    if (this.hasStep1IconTarget) {
      this.step1IconTarget.classList.remove('bg-gray-300', 'dark:bg-gray-600', 'text-gray-700', 'dark:text-gray-300')
      this.step1IconTarget.classList.add('bg-green-500', 'text-white')
    }
    if (this.hasStep1StatusTarget) {
      this.step1StatusTarget.textContent = 'Completed'
      this.step1StatusTarget.classList.remove('text-gray-600', 'dark:text-gray-400')
      this.step1StatusTarget.classList.add('text-green-600', 'dark:text-green-400')
    }
  }

  updateStep2(status, complete) {
    if (this.hasStep2IconTarget) {
      if (complete) {
        this.step2IconTarget.classList.remove('bg-gray-300', 'dark:bg-gray-600', 'text-gray-700', 'dark:text-gray-300')
        this.step2IconTarget.classList.add('bg-green-500', 'text-white')
      } else if (status === 'running') {
        this.step2IconTarget.classList.remove('bg-gray-300', 'dark:bg-gray-600', 'text-gray-700', 'dark:text-gray-300')
        this.step2IconTarget.classList.add('bg-blue-500', 'text-white')
      }
    }

    if (this.hasStep2StatusTarget) {
      let statusText = 'Waiting...'
      if (status === 'running') {
        statusText = 'In progress...'
      } else if (status === 'complete') {
        statusText = 'Completed'
      } else if (status === 'failed') {
        statusText = 'Failed'
      }

      this.step2StatusTarget.textContent = statusText

      if (complete) {
        this.step2StatusTarget.classList.remove('text-gray-600', 'dark:text-gray-400', 'text-yellow-600', 'dark:text-yellow-400', 'text-red-600', 'dark:text-red-400')
        this.step2StatusTarget.classList.add('text-green-600', 'dark:text-green-400')
      } else if (status === 'running') {
        this.step2StatusTarget.classList.remove('text-gray-600', 'dark:text-gray-400', 'text-green-600', 'dark:text-green-400', 'text-red-600', 'dark:text-red-400')
        this.step2StatusTarget.classList.add('text-yellow-600', 'dark:text-yellow-400')
      } else if (status === 'failed') {
        this.step2StatusTarget.classList.remove('text-gray-600', 'dark:text-gray-400', 'text-yellow-600', 'dark:text-yellow-400', 'text-green-600', 'dark:text-green-400')
        this.step2StatusTarget.classList.add('text-red-600', 'dark:text-red-400')
      }
    }

    if (this.hasStep2SpinnerTarget) {
      if (status === 'running') {
        this.step2SpinnerTarget.classList.remove('hidden')
      } else {
        this.step2SpinnerTarget.classList.add('hidden')
      }
    }
  }

  updateStep3(status, complete) {
    if (this.hasStep3IconTarget) {
      if (complete) {
        this.step3IconTarget.classList.remove('bg-gray-300', 'dark:bg-gray-600', 'text-gray-700', 'dark:text-gray-300')
        this.step3IconTarget.classList.add('bg-green-500', 'text-white')
      } else if (status === 'running') {
        this.step3IconTarget.classList.remove('bg-gray-300', 'dark:bg-gray-600', 'text-gray-700', 'dark:text-gray-300')
        this.step3IconTarget.classList.add('bg-blue-500', 'text-white')
      }
    }

    if (this.hasStep3StatusTarget) {
      let statusText = 'Waiting...'
      if (status === 'running') {
        statusText = 'In progress...'
      } else if (status === 'complete') {
        statusText = 'Completed'
      } else if (status === 'failed') {
        statusText = 'Failed'
      }

      this.step3StatusTarget.textContent = statusText

      if (complete) {
        this.step3StatusTarget.classList.remove('text-gray-600', 'dark:text-gray-400', 'text-yellow-600', 'dark:text-yellow-400', 'text-red-600', 'dark:text-red-400')
        this.step3StatusTarget.classList.add('text-green-600', 'dark:text-green-400')
      } else if (status === 'running') {
        this.step3StatusTarget.classList.remove('text-gray-600', 'dark:text-gray-400', 'text-green-600', 'dark:text-green-400', 'text-red-600', 'dark:text-red-400')
        this.step3StatusTarget.classList.add('text-yellow-600', 'dark:text-yellow-400')
      } else if (status === 'failed') {
        this.step3StatusTarget.classList.remove('text-gray-600', 'dark:text-gray-400', 'text-yellow-600', 'dark:text-yellow-400', 'text-green-600', 'dark:text-green-400')
        this.step3StatusTarget.classList.add('text-red-600', 'dark:text-red-400')
      }
    }

    if (this.hasStep3SpinnerTarget) {
      if (status === 'running') {
        this.step3SpinnerTarget.classList.remove('hidden')
      } else {
        this.step3SpinnerTarget.classList.add('hidden')
      }
    }
  }
}

