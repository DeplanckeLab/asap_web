import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    runId: Number,
    slurmJobId: String,
    projectId: Number
  }

  static targets = ["position", "waitTime", "queueInfo", "emptyQueue"]

  connect() {
    console.log(`[QueuePositionController] Connected for Run#${this.runIdValue}, SLURM Job#${this.slurmJobIdValue}, Project#${this.projectIdValue}`)
    console.log(`[QueuePositionController] Has position target: ${this.hasPositionTarget}`)
    console.log(`[QueuePositionController] Has queueInfo target: ${this.hasQueueInfoTarget}`)
    console.log(`[QueuePositionController] Has emptyQueue target: ${this.hasEmptyQueueTarget}`)
    
    // Show spinner initially in position target
    if (this.hasPositionTarget) {
      this.positionTarget.innerHTML = '<i class="fas fa-spinner fa-spin"></i>'
    }
    
    // Show queueInfo initially, hide emptyQueue
    if (this.hasQueueInfoTarget) {
      this.queueInfoTarget.classList.remove('hidden')
    }
    if (this.hasEmptyQueueTarget) {
      this.emptyQueueTarget.classList.add('hidden')
    }
    
    this.startPolling()
  }

  disconnect() {
    console.log(`[QueuePositionController] Disconnected`)
    this.stopPolling()
  }

  startPolling() {
    // Poll every 5 seconds for queue position
    this.pollInterval = setInterval(() => {
      this.updateQueuePosition()
    }, 5000)
    
    // Initial update
    this.updateQueuePosition()
  }

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval)
      this.pollInterval = null
    }
  }

  async updateQueuePosition() {
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
      console.log(`[QueuePositionController] Queue position data:`, data)
      
      if (data.queue_position !== null && data.queue_position !== undefined) {
        if (data.queue_position === 0) {
          // Position 0 means queue is empty - show empty queue message, hide position info
          console.log(`[QueuePositionController] Queue is empty, showing empty queue message`)
          if (this.hasQueueInfoTarget) {
            this.queueInfoTarget.classList.add('hidden')
          }
          if (this.hasEmptyQueueTarget) {
            this.emptyQueueTarget.classList.remove('hidden')
          }
        } else if (data.queue_position > 0) {
          // Show actual queue position
          const currentPosition = this.hasPositionTarget ? this.positionTarget.textContent.trim() : null
          console.log(`[QueuePositionController] Updating queue position: ${currentPosition} -> ${data.queue_position}`)
          
          if (this.hasQueueInfoTarget) {
            this.queueInfoTarget.classList.remove('hidden')
          }
          if (this.hasEmptyQueueTarget) {
            this.emptyQueueTarget.classList.add('hidden')
          }
          if (this.hasPositionTarget) {
            const oldPosition = this.positionTarget.textContent.trim()
            this.positionTarget.textContent = data.queue_position
            if (oldPosition !== String(data.queue_position) && oldPosition !== '') {
              console.log(`[QueuePositionController] Position updated from ${oldPosition} to ${data.queue_position}`)
            }
          }
        } else {
          // Invalid position - show spinner (keep loading)
          console.log(`[QueuePositionController] Invalid position, showing spinner`)
          if (this.hasPositionTarget) {
            this.positionTarget.innerHTML = '<i class="fas fa-spinner fa-spin"></i>'
          }
        }
      } else {
        // No queue position data yet - show spinner (keep loading)
        console.log(`[QueuePositionController] No queue position data, showing spinner`)
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

      // Also update wait time if available
      if (data.wait_time !== null && data.wait_time !== undefined && this.hasWaitTimeTarget) {
        this.waitTimeTarget.textContent = this.formatDuration(data.wait_time)
      }
    } catch (error) {
      console.warn(`[QueuePositionController] Error fetching queue position:`, error)
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
}

