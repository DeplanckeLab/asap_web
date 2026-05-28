import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Visible label prefix for queue position (matches server/tooltip wording).
const SLURM_QUEUE_LABEL = "Slurm queue position:"

export default class extends Controller {
  static values = {
    runId: Number,
    slurmJobId: String,
    projectId: String,
    submittedAt: String
  }

  static targets = ["position", "waitTime", "queueInfo", "emptyQueue", "waitingTime", "waitingIcon", "queueLine", "blockerMessage", "statusMessage"]

  connect() {
    this.subscribeToProject()
    this.updateQueuePosition()

    if (this.hasSubmittedAtValue && this.hasWaitingTimeTarget) {
      this.startWaitingTimer()
    }
  }

  disconnect() {
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
    if (!data) {
      return
    }

    // When the run this controller belongs to leaves the pending/waiting state,
    // the queue information is meaningless and must disappear. Use
    // hideSlurmQueueRow so single-run waiting panels only hide the queue line
    // (keeping the surrounding waiting UI) while compact list rows remove the
    // whole "Queue: ..." element.
    if (data.event === "run_status_changed" && data.run_status) {
      if (Number(data.run_status.run_id) !== Number(this.runIdValue)) {
        return
      }
      const statusId = Number(data.run_status.status_id)
      const isWaiting = statusId === 1 || statusId === 6
      if (!isWaiting) {
        this.hideSlurmQueueRow()
      }
      return
    }

    if (data.event !== "queue_position_changed") {
      return
    }
    if (!data.run_id || Number(data.run_id) !== Number(this.runIdValue)) {
      return
    }

    if (data.show_slurm_queue === false) {
      this.hideSlurmQueueRow()
      this.clearSlurmHover()
      return
    }

    if (data.show_slurm_queue === true) {
      this.showSlurmQueueRow()
    }

    if (data.slurm_queue_hover) {
      this.syncSlurmHover(data.slurm_queue_hover)
    } else if (data.queue_position === null || data.queue_position === undefined) {
      this.clearSlurmHover()
    }

    this.applySlurmBlocker(data.slurm_blocker_message)
    this.applyQueuePosition(data.queue_position, data.slurm_queue_hover)
  }

  // Fully tears down the controller and removes its root element from the DOM.
  // Safe to call multiple times.
  removeElement() {
    this.stopWaitingTimer()
    this.unsubscribeFromProject()
    if (this.element && this.element.parentNode) {
      this.element.parentNode.removeChild(this.element)
    }
  }

  syncSlurmHover(text) {
    if (!text) {
      this.clearSlurmHover()
      return
    }
    const el = this.hasWaitingIconTarget ? this.waitingIconTarget : this.element
    el.setAttribute("title", text)
    el.setAttribute("aria-label", text)
    el.classList.add("cursor-help")
  }

  clearSlurmHover() {
    const el = this.hasWaitingIconTarget ? this.waitingIconTarget : this.element
    el.removeAttribute("title")
    el.removeAttribute("aria-label")
    el.classList.remove("cursor-help")
  }

  hideSlurmQueueRow() {
    // Preferred path: templates that expose named targets (single-run and
    // parsing views) hide only the queue row so the surrounding waiting UI
    // stays visible.
    if (this.hasQueueLineTarget) {
      this.queueLineTarget.classList.add("hidden")
      if (this.hasEmptyQueueTarget) {
        this.emptyQueueTarget.classList.add("hidden")
      }
      return
    }
    if (this.hasQueueInfoTarget) {
      this.queueInfoTarget.classList.add("hidden")
      if (this.hasEmptyQueueTarget) {
        this.emptyQueueTarget.classList.add("hidden")
      }
      return
    }

    // Fallback for compact templates (runs table, pipeline runs list) that do
    // not wrap the queue line in a dedicated target: drop the whole
    // controller root, which is the "Queue: ..." element itself.
    this.removeElement()
  }

  showSlurmQueueRow() {
    if (this.hasQueueLineTarget) {
      this.queueLineTarget.classList.remove("hidden")
    } else if (this.hasQueueInfoTarget) {
      this.queueInfoTarget.classList.remove("hidden")
    }
  }

  startWaitingTimer() {
    this.waitingTimerInterval = setInterval(() => {
      this.updateWaitingTime()
    }, 1000)
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
        this.waitingTimeTarget.textContent = "0:00"
        return
      }

      const hours = Math.floor(elapsedSeconds / 3600)
      const minutes = Math.floor((elapsedSeconds % 3600) / 60)
      const seconds = elapsedSeconds % 60

