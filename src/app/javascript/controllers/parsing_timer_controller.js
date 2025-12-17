import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["elapsedTime", "expectedTime"]
  static values = { 
    startTime: String,
    expectedDuration: Number
  }

  connect() {
    // Only start timer if we have a start time
    if (this.hasStartTimeValue) {
      this.startTimer()
    }
  }

  disconnect() {
    this.stopTimer()
  }

  startTimer() {
    // Clear any existing interval
    this.stopTimer()
    
    // Update immediately
    this.updateElapsedTime()
    
    // Update every second
    this.timerInterval = setInterval(() => {
      this.updateElapsedTime()
    }, 1000)
  }

  stopTimer() {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
      this.timerInterval = null
    }
  }

  updateElapsedTime() {
    if (!this.hasStartTimeValue || !this.hasElapsedTimeTarget) {
      return
    }

    try {
      const startTime = new Date(this.startTimeValue)
      const now = new Date()
      const elapsedSeconds = Math.floor((now - startTime) / 1000)
      
      if (elapsedSeconds < 0) {
        this.elapsedTimeTarget.textContent = '--:--:--'
        return
      }

      // Format as HH:MM:SS
      const hours = Math.floor(elapsedSeconds / 3600)
      const minutes = Math.floor((elapsedSeconds % 3600) / 60)
      const seconds = elapsedSeconds % 60

      const formatted = hours > 0
        ? `${hours}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
        : `${minutes}:${String(seconds).padStart(2, '0')}`

      this.elapsedTimeTarget.textContent = formatted
    } catch (error) {
      console.error('[ParsingTimerController] Error updating elapsed time:', error)
      this.elapsedTimeTarget.textContent = '--:--:--'
    }
  }

  formatDuration(seconds) {
    if (!seconds || seconds <= 0) {
      return '--:--:--'
    }

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

