import { Controller } from "@hotwired/stimulus"

// Horizontal peek carousel for welcome news cards: scroll-snap track,
// prev/next by one card, and button state from scroll position.
export default class extends Controller {
  static targets = ["track", "prev", "next", "item"]

  connect() {
    this.onScroll = () => this.updateButtons()
    this.trackTarget.addEventListener("scroll", this.onScroll, { passive: true })
    this.resizeObserver = new ResizeObserver(() => this.updateButtons())
    this.resizeObserver.observe(this.trackTarget)
    this.updateButtons()
  }

  disconnect() {
    this.trackTarget.removeEventListener("scroll", this.onScroll)
    if (this.resizeObserver) this.resizeObserver.disconnect()
  }

  prev() {
    this.scrollByDirection(-1)
  }

  next() {
    this.scrollByDirection(1)
  }

  keydown(event) {
    if (event.key === "ArrowLeft") {
      event.preventDefault()
      this.prev()
    } else if (event.key === "ArrowRight") {
      event.preventDefault()
      this.next()
    }
  }

  scrollByDirection(direction) {
    const behavior = window.matchMedia("(prefers-reduced-motion: reduce)").matches
      ? "auto"
      : "smooth"
    this.trackTarget.scrollBy({ left: this.scrollAmount() * direction, behavior })
  }

  scrollAmount() {
    const item = this.itemTargets[0]
    if (!item) return this.trackTarget.clientWidth * 0.8

    const style = getComputedStyle(this.trackTarget)
    const gap = parseFloat(style.columnGap || style.gap) || 0
    return item.offsetWidth + gap
  }

  updateButtons() {
    const el = this.trackTarget
    const maxScroll = el.scrollWidth - el.clientWidth
    const atStart = el.scrollLeft <= 1
    const atEnd = el.scrollLeft >= maxScroll - 1 || maxScroll <= 1

    if (this.hasPrevTarget) {
      this.prevTarget.disabled = atStart
    }
    if (this.hasNextTarget) {
      this.nextTarget.disabled = atEnd
    }
  }
}
