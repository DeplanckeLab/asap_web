import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "message", "form"]

  open(event) {
    event.preventDefault()

    const url = event.params.url
    if (!url) {
      console.error("[ConfirmDeleteController] Missing url param")
      return
    }

    const label = event.params.label || "this item"
    this.messageTarget.textContent = `Delete "${label}"? This cannot be undone.`
    this.formTarget.action = url
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  close(event) {
    if (event) {
      event.preventDefault()
    }
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  stop(event) {
    event.stopPropagation()
  }

  closeOnBackdrop(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && !this.modalTarget.classList.contains("hidden")) {
      this.close()
    }
  }

  confirm(event) {
    event.preventDefault()
    this.formTarget.requestSubmit()
  }
}
