import { Controller } from "@hotwired/stimulus"

// Scrolls to and briefly highlights the news card matching the URL hash.
export default class extends Controller {
  static targets = ["card"]

  connect() {
    this.highlightFromHash()
    this.boundHashChange = () => this.highlightFromHash()
    window.addEventListener("hashchange", this.boundHashChange)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.boundHashChange)
    if (this.clearTimer) {
      clearTimeout(this.clearTimer)
      this.clearTimer = null
    }
  }

  highlightFromHash() {
    const hash = window.location.hash.toString().replace(/^#/, "")
    if (!hash) return

    const card = this.cardTargets.find((el) => el.id === hash)
    if (!card) return

    this.clearHighlight()

    requestAnimationFrame(() => {
      card.scrollIntoView({ behavior: "smooth", block: "center" })
      const ringClasses = (card.dataset.highlightRing || "ring-gray-400").split(/\s+/).filter(Boolean)
      card.classList.remove("ring-transparent")
      card.classList.add(...ringClasses)
      this.highlightedCard = card
      this.highlightedRingClasses = ringClasses

      this.clearTimer = setTimeout(() => this.clearHighlight(), 2500)
    })
  }

  clearHighlight() {
    if (!this.highlightedCard) return

    if (this.highlightedRingClasses?.length) {
      this.highlightedCard.classList.remove(...this.highlightedRingClasses)
    }
    this.highlightedCard.classList.add("ring-transparent")
    this.highlightedCard = null
    this.highlightedRingClasses = null
  }
}
