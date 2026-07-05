import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "tbody", "columnsOnly"]
  static values = {
    saveUrl: String,
    initialFilter: { type: String, default: "" },
    initialColumnsOnly: { type: Boolean, default: false }
  }

  connect() {
    if (this.hasInputTarget && this.initialFilterValue) {
      this.inputTarget.value = this.initialFilterValue
    }
    if (this.hasColumnsOnlyTarget) {
      this.columnsOnlyTarget.checked = this.initialColumnsOnlyValue
    }
    this.applyFilter()
  }

  filter() {
    this.applyFilter()
    this.schedulePersist()
  }

  applyFilter() {
    const raw = this.hasInputTarget ? this.inputTarget.value : ""
    const q = raw.toLowerCase().trim()
    if (!this.hasTbodyTarget) return

    const columnsOnly =
      this.hasColumnsOnlyTarget && this.columnsOnlyTarget.checked

    this.tbodyTarget.querySelectorAll("tr").forEach((row) => {
      const haystack = columnsOnly
        ? row.dataset.rowFilterColumns || ""
        : row.dataset.rowFilterText || ""
      if (q.length === 0) {
        row.hidden = false
      } else {
        row.hidden = !haystack.includes(q)
      }
    })

    this.schedulePersist()
  }

  schedulePersist() {
    if (!this.hasSaveUrlValue) return

    clearTimeout(this.persistTimer)
    this.persistTimer = setTimeout(() => this.persist(), 300)
  }

  persist() {
    if (!this.hasSaveUrlValue) return

    const body = new FormData()
    body.append("table_filter", this.hasInputTarget ? this.inputTarget.value : "")
    body.append(
      "columns_only",
      this.hasColumnsOnlyTarget && this.columnsOnlyTarget.checked ? "1" : "0"
    )

    const csrfToken =
      document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""

    fetch(this.saveUrlValue, {
      method: "PATCH",
      body,
      headers: {
        "X-CSRF-Token": csrfToken,
        Accept: "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
      },
      credentials: "same-origin"
    })
  }
}
