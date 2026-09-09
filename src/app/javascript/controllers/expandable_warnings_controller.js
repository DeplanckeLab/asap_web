import { Controller } from "@hotwired/stimulus"

// Collapses long warning lists, with a button to reveal every item.
export default class extends Controller {
  static targets = ["extra", "expandButton"]

  connect() {
    if (this.extraTargets.length === 0) {
      if (this.hasExpandButtonTarget) {
        this.expandButtonTarget.classList.add("hidden")
      }
      return
    }
    this.extraTargets.forEach((el) => el.classList.add("hidden"))
    if (this.hasExpandButtonTarget) {
      this.expandButtonTarget.classList.remove("hidden")
    }
  }

  expand(event) {
    if (event) event.preventDefault()
    this.extraTargets.forEach((el) => el.classList.remove("hidden"))
    if (this.hasExpandButtonTarget) {
      this.expandButtonTarget.remove()
    }
  }
}
