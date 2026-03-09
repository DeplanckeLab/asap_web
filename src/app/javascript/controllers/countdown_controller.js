import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display"]
  static values = { endMs: Number, idleDays: Number, lockTitle: Boolean }

  connect() {
    this.update()
    this.interval = setInterval(() => this.update(), 1000)
  }

  disconnect() {
    if (this.interval) {
      clearInterval(this.interval)
      this.interval = null
    }
  }

  update() {
    const remainingMs = Math.max(this.endMsValue - Date.now(), 0)
    const totalSeconds = Math.floor(remainingMs / 1000)

    if (totalSeconds <= 0) {
      const message = "IMMINENT"

      this.element.classList.remove(
        "bg-amber-100",
        "text-amber-800",
        "border-amber-200",
        "bg-amber-500/20",
        "text-amber-200",
        "border-amber-400/40"
      )
      this.element.classList.add("bg-red-100", "text-red-800", "border-red-200")

      this.displayTargets.forEach((target) => {
        target.textContent = message
      })

      if (!this.lockTitleValue) {
        const days = Number(this.idleDaysValue)
        const hasDays = Number.isFinite(days) && days > 0
        this.element.title = hasDays
          ? `This project was inactive for more than ${Math.floor(days)} days and is about to be deleted`
          : "This project is about to be deleted"
      }

      if (this.interval) {
        clearInterval(this.interval)
        this.interval = null
      }
      return
    }

    const hours = Math.floor(totalSeconds / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    const seconds = totalSeconds % 60
    const formatted = `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`

    this.displayTargets.forEach((target) => {
      target.textContent = formatted
    })

    if (!this.lockTitleValue) {
      this.element.title = `This sandbox project will self-destroy in ${formatted}.`
    }
  }
}
