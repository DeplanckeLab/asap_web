import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "tbody", "columnsOnly"]

  filter() {
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
  }
}
