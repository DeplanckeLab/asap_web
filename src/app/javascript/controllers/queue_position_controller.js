import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static values = {
    runId: Number,
    slurmJobId: String,
    projectId: String,
    submittedAt: String
  }

  static targets = ["position", "waitTime", "queueInfo", "emptyQueue", "waitingTime"]

  connect() {
    console.log(`[QueuePositionController] ===== CONNECT() CALLED =====`)
    console.log(`[QueuePositionController] Element:`, this.element)
    console.log(`[QueuePositionController] Element HTML:`, this.element.outerHTML.substring(0, 500))
    console.log(`[QueuePositionController] Run ID: ${this.runIdValue}`)
    console.log(`[QueuePositionController] SLURM Job ID: ${this.slurmJobIdValue}`)
    console.log(`[QueuePositionController] Project ID: ${this.projectIdValue}`)
    console.log(`[QueuePositionController] Has position target: ${this.hasPositionTarget}`)
    console.log(`[QueuePositionController] Has queueInfo target: ${this.hasQueueInfoTarget}`)
    console.log(`[QueuePositionController] Has emptyQueue target: ${this.hasEmptyQueueTarget}`)
    
    // Validate values
    if (!this.runIdValue) {
      console.warn(`[QueuePositionController] WARNING: runIdValue is missing!`)
    }
    if (!this.slurmJobIdValue) {
      console.warn(`[QueuePositionController] WARNING: slurmJobIdValue is missing!`)
    }
    if (!this.projectIdValue) {
      console.warn(`[QueuePositionController] WARNING: projectIdValue is missing!`)
    }
    
    // Show spinner initially in position target
    if (this.hasPositionTarget) {
      console.log(`[QueuePositionController] Setting spinner in position target`)
      this.positionTarget.innerHTML = '<i class="fas fa-spinner fa-spin"></i>'
    } else {
      console.warn(`[QueuePositionController] WARNING: position target not found!`)
    }
    
    // Show queueInfo initially, hide emptyQueue
    if (this.hasQueueInfoTarget) {
      console.log(`[QueuePositionController] Showing queueInfo target`)
      this.queueInfoTarget.classList.remove('hidden')
    } else {
      console.warn(`[QueuePositionController] WARNING: queueInfo target not found!`)
    }
    if (this.hasEmptyQueueTarget) {
      console.log(`[QueuePositionController] Hiding emptyQueue target`)
      this.emptyQueueTarget.classList.add('hidden')
    } else {
      console.warn(`[QueuePositionController] WARNING: emptyQueue target not found!`)
    }
    
    this.subscribeToProject()
    this.updateQueuePosition()
    
    // Start waiting timer if submittedAt is available
    if (this.hasSubmittedAtValue && this.hasWaitingTimeTarget) {
      console.log(`[QueuePositionController] Starting waiting timer from: ${this.submittedAtValue}`)
      this.startWaitingTimer()
    }
  }

  disconnect() {
    console.log(`[QueuePositionController] Disconnected`)
    this.unsubscribeFromProject()
    this.stopWaitingTimer()
  }

  subscribeToProject() {
    if (!this.projectIdValue) {
      return
    }

    this.subscription = consumer.subscriptions.create(
      {
        channel: "ProjectChannel",
        project_id: this.projectIdValue
      },
      {
        received: (data) => this.handleProjectBroadcast(data)
      }
    )
  }

  unsubscribeFromProject() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  handleProjectBroadcast(data) {
    if (!data || data.event !== 'queue_position_changed') {
      return
    }
    if (!data.run_id || Number(data.run_id) !== Number(this.runIdValue)) {
      return
    }

    this.applyQueuePosition(data.queue_position)
  }

  startWaitingTimer() {
    // Update every second
    this.waitingTimerInterval = setInterval(() => {
      this.updateWaitingTime()
    }, 1000)
    
    // Initial update
    this.updateWaitingTime()
  }

  stopWaitingTimer() {
    if (this.waitingTimerInterval) {
      clearInterval(this.waitingTimerInterval)
      this.waitingTimerInterval = null
    }
  }

  updateWaitingTime() {
    if (!this.hasSubmittedAtValue || !this.hasWaitingTimeTarget) {
      return
    }

    try {
      const submittedAt = new Date(this.submittedAtValue)
      const now = new Date()
      const elapsedSeconds = Math.floor((now - submittedAt) / 1000)
      
      if (elapsedSeconds < 0) {
        this.waitingTimeTarget.textContent = '0:00'
        return
      }

      // Format as MM:SS or HH:MM:SS
      const hours = Math.floor(elapsedSeconds / 3600)
      const minutes = Math.floor((elapsedSeconds % 3600) / 60)
      const seconds = elapsedSeconds % 60

      const formatted = hours > 0
        ? `${hours}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
        : `${minutes}:${String(seconds).padStart(2, '0')}`

      this.waitingTimeTarget.textContent = formatted
    } catch (error) {
      console.error(`[QueuePositionController] Error updating waiting time:`, error)
      this.waitingTimeTarget.textContent = '--:--'
    }
  }

  async updateQueuePosition() {
    console.log(`[QueuePositionController] ===== updateQueuePosition() CALLED =====`)
    console.log(`[QueuePositionController] slurmJobIdValue: ${this.slurmJobIdValue}`)
    console.log(`[QueuePositionController] runIdValue: ${this.runIdValue}`)
    console.log(`[QueuePositionController] projectIdValue: ${this.projectIdValue}`)
    console.log(`[QueuePositionController] hasPositionTarget: ${this.hasPositionTarget}`)
    
    if (!this.slurmJobIdValue) {
      console.warn(`[QueuePositionController] No SLURM job ID, skipping update`)
      return
    }

    if (!this.hasPositionTarget) {
      console.warn(`[QueuePositionController] No position target found, skipping update`)
      return
    }

    const url = `/projects/${this.projectIdValue}/queue_position?slurm_job_id=${this.slurmJobIdValue}&run_id=${this.runIdValue}`
    console.log(`[QueuePositionController] Fetching queue position from: ${url}`)

    try {
      // Fetch queue position from the server
      const response = await fetch(url, {
        method: 'GET',
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest'
        },
        credentials: 'same-origin'
      })

      console.log(`[QueuePositionController] Response status: ${response.status}`)

      if (!response.ok) {
        const errorText = await response.text()
        console.warn(`[QueuePositionController] Failed to fetch queue position: ${response.status} - ${errorText}`)
        if (this.hasPositionTarget) {
          this.positionTarget.textContent = `(error checking queue position)`
        }
        return
      }

      const data = await response.json()
      console.log(`[QueuePositionController] Queue position data received:`, data)
      console.log(`[QueuePositionController] queue_position value:`, data.queue_position, `(type: ${typeof data.queue_position})`)
      console.log(`[QueuePositionController] wait_time value:`, data.wait_time)
      this.applyQueuePosition(data.queue_position)

      // Also update wait time if available
      if (data.wait_time !== null && data.wait_time !== undefined && this.hasWaitTimeTarget) {
        this.waitTimeTarget.textContent = this.formatDuration(data.wait_time)
      }
    } catch (error) {
      console.error(`[QueuePositionController] ===== ERROR IN updateQueuePosition() =====`)
      console.error(`[QueuePositionController] Error type:`, error.constructor.name)
      console.error(`[QueuePositionController] Error message:`, error.message)
      console.error(`[QueuePositionController] Error stack:`, error.stack)
      if (this.hasPositionTarget) {
        this.positionTarget.textContent = `(error: ${error.message})`
      }
    }
  }

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

  applyQueuePosition(queuePosition) {
    if (queuePosition !== null && queuePosition !== undefined) {
      if (queuePosition === 0) {
        if (this.hasQueueInfoTarget) {
          this.queueInfoTarget.classList.add('hidden')
        }
        if (this.hasEmptyQueueTarget) {
          this.emptyQueueTarget.classList.remove('hidden')
        }
        return
      }

      if (queuePosition > 0) {
        if (this.hasQueueInfoTarget) {
          this.queueInfoTarget.classList.remove('hidden')
        }
        if (this.hasEmptyQueueTarget) {
          this.emptyQueueTarget.classList.add('hidden')
        }
        if (this.hasPositionTarget) {
          this.positionTarget.textContent = queuePosition
        }
        return
      }
    }

    if (this.hasQueueInfoTarget) {
      this.queueInfoTarget.classList.remove('hidden')
    }
    if (this.hasEmptyQueueTarget) {
      this.emptyQueueTarget.classList.add('hidden')
    }
    if (this.hasPositionTarget) {
      this.positionTarget.innerHTML = '<i class="fas fa-spinner fa-spin"></i>'
    }
  }
}

