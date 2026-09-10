import { Controller } from "@hotwired/stimulus"

// Shows a preview of warnings in-card, and the full list in a closable popup.
export default class extends Controller {
  static targets = ["modal", "expandButton"]

  connect() {
    if (!this.hasModalTarget && this.hasExpandButtonTarget) {
      this.expandButtonTarget.classList.add("hidden")
    }
  }

  disconnect() {
    this.unlockBody()
  }

  open(event) {
    if (event) event.preventDefault()
    if (!this.hasModalTarget) return
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  close(event) {
    if (event) event.preventDefault()
    if (!this.hasModalTarget) return
    this.modalTarget.classList.add("hidden")
    this.unlockBody()
  }

  stop(event) {
    event.stopPropagation()
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") return
    if (!this.hasModalTarget || this.modalTarget.classList.contains("hidden")) return
    this.close()
  }

  unlockBody() {
    document.body.classList.remove("overflow-hidden")
  }
}
