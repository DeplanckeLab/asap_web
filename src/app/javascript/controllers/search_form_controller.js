import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    debounceMs: { type: Number, default: 350 }
  }

  connect() {
    this.submitTimer = null
  }

  disconnect() {
    this.clearSubmitTimer()
  }

  submitDebounced() {
    this.clearSubmitTimer()
    this.submitTimer = setTimeout(() => {
      this.submitNow()
    }, this.debounceMsValue)
  }

  submitNow() {
    this.clearSubmitTimer()
    this.element.submit()
  }

  clearSubmitTimer() {
    if (this.submitTimer) {
      clearTimeout(this.submitTimer)
      this.submitTimer = null
    }
  }
}
