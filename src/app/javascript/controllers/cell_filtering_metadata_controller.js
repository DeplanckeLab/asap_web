import { Controller } from "@hotwired/stimulus"

const SET_OPERATIONS = [
  { value: "intersection", label: "INTERSECTION" },
  { value: "union", label: "UNION" },
  { value: "difference_ab", label: "A \\ B" },
  { value: "difference_ba", label: "B \\ A" },
  { value: "xor", label: "SYMMETRIC DIFFERENCE" }
]

export default class extends Controller {
  static targets = [
    "filtersContainer",
    "resultSummary",
    "discardedMetadataHidden",
    "manualSelectionHidden"
  ]
  static values = {
    projectKey: String,
    annotsByRun: Object,
    runs: Array,
    nberCells: Number
  }

  connect() {
    this.nextFilterId = 1
    this.filters = []
    this.addFilter()
  }

  reset() {
    this.filters = []
    this.nextFilterId = 1
    this.addFilter()
  }

  addFilter(event) {
    if (event) event.preventDefault()
    const defaultRunId = this.defaultRunId()
    this.filters.push({
      id: this.nextFilterId++,
      runId: defaultRunId,
      annotId: "",
      annotName: "",
      categories: [],
      operationBefore: this.filters.length === 0 ? null : "intersection",
      loading: false,
      error: null
    })
    this.render()
    this.syncSummaryAndEmit()
  }

  removeFilter(event) {
    const filterId = parseInt(event.params.filterId, 10)
    this.filters = this.filters.filter((filter) => filter.id !== filterId)
    if (this.filters.length === 0) {
      this.addFilter()
      return
    }
    this.filters[0].operationBefore = null
    this.render()
    this.syncSummaryAndEmit()
  }

  operationChanged(event) {
    const filterId = parseInt(event.params.filterId, 10)
    const filter = this.findFilter(filterId)
    if (!filter || filter.operationBefore === null) return
    filter.operationBefore = event.currentTarget.value
    this.syncSummaryAndEmit()
  }

  storeRunChanged(event) {
    const filterId = parseInt(event.params.filterId, 10)
    const filter = this.findFilter(filterId)
    if (!filter) return
    filter.runId = event.currentTarget.value
    filter.annotId = ""
    filter.annotName = ""
    filter.categories = []
    filter.error = null
    this.render()
    this.syncSummaryAndEmit()
  }

  annotChanged(event) {
    const filterId = parseInt(event.params.filterId, 10)
    const filter = this.findFilter(filterId)
    if (!filter) return
    const annotId = event.currentTarget.value
    filter.annotId = annotId
    filter.annotName = this.annotNameFor(filter.runId, annotId)
    filter.categories = []
    filter.error = null
    if (!annotId) {
      this.render()
      this.syncSummaryAndEmit()
      return
    }
    this.loadCategories(filter)
  }

  toggleAll(event) {
    const filterId = parseInt(event.params.filterId, 10)
    const shouldCheck = event.params.checked === true || event.params.checked === "true"
    const filter = this.findFilter(filterId)
    if (!filter) return
    filter.categories.forEach((category) => {
      category.checked = shouldCheck
    })
    this.renderFilterCategories(filter)
    this.syncSummaryAndEmit()
  }

  categoryChanged(event) {
    const filterId = parseInt(event.params.filterId, 10)
    const categoryIndex = parseInt(event.params.categoryIndex, 10)
    const filter = this.findFilter(filterId)
    if (!filter) return
    const category = filter.categories[categoryIndex]
    if (!category) return
    category.checked = event.currentTarget.checked
    this.syncSummaryAndEmit()
  }

  getDiscardedIndices() {
    return this.computeComposition().discardedIndices
  }

  findFilter(filterId) {
    return this.filters.find((filter) => filter.id === filterId)
  }

  defaultRunId() {
    const runs = Array.isArray(this.runsValue) ? this.runsValue : []
    if (runs.length === 0) return ""
    return String(runs[0].id)
  }

