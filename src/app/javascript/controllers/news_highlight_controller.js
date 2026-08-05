import { Controller } from "@hotwired/stimulus"

// Scrolls to and briefly highlights the news card matching the URL hash.
// Accounts for the sticky news filter header under the fixed nav.
export default class extends Controller {
  static targets = ["card", "header"]

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
      this.scrollCardIntoView(card)

      const ringClasses = (card.dataset.highlightRing || "ring-gray-400").split(/\s+/).filter(Boolean)
      card.classList.remove("ring-transparent")
      card.classList.add(...ringClasses)
      this.highlightedCard = card
      this.highlightedRingClasses = ringClasses

      this.clearTimer = setTimeout(() => this.clearHighlight(), 2500)
    })
  }

  scrollCardIntoView(card) {
    const gap = 16
    const headerBottom = this.hasHeaderTarget
      ? this.headerTarget.getBoundingClientRect().bottom
      : 0
    const cardTop = card.getBoundingClientRect().top
    const top = window.scrollY + cardTop - headerBottom - gap
    window.scrollTo({ top: Math.max(0, top), behavior: "smooth" })
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
