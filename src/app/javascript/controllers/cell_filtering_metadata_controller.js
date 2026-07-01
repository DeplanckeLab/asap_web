import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["storeRunSelect", "annotSelect", "categoriesContainer", "discardedMetadataHidden", "manualSelectionHidden"]
  static values = {
    projectKey: String,
    annotsByRun: Object
  }

  connect() {
    this.updateAnnotOptions()
  }

  storeRunChanged() {
    this.updateAnnotOptions()
    this.renderEmptyCategories()
    this.emitCategoriesChanged()
    this.updateMetadataSummary()
  }

  annotChanged() {
    const annotId = this.hasAnnotSelectTarget ? this.annotSelectTarget.value : ""
    if (!annotId) {
      this.renderEmptyCategories()
      this.emitCategoriesChanged()
      this.updateMetadataSummary()
      return
    }
    this.loadCategories(annotId)
  }

  toggleAll(event) {
    const shouldCheck = event.params.checked === "true"
    this.categoriesContainerTarget.querySelectorAll(".check_box_cat").forEach((checkbox) => {
      checkbox.checked = shouldCheck
    })
    this.updateMetadataSummary()
    this.emitCategoriesChanged()
  }

  categoryChanged() {
    this.updateMetadataSummary()
    this.emitCategoriesChanged()
  }

  updateAnnotOptions() {
    if (!this.hasStoreRunSelectTarget || !this.hasAnnotSelectTarget) return
    const runId = this.storeRunSelectTarget.value
    const annots = (this.annotsByRunValue && this.annotsByRunValue[runId]) ? this.annotsByRunValue[runId] : []

    this.annotSelectTarget.innerHTML = ""
    const placeholder = document.createElement("option")
    placeholder.value = ""
    placeholder.textContent = "Select an annotation"
    this.annotSelectTarget.appendChild(placeholder)

    annots
      .slice()
      .sort((a, b) => String(a.name).localeCompare(String(b.name)))
      .forEach((annot) => {
        const option = document.createElement("option")
        option.value = String(annot.id)
        option.textContent = String(annot.name || "")
        this.annotSelectTarget.appendChild(option)
      })

    this.annotSelectTarget.value = ""
  }

  loadCategories(annotId) {
    fetch(`/annots/${annotId}/categories.json`, {
      method: "GET",
      headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" },
      credentials: "same-origin"
    })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`)
        }
        return response.json()
      })
      .then((payload) => {
        const categories = Array.isArray(payload.categories) ? payload.categories : []
        this.renderCategories(categories)
        this.updateMetadataSummary()
        this.emitCategoriesChanged()
      })
      .catch(() => {
        this.categoriesContainerTarget.innerHTML = "<div class='text-sm text-red-600'>Failed to load categories.</div>"
        this.emitCategoriesChanged()
      })
  }

  renderCategories(categories) {
    if (!this.hasCategoriesContainerTarget) return
    if (!categories.length) {
      this.categoriesContainerTarget.innerHTML = "<div class='cell-filtering-hint text-gray-500'>No categories available.</div>"
      return
    }

    const badges = categories.map((cat) => {
      const catName = String(cat.name ?? "NA")
      const safeCat = catName.replace(/"/g, "&quot;")
      const indices = Array.isArray(cat.indices) ? cat.indices : []
      const encodedIndices = JSON.stringify(indices).replace(/"/g, "&quot;")
      return `
        <label class="inline-flex items-center gap-1 rounded border border-gray-200 bg-gray-50 text-gray-700">
          <input type="checkbox"
                 class="check_box_cat"
                 id="sc_${safeCat}"
                 data-cell-indices="${encodedIndices}"
                 checked
                 data-action="change->cell-filtering-metadata#categoryChanged">
          <span>${safeCat} (${indices.length} cells)</span>
        </label>
      `
    }).join("")

    this.categoriesContainerTarget.innerHTML = `
      <div class="cell-filtering-metadata-actions">
        <button type="button"
                class="bg-sky-600 hover:bg-sky-700 text-white rounded"
                data-action="click->cell-filtering-metadata#toggleAll"
                data-cell-filtering-metadata-checked-param="true">Select all</button>
        <button type="button"
                class="bg-sky-600 hover:bg-sky-700 text-white rounded"
                data-action="click->cell-filtering-metadata#toggleAll"
                data-cell-filtering-metadata-checked-param="false">Unselect all</button>
      </div>
      <div id="list_of_cats" class="flex flex-wrap">${badges}</div>
    `
  }

  renderEmptyCategories() {
    if (this.hasCategoriesContainerTarget) {
      this.categoriesContainerTarget.innerHTML = ""
    }
  }

  updateMetadataSummary() {
    if (!this.hasDiscardedMetadataHiddenTarget || !this.hasManualSelectionHiddenTarget || !this.hasAnnotSelectTarget) return

    const annotName = this.hasAnnotSelectTarget
      ? this.annotSelectTarget.options[this.annotSelectTarget.selectedIndex]?.text?.trim()
      : ""

    const checked = []
    const unchecked = []
    this.categoriesContainerTarget.querySelectorAll(".check_box_cat").forEach((checkbox) => {
      const catName = checkbox.id.replace(/^sc_/, "")
      if (checkbox.checked) checked.push(catName)
      else unchecked.push(catName)
    })

    const type = checked.length < unchecked.length ? "sel" : "unsel"
    const vals = type === "sel" ? checked : unchecked
    const payload = {}
    if (annotName) payload[annotName] = { type, vals }

    this.discardedMetadataHiddenTarget.value = JSON.stringify(payload)

    const label = annotName && vals.length > 0 ? `${annotName}: ${(type === "sel" ? "discarded" : "kept")}=${vals.join(",")}` : ""
    this.manualSelectionHiddenTarget.value = label
  }

  emitCategoriesChanged() {
    this.element.dispatchEvent(new CustomEvent("metadata-categories-changed", { bubbles: true }))
  }
}
