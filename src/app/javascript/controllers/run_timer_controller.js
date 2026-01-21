import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["elapsedTime"]
  static values = { 
    startTime: String,
    submittedAt: String
  }

  connect() {
    // Only start timer if we have a start time (for running) or submitted_at (for waiting)
    if (this.hasStartTimeValue || this.hasSubmittedAtValue) {
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
    if (!this.hasElapsedTimeTarget) {
      return
    }

    try {
      let elapsedSeconds = 0
      
      // For running: use start_time
      if (this.hasStartTimeValue) {
        const startTime = new Date(this.startTimeValue)
        const now = new Date()
        elapsedSeconds = Math.floor((now - startTime) / 1000)
      }
      // For waiting: use submitted_at
      else if (this.hasSubmittedAtValue) {
        const submittedAt = new Date(this.submittedAtValue)
        const now = new Date()
        elapsedSeconds = Math.floor((now - submittedAt) / 1000)
      }
      
      if (elapsedSeconds < 0) {
        this.elapsedTimeTarget.textContent = '0:00'
        return
      }

      // Format as MM:SS or HH:MM:SS
      const hours = Math.floor(elapsedSeconds / 3600)
      const minutes = Math.floor((elapsedSeconds % 3600) / 60)
      const seconds = elapsedSeconds % 60

      const formatted = hours > 0
        ? `${hours}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
        : `${minutes}:${String(seconds).padStart(2, '0')}`

      this.elapsedTimeTarget.textContent = formatted
    } catch (error) {
      console.error('[RunTimerController] Error updating elapsed time:', error)
      this.elapsedTimeTarget.textContent = '--:--'
    }
  }
}









