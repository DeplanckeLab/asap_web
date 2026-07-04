import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["searchInput", "results", "hiddenField", "selectedDisplay"]
  static values = {
    projectId: String,
    attrName: String,
    collectionAttrName: { type: String, default: "global_gene_set_collection_id" },
    matrixAttrName: { type: String, default: "input_matrix" }
  }

  connect() {
    this.debounceTimer = null
    this.selectedItemLabel = ""

    this.boundCollectionChange = this.handleCollectionChange.bind(this)
    this.boundMatrixContextChanged = this.handleMatrixContextChanged.bind(this)
    this.boundDocumentClick = this.handleDocumentClick.bind(this)

    const collectionSelect = this.getCollectionSelect()
    if (collectionSelect) {
      collectionSelect.addEventListener("change", this.boundCollectionChange)
    }

    const form = this.element.closest("form")
    if (form) {
      form.addEventListener("input-data:matrix-context-changed", this.boundMatrixContextChanged)
    }

    document.addEventListener("click", this.boundDocumentClick, true)

    this.restoreFromHiddenField()
    this.refreshItems("")
  }

  disconnect() {
    const collectionSelect = this.getCollectionSelect()
    if (collectionSelect) {
      collectionSelect.removeEventListener("change", this.boundCollectionChange)
    }

    const form = this.element.closest("form")
    if (form) {
      form.removeEventListener("input-data:matrix-context-changed", this.boundMatrixContextChanged)
    }

    document.removeEventListener("click", this.boundDocumentClick, true)
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer)
    }
  }

  searchInputChanged() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => {
      this.refreshItems(this.searchInputTarget.value.trim())
    }, 300)
  }

  handleCollectionChange() {
    this.clearSelection()
    this.refreshItems(this.searchInputTarget.value.trim())
  }

  handleMatrixContextChanged() {
    this.refreshItems(this.searchInputTarget.value.trim())
  }

  handleDocumentClick(event) {
    if (!this.element.contains(event.target)) {
      this.hideResults()
    }
  }

  getCollectionSelect() {
    return document.getElementById(`attrs_${this.collectionAttrNameValue}`)
  }

  getLoomFile() {
    const matrixHidden = document.getElementById(`attrs_${this.matrixAttrNameValue}`)
    if (!matrixHidden || !matrixHidden.value) {
      return ""
    }
    try {
      const parsed = JSON.parse(matrixHidden.value)
      const item = Array.isArray(parsed) ? parsed[0] : parsed
      return item && item.output_filename ? String(item.output_filename) : ""
    } catch (_e) {
      return ""
    }
  }

  restoreFromHiddenField() {
    const itemId = String(this.hiddenFieldTarget.value || "").trim()
    if (!itemId) {
      return
    }
    this.selectedItemLabel = `Gene set item #${itemId}`
    this.renderSelectedDisplay()
  }

  clearSelection() {
    this.hiddenFieldTarget.value = ""
    this.selectedItemLabel = ""
    this.renderSelectedDisplay()
    this.dispatchChanged()
  }

  renderSelectedDisplay() {
    if (!this.hasSelectedDisplayTarget) {
      return
    }
    if (this.selectedItemLabel) {
      this.selectedDisplayTarget.textContent = this.selectedItemLabel
      this.selectedDisplayTarget.classList.remove("hidden")
    } else {
      this.selectedDisplayTarget.textContent = ""
      this.selectedDisplayTarget.classList.add("hidden")
    }
  }

  async refreshItems(query) {
    const collectionId = this.getCollectionSelect()?.value
    const loomFile = this.getLoomFile()

    if (!collectionId) {
      this.renderResultsMessage("Select a gene set collection first")
      return
    }
    if (!loomFile) {
      this.renderResultsMessage("Select an input matrix first")
      return
    }

    const params = new URLSearchParams({
      collection_id: collectionId,
      loom_file: loomFile,
      query: query
    })

    try {
      const response = await fetch(
        `/projects/${encodeURIComponent(this.projectIdValue)}/gene_set_collection_items?${params.toString()}`,
        { headers: { Accept: "application/json" } }
      )
      const payload = await response.json()
      if (!response.ok || payload.status !== "ok") {
        this.renderResultsMessage(payload.message || "Failed to load gene sets")
        return
      }

      const items = Array.isArray(payload.items)
        ? payload.items.filter((item) => item.supports_module_score !== false)
        : []
      this.renderItems(items)
    } catch (_e) {
      this.renderResultsMessage("Failed to load gene sets")
    }
  }

  renderResultsMessage(message) {
    if (!this.hasResultsTarget) {
      return
    }
    this.resultsTarget.innerHTML = ""
    const row = document.createElement("div")
    row.className = "px-4 py-3 text-sm text-gray-500"
    row.textContent = message
    this.resultsTarget.appendChild(row)
    this.showResults()
  }

  formatItemNameHtml(name) {
    const trimmed = String(name || "").trim()
    if (trimmed) {
      return this.escapeHtml(trimmed)
    }
    return '<span class="italic text-gray-500">No name</span>'
  }

  formatItemLabelPlain(item) {
    const identifier = String(item.identifier || "").trim()
    const name = String(item.name || "").trim()
    if (identifier) {
      return name ? `${identifier} ${name}` : `${identifier} No name`
    }
    if (name) {
      return name
    }
    return item.display_name || `Item ${item.id}`
  }

  formatItemLabelHtml(item) {
    const identifier = String(item.identifier || "").trim()
    const name = String(item.name || "").trim()
    if (identifier) {
      const nameHtml = name
        ? ` ${this.escapeHtml(name)}`
        : ` ${this.formatItemNameHtml("")}`
      return `${this.escapeHtml(identifier)}${nameHtml}`
    }
    if (name) {
      return this.escapeHtml(name)
    }
    return this.escapeHtml(item.display_name || `Item ${item.id}`)
  }

  renderItems(items) {
    if (!this.hasResultsTarget) {
      return
    }
    this.resultsTarget.innerHTML = ""

    if (items.length === 0) {
      this.renderResultsMessage("No matching gene sets")
      return
    }

    items.forEach((item) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "w-full text-left px-4 py-3 hover:bg-gray-50 border-b border-gray-100 last:border-b-0"
      const label = this.formatItemLabelPlain(item)
      const labelHtml = this.formatItemLabelHtml(item)
      const countParts = []
      if (item.gene_count != null) {
        countParts.push(`${item.gene_count} genes`)
      }
      if (item.in_dataset_count != null) {
        countParts.push(`${item.in_dataset_count} in dataset`)
      }
      button.innerHTML = `
        <div class="font-medium text-gray-900">${labelHtml}</div>
        ${countParts.length > 0 ? `<div class="text-xs text-gray-500 mt-1">${this.escapeHtml(countParts.join(", "))}</div>` : ""}
      `
      button.addEventListener("click", (event) => {
        event.preventDefault()
        event.stopPropagation()
        this.selectItem(item.id, label)
      })
      this.resultsTarget.appendChild(button)
    })

    this.showResults()
  }

  selectItem(itemId, label) {
    this.hiddenFieldTarget.value = String(itemId)
    this.selectedItemLabel = label
    if (this.hasSearchInputTarget) {
      this.searchInputTarget.value = label
    }
    this.renderSelectedDisplay()
    this.hideResults()
    this.dispatchChanged()
  }

  dispatchChanged() {
    this.hiddenFieldTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.dispatch("changed", { detail: { itemId: this.hiddenFieldTarget.value } })
  }

  showResults() {
    if (!this.hasResultsTarget) {
      return
    }
    this.resultsTarget.classList.remove("hidden")
  }

  hideResults() {
    if (!this.hasResultsTarget) {
      return
    }
    this.resultsTarget.classList.add("hidden")
  }

  escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }
}
