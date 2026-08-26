import { Controller } from "@hotwired/stimulus"

// Auto-submits the external catalog filter form when widgets change.
export default class extends Controller {
  static values = {
    debounce: { type: Number, default: 300 }
  }

  connect() {
    this.timer = null
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  submitNow() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    this.element.requestSubmit()
  }

  debouncedSubmit() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.timer = null
      this.element.requestSubmit()
    }, this.debounceValue)
  }
}
