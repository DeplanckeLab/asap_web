import { Controller } from "@hotwired/stimulus"

// Expression-matrix downloads (ASAP.jar ExtractRow) can take minutes with no
// page navigation. Keep the TSV/JSON links clickable and users start a second
// extract. First click owns the group; a heavy download also locks other
// matrix download groups on this page.
export default class extends Controller {
  static values = {
    heavy: { type: Boolean, default: false }
  }

  static heavyBusy = false

  start(event) {
    if (this.element.dataset.annotDownloadBusy === "true" || event.detail > 1) {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    if (this.heavyValue && this.constructor.heavyBusy) {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    this.element.dataset.annotDownloadBusy = "true"
    if (this.heavyValue) {
      this.constructor.heavyBusy = true
      this.lockOtherHeavyGroups()
    }

    this.lockGroup(event.currentTarget)
  }

  lockGroup(activeLink) {
    this.element.querySelectorAll("a").forEach((link) => {
      this.disableLink(link, link === activeLink ? "Preparing..." : null)
    })
  }

  lockOtherHeavyGroups() {
    document.querySelectorAll("[data-controller~='annot-download']").forEach((el) => {
      if (el === this.element) return
      if (el.dataset.annotDownloadHeavyValue !== "true") return
      el.dataset.annotDownloadBusy = "true"
      el.querySelectorAll("a").forEach((link) => this.disableLink(link, null))
    })
  }

  disableLink(link, label) {
    link.classList.add("opacity-50", "pointer-events-none", "cursor-wait")
    link.setAttribute("aria-disabled", "true")
    link.setAttribute("title", "Download in progress")
    if (label) {
      link.textContent = label
    }
  }
}
