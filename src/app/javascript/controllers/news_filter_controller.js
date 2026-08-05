import { Controller } from "@hotwired/stimulus"

// Filters news cards by category on the news index page.
export default class extends Controller {
  static targets = ["button", "card", "empty"]
  static values = {
    type: { type: String, default: "" }
  }

  connect() {
    const params = new URLSearchParams(window.location.search)
    const fromQuery = (params.get("type") || "").trim()
    if (fromQuery) this.typeValue = fromQuery
    this.applyFilter()
  }

  select(event) {
    event.preventDefault()
    const type = event.currentTarget.dataset.newsType || ""
    this.typeValue = type
    this.syncQuery()
    this.applyFilter()
  }

  applyFilter() {
    const selected = this.typeValue.toString()
    let visibleCount = 0

    this.cardTargets.forEach((card) => {
      const match = selected === "" || card.dataset.newsType === selected
      card.hidden = !match
      if (match) visibleCount += 1
    })

    this.buttonTargets.forEach((button) => {
      const active = (button.dataset.newsType || "") === selected
      button.setAttribute("aria-pressed", active ? "true" : "false")
      button.classList.toggle("bg-gray-900", active)
      button.classList.toggle("text-white", active)
      button.classList.toggle("border-gray-900", active)
      button.classList.toggle("bg-white", !active)
      button.classList.toggle("text-gray-700", !active)
      button.classList.toggle("border-gray-300", !active)
      button.classList.toggle("dark:bg-white", !active)
      button.classList.toggle("dark:text-gray-800", !active)
    })

    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = visibleCount > 0
    }
  }

  syncQuery() {
    const url = new URL(window.location.href)
    if (this.typeValue) {
      url.searchParams.set("type", this.typeValue)
    } else {
      url.searchParams.delete("type")
    }
    window.history.replaceState({}, "", url)
  }
}
