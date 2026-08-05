import { Controller } from "@hotwired/stimulus"

// Opens the news history page when the welcome card is clicked,
// unless the click landed on a link inside the card.
export default class extends Controller {
  static values = { url: String }

  open(event) {
    if (event.type === "keydown" && event.key === " ") {
      event.preventDefault()
    }

    const interactive = event.target.closest("a, button, input, textarea, select, label")
    if (interactive && this.element.contains(interactive)) return

    window.location.href = this.urlValue
  }
}
