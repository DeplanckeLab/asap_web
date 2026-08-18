import { Controller } from "@hotwired/stimulus"

// Metadata downloads stay on the same page. First click owns the group so a
// second click does not start another extract.
export default class extends Controller {
  start(event) {
    if (this.element.dataset.annotDownloadBusy === "true" || event.detail > 1) {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    this.element.dataset.annotDownloadBusy = "true"
    this.lockGroup(event.currentTarget)
  }

  lockGroup(activeLink) {
    this.element.querySelectorAll("a").forEach((link) => {
      this.disableLink(link, link === activeLink ? "Preparing..." : null)
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
