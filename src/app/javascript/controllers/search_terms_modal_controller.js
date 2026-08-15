import { Controller } from "@hotwired/stimulus"

// Opens a full-list popup for truncated ontology term badges (e.g. Technology on search projects),
// matching the summary scFAIR metadata card modal.
export default class extends Controller {
  static targets = ["overlay", "titleText", "titleSwatch", "count", "countLabel", "list"]

  connect() {
    this.onClick = this.onClick.bind(this)
    this.onKeydown = this.onKeydown.bind(this)
    this.element.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    this.element.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKeydown)
  }

  onClick(event) {
    const trigger = event.target.closest("[data-search-terms-modal-trigger]")
    if (trigger && this.element.contains(trigger)) {
      event.preventDefault()
      event.stopPropagation()
      this.openFromTrigger(trigger)
      return
    }

    if (event.target === this.overlayTarget) {
      this.close()
    }
  }

  onKeydown(event) {
    if (event.key === "Escape" && !this.overlayTarget.classList.contains("hidden")) {
      this.close()
    }
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    this.listTarget.innerHTML = ""
  }

  openFromTrigger(trigger) {
    let terms = []
    try {
      terms = JSON.parse(trigger.dataset.cardTerms || "[]")
    } catch (_error) {
      terms = []
    }
    if (!Array.isArray(terms)) terms = []

    terms = terms.map((term) => {
      if (term && typeof term === "object") {
        return {
          label: String(term.label == null ? "" : term.label),
          identifier: String(term.identifier == null ? "" : term.identifier),
          url: String(term.url == null ? "" : term.url)
        }
      }
      const text = String(term == null ? "" : term)
      return { label: text, identifier: "", url: "" }
    }).filter((term) => term.label || term.identifier)

    terms.sort((a, b) => {
      const left = a.label || a.identifier
      const right = b.label || b.identifier
      const leftMatch = left.match(/^(\d+)/)
      const rightMatch = right.match(/^(\d+)/)
      if (leftMatch && rightMatch) {
        const byNumber = Number(leftMatch[1]) - Number(rightMatch[1])
        if (byNumber !== 0) return byNumber
        return left.localeCompare(right, undefined, { sensitivity: "base" })
      }
      if (leftMatch) return -1
      if (rightMatch) return 1
      return left.localeCompare(right, undefined, { sensitivity: "base" })
    })

    const label = trigger.dataset.cardLabel || "Terms"
    const color = trigger.dataset.cardColor || "#64748B"
    this.titleTextTarget.textContent = label
    this.titleSwatchTarget.style.backgroundColor = color
    this.countTarget.textContent = String(terms.length)
    this.countLabelTarget.textContent = terms.length <= 1 ? "term" : "terms"
    this.listTarget.innerHTML = terms.map((term) => {
      const displayLabel = this.escapeHtml(term.label || term.identifier)
      const ontologyUrl = /^https?:\/\//i.test(term.url) ? term.url : ""
      const identifierHtml = term.identifier
        ? `<span class="shrink-0 badge-text font-mono opacity-90">${this.escapeHtml(term.identifier)}</span>`
        : ""
      const inner = `<span class="min-w-0 break-words">${displayLabel}</span>${identifierHtml}`
      const rowClass = "badge-text px-3 py-1.5 rounded flex items-baseline justify-between gap-3"
      const rowStyle = `background-color: ${color}22; color: ${color};`
      if (ontologyUrl) {
        return `<li><a href="${this.escapeHtml(ontologyUrl)}" target="_blank" rel="noopener noreferrer" class="${rowClass} hover:opacity-80" style="${rowStyle}">${inner}</a></li>`
      }
      return `<li class="${rowClass}" style="${rowStyle}">${inner}</li>`
    }).join("")
    this.overlayTarget.classList.remove("hidden")
  }

  escapeHtml(value) {
    return String(value == null ? "" : value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}