  annotsForRun(runId) {
    const byRun = this.annotsByRunValue || {}
    return Array.isArray(byRun[runId]) ? byRun[runId] : []
  }

  annotNameFor(runId, annotId) {
    const annot = this.annotsForRun(runId).find((entry) => String(entry.id) === String(annotId))
    return annot ? String(annot.name || "") : ""
  }

  loadCategories(filter) {
    filter.loading = true
    filter.error = null
    this.render()
    fetch(`/annots/${filter.annotId}/categories.json`, {
      method: "GET",
      headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" },
      credentials: "same-origin"
    })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then((payload) => {
        const current = this.findFilter(filter.id)
        if (!current || String(current.annotId) !== String(filter.annotId)) return
        const categories = Array.isArray(payload.categories) ? payload.categories : []
        current.categories = categories.map((cat) => ({
          name: String(cat.name ?? "NA"),
          indices: Array.isArray(cat.indices) ? cat.indices.map((idx) => parseInt(idx, 10)).filter((idx) => !Number.isNaN(idx)) : [],
          checked: true
        }))
        current.loading = false
        current.error = null
        this.render()
        this.syncSummaryAndEmit()
      })
      .catch(() => {
        const current = this.findFilter(filter.id)
        if (!current || String(current.annotId) !== String(filter.annotId)) return
        current.categories = []
        current.loading = false
        current.error = "Failed to load categories."
        this.render()
        this.syncSummaryAndEmit()
      })
  }

  applySetOperation(setA, setB, operation) {
    const result = new Set()
    if (operation === "intersection") {
      setA.forEach((value) => {
        if (setB.has(value)) result.add(value)
      })
      return result
    }
    if (operation === "difference_ab") {
      setA.forEach((value) => {
        if (!setB.has(value)) result.add(value)
      })
      return result
    }
    if (operation === "difference_ba") {
      setB.forEach((value) => {
        if (!setA.has(value)) result.add(value)
      })
      return result
    }
    if (operation === "xor") {
      setA.forEach((value) => {
        if (!setB.has(value)) result.add(value)
      })
      setB.forEach((value) => {
        if (!setA.has(value)) result.add(value)
      })
      return result
    }
    setA.forEach((value) => result.add(value))
    setB.forEach((value) => result.add(value))
    return result
  }

  operationLabel(operation) {
    const found = SET_OPERATIONS.find((entry) => entry.value === operation)
    return found ? found.label : "UNION"
  }

  activeFilters() {
    return this.filters.filter((filter) => filter.annotId && filter.categories.length > 0)
  }

  selectedSetFor(filter) {
    const selected = new Set()
    filter.categories.forEach((category) => {
      if (!category.checked) return
      category.indices.forEach((idx) => selected.add(idx))
    })
    return selected
  }

  universeSetFor(filter) {
    const universe = new Set()
    filter.categories.forEach((category) => {
      category.indices.forEach((idx) => universe.add(idx))
    })
    return universe
  }