      const formatted = hours > 0
        ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
        : `${minutes}:${String(seconds).padStart(2, "0")}`

      this.waitingTimeTarget.textContent = formatted
    } catch (error) {
      this.waitingTimeTarget.textContent = "--:--"
    }
  }

  async updateQueuePosition() {
    if (!this.slurmJobIdValue) {
      return
    }

    if (!this.hasPositionTarget) {
      return
    }

    const url = `/projects/${this.projectIdValue}/queue_position?slurm_job_id=${encodeURIComponent(this.slurmJobIdValue)}&run_id=${encodeURIComponent(this.runIdValue)}`

    try {
      const response = await fetch(url, {
        method: "GET",
        headers: {
          Accept: "application/json",
          "X-Requested-With": "XMLHttpRequest"
        },
        credentials: "same-origin"
      })

      if (!response.ok) {
        if (this.hasPositionTarget) {
          this.positionTarget.textContent = "(error checking queue position)"
        }
        this.positionTarget.removeAttribute("data-slurm-queue-position")
        return
      }

      const data = await response.json()

      if (data.show_slurm_queue === false) {
        this.hideSlurmQueueRow()
        return
      }

      if (data.show_slurm_queue !== false) {
        this.showSlurmQueueRow()
      }

      if (data.slurm_queue_hover) {
        this.syncSlurmHover(data.slurm_queue_hover)
      }

      this.applySlurmBlocker(data.slurm_blocker_message)
      this.applyQueuePosition(data.queue_position, data.slurm_queue_hover)

      if (data.wait_time !== null && data.wait_time !== undefined && this.hasWaitTimeTarget) {
        this.waitTimeTarget.textContent = this.formatDuration(data.wait_time)
      }
    } catch (error) {
      if (this.hasPositionTarget) {
        this.positionTarget.textContent = `(error: ${error.message})`
      }
      this.positionTarget.removeAttribute("data-slurm-queue-position")
    }
  }

  formatDuration(seconds) {
    if (!seconds && seconds !== 0) return "0s"

    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60

    if (hours > 0) {
      return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`
    }
    return `${minutes}:${String(secs).padStart(2, "0")}`
  }

  applySlurmBlocker(message) {
    if (!this.hasBlockerMessageTarget) {
      return
    }

    const text = message != null ? String(message).trim() : ""
    if (text === "") {
      this.blockerMessageTarget.classList.add("hidden")
      this.blockerMessageTarget.textContent = ""
      if (this.hasStatusMessageTarget) {
        this.statusMessageTarget.classList.remove("hidden")
      }
      return
    }

    this.blockerMessageTarget.textContent = text
    this.blockerMessageTarget.classList.remove("hidden")
    if (this.hasStatusMessageTarget) {
      this.statusMessageTarget.classList.add("hidden")
    }
  }

  applyQueuePosition(queuePosition, slurmQueueHover) {
    if (!this.hasPositionTarget) {
      return
    }

    if (slurmQueueHover) {
      this.syncSlurmHover(slurmQueueHover)
    }

    if (queuePosition !== null && queuePosition !== undefined) {
      if (queuePosition === 0) {
        if (this.hasQueueInfoTarget) {
          this.queueInfoTarget.classList.add("hidden")
        }
        if (this.hasEmptyQueueTarget) {
          this.emptyQueueTarget.classList.remove("hidden")
        }
        this.positionTarget.removeAttribute("data-slurm-queue-position")
        return
      }

      if (queuePosition > 0) {
        if (this.hasQueueInfoTarget) {
          this.queueInfoTarget.classList.remove("hidden")
        }
        if (this.hasEmptyQueueTarget) {
          this.emptyQueueTarget.classList.add("hidden")
        }
        this.positionTarget.textContent = String(queuePosition)
        this.positionTarget.setAttribute("data-slurm-queue-position", String(queuePosition))
        this.positionTarget.setAttribute("aria-label", `${SLURM_QUEUE_LABEL} ${queuePosition}`)
        return
      }
    }

    if (this.hasQueueInfoTarget) {
      this.queueInfoTarget.classList.remove("hidden")
    }
    if (this.hasEmptyQueueTarget) {
      this.emptyQueueTarget.classList.add("hidden")
    }
    this.positionTarget.innerHTML = '<i class="fas fa-spinner fa-spin"></i>'
    this.positionTarget.removeAttribute("data-slurm-queue-position")
    this.positionTarget.removeAttribute("aria-label")
  }
}
