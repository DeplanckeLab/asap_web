import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    itemSelector: String
  }

  dragstart(event) {
    const item = event.currentTarget.closest(this.itemSelectorValue)
    if (!item) return

    this.draggedItem = item
    item.classList.add("opacity-50")
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", item.dataset.id)
  }

  dragover(event) {
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
  }

  drop(event) {
    event.preventDefault()
    const target = event.currentTarget.closest(this.itemSelectorValue)
    if (!target || !this.draggedItem || target === this.draggedItem) return

    const targetRect = target.getBoundingClientRect()
    const insertAfter = event.clientY > targetRect.top + targetRect.height / 2
    if (insertAfter) {
      target.after(this.draggedItem)
    } else {
      target.before(this.draggedItem)
    }

    this.persistOrder()
  }

  dragend(event) {
    const item = event.currentTarget.closest(this.itemSelectorValue)
    if (!item) return

    item.classList.remove("opacity-50")
    this.draggedItem = null
  }

  async persistOrder() {
    const orderedItems = Array.from(this.element.querySelectorAll(this.itemSelectorValue))
    const orderedIds = orderedItems.map((item) => item.dataset.id)
    this.refreshRankLabels(orderedItems)
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    await fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ ordered_ids: orderedIds })
    })
  }

  refreshRankLabels(items) {
    items.forEach((item, index) => {
      const label = item.querySelector("[data-rank-label]")
      if (!label) return

      if (label.textContent.includes("Step #")) {
        label.textContent = `Step #${index + 1}`
      } else {
        label.textContent = String(index + 1)
      }
    })
  }
}