  computeComposition() {
    const active = this.activeFilters()
    if (active.length === 0) {
      return {
        keptIndices: [],
        discardedIndices: [],
        keptCount: null,
        recipe: { version: 2, filters: [], steps: [] }
      }
    }

    let kept = this.selectedSetFor(active[0])
    const universe = this.universeSetFor(active[0])
    const steps = []
    const filterPayload = []

    active.forEach((filter, index) => {
      const checked = filter.categories.filter((category) => category.checked).map((category) => category.name)
      const unchecked = filter.categories.filter((category) => !category.checked).map((category) => category.name)
      const type = checked.length < unchecked.length ? "sel" : "unsel"
      const vals = type === "sel" ? checked : unchecked
      filterPayload.push({
        annot: filter.annotName,
        annot_id: filter.annotId,
        run_id: filter.runId,
        type,
        vals,
        selected: checked
      })

      if (index === 0) return
      const operation = filter.operationBefore || "intersection"
      const operandB = this.selectedSetFor(filter)
      this.universeSetFor(filter).forEach((idx) => universe.add(idx))
      const beforeCount = kept.size
      kept = this.applySetOperation(kept, operandB, operation)
      steps.push({
        operation,
        operand_a_count: beforeCount,
        operand_b_count: operandB.size,
        result_count: kept.size,
        operand_b_annot: filter.annotName
      })
    })

    const discardedIndices = []
    universe.forEach((idx) => {
      if (!kept.has(idx)) discardedIndices.push(idx)
    })
    discardedIndices.sort((a, b) => a - b)

    return {
      keptIndices: Array.from(kept).sort((a, b) => a - b),
      discardedIndices,
      keptCount: kept.size,
      recipe: {
        version: 2,
        filters: filterPayload,
        steps,
        // Compatibility for older single-annot consumers
        ...Object.fromEntries(
          filterPayload.map((entry) => [entry.annot, { type: entry.type, vals: entry.vals }])
        )
      }
    }
  }

  syncSummaryAndEmit() {
    this.updateMetadataSummary()
    this.updateResultSummary()
    this.emitCategoriesChanged()
  }

  updateMetadataSummary() {
    if (!this.hasDiscardedMetadataHiddenTarget || !this.hasManualSelectionHiddenTarget) return
    const composition = this.computeComposition()
    this.discardedMetadataHiddenTarget.value = JSON.stringify(composition.recipe)

    const active = this.activeFilters()
    if (active.length === 0) {
      this.manualSelectionHiddenTarget.value = ""
      return
    }

    const parts = active.map((filter, index) => {
      const checked = filter.categories.filter((category) => category.checked).map((category) => category.name)
      const label = `${filter.annotName}:{${checked.join(",")}}`
      if (index === 0) return label
      return `${this.operationLabel(filter.operationBefore)} ${label}`
    })
    const keptLabel = composition.keptCount === null ? "" : ` => kept ${composition.keptCount}`
    this.manualSelectionHiddenTarget.value = parts.join(" ") + keptLabel
  }

  updateResultSummary() {
    if (!this.hasResultSummaryTarget) return
    const active = this.activeFilters()
    if (active.length === 0) {
      this.resultSummaryTarget.textContent = "No metadata filter applied."
      return
    }
    const composition = this.computeComposition()
    const opText = active.length === 1
      ? "selected categories"
      : `${active.length} metadata filters with set operations`
    this.resultSummaryTarget.textContent = `Metadata composition keeps ${composition.keptCount} cells (${opText}).`
  }

  emitCategoriesChanged() {
    this.element.dispatchEvent(new CustomEvent("metadata-categories-changed", { bubbles: true }))
  }

  escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
  }

  render() {
    if (!this.hasFiltersContainerTarget) return
    this.filtersContainerTarget.innerHTML = this.filters.map((filter, index) => this.renderFilterCard(filter, index)).join("")
  }

  renderFilterCategories(filter) {
    const container = this.filtersContainerTarget.querySelector(`[data-filter-categories="${filter.id}"]`)
    if (!container) return
    container.innerHTML = this.categoriesHtml(filter)
  }

  renderFilterCard(filter, index) {
    const runs = Array.isArray(this.runsValue) ? this.runsValue : []
    const annots = this.annotsForRun(filter.runId)
      .slice()
      .sort((a, b) => String(a.name).localeCompare(String(b.name)))

    const runOptions = runs.map((run) => {
      const selected = String(run.id) === String(filter.runId) ? " selected" : ""
      return `<option value="${this.escapeHtml(String(run.id))}"${selected}>${this.escapeHtml(String(run.label || run.id))}</option>`
    }).join("")

    const annotOptions = [
      `<option value="">Select an annotation</option>`,
      ...annots.map((annot) => {
        const selected = String(annot.id) === String(filter.annotId) ? " selected" : ""
        return `<option value="${this.escapeHtml(String(annot.id))}"${selected}>${this.escapeHtml(String(annot.name || ""))}</option>`
      })
    ].join("")

    const operationHtml = index === 0 ? "" : `
      <div class="cell-filtering-set-op">
        <label>Combine with previous using</label>
        <select data-action="change->cell-filtering-metadata#operationChanged"
                data-cell-filtering-metadata-filter-id-param="${filter.id}">
          ${SET_OPERATIONS.map((operation) => {
            const selected = operation.value === filter.operationBefore ? " selected" : ""
            return `<option value="${operation.value}"${selected}>${operation.label}</option>`
          }).join("")}
        </select>
      </div>
    `

    let categoriesBlock = ""
    if (filter.loading) {
      categoriesBlock = `<div class="cell-filtering-hint">Loading categories...</div>`
    } else if (filter.error) {
      categoriesBlock = `<div class="text-sm text-red-600">${this.escapeHtml(filter.error)}</div>`
    } else if (filter.annotId) {
      categoriesBlock = `<div data-filter-categories="${filter.id}">${this.categoriesHtml(filter)}</div>`
    }

    return `
      <div class="cell-filtering-metadata-filter" data-filter-id="${filter.id}">
        ${operationHtml}
        <div class="cell-filtering-metadata-filter-header">
          <span class="cell-filtering-metadata-filter-title">Metadata filter ${index + 1}</span>
          <button type="button"
                  class="cell-filtering-metadata-remove"
                  data-action="click->cell-filtering-metadata#removeFilter"
                  data-cell-filtering-metadata-filter-id-param="${filter.id}">Remove</button>
        </div>
        <div class="cell-filtering-field">
          <label>Run</label>
          <select data-action="change->cell-filtering-metadata#storeRunChanged"
                  data-cell-filtering-metadata-filter-id-param="${filter.id}">
            ${runOptions}
          </select>
        </div>
        <div class="cell-filtering-field">
          <label>Annotation</label>
          <select data-action="change->cell-filtering-metadata#annotChanged"
                  data-cell-filtering-metadata-filter-id-param="${filter.id}">
            ${annotOptions}
          </select>
        </div>
        ${categoriesBlock}
      </div>
    `
  }

  categoriesHtml(filter) {
    if (!filter.categories.length) {
      return `<div class="cell-filtering-hint text-gray-500">No categories available.</div>`
    }
    const badges = filter.categories.map((category, categoryIndex) => {
      const checked = category.checked ? " checked" : ""
      return `
        <label class="inline-flex items-center gap-1 rounded border border-gray-200 bg-gray-50 text-gray-700">
          <input type="checkbox"
                 class="check_box_cat"
                 ${checked}
                 data-action="change->cell-filtering-metadata#categoryChanged"
                 data-cell-filtering-metadata-filter-id-param="${filter.id}"
                 data-cell-filtering-metadata-category-index-param="${categoryIndex}">
          <span>${this.escapeHtml(category.name)} (${category.indices.length} cells)</span>
        </label>
      `
    }).join("")

    return `
      <div class="cell-filtering-metadata-actions">
        <button type="button"
                class="bg-sky-600 hover:bg-sky-700 text-white rounded"
                data-action="click->cell-filtering-metadata#toggleAll"
                data-cell-filtering-metadata-filter-id-param="${filter.id}"
                data-cell-filtering-metadata-checked-param="true">Select all</button>
        <button type="button"
                class="bg-sky-600 hover:bg-sky-700 text-white rounded"
                data-action="click->cell-filtering-metadata#toggleAll"
                data-cell-filtering-metadata-filter-id-param="${filter.id}"
                data-cell-filtering-metadata-checked-param="false">Unselect all</button>
      </div>
      <div class="list_of_cats flex flex-wrap">${badges}</div>
    `
  }
}
